import Foundation
import SwiftData

/// How `NotificationDeliveryState` is written down.
///
/// A separate flat enum rather than the domain type encoded whole, because the domain type
/// carries an associated value and this one has to survive in a `#Predicate`: dispatch asks
/// the store for pending rows, and a predicate can compare a stored `String` but cannot take
/// a case apart. The reason travels in its own attribute alongside.
///
/// Raw values are the storage format. Do not rename them.
enum StoredNotificationState: String, Codable, Sendable {
    case pending
    case scheduled
    case delivered
    case suppressed
    case cancelled
}

/// Durable row for `AppNotification`.
///
/// On the main `BarosenseModelContainer` schema rather than in a container of its own: the
/// planner reads check-ins and writes notifications in one pass, and splitting the two across
/// containers would buy nothing but a boundary to cross.
@Model
final class StoredNotification {

    /// Indexed on `scheduledFor` because every read is a window over it — dispatch asks for
    /// what is due, the budget asks for one day, the list asks for the last fortnight.
    #Index<StoredNotification>([\.scheduledFor])

    /// The notification's own identifier, carried across from the domain value, and also the
    /// identifier its `UNNotificationRequest` is registered under. Unique, so a row that is
    /// re-saved as it moves through its states replaces itself instead of forking.
    @Attribute(.unique) var id: UUID = UUID()

    /// `AppNotificationKind.rawValue`.
    var kindRawValue: String = ""

    var createdAt: Date = Date.distantPast

    var scheduledFor: Date = Date.distantPast

    /// `StoredNotificationState.rawValue`. Flat rather than the domain enum, so the pending
    /// query is a predicate on the database instead of a fetch of everything followed by a
    /// filter in memory.
    var stateRawValue: String = StoredNotificationState.pending.rawValue

    /// `NotificationSuppressionReason.rawValue`, and `nil` for every state that is not
    /// `suppressed`. The pair is written together and read back together — see `notification`.
    var suppressionReasonRawValue: String?

    var deliveredAt: Date?

    var readAt: Date?

    init(notification: AppNotification) {
        self.id = notification.id
        apply(notification)
    }

    func apply(_ notification: AppNotification) {
        kindRawValue = notification.kind.rawValue
        createdAt = notification.createdAt
        scheduledFor = notification.scheduledFor
        deliveredAt = notification.deliveredAt
        readAt = notification.readAt

        switch notification.state {
        case .pending:
            stateRawValue = StoredNotificationState.pending.rawValue
            suppressionReasonRawValue = nil
        case .scheduled:
            stateRawValue = StoredNotificationState.scheduled.rawValue
            suppressionReasonRawValue = nil
        case .delivered:
            stateRawValue = StoredNotificationState.delivered.rawValue
            suppressionReasonRawValue = nil
        case .cancelled:
            stateRawValue = StoredNotificationState.cancelled.rawValue
            suppressionReasonRawValue = nil
        case .suppressed(let reason):
            stateRawValue = StoredNotificationState.suppressed.rawValue
            suppressionReasonRawValue = reason.rawValue
        }
    }

    /// `nil` when the row was written by a build that knew a kind, a state or a suppression
    /// reason this one does not.
    ///
    /// Skipped on read rather than coerced into a neighbouring case, the same rule
    /// `StoredCheckIn.checkIn` follows. A row whose state cannot be read is a row nothing can
    /// safely act on: guessing `pending` would re-send a notification the user already had,
    /// and guessing `delivered` would claim one they never saw.
    var notification: AppNotification? {
        guard let kind = AppNotificationKind(rawValue: kindRawValue),
              let storedState = StoredNotificationState(rawValue: stateRawValue),
              let state = Self.state(storedState, reasonRawValue: suppressionReasonRawValue)
        else {
            return nil
        }

        return AppNotification(id: id,
                               kind: kind,
                               createdAt: createdAt,
                               scheduledFor: scheduledFor,
                               state: state,
                               deliveredAt: deliveredAt,
                               readAt: readAt)
    }

    /// Rebuilds the domain state from the pair of attributes it was split into. `nil` when a
    /// suppressed row's reason will not parse — a suppression with no readable reason cannot
    /// be explained to the user, which is the only thing the row is for.
    private static func state(_ stored: StoredNotificationState,
                              reasonRawValue: String?) -> NotificationDeliveryState? {
        switch stored {
        case .pending: .pending
        case .scheduled: .scheduled
        case .delivered: .delivered
        case .cancelled: .cancelled
        case .suppressed:
            NotificationSuppressionReason(rawValue: reasonRawValue ?? "").map {
                .suppressed(reason: $0)
            }
        }
    }
}

/// On-disk `NotificationLogStore`.
///
/// A `@ModelActor` like the other stores: the `ModelContext` stays on its executor and only
/// `AppNotification` values come out, so no `@Model` instance crosses an isolation boundary.
@ModelActor
actor SwiftDataNotificationLogStore: NotificationLogStore {

    func save(_ notification: AppNotification) throws {
        let id = notification.id
        let descriptor = FetchDescriptor<StoredNotification>(predicate: #Predicate { $0.id == id })

        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(notification)
        } else {
            modelContext.insert(StoredNotification(notification: notification))
        }
        try modelContext.save()
    }

    func pendingNotifications(scheduledBefore date: Date) throws -> [AppNotification] {
        let pending = StoredNotificationState.pending.rawValue

        let descriptor = FetchDescriptor<StoredNotification>(
            predicate: #Predicate {
                $0.stateRawValue == pending && $0.scheduledFor < date
            },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )

        return try modelContext.fetch(descriptor).compactMap(\.notification)
    }

    func notifications(in range: Range<Date>) throws -> [AppNotification] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<StoredNotification>(
            predicate: #Predicate { $0.scheduledFor >= lower && $0.scheduledFor < upper },
            sortBy: [SortDescriptor(\.scheduledFor, order: .forward)]
        )

        return try modelContext.fetch(descriptor).compactMap(\.notification)
    }

    /// A batch delete rather than a fetch-then-delete loop, for the reason
    /// `SwiftDataCheckInStore.deleteAllCheckIns` uses one: this table grows for the life of
    /// the install, and materialising every row just to remove it is memory spent at the
    /// moment the user has asked for the data to be gone.
    func deleteAllNotifications() throws {
        try modelContext.delete(model: StoredNotification.self)
        try modelContext.save()
    }
}
