import XCTest
@testable import Barosense

/// "Delete my data" has to reach every store, and has to be honest about the ones it could
/// not empty — there is no transaction across three SwiftData containers.
final class BarosenseDataEraserTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testEveryStoreIsEmptied() async throws {
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena",
                                                            onboardingCompletedAt: now))
        let tags = InMemoryWellbeingTagStore(WellbeingTag.seeds)
        let checkIns = InMemoryCheckInStore()
        let health = InMemoryHealthSampleStore()
        let pressure = InMemoryPressureSampleStore()
<<<<<<< HEAD
        let notifications = InMemoryNotificationStore()
=======
        let notifications = InMemoryNotificationLogStore()
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

        // Note and medication entry on purpose: this is the free text the erase promise is
        // mostly about, and it is the row that used to survive it.
        try await checkIns.save(CheckIn(timestamp: now,
                                        intensity: CheckInIntensity(clamping: 7),
                                        tagIDs: [.seeded("fatigue")],
                                        medications: [MedicationEntry(name: "Ibuprofen",
                                                                      dose: "400 mg",
                                                                      takenAt: now)!],
                                        note: "Woke up early"))
        try await health.save([HealthSample(id: UUID(),
                                            start: now,
                                            end: now,
                                            value: .restingHeartRateBPM(60))])
        try await pressure.save([PressureSample(id: UUID(),
                                                timestamp: now,
                                                pressure: Pressure(hectopascals: 1013))])
<<<<<<< HEAD
        try await notifications.save(NotificationRecord(kind: .checkInReminder,
                                                        language: .english,
                                                        scheduledFor: now,
                                                        state: .scheduled,
                                                        createdAt: now))
=======
        // A delivered reminder: the record that the app has been nudging this person, which is
        // theirs and goes with everything else.
        try await notifications.save(AppNotification(kind: .checkInReminder,
                                                     createdAt: now,
                                                     scheduledFor: now,
                                                     state: .delivered,
                                                     deliveredAt: now))
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         checkInStore: checkIns,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure,
                                         notificationLog: notifications)

        try await eraser.eraseEverything()

        let remainingHealth = try await health.samples(of: .restingHeartRate,
                                                       in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        let remainingPressure = try await pressure.samples(
            in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))

        let remainingProfile = try await profiles.profile()
        let remainingTags = try await tags.allTags()
        let remainingCheckIns = try await checkIns.checkIns(in: Date.distantPast..<Date.distantFuture)
<<<<<<< HEAD
        let remainingNotifications = try await notifications.records(
=======
        let remainingNotifications = try await notifications.notifications(
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
            in: Date.distantPast..<Date.distantFuture)

        XCTAssertNil(remainingProfile)
        XCTAssertEqual(remainingTags.count, 0)
        XCTAssertEqual(remainingCheckIns.count, 0)
        XCTAssertEqual(remainingHealth.count, 0)
        XCTAssertEqual(remainingPressure.count, 0)
        XCTAssertEqual(remainingNotifications.count, 0)
    }

    /// The vocabulary is hard-deleted, so the check-ins pointing at it have to be gone
    /// first. Only the order protects a crash between the two steps — a refusal does not,
    /// because the walk deliberately continues — which is why this is pinned by a test and
    /// not left to the comment in `eraseEverything`.
    func testCheckInsAreErasedBeforeTheVocabularyTheyPointAt() async throws {
        let order = EraseOrder()

        let eraser = BarosenseDataEraser(profileStore: InMemoryUserProfileStore(),
                                         checkInStore: RecordingCheckInStore(order: order),
                                         tagStore: RecordingWellbeingTagStore(order: order),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: InMemoryPressureSampleStore(),
<<<<<<< HEAD
                                         notificationLog: InMemoryNotificationStore())
=======
                                         notificationLog: InMemoryNotificationLogStore())
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

        try await eraser.eraseEverything()

        let walked = await order.walked
        XCTAssertEqual(walked, [.checkIns, .tagVocabulary])
    }

    /// A reading taken in the same second as the erase — a foreground activation records one
    /// on the way into Settings — must still go. `deleteSamples(before: .now)` would leave it.
    func testASampleTimestampedNowIsStillRemoved() async throws {
        let pressure = InMemoryPressureSampleStore()
        let sample = PressureSample(id: UUID(), timestamp: .now, pressure: Pressure(hectopascals: 1013))
        try await pressure.save([sample])

        let eraser = BarosenseDataEraser(profileStore: InMemoryUserProfileStore(),
                                         checkInStore: InMemoryCheckInStore(),
                                         tagStore: InMemoryWellbeingTagStore(),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: pressure,
<<<<<<< HEAD
                                         notificationLog: InMemoryNotificationStore())
=======
                                         notificationLog: InMemoryNotificationLogStore())
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

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
        let checkIns = InMemoryCheckInStore([CheckIn(timestamp: now,
                                                     intensity: CheckInIntensity(clamping: 4))])
        let pressure = FailingPressureSampleStore()
        let health = InMemoryHealthSampleStore()

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         checkInStore: checkIns,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure,
<<<<<<< HEAD
                                         notificationLog: InMemoryNotificationStore())
=======
                                         notificationLog: InMemoryNotificationLogStore())
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

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
        let remainingCheckIns = try await checkIns.checkIns(in: Date.distantPast..<Date.distantFuture)

        XCTAssertNil(remainingProfile)
        XCTAssertEqual(remainingTags.count, 0)
        XCTAssertEqual(remainingCheckIns.count, 0)
    }

    func testEveryStoreRefusingNamesAllOfThem() async throws {
        let eraser = BarosenseDataEraser(profileStore: FailingUserProfileStore(),
                                         checkInStore: FailingCheckInStore(),
                                         tagStore: FailingWellbeingTagStore(),
                                         healthLog: FailingHealthSampleStore(),
                                         pressureLog: FailingPressureSampleStore(),
<<<<<<< HEAD
                                         notificationLog: FailingNotificationStore())
=======
                                         notificationLog: FailingNotificationLogStore())
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

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
                                         checkInStore: InMemoryCheckInStore(),
                                         tagStore: InMemoryWellbeingTagStore(),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: InMemoryPressureSampleStore(),
<<<<<<< HEAD
                                         notificationLog: InMemoryNotificationStore())
=======
                                         notificationLog: InMemoryNotificationLogStore())
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)

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

private struct FailingCheckInStore: CheckInStore {
    func save(_ checkIn: CheckIn) async throws { throw StoreRefused() }
    func checkIns(in range: Range<Date>) async throws -> [CheckIn] { throw StoreRefused() }
    func mostRecentCheckIn(before date: Date) async throws -> CheckIn? { throw StoreRefused() }
    func delete(id: UUID) async throws { throw StoreRefused() }
    func deleteAllCheckIns() async throws { throw StoreRefused() }
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

<<<<<<< HEAD
private struct FailingNotificationStore: NotificationStore {
    func save(_ record: NotificationRecord) async throws { throw StoreRefused() }
    func records(in range: Range<Date>) async throws -> [NotificationRecord] { throw StoreRefused() }
    func pendingRecords(notBefore date: Date) async throws -> [NotificationRecord] {
        throw StoreRefused()
    }
    func deleteNotifications(before date: Date) async throws -> Int { throw StoreRefused() }
=======
private struct FailingNotificationLogStore: NotificationLogStore {
    func save(_ notification: AppNotification) async throws { throw StoreRefused() }
    func pendingNotifications(scheduledBefore date: Date) async throws -> [AppNotification] {
        throw StoreRefused()
    }
    func notifications(in range: Range<Date>) async throws -> [AppNotification] { throw StoreRefused() }
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
    func deleteAllNotifications() async throws { throw StoreRefused() }
}

/// The order the eraser walked its stores in. An actor because the doubles writing to it
/// are `Sendable` values handed to a non-isolated eraser.
private actor EraseOrder {
    private(set) var walked: [ErasableStore] = []

    func record(_ store: ErasableStore) {
        walked.append(store)
    }
}

private struct RecordingCheckInStore: CheckInStore {
    let order: EraseOrder

    func save(_ checkIn: CheckIn) async throws {}
    func checkIns(in range: Range<Date>) async throws -> [CheckIn] { [] }
    func mostRecentCheckIn(before date: Date) async throws -> CheckIn? { nil }
    func delete(id: UUID) async throws {}
    func deleteAllCheckIns() async { await order.record(.checkIns) }
}

private struct RecordingWellbeingTagStore: WellbeingTagStore {
    let order: EraseOrder

    func activeTags() async throws -> [WellbeingTag] { [] }
    func allTags() async throws -> [WellbeingTag] { [] }
    func save(_ tag: WellbeingTag) async throws {}
    func archive(id: WellbeingTag.ID) async throws {}
    func deleteAllTags() async { await order.record(.tagVocabulary) }
    func insertIfAbsent(_ tags: [WellbeingTag]) async throws {}
}
