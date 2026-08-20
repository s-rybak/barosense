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

    /// Whether the one-off historical request has ever **succeeded**.
    ///
    /// Recorded rather than inferred from the archive, and that is the whole point. The obvious
    /// inference — "the seven-day window already holds rows" — reads as true the day after a
    /// bootstrap that failed, because the window moves and yesterday's ordinary forecast rows
    /// slide into it; the install then never bootstraps again. The next obvious one — a row
    /// with `issuedAt == validAt` — is not a marker either: a forecast's own zero-lead point is
    /// knowable at the hour it describes, exactly like an observation.
    func hasBootstrappedHistory() -> Bool

    func setHasBootstrappedHistory(_ hasBootstrapped: Bool)

    /// When a request went out today and came back with nothing.
    ///
    /// The day's budget is counted off **stored issues** (`WeatherRequestBudget`), which is
    /// what makes it survive a relaunch — and which is also why a request that fails leaves no
    /// trace of itself. Without this ledger a service that is refusing the app (no
    /// `DEVELOPMENT_TEAM`, an expired token, a device offline for a day) turns every single
    /// scene activation into another network call, because the archive still reads as empty.
    ///
    /// Only failures are recorded. A request that lands writes rows, and those rows are the
    /// record; writing both would count one slot twice.
    func failedRequests(in day: Range<Date>) -> [Date]

    func recordFailedRequest(at instant: Date)
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
///
/// The failed-request ledger rides here rather than in a store of its own, and it is the one
/// thing in this type that is not a preference. It is kept out of the erase for the same
/// reason: at most four timestamps of "the app asked the weather service something", self-pruned
/// after 48 hours, holding nothing about the user — and an erase that reset it would be handing
/// back the day's spent quota rather than deleting data.
struct UserDefaultsWeatherKitPreferenceStore: WeatherKitPreferenceStore {

    private enum Keys {
        static let weatherKit = "barosense.settings.weatherKit"
        static let hasOfferedWeatherKit = "barosense.settings.weatherKitOffered"
        static let hasBootstrappedHistory = "barosense.settings.weatherKitHistoryBootstrapped"
        static let failedRequests = "barosense.settings.weatherKitFailedRequests"
    }

    /// How long a failure is remembered.
    ///
    /// **48 hours.** The budget only ever asks about the current local day, so anything older
    /// than one day plus a DST hour can never be read again; 48 h is that with room to spare
    /// and still bounds the array at a handful of entries.
    private static let failureRetentionSeconds: TimeInterval = 48 * 3600

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

    func hasBootstrappedHistory() -> Bool {
        defaults.bool(forKey: Keys.hasBootstrappedHistory)
    }

    func setHasBootstrappedHistory(_ hasBootstrapped: Bool) {
        defaults.set(hasBootstrapped, forKey: Keys.hasBootstrappedHistory)
    }

    /// Stored as an array of `timeIntervalSince1970`, which `UserDefaults` holds natively —
    /// no archiver, and readable in a plist dump when something needs explaining.
    func failedRequests(in day: Range<Date>) -> [Date] {
        storedFailures().filter { day.contains($0) }
    }

    /// Pruned on write rather than on read, so the array cannot grow across a stretch of days
    /// spent offline and so a read stays a plain filter.
    ///
    /// The horizon is measured from the **newest** entry, not from the one being written. The
    /// two are the same whenever the clock moves forward, which is the ordinary case — but a
    /// clock that jumps backwards, by a manual change or a time-zone move, would otherwise give
    /// every subsequent write an older cutoff than the last and prune nothing at all. The bound
    /// on this array has to hold whichever way the clock went.
    func recordFailedRequest(at instant: Date) {
        let all = storedFailures() + [instant]
        let newest = all.max() ?? instant
        let kept = all
            .filter { $0 > newest.addingTimeInterval(-Self.failureRetentionSeconds) }
            .map(\.timeIntervalSince1970)

        defaults.set(kept, forKey: Keys.failedRequests)
    }

    private func storedFailures() -> [Date] {
        let stored = defaults.array(forKey: Keys.failedRequests) as? [Double] ?? []
        return stored.map(Date.init(timeIntervalSince1970:))
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
    private var hasBootstrapped: Bool
    private var failures: [Date] = []

    init(isWeatherKitEnabled: Bool = true,
         hasOfferedWeatherKit: Bool = true,
         hasBootstrappedHistory: Bool = false) {
        self.isEnabled = isWeatherKitEnabled
        self.hasOffered = hasOfferedWeatherKit
        self.hasBootstrapped = hasBootstrappedHistory
    }

    func isWeatherKitEnabled() -> Bool { lock.withLock { isEnabled } }

    func setWeatherKitEnabled(_ isEnabled: Bool) {
        lock.withLock { self.isEnabled = isEnabled }
    }

    func hasOfferedWeatherKit() -> Bool { lock.withLock { hasOffered } }

    func setHasOfferedWeatherKit(_ hasOffered: Bool) {
        lock.withLock { self.hasOffered = hasOffered }
    }

    func hasBootstrappedHistory() -> Bool { lock.withLock { hasBootstrapped } }

    func setHasBootstrappedHistory(_ hasBootstrapped: Bool) {
        lock.withLock { self.hasBootstrapped = hasBootstrapped }
    }

    func failedRequests(in day: Range<Date>) -> [Date] {
        lock.withLock { failures.filter { day.contains($0) } }
    }

    func recordFailedRequest(at instant: Date) {
        lock.withLock { failures.append(instant) }
    }
}
