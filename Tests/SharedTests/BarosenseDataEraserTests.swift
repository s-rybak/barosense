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
        let epochs = InMemoryPressureLocationEpochStore()
        let forecasts = InMemoryWeatherForecastStore()
        let notifications = InMemoryNotificationStore()

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
        // A city, an oblast and a country is the nearest thing this app stores to a movement
        // record, so it is squarely inside what "delete my data" promises.
        try await epochs.save(PressureLocationEpoch(
            coordinate: GeoCoordinate(latitude: 50.4, longitude: 30.5),
            place: PlaceName(locality: "Kyiv", administrativeArea: "Kyiv", country: "Ukraine"),
            startedAt: now
        ))
        try await forecasts.save([WeatherForecastPoint(issuedAt: now,
                                                       validAt: now.addingTimeInterval(3600),
                                                       meanSeaLevelPressureHPa: 1013,
                                                       temperatureC: 12)])
        try await notifications.save(NotificationRecord(kind: .checkInReminder,
                                                        language: .english,
                                                        scheduledFor: now,
                                                        state: .scheduled,
                                                        createdAt: now))

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         checkInStore: checkIns,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure,
                                         locationEpochs: epochs,
                                         weatherArchive: forecasts,
                                         notificationLog: notifications)

        try await eraser.eraseEverything()

        let remainingHealth = try await health.samples(of: .restingHeartRate,
                                                       in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        let remainingPressure = try await pressure.samples(
            in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))

        let remainingProfile = try await profiles.profile()
        let remainingTags = try await tags.allTags()
        let remainingCheckIns = try await checkIns.checkIns(in: Date.distantPast..<Date.distantFuture)
        let remainingEpochs = try await epochs.allEpochs()
        let remainingForecasts = try await forecasts.points(
            issuedAtOrBefore: .distantFuture, validIn: Date.distantPast..<Date.distantFuture)
        let remainingNotifications = try await notifications.records(
            in: Date.distantPast..<Date.distantFuture)

        XCTAssertNil(remainingProfile)
        XCTAssertEqual(remainingTags.count, 0)
        XCTAssertEqual(remainingCheckIns.count, 0)
        XCTAssertEqual(remainingHealth.count, 0)
        XCTAssertEqual(remainingPressure.count, 0)
        XCTAssertEqual(remainingEpochs.count, 0)
        XCTAssertEqual(remainingForecasts.count, 0)
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
                                         locationEpochs: InMemoryPressureLocationEpochStore(),
                                         weatherArchive: InMemoryWeatherForecastStore(),
                                         notificationLog: InMemoryNotificationStore())

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
        let epochs = InMemoryPressureLocationEpochStore()
        let forecasts = InMemoryWeatherForecastStore()

        let eraser = BarosenseDataEraser(profileStore: InMemoryUserProfileStore(),
                                         checkInStore: InMemoryCheckInStore(),
                                         tagStore: InMemoryWellbeingTagStore(),
                                         healthLog: InMemoryHealthSampleStore(),
                                         pressureLog: pressure,
                                         locationEpochs: epochs,
                                         weatherArchive: forecasts,
                                         notificationLog: InMemoryNotificationStore())

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
        let epochs = InMemoryPressureLocationEpochStore()
        let forecasts = InMemoryWeatherForecastStore()

        let eraser = BarosenseDataEraser(profileStore: profiles,
                                         checkInStore: checkIns,
                                         tagStore: tags,
                                         healthLog: health,
                                         pressureLog: pressure,
                                         locationEpochs: epochs,
                                         weatherArchive: forecasts,
                                         notificationLog: InMemoryNotificationStore())

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
                                         locationEpochs: FailingPressureLocationEpochStore(),
                                         weatherArchive: FailingWeatherForecastStore(),
                                         notificationLog: FailingNotificationStore())

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
                                         locationEpochs: InMemoryPressureLocationEpochStore(),
                                         weatherArchive: InMemoryWeatherForecastStore(),
                                         notificationLog: InMemoryNotificationStore())

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

private struct FailingPressureLocationEpochStore: PressureLocationEpochStore {
    func save(_ epoch: PressureLocationEpoch) async throws { throw StoreRefused() }
    func currentEpoch() async throws -> PressureLocationEpoch? { throw StoreRefused() }
    func epoch(id: UUID) async throws -> PressureLocationEpoch? { throw StoreRefused() }
    func allEpochs() async throws -> [PressureLocationEpoch] { throw StoreRefused() }
    func deleteAllEpochs() async throws { throw StoreRefused() }
}

private struct FailingWeatherForecastStore: WeatherForecastStore {
    func save(_ points: [WeatherForecastPoint]) async throws { throw StoreRefused() }
    func points(issuedAtOrBefore instant: Date,
                validIn range: Range<Date>) async throws -> [WeatherForecastPoint] {
        throw StoreRefused()
    }
    func mostRecentIssuedAt(atOrBefore instant: Date) async throws -> Date? { throw StoreRefused() }
    func points(issuedAt: Date) async throws -> [WeatherForecastPoint] { throw StoreRefused() }
    func issueTimes(in range: Range<Date>) async throws -> [Date] { throw StoreRefused() }
    func deletePoints(validBefore date: Date) async throws -> Int { throw StoreRefused() }
    func deleteAllForecasts() async throws { throw StoreRefused() }
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

private struct FailingNotificationStore: NotificationStore {
    func save(_ record: NotificationRecord) async throws { throw StoreRefused() }
    func records(in range: Range<Date>) async throws -> [NotificationRecord] { throw StoreRefused() }
    func pendingRecords(notBefore date: Date) async throws -> [NotificationRecord] {
        throw StoreRefused()
    }
    func deleteNotifications(before date: Date) async throws -> Int { throw StoreRefused() }
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
