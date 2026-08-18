import Foundation

/// Everything a screen needs to know about notifications, from one pass over the log.
///
/// One value rather than five separate reads, because the Settings section and the bell have
/// to agree: a badge saying "1 unread" beside a section saying "0 sent today" is two answers
/// to one question.
struct NotificationsSnapshot: Hashable, Sendable {

    let permission: NotificationPermission

    /// What the user asked for in Settings. Not the same as "reminders will arrive" — see
    /// `isCheckInReminderActive`, which is what the switch shows.
    let isCheckInReminderEnabled: Bool

    /// Today's allowance and what is left of it.
    let budget: NotificationBudgetStatus

    /// When the next reminder is due, pending or already handed to the system. `nil` when
    /// none is planned.
    let nextReminderAt: Date?

    /// The log, newest first, over the window the app keeps.
    let history: [AppNotification]

    /// Reminders are on **and** iOS will let them through. The switch shows this, not the
    /// preference: a switch that stays on while the permission is revoked in iOS Settings is
    /// a switch that lies, which is the same rule the Apple Health row follows.
    var isCheckInReminderActive: Bool {
        isCheckInReminderEnabled && permission == .granted
    }

    /// Delivered and not yet looked at. What the bell counts.
    var unreadCount: Int { history.count(where: \.isUnread) }

    static let empty = NotificationsSnapshot(
        permission: .notRequested,
        isCheckInReminderEnabled: false,
        budget: NotificationBudgetStatus(day: .distantPast, used: 0, limit: NotificationBudget.dailyLimit),
        nextReminderAt: nil,
        history: []
    )
}

/// Plans, records and sends every notification Barosense raises.
///
/// The single door between the app and `UNUserNotificationCenter`, and the piece that makes
/// the log more than bookkeeping. One pass of `refresh` does four things in this order, and
/// the order is load-bearing:
///
/// 1. **Reconcile** — establish what the system did with what it was given last time.
///    Delivered rows have to be settled *before* the budget is counted, or a notification the
///    user already received would not be counted against the day it arrived on.
/// 2. **Stand down or clear the way** — if reminders are off or iOS will not deliver them,
///    withdraw everything outstanding and stop. Nothing is planned that cannot arrive.
/// 3. **Plan** — write the next check-in reminder into the log as a `pending` row. Planning
///    only ever writes to the database; it never talks to the system.
/// 4. **Dispatch** — read the pending queue back *out of the database*, spend the daily
///    budget on it in time order, and hand the survivors to iOS.
///
/// Steps 3 and 4 are separate on purpose. A planner that scheduled directly would have no
/// durable record to enforce a daily limit against — the system centre cannot say how many
/// notifications it delivered yesterday — and no way to show the user what was held back and
/// why. Going through the log means the limit survives a relaunch, and every suppression is
/// a row with a reason on it.
///
/// An actor, so the four steps cannot interleave with a second caller's. It is also the only
/// writer of the log, which is what lets the in-memory ledger below be trusted inside a pass.
actor NotificationCoordinator {

    /// How far ahead a notification is handed to the system.
    ///
    /// Two days. Long enough that a user who does not open the app tomorrow still gets
    /// tomorrow's reminder, short enough that a plan built from today's rhythm is not still
    /// being honoured a week after the rhythm changed. It also bounds what iOS is holding:
    /// the system caps pending requests per app, and there is no reason to spend that budget
    /// on notifications a later pass would rewrite anyway.
    static let schedulingHorizonHours = 48

    /// How far back `refresh` looks, and how much history the bell's list shows.
    static let historyWindowDays = 30

    private let log: any NotificationLogStore
    private let checkIns: any CheckInStore
    private let system: any UserNotificationScheduling
    private let content: any NotificationContentProviding
    private let preferences: any NotificationPreferenceStore

    /// Read per pass rather than stored, because a day boundary moves when the device changes
    /// time zone and the app is not relaunched for it. The daily limit is a promise about the
    /// user's day, so it has to follow the user's clock.
    private let calendar: @Sendable () -> Calendar

    init(log: any NotificationLogStore,
         checkIns: any CheckInStore,
         system: any UserNotificationScheduling,
         content: any NotificationContentProviding,
         preferences: any NotificationPreferenceStore,
         calendar: @escaping @Sendable () -> Calendar = { .current }) {
        self.log = log
        self.checkIns = checkIns
        self.system = system
        self.content = content
        self.preferences = preferences
        self.calendar = calendar
    }

    // MARK: - Entry points

    /// A full pass: reconcile, plan, dispatch. Safe to call on every foreground activation.
    ///
    /// Costs, per call: one log read, one `UNUserNotificationCenter` settings read, one
    /// pending-request read, one check-in read, and a write per row whose state actually
    /// changed. No timer and no polling — the pass runs when the app is already awake, which
    /// is the only time it can do anything anyway.
    @discardableResult
    func refresh(now: Date = Date()) async -> NotificationsSnapshot {
        let today = calendar()
        var ledger = await loadLedger(now: now)

        await reconcile(&ledger, now: now)

        guard preferences.isCheckInReminderEnabled() else {
            await standDown(&ledger, reason: .remindersOff, now: now)
            let permission = await system.permission()
            return snapshot(from: ledger, permission: permission, now: now, calendar: today)
        }

        let permission = await system.permission()
        guard permission == .granted else {
            await standDown(&ledger, reason: .permissionDenied, now: now)
            return snapshot(from: ledger, permission: permission, now: now, calendar: today)
        }

        let history = await recentCheckIns(now: now)
        await withdrawAnsweredReminders(&ledger, checkIns: history, now: now, calendar: today)
        await planCheckInReminder(&ledger, checkIns: history, now: now, calendar: today)
        await dispatchDueNotifications(&ledger, now: now, calendar: today)

        return snapshot(from: ledger, permission: permission, now: now, calendar: today)
    }

    /// What the screens read, without touching the system centre's plan.
    ///
    /// Separate from `refresh` because the bell's badge is drawn far more often than the plan
    /// needs rebuilding, and a badge should not be able to reschedule anything.
    func snapshot(now: Date = Date()) async -> NotificationsSnapshot {
        let today = calendar()
        let ledger = await loadLedger(now: now)
        let permission = await system.permission()
        return snapshot(from: ledger, permission: permission, now: now, calendar: today)
    }

    /// Turns the check-in reminder on or off, asking iOS for permission the first time it is
    /// turned on, and rebuilds the plan around the answer.
    ///
    /// The preference is only written when reminders can actually be delivered. A stored
    /// "on" sitting behind a refused permission would put the switch in a state the user's
    /// device disagrees with, and there is nothing the app could do about it from there.
    @discardableResult
    func setCheckInReminderEnabled(_ enabled: Bool, now: Date = Date()) async -> NotificationsSnapshot {
        guard enabled else {
            preferences.setCheckInReminderEnabled(false)
            return await refresh(now: now)
        }

        let permission = await system.permission()
        // Only ever asks from `.notRequested`. iOS shows the sheet once; calling again after a
        // refusal shows nothing and would just make the tap look like it did something.
        let resolved = permission == .notRequested ? await system.requestPermission() : permission

        preferences.setCheckInReminderEnabled(resolved == .granted)
        return await refresh(now: now)
    }

    /// Marks everything the user has received as seen. Clears the bell.
    @discardableResult
    func markHistoryRead(now: Date = Date()) async -> NotificationsSnapshot {
        var ledger = await loadLedger(now: now)

        for row in Array(ledger.values) where row.isUnread {
            var updated = row
            updated.readAt = now
            await write(updated, into: &ledger)
        }

        let permission = await system.permission()
        return snapshot(from: ledger, permission: permission, now: now, calendar: calendar())
    }

    // MARK: - The pass

    /// The log window this pass works over, keyed by id.
    ///
    /// Held in memory for the length of one pass so the budget can be counted against rows
    /// this pass has just written — four notifications due on one day have to see each other,
    /// or each would find the day empty and all four would go out.
    private typealias Ledger = [UUID: AppNotification]

    private func loadLedger(now: Date) async -> Ledger {
        let rows = (try? await log.notifications(in: window(around: now))) ?? []

        // Built by assignment rather than with `Dictionary(uniqueKeysWithValues:)`, which traps
        // on a duplicate key. Ids are unique in both store implementations, and a data
        // condition is still not something to crash the app over.
        var ledger: Ledger = [:]
        for row in rows {
            ledger[row.id] = row
        }
        return ledger
    }

    /// Settles what the system did with the rows it was given.
    ///
    /// Three transitions, and each is a fact the app cannot learn any other way:
    ///
    /// - A scheduled row whose moment has passed and which the system is no longer holding
    ///   was **delivered**. There is no callback for this — the app may have been closed —
    ///   so it is established by the absence of the request.
    /// - A scheduled row still in the future that the system has *forgotten* goes back to
    ///   pending, so the next dispatch re-sends it rather than leaving a row that claims a
    ///   notification is coming when nothing will arrive.
    /// - A pending row whose moment has already passed is **suppressed**. A trigger in the
    ///   past never fires, and asking "how are you feeling?" six hours late files the answer
    ///   against the wrong hour — which is the one thing the rhythm exists to get right.
    private func reconcile(_ ledger: inout Ledger, now: Date) async {
        let held = await system.pendingIdentifiers()

        // Snapshotted into an array first: the loop writes back into `ledger`, and iterating a
        // collection while mutating what it came from is a habit worth not forming.
        for row in Array(ledger.values) {
            var updated = row

            switch row.state {
            case .scheduled where row.scheduledFor <= now && !held.contains(row.id):
                updated.state = .delivered
                updated.deliveredAt = row.scheduledFor
            case .scheduled where row.scheduledFor > now && !held.contains(row.id):
                updated.state = .pending
            case .pending where row.scheduledFor <= now:
                updated.state = .suppressed(reason: .missedItsMoment)
            default:
                continue
            }

            await write(updated, into: &ledger)
        }
    }

    /// Withdraws everything outstanding, because nothing may be delivered.
    ///
    /// Scheduled rows are cancelled with the system as well as in the log — the row is the
    /// record, but iOS is what would actually ring. Pending rows are suppressed with the
    /// reason, so the list can say why the reminder the user was expecting did not arrive
    /// rather than simply not showing one.
    private func standDown(_ ledger: inout Ledger,
                           reason: NotificationSuppressionReason,
                           now: Date) async {
        let outstanding = ledger.values.filter { $0.scheduledFor > now }
        let held = outstanding.filter(\.state.isHeldBySystem).map(\.id)

        if !held.isEmpty {
            await system.cancel(ids: held)
        }

        for row in outstanding {
            var updated = row

            switch row.state {
            case .scheduled: updated.state = .cancelled
            case .pending: updated.state = .suppressed(reason: reason)
            default: continue
            }

            await write(updated, into: &ledger)
        }
    }

    /// Drops a planned reminder for a day the user has already checked in on.
    ///
    /// The reminder asks a question. Asking it after it has been answered is the fastest way
    /// to teach someone to turn notifications off, and it also frees the day's budget slot for
    /// something that has not been answered yet.
    private func withdrawAnsweredReminders(_ ledger: inout Ledger,
                                           checkIns: [CheckIn],
                                           now: Date,
                                           calendar: Calendar) async {
        let outstanding = ledger.values.filter {
            $0.kind == .checkInReminder
                && $0.scheduledFor > now
                && ($0.state == .pending || $0.state == .scheduled)
                && hasCheckIn(onDayOf: $0.scheduledFor, in: checkIns, calendar: calendar)
        }

        let held = outstanding.filter(\.state.isHeldBySystem).map(\.id)
        if !held.isEmpty {
            await system.cancel(ids: held)
        }

        for row in outstanding {
            var updated = row
            updated.state = .cancelled
            await write(updated, into: &ledger)
        }
    }

    /// Writes the next check-in reminder into the log, if there is not one already.
    ///
    /// Writes only. Whether it may actually go out is the dispatch step's decision, and
    /// keeping the two apart is what makes the daily limit auditable: every reminder the app
    /// ever intended to send exists as a row, including the ones the limit stopped.
    private func planCheckInReminder(_ ledger: inout Ledger,
                                     checkIns: [CheckIn],
                                     now: Date,
                                     calendar: Calendar) async {
        let alreadyPlanned = ledger.values.contains {
            $0.kind == .checkInReminder
                && $0.scheduledFor > now
                && ($0.state == .pending || $0.state == .scheduled)
        }
        guard !alreadyPlanned else { return }

        let rhythm = CheckInRhythmAnalysis.rhythm(from: checkIns, calendar: calendar)
        let secondsFromMidnight = CheckInRhythmAnalysis.reminderSecondsFromMidnight(for: rhythm)

        var instant = CheckInRhythmAnalysis.nextOccurrence(ofSecondsFromMidnight: secondsFromMidnight,
                                                           after: now,
                                                           calendar: calendar)

        // Today's hour may still be ahead of us on a day that has already been answered.
        if hasCheckIn(onDayOf: instant, in: checkIns, calendar: calendar) {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: instant))
                ?? instant
            instant = CheckInRhythmAnalysis.nextOccurrence(ofSecondsFromMidnight: secondsFromMidnight,
                                                           after: tomorrow,
                                                           calendar: calendar)
        }

        guard instant < horizon(from: now) else { return }

        await write(AppNotification(kind: .checkInReminder, createdAt: now, scheduledFor: instant),
                    into: &ledger)
    }

    /// Reads the queue back out of the database and hands what fits to iOS.
    ///
    /// The read is `pendingNotifications(scheduledBefore:)` rather than a filter over the
    /// ledger, because the log is the queue: this is the one step that decides what actually
    /// leaves the app, and it asks the store what is outstanding instead of trusting anything
    /// held in memory since the pass began.
    ///
    /// Ascending by fire time, so a day whose budget runs out holds back the *last*
    /// notification rather than an arbitrary one.
    private func dispatchDueNotifications(_ ledger: inout Ledger, now: Date, calendar: Calendar) async {
        let queue = (try? await log.pendingNotifications(scheduledBefore: horizon(from: now))) ?? []

        for queued in queue {
            // The ledger wins where the two differ: it holds this pass's own writes, which the
            // queue read may predate.
            let row = ledger[queued.id] ?? queued
            guard row.state == .pending, row.scheduledFor > now else { continue }

            var updated = row

            guard NotificationBudget.hasRoom(on: row.scheduledFor,
                                             log: Array(ledger.values),
                                             calendar: calendar) else {
                updated.state = .suppressed(reason: .dailyLimit)
                await write(updated, into: &ledger)
                continue
            }

            do {
                try await system.schedule(id: row.id,
                                          content: content.content(for: row.kind),
                                          at: row.scheduledFor)
                updated.state = .scheduled
                await write(updated, into: &ledger)
            } catch {
                // Left pending on purpose. Every reason this fails — the centre refusing, the
                // fire date slipping into the past between the read and the call — is either
                // transient or will be settled by the next pass's reconciliation, and marking
                // it suppressed would spend a slot on a notification nobody decided against.
                continue
            }
        }
    }

    // MARK: - Helpers

    /// Writes a row to the store and to this pass's ledger, so the two cannot disagree.
    ///
    /// A store failure updates the ledger anyway. The alternative — leaving the ledger on the
    /// old value — would let the same pass plan a second copy of a row it has just written,
    /// and the next pass re-reads from the store regardless.
    private func write(_ notification: AppNotification, into ledger: inout Ledger) async {
        try? await log.save(notification)
        ledger[notification.id] = notification
    }

    private func horizon(from now: Date) -> Date {
        now.addingTimeInterval(TimeInterval(Self.schedulingHorizonHours) * 3600)
    }

    private func window(around now: Date) -> Range<Date> {
        let start = now.addingTimeInterval(-TimeInterval(Self.historyWindowDays) * 24 * 3600)
        return start..<horizon(from: now)
    }

    /// The check-ins the rhythm is read from, plus everything recorded today.
    private func recentCheckIns(now: Date) async -> [CheckIn] {
        let start = now.addingTimeInterval(-TimeInterval(CheckInRhythmAnalysis.lookbackDays) * 24 * 3600)
        return (try? await checkIns.checkIns(in: start..<now)) ?? []
    }

    private func hasCheckIn(onDayOf date: Date, in checkIns: [CheckIn], calendar: Calendar) -> Bool {
        checkIns.contains { calendar.isDate($0.timestamp, inSameDayAs: date) }
    }

    private func snapshot(from ledger: Ledger,
                          permission: NotificationPermission,
                          now: Date,
                          calendar: Calendar) -> NotificationsSnapshot {
        let rows = Array(ledger.values)
        let next = rows
            .filter { $0.scheduledFor > now && ($0.state == .pending || $0.state == .scheduled) }
            .min { $0.scheduledFor < $1.scheduledFor }

        return NotificationsSnapshot(
            permission: permission,
            isCheckInReminderEnabled: preferences.isCheckInReminderEnabled(),
            budget: NotificationBudget.status(on: now, log: rows, calendar: calendar),
            nextReminderAt: next?.scheduledFor,
            // Newest first: the list is read from the top, and the row a user is looking for
            // after a notification arrives is the one that just arrived.
            history: rows.sorted { $0.scheduledFor > $1.scheduledFor }
        )
    }
}
