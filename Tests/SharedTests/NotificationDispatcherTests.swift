import XCTest
@testable import Barosense

/// A `NotificationDelivering` that records what it was asked to do and answers from memory.
///
/// An actor rather than a class with a lock: the dispatcher awaits it from whatever context is
/// running, and the project builds with complete strict concurrency.
actor FakeNotificationDeliverer: NotificationDelivering {

    private(set) var scheduled: [NotificationDeliveryRequest] = []
    private(set) var cancelled: [UUID] = []
    private(set) var authorizationRequests = 0

    private var authorized: Bool
    private var delivered: Set<UUID> = []
    private var refuses = false

    init(authorized: Bool = true) {
        self.authorized = authorized
    }

    func isAuthorized() -> Bool { authorized }

    func requestAuthorization() -> Bool {
        authorizationRequests += 1
        return authorized
    }

    func schedule(_ request: NotificationDeliveryRequest) throws {
        guard authorized else { throw NotificationDeliveryError.notAuthorized }
        guard !refuses else {
            throw NotificationDeliveryError.systemRefused(underlying: CocoaError(.fileNoSuchFile))
        }
        scheduled.append(request)
    }

    func cancel(ids: [UUID]) {
        cancelled.append(contentsOf: ids)
        scheduled.removeAll { ids.contains($0.id) }
    }

    /// Everything handed over and not withdrawn. Stands in for the system's own pending list.
    func pendingIdentifiers() -> Set<UUID> { Set(scheduled.map(\.id)) }

    func deliveredIdentifiers() -> Set<UUID> { delivered }

    // MARK: Test control

    func setAuthorized(_ value: Bool) { authorized = value }

    func setRefuses(_ value: Bool) { refuses = value }

    /// Pretends the system fired one of the requests it holds.
    func markDelivered(_ id: UUID) {
        delivered.insert(id)
        scheduled.removeAll { $0.id == id }
    }

    /// A request the system holds that the app has no row for — what an erase leaves behind.
    func plantOrphan(id: UUID) {
        scheduled.append(NotificationDeliveryRequest(id: id,
                                                     kind: .checkInReminder,
                                                     title: "",
                                                     body: "",
                                                     fireAt: .now))
    }
}

/// The one path from "the app would like to say something" to "the system was asked to say it".
final class NotificationDispatcherTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                                         hour: hour, minute: minute)))
    }

    private func plan(_ dates: [Date]) -> [PlannedNotification] {
        dates.map { PlannedNotification(kind: .checkInReminder, fireAt: $0) }
    }

    private func dispatcher(store: any NotificationStore,
                            deliverer: any NotificationDelivering,
                            limit: Int = NotificationBudget.dailySendLimit) -> NotificationDispatcher {
        NotificationDispatcher(store: store,
                               deliverer: deliverer,
                               calendar: calendar,
                               budget: NotificationBudget(dailySendLimit: limit))
    }

    // MARK: - Scheduling

    func testAPlannedNotificationIsLoggedAndHandedToTheSystem() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let slot = try date(12, 20)

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan([slot]), now: now, language: .english)

        XCTAssertEqual(outcome.scheduled, 1)
        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.count, 1)
        XCTAssertEqual(logged.first?.state, .scheduled)
        XCTAssertEqual(logged.first?.scheduledFor, slot)

        let handed = await deliverer.scheduled
        XCTAssertEqual(handed.count, 1)
        // The row and the system's request share one identifier, which is what lets a row be
        // withdrawn without a second lookup table.
        XCTAssertEqual(handed.first?.id, logged.first?.id)
    }

    /// This runs on every scene activation. A second pass with the same plan must do nothing.
    func testASecondPassWithTheSamePlanChangesNothing() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let slots = try [date(12, 20), date(13, 20)]
        let dispatcher = dispatcher(store: store, deliverer: deliverer)

        _ = try await dispatcher.reconcile(plan: plan(slots), now: now, language: .english)
        let second = try await dispatcher.reconcile(plan: plan(slots), now: now, language: .english)

        XCTAssertTrue(second.isQuiet)
        let handed = await deliverer.scheduled
        XCTAssertEqual(handed.count, 2)
    }

    func testTheCopyIsResolvedInTheAppsLanguage() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()

        _ = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan([try date(12, 20)]), now: try date(12, 9), language: .english)

        let handed = await deliverer.scheduled
        XCTAssertEqual(handed.first?.title, "How are you feeling?")
        XCTAssertFalse(handed.first?.body.isEmpty ?? true)
        // Carried into the payload, which is what a tap reads to know where to go — the row it
        // came from may not be readable yet on a cold launch. See `NotificationUserInfo`.
        XCTAssertEqual(handed.first?.kind, .checkInReminder)
    }

    /// The request sitting in the notification centre is already rendered and iOS will not
    /// re-resolve it, so the only way to change the language of a scheduled reminder is to
    /// replace it. Without this a Ukrainian switch is invisible for a week.
    func testASwitchOfLanguageReissuesWhatIsAlreadyScheduled() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let slot = try date(12, 20)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)

        _ = try await dispatcher.reconcile(plan: plan([slot]), now: now, language: .english)
        let outcome = try await dispatcher.reconcile(plan: plan([slot]),
                                                     now: now,
                                                     language: .ukrainian)

        XCTAssertEqual(outcome.cancelled, 1)
        XCTAssertEqual(outcome.scheduled, 1)

        let handed = await deliverer.scheduled
        XCTAssertEqual(handed.count, 1)
        // Against `NotificationCopy` rather than against the Ukrainian words themselves. What
        // this test is about is which language reached the system, and a literal here would put
        // a dispatcher test in the way of every future rewording of the reminder.
        XCTAssertEqual(handed.first?.title,
                       NotificationCopy.title(for: .checkInReminder, in: .ukrainian))
        XCTAssertNotEqual(handed.first?.title,
                          NotificationCopy.title(for: .checkInReminder, in: .english))

        let live = await store.pendingRecords(notBefore: now)
        XCTAssertEqual(live.map(\.language), [.ukrainian])
    }

    // MARK: - The cap

    func testTheFourthNotificationOfADayIsSuppressedAndStillLogged() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 6)
        let slots = try [date(12, 9), date(12, 13), date(12, 18), date(12, 21)]

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan(slots), now: now, language: .english)

        XCTAssertEqual(outcome.scheduled, 3)
        XCTAssertEqual(outcome.suppressed, 1)

        let handed = await deliverer.scheduled
        XCTAssertEqual(handed.count, 3)

        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.count, 4)
        XCTAssertEqual(logged.last?.state, .suppressed)
        XCTAssertEqual(logged.last?.scheduledFor, try date(12, 21))
    }

    /// A refusal is what the cap cost on one pass, not a verdict on the slot. When the day's
    /// allowance is freed — here by a slot leaving the plan, which is what a check-in does to
    /// that evening's reminder — the notification the cap turned away is worth having after all.
    func testASuppressedSlotIsTakenUpOnceTheAllowanceIsFreed() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 6)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)
        let full = try [date(12, 9), date(12, 13), date(12, 18), date(12, 21)]

        let first = try await dispatcher.reconcile(plan: plan(full), now: now, language: .english)
        XCTAssertEqual(first.suppressed, 1)

        // The 18:00 slot is no longer wanted, which returns its allowance to the day.
        let reduced = try [date(12, 9), date(12, 13), date(12, 21)]
        let second = try await dispatcher.reconcile(plan: plan(reduced),
                                                    now: now,
                                                    language: .english)

        XCTAssertEqual(second.cancelled, 1)
        XCTAssertEqual(second.scheduled, 1)

        let handed = await deliverer.scheduled.map(\.fireAt).sorted()
        XCTAssertEqual(handed, try [date(12, 9), date(12, 13), date(12, 21)])
    }

    /// The other half of the same rule. A slot the cap is still refusing must not be logged again
    /// on every pass — the app reconciles on every scene activation, and one refusal would become
    /// a dozen rows saying the same thing.
    func testAStandingRefusalIsLoggedOnceRatherThanOncePerPass() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 6)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)
        let slots = try [date(12, 9), date(12, 13), date(12, 18), date(12, 21)]

        _ = try await dispatcher.reconcile(plan: plan(slots), now: now, language: .english)
        let second = try await dispatcher.reconcile(plan: plan(slots),
                                                    now: now,
                                                    language: .english)

        XCTAssertEqual(second.suppressed, 0)
        XCTAssertTrue(second.isQuiet)

        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.filter { $0.state == .suppressed }.count, 1)
    }

    /// The allowance is spent by the earliest slot that asks for it, whatever order the caller
    /// built its plan in — otherwise the cap depends on the shape of the caller.
    func testTheEarliestSlotsGetTheAllowance() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let shuffled = try [date(12, 21), date(12, 9), date(12, 18), date(12, 13)]

        _ = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan(shuffled), now: try date(12, 6), language: .english)

        let handed = await deliverer.scheduled.map(\.fireAt).sorted()
        XCTAssertEqual(handed, try [date(12, 9), date(12, 13), date(12, 18)])
    }

    func testEachDayGetsItsOwnAllowance() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let slots = try [date(12, 9), date(12, 13), date(12, 18),
                         date(13, 9), date(13, 13), date(13, 18)]

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan(slots), now: try date(12, 6), language: .english)

        XCTAssertEqual(outcome.scheduled, 6)
        XCTAssertEqual(outcome.suppressed, 0)
    }

    /// The cap has to survive a relaunch: it is counted off stored rows, not off what this
    /// process happens to have sent.
    func testYesterdaysStoredRowsStillCountToday() async throws {
        let alreadySent = try [date(12, 8), date(12, 12)].map {
            NotificationRecord(kind: .checkInReminder,
                               language: .english,
                               scheduledFor: $0,
                               state: .delivered,
                               createdAt: $0)
        }
        let store = InMemoryNotificationStore(alreadySent)
        let deliverer = FakeNotificationDeliverer()

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan(try [date(12, 18), date(12, 21)]),
                       now: try date(12, 14),
                       language: .english)

        XCTAssertEqual(outcome.scheduled, 1)
        XCTAssertEqual(outcome.suppressed, 1)
    }

    // MARK: - Withdrawing

    /// What a check-in does: the planner drops that evening's slot, so the row is withdrawn.
    func testAnEmptyPlanWithdrawsWhatWasScheduled() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)

        _ = try await dispatcher.reconcile(plan: plan([try date(12, 20)]),
                                           now: now, language: .english)
        let outcome = try await dispatcher.reconcile(plan: [], now: now, language: .english)

        XCTAssertEqual(outcome.cancelled, 1)
        let stillHeld = await deliverer.scheduled
        XCTAssertTrue(stillHeld.isEmpty)
        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.first?.state, .cancelled)
    }

    /// A row whose time has gone either fired or was missed. Withdrawing it now would rewrite
    /// history rather than change what the user sees.
    func testAPastScheduledRowIsLeftAlone() async throws {
        let past = NotificationRecord(kind: .checkInReminder,
                                      language: .english,
                                      scheduledFor: try date(11, 20),
                                      state: .scheduled,
                                      createdAt: try date(11, 9))
        let store = InMemoryNotificationStore([past])
        let deliverer = FakeNotificationDeliverer()

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: [], now: try date(12, 9), language: .english)

        XCTAssertEqual(outcome.cancelled, 0)
        let logged = await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(logged.first?.state, .scheduled)
    }

    /// Two rows for one slot are two notifications at the same minute. Reached on device by two
    /// passes running at once, which is now prevented upstream — this is the repair, and it has
    /// to work on a store that already holds the damage.
    func testADuplicateRowForOneSlotIsWithdrawn() async throws {
        let slot = try date(12, 20)
        let now = try date(12, 9)
        let twins = (0..<2).map { _ in
            NotificationRecord(kind: .checkInReminder,
                               language: .english,
                               scheduledFor: slot,
                               state: .scheduled,
                               createdAt: now)
        }
        let store = InMemoryNotificationStore(twins)
        let deliverer = FakeNotificationDeliverer()

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan([slot]), now: now, language: .english)

        XCTAssertEqual(outcome.cancelled, 1)
        XCTAssertEqual(outcome.scheduled, 0)
        let live = await store.pendingRecords(notBefore: now)
        XCTAssertEqual(live.count, 1)
    }

    /// "Delete my data" empties the log and cannot reach into the notification centre. The next
    /// pass is where a week of already-scheduled reminders is withdrawn.
    func testARequestTheLogDoesNotAccountForIsCancelled() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let orphan = UUID()
        await deliverer.plantOrphan(id: orphan)

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: [], now: try date(12, 9), language: .english)

        XCTAssertEqual(outcome.orphansCancelled, 1)
        let withdrawn = await deliverer.cancelled
        XCTAssertEqual(withdrawn, [orphan])
    }

    // MARK: - Delivery

    func testARowIsMarkedDeliveredOnlyOnTheSystemsEvidence() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)

        _ = try await dispatcher.reconcile(plan: plan([try date(12, 20)]),
                                           now: now, language: .english)
        let written = await store.records(in: now..<Date.distantFuture)
        let id = try XCTUnwrap(written.first?.id)

        // Time passes and nothing is reported: the row stays put.
        let quiet = try await dispatcher.reconcile(plan: [], now: try date(12, 21),
                                                   language: .english)
        XCTAssertEqual(quiet.markedDelivered, 0)

        await deliverer.markDelivered(id)
        let outcome = try await dispatcher.reconcile(plan: [], now: try date(12, 22),
                                                     language: .english)

        XCTAssertEqual(outcome.markedDelivered, 1)
        let logged = await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(logged.first?.state, .delivered)
    }

    // MARK: - Authorisation and refusal

    func testNothingIsScheduledWithoutPermission() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer(authorized: false)

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan([try date(12, 20)]), now: try date(12, 9), language: .english)

        XCTAssertEqual(outcome.scheduled, 0)
        let logged = await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertTrue(logged.isEmpty)
    }

    /// Rows left in `.scheduled` after permission is revoked would go on spending the day's
    /// allowance for notifications that cannot arrive.
    func testRevokedPermissionWithdrawsTheOutstandingRows() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        let now = try date(12, 9)
        let dispatcher = dispatcher(store: store, deliverer: deliverer)

        _ = try await dispatcher.reconcile(plan: plan([try date(12, 20)]),
                                           now: now, language: .english)
        await deliverer.setAuthorized(false)
        let outcome = try await dispatcher.reconcile(plan: plan([try date(12, 20)]),
                                                     now: now, language: .english)

        XCTAssertEqual(outcome.cancelled, 1)
        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.first?.state, .cancelled)
    }

    /// A refusal must not cost the user a notification they could have had: the row is walked
    /// back so the allowance it took is returned.
    func testASystemRefusalReturnsTheAllowance() async throws {
        let store = InMemoryNotificationStore()
        let deliverer = FakeNotificationDeliverer()
        await deliverer.setRefuses(true)
        let now = try date(12, 9)

        let outcome = try await dispatcher(store: store, deliverer: deliverer)
            .reconcile(plan: plan([try date(12, 20)]), now: now, language: .english)

        XCTAssertEqual(outcome.scheduled, 0)
        let logged = await store.records(in: now..<Date.distantFuture)
        XCTAssertEqual(logged.first?.state, .cancelled)
        XCTAssertEqual(NotificationBudget().remainingSends(on: try date(12, 20),
                                                           given: logged,
                                                           calendar: calendar), 3)
    }

    // MARK: - Retention

    func testRowsOlderThanTheRetentionWindowArePruned() async throws {
        let ancient = NotificationRecord(kind: .checkInReminder,
                                         language: .english,
                                         scheduledFor: try date(1, 20),
                                         state: .delivered,
                                         createdAt: try date(1, 9))
        let store = InMemoryNotificationStore([ancient])
        let deliverer = FakeNotificationDeliverer()
        let dispatcher = NotificationDispatcher(store: store,
                                                deliverer: deliverer,
                                                calendar: calendar,
                                                retention: 5 * 24 * 3600)

        let outcome = try await dispatcher.reconcile(plan: [], now: try date(12, 9),
                                                     language: .english)

        XCTAssertEqual(outcome.pruned, 1)
        let logged = await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertTrue(logged.isEmpty)
    }
}
