import Foundation

/// Non-persistent `NotificationLogStore` for unit tests, SwiftUI previews, and any build
/// without a durable store. Contents are lost with the process.
///
/// An actor rather than a lock, for the reason `InMemoryCheckInStore` is one: the log is
/// reached from the planner and from the UI, and the project builds with complete strict
/// concurrency.
actor InMemoryNotificationLogStore: NotificationLogStore {

    private var storage: [UUID: AppNotification] = [:]

    init(_ notifications: [AppNotification] = []) {
        for notification in notifications {
            storage[notification.id] = notification
        }
    }

    func save(_ notification: AppNotification) {
        storage[notification.id] = notification
    }

    func pendingNotifications(scheduledBefore date: Date) -> [AppNotification] {
        storage.values
            .filter { $0.state == .pending && $0.scheduledFor < date }
            .sorted { $0.scheduledFor < $1.scheduledFor }
    }

    func notifications(in range: Range<Date>) -> [AppNotification] {
        storage.values
            .filter { range.contains($0.scheduledFor) }
            .sorted { $0.scheduledFor < $1.scheduledFor }
    }

    func deleteAllNotifications() {
        storage.removeAll()
    }
}
