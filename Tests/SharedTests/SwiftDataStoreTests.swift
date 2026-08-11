import SwiftData
import XCTest
@testable import Barosense

/// The durable stores against the same contracts the in-memory doubles satisfy.
///
/// Run on an in-memory `ModelContainer` built from the real `BarosenseModelContainer`
/// schema, so the mapping under test is the shipped one — only the file on disk is
/// missing.
final class SwiftDataStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeContainer() throws -> ModelContainer {
        try BarosenseModelContainer.makeInMemory()
    }

    // MARK: - Profile

    func testProfileRoundTripsThroughTheDurableStore() async throws {
        let store: any UserProfileStore =
            SwiftDataUserProfileStore(modelContainer: try makeContainer())

        let profile = UserProfile(displayName: "Sam",
                                  ageYears: 34,
                                  gender: .other,
                                  episodeFrequency: .weekly,
                                  typicalEpisodeDuration: .sixToTwentyFourHours,
                                  termsAcceptedAt: referenceDate,
                                  healthAccessRequestedAt: referenceDate,
                                  onboardingCompletedAt: referenceDate)

        try await store.save(profile)

        let read = try await store.profile()
        XCTAssertEqual(read, profile)
    }

    func testProfileIsNilBeforeAnythingIsWritten() async throws {
        let store: any UserProfileStore =
            SwiftDataUserProfileStore(modelContainer: try makeContainer())

        let read = try await store.profile()
        XCTAssertNil(read)
    }

    func testSecondSaveReplacesTheFirstRatherThanAddingARow() async throws {
        let store: any UserProfileStore =
            SwiftDataUserProfileStore(modelContainer: try makeContainer())

        try await store.save(UserProfile(displayName: "Sam", ageYears: 34))
        try await store.save(UserProfile(displayName: "Alex"))

        // A cleared field has to be cleared in storage; a second row would also show up
        // here as the old value coming back.
        let read = try await store.profile()
        XCTAssertEqual(read, UserProfile(displayName: "Alex"))
    }

    func testDeletedProfileStaysDeleted() async throws {
        let store: any UserProfileStore =
            SwiftDataUserProfileStore(modelContainer: try makeContainer())

        try await store.save(UserProfile(onboardingCompletedAt: referenceDate))
        try await store.deleteProfile()

        let read = try await store.profile()
        XCTAssertNil(read)
    }

    func testProfileSurvivesAFreshStoreOnTheSameContainer() async throws {
        // Stands in for a relaunch: a new store actor over the same container has to see
        // what the previous one wrote. This is the property onboarding depends on to not
        // run twice.
        let container = try makeContainer()
        let writer: any UserProfileStore = SwiftDataUserProfileStore(modelContainer: container)
        try await writer.save(UserProfile(displayName: "Sam",
                                          onboardingCompletedAt: referenceDate))

        let reader: any UserProfileStore = SwiftDataUserProfileStore(modelContainer: container)
        let read = try await reader.profile()

        XCTAssertEqual(read?.hasCompletedOnboarding, true)
        XCTAssertEqual(read?.displayName, "Sam")
    }

    // MARK: - Tag identity encoding

    func testBothIdentityKindsRoundTripThroughTheStorageKey() {
        let seeded = WellbeingTag.ID.seeded("fatigue")
        let user = WellbeingTag.ID.user(UUID())

        for id in [seeded, user] {
            let key = StoredWellbeingTag.identityKey(for: id)
            XCTAssertEqual(StoredWellbeingTag.identity(from: key), id)
        }
    }

    func testAnUnparseableKeyIsRejectedRatherThanGuessed() {
        XCTAssertNil(StoredWellbeingTag.identity(from: "fatigue"))
        XCTAssertNil(StoredWellbeingTag.identity(from: "seeded:"))
        XCTAssertNil(StoredWellbeingTag.identity(from: "user:not-a-uuid"))
        XCTAssertNil(StoredWellbeingTag.identity(from: "other:x"))
    }

    func testSeededAndUserKeysCannotCollide() {
        let uuid = UUID()
        XCTAssertNotEqual(StoredWellbeingTag.identityKey(for: .seeded(uuid.uuidString)),
                          StoredWellbeingTag.identityKey(for: .user(uuid)))
    }

    // MARK: - Tags

    func testSeedingIsIdempotent() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())

        try await store.insertIfAbsent(WellbeingTag.seeds)
        try await store.insertIfAbsent(WellbeingTag.seeds)

        let stored = try await store.allTags()
        XCTAssertEqual(stored.count, WellbeingTag.seeds.count)
        XCTAssertEqual(Set(stored.map(\.id)), Set(WellbeingTag.seeds.map(\.id)))
    }

    func testSeedingDoesNotUndoARename() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())

        try await store.insertIfAbsent(WellbeingTag.seeds)
        try await store.save(WellbeingTag(id: .seeded("fatigue"), name: "Worn out"))
        try await store.insertIfAbsent(WellbeingTag.seeds)

        let renamed = try await store.allTags().first { $0.id == .seeded("fatigue") }
        XCTAssertEqual(renamed?.name, "Worn out")
    }

    func testSeedingDoesNotResurrectAnArchivedTag() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())

        try await store.insertIfAbsent(WellbeingTag.seeds)
        try await store.archive(id: .seeded("joints"))
        try await store.insertIfAbsent(WellbeingTag.seeds)

        let active = try await store.activeTags()
        let all = try await store.allTags()
        XCTAssertFalse(active.contains { $0.id == .seeded("joints") })
        XCTAssertTrue(all.contains { $0.id == .seeded("joints") })
    }

    func testArchivingAnUnknownIdentifierIsNotAnError() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())

        try await store.archive(id: .user(UUID()))

        let all = try await store.allTags()
        XCTAssertTrue(all.isEmpty)
    }

    func testTagsComeBackAscendingByName() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())

        for name in ["Cold snap", "Anxious", "Bright light"] {
            try await store.save(WellbeingTag(id: .user(UUID()), name: name))
        }

        let names = try await store.activeTags().map(\.name)
        XCTAssertEqual(names, ["Anxious", "Bright light", "Cold snap"])
    }

    func testSaveWithTheSameIdentifierRenamesRatherThanDuplicates() async throws {
        let store: any WellbeingTagStore =
            SwiftDataWellbeingTagStore(modelContainer: try makeContainer())
        let id = WellbeingTag.ID.user(UUID())

        try await store.save(WellbeingTag(id: id, name: "Long drive"))
        try await store.save(WellbeingTag(id: id, name: "Commute"))

        let stored = try await store.allTags()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(stored.first?.name, "Commute")
    }

    // MARK: - Check-ins

    private func makeCheckInStore() throws -> any CheckInStore {
        SwiftDataCheckInStore(modelContainer: try makeContainer())
    }

    private func window(aroundHours hours: Double) -> Range<Date> {
        referenceDate.addingTimeInterval(-hours * 3600)..<referenceDate.addingTimeInterval(hours * 3600)
    }

    func testCheckInRoundTripsThroughTheDurableStore() async throws {
        let store = try makeCheckInStore()
        let checkIn = CheckIn(timestamp: referenceDate,
                              intensity: CheckInIntensity(clamping: 8),
                              tagIDs: [.seeded("fatigue"), .user(UUID())],
                              medications: [MedicationEntry(name: "Ibuprofen",
                                                            dose: "400 mg",
                                                            takenAt: referenceDate)!],
                              note: "Woke up early")

        try await store.save(checkIn)

        let read = try await store.checkIns(in: window(aroundHours: 1))
        XCTAssertEqual(read, [checkIn])
    }

    func testCheckInWithoutTagsMedicationOrNoteRoundTrips() async throws {
        let store = try makeCheckInStore()
        let checkIn = CheckIn(timestamp: referenceDate, intensity: CheckInIntensity(clamping: 1))

        try await store.save(checkIn)

        let read = try await store.checkIns(in: window(aroundHours: 1))
        XCTAssertEqual(read, [checkIn])
        XCTAssertTrue(read.first?.tagIDs.isEmpty ?? false)
        XCTAssertTrue(read.first?.medications.isEmpty ?? false)
        XCTAssertNil(read.first?.note)
    }

    func testMedicationEntriesKeepTheirOrderAndTheirMissingDoses() async throws {
        // Order is what the user typed and is the only thing that distinguishes two entries
        // of the same name, so the store may not sort or de-duplicate them.
        let store = try makeCheckInStore()
        let earlier = referenceDate.addingTimeInterval(-3600)
        let entries = [MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: earlier)!,
                       MedicationEntry(name: "Magnesium", takenAt: referenceDate)!,
                       MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: referenceDate)!]

        try await store.save(CheckIn(timestamp: referenceDate,
                                     intensity: CheckInIntensity(clamping: 6),
                                     medications: entries))

        let read = try await store.checkIns(in: window(aroundHours: 1))
        XCTAssertEqual(read.first?.medications, entries)
        XCTAssertNil(read.first?.medications[1].dose)
        // The time survives the round trip on its own rather than collapsing onto the
        // check-in's timestamp, which is the fallback a row written before the attribute
        // existed gets.
        XCTAssertEqual(read.first?.medications.first?.takenAt, earlier)
    }

    func testSavingTheSameIdentifierTwiceReplacesRatherThanDuplicates() async throws {
        // The property the watch→phone transfer will depend on: a payload delivered twice
        // must not become two training rows.
        let store = try makeCheckInStore()
        let id = UUID()

        try await store.save(CheckIn(id: id, timestamp: referenceDate,
                                     intensity: CheckInIntensity(clamping: 8)))
        try await store.save(CheckIn(id: id, timestamp: referenceDate,
                                     intensity: CheckInIntensity(clamping: 3),
                                     note: "Better after lunch"))

        let read = try await store.checkIns(in: window(aroundHours: 1))
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.intensity.rawValue, 3)
        XCTAssertEqual(read.first?.note, "Better after lunch")
    }

    func testCheckInsComeBackAscendingAndHalfOpen() async throws {
        let store = try makeCheckInStore()
        let hour: TimeInterval = 3600

        for offset in [2 * hour, 0, hour] {
            try await store.save(CheckIn(timestamp: referenceDate.addingTimeInterval(offset),
                                         intensity: CheckInIntensity(clamping: 5)))
        }

        // Upper bound excluded, lower bound included — so adjacent windows cannot count the
        // boundary check-in twice.
        let read = try await store.checkIns(
            in: referenceDate..<referenceDate.addingTimeInterval(2 * hour)
        )

        XCTAssertEqual(read.map(\.timestamp),
                       [referenceDate, referenceDate.addingTimeInterval(hour)])
    }

    func testMostRecentCheckInIsStrictlyBeforeTheGivenInstant() async throws {
        // Strictly before, so a feature computed at a check-in's own timestamp cannot pick
        // up that check-in and leak its own label into the row.
        let store = try makeCheckInStore()
        let earlier = CheckIn(timestamp: referenceDate.addingTimeInterval(-3600),
                              intensity: CheckInIntensity(clamping: 8))
        let atInstant = CheckIn(timestamp: referenceDate, intensity: CheckInIntensity(clamping: 1))

        try await store.save(earlier)
        try await store.save(atInstant)

        let prior = try await store.mostRecentCheckIn(before: referenceDate)
        XCTAssertEqual(prior, earlier)
    }

    func testMostRecentCheckInIsNilWithNothingBehindIt() async throws {
        let store = try makeCheckInStore()
        try await store.save(CheckIn(timestamp: referenceDate,
                                     intensity: CheckInIntensity(clamping: 5)))

        let read = try await store.mostRecentCheckIn(before: referenceDate.addingTimeInterval(-1))
        XCTAssertNil(read)
    }

    func testDeletingACheckInRemovesItAndDeletingNothingIsNotAnError() async throws {
        let store = try makeCheckInStore()
        let checkIn = CheckIn(timestamp: referenceDate, intensity: CheckInIntensity(clamping: 5))

        try await store.save(checkIn)
        try await store.delete(id: checkIn.id)
        try await store.delete(id: UUID())

        let remaining = try await store.checkIns(in: window(aroundHours: 1))
        XCTAssertTrue(remaining.isEmpty)
    }

    func testCheckInsSurviveAFreshStoreOnTheSameContainer() async throws {
        // Stands in for a relaunch. This is the property that was missing until now — the
        // in-memory store lost every check-in with the process.
        let container = try makeContainer()
        let writer: any CheckInStore = SwiftDataCheckInStore(modelContainer: container)
        try await writer.save(CheckIn(timestamp: referenceDate,
                                      intensity: CheckInIntensity(clamping: 10)))

        let reader: any CheckInStore = SwiftDataCheckInStore(modelContainer: container)
        let read = try await reader.checkIns(in: window(aroundHours: 1))

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.intensity.rawValue, 10)
    }

    func testAStoredIntensityOutsideTheScaleIsRejectedRatherThanClamped() {
        // A fabricated label is worse than a missing one: every metric in §7 of the ML spec
        // is computed against this value.
        let row = StoredCheckIn(checkIn: CheckIn(timestamp: referenceDate,
                                                 intensity: CheckInIntensity(clamping: 5)))
        XCTAssertNotNil(row.checkIn)

        row.intensityRawValue = 11
        XCTAssertNil(row.checkIn)

        // The default a row written before this attribute existed comes back with. Those
        // rows carried a 1–5 score running the other way, so reading them as an intensity
        // would invert them — being dropped here is the whole point of the rename.
        row.intensityRawValue = 0
        XCTAssertNil(row.checkIn)
    }

    func testAStoredMedicationWithoutANameIsDroppedAndTheCheckInSurvives() {
        let row = StoredCheckIn(checkIn: CheckIn(timestamp: referenceDate,
                                                 intensity: CheckInIntensity(clamping: 5),
                                                 medications: [MedicationEntry(name: "Magnesium",
                                                                               takenAt: referenceDate)!]))

        row.medications[0].name = "  "

        XCTAssertNotNil(row.checkIn)
        XCTAssertTrue(row.checkIn?.medications.isEmpty ?? false)
    }

    func testTagIdentitiesUseTheSameStorageEncodingAsTheVocabulary() {
        // Two encodings for one identity is how a check-in ends up pointing at a tag that
        // exists but cannot be found.
        let user = UUID()
        let row = StoredCheckIn(checkIn: CheckIn(timestamp: referenceDate,
                                                 intensity: CheckInIntensity(clamping: 5),
                                                 tagIDs: [.seeded("fatigue"), .user(user)]))

        XCTAssertEqual(Set(row.tagIdentityKeys), ["seeded:fatigue", "user:\(user.uuidString)"])
        XCTAssertEqual(row.checkIn?.tagIDs, [.seeded("fatigue"), .user(user)])
    }
}
