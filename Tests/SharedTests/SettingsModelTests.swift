import XCTest
@testable import Barosense

/// The settings list: what the Apple Health row reports, and what "delete my data" does.
@MainActor
final class SettingsModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Apple Health row

    /// The switch reflects the one authorisation fact iOS exposes for a read set: whether
    /// the user has been asked about all of it. Never "granted" — iOS does not say.
    func testTheSwitchIsOffUntilEveryTypeHasBeenAsked() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .notRequested))

        await model.load()

        XCTAssertEqual(model.health.access, .notRequested)
        XCTAssertFalse(model.health.isConnected)
        XCTAssertTrue(model.health.isInteractive)
    }

    func testTheSwitchIsOnOnceTheSheetHasBeenAnswered() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .requested))

        await model.load()

        XCTAssertTrue(model.health.isConnected)
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

        let model = makeModel(access: StubHealthAccessReporter(state: .requested), healthLog: log)
        await model.load()

        XCTAssertTrue(model.health.hasReadings)
    }

    /// Granted-but-empty and refused look identical from here. The model says only what it
    /// can observe: nothing has arrived.
    func testAnEmptyLogReportsNoReadingsWithoutClaimingARefusal() async {
        let model = makeModel(access: StubHealthAccessReporter(state: .requested))

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

        let model = makeModel(access: StubHealthAccessReporter(state: .requested), healthLog: log)
        await model.load()

        XCTAssertFalse(model.health.hasReadings)
    }

    func testTappingAnUnaskedRowPresentsTheSheetAndRereadsTheState() async {
        let reporter = StubHealthAccessReporter(state: .notRequested)
        let model = makeModel(access: reporter)
        await model.load()

        // What the sheet moves to, whatever the user answered.
        reporter.state = .requested
        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .presentedSheet)
        XCTAssertEqual(reporter.requestCount, 1)
        XCTAssertTrue(model.health.isConnected)
    }

    /// iOS shows the sheet once. After that the app cannot change anything and must send
    /// the user to the Health app instead of silently doing nothing.
    func testTappingAnAlreadyAskedRowDoesNotRequestAgain() async {
        let reporter = StubHealthAccessReporter(state: .requested)
        let model = makeModel(access: reporter)
        await model.load()

        let outcome = await model.toggleHealthAccess()

        XCTAssertEqual(outcome, .needsHealthApp)
        XCTAssertEqual(reporter.requestCount, 0)
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

    private func makeModel(access: any HealthAccessReporting = StubHealthAccessReporter(state: .requested),
                           profiles: any UserProfileStore = InMemoryUserProfileStore(),
                           healthLog: any HealthSampleStore = InMemoryHealthSampleStore(),
                           pressureLog: any PressureSampleStore = InMemoryPressureSampleStore(),
                           onDataErased: @escaping () async -> Void = {}) -> SettingsModel {
        let dependencies = SettingsDependencies(
            profileStore: profiles,
            tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
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
