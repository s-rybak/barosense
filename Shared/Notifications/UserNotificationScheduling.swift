import Foundation

/// The words one notification carries, already resolved into the language the user reads.
///
/// Plain `String`s rather than localisation keys, because the resolution happens on the way
/// past: the app layer knows which language is selected (`LanguageController`), and `Shared/`
/// is UI-free and has no business owning copy.
struct NotificationContent: Hashable, Sendable {
    let title: String
    let body: String
}

/// Supplies the copy for a notification kind.
///
/// A protocol so the planner can be exercised with fixed strings, and so the one
/// implementation that reads the app bundle stays in the app target where the strings
/// catalogue lives.
protocol NotificationContentProviding: Sendable {
    func content(for kind: AppNotificationKind) -> NotificationContent
}

/// Whether Barosense may put anything on the user's lock screen.
///
/// Three states, not two, for the reason the Apple Health row has more than two: "never
/// asked" is actionable from inside the app and "refused" is not — iOS shows the permission
/// sheet once, and after that only Settings can change the answer.
enum NotificationPermission: Hashable, Sendable {
    case notRequested
    case granted
    /// Refused, or revoked later in iOS Settings. Also what a provisional or otherwise
    /// restricted authorisation is reported as: anything short of a plain grant is treated as
    /// "do not send", because a notification the user cannot see is a budget slot spent for
    /// nothing.
    case denied
}

/// What the system notification centre refused to do.
enum NotificationSchedulingError: Error, Sendable {
    /// `UNUserNotificationCenter` rejected the request. Carries no user data — the underlying
    /// error is a system internal with nothing actionable in it.
    case systemRefused
    /// The fire date has already passed. A trigger in the past never fires, so handing one
    /// over would silently lose the notification.
    case fireDateInThePast
}

/// The system notification centre, as the planner needs it.
///
/// A protocol so `NotificationCoordinator` — which owns the interesting rules, the daily
/// budget and the rhythm — is testable with no `UNUserNotificationCenter`, no permission
/// sheet and no device. The same rule every sensor and store in this project follows.
protocol UserNotificationScheduling: Sendable {

    /// What the user has already answered. Never asks anything.
    func permission() async -> NotificationPermission

    /// Puts the system permission sheet up if it has not been shown, and reports where that
    /// left things. Calling it again after an answer is harmless and shows nothing.
    func requestPermission() async -> NotificationPermission

    /// Registers one notification to fire at `date`, under `id`.
    ///
    /// The identifier is the log row's own `id` (`AppNotification.id`), so what the system
    /// holds and what the log says can be reconciled without a second lookup table.
    func schedule(id: UUID, content: NotificationContent, at date: Date) async throws

    /// Withdraws requests the system has not yet fired. Identifiers it does not know are
    /// ignored, which is what makes this safe to call from a reconciliation pass.
    func cancel(ids: [UUID]) async

    /// Identifiers the system is still holding, so a log row can be told apart from one the
    /// system has already fired. The read reconciliation is built on.
    func pendingIdentifiers() async -> Set<UUID>
}
