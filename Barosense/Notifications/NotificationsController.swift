import SwiftUI
import UIKit

/// The app layer's view onto `NotificationCoordinator`.
///
/// Holds the last snapshot on the main actor so the bell, the Settings section and the list
/// all draw from one value — three screens reading the log separately is three chances for
/// them to disagree about how many notifications went out today.
///
/// Owns no rules. When a reminder is due, what the daily limit is and what gets held back are
/// all decisions in `Shared/`, reachable from a test with no device.
@MainActor
@Observable
final class NotificationsController {

    private(set) var snapshot: NotificationsSnapshot = .empty

    private let coordinator: NotificationCoordinator

    init(coordinator: NotificationCoordinator) {
        self.coordinator = coordinator
    }

    var unreadCount: Int { snapshot.unreadCount }

    // MARK: - Passes

    /// A full pass — reconcile, plan, dispatch.
    ///
    /// Call sites are deliberately few: foreground activation, and immediately after a
    /// check-in is written (which may make today's reminder unnecessary). Both are moments
    /// the app is already awake and already doing work, so this adds no wake of its own.
    func refresh() async {
        snapshot = await coordinator.refresh()
    }

    /// Re-reads the log without touching the plan. What a screen appearing calls.
    func reload() async {
        snapshot = await coordinator.snapshot()
    }

    /// Clears the bell. Called when the list is opened, not when it is dismissed — the rows
    /// have been seen by then.
    func markHistoryRead() async {
        snapshot = await coordinator.markHistoryRead()
    }

    // MARK: - The switch

    /// What tapping the reminder switch should do next.
    ///
    /// Mirrors `SettingsModel.HealthToggleOutcome`, and for the same reason: the switch is not
    /// a preference the app fully owns. Once iOS has been answered, only iOS Settings can
    /// change the answer, and a switch that silently does nothing is worse than no switch.
    enum ReminderToggleOutcome: Equatable {
        case enabled
        case disabled
        /// Permission was refused or has been revoked. The app has nothing left to ask.
        case needsSystemSettings
    }

    /// Turns the reminder off and withdraws everything outstanding, without going through the
    /// switch.
    ///
    /// Its caller is "delete my data" (`SettingsModel.eraseEverything`): an already-scheduled
    /// reminder is held by iOS, not by a store, so the erase has to stand it down explicitly
    /// or it arrives after everything else is gone.
    func disableCheckInReminder() async {
        snapshot = await coordinator.setCheckInReminderEnabled(false)
    }

    @discardableResult
    func toggleCheckInReminder() async -> ReminderToggleOutcome {
        let wantsOn = !snapshot.isCheckInReminderActive
        snapshot = await coordinator.setCheckInReminderEnabled(wantsOn)

        guard wantsOn else { return .disabled }
        return snapshot.isCheckInReminderActive ? .enabled : .needsSystemSettings
    }

    /// Opens Barosense's own page in iOS Settings, where notification permission lives.
    ///
    /// There is no URL for the Notifications pane specifically; the app's page is as close as
    /// iOS allows, and it is where the switch the user needs actually is.
    static func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

extension NotificationsController {

    /// A controller over in-memory stores, for previews. Nothing here reaches the system
    /// notification centre, so a preview cannot put a permission sheet on screen or schedule
    /// anything on the device it runs on.
    static var preview: NotificationsController {
        NotificationsController(coordinator: NotificationCoordinator(
            log: InMemoryNotificationLogStore(),
            checkIns: InMemoryCheckInStore(),
            system: UnavailableUserNotificationScheduler(),
            content: LocalizedNotificationContent(),
            preferences: InMemoryNotificationPreferenceStore()
        ))
    }
}

/// A scheduler that refuses everything, for previews and for any build where reaching the
/// system centre would be wrong.
///
/// Reports `.denied` rather than `.notRequested`: `.notRequested` is the one state that makes
/// the app ask, and a preview must never be able to raise a permission sheet.
struct UnavailableUserNotificationScheduler: UserNotificationScheduling {
    func permission() async -> NotificationPermission { .denied }
    func requestPermission() async -> NotificationPermission { .denied }
    func schedule(id: UUID, content: NotificationContent, at date: Date) async throws {
        throw NotificationSchedulingError.systemRefused
    }
    func cancel(ids: [UUID]) async {}
    func pendingIdentifiers() async -> Set<UUID> { [] }
}
