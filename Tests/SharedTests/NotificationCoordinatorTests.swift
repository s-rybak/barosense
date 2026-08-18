import XCTest
@testable import Barosense

/// One pass of the notification plan: reconcile, stand down or plan, dispatch.
///
/// Everything here runs against `InMemoryNotificationLogStore` and a spy scheduler — no
/// `UNUserNotificationCenter`, no permission sheet, no device. That is the point of putting the
/// rules in `Shared/`: the daily limit and the reminder's timing are the two things most likely
/// to go wrong, and neither should need a phone to check.
final class NotificationCoordinatorTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    /// Midday on the fourth, with a 20:00 habit behind it.
    private var now: Date { date(day: 4, hour: 12) }

    // MARK: - Planning

    func testTheReminderIsPlannedAtTheHourTheUserUsuallyLogs() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        let snapshot = await coordinator.refresh(now: now)

        let scheduled = await system.scheduledDates
        XCTAssertEqual(scheduled, [date(day: 4, hour: 20)])
        XCTAssertEqual(snapshot.nextReminderAt, date(day: 4, hour: 20))

        let rows = try await log.notifications(in: window)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.kind, .checkInReminder)
        XCTAssertEqual(rows.first?.state, .scheduled)
    }

    /// The log is written first and the system is told second, which is what makes the daily
    /// limit enforceable at all — the system centre cannot be asked what it delivered
    /// yesterday, and a row can.
    func testEverythingHandedToTheSystemIsARowInTheLogFirst() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        await coordinator.refresh(now: now)

        let rows = try await log.notifications(in: window)
        let scheduledIDs = await system.scheduledIDs
        XCTAssertEqual(scheduledIDs, rows.map(\.id))
    }

    /// The queue read is the store's, not the planner's memory. A row put into the database by
    /// anything at all is picked up and sent on the next pass.
    func testTheDispatchQueueIsReadOutOfTheStore() async throws {
        let queued = AppNotification(kind: .checkInReminder,
                                     createdAt: now,
                                     scheduledFor: date(day: 4, hour: 20))
        let log = InMemoryNotificationLogStore([queued])
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, system: system)

        await coordinator.refresh(now: now)

        let scheduledIDs = await system.scheduledIDs
        XCTAssertEqual(scheduledIDs, [queued.id])

        let rows = try await log.notifications(in: window)
        // No second reminder planned beside it: one future reminder at a time.
        XCTAssertEqual(rows.count, 1)
    }

    func testRepeatedPassesDoNotPlanASecondReminder() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        await coordinator.refresh(now: now)
        await coordinator.refresh(now: date(day: 4, hour: 13))
        await coordinator.refresh(now: date(day: 4, hour: 14))

        let scheduledIDs = await system.scheduledIDs
        let rows = try await log.notifications(in: window)

        XCTAssertEqual(scheduledIDs.count, 1)
        XCTAssertEqual(rows.count, 1)
    }

    /// A reminder asks a question. Asking it after it has been answered is the fastest way to
    /// teach someone to switch notifications off.
    func testADayThatHasAlreadyBeenCheckedInIsSkipped() async throws {
        let checkIns = eveningHabit + [checkIn(day: 4, hour: 9)]
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: checkIns, system: system)

        await coordinator.refresh(now: now)

        let scheduledDates = await system.scheduledDates
        let scheduled = try XCTUnwrap(scheduledDates.first)
        XCTAssertTrue(calendar.isDate(scheduled, inSameDayAs: date(day: 5, hour: 0)))
    }

    /// The check-in may land after the reminder has already been accepted by iOS, which is the
    /// case the withdrawal exists for: the row is rewritten *and* the system request pulled.
    func testAReminderIsWithdrawnWhenTheDayIsCheckedInAfterItWasScheduled() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let checkIns = InMemoryCheckInStore(eveningHabit)
        let coordinator = makeCoordinator(log: log, checkInStore: checkIns, system: system)

        await coordinator.refresh(now: now)
        let plannedRows = try await log.notifications(in: window)
        let planned = try XCTUnwrap(plannedRows.first)

        await checkIns.save(checkIn(day: 4, hour: 13))
        await coordinator.refresh(now: date(day: 4, hour: 14))

        let cancelled = await system.cancelledIDs
        let rows = try await log.notifications(in: window)
        let withdrawn = rows.first { $0.id == planned.id }

        XCTAssertEqual(cancelled, [planned.id])
        XCTAssertEqual(withdrawn?.state, .cancelled)
        // And a new one for the following day took its place.
        XCTAssertEqual(rows.count, 2)
    }

    // MARK: - The daily limit

    func testTheFourthNotificationOfADayIsHeldBack() async throws {
        let spent = (0..<NotificationBudget.dailyLimit).map {
            delivered(day: 4, hour: 6 + $0)
        }
        let log = InMemoryNotificationLogStore(spent)
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        let snapshot = await coordinator.refresh(now: now)

        let scheduledIDs = await system.scheduledIDs
        XCTAssertTrue(scheduledIDs.isEmpty)

        let rows = try await log.notifications(in: window)
        let heldBack = rows.first { $0.scheduledFor == date(day: 4, hour: 20) }
        XCTAssertEqual(heldBack?.state, .suppressed(reason: .dailyLimit))

        XCTAssertEqual(snapshot.budget.used, NotificationBudget.dailyLimit)
        XCTAssertEqual(snapshot.budget.remaining, 0)
    }

    /// The suppression must not spend the slot that caused it, and tomorrow starts clean.
    func testTheNextDayHasItsOwnAllowance() async throws {
        let spent = (0..<NotificationBudget.dailyLimit).map {
            delivered(day: 4, hour: 6 + $0)
        }
        let log = InMemoryNotificationLogStore(spent)
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        // Past this evening's hour, so the plan lands on the fifth.
        await coordinator.refresh(now: date(day: 4, hour: 21))

        let scheduled = await system.scheduledDates
        XCTAssertEqual(scheduled, [date(day: 5, hour: 20)])
    }

    // MARK: - Reconciliation

    /// There is no callback for delivery — the app may have been closed — so a notification the
    /// system no longer holds and whose moment has passed is taken to have arrived.
    func testAScheduledNotificationThatHasFiredIsSettledAsDelivered() async throws {
        let fired = AppNotification(kind: .checkInReminder,
                                    createdAt: date(day: 4, hour: 8),
                                    scheduledFor: date(day: 4, hour: 10),
                                    state: .scheduled)
        let log = InMemoryNotificationLogStore([fired])
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit)

        let snapshot = await coordinator.refresh(now: now)

        let rows = try await log.notifications(in: window)
        let settled = try XCTUnwrap(rows.first { $0.id == fired.id })
        XCTAssertEqual(settled.state, .delivered)
        XCTAssertEqual(settled.deliveredAt, date(day: 4, hour: 10))
        XCTAssertEqual(snapshot.unreadCount, 1)
    }

    /// A trigger in the past never fires, and asking "how are you feeling?" hours late files
    /// the answer against the wrong hour — the one thing the rhythm exists to get right.
    func testAQueuedNotificationWhoseMomentPassedIsSuppressedRatherThanSentLate() async throws {
        let missed = AppNotification(kind: .checkInReminder,
                                     createdAt: date(day: 4, hour: 8),
                                     scheduledFor: date(day: 4, hour: 10))
        let log = InMemoryNotificationLogStore([missed])
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        await coordinator.refresh(now: now)

        let rows = try await log.notifications(in: window)
        let settled = try XCTUnwrap(rows.first { $0.id == missed.id })
        let scheduledIDs = await system.scheduledIDs

        XCTAssertEqual(settled.state, .suppressed(reason: .missedItsMoment))
        XCTAssertFalse(scheduledIDs.contains(missed.id))
    }

    /// Every reason the system centre can refuse is either transient or settled by the next
    /// pass, so the row stays in the queue rather than being marked as decided against.
    func testASystemRefusalLeavesTheRowQueuedForTheNextPass() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler(refusesToSchedule: true)
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        await coordinator.refresh(now: now)

        let rows = try await log.notifications(in: window)
        XCTAssertEqual(rows.first?.state, .pending)
    }

    // MARK: - The switch

    func testNothingIsPlannedWhileRemindersAreOff() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log,
                                          checkIns: eveningHabit,
                                          system: system,
                                          remindersEnabled: false)

        let snapshot = await coordinator.refresh(now: now)

        let rows = try await log.notifications(in: window)
        let scheduledIDs = await system.scheduledIDs

        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(scheduledIDs.isEmpty)
        XCTAssertNil(snapshot.nextReminderAt)
        XCTAssertFalse(snapshot.isCheckInReminderActive)
    }

    func testTurningTheReminderOffWithdrawsWhatWasAlreadyScheduled() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        await coordinator.refresh(now: now)
        let plannedRows = try await log.notifications(in: window)
        let planned = try XCTUnwrap(plannedRows.first)

        let snapshot = await coordinator.setCheckInReminderEnabled(false, now: now)

        let cancelled = await system.cancelledIDs
        let rows = try await log.notifications(in: window)
        let settled = try XCTUnwrap(rows.first { $0.id == planned.id })

        XCTAssertEqual(cancelled, [planned.id])
        XCTAssertEqual(settled.state, .cancelled)
        XCTAssertFalse(snapshot.isCheckInReminderActive)
    }

    /// iOS shows the permission sheet once. Asking again after a refusal shows nothing, so the
    /// second tap has to route the user somewhere rather than look like it did something.
    func testARefusedPermissionLeavesTheSwitchOffAndIsNotAskedTwice() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler(permission: .notRequested, answering: .denied)
        let preferences = InMemoryNotificationPreferenceStore(isCheckInReminderEnabled: false)
        let coordinator = makeCoordinator(log: log,
                                          checkIns: eveningHabit,
                                          system: system,
                                          preferences: preferences)

        let first = await coordinator.setCheckInReminderEnabled(true, now: now)
        let second = await coordinator.setCheckInReminderEnabled(true, now: now)

        let requestCount = await system.requestCount
        let scheduledIDs = await system.scheduledIDs

        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(first.isCheckInReminderActive)
        XCTAssertFalse(second.isCheckInReminderEnabled)
        XCTAssertTrue(scheduledIDs.isEmpty)
    }

    func testGrantingPermissionTurnsTheSwitchOnAndPlansTheFirstReminder() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler(permission: .notRequested, answering: .granted)
        let preferences = InMemoryNotificationPreferenceStore(isCheckInReminderEnabled: false)
        let coordinator = makeCoordinator(log: log,
                                          checkIns: eveningHabit,
                                          system: system,
                                          preferences: preferences)

        let snapshot = await coordinator.setCheckInReminderEnabled(true, now: now)

        XCTAssertTrue(snapshot.isCheckInReminderActive)
        XCTAssertEqual(snapshot.nextReminderAt, date(day: 4, hour: 20))
        XCTAssertTrue(preferences.isCheckInReminderEnabled())
    }

    // MARK: - The bell

    func testMarkingTheHistoryReadClearsTheUnreadCount() async throws {
        let log = InMemoryNotificationLogStore([delivered(day: 4, hour: 8)])
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit)

        let before = await coordinator.snapshot(now: now)
        let after = await coordinator.markHistoryRead(now: now)

        XCTAssertEqual(before.unreadCount, 1)
        XCTAssertEqual(after.unreadCount, 0)
    }

    /// A plain read must not be able to move the plan — the bell's badge is drawn far more
    /// often than the plan needs rebuilding.
    func testReadingASnapshotSchedulesNothing() async throws {
        let log = InMemoryNotificationLogStore()
        let system = SpyUserNotificationScheduler()
        let coordinator = makeCoordinator(log: log, checkIns: eveningHabit, system: system)

        _ = await coordinator.snapshot(now: now)

        let rows = try await log.notifications(in: window)
        let scheduledIDs = await system.scheduledIDs

        XCTAssertTrue(rows.isEmpty)
        XCTAssertTrue(scheduledIDs.isEmpty)
    }

    // MARK: - Fixtures

    private func makeCoordinator(log: InMemoryNotificationLogStore,
                                 checkIns: [CheckIn] = [],
                                 checkInStore: InMemoryCheckInStore? = nil,
                                 system: SpyUserNotificationScheduler = SpyUserNotificationScheduler(),
                                 preferences: InMemoryNotificationPreferenceStore? = nil,
                                 remindersEnabled: Bool = true) -> NotificationCoordinator {
        let calendar = calendar
        return NotificationCoordinator(
            log: log,
            checkIns: checkInStore ?? InMemoryCheckInStore(checkIns),
            system: system,
            content: FixedNotificationContent(),
            preferences: preferences
                ?? InMemoryNotificationPreferenceStore(isCheckInReminderEnabled: remindersEnabled),
            calendar: { calendar }
        )
    }

    /// Three evenings at 20:00 — enough for the rhythm to be reliable, and clear of the
    /// default hour so a test cannot pass by falling back to it.
    private var eveningHabit: [CheckIn] {
        [checkIn(day: 1, hour: 20), checkIn(day: 2, hour: 20), checkIn(day: 3, hour: 20)]
    }

    /// Wide enough to hold everything any test in this file writes.
    private var window: Range<Date> { date(day: 1, hour: 0)..<date(day: 9, hour: 0) }

    private func checkIn(day: Int, hour: Int, minute: Int = 0) -> CheckIn {
        CheckIn(timestamp: date(day: day, hour: hour, minute: minute),
                intensity: CheckInIntensity(clamping: 4))
    }

    private func delivered(day: Int, hour: Int) -> AppNotification {
        let instant = date(day: day, hour: hour)
        return AppNotification(kind: .checkInReminder,
                               createdAt: instant,
                               scheduledFor: instant,
                               state: .delivered,
                               deliveredAt: instant)
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day,
                                           hour: hour, minute: minute)) ?? .distantPast
    }
}

// MARK: - Doubles

/// Stands in for `UNUserNotificationCenter`, and behaves like it in the one way the
/// reconciliation depends on: a request it accepts is one it then reports as pending, until it
/// is cancelled.
private actor SpyUserNotificationScheduler: UserNotificationScheduling {

    private var current: NotificationPermission
    private let answer: NotificationPermission
    private let refusesToSchedule: Bool
    private var held: Set<UUID> = []

    private(set) var requestCount = 0
    private(set) var scheduledIDs: [UUID] = []
    private(set) var scheduledDates: [Date] = []
    private(set) var cancelledIDs: [UUID] = []

    init(permission: NotificationPermission = .granted,
         answering answer: NotificationPermission = .granted,
         refusesToSchedule: Bool = false) {
        current = permission
        self.answer = answer
        self.refusesToSchedule = refusesToSchedule
    }

    func permission() async -> NotificationPermission { current }

    func requestPermission() async -> NotificationPermission {
        requestCount += 1
        if current == .notRequested { current = answer }
        return current
    }

    func schedule(id: UUID, content: NotificationContent, at date: Date) async throws {
        if refusesToSchedule { throw NotificationSchedulingError.systemRefused }

        scheduledIDs.append(id)
        scheduledDates.append(date)
        held.insert(id)
    }

    func cancel(ids: [UUID]) async {
        cancelledIDs.append(contentsOf: ids)
        held.subtract(ids)
    }

    func pendingIdentifiers() async -> Set<UUID> { held }
}

private struct FixedNotificationContent: NotificationContentProviding {
    func content(for kind: AppNotificationKind) -> NotificationContent {
        NotificationContent(title: "How are you feeling?", body: "A short check-in.")
    }
}
