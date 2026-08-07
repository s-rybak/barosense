import Foundation

/// How often the barometer is allowed to run, in one place.
///
/// Every number here is a battery debit and has to be arguable on its own. They live
/// together rather than at their call sites so the total is readable, and so the
/// kill-switch is not something a reviewer has to go looking for.
///
/// **The phone is the sampling device.** The watch neither reads its barometer nor
/// schedules a wake, so nothing here is charged to the watch battery
/// (`.claude/skills/watchos_budget/SKILL.md` has nothing left to budget for this feature).
enum PressureSamplingPolicy {

    /// Floor between two readings taken by the same running process.
    ///
    /// Fifteen minutes. The feature registry asks for ≥1 sample/h
    /// (`.claude/context/ml-spec.md` §2.1), so this is 4× that ceiling — tight enough that
    /// a pressure change during an afternoon of ordinary phone use is recorded with real
    /// resolution, loose enough that unlocking the phone forty times an hour still costs at
    /// most four sensor starts.
    ///
    /// Also the finest bucket any chart range uses. A grid finer than the sampling floor
    /// would average nothing.
    static let minimumIntervalSeconds: TimeInterval = 15 * 60

    /// Identifier of the iOS background-refresh task.
    ///
    /// Must also appear in `BGTaskSchedulerPermittedIdentifiers` in the target's Info.plist
    /// — a submission with an identifier the plist does not list throws
    /// `BGTaskSchedulerErrorCodeNotPermitted` and the chain silently never starts.
    static let backgroundRefreshIdentifier = "com.barosense.pressure.refresh"

    /// What the app *asks* iOS for between background wakes.
    ///
    /// A request, and a weak one. `BGAppRefreshTaskRequest.earliestBeginDate` sets a floor,
    /// never a cadence: iOS decides from usage history, charge state and Low Power Mode, and
    /// for most apps grants a handful of wakes a day rather than 96. Asking for 15 min
    /// simply means the app is eligible as early as possible and never asks for more.
    ///
    /// The realistic coverage story is therefore foreground-first — a phone picked up
    /// through the day covers most 15-minute slots of waking hours — with background wakes
    /// filling what they can and the overnight gap left honest. The coverage features exist
    /// to tell the model exactly that.
    static let backgroundRefreshIntervalSeconds: TimeInterval = 15 * 60

    /// Kill-switch for background sampling.
    ///
    /// Cost is **unmeasured on device**. Set to `false` if Instruments shows unacceptable
    /// drain; foreground sampling on app activation remains as the backstop, and the
    /// pipeline already tolerates the wider gaps that would follow.
    static let isBackgroundRefreshEnabled = true
}

/// How long the barometer log is kept.
///
/// A separate policy from `PressureSamplingPolicy` because it answers the opposite
/// question: that one decides what goes in, this one decides what stops being worth
/// keeping. Both govern the same rows — the training history — so both are deliberate.
enum PressureRetentionPolicy {

    /// Five years.
    ///
    /// The bias is toward keeping: these rows are what the model is fitted on, a personal
    /// response to weather is plausibly seasonal, and five years is five passes over the
    /// annual cycle. Nothing in the validation protocol asks for more.
    ///
    /// It is a ceiling, not a target. At one row per 15 min the table gains ~2 900 rows a
    /// month, so five years is ~175 000 rows — tens of MB with the timestamp index. The
    /// horizon exists so the file cannot grow without bound on a device the user never
    /// reinstalls on, not because year six would be expensive.
    static let maximumHistoryYears = 5

    /// How often a running process re-checks the horizon.
    ///
    /// Daily. The cutoff moves by one day per day, so a finer interval deletes nothing and
    /// only spends a query; a coarser one lets a long-lived process drift past the horizon.
    static let pruneIntervalSeconds: TimeInterval = 24 * 3600

    /// Oldest timestamp still worth keeping. Rows strictly older than this are dropped.
    ///
    /// Calendar arithmetic rather than `now − 5 × 365 × 86 400`, so the horizon lands on the
    /// same date every year instead of creeping forward by a day per leap year.
    ///
    /// The fallback is `distantPast`, not `now`: if the arithmetic ever fails, a pass that
    /// deletes nothing is a bug someone can fix later, and a pass that deletes the entire
    /// training history is not.
    static func cutoff(asOf now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .year, value: -maximumHistoryYears, to: now) ?? .distantPast
    }
}

/// Takes one barometer reading and writes it to the local log.
///
/// The sibling of `HealthSampleRecorder`, and deliberately the same shape: what the chart
/// draws and what the model is fitted on are the same rows rather than two nearly-identical
/// histories.
///
/// Telling the watch what to show is **not** this type's job — that is
/// `PressureDisplayLink`, driven by the phone's controller. Keeping the two apart is what
/// lets the display side publish, throttle or fail without any of it reaching the log.
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

    /// When this instance last checked the retention horizon. In memory for the same reason
    /// as `lastRecordedAt`, and with the same consequence: a fresh process prunes on its
    /// first reading. That is the cadence wanted — the horizon only moves by a day a day,
    /// and every launch checking once costs one indexed query that usually matches nothing.
    private var lastPrunedAt: Date?

    init(source: any PressureSource,
         log: any PressureSampleStore,
         minimumInterval: TimeInterval = PressureSamplingPolicy.minimumIntervalSeconds) {
        self.source = source
        self.log = log
        self.minimumInterval = minimumInterval
    }

    /// Whether this device has a usable barometer. `nonisolated` because the answer is a
    /// device fact behind a `let`, and the chart's empty state has to word itself
    /// synchronously — an iPad has no barometer, and "waiting for the first reading" would
    /// be a wait that never ends.
    nonisolated var isAvailable: Bool { source.isAvailable }

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

        await pruneExpiredHistory(asOf: now)

        return sample
    }

    /// Drops rows past `PressureRetentionPolicy`'s horizon, at most once per prune interval.
    ///
    /// Hung off the write path rather than given its own timer or background task: the log
    /// only grows when a reading lands, so the one moment retention can possibly be needed
    /// is just after one did. A wake scheduled purely to delete rows would be a battery
    /// debit with nothing to show for it.
    ///
    /// Failure is swallowed. The reading is already durable at this point, and a retention
    /// pass that could not run costs disk space, not data — throwing from here would turn a
    /// housekeeping failure into a lost measurement, which is the wrong way round. The clock
    /// is reset before the attempt, so a store that fails every time logs once a day rather
    /// than on every reading.
    private func pruneExpiredHistory(asOf now: Date) async {
        if let lastPrunedAt,
           now.timeIntervalSince(lastPrunedAt) < PressureRetentionPolicy.pruneIntervalSeconds {
            return
        }
        lastPrunedAt = now

        do {
            let dropped = try await log.deleteSamples(before: PressureRetentionPolicy.cutoff(asOf: now))
            if dropped > 0 {
                BarosenseLog.persistence.info(
                    "pressure retention dropped \(dropped, privacy: .public) rows past the horizon"
                )
            }
        } catch {
            BarosenseLog.persistence.error(
                "pressure retention failed: \(String(describing: error), privacy: .public)"
            )
        }
    }

    /// Samples whose timestamp falls in the trailing `window`, ascending.
    ///
    /// Reading through the recorder rather than handing the store to the view keeps one
    /// object in front of the log, which is what lets the chart's view model stay ignorant
    /// of how the rows got there.
    func samples(trailing window: TimeInterval, asOf now: Date = .now) async throws -> [PressureSample] {
        try await log.samples(in: now.addingTimeInterval(-window)..<now.addingTimeInterval(1))
    }
}
