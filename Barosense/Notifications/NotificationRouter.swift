import Foundation
import UserNotifications

/// Where a tapped notification should land the user.
///
/// A route rather than a kind, because the two are not the same question: a kind is what the app
/// had to say, a route is the screen that answers it. They coincide today because there is one
/// kind, and separating them is what stops the navigation gaining a `switch` over notification
/// kinds in a second place later.
enum NotificationRoute: Equatable, Sendable {

    /// The check-in sheet, open and ready to be filled in.
    case checkIn

    /// The route for the kind named in a notification's payload.
    ///
    /// `nil` when the payload names a kind this build does not know — a request scheduled by a
    /// newer build and tapped after a downgrade. Answered by doing nothing rather than by
    /// guessing at a screen: the app opens where the user left it, which is the one outcome that
    /// is never wrong.
    init?(kindRawValue: String) {
        guard let kind = NotificationKind(rawValue: kindRawValue) else { return nil }

        switch kind {
        case .checkInReminder: self = .checkIn
        }
    }
}

/// The one route a tapped notification is waiting for the UI to take.
///
/// A tap arrives from the system, not from the view tree, and may arrive before there is a view
/// tree at all — a cold launch from the lock screen runs the delegate while the window is still
/// being built. Holding the route here lets the tap be recorded whenever it lands and acted on
/// when `RootView` is ready for it, instead of being dropped for arriving early.
@MainActor
@Observable
final class NotificationRouter {

    /// Set by a tap, cleared by whoever acts on it. Optional rather than a stream: two taps
    /// before the UI catches up should open one screen, and the second is the one that counts.
    private(set) var pending: NotificationRoute?

    func request(_ route: NotificationRoute) {
        pending = route
    }

    /// Called once the UI has actually moved, so a later scene activation does not open the
    /// sheet a second time over a check-in the user has already written.
    func clear() {
        pending = nil
    }
}

/// Answers `UNUserNotificationCenter` on the app's behalf.
///
/// Registered in `BarosenseApp.init`, which is the last moment that counts: iOS delivers a tap
/// that launched the app as soon as launching finishes, and a delegate set after that never hears
/// about it. The one visible symptom would be that tapping a reminder works — except on the taps
/// that opened the app, which are most of them.
final class NotificationResponder: NSObject, UNUserNotificationCenterDelegate {

    private let router: NotificationRouter

    init(router: NotificationRouter) {
        self.router = router
        super.init()
    }

    /// Shown while the app is in the foreground, without the sound.
    ///
    /// Not silence, for a reason that is not about taste: a notification the app declines to
    /// present is never added to Notification Centre, so it never appears in
    /// `deliveredNotifications()` — and `NotificationDispatcher.markDelivered` reads exactly that
    /// list. Suppressing it would leave the row `.scheduled` for ever, holding one of the day's
    /// three sends against a notification that had already happened.
    ///
    /// The sound is dropped because the user is looking at the screen it would be interrupting.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list])
    }

    /// A tap on the notification itself. Dismissals and any future action buttons are not routes.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        // Answered first and unconditionally. The system holds the app awake until this is
        // called, and the routing below is a main-actor hop that must not sit inside that window.
        completionHandler()

        guard response.actionIdentifier == UNNotificationDefaultActionIdentifier,
              let raw = response.notification.request.content
                  .userInfo[NotificationUserInfo.kind] as? String,
              let route = NotificationRoute(kindRawValue: raw)
        else {
            return
        }

        Task { @MainActor [router] in
            router.request(route)
        }
    }
}
