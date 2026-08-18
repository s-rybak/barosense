import Foundation
import UserNotifications

/// `UserNotificationScheduling` over the real `UNUserNotificationCenter`.
///
/// The whole adapter: it converts, it does not decide. Whether a notification may be sent at
/// all is `NotificationCoordinator`'s question, and the daily budget is `NotificationBudget`'s
/// — both testable without this file existing.
///
/// Stateless, and it reaches for `UNUserNotificationCenter.current()` inside each call rather
/// than storing it. The centre is a system singleton whose lifetime is not ours to hold, and
/// keeping a stored reference in a `Sendable` type would be a claim about its concurrency
/// guarantees that the SDK does not make.
struct UserNotificationCenterScheduler: UserNotificationScheduling {

    /// What Barosense asks for: a banner and a sound.
    ///
    /// No `.badge`. Nothing in the app reads an app-icon badge — the bell on Now counts unread
    /// rows out of the log instead — and asking for a permission no feature consumes is the
    /// surgical-permissions rule (`CLAUDE.md`, constraint 3) applied outside HealthKit.
    private static let options: UNAuthorizationOptions = [.alert, .sound]

    func permission() async -> NotificationPermission {
        let settings = await UNUserNotificationCenter.current().notificationSettings()

        switch settings.authorizationStatus {
        case .notDetermined:
            return .notRequested
        case .authorized:
            return .granted
        case .denied:
            return .denied
        // `.provisional` delivers quietly to the notification centre with no banner, and
        // `.ephemeral` belongs to App Clips. Neither is something Barosense asks for, and a
        // notification the user does not see is a budget slot spent for nothing — so both are
        // reported as "do not send" rather than as a grant.
        case .provisional, .ephemeral:
            return .denied
        @unknown default:
            return .denied
        }
    }

    func requestPermission() async -> NotificationPermission {
        // The result is deliberately discarded in favour of re-reading the settings, for the
        // reason `SettingsModel.toggleHealthAccess` re-reads HealthKit: the returned `Bool`
        // says what the sheet answered, and what matters is the state that answer left behind.
        // They differ when the sheet was never shown because an answer already existed.
        _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: Self.options)
        return await permission()
    }

    /// Registers one request under `id`.
    ///
    /// A `UNTimeIntervalNotificationTrigger` rather than a calendar one. The log row records an
    /// absolute instant, and reconciliation compares against that instant; an interval trigger
    /// fires at exactly it. A calendar trigger would fire at the same *wall clock* reading,
    /// which after a flight across two time zones is a different moment than the one the log
    /// says — and the log is what the user is shown.
    func schedule(id: UUID, content: NotificationContent, at date: Date) async throws {
        let interval = date.timeIntervalSinceNow
        // A trigger in the past never fires and `UNTimeIntervalNotificationTrigger` traps on a
        // non-positive interval, so this is a guard against a crash as well as against a
        // silently lost notification.
        guard interval > 0 else { throw NotificationSchedulingError.fireDateInThePast }

        let payload = UNMutableNotificationContent()
        payload.title = content.title
        payload.body = content.body
        payload.sound = .default

        let request = UNNotificationRequest(
            identifier: id.uuidString,
            content: payload,
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false)
        )

        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            // Swallowed into a typed case on purpose: the underlying error is a system
            // internal, and the only useful response — leave the row pending and try again on
            // the next pass — is the same whatever it says.
            throw NotificationSchedulingError.systemRefused
        }
    }

    func cancel(ids: [UUID]) async {
        guard !ids.isEmpty else { return }

        UNUserNotificationCenter.current()
            .removePendingNotificationRequests(withIdentifiers: ids.map(\.uuidString))
    }

    func pendingIdentifiers() async -> Set<UUID> {
        let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
        return Set(requests.compactMap { UUID(uuidString: $0.identifier) })
    }
}
