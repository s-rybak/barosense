import Foundation

/// Storage for the WeatherKit switch in Settings.
///
/// Synchronous, like `ReminderPreferenceStore` and for its reason: this is one boolean, read at
/// the top of every refresh pass to decide whether the pass has anything to do, and an `async`
/// read would put that decision behind a suspension point the pass has no other reason to have.
protocol WeatherKitPreferenceStore: Sendable {

    /// Whether the user wants WeatherKit used at all.
    func isWeatherKitEnabled() -> Bool

    func setWeatherKitEnabled(_ isEnabled: Bool)

    /// Whether the trade has been explained once, in the app's own words.
    ///
    /// A different question from the preference: that is what the user wants, this is whether
    /// they have been given the chance to say. It is what stops the explanation reappearing
    /// every launch.
    func hasOfferedWeatherKit() -> Bool

    func setHasOfferedWeatherKit(_ hasOffered: Bool)
}

/// `UserDefaults`-backed `WeatherKitPreferenceStore`.
///
/// **Absence of the key means on**, decided in `.claude/context/pressure-forecast-spec.md`
/// §7.2 question 1. WeatherKit costs the user nothing they have not already agreed to — a
/// coordinate leaves the device, no health data does — and it is the difference between a
/// forecast that reaches days ahead and one that reaches hours. The switch exists to turn it
/// *off*; an install that has never touched it has not done that.
///
/// The preference holds nothing personal, which is why `BarosenseDataEraser` leaves it alone —
/// the same reasoning as the reminder switch and the language row. An erase that silently
/// re-enabled a network feature would be changing a setting rather than deleting data.
struct UserDefaultsWeatherKitPreferenceStore: WeatherKitPreferenceStore {

    private enum Keys {
        static let weatherKit = "barosense.settings.weatherKit"
        static let hasOfferedWeatherKit = "barosense.settings.weatherKitOffered"
    }

    /// `nonisolated(unsafe)` for the reason the reminder store gives: `UserDefaults` is
    /// documented thread-safe and simply is not annotated `Sendable` in the SDK.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `object(forKey:)` rather than `bool(forKey:)`: the latter reports `false` for a key
    /// never written, which is the opposite of this preference's default and would leave every
    /// fresh install on the short-range path.
    func isWeatherKitEnabled() -> Bool {
        guard let stored = defaults.object(forKey: Keys.weatherKit) as? Bool else { return true }

        return stored
    }

    func setWeatherKitEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.weatherKit)
    }

    /// `bool(forKey:)` is right here and wrong above: an install that never wrote this key has
    /// genuinely never been shown the explanation.
    func hasOfferedWeatherKit() -> Bool {
        defaults.bool(forKey: Keys.hasOfferedWeatherKit)
    }

    func setHasOfferedWeatherKit(_ hasOffered: Bool) {
        defaults.set(hasOffered, forKey: Keys.hasOfferedWeatherKit)
    }
}

/// Non-persistent `WeatherKitPreferenceStore` for previews and unit tests.
///
/// `hasOfferedWeatherKit` defaults to `true`, the opposite of the durable store, for the reason
/// `InMemoryReminderPreferenceStore` does it: a preview is not a fresh install, and defaulting
/// the other way would put the explanation on screen in every canvas refresh.
final class InMemoryWeatherKitPreferenceStore: WeatherKitPreferenceStore, @unchecked Sendable {

    private let lock = NSLock()
    private var isEnabled: Bool
    private var hasOffered: Bool

    init(isWeatherKitEnabled: Bool = true, hasOfferedWeatherKit: Bool = true) {
        self.isEnabled = isWeatherKitEnabled
        self.hasOffered = hasOfferedWeatherKit
    }

    func isWeatherKitEnabled() -> Bool { lock.withLock { isEnabled } }

    func setWeatherKitEnabled(_ isEnabled: Bool) {
        lock.withLock { self.isEnabled = isEnabled }
    }

    func hasOfferedWeatherKit() -> Bool { lock.withLock { hasOffered } }

    func setHasOfferedWeatherKit(_ hasOffered: Bool) {
        lock.withLock { self.hasOffered = hasOffered }
    }
}
