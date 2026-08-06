import Foundation

/// Kill-switch for HealthKit background delivery.
///
/// Cost is **unmeasured on device** (see `.claude/context/ml-spec.md` → Health ingest).
/// Set to `false` before shipping if Instruments shows unacceptable drain; foreground
/// scene-active ingest remains as the backstop.
enum HealthBackgroundDelivery {
    static let isEnabled = true
}

/// Long-lived observer over the Health store.
///
/// Declared next to `HealthDataReader` so the ingest controller and its tests never see
/// `HKObserverQuery`. Production wires `HealthKitChangeObserver`; tests wire a stub that
/// fires `onChange` on demand.
protocol HealthChangeObserving: Sendable {

    /// Registers observers once. Safe to call repeatedly — subsequent calls are no-ops.
    ///
    /// Must run at process launch (composition root), not from a view: HealthKit delivers
    /// background updates by relaunching the app and expects the queries to already exist.
    /// `onChange` may be invoked on an arbitrary executor; the callee decides isolation.
    func start(onChange: @escaping @Sendable () async -> Void) async
}

/// Used when background delivery is flagged off, and in previews.
struct NoOpHealthChangeObserver: HealthChangeObserving {
    func start(onChange: @escaping @Sendable () async -> Void) async {}
}

/// Collapses a burst of observer firings into one ingest pull.
///
/// Three types can wake within the same second (a night of sleep stages lands as many
/// rows). Without a coalesce, that is three overlapping 48 h HealthKit reads for one
/// logical update. The delay is short enough not to matter for training and long enough
/// to absorb a staged sleep write.
actor HealthIngestSignalCoalescer {

    private let delayNanoseconds: UInt64
    private let perform: @Sendable () async -> Void
    private var pending: Task<Void, Never>?

    /// Default 750 ms — enough to merge the three type-observers, short vs. hourly cadence.
    init(delayNanoseconds: UInt64 = 750_000_000,
         perform: @escaping @Sendable () async -> Void) {
        self.delayNanoseconds = delayNanoseconds
        self.perform = perform
    }

    func signal() {
        pending?.cancel()
        pending = Task {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
            guard !Task.isCancelled else { return }
            await perform()
        }
    }

    /// Waits for the currently scheduled batch so tests can synchronise with the work
    /// itself instead of guessing how much wall-clock delay is sufficient.
    func waitForPendingWork() async {
        let task = pending
        await task?.value
    }
}
