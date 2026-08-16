import Foundation

/// Storage for the reminder switch in Settings.
///
/// Synchronous, like `LanguagePreferenceStore` and unlike every data store here: it is one
/// boolean, read at the top of each reconcile pass to decide whether the pass has anything to
/// schedule. An `async` read would put that decision behind a suspension point the pass has no
/// other reason to have.
protocol ReminderPreferenceStore: Sendable {

    /// Whether the user wants the check-in reminder.
    func isCheckInReminderEnabled() -> Bool

    /// Records the choice.
    func setCheckInReminderEnabled(_ isEnabled: Bool)

    /// Whether the reminder has already been explained once, in its own words, before iOS was
    /// asked anything.
    ///
    /// Separate from the preference because it answers a different question. The preference is
    /// what the user wants; this is whether they have been given the chance to say. It is what
    /// stops the explanation reappearing on every launch, and what makes "not now" a durable
    /// answer rather than a deferral.
    func hasOfferedCheckInReminder() -> Bool

    /// Records that the explanation has been shown, whichever way it was answered.
    func setHasOfferedCheckInReminder(_ hasOffered: Bool)
}

/// `UserDefaults`-backed `ReminderPreferenceStore`.
///
/// **Absence of the key means on.** iOS already gates the reminder behind a permission prompt
/// the user has to answer; shipping the preference off as well would make them say yes twice to
/// hear from the app once. The switch exists to turn the reminder *off*, and an install that has
/// never touched it has not done that.
///
/// The preference holds no personal data, which is why "delete my data" leaves it alone — the
/// same reason `BarosenseDataEraser` does not reach for the language preference. An erase that
/// silently re-enabled notifications would be changing a setting the user made, not deleting
/// data they stored.
struct UserDefaultsReminderPreferenceStore: ReminderPreferenceStore {

    private enum Keys {
        static let checkInReminder = "barosense.settings.checkInReminder"
        static let hasOfferedCheckInReminder = "barosense.settings.checkInReminderOffered"
    }

    /// `nonisolated(unsafe)` for the reason `UserDefaultsLanguagePreferenceStore` gives:
    /// `UserDefaults` is documented thread-safe and simply is not annotated `Sendable` in the
    /// SDK. Dropping `Sendable` from the protocol instead would make every future off-main read
    /// of this preference a new problem.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func isCheckInReminderEnabled() -> Bool {
        // `object(forKey:)` rather than `bool(forKey:)`. The latter reports `false` for a key
        // that was never written, which is the exact opposite of this preference's default and
        // would leave a fresh install with reminders silently off.
        guard let stored = defaults.object(forKey: Keys.checkInReminder) as? Bool else {
            return true
        }

        return stored
    }

    func setCheckInReminderEnabled(_ isEnabled: Bool) {
        defaults.set(isEnabled, forKey: Keys.checkInReminder)
    }

    /// `bool(forKey:)` is right here and wrong above: an install that has never written this key
    /// has genuinely never been offered the reminder, so `false` is the truth rather than a
    /// missing value standing in for one.
    func hasOfferedCheckInReminder() -> Bool {
        defaults.bool(forKey: Keys.hasOfferedCheckInReminder)
    }

    func setHasOfferedCheckInReminder(_ hasOffered: Bool) {
        defaults.set(hasOffered, forKey: Keys.hasOfferedCheckInReminder)
    }
}

/// Non-persistent `ReminderPreferenceStore` for previews and unit tests.
///
/// A lock rather than an actor, because the protocol is synchronous — see the note on it. The
/// locked values are two `Bool`s, so there is nothing here for the unchecked conformance to hide.
final class InMemoryReminderPreferenceStore: ReminderPreferenceStore, @unchecked Sendable {

    private let lock = NSLock()
    private var isEnabled: Bool
    private var hasOffered: Bool

    /// `hasOfferedCheckInReminder` defaults to `true`, which is the opposite of the durable
    /// store's default and deliberate: a preview or a test that has not said otherwise is not a
    /// fresh install, and defaulting the other way would put the primer on screen in every canvas
    /// refresh and in every test that only wanted a preference.
    init(isCheckInReminderEnabled: Bool = true, hasOfferedCheckInReminder: Bool = true) {
        isEnabled = isCheckInReminderEnabled
        hasOffered = hasOfferedCheckInReminder
    }

    func isCheckInReminderEnabled() -> Bool {
        lock.withLock { isEnabled }
    }

    func setCheckInReminderEnabled(_ isEnabled: Bool) {
        lock.withLock { self.isEnabled = isEnabled }
    }

    func hasOfferedCheckInReminder() -> Bool {
        lock.withLock { hasOffered }
    }

    func setHasOfferedCheckInReminder(_ hasOffered: Bool) {
        lock.withLock { self.hasOffered = hasOffered }
    }
}
