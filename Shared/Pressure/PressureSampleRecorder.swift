import Foundation

/// How often the barometer is allowed to run, in one place.
///
/// Every number here is a battery debit and has to be arguable on its own
/// (`.claude/skills/watchos_budget/SKILL.md`). They live together rather than at their call
/// sites so the total is readable, and so the kill-switch is not something a reviewer has
/// to go looking for.
enum PressureSamplingPolicy {

    /// Floor between two readings taken by the same running process.
    ///
    /// The feature registry asks for ≥1 sample/h (`.claude/context/ml-spec.md` §2.1), so ten
    /// minutes is already 6× that ceiling — generous enough that opening the app after a
    /// walk records the change, tight enough that flipping in and out of the app cannot
    /// start the sensor dozens of times an hour.
    static let minimumIntervalSeconds: TimeInterval = 10 * 60

    /// Target gap between background wakes on the watch.
    ///
    /// One hour is the cadence the feature registry needs and not a round number chosen for
    /// comfort: `pressureHPa` requires a sample within 90 minutes of the moment a feature is
    /// computed, so a two-hour target would put the common case outside its own tolerance.
    /// The system decides the real cadence and will often give less — that is expected, and
    /// the coverage features exist to record it.
    static let backgroundRefreshIntervalSeconds: TimeInterval = 3600

    /// Kill-switch for watch background sampling.
    ///
    /// Cost is **unmeasured on device**. Set to `false` before shipping if Instruments shows
    /// unacceptable drain; foreground sampling on app activation remains as the backstop,
    /// and the pipeline already tolerates the wider gaps that would follow.
    static let isBackgroundRefreshEnabled = true
}

/// Takes one barometer reading and writes it to the local log.
///
/// The sibling of `HealthSampleRecorder`, and deliberately the same shape: what the chart
/// draws and what the model is fitted on are the same rows rather than two nearly-identical
/// histories.
///
/// Shipping those rows to the other device is **not** this type's job — that is
/// `PressureSampleUplink`, driven by the platform controller. Keeping the two apart is what
/// lets the watch decide to resend a whole window while the recorder stays a one-shot.
///
/// An `actor` because it carries one piece of mutable state — when it last sampled — and
/// that state is the rate limit. A `struct` would push the limit onto every caller, and a
/// caller that forgot it would run the barometer on every scene activation.
actor PressureSampleRecorder {

    private let source: any PressureSource
    private let log: any PressureSampleStore
    private let minimumInterval: TimeInterval

    /// When this instance last stored a reading. In memory on purpose: it exists to damp a
    /// burst of foreground activations inside one session, not to enforce a cadence across
    /// launches. A background wake starts a fresh process and should always sample.
    private var lastRecordedAt: Date?

    init(source: any PressureSource,
         log: any PressureSampleStore,
         minimumInterval: TimeInterval = PressureSamplingPolicy.minimumIntervalSeconds) {
        self.source = source
        self.log = log
        self.minimumInterval = minimumInterval
    }

    var isAvailable: Bool { source.isAvailable }

    /// Reads the barometer once and persists what it read.
    ///
    /// Returns `nil` when the rate limit declined to sample — an ordinary outcome, not a
    /// failure. Throws when the sensor refused or the reading was not usable.
    ///
    /// The reading is stored **raw**. Altitude contamination is real and large — 10 m of
    /// stairs moves station pressure about as much as a meaningful six-hour weather change
    /// — but it is rejected at feature time, on the series, where the neighbouring samples
    /// that identify it are visible (`.claude/context/ml-spec.md` §3). Discarding it here
    /// would delete the evidence and leave a hole the coverage features could not explain.
    @discardableResult
    func record(asOf now: Date = .now) async throws -> PressureSample? {
        if let lastRecordedAt, now.timeIntervalSince(lastRecordedAt) < minimumInterval {
            return nil
        }

        let pressure = try await source.currentPressure()
        guard pressure.isPlausible else {
            throw PressureSourceError.implausibleReading(hectopascals: pressure.hectopascals)
        }

        let sample = PressureSample(timestamp: now, pressure: pressure)
        try await log.save([sample])
        lastRecordedAt = now

        return sample
    }

    /// Stores rows that arrived from somewhere other than this device's sensor.
    ///
    /// The receiving end of the uplink. Separate from `record` because nothing here touches
    /// the barometer or the rate limit: these readings were already taken, already gated,
    /// and carry the identifier the sending device gave them, so a redelivery collapses
    /// onto one row instead of multiplying into training data.
    func ingest(_ samples: [PressureSample]) async throws {
        try await log.save(samples.filter { $0.pressure.isPlausible })
    }

    /// Samples whose timestamp falls in the trailing `window`, ascending.
    ///
    /// Reading through the recorder rather than handing the store to the view keeps one
    /// object in front of the log, which is what lets the chart's view model stay ignorant
    /// of whether the rows came from this device or arrived over the uplink.
    func samples(trailing window: TimeInterval, asOf now: Date = .now) async throws -> [PressureSample] {
        try await log.samples(in: now.addingTimeInterval(-window)..<now.addingTimeInterval(1))
    }
}
