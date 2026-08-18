import Foundation

/// Storage for the notification switches in Settings.
///
/// Synchronous for the reason `LanguagePreferenceStore` is: these are one-byte values read
/// while a screen is drawing itself, and an `async` read would make the row flicker through
/// its off state on every appearance.
protocol NotificationPreferenceStore: Sendable {

    /// Whether the user has asked for the check-in reminder. `false` until they turn it on.
    ///
    /// Off by default, deliberately. Defaulting to on would mean the first thing a new user
    /// sees is a system permission sheet they did not ask for, answered before they know what
    /// the app does — and a refusal there is close to permanent, because iOS shows that sheet
    /// once. The switch in Settings is what asks.
    func isCheckInReminderEnabled() -> Bool

    func setCheckInReminderEnabled(_ enabled: Bool)
}

/// `UserDefaults`-backed `NotificationPreferenceStore`.
///
/// Holds a single boolean and nothing personal — which is why "delete my data" leaves it
/// alone, the same reasoning `BarosenseDataEraser` records for the language row. The
/// notification *log* is personal and is erased; the switch that produced it is not.
struct UserDefaultsNotificationPreferenceStore: NotificationPreferenceStore {

    private enum Keys {
        static let checkInReminder = "barosense.notifications.checkInReminder"
    }

    /// `nonisolated(unsafe)` for the reason `UserDefaultsLanguagePreferenceStore` uses it:
    /// `UserDefaults` is documented thread-safe but is not annotated `Sendable` in the SDK,
    /// and dropping `Sendable` from the protocol would make every off-main read of this
    /// preference a new problem.
    private nonisolated(unsafe) let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// `bool(forKey:)` reports `false` for a key that was never written, which is exactly the
    /// default this preference wants — so the absence of the key and an explicit "off" are
    /// deliberately not distinguished.
    func isCheckInReminderEnabled() -> Bool {
        defaults.bool(forKey: Keys.checkInReminder)
    }

    func setCheckInReminderEnabled(_ enabled: Bool) {
        defaults.set(enabled, forKey: Keys.checkInReminder)
    }
}

/// In-memory `NotificationPreferenceStore` for tests and previews.
///
/// A final class with a lock rather than an actor, because the protocol is synchronous — the
/// same trade-off the protocol's own documentation explains.
final class InMemoryNotificationPreferenceStore: NotificationPreferenceStore, @unchecked Sendable {

    private let lock = NSLock()
    private var enabled: Bool

    init(isCheckInReminderEnabled: Bool = false) {
        enabled = isCheckInReminderEnabled
    }

    func isCheckInReminderEnabled() -> Bool {
        lock.withLock { enabled }
    }

    func setCheckInReminderEnabled(_ enabled: Bool) {
        lock.withLock { self.enabled = enabled }
    }
}
