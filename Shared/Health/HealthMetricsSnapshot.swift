import Foundation

/// What the Health card row shows at one instant.
///
/// Every field is optional and absence is the ordinary case, not a failure: read denial is
/// indistinguishable from an empty Health store, blood oxygen depends on the watch model
/// and the region, and a user with no watch has none of it. Nothing here may be turned
/// into a blocking state.
struct HealthMetricsSnapshot: Hashable, Sendable {

    /// Beats per minute, the most recent reading the watch took inside the staleness
    /// bound. This is what the Now screen's pulse card shows — a figure from minutes ago,
    /// not `restingHeartRateBPM`, which is a daily aggregate HealthKit publishes hours
    /// after the day it describes and which read as stale on a screen labelled "now".
    let heartRateBPM: Double?

    /// Beats per minute, most recent reading inside the staleness bound.
    ///
    /// HealthKit's daily resting aggregate, not a measurement. Kept because it is what the
    /// model consumes (`.claude/context/ml-spec.md` §2.3) and it comes out of the same read
    /// the snapshot is built from; nothing on screen shows it.
    let restingHeartRateBPM: Double?

    /// Fraction of 0...1, most recent reading inside the staleness bound.
    let oxygenSaturationFraction: Double?

    /// Hours asleep across the trailing window, overlapping intervals counted once.
    let asleepHours: Double?

    static let empty = HealthMetricsSnapshot(heartRateBPM: nil,
                                             restingHeartRateBPM: nil,
                                             oxygenSaturationFraction: nil,
                                             asleepHours: nil)

    var isEmpty: Bool {
        heartRateBPM == nil
            && restingHeartRateBPM == nil
            && oxygenSaturationFraction == nil
            && asleepHours == nil
    }
}

extension HealthMetricsSnapshot {

    /// Builds the row from raw stored samples.
    ///
    /// Pure and synchronous on purpose: this is the piece that decides what a number on
    /// screen means, so it has to be exercisable from a test with a handful of literals
    /// and no Health store anywhere.
    ///
    /// `samples` may hold every kind at once and need not be sorted.
    static func make(from samples: [HealthSample], asOf now: Date) -> HealthMetricsSnapshot {
        HealthMetricsSnapshot(
            heartRateBPM: latestHeartRate(in: samples, asOf: now),
            restingHeartRateBPM: latestRestingHeartRate(in: samples, asOf: now),
            oxygenSaturationFraction: latestSaturation(in: samples, asOf: now),
            asleepHours: asleepHours(in: samples, asOf: now)
        )
    }

    private static func latestHeartRate(in samples: [HealthSample], asOf now: Date) -> Double? {
        latest(.heartRate, in: samples, within: .heartRate, asOf: now) { sample in
            if case .heartRateBPM(let bpm) = sample.value { bpm } else { nil }
        }
    }

    private static func latestRestingHeartRate(in samples: [HealthSample], asOf now: Date) -> Double? {
        latest(.restingHeartRate, in: samples, within: .restingHeartRate, asOf: now) { sample in
            if case .restingHeartRateBPM(let bpm) = sample.value { bpm } else { nil }
        }
    }

    /// Newest reading of one kind inside its staleness window.
    ///
    /// Filters on `kind` before taking the maximum, which the two heart-rate metrics made
    /// necessary: `samples` now carries two families measured in bpm, and a `max` over all
    /// of them would hand a resting aggregate to the pulse card whenever it happened to be
    /// the later row.
    private static func latest(_ kind: HealthMetricKind,
                               in samples: [HealthSample],
                               within staleness: HealthMetricsWindow,
                               asOf now: Date,
                               value: (HealthSample) -> Double?) -> Double? {
        let window = staleness.trailing(from: now)
        return samples
            .filter { $0.kind == kind && window.contains($0.end) }
            .max { $0.end < $1.end }
            .flatMap(value)
    }

    private static func latestSaturation(in samples: [HealthSample], asOf now: Date) -> Double? {
        latest(.oxygenSaturation, in: samples, within: .oxygenSaturation, asOf: now) { sample in
            if case .oxygenSaturationFraction(let fraction) = sample.value { fraction } else { nil }
        }
    }

    /// Total time asleep in the trailing window, with overlaps counted once.
    ///
    /// The union matters. A phone and a watch both write sleep, and the same night can
    /// arrive twice from two sources; summing the intervals naively reports fourteen hours
    /// for a seven-hour night. Staged segments from one source also touch end to end, so
    /// the merge has to count "ends exactly where the next begins" as one stretch rather
    /// than as two.
    ///
    /// Selection is on `end`, and a selected interval counts in full even if it began
    /// before the window opened — a night that ended this morning is last night's sleep,
    /// not the slice of it that happens to fall inside a trailing 24 hours. Individual
    /// intervals are already capped at 24 h by `HealthSample.isPlausible`, so this cannot
    /// drag in an unbounded stretch of history.
    static func asleepHours(in samples: [HealthSample], asOf now: Date) -> Double? {
        let window = HealthMetricsWindow.asleep.trailing(from: now)
        let intervals = samples
            .filter { $0.kind == .asleep && window.contains($0.end) && $0.duration > 0 }
            .map { $0.start..<$0.end }
            .sorted { $0.lowerBound < $1.lowerBound }

        guard !intervals.isEmpty else { return nil }

        var seconds: TimeInterval = 0
        var open = intervals[0]

        for interval in intervals.dropFirst() {
            if interval.lowerBound <= open.upperBound {
                open = open.lowerBound..<max(open.upperBound, interval.upperBound)
            } else {
                seconds += open.upperBound.timeIntervalSince(open.lowerBound)
                open = interval
            }
        }
        seconds += open.upperBound.timeIntervalSince(open.lowerBound)

        return seconds / 3600
    }
}

/// How far back each metric is willing to look.
///
/// All four numbers are *provisional*: chosen from how often each type is written, not
/// from a measured distribution. Re-derive them once there is real history and update
/// `.claude/context/ml-spec.md` in the same change.
struct HealthMetricsWindow: Hashable, Sendable {

    /// A measured heart rate is only "now" for so long. A worn watch writes one every few
    /// minutes, so two hours covers an ordinary gap — a meeting, a charge cycle — and
    /// still refuses to present this morning's reading as the current pulse. A watch that
    /// has been off the wrist longer than that leaves the card blank, which is the honest
    /// answer.
    ///
    /// Also caps what one refresh reads of it (`HealthMetricKind.readLookbackCap`):
    /// nothing older can reach the screen, and at roughly one sample per five minutes the
    /// foreground lookback would otherwise pull about 2 000 readings to show the newest.
    static let heartRate = HealthMetricsWindow.hours(2)

    /// Resting heart rate is a daily aggregate and lands late — often not until the
    /// evening of the day it covers. Two days of slack keeps the card from emptying out
    /// every morning; anything older is stale enough to mislead.
    static let restingHeartRate = HealthMetricsWindow.hours(48)

    /// Blood oxygen is written in background bursts and is frequently absent altogether.
    /// A day-old reading is still the most recent thing there is; older than that is not
    /// worth showing as "now".
    static let oxygenSaturation = HealthMetricsWindow.hours(24)

    /// Last night. A trailing day covers the previous night whatever time of day the
    /// screen is opened, and covers naps on top of it.
    static let asleep = HealthMetricsWindow.hours(24)

    /// Lookback for the read a saved check-in is stamped from
    /// (`CheckInHealthContext`).
    ///
    /// 24 h is the widest of the three windows that stamp quotes — blood oxygen and sleep —
    /// so nothing it can show is missed, while heart rate narrows itself further to 2 h
    /// through `HealthMetricKind.readLookbackCap`. Deliberately not `refreshLookback`: a
    /// check-in should cost a read of one day, not of a week, and the two wider windows are
    /// already covered by the foreground refresh that runs on every activation.
    static let checkInContext = HealthMetricsWindow.hours(24)

    /// How much history one foreground refresh pulls into the log.
    ///
    /// Wider than any display window, so a few days without opening the app do not leave
    /// a hole in the training history. Not a backfill: the first refresh on a fresh
    /// install picks up a week, not a year, and a deliberate backfill is a separate job.
    static let refreshLookback = HealthMetricsWindow.hours(7 * 24)

    /// Lookback for a background-delivery wake.
    ///
    /// Narrower than `refreshLookback` on purpose: the durable store already holds older
    /// rows, and an hourly wake only needs to catch what arrived since the previous one
    /// (plus margin for a missed delivery). Cuts the HealthKit query cost on the hot path
    /// that can run up to a few times per hour.
    static let backgroundLookback = HealthMetricsWindow.hours(48)

    let seconds: TimeInterval

    static func hours(_ hours: Double) -> HealthMetricsWindow {
        HealthMetricsWindow(seconds: hours * 3600)
    }

    /// Closed at both ends: a reading timestamped exactly `now` is the freshest thing
    /// there is and must count. These windows are read one at a time for display, never
    /// tiled edge to edge, so the double-counting that makes `Range` the right choice in
    /// the store contract does not arise here.
    func trailing(from now: Date) -> ClosedRange<Date> {
        now.addingTimeInterval(-seconds)...now
    }
}
