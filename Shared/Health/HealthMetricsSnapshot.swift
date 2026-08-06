import Foundation

/// What the Health card row shows at one instant.
///
/// Every field is optional and absence is the ordinary case, not a failure: read denial is
/// indistinguishable from an empty Health store, blood oxygen depends on the watch model
/// and the region, and a user with no watch has none of it. Nothing here may be turned
/// into a blocking state.
struct HealthMetricsSnapshot: Hashable, Sendable {

    /// Beats per minute, most recent reading inside the staleness bound.
    let restingHeartRateBPM: Double?

    /// Fraction of 0...1, most recent reading inside the staleness bound.
    let oxygenSaturationFraction: Double?

    /// Hours asleep across the trailing window, overlapping intervals counted once.
    let asleepHours: Double?

    static let empty = HealthMetricsSnapshot(restingHeartRateBPM: nil,
                                             oxygenSaturationFraction: nil,
                                             asleepHours: nil)

    var isEmpty: Bool {
        restingHeartRateBPM == nil && oxygenSaturationFraction == nil && asleepHours == nil
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
            restingHeartRateBPM: latestHeartRate(in: samples, asOf: now),
            oxygenSaturationFraction: latestSaturation(in: samples, asOf: now),
            asleepHours: asleepHours(in: samples, asOf: now)
        )
    }

    private static func latestHeartRate(in samples: [HealthSample], asOf now: Date) -> Double? {
        let window = HealthMetricsWindow.restingHeartRate.trailing(from: now)
        return samples
            .filter { window.contains($0.end) }
            .max { $0.end < $1.end }
            .flatMap { sample in
                if case .restingHeartRateBPM(let bpm) = sample.value { bpm } else { nil }
            }
    }

    private static func latestSaturation(in samples: [HealthSample], asOf now: Date) -> Double? {
        let window = HealthMetricsWindow.oxygenSaturation.trailing(from: now)
        return samples
            .filter { window.contains($0.end) }
            .max { $0.end < $1.end }
            .flatMap { sample in
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
