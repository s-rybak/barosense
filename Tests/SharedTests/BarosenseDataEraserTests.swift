import XCTest
@testable import Barosense

/// "Delete my data" has to reach every store, and has to be honest about the ones it could
/// not empty — there is no transaction across three SwiftData containers.
final class BarosenseDataEraserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEverySoreIsEmptied() async throws {
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena",
                                                            onboardingCompletedAt: now))
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)
        let health = InMemoryHealthSampleStore()
        let pressure = InMemoryPressureSampleStore()

        try await health.save([HealthSample(id: UUID(),
                                            start: now,
                                            end: now,
                                            value: .restingHeartRateBPM(60))])
        try await pressure.save([PressureSample(id: UUID(),
                                                timestamp: now,
                                                pressure: Pressure(hectopascals: 1013))])

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure)

        try await eraser.eraseEverything()

        let remainingHealth = try await health.samples(of: .restingHeartRate,
                                                       in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        let remainingPressure = try await pressure.samples(
            in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))

        let remainingProfile = try await profiles.profile()
        let remainingTags = try await tags.allTags()

        XCTAssertNil(remainingProfile)
        XCTAssertEqual(remainingTags.count, 0)
        XCTAssertEqual(remainingHealth.count, 0)
        XCTAssertEqual(remainingPressure.count, 0)
    }

    /// A reading taken in the same second as the erase — a foreground activation records one
    /// on the way into Settings — must still go. `deleteSamples(before: .now)` would leave it.
    func testASampleTimestampedNowIsStillRemoved() async throws {
        let pressure = InMemoryPressureSampleStore()
        let sample = PressureSample(id: UUID(), timestamp: .now, pressure: Pressure(hectopascals: 1013))
        try await pressure.save([sample])

        let eraser = BarosenseDataEraser(profileStore: InMemoryUserProfileStore(),
                                         tagStore: InMemoryWellbeingTagStore(),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: pressure)

        try await eraser.eraseEverything()

        let remaining = try await pressure.samples(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(remaining.count, 0)
    }

    /// One store refusing must not stop the others. Anything else and the user is told the
    /// erase failed while most of their history is already gone — or, worse, is told it
    /// succeeded while it is not.
    func testARefusalDoesNotStopTheRemainingStores() async throws {
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena"))
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)
        let pressure = FailingPressureSampleStore()
        let health = InMemoryHealthSampleStore()

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure)

        do {
            try await eraser.eraseEverything()
            XCTFail("expected the refusal to surface")
        } catch DataEraseFailure.storesRefused(let stores) {
            XCTAssertEqual(stores, [.pressureLog])
        }

        // The pressure log is the *first* store the eraser walks, so this is the assertion
        // that proves it kept going rather than returning at the first throw.
        let remainingProfile = try await profiles.profile()
        let remainingTags = try await tags.allTags()

        XCTAssertNil(remainingProfile)
        XCTAssertEqual(remainingTags.count, 0)
    }

    func testEverySoreRefusingNamesAllOfThem() async throws {
        let eraser = BarosenseDataEraser(profileStore: FailingUserProfileStore(),
                                         tagStore: FailingWellbeingTagStore(),
                                         healthLog: FailingHealthSampleStore(),
                                         pressureLog: FailingPressureSampleStore())

        do {
            try await eraser.eraseEverything()
            XCTFail("expected the refusal to surface")
        } catch DataEraseFailure.storesRefused(let stores) {
            XCTAssertEqual(Set(stores), Set(ErasableStore.allCases))
        }
    }

    /// Erasing an already-empty device is a normal thing to do twice.
    func testErasingNothingSucceeds() async throws {
        let eraser = BarosenseDataEraser(profileStore: InMemoryUserProfileStore(),
                                         tagStore: InMemoryWellbeingTagStore(),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: InMemoryPressureSampleStore())

        try await eraser.eraseEverything()
        try await eraser.eraseEverything()
    }
}

// MARK: - Doubles

private struct StoreRefused: Error {}

private struct FailingUserProfileStore: UserProfileStore {
    func profile() async throws -> UserProfile? { throw StoreRefused() }
    func save(_ profile: UserProfile) async throws { throw StoreRefused() }
    func deleteProfile() async throws { throw StoreRefused() }
}

private struct FailingWellbeingTagStore: WellbeingTagStore {
    func activeTags() async throws -> [WellbeingTag] { throw StoreRefused() }
    func allTags() async throws -> [WellbeingTag] { throw StoreRefused() }
    func save(_ tag: WellbeingTag) async throws { throw StoreRefused() }
    func archive(id: WellbeingTag.ID) async throws { throw StoreRefused() }
    func deleteAllTags() async throws { throw StoreRefused() }
    func insertIfAbsent(_ tags: [WellbeingTag]) async throws { throw StoreRefused() }
}

private struct FailingHealthSampleStore: HealthSampleStore {
    func save(_ samples: [HealthSample]) async throws { throw StoreRefused() }
    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        throw StoreRefused()
    }
    func deleteSamples(before date: Date) async throws -> Int { throw StoreRefused() }
}

private struct FailingPressureSampleStore: PressureSampleStore {
    func save(_ samples: [PressureSample]) async throws { throw StoreRefused() }
    func samples(in range: Range<Date>) async throws -> [PressureSample] { throw StoreRefused() }
    func deleteSamples(before date: Date) async throws -> Int { throw StoreRefused() }
}
