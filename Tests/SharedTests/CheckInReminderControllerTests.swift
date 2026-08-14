import XCTest
@testable import Barosense

/// What a reconcile pass does when the reminder is switched off, and when it asks iOS for
/// permission.
@MainActor
final class CheckInReminderControllerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    // MARK: - Standing down

    /// The behaviour the switch depends on. Turning the reminder off has to reach the week
    /// already sitting in the notification centre — a pass that returned early instead would
    /// leave the user switching reminders off and going on getting them for another seven days.
    func testTurningTheReminderOffWithdrawsWhatWasAlreadyScheduled() async throws {
        let log = InMemoryNotificationStore()
        let outstanding = NotificationRecord(kind: .checkInReminder,
                                             language: .english,
                                             scheduledFor: now.addingTimeInterval(3600),
                                             state: .scheduled,
                                             createdAt: now)
        try await log.save(outstanding)

        let deliverer = RecordingNotificationDeliverer(isAuthorized: true)
        let controller = makeController(
            store: log,
            deliverer: deliverer,
            preferences: InMemoryReminderPreferenceStore(isCheckInReminderEnabled: false)
        )

        await controller.refresh(language: .english, calendar: calendar, now: now)

        let rows = try await log.records(in: now..<Date.distantFuture)

        XCTAssertEqual(deliverer.cancelledIDs, [outstanding.id])
        XCTAssertEqual(rows.map(\.state), [.cancelled])
        XCTAssertTrue(deliverer.scheduledIDs.isEmpty)
    }

    /// Nothing is planned while the switch is off, so a pass over an empty log is silent rather
    /// than filling the week back in.
    func testNothingIsScheduledWhileTheReminderIsOff() async throws {
        let log = InMemoryNotificationStore()
        let deliverer = RecordingNotificationDeliverer(isAuthorized: true)
        let controller = makeController(
            store: log,
            deliverer: deliverer,
            preferences: InMemoryReminderPreferenceStore(isCheckInReminderEnabled: false)
        )

        await controller.refresh(language: .english, calendar: calendar, now: now)

        XCTAssertTrue(deliverer.scheduledIDs.isEmpty)
    }

    // MARK: - Permission

    /// The invariant the whole permission design rests on. iOS shows the prompt once ever, and a
    /// prompt raised by a scene activation is spent on a dialog the user has no context for —
    /// which is answered "Don't Allow" and cannot be asked again. A reconcile pass therefore
    /// never asks, on any path, including the one where the reminder is switched on and wanted.
    func testAReconcilePassNeverRaisesAPermissionPrompt() async {
        let deliverer = RecordingNotificationDeliverer(isAuthorized: true)
        let controller = makeController(deliverer: deliverer)

        await controller.refresh(language: .english, calendar: calendar, now: now)
        await controller.refresh(language: .english, calendar: calendar, now: now)

        XCTAssertEqual(deliverer.authorizationRequests, 0)
    }

    // MARK: - The primer

    func testThePrimerIsOfferedOnAFreshInstall() async {
        let controller = makeController(
            deliverer: RecordingNotificationDeliverer(isAuthorized: false),
            preferences: InMemoryReminderPreferenceStore(hasOfferedCheckInReminder: false)
        )

        let shouldOffer = await controller.shouldOfferPrimer()

        XCTAssertTrue(shouldOffer)
    }

    /// Once per install, whichever way it was answered. Re-offering it would make "not now" mean
    /// "ask me again next launch", which is the nagging the screen exists to avoid.
    func testThePrimerIsNotOfferedAgainOnceAnswered() async {
        let preferences = InMemoryReminderPreferenceStore(hasOfferedCheckInReminder: false)
        let controller = makeController(
            deliverer: RecordingNotificationDeliverer(isAuthorized: false),
            preferences: preferences
        )

        controller.declinePrimer()
        let shouldOffer = await controller.shouldOfferPrimer()

        XCTAssertFalse(shouldOffer)
    }

    /// A reinstall over a previous grant, or a restore. Explaining a thing that is already
    /// working, and then asking for permission already held, is a screen with nothing to do.
    func testThePrimerIsNotOfferedWhenPermissionIsAlreadyGranted() async {
        let controller = makeController(
            deliverer: RecordingNotificationDeliverer(isAuthorized: true),
            preferences: InMemoryReminderPreferenceStore(hasOfferedCheckInReminder: false)
        )

        let shouldOffer = await controller.shouldOfferPrimer()

        XCTAssertFalse(shouldOffer)
    }

    /// Accepting is the one path that reaches iOS, and it has to plan the week straight away —
    /// a grant that nothing re-planned against would leave the user waiting for the next launch
    /// to hear anything.
    func testAcceptingThePrimerAsksIOSAndPlansTheWeek() async {
        let deliverer = RecordingNotificationDeliverer(isAuthorized: true)
        let preferences = InMemoryReminderPreferenceStore(isCheckInReminderEnabled: false,
                                                          hasOfferedCheckInReminder: false)
        let controller = makeController(deliverer: deliverer, preferences: preferences)

        await controller.acceptPrimer(language: .english, calendar: calendar, now: now)

        XCTAssertEqual(deliverer.authorizationRequests, 1)
        XCTAssertEqual(deliverer.scheduledIDs.count, CheckInReminderPlanner.horizonDays)
        XCTAssertTrue(preferences.isCheckInReminderEnabled())
        XCTAssertTrue(preferences.hasOfferedCheckInReminder())
    }

    /// "Not now" writes the preference *off* rather than leaving it on with no permission behind
    /// it. The difference is what Settings then says: the second state is
    /// `ReminderSettings.isBlockedBySystem`, whose caption sends the user to iOS Settings to
    /// re-enable something nobody ever asked them about.
    func testDecliningThePrimerLeavesTheSettingsSwitchTellingTheTruth() async {
        let deliverer = RecordingNotificationDeliverer(isAuthorized: false)
        let preferences = InMemoryReminderPreferenceStore(hasOfferedCheckInReminder: false)
        let controller = makeController(deliverer: deliverer, preferences: preferences)

        controller.declinePrimer()

        XCTAssertFalse(preferences.isCheckInReminderEnabled())
        XCTAssertTrue(preferences.hasOfferedCheckInReminder())
        // Nothing was asked of iOS, which is what leaves the Settings switch a working second
        // chance rather than a dead one.
        XCTAssertEqual(deliverer.authorizationRequests, 0)
    }

    // MARK: - Helpers

    private func makeController(
        checkIns: any CheckInStore = InMemoryCheckInStore(),
        store: any NotificationStore = InMemoryNotificationStore(),
        deliverer: any NotificationDelivering = RecordingNotificationDeliverer(isAuthorized: true),
        preferences: any ReminderPreferenceStore = InMemoryReminderPreferenceStore()
    ) -> CheckInReminderController {
        CheckInReminderController(checkIns: checkIns,
                                  store: store,
                                  deliverer: deliverer,
                                  preferences: preferences)
    }
}

// MARK: - Doubles

/// Accepts everything and remembers what it was asked to do, so a pass can be asserted on what
/// reached the system rather than only on what the log says afterwards.
private final class RecordingNotificationDeliverer: NotificationDelivering, @unchecked Sendable {

    private let lock = NSLock()
    private let authorized: Bool
    private var _scheduledIDs: [UUID] = []
    private var _cancelledIDs: [UUID] = []
    private var _authorizationRequests = 0

    init(isAuthorized: Bool) {
        authorized = isAuthorized
    }

    var scheduledIDs: [UUID] { lock.withLock { _scheduledIDs } }
    var cancelledIDs: [UUID] { lock.withLock { _cancelledIDs } }
    var authorizationRequests: Int { lock.withLock { _authorizationRequests } }

    func isAuthorized() async -> Bool { authorized }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _authorizationRequests += 1
            return authorized
        }
    }

    func schedule(_ request: NotificationDeliveryRequest) async throws {
        guard authorized else { throw NotificationDeliveryError.notAuthorized }

        lock.withLock { _scheduledIDs.append(request.id) }
    }

    func cancel(ids: [UUID]) async {
        lock.withLock { _cancelledIDs.append(contentsOf: ids) }
    }

    /// Empty rather than the scheduled set: the pass must not treat something it has just handed
    /// over as already outstanding from a previous run.
    func pendingIdentifiers() async -> Set<UUID> { [] }

    func deliveredIdentifiers() async -> Set<UUID> { [] }
}
