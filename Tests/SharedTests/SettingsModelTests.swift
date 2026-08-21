import XCTest
@testable import Barosense

/// The settings list: what the Apple Health row reports, and what "delete my data" does.
@MainActor
final class SettingsModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every type in the read set proven readable — the state a fully granted user on
    /// hardware that carries every sensor lands in.
    private static let everythingReadable = HealthAccessState.requested(
        readable: Set(HealthMetricKind.allCases)
    )

    // MARK: - Apple Health row

    /// Nobody has been asked yet, so there is nothing readable to prove.
    func testTheSwitchIsOffUntilEveryTypeHasBeenAsked() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .notRequested))

        await model.load()

        XCTAssertEqual(model.health.access, .notRequested)
        XCTAssertFalse(model.health.isConnected)
        XCTAssertTrue(model.health.isInteractive)
    }

    /// The case this whole state exists for: the sheet has been answered, and answered in
    /// a way that left nothing readable. Being *asked* is not being *granted*, and the
    /// switch may not claim otherwise.
    func testTheSwitchIsOffWhenTheSheetLeftNothingReadable() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .requested(readable: [])))

        await model.load()

        XCTAssertFalse(model.health.isConnected)
        XCTAssertTrue(model.health.hasNothingReadable)
        // Still actionable: the Health app can settle what the app cannot.
        XCTAssertTrue(model.health.isInteractive)
    }

    /// An Apple Watch SE — or a US unit sold between January 2024 and mid-2025 — has no
    /// blood-oxygen sensor at all, so that probe comes back empty however complete the
    /// user's grant is. The switch must still be on: holding it off sends them to the
    /// Health app, where everything is already allowed, and back again for good.
    func testTheSwitchIsOnWithoutABloodOxygenSensor() async {
        let reporter = StubHealthAccessReporter(
            state: .requested(readable: [.heartRate, .restingHeartRate, .asleep])
        )
        let model = makeModel(access: reporter)

        await model.load()

        XCTAssertTrue(model.health.isConnected)
        XCTAssertFalse(model.health.hasNothingReadable)
        // The row still reports what was observed — it is the switch that stops acting
        // on it, not the observation that disappears.
        XCTAssertEqual(model.health.unreadableTypes, [.oxygenSaturation])
    }

    /// A type a working device does produce is a different matter: nothing about the
    /// hardware explains an empty sleep probe, so the switch stays off and the caption
    /// has somewhere to send the user.
    func testTheSwitchIsOffWhileATypeEveryDeviceProducesCannotBeRead() async {
        let reporter = StubHealthAccessReporter(
            state: .requested(readable: [.heartRate, .restingHeartRate, .oxygenSaturation])
        )
        let model = makeModel(access: reporter)

        await model.load()

        XCTAssertFalse(model.health.isConnected)
        XCTAssertFalse(model.health.hasNothingReadable)
        XCTAssertEqual(model.health.unreadableTypes, [.asleep])
    }

    func testTheSwitchIsOnWhenEveryTypeCanBeRead() async {
        let model = makeModel(access: StubHealthAccessReporter(state: Self.everythingReadable))

        await model.load()

        XCTAssertTrue(model.health.isConnected)
        XCTAssertTrue(model.health.unreadableTypes.isEmpty)
    }

    /// No Health store on this device: the row is inert rather than merely off, because
    /// there is nothing a tap could do.
    func testTheSwitchIsNotInteractiveWithoutAHealthStore() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .unavailable))

        await model.load()

        let outcome = await model.toggleHealthAccess()

        XCTAssertFalse(model.health.isInteractive)
        XCTAssertEqual(outcome, .unavailable)
    }

    /// Whether readings are arriving is a separate fact from the authorisation, read from
    /// the training log rather than from HealthKit.
    func testReadingsAreReportedFromTheTrainingLog() async throws {
        let log = InMemoryHealthSampleStore()
        try await log.save([HealthSample(id: UUID(),
                                         start: now.addingTimeInterval(-3600),
                                         end: now.addingTimeInterval(-3600),
                                         value: .restingHeartRateBPM(58))])

        let model = makeModel(access: StubHealthAccessReporter(state: Self.everythingReadable),
                              healthLog: log)
        await model.load()

        XCTAssertTrue(model.health.hasReadings)
    }

    /// Read access can be granted while nothing has arrived — ingestion stalled, or the
    /// watch left in a drawer. That is a caption, not a reason to turn the switch off.
    func testAnEmptyLogDoesNotTurnAGrantedConnectionOff() async {
        let model = makeModel(access: StubHealthAccessReporter(state: Self.everythingReadable))

        await model.load()

        XCTAssertTrue(model.health.isConnected)
        XCTAssertFalse(model.health.hasReadings)
    }

    /// Older than the lookback window the log is refreshed over, so it does not count as
    /// "readings are arriving".
    func testAStaleReadingDoesNotCountAsConnected() async throws {
        let log = InMemoryHealthSampleStore()
        let old = now.addingTimeInterval(-30 * 24 * 3600)
        try await log.save([HealthSample(id: UUID(), start: old, end: old,
                                         value: .restingHeartRateBPM(58))])

        let model = makeModel(access: StubHealthAccessReporter(state: Self.everythingReadable),
                              healthLog: log)
        await model.load()

        XCTAssertFalse(model.health.hasReadings)
    }

    // MARK: - Tapping the switch

    func testTappingAnUnaskedRowRequestsAccessAndRereadsWhatBecameReadable() async {
        let reporter = StubHealthAccessReporter(state: .notRequested)
        let model = makeModel(access: reporter)
        await model.load()

        // The user allowed everything on the sheet the request put up.
        reporter.state = Self.everythingReadable
        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .presentedSheet)
        XCTAssertEqual(reporter.requestCount, 1)
        XCTAssertTrue(model.health.isConnected)
    }

    /// The re-check is what makes the switch honest: the sheet does not report its answer,
    /// so a refusal is only visible in what became readable behind it.
    func testARefusedSheetLeavesTheSwitchOff() async {
        let reporter = StubHealthAccessReporter(state: .notRequested)
        let model = makeModel(access: reporter)
        await model.load()

        reporter.state = .requested(readable: [])
        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(reporter.requestCount, 1)
        XCTAssertFalse(model.health.isConnected)
        // Not `.needsHealthApp`: the sheet has only just been answered, and throwing the
        // user into another app on top of it is the re-prompt loop the skill rules out.
        XCTAssertEqual(outcome, .presentedSheet)
    }

    /// iOS shows the sheet once. After that the app cannot change anything and must send
    /// the user to the Health app instead of silently doing nothing.
    func testTappingAnAlreadyAskedRowDoesNotRequestAgain() async {
        let reporter = StubHealthAccessReporter(state: .requested(readable: []))
        let model = makeModel(access: reporter)
        await model.load()

        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .needsHealthApp)
        XCTAssertEqual(reporter.requestCount, 0)
    }

    /// Access given in the Health app while this screen was in the background. The tap
    /// re-checks before routing anywhere, so the user is not bounced out of the app to be
    /// told about something that has already happened.
    func testARecheckThatFindsAccessTurnsTheSwitchOnWithoutLeavingTheApp() async {
        let reporter = StubHealthAccessReporter(state: .requested(readable: []))
        let model = makeModel(access: reporter)
        await model.load()

        reporter.state = Self.everythingReadable
        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .connected)
        XCTAssertEqual(reporter.requestCount, 0)
        XCTAssertTrue(model.health.isConnected)
    }

    /// Turning a granted connection off is not something the app may do — only Health can
    /// revoke a grant — so the tap has to lead there rather than flip the switch.
    func testTurningAConnectedSwitchOffSendsTheUserToHealth() async {
        let reporter = StubHealthAccessReporter(state: Self.everythingReadable)
        let model = makeModel(access: reporter)
        await model.load()

        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .needsHealthApp)
        XCTAssertEqual(reporter.requestCount, 0)
        XCTAssertTrue(model.health.isConnected)
    }

    // MARK: - Check-in reminder row

    func testTheReminderSwitchIsOnWhenItIsWantedAndIOSWillDeliver() async {
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: true))

        await model.load()

        XCTAssertTrue(model.reminders.isOn)
        XCTAssertFalse(model.reminders.isBlockedBySystem)
    }

    /// The state the two facts exist for. The user asked for the reminder and iOS is not
    /// delivering it, so a switch showing the preference alone would sit there reading "on"
    /// for someone who has been getting nothing.
    func testTheReminderSwitchIsOffWhileIOSWillNotDeliver() async {
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: false))

        await model.load()

        XCTAssertTrue(model.reminders.isPreferred)
        XCTAssertFalse(model.reminders.isOn)
        XCTAssertTrue(model.reminders.isBlockedBySystem)
    }

    /// Off because the user turned it off is not the same state as off because iOS refused,
    /// and only one of the two has anywhere to send them.
    func testAReminderTurnedOffByTheUserIsNotBlockedByTheSystem() async {
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: true),
                              reminderPreferences: InMemoryReminderPreferenceStore(
                                  isCheckInReminderEnabled: false
                              ))

        await model.load()

        XCTAssertFalse(model.reminders.isOn)
        XCTAssertFalse(model.reminders.isBlockedBySystem)
    }

    // MARK: - Tapping the reminder switch

    /// The switch is not finished when the preference is written: a week of reminders is
    /// already sitting in the notification centre, and only a reconcile pass withdraws them.
    func testTurningTheReminderOffRecordsItAndReplans() async {
        let preferences = InMemoryReminderPreferenceStore()
        let replanned = Replanned()
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: true),
                              reminderPreferences: preferences,
                              onRemindersChanged: { await replanned.record() })
        await model.load()

        let outcome = await model.toggleReminder()
        let replanCount = await replanned.count

        XCTAssertEqual(outcome, .changed)
        XCTAssertFalse(preferences.isCheckInReminderEnabled())
        XCTAssertFalse(model.reminders.isOn)
        XCTAssertEqual(replanCount, 1)
    }

    /// Permission is already granted, so turning it back on is a preference and nothing else.
    /// Asking iOS again here would be a cross-process round trip for an answer already held.
    func testTurningTheReminderBackOnDoesNotAskIOSAgain() async {
        let deliverer = StubNotificationDeliverer(isAuthorized: true)
        let preferences = InMemoryReminderPreferenceStore(isCheckInReminderEnabled: false)
        let model = makeModel(notifications: deliverer, reminderPreferences: preferences)
        await model.load()

        let outcome = await model.toggleReminder()

        XCTAssertEqual(outcome, .changed)
        XCTAssertEqual(deliverer.requestCount, 0)
        XCTAssertTrue(model.reminders.isOn)
    }

    /// The switch has to hold the value the user chose for the whole of the pass that follows it
    /// — writing the preference, re-planning a week, re-reading the row. Reading `reminders`
    /// alone shows the state from before the tap for that stretch, so the switch springs back to
    /// where it was and then moves again, which reads as a control that dropped the tap.
    func testTheSwitchHoldsTheChosenValueUntilThePassHasFinished() async {
        let observer = ReminderSwitchObserver()
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: true),
                              reminderPreferences: InMemoryReminderPreferenceStore(),
                              onRemindersChanged: { [observer] in
                                  observer.midPassValue = observer.model?.isReminderOn
                              })
        observer.model = model
        await model.load()
        XCTAssertTrue(model.isReminderOn)

        await model.toggleReminder()

        // The one moment it used to be wrong: preference written, row not yet re-read.
        XCTAssertEqual(observer.midPassValue, false)
        XCTAssertFalse(model.isReminderOn)
        XCTAssertNil(model.pendingReminderValue)
    }

    /// The other side of the rule. When iOS has the last word there is nothing to be optimistic
    /// about, so the switch stays where it is instead of flicking on and back off while the app
    /// finds out that permission is still refused.
    func testTheSwitchDoesNotMoveWhileIOSIsBeingAsked() async {
        let observer = ReminderSwitchObserver()
        let model = makeModel(notifications: StubNotificationDeliverer(isAuthorized: false),
                              onRemindersChanged: { [observer] in
                                  observer.midPassValue = observer.model?.isReminderOn
                              })
        observer.model = model
        await model.load()

        let outcome = await model.toggleReminder()

        XCTAssertEqual(outcome, .needsSystemSettings)
        XCTAssertEqual(observer.midPassValue, false)
        XCTAssertFalse(model.isReminderOn)
    }

    /// Answered with a refusal at some point in the past. iOS will not show the prompt again,
    /// so the only honest thing left is to send the user to Settings.
    func testTappingABlockedSwitchRoutesToSettingsWhenIOSStillRefuses() async {
        let deliverer = StubNotificationDeliverer(isAuthorized: false)
        let model = makeModel(notifications: deliverer)
        await model.load()

        let outcome = await model.toggleReminder()

        XCTAssertEqual(outcome, .needsSystemSettings)
        XCTAssertEqual(deliverer.requestCount, 1)
        XCTAssertFalse(model.reminders.isOn)
    }

    func testTappingABlockedSwitchTurnsTheReminderOnWhenPermissionIsGranted() async {
        let deliverer = StubNotificationDeliverer(isAuthorized: false, grantsOnRequest: true)
        let model = makeModel(notifications: deliverer)
        await model.load()

        let outcome = await model.toggleReminder()

        XCTAssertEqual(outcome, .authorized)
        XCTAssertTrue(model.reminders.isOn)
    }

    /// The preference goes on before the prompt, not after it. Someone who had switched the
    /// reminder off and then tapped a blocked switch is asking for it back — and a grant that
    /// left the preference off would flip the switch straight back to off and read as a tap
    /// that did nothing.
    func testTappingABlockedSwitchWantsTheReminderOnEvenIfItHadBeenTurnedOff() async {
        let preferences = InMemoryReminderPreferenceStore(isCheckInReminderEnabled: false)
        let model = makeModel(
            notifications: StubNotificationDeliverer(isAuthorized: false, grantsOnRequest: true),
            reminderPreferences: preferences
        )
        await model.load()

        await model.toggleReminder()

        XCTAssertTrue(preferences.isCheckInReminderEnabled())
        XCTAssertTrue(model.reminders.isOn)
    }

    // MARK: - The daily count

    func testTheDailyCountReportsWhatTodayHasAlreadyCommittedTo() async throws {
        let log = InMemoryNotificationStore()
        // Scheduled counts as well as delivered: a reminder placed for this evening is spent
        // from the moment the row is written, which is what the cap promises.
        try await log.save(record(at: now.addingTimeInterval(-3600), state: .delivered))
        try await log.save(record(at: now.addingTimeInterval(3600), state: .scheduled))
        try await log.save(record(at: now.addingTimeInterval(1800), state: .suppressed))

        let model = makeModel(notificationLog: log)
        await model.load()

        XCTAssertEqual(model.reminders.countedToday, 2)
        XCTAssertEqual(model.reminders.dailyLimit, 3)
    }

    func testTheDailyCountLeavesYesterdayOutOfIt() async throws {
        let log = InMemoryNotificationStore()
        try await log.save(record(at: now.addingTimeInterval(-24 * 3600), state: .delivered))

        let model = makeModel(notificationLog: log)
        await model.load()

        XCTAssertEqual(model.reminders.countedToday, 0)
    }

    // MARK: - Erasing

    func testASuccessfulEraseHandsTheUserBackToOnboarding() async throws {
        let profiles = InMemoryUserProfileStore(UserProfile(displayName: "Olena",
                                                            onboardingCompletedAt: now))
        let restarted = Restarted()
        let model = makeModel(profiles: profiles, onDataErased: { await restarted.record() })
        await model.load()
        XCTAssertNotNil(model.profile)

        await model.eraseEverything()

        let restartCount = await restarted.count
        let remainingProfile = try await profiles.profile()

        XCTAssertEqual(model.eraseState, .idle)
        XCTAssertNil(model.profile)
        XCTAssertEqual(restartCount, 1)
        XCTAssertNil(remainingProfile)
    }

    /// Dropping someone into a fresh onboarding flow while part of their history is still
    /// on disk would rebuild a profile next to records it does not describe.
    func testAFailedEraseDoesNotRestartOnboarding() async {
        let restarted = Restarted()
        let model = makeModel(pressureLog: RefusingPressureSampleStore(),
                              onDataErased: { await restarted.record() })
        await model.load()

        await model.eraseEverything()

        let restartCount = await restarted.count

        XCTAssertEqual(model.eraseState, .failed(stores: [.pressureLog]))
        XCTAssertEqual(restartCount, 0)
    }

    func testDismissingTheFailureClearsIt() async {
        let model = makeModel(pressureLog: RefusingPressureSampleStore())
        await model.load()
        await model.eraseEverything()

        model.dismissEraseFailure()

        XCTAssertEqual(model.eraseState, .idle)
    }

    // MARK: - Helpers

    /// GMT rather than the device's, so which day a notification row falls in is the same
    /// wherever the tests run.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func record(at date: Date,
                        state: NotificationDeliveryState) -> NotificationRecord {
        NotificationRecord(kind: .checkInReminder,
                           language: .english,
                           scheduledFor: date,
                           state: state,
                           createdAt: date)
    }

    private func makeModel(access: any HealthAccessReporting
                               = StubHealthAccessReporter(state: SettingsModelTests.everythingReadable),
                           profiles: any UserProfileStore = InMemoryUserProfileStore(),
                           healthLog: any HealthSampleStore = InMemoryHealthSampleStore(),
                           pressureLog: any PressureSampleStore = InMemoryPressureSampleStore(),
                           notificationLog: any NotificationStore = InMemoryNotificationStore(),
                           notifications: any NotificationDelivering = StubNotificationDeliverer(),
                           reminderPreferences: any ReminderPreferenceStore
                               = InMemoryReminderPreferenceStore(),
                           locationAccess: any LocationAccessReporting
                               = StubLocationAccessReporter(state: .unavailable),
                           locationEpochs: any PressureLocationEpochStore
                               = InMemoryPressureLocationEpochStore(),
                           weatherPreferences: any WeatherKitPreferenceStore
                               = InMemoryWeatherKitPreferenceStore(),
                           onDataErased: @escaping () async -> Void = {},
                           onRemindersChanged: @escaping () async -> Void = {}) -> SettingsModel {
        let dependencies = SettingsDependencies(
            profileStore: profiles,
            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
            checkInStore: InMemoryCheckInStore(),
            healthLog: healthLog,
            pressureLog: pressureLog,
            locationEpochs: locationEpochs,
            weatherArchive: InMemoryWeatherForecastStore(),
            notificationLog: notificationLog,
            notifications: notifications,
            reminderPreferences: reminderPreferences,
            weatherPreferences: weatherPreferences,
            healthAccess: access,
            locationAccess: locationAccess
        )
        let now = now
        return SettingsModel(dependencies: dependencies,
                             calendar: calendar,
                             now: { now },
                             onDataErased: onDataErased,
                             onRemindersChanged: onRemindersChanged)
    }
}

// MARK: - Doubles

/// Reports whatever state it is set to, and counts requests so a test can prove the model
/// does not re-request once the sheet has already been answered.
private final class StubHealthAccessReporter: HealthAccessReporting, @unchecked Sendable {

    /// `@unchecked` with a lock rather than an actor: the protocol is `Sendable` and
    /// non-isolated, and a test double that has to be awaited to configure is harder to
    /// read than one guarded lock.
    private let lock = NSLock()
    private var _state: HealthAccessState
    private var _requestCount = 0

    init(state: HealthAccessState) {
        _state = state
    }

    var state: HealthAccessState {
        get { lock.withLock { _state } }
        set { lock.withLock { _state = newValue } }
    }

    var requestCount: Int { lock.withLock { _requestCount } }

    func accessState() async -> HealthAccessState { state }

    func requestAccess() async throws {
        lock.withLock { _requestCount += 1 }
    }
}

/// Reports whatever authorisation it is set to, and counts requests so a test can prove the
/// model does not go back to iOS for an answer it already has.
///
/// Locked and `@unchecked` for the reason `StubHealthAccessReporter` is.
private final class StubNotificationDeliverer: NotificationDelivering, @unchecked Sendable {

    private let lock = NSLock()
    private var _isAuthorized: Bool
    private let grantsOnRequest: Bool
    private var _requestCount = 0

    /// `grantsOnRequest` is the user tapping "Allow" on the prompt this call puts up. Left
    /// `false`, the deliverer stands for an authorisation that was refused at some point in the
    /// past — which iOS answers from its own record without showing anything.
    init(isAuthorized: Bool = true, grantsOnRequest: Bool = false) {
        _isAuthorized = isAuthorized
        self.grantsOnRequest = grantsOnRequest
    }

    var requestCount: Int { lock.withLock { _requestCount } }

    func isAuthorized() async -> Bool { lock.withLock { _isAuthorized } }

    func requestAuthorization() async -> Bool {
        lock.withLock {
            _requestCount += 1
            if grantsOnRequest { _isAuthorized = true }
            return _isAuthorized
        }
    }

    func schedule(_ request: NotificationDeliveryRequest) async throws {}
    func cancel(ids: [UUID]) async {}
    func pendingIdentifiers() async -> Set<UUID> { [] }
    func deliveredIdentifiers() async -> Set<UUID> { [] }
}

private struct StoreRefused: Error {}

private struct RefusingPressureSampleStore: PressureSampleStore {
    func save(_ samples: [PressureSample]) async throws { throw StoreRefused() }
    func samples(in range: Range<Date>) async throws -> [PressureSample] { throw StoreRefused() }
    func deleteSamples(before date: Date) async throws -> Int { throw StoreRefused() }
}

private actor Restarted {
    private(set) var count = 0
    func record() { count += 1 }
}

/// Carries the model into the replan callback, which has to be built before the model exists,
/// and holds what the switch was displaying at the moment that callback ran — after the
/// preference has been written and before the row has been re-read.
@MainActor
private final class ReminderSwitchObserver {
    var model: SettingsModel?
    var midPassValue: Bool?
}

private actor Replanned {
    private(set) var count = 0
    func record() { count += 1 }
}
