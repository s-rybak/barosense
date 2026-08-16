import Foundation
import UserNotifications

/// Keys Barosense puts in a notification's `userInfo`.
///
/// Everything here is read back when the user taps the notification, possibly on a cold launch
/// where the app has not opened its store yet. That is the whole reason anything is carried in
/// the payload rather than looked up: the tap has to be answered in the moment, and a launch that
/// had to open SwiftData before it could decide which screen to show would show the wrong one
/// first and then move.
///
/// Nothing health-derived goes in here, for the reason nothing health-derived goes in the body —
/// see `NotificationRecord`.
enum NotificationUserInfo {

    /// `NotificationKind.rawValue`. Persisted inside a scheduled request, so it is subject to the
    /// same rule as the stored raw values: renaming a case orphans every request already handed
    /// to the system, which then taps through to nothing.
    static let kind = "barosense.notification.kind"
}

/// One notification, as the system needs it.
struct NotificationDeliveryRequest: Hashable, Sendable {

    /// The stored record's `id`. The same value identifies the row and the system's request, so
    /// a row can be withdrawn without a second table mapping one to the other.
    let id: UUID

    /// What this notification is for. Carried into the payload so a tap knows where to go — see
    /// `NotificationUserInfo`.
    let kind: NotificationKind

    let title: String
    let body: String
    let fireAt: Date
}

/// Why a notification could not be handed over.
enum NotificationDeliveryError: Error, Sendable {

    /// The user has not granted permission, or has revoked it. Not an error to report on
    /// screen — it is a state, and the answer to it is to stop scheduling.
    case notAuthorized

    /// `UNUserNotificationCenter` refused the request.
    case systemRefused(underlying: Error)
}

/// The boundary between the app's notification policy and the system's notification centre.
///
/// A protocol so everything above it — the log, the daily cap, the planner, the dispatcher — is
/// runnable from a plain unit test with a pinned clock and no `UNUserNotificationCenter`
/// anywhere near it. Same rule as every store in `Shared/Persistence/`.
///
/// It is deliberately thin: schedule, withdraw, and report what the system currently holds.
/// Every decision about *whether* to send lives above it.
protocol NotificationDelivering: Sendable {

    /// Whether the app may post notifications right now, without prompting.
    func isAuthorized() async -> Bool

    /// Prompts if the user has not been asked yet, and reports the answer.
    ///
    /// Asking a second time is a no-op the system answers from its own record, so this is safe
    /// to call on every activation — but callers should not, because the answer is stable and
    /// the call is a cross-process round trip.
    func requestAuthorization() async -> Bool

    /// Hands one notification to the system, to fire at `request.fireAt`.
    func schedule(_ request: NotificationDeliveryRequest) async throws

    /// Withdraws requests that have not fired yet. Withdrawing something absent is not an error.
    func cancel(ids: [UUID]) async

    /// Identifiers the system is still holding, unfired.
    ///
    /// What makes an orphan detectable: a request the system holds with no row behind it — left
    /// by an erase, or by an install whose store was reset — is cancelled rather than left to
    /// fire out of nowhere.
    func pendingIdentifiers() async -> Set<UUID>

    /// Identifiers the system has already shown, and still has in Notification Centre.
    ///
    /// The only evidence a notification actually reached the user. A scheduled row whose time
    /// has passed is not evidence of anything — see `NotificationDeliveryState.delivered`.
    func deliveredIdentifiers() async -> Set<UUID>
}

/// `NotificationDelivering` on `UNUserNotificationCenter`.
///
/// ## Battery
///
/// Nothing here schedules work of Barosense's own: no timer, no background task, no observer.
/// A `UNCalendarNotificationTrigger` is held and fired by the system's own scheduler, which is
/// already running for every app on the device, and the app is not woken when it fires. The cost
/// of this whole subsystem is the handful of cross-process calls made on a scene activation the
/// user initiated — bounded by `CheckInReminderPlanner.horizonDays` requests, and normally zero,
/// because a plan that has not changed schedules nothing. `CLAUDE.md` constraint 4 is satisfied
/// by there being no new wake source rather than by a cheap one.
struct UserNotificationCenterDeliverer: NotificationDelivering {

    /// Injected so a test can pass a centre of its own. Defaults to the app's.
    private let center: @Sendable () -> UNUserNotificationCenter

    init(center: @escaping @Sendable () -> UNUserNotificationCenter = { .current() }) {
        self.center = center
    }

    func isAuthorized() async -> Bool {
        let settings = await center().notificationSettings()

        switch settings.authorizationStatus {
        case .authorized, .provisional, .ephemeral: return true
        // `.notDetermined` is not authorisation. It is "nobody has asked", and answering it
        // here would put a system prompt in front of the user as a side effect of a status
        // check — see `requestAuthorization`, which is the deliberate call.
        case .denied, .notDetermined: return false
        @unknown default: return false
        }
    }

    /// `.alert` and `.sound` only.
    ///
    /// No `.badge`: a number on the app icon is a count of something unread, and nothing here is
    /// a message. No `.criticalAlert` and no `.provisional` — the first needs an entitlement
    /// Apple grants for genuine emergencies and this is not one, the second delivers quietly to
    /// Notification Centre, which for a reminder placed at a moment the user chose is the one
    /// place it will not be seen.
    func requestAuthorization() async -> Bool {
        do {
            return try await center().requestAuthorization(options: [.alert, .sound])
        } catch {
            return false
        }
    }

    func schedule(_ request: NotificationDeliveryRequest) async throws {
        guard await isAuthorized() else { throw NotificationDeliveryError.notAuthorized }

        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.sound = .default
        // What the tap needs to know, and nothing else. See `NotificationUserInfo`.
        content.userInfo = [NotificationUserInfo.kind: request.kind.rawValue]
        // Groups every Barosense notification under one heading in Notification Centre, and is
        // what a future "clear the reminders" would filter on.
        content.threadIdentifier = "com.barosense.notifications"

        // Calendar components rather than a time interval. The two disagree whenever the device
        // changes time zone between scheduling and firing, and this is placed at a wall-clock
        // time the user recognises — 20:00 where they are, not 20:00 where they were.
        let parts = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute], from: request.fireAt
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: parts, repeats: false)

        do {
            try await center().add(UNNotificationRequest(identifier: request.id.uuidString,
                                                         content: content,
                                                         trigger: trigger))
        } catch {
            throw NotificationDeliveryError.systemRefused(underlying: error)
        }
    }

    func cancel(ids: [UUID]) async {
        center().removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    }

    func pendingIdentifiers() async -> Set<UUID> {
        let requests = await center().pendingNotificationRequests()

        return Set(requests.compactMap { UUID(uuidString: $0.identifier) })
    }

    func deliveredIdentifiers() async -> Set<UUID> {
        let delivered = await center().deliveredNotifications()

        return Set(delivered.compactMap { UUID(uuidString: $0.request.identifier) })
    }
}

/// A deliverer that accepts everything and does nothing, for previews and for the bring-up path
/// where notifications are switched off.
///
/// Reports `false` for authorisation so nothing above it believes a notification is reaching
/// anyone: a no-op that claimed to be authorised would let the dispatcher write `.scheduled`
/// rows for notifications that will never arrive, and those rows spend the day's allowance.
struct NoOpNotificationDeliverer: NotificationDelivering {
    func isAuthorized() async -> Bool { false }
    func requestAuthorization() async -> Bool { false }
    func schedule(_ request: NotificationDeliveryRequest) async throws {
        throw NotificationDeliveryError.notAuthorized
    }
    func cancel(ids: [UUID]) async {}
    func pendingIdentifiers() async -> Set<UUID> { [] }
    func deliveredIdentifiers() async -> Set<UUID> { [] }
}
