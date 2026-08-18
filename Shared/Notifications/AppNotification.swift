import Foundation

/// What a notification Barosense raises is about.
///
/// The kind is what gets stored — never the rendered text. Copy is resolved at the moment a
/// row is handed to the system, and again every time the in-app list draws it, so switching
/// the app language does not leave a history of sentences in the language of the day they
/// were written.
///
/// Raw values are persisted and are part of the storage format. Do not rename them.
enum AppNotificationKind: String, Codable, CaseIterable, Sendable {

    /// The nudge to record a check-in, timed to the hour the user usually logs at — see
    /// `CheckInRhythm`. Deliberately a question about how they feel and nothing more: it
    /// carries no reading, no trend and no statement about their body.
    case checkInReminder
}

/// Why a logged notification never reached the user.
///
/// Recorded rather than dropped. A reminder that was planned and then held back is exactly
/// what the Settings section has to be able to explain — "you have used today's three" is a
/// different fact from "nothing was planned".
///
/// Raw values are persisted. Do not rename them.
enum NotificationSuppressionReason: String, Codable, Sendable {

    /// The day's budget was already spent. See `NotificationBudget`.
    case dailyLimit

    /// The user has not granted notification permission, or has revoked it.
    case permissionDenied

    /// Reminders are switched off in Settings.
    case remindersOff

    /// Its moment passed before the app was next able to hand it to the system. A reminder
    /// delivered hours late is worse than one not delivered — the question "how are you
    /// feeling?" is about a moment, and answering it at midnight files a check-in against
    /// the wrong hour.
    case missedItsMoment
}

/// Where one logged notification got to.
///
/// Five states rather than a `Bool`, because the four ways a planned notification can fail to
/// arrive are the ones a user asks about. Raw values are persisted — see
/// `StoredNotification`, which encodes this as a string plus an optional reason.
enum NotificationDeliveryState: Hashable, Codable, Sendable {

    /// Written to the log, not yet handed to the system. The state every row starts in: the
    /// log is the queue, and dispatch reads from it.
    case pending

    /// Handed to `UNUserNotificationCenter` and waiting for its fire date. Counts against the
    /// daily budget from this moment — the user is going to receive it.
    case scheduled

    /// The system fired it. Established by reconciliation on foreground rather than by a
    /// callback: a delivered notification is one that is no longer pending with the system
    /// and whose moment has passed.
    case delivered

    /// Planned, then held back. Never reached the user and never counts against the budget.
    case suppressed(reason: NotificationSuppressionReason)

    /// Withdrawn before its fire date — reminders switched off, or the plan moved.
    case cancelled
}

extension NotificationDeliveryState {

    /// Whether this row occupies one of the day's three slots.
    ///
    /// Scheduled and delivered only. A suppressed row must not consume the budget that
    /// suppressed it, or one busy day would spend the next one's allowance too.
    var consumesBudget: Bool {
        switch self {
        case .scheduled, .delivered: true
        case .pending, .suppressed, .cancelled: false
        }
    }

    /// Whether the system still holds a request for this row, so cancelling it means telling
    /// `UNUserNotificationCenter` as well as rewriting the log.
    var isHeldBySystem: Bool { self == .scheduled }
}

/// One notification Barosense raised, as the log holds it.
///
/// This is the model the whole feature turns on: nothing is handed to iOS that is not a row
/// here first. Planning writes rows, dispatch reads them back and hands the due ones to the
/// system, and the daily limit is a count over them. One consequence worth stating — the
/// user can be shown exactly what the app sent them and when, because the app cannot send
/// anything it did not write down.
///
/// A value type, like `CheckIn`: the budget rule and the rhythm both have to be reachable
/// from a plain unit test with no store and no device.
///
/// **No health payload.** A row carries a kind, two timestamps and a state. It never carries
/// an intensity, a pressure reading or a note, so the log is safe to show in a list and safe
/// to count — and there is nothing in it that would matter if it were.
struct AppNotification: Identifiable, Hashable, Codable, Sendable {

    /// Also the identifier the system request is registered under, so a row can be cancelled
    /// or reconciled without a second lookup table.
    let id: UUID

    let kind: AppNotificationKind

    /// When the planner wrote the row.
    let createdAt: Date

    /// When it should reach the user. For a check-in reminder this is the next occurrence of
    /// the hour they usually log at.
    let scheduledFor: Date

    var state: NotificationDeliveryState

    /// When the system actually fired it, as far as reconciliation could establish. `nil`
    /// until then, and for every row that never arrives.
    var deliveredAt: Date?

    /// When the user opened the list with this row in it. Drives the bell's unread count and
    /// nothing else.
    var readAt: Date?

    init(id: UUID = UUID(),
         kind: AppNotificationKind,
         createdAt: Date,
         scheduledFor: Date,
         state: NotificationDeliveryState = .pending,
         deliveredAt: Date? = nil,
         readAt: Date? = nil) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.scheduledFor = scheduledFor
        self.state = state
        self.deliveredAt = deliveredAt
        self.readAt = readAt
    }
}

extension AppNotification {

    /// A row the user has received and not yet looked at. What the bell counts.
    var isUnread: Bool { state == .delivered && readAt == nil }
}
