import XCTest
@testable import Barosense

/// The Apple Weather switch in Settings.
///
/// The one control on that screen with no system authorisation behind it, which is exactly why
/// it needs its own cases: nothing outside the app can change it, so "off" has a single meaning
/// and the setter has nothing to interpret — and a future edit that gave it the Health row's
/// two-facts treatment would be adding a state that cannot occur.
@MainActor
final class SettingsWeatherRowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let calendar = Calendar(identifier: .gregorian)

    /// The shipped default. WeatherKit costs the user a coordinate, not health data, and it is
    /// the difference between a forecast that reaches days ahead and one that reaches hours.
    func testTheSwitchIsOnForAnInstallThatHasNeverTouchedIt() async {
        let preferences = InMemoryWeatherKitPreferenceStore()
        let model = makeModel(weatherPreferences: preferences)

        await model.load()

        XCTAssertTrue(model.isWeatherKitOn)
    }

    func testTurningItOffIsRecordedAndShownImmediately() async {
        let preferences = InMemoryWeatherKitPreferenceStore()
        let model = makeModel(weatherPreferences: preferences)
        await model.load()

        model.setWeatherKitEnabled(false)

        XCTAssertFalse(model.isWeatherKitOn)
        XCTAssertFalse(preferences.isWeatherKitEnabled())
    }

    /// Finding the switch is being told what it does, so using it settles the explanation too.
    /// Without this a user who turned WeatherKit on from Settings would still be blocked by
    /// `WeatherForecastRefresher`'s "not yet explained" gate until the primer had run.
    func testUsingTheSwitchMarksTheTradeAsExplained() async {
        let preferences = InMemoryWeatherKitPreferenceStore(hasOfferedWeatherKit: false)
        let model = makeModel(weatherPreferences: preferences)
        await model.load()

        model.setWeatherKitEnabled(true)

        XCTAssertTrue(preferences.hasOfferedWeatherKit())
    }

    /// The stored preference is what a reload settles on, so the switch cannot drift from the
    /// value the refresher reads.
    func testAReloadShowsWhatWasStored() async {
        let preferences = InMemoryWeatherKitPreferenceStore(isWeatherKitEnabled: false)
        let model = makeModel(weatherPreferences: preferences)

        await model.load()

        XCTAssertFalse(model.isWeatherKitOn)
    }

    // MARK: - Helpers

    private func makeModel(weatherPreferences: any WeatherKitPreferenceStore) -> SettingsModel {
        let dependencies = SettingsDependencies(
            profileStore: InMemoryUserProfileStore(),
            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
            checkInStore: InMemoryCheckInStore(),
            healthLog: InMemoryHealthSampleStore(),
            pressureLog: InMemoryPressureSampleStore(),
            locationEpochs: InMemoryPressureLocationEpochStore(),
            weatherArchive: InMemoryWeatherForecastStore(),
            notificationLog: InMemoryNotificationStore(),
            notifications: NoOpNotificationDeliverer(),
            reminderPreferences: InMemoryReminderPreferenceStore(),
            weatherPreferences: weatherPreferences,
            healthAccess: UnavailableHealthAccessReporter(),
            locationAccess: UnavailableLocationAccessReporter()
        )
        let now = now
        return SettingsModel(dependencies: dependencies,
                             calendar: calendar,
                             now: { now },
                             onDataErased: {})
    }
}
