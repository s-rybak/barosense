import Foundation

/// Reads the Health store, writes what it read into the training log, and returns what the
/// screen should show.
///
/// One pass does both jobs deliberately. The alternative — a display path that queries
/// HealthKit and a separate logging path that queries it again — gives the model a
/// history that was never quite what the user saw, and doubles the number of reads for
/// nothing.
///
/// A `struct`: both dependencies are `Sendable` protocols and there is no state to guard.
struct HealthSampleRecorder: Sendable {

    private let reader: any HealthDataReader
    private let log: any HealthSampleStore
    private let lookback: HealthMetricsWindow

    init(reader: any HealthDataReader,
         log: any HealthSampleStore,
         lookback: HealthMetricsWindow = .refreshLookback) {
        self.reader = reader
        self.log = log
        self.lookback = lookback
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
    /// showing the two metrics that are there.
    @discardableResult
    func refresh(asOf now: Date = .now,
                 lookback lookbackWindow: HealthMetricsWindow? = nil) async throws -> HealthMetricsSnapshot {
        let window = (lookbackWindow ?? lookback).trailing(from: now)
        let range = window.lowerBound..<window.upperBound.addingTimeInterval(1)

        var collected: [HealthSample] = []
        var failures: [any Error] = []

        for kind in HealthMetricKind.allCases {
            do {
                collected += try await reader.samples(of: kind, in: range)
            } catch {
                failures.append(error)
            }
        }

        // Every kind failed — that is the device saying no, not a thin data day. Let it
        // surface so the screen can say something other than "no readings".
        if collected.isEmpty, let failure = failures.first {
            throw failure
        }

        try await log.save(collected)

        return HealthMetricsSnapshot.make(from: collected, asOf: now)
    }
}
