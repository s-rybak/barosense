import Foundation

/// Storage for every notification Barosense raises.
///
/// The log is not a record kept alongside the feature — it **is** the queue. Nothing is handed
/// to `UNUserNotificationCenter` that was not written here first, and dispatch reads its work
/// back out of this store rather than out of whatever the planner happened to be holding. Two
/// things follow from that, and both are the reason for the design:
///
/// - The daily limit is a count over rows (`NotificationBudget`), so it survives a relaunch,
///   a crash between planning and sending, and the system forgetting what it delivered.
/// - The user can be shown exactly what the app sent them, because the app cannot send
///   anything it did not write down.
///
/// A protocol, like every other store here, so the planner and its tests depend on this and
/// not on SwiftData. The durable implementation is injected at the app layer.
///
/// Rows carry no health values — see `AppNotification` — but they do describe when a person
/// is at their phone, which is behavioural. They stay on-device under the same rule as
/// everything else (`CLAUDE.md`, constraint 2).
protocol NotificationLogStore: Sendable {

    /// Inserts a notification, or replaces the stored row carrying the same `id`.
    ///
    /// Replace-on-same-id is what lets a row move through its states — pending → scheduled →
    /// delivered — without the caller tracking whether it has been written yet.
    func save(_ notification: AppNotification) async throws

    /// Rows still waiting to be handed to the system, with `scheduledFor` before `date`,
    /// ascending by `scheduledFor`.
    ///
    /// The read dispatch runs on. Ascending because the budget is spent in the order the
    /// notifications would arrive: when four are due and three may go, it must be the last
    /// one that is held back, not an arbitrary one.
    func pendingNotifications(scheduledBefore date: Date) async throws -> [AppNotification]

    /// Rows whose `scheduledFor` falls in `range`, ascending.
    ///
    /// Half-open, like `CheckInStore.checkIns(in:)`: adjacent windows can be asked for without
    /// counting a boundary row twice. Backs both the day's budget and the in-app list.
    func notifications(in range: Range<Date>) async throws -> [AppNotification]

    /// Removes every stored notification.
    ///
    /// The counterpart to `CheckInStore.deleteAllCheckIns`, and it exists for the same single
    /// caller: "delete my data" (`BarosenseDataEraser`).
    func deleteAllNotifications() async throws
}
