import XCTest
@testable import Barosense

/// The settings list: what the Apple Health row reports, and what "delete my data" does.
@MainActor
final class SettingsModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Every type in the read set proven readable — the only state the switch may be on in.
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

    /// Partial access is not access. One unreadable type is enough to keep it off, and the
    /// screen is told which one so its caption does not have to guess.
    func testTheSwitchIsOffWhileAnyTypeCannotBeRead() async {
        let reporter = StubHealthAccessReporter(
            state: .requested(readable: [.restingHeartRate, .asleep])
        )
        let model = makeModel(access: reporter)

        await model.load()

        XCTAssertFalse(model.health.isConnected)
        XCTAssertFalse(model.health.hasNothingReadable)
        XCTAssertEqual(model.health.unreadableTypes, [.oxygenSaturation])
    }

    func testTheSwitchIsOnOnlyWhenEveryTypeCanBeRead() async {
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

    private func makeModel(access: any HealthAccessReporting
                               = StubHealthAccessReporter(state: SettingsModelTests.everythingReadable),
                           profiles: any UserProfileStore = InMemoryUserProfileStore(),
                           healthLog: any HealthSampleStore = InMemoryHealthSampleStore(),
                           pressureLog: any PressureSampleStore = InMemoryPressureSampleStore(),
                           onDataErased: @escaping () async -> Void = {}) -> SettingsModel {
        let dependencies = SettingsDependencies(
            profileStore: profiles,
            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
            checkInStore: InMemoryCheckInStore(),
            healthLog: healthLog,
            pressureLog: pressureLog,
            healthAccess: access
        )
        let now = now
        return SettingsModel(dependencies: dependencies,
                             now: { now },
                             onDataErased: onDataErased)
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
