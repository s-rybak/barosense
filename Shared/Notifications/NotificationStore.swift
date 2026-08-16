import Foundation

/// The log of everything Barosense has decided to tell the user, and what became of it.
///
/// A protocol for the reason every other store here is one: the policy on top of it — the daily
/// cap, the reminder planner, the dispatcher — has to be runnable from a plain unit test with
/// synthetic rows and a pinned clock, with no SwiftData and no `UNUserNotificationCenter`
/// anywhere near it. The durable implementation is injected at the app layer.
///
/// **This is the queue, not a side effect of one.** Nothing is handed to the system that does not
/// have a row here first, and what gets sent next is read back out of these rows rather than
/// recomputed from scratch at the point of sending. That is what makes the cap enforceable
/// across launches: the count of a day's sends survives the process that made them.
///
/// Rows hold no health data — see `NotificationRecord`.
protocol NotificationStore: Sendable {

    /// Inserts a record, or replaces the stored one carrying the same `id`.
    ///
    /// Upsert rather than insert-or-throw so a state change is one call: the dispatcher moves a
    /// row to `.delivered` by saving the value `NotificationRecord.moved(to:at:)` returned.
    func save(_ record: NotificationRecord) async throws

    /// Records whose `scheduledFor` falls in `range`, ascending.
    ///
    /// Half-open, matching `CheckInStore.checkIns(in:)`: the budget asks day by day, and a
    /// boundary record counted in both days would spend two allowances.
    func records(in range: Range<Date>) async throws -> [NotificationRecord]

    /// Every record still waiting to fire as of `date`, ascending — `.scheduled` rows with
    /// `scheduledFor` at or after it.
    ///
    /// The dispatcher's working set: what the system has already been asked for, so a plan that
    /// no longer wants a slot can withdraw it and one that still does can leave it alone.
    func pendingRecords(notBefore date: Date) async throws -> [NotificationRecord]

    /// Drops rows scheduled before `date` and reports how many went.
    ///
    /// The log is unbounded otherwise: one reminder a day for the life of an install is a table
    /// that only grows, and nothing reads a row older than the window the cap is counted over.
    @discardableResult
    func deleteNotifications(before date: Date) async throws -> Int

    /// Removes every row. The counterpart to `CheckInStore.deleteAllCheckIns`, for the same
    /// single caller: "delete my data" (`BarosenseDataEraser`).
    ///
    /// The log carries nothing health-derived, so this is not a privacy obligation — it is a
    /// consistency one. An erase that left the log behind would leave the cap holding rows for a
    /// history that no longer exists, and the user back at onboarding with yesterday's allowance
    /// already spent.
    func deleteAllNotifications() async throws
}

/// Non-persistent `NotificationStore` for unit tests, previews and bring-up. Contents are lost
/// with the process.
///
/// An actor rather than a lock, as `InMemoryCheckInStore` is: the store is reached from the
/// dispatcher and from whatever activation triggered it, and the project builds with complete
/// strict concurrency.
actor InMemoryNotificationStore: NotificationStore {

    private var storage: [UUID: NotificationRecord] = [:]

    init(_ records: [NotificationRecord] = []) {
        for record in records {
            storage[record.id] = record
        }
    }

    func save(_ record: NotificationRecord) {
        storage[record.id] = record
    }

    func records(in range: Range<Date>) -> [NotificationRecord] {
        storage.values
            .filter { range.contains($0.scheduledFor) }
            .sorted { $0.scheduledFor < $1.scheduledFor }
    }

    func pendingRecords(notBefore date: Date) -> [NotificationRecord] {
        storage.values
            .filter { $0.state == .scheduled && $0.scheduledFor >= date }
            .sorted { $0.scheduledFor < $1.scheduledFor }
    }

    @discardableResult
    func deleteNotifications(before date: Date) -> Int {
        let doomed = storage.filter { $0.value.scheduledFor < date }.keys
        for id in doomed {
            storage[id] = nil
        }
        return doomed.count
    }

    func deleteAllNotifications() {
        storage.removeAll()
    }
}
