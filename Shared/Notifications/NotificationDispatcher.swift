import Foundation

/// One notification somebody wants sent, before anything has decided whether it may be.
struct PlannedNotification: Hashable, Sendable {
    let kind: NotificationKind
    let fireAt: Date
}

/// Brings the log, the daily cap and the system's notification centre into agreement.
///
/// This is the only path from "the app would like to say something" to "the system has been
/// asked to say it". Nothing else may call `NotificationDelivering.schedule`, because everything
/// that makes the cap work happens here: the row is written first, the count is taken off the
/// stored rows rather than off this process's memory, and what the system is holding is
/// reconciled against what the store says it should be.
///
/// ## What one pass does
///
/// 1. **Prunes** rows older than the retention window. The log is otherwise unbounded.
/// 2. **Stops early if the app is not authorised**, withdrawing anything still outstanding so
///    the log does not go on claiming notifications are on their way.
/// 3. **Marks delivered** every scheduled row the system says it has shown.
/// 4. **Cancels orphans** — requests the system holds that no row accounts for. An erase leaves
///    exactly these, and without this step it would leave a week of reminders firing out of an
///    app that has forgotten it asked for them.
/// 5. **Cancels rows the plan no longer wants**, including any left in a language the app is no
///    longer in. This is what makes a check-in silence that evening's reminder — the planner
///    drops the slot, so the row for it is withdrawn — and what makes a language switch in
///    Settings reach a week of already-rendered requests the system will not re-resolve.
/// 6. **Schedules what is left**, in ascending order, until the day's allowance runs out — and
///    logs a `.suppressed` row for whatever the cap refused, so the refusal is auditable rather
///    than invisible.
///
/// Idempotent: running it twice with the same plan and clock schedules nothing the second time.
/// That matters because it runs on every scene activation.
struct NotificationDispatcher: Sendable {

    private let store: any NotificationStore
    private let deliverer: any NotificationDelivering
    private let budget: NotificationBudget
    private let calendar: Calendar
    private let retention: TimeInterval

    /// How far back the log is kept.
    ///
    /// 30 days. Long enough to answer "what has this app been sending me" over a period the user
    /// can remember, short enough that the table stays in the low hundreds of rows for the life
    /// of the install. Nothing reads a row older than the day it was scheduled in, so the only
    /// cost of the window being short is the audit trail.
    static let defaultRetention: TimeInterval = 30 * 24 * 3600

    init(store: any NotificationStore,
         deliverer: any NotificationDelivering,
         calendar: Calendar,
         budget: NotificationBudget = NotificationBudget(),
         retention: TimeInterval = NotificationDispatcher.defaultRetention) {
        self.store = store
        self.deliverer = deliverer
        self.budget = budget
        self.calendar = calendar
        self.retention = retention
    }

    /// What one pass did. Returned rather than only logged so the behaviour is assertable in a
    /// test without reading the store back.
    struct Outcome: Hashable, Sendable {
        var scheduled = 0
        var suppressed = 0
        var cancelled = 0
        var markedDelivered = 0
        var pruned = 0
        var orphansCancelled = 0

        /// `true` when the pass changed nothing, which is the expected result of every
        /// activation after the first of the day.
        var isQuiet: Bool {
            scheduled == 0 && suppressed == 0 && cancelled == 0
                && markedDelivered == 0 && pruned == 0 && orphansCancelled == 0
        }
    }

    @discardableResult
    func reconcile(plan: [PlannedNotification],
                   now: Date,
                   language: AppLanguage) async throws -> Outcome {
        var outcome = Outcome()

        outcome.pruned = try await store.deleteNotifications(before: now - retention)

        var ledger = try await store.records(in: (now - retention)..<Date.distantFuture)

        guard await deliverer.isAuthorized() else {
            outcome.cancelled = try await withdrawEverythingOutstanding(in: ledger, now: now)
            return outcome
        }

        outcome.markedDelivered = try await markDelivered(&ledger, now: now)
        outcome.orphansCancelled = await cancelOrphans(knownTo: ledger)
        outcome.cancelled = try await cancelUnwanted(&ledger,
                                                     plan: plan,
                                                     now: now,
                                                     language: language)

        let sent = try await schedule(plan, into: &ledger, now: now, language: language)
        outcome.scheduled = sent.scheduled
        outcome.suppressed = sent.suppressed

        if !outcome.isQuiet {
            BarosenseLog.notifications.info(
                """
                reconcile: scheduled=\(outcome.scheduled, privacy: .public) \
                suppressed=\(outcome.suppressed, privacy: .public) \
                cancelled=\(outcome.cancelled, privacy: .public) \
                delivered=\(outcome.markedDelivered, privacy: .public) \
                orphans=\(outcome.orphansCancelled, privacy: .public) \
                pruned=\(outcome.pruned, privacy: .public)
                """
            )
        }

        return outcome
    }

    // MARK: - Steps

    /// Permission is gone, or was never given. Every outstanding row is withdrawn.
    ///
    /// The system has already dropped the requests themselves — that is what revoking permission
    /// does — so the point of this is the log: rows left in `.scheduled` would go on spending the
    /// day's allowance for notifications that cannot arrive, and would then suppress the first
    /// real one after permission came back.
    private func withdrawEverythingOutstanding(in ledger: [NotificationRecord],
                                               now: Date) async throws -> Int {
        let outstanding = ledger.filter { $0.state == .scheduled }
        guard !outstanding.isEmpty else { return 0 }

        await deliverer.cancel(ids: outstanding.map(\.id))
        for record in outstanding {
            guard let moved = record.moved(to: .cancelled, at: now) else { continue }
            try await store.save(moved)
        }

        return outstanding.count
    }

    private func markDelivered(_ ledger: inout [NotificationRecord], now: Date) async throws -> Int {
        let delivered = await deliverer.deliveredIdentifiers()
        guard !delivered.isEmpty else { return 0 }

        var count = 0
        for record in ledger where record.state == .scheduled && delivered.contains(record.id) {
            guard let moved = record.moved(to: .delivered, at: now) else { continue }
            try await store.save(moved)
            replace(moved, in: &ledger)
            count += 1
        }

        return count
    }

    /// Requests the system holds that this app has no row for.
    ///
    /// Not a theoretical case: "delete my data" empties the log and cannot reach into the
    /// notification centre — see `BarosenseDataEraser` — so the first activation afterwards is
    /// where a week of already-scheduled reminders is withdrawn.
    private func cancelOrphans(knownTo ledger: [NotificationRecord]) async -> Int {
        let known = Set(ledger.filter { $0.state == .scheduled }.map(\.id))
        let orphans = await deliverer.pendingIdentifiers().subtracting(known)
        guard !orphans.isEmpty else { return 0 }

        await deliverer.cancel(ids: Array(orphans))

        return orphans.count
    }

    /// Scheduled rows in the future that the plan no longer asks for, plus any duplicate of a
    /// slot it does.
    ///
    /// Past rows are left alone. A scheduled row whose time has gone either fired — and the next
    /// pass's `markDelivered` will say so once the system reports it — or was missed, and either
    /// way withdrawing it now would rewrite history rather than change what the user sees.
    ///
    /// The duplicate rule is repair, not policy. Two rows for one slot mean two notifications at
    /// the same minute, and the only thing standing between the user and that is a cap counted in
    /// threes. It is reachable through any path that gets two passes running at once — which is
    /// meant to be impossible (`CheckInReminderController.inFlight`) and was not, so the state is
    /// cleaned up here rather than only ruled out upstream.
    private func cancelUnwanted(_ ledger: inout [NotificationRecord],
                                plan: [PlannedNotification],
                                now: Date,
                                language: AppLanguage) async throws -> Int {
        var kept: [NotificationRecord] = []
        let unwanted = ledger.filter { record in
            guard record.state == .scheduled, record.scheduledFor > now else { return false }
            // A row rendered in a language the app has since left. The request in the
            // notification centre already holds those words and iOS will not re-resolve them,
            // so the only way to change the language of a scheduled reminder is to replace it.
            guard record.language == language else { return true }
            guard plan.contains(where: { matches(record, $0) }) else { return true }
            // The first row for a slot stays; anything else pointing at the same minute goes.
            guard !kept.contains(where: { sameSlot($0, record) }) else { return true }

            kept.append(record)
            return false
        }
        guard !unwanted.isEmpty else { return 0 }

        await deliverer.cancel(ids: unwanted.map(\.id))
        for record in unwanted {
            guard let moved = record.moved(to: .cancelled, at: now) else { continue }
            try await store.save(moved)
            replace(moved, in: &ledger)
        }

        return unwanted.count
    }

    /// Everything the plan still wants and the log does not yet hold, in ascending order.
    ///
    /// Ascending matters: the allowance is spent by the earliest slot that asks for it, which is
    /// the only ordering under which the cap does not depend on the order the caller happened to
    /// build its plan in.
    ///
    /// ## What counts as "the log already holds it"
    ///
    /// Only `.scheduled` and `.delivered`. Those are settled — the slot is with the system, or it
    /// has already reached the user, and either way asking again would send it twice.
    ///
    /// `.suppressed` is not settled, and reading it as such was a bug. A refusal records what the
    /// cap cost on one pass, not a decision about the slot: the allowance can be freed later the
    /// same day — a check-in withdraws that evening's reminder, and `.cancelled` rows spend
    /// nothing — and the slot is then worth having after all. Reading the refusal as final left
    /// the day quieter than the cap actually required. Unreachable with one notification kind
    /// planned one slot deep, which is why it never showed; it would have appeared with the
    /// second kind, as a notification that silently never arrived.
    private func schedule(_ plan: [PlannedNotification],
                          into ledger: inout [NotificationRecord],
                          now: Date,
                          language: AppLanguage) async throws -> (scheduled: Int, suppressed: Int) {
        var scheduled = 0
        var suppressed = 0

        for planned in plan.sorted(by: { $0.fireAt < $1.fireAt }) {
            guard planned.fireAt > now else { continue }

            let logged = ledger.filter { matches($0, planned) && $0.language == language }
            let isSettled = logged.contains { $0.state == .scheduled || $0.state == .delivered }
            guard !isSettled else { continue }

            let allowed = budget.admitsAnotherSend(on: planned.fireAt,
                                                   given: ledger,
                                                   calendar: calendar)
            guard allowed else {
                // One refusal per slot, not one per pass. The row exists to be read back — "this
                // is what the cap cost that day" — and re-logging on every scene activation would
                // turn a single refusal into a day's worth of them and make the log useless for
                // the question it is kept to answer.
                guard !logged.contains(where: { $0.state == .suppressed }) else { continue }

                let record = NotificationRecord(kind: planned.kind,
                                                language: language,
                                                scheduledFor: planned.fireAt,
                                                state: .suppressed,
                                                createdAt: now)
                try await store.save(record)
                ledger.append(record)
                suppressed += 1
                continue
            }

            // The row goes in before the hand-over, not after. If the process dies between the
            // two, an unrecorded scheduled notification is the failure that breaks the cap —
            // it fires, spends an allowance nothing counted, and the next pass schedules
            // another on top of it. A row with nothing behind it is the harmless direction:
            // `cancelOrphans` cannot see it, and it expires unfired.
            let record = NotificationRecord(kind: planned.kind,
                                            language: language,
                                            scheduledFor: planned.fireAt,
                                            state: .scheduled,
                                            createdAt: now)
            try await store.save(record)
            ledger.append(record)

            do {
                try await deliverer.schedule(
                    NotificationDeliveryRequest(
                        id: record.id,
                        kind: planned.kind,
                        title: NotificationCopy.title(for: planned.kind, in: language),
                        body: NotificationCopy.body(for: planned.kind, in: language),
                        fireAt: planned.fireAt
                    )
                )
                scheduled += 1
            } catch {
                // The system refused. The row is walked back to `.cancelled` so the allowance it
                // took is returned — a refusal must not cost the user a notification they could
                // have had.
                if let moved = record.moved(to: .cancelled, at: now) {
                    try await store.save(moved)
                    replace(moved, in: &ledger)
                }
                BarosenseLog.notifications.error("schedule refused by the system")
            }
        }

        return (scheduled, suppressed)
    }

    // MARK: - Helpers

    /// Whether a stored row is the plan entry.
    ///
    /// Compared to the minute rather than to the instant. Both sides come from the same calendar
    /// arithmetic, but one has been through a `Date` on disk and back, and an equality that a
    /// sub-microsecond of storage drift can break would schedule the same reminder twice a day
    /// for the life of the install.
    private func matches(_ record: NotificationRecord, _ planned: PlannedNotification) -> Bool {
        record.kind == planned.kind
            && calendar.isDate(record.scheduledFor,
                               equalTo: planned.fireAt,
                               toGranularity: .minute)
    }

    /// The same rule between two stored rows, for spotting a duplicate.
    private func sameSlot(_ lhs: NotificationRecord, _ rhs: NotificationRecord) -> Bool {
        lhs.kind == rhs.kind
            && calendar.isDate(lhs.scheduledFor,
                               equalTo: rhs.scheduledFor,
                               toGranularity: .minute)
    }

    private func replace(_ record: NotificationRecord, in ledger: inout [NotificationRecord]) {
        guard let index = ledger.firstIndex(where: { $0.id == record.id }) else { return }

        ledger[index] = record
    }
}
