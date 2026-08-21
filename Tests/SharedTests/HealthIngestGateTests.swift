import XCTest
@testable import Barosense

/// What "delete my data" has to survive.
///
/// `BarosenseDataEraser` empties the Health log, and until the gate existed nothing told
/// the ingest side: the HealthKit observers stayed registered and the next foreground
/// activation pulled `refreshLookback` — seven days — straight back in. The alert said the
/// readings were gone; minutes later they were not.
@MainActor
final class HealthIngestGateTests: XCTestCase {

    /// A launch that lands in onboarding writes nothing. This is the post-erase state as
    /// well as the fresh install: after an erase there is no profile, so the app is back
    /// in onboarding and stays closed until the flow is finished again.
    func testAClosedGateWritesNothingToTheLog() async {
        let log = InMemoryHealthSampleStore()
        let controller = makeController(log: log)

        await controller.refreshLog(lookback: .refreshLookback)

        let stored = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertTrue(stored.isEmpty)
    }

    /// Onboarding finished: ingest opens and the pull that was suppressed happens.
    func testAnOpenGateWritesToTheLog() async {
        let log = InMemoryHealthSampleStore()
        let controller = makeController(log: log)

        await controller.setEnabled(true)
        await controller.refreshLog(lookback: .refreshLookback)

        let stored = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertEqual(stored.count, 1)
    }

    /// The erase itself: the user was past onboarding, wiped everything, and is handed back
    /// to the flow. Every later refresh has to stay silent — that is the bug this closes.
    func testClosingTheGateStopsTheLogRefillingAfterAnErase() async {
        let log = InMemoryHealthSampleStore()
        let controller = makeController(log: log)

        await controller.setEnabled(true)
        await controller.refreshLog(lookback: .refreshLookback)
        let beforeErase = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertFalse(beforeErase.isEmpty)

        // Stands in for `BarosenseDataEraser` plus the phase change it triggers.
        await log.deleteSamples(before: .distantFuture)
        await controller.setEnabled(false)

        await controller.refreshLog(lookback: .refreshLookback)
        await controller.refreshLog(lookback: .backgroundLookback)

        let stored = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertTrue(stored.isEmpty, "an erased log must not refill while onboarding is on screen")
    }

    /// The gate is the ingest side of the promise, not a preference: nothing in the app may
    /// leave it open by default, because the default is what a post-erase relaunch gets.
    func testTheGateStartsClosed() async {
        let gate = HealthIngestGate()

        let isOpen = await gate.isOpen

        XCTAssertFalse(isOpen)
    }

    /// The path the bug report actually names: HealthKit relaunches the app, the observer
    /// registered at launch fires, and the coalescer runs the controller's own work closure.
    ///
    /// The tests above reach the gate through `refreshLog`, which is a different call site —
    /// this one goes through the wiring `start()` builds. Both halves are asserted, because
    /// a closed-gate test alone would also pass if the observer had never been registered.
    func testAnObserverFiringRefillsTheLogOnlyWhileIngestIsOpen() async {
        let log = InMemoryHealthSampleStore()
        let observer = ManualHealthChangeObserver()
        let controller = makeController(log: log, changeObserver: observer)

        await controller.setEnabled(true)
        controller.start()
        await observer.waitUntilRegistered()

        await log.deleteSamples(before: .distantFuture)
        await observer.fire()
        await controller.backgroundCoalescer.waitForPendingWork()
        let whileOpen = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertEqual(whileOpen.count, 1, "the observer path must reach the log while ingest is open")

        // The erase, and the phase change that follows it.
        await log.deleteSamples(before: .distantFuture)
        await controller.setEnabled(false)

        // The observer is still registered — deliberately, see `setEnabled` — so the gate
        // is the only thing standing between this firing and a refilled log.
        await observer.fire()
        await controller.backgroundCoalescer.waitForPendingWork()

        let afterErase = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertTrue(afterErase.isEmpty, "an observer firing after an erase must not refill the log")
    }

    /// The Now screen refreshes through a recorder of its own, without going through the
    /// controller at all. It has to be gated too.
    ///
    /// Today navigation keeps that screen off the display until onboarding is finished, so
    /// nothing reaches this path after an erase — but that is a fact about routing, not a
    /// guarantee about writes, and the next screen that reads Health would not inherit it.
    func testARefreshTakenOutsideTheControllerIsGatedToo() async throws {
        let log = InMemoryHealthSampleStore()
        let recorder = HealthSampleRecorder(reader: OneReadingHealthDataReader(), log: log)

        let snapshot = try await recorder.refresh()

        XCTAssertEqual(snapshot.restingHeartRateBPM, 58,
                       "a closed gate suppresses the write, not the reading behind the card")
        let stored = await log.samples(of: .restingHeartRate, in: everySecond)
        XCTAssertTrue(stored.isEmpty)
    }

    // MARK: - Helpers

    private var everySecond: Range<Date> { Date.distantPast..<Date.distantFuture }

    private func makeController(
        log: any HealthSampleStore,
        changeObserver: any HealthChangeObserving = NoOpHealthChangeObserver()
    ) -> HealthIngestController {
        HealthIngestController(
            recorder: HealthSampleRecorder(reader: OneReadingHealthDataReader(), log: log),
            changeObserver: changeObserver
        )
    }
}

/// Stands in for `HealthKitChangeObserver`: keeps the controller's own `onChange` closure
/// so a test can fire it the way a background wake would.
private actor ManualHealthChangeObserver: HealthChangeObserving {

    private var onChange: (@Sendable () async -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func start(onChange: @escaping @Sendable () async -> Void) async {
        self.onChange = onChange
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }

    /// Suspends until the controller has registered. `start()` hands off to a task, so a
    /// test that fired immediately would be racing it rather than testing it.
    func waitUntilRegistered() async {
        guard onChange == nil else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func fire() async {
        await onChange?()
    }
}

/// Returns exactly one resting-heart-rate reading, so "did anything reach the log" is a
/// count and not a judgement call.
private struct OneReadingHealthDataReader: HealthDataReader {

    func requestAuthorization() async throws {}

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        guard kind == .restingHeartRate else { return [] }
        // Dated from the window the recorder actually asked for. `refreshLog` does not
        // take an `asOf`, so the window is anchored to the wall clock — a fixed instant
        // here would fall outside it and the test would pass for the wrong reason.
        let instant = range.upperBound.addingTimeInterval(-1)
        // A fixed id, so a second read replaces the row rather than adding one — the same
        // idempotence the real store relies on.
        return [HealthSample(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                             start: instant,
                             end: instant,
                             value: .restingHeartRateBPM(58))]
    }
}
