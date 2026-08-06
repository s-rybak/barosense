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
}
