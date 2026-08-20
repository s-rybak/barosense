import XCTest
@testable import Barosense

/// The location row in Settings: what it shows, and where a tap leads.
///
/// Split out of `SettingsModelTests` rather than added to it. That suite is already at the
/// relaxed 400-line ceiling for test types, and these cases exercise a different pair of
/// dependencies — nothing here reads HealthKit or the notification log.
@MainActor
final class SettingsLocationRowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    // MARK: - Location row

    /// Acceptance criterion 8, on the row model rather than on a screenshot — this is the
    /// state most likely to regress the next time the settings screen is edited. Reduced
    /// accuracy is the accuracy the app asks for; drawing it as a fault would push the user
    /// to hand over precision nothing here reads.
    func testTheLocationRowIsOnAtReducedAccuracy() async {
        let model = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .reduced))
        )

        await model.load()

        XCTAssertTrue(model.location.isConnected)
        XCTAssertTrue(model.location.isReducedAccuracy)
        XCTAssertTrue(model.location.isInteractive)
    }

    /// Full accuracy must not read any differently. If these two ever diverge, one of them is
    /// a nag about a permission the feature does not need.
    func testFullAccuracyReadsExactlyLikeReduced() async {
        let reduced = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .reduced))
        )
        let full = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .full))
        )

        await reduced.load()
        await full.load()

        XCTAssertEqual(reduced.location.isConnected, full.location.isConnected)
        XCTAssertEqual(reduced.location.needsSystemSettings, full.location.needsSystemSettings)
    }

    /// Never asked: the row leads to the app's own explanation, and nothing on this screen
    /// reaches iOS until that screen's own button is tapped.
    func testAnUnaskedLocationRowExplainsBeforeItAsks() async {
        let reporter = StubLocationAccessReporter(state: .notRequested)
        let model = makeModel(locationAccess: reporter)

        await model.load()
        let outcome = await model.toggleLocationAccess()

        XCTAssertEqual(outcome, .needsExplanation)
        XCTAssertEqual(reporter.requestCount, 0)
    }

    /// Acceptance criterion 9. iOS shows the prompt once ever, so a refused row that tried to
    /// raise it again would be a switch that visibly does nothing.
    func testARefusedLocationRowRoutesToSystemSettings() async {
        let reporter = StubLocationAccessReporter(state: .denied)
        let model = makeModel(locationAccess: reporter)

        await model.load()
        let outcome = await model.toggleLocationAccess()

        XCTAssertEqual(outcome, .needsSystemSettings)
        XCTAssertFalse(model.location.isConnected)
        XCTAssertEqual(reporter.requestCount, 0)
    }

    /// A granted row goes to Settings too — that is where a grant is downgraded or withdrawn,
    /// and the row's promise is that a tap always leads somewhere it can be changed.
    func testAGrantedLocationRowAlsoLeadsSomewhereItCanBeChanged() async {
        let model = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .reduced))
        )

        await model.load()

        let outcome = await model.toggleLocationAccess()
        XCTAssertEqual(outcome, .needsSystemSettings)
    }

    /// Services off device-wide: inert, and no route offered. Barosense's own Settings page
    /// cannot fix a device-wide switch, so sending the user there would be a dead end.
    func testLocationServicesOffLeavesTheRowInert() async {
        let model = makeModel(locationAccess: StubLocationAccessReporter(state: .unavailable))

        await model.load()

        let outcome = await model.toggleLocationAccess()

        XCTAssertFalse(model.location.isInteractive)
        XCTAssertEqual(outcome, .unavailable)
    }

    /// Accepting the explanation is the one path from this screen to a system prompt.
    func testAcceptingTheExplanationIsTheOnlyPathToThePrompt() async {
        let reporter = StubLocationAccessReporter(state: .notRequested)
        let model = makeModel(locationAccess: reporter)
        await model.load()

        model.isExplainingLocation = true
        reporter.state = .granted(accuracy: .reduced)
        await model.requestLocationAccess()

        XCTAssertEqual(reporter.requestCount, 1)
        XCTAssertFalse(model.isExplainingLocation)
        XCTAssertTrue(model.location.isConnected)
    }

    /// "Not now" writes nothing and asks nothing. Unlike the reminder there is no preference
    /// to record: iOS still holds the prompt for the next tap.
    func testDecliningTheExplanationAsksForNothing() async {
        let reporter = StubLocationAccessReporter(state: .notRequested)
        let model = makeModel(locationAccess: reporter)
        await model.load()

        model.isExplainingLocation = true
        model.declineLocationAccess()

        XCTAssertFalse(model.isExplainingLocation)
        XCTAssertEqual(reporter.requestCount, 0)
        XCTAssertTrue(model.location.canExplainBeforeAsking)
    }

    /// The place comes off the epoch table, not off a fresh reverse geocode — a settings
    /// screen that geocoded on every appearance would be throttled into naming nothing.
    func testTheRowNamesThePlaceFromTheEpochTable() async {
        let epochs = InMemoryPressureLocationEpochStore([
            PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                                  place: PlaceName(locality: "Kyiv",
                                                   administrativeArea: "Kyiv",
                                                   country: "Ukraine"),
                                  startedAt: now)
        ])
        let model = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
            locationEpochs: epochs
        )

        await model.load()

        // "Kyiv, Kyiv, Ukraine" is what Apple's geocoder returns for a city that is its own
        // administrative area, and printing it back is how the app looks broken.
        XCTAssertEqual(model.locationPlaceDescription, "Kyiv, Ukraine")
    }

    func testAnEpochWithNoNameLeavesThePlaceUnstated() async {
        let epochs = InMemoryPressureLocationEpochStore([
            PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                                  startedAt: now)
        ])
        let model = makeModel(
            locationAccess: StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
            locationEpochs: epochs
        )

        await model.load()

        XCTAssertNil(model.locationPlaceDescription)
        XCTAssertTrue(model.location.isConnected)
    }

    // MARK: - Helpers

    private func makeModel(locationAccess: any LocationAccessReporting,
                           locationEpochs: any PressureLocationEpochStore
                               = InMemoryPressureLocationEpochStore()) -> SettingsModel {
        let dependencies = SettingsDependencies(
            profileStore: InMemoryUserProfileStore(),
            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
            checkInStore: InMemoryCheckInStore(),
            healthLog: InMemoryHealthSampleStore(),
            pressureLog: InMemoryPressureSampleStore(),
            locationEpochs: locationEpochs,
            weatherArchive: InMemoryWeatherForecastStore(),
            notificationLog: InMemoryNotificationStore(),
            notifications: NoOpNotificationDeliverer(),
            reminderPreferences: InMemoryReminderPreferenceStore(),
            weatherPreferences: InMemoryWeatherKitPreferenceStore(),
            healthAccess: UnavailableHealthAccessReporter(),
            locationAccess: locationAccess
        )
        let now = now
        return SettingsModel(dependencies: dependencies,
                             calendar: calendar,
                             now: { now },
                             onDataErased: {})
    }
}
