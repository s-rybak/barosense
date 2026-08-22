import Foundation

/// Reads the Health store, writes what it read into the training log, and returns what the
/// screen should show.
///
/// One pass does both jobs deliberately. The alternative — a display path that queries
/// HealthKit and a separate logging path that queries it again — gives the model a
/// history that was never quite what the user saw, and doubles the number of reads for
/// nothing.
///
/// A `struct`: the dependencies are `Sendable` protocols and there is no state to guard —
/// the one piece of mutable state involved lives in `gate`, which is an actor.
struct HealthSampleRecorder: Sendable {

    private let reader: any HealthDataReader
    private let log: any HealthSampleStore
    private let lookback: HealthMetricsWindow

    /// Whether this recorder may write to the log.
    ///
    /// Held by the type that writes rather than by `HealthIngestController`, because the
    /// controller is not the only caller — the Now screen refreshes through this same
    /// recorder — and an invariant enforced at some of the call sites is not an invariant.
    /// `HealthIngestController` opens and closes it; see `HealthIngestGate`.
    ///
    /// Closed on creation, so a recorder nobody opens reads and displays but records
    /// nothing. That is the direction a promise about erased data has to fail in.
    let gate: HealthIngestGate

    init(reader: any HealthDataReader,
         log: any HealthSampleStore,
         lookback: HealthMetricsWindow = .refreshLookback,
         gate: HealthIngestGate = HealthIngestGate()) {
        self.reader = reader
        self.log = log
        self.lookback = lookback
        self.gate = gate
    }

    /// Shows the user the Health sheet for the read set.
    ///
    /// Call once per launch, not per refresh: iOS presents the sheet only the first time,
    /// but every call is still an XPC round trip. It tells you nothing about the outcome
    /// either way — `refresh` returning an empty snapshot is the only observable signal,
    /// and it means "denied or no data", which the app must handle identically.
    func authorize() async throws {
        try await reader.requestAuthorization()
    }

    /// Pulls a lookback window from the Health store, appends it to the log, and builds
    /// the snapshot from what was read.
    ///
    /// Safe to call repeatedly. Windows overlap by design and rows carry HealthKit's own
    /// identifiers, so a re-read replaces rows instead of duplicating them — which is what
    /// lets the refresh be dumb and stateless rather than track an anchor it has nowhere
    /// durable to keep.
    ///
    /// `lookback` overrides the recorder's default for that call. Foreground paths keep
    /// the 7 d default; background delivery uses
    /// `HealthMetricsWindow.backgroundLookback` so an hourly wake does not re-read a week.
    ///
    /// A failure on one kind does not sink the others: blood oxygen is absent on most
    /// hardware, and losing the whole row because of it would be a worse answer than
    /// showing the metrics that are there.
    @discardableResult
    func refresh(asOf now: Date = .now,
                 lookback lookbackWindow: HealthMetricsWindow? = nil) async throws -> HealthMetricsSnapshot {
        let window = (lookbackWindow ?? lookback).trailing(from: now)
        let range = window.lowerBound..<window.upperBound.addingTimeInterval(1)

        var collected: [HealthSample] = []
        var failures: [any Error] = []
        var successfulKindCount = 0

        for kind in HealthMetricKind.allCases {
            try Task.checkCancellation()
            do {
                let samples = try await reader.samples(of: kind,
                                                       in: Self.range(for: kind,
                                                                      within: range,
                                                                      asOf: now))
                try Task.checkCancellation()
                collected += samples
                successfulKindCount += 1
            } catch is CancellationError {
                // Cancellation is a control-flow request, not one unavailable Health kind.
                // Swallowing it here would run the remaining queries and could write their
                // samples after the check-in deadline had already moved on.
                throw CancellationError()
            } catch {
                failures.append(error)
            }
        }

        // Every kind failed — that is the device saying no, not a thin data day. Let it
        // surface so the screen can say something other than "no readings".
        if successfulKindCount == 0, let failure = failures.first {
            throw failure
        }

        // Only what the model consumes reaches the log. `.heartRate` is read for the Now
        // card and dropped here — see `HealthMetricKind.isLoggedForTraining` for the row
        // count that buys. The snapshot below is built from everything that was read, so
        // the card still gets its figure.
        //
        // The gate suppresses this write and nothing else. Reading for display is not
        // accumulating history, and a screen that went blank while the gate was closed
        // would be reporting a state the user never asked about.
        try Task.checkCancellation()
        if await gate.isOpen {
            try Task.checkCancellation()
            try await log.save(collected.filter(\.kind.isLoggedForTraining))
        }

        return HealthMetricsSnapshot.make(from: collected, asOf: now)
    }

    /// One kind's slice of the refresh window.
    ///
    /// Identical to the caller's window for every kind the log keeps. A display-only kind
    /// narrows it to its own staleness bound: reading further back would fetch samples
    /// that cannot appear anywhere and are not kept.
    private static func range(for kind: HealthMetricKind,
                              within range: Range<Date>,
                              asOf now: Date) -> Range<Date> {
        guard let cap = kind.readLookbackCap else { return range }
        let earliest = max(range.lowerBound, now.addingTimeInterval(-cap.seconds))
        return earliest..<range.upperBound
    }
}
