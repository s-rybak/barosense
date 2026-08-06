import Foundation

/// Health-derived features at one check-in instant.
///
/// Every field is optional. Absence is the ordinary case — denied Health access, a watch
/// without blood oxygen, a morning before resting heart rate lands — and the model must
/// handle a missing value explicitly. Nothing here invents a number to fill a hole.
///
/// Pure over samples. The store-backed entry point is a thin fetch; the rules live here so
/// a unit test can exercise them with literals and no SwiftData / HealthKit.
struct HealthFeatures: Hashable, Sendable {

    /// Hours asleep in the most recent night/session ending ≤24 h before the instant.
    let sleepDurationHours: Double?

    /// Hours from the end of that session to the instant.
    let hoursSinceWake: Double?

    /// Resting heart rate for the calendar day before the instant, in bpm.
    let restingHeartRateBPM: Double?

    /// Most recent SpO₂ with `end` at or before the instant inside the lookback, as a
    /// 0...1 fraction.
    let oxygenSaturationFraction: Double?
}

/// Builds `HealthFeatures` at a check-in instant from raw `HealthSample` rows.
///
/// Windows and rules match `.claude/context/ml-spec.md` §2.3 and are independent of the
/// Now-screen display windows in `HealthMetricsWindow`.
enum HealthFeatureExtractor {

    /// How far back a store-backed extract pulls. Wider than every feature window below
    /// so a single fetch covers sleep, RHR and SpO₂.
    static let storeLookback: TimeInterval = 48 * 3600

    /// Asleep session must end inside this trailing window before the instant.
    static let sleepLookback: TimeInterval = 24 * 3600

    /// SpO₂ older than this is dropped rather than kept as current physiology.
    static let oxygenLookback: TimeInterval = 24 * 3600

    /// Reads the store, keeps only samples with `end <= instant`, then runs the pure extract.
    static func extract(from store: any HealthSampleStore,
                        at instant: Date,
                        calendar: Calendar = .current) async throws -> HealthFeatures {
        let lower = instant.addingTimeInterval(-storeLookback)
        // Upper bound is exclusive in the store contract; `instant + 1s` includes a sample
        // timestamped exactly `instant`, and the pure extract still enforces `end <= instant`.
        let range = lower..<instant.addingTimeInterval(1)

        var samples: [HealthSample] = []
        for kind in HealthMetricKind.allCases {
            samples += try await store.samples(of: kind, in: range)
        }

        return extract(from: samples, at: instant, calendar: calendar)
    }

    /// Pure. Only samples with `end <= instant` may contribute — no look-ahead.
    static func extract(from samples: [HealthSample],
                        at instant: Date,
                        calendar: Calendar = .current) -> HealthFeatures {
        let visible = samples.filter { $0.end <= instant }

        let sleep = sleepFeatures(in: visible, at: instant)
        return HealthFeatures(
            sleepDurationHours: sleep.durationHours,
            hoursSinceWake: sleep.hoursSinceWake,
            restingHeartRateBPM: restingHeartRateBPM(in: visible, at: instant, calendar: calendar),
            oxygenSaturationFraction: oxygenSaturationFraction(in: visible, at: instant)
        )
    }

    // MARK: - Sleep

    private struct SleepFeatures {
        var durationHours: Double?
        var hoursSinceWake: Double?
    }

    /// Most recent asleep session ending in the trailing 24 h up to the instant.
    ///
    /// A session is a maximal run of overlapping or abutting asleep intervals. Staged
    /// segments from one source touch end-to-end and merge; a real gap (an awakening that
    /// Health recorded between stages) splits sessions. We do not log `.awake`, so a gap
    /// in the asleep stream *is* the awakening. `sleepAwakeningCount` stays blocked.
    private static func sleepFeatures(in samples: [HealthSample], at instant: Date) -> SleepFeatures {
        let cutoff = instant.addingTimeInterval(-sleepLookback)
        let intervals = samples
            .filter { $0.kind == .asleep && $0.end > cutoff && $0.duration > 0 }
            .map { $0.start..<$0.end }
            .sorted { $0.lowerBound < $1.lowerBound }

        guard let session = sessions(merging: intervals).max(by: { $0.upperBound < $1.upperBound })
        else {
            return SleepFeatures(durationHours: nil, hoursSinceWake: nil)
        }

        let durationHours = session.upperBound.timeIntervalSince(session.lowerBound) / 3600
        let hoursSinceWake = instant.timeIntervalSince(session.upperBound) / 3600
        return SleepFeatures(durationHours: durationHours, hoursSinceWake: hoursSinceWake)
    }

    private static func sessions(merging intervals: [Range<Date>]) -> [Range<Date>] {
        guard let first = intervals.first else { return [] }

        var result: [Range<Date>] = []
        var open = first

        for interval in intervals.dropFirst() {
            if interval.lowerBound <= open.upperBound {
                open = open.lowerBound..<max(open.upperBound, interval.upperBound)
            } else {
                result.append(open)
                open = interval
            }
        }
        result.append(open)
        return result
    }

    // MARK: - Resting heart rate

    /// Previous completed calendar day's resting heart rate.
    ///
    /// Selection is on the sample's `start` falling inside yesterday, with `end` at or
    /// before the instant. Anchoring on `start` (the day the aggregate covers) rather
    /// than `end` is what stops a late-published sample whose `end` lands this morning
    /// from being read as "today" and leaking the future into a morning row — and what
    /// still accepts that same late-published sample as yesterday's value once it is
    /// knowable.
    private static func restingHeartRateBPM(in samples: [HealthSample],
                                            at instant: Date,
                                            calendar: Calendar) -> Double? {
        let dayStart = calendar.startOfDay(for: instant)
        guard let previousDayStart = calendar.date(byAdding: .day, value: -1, to: dayStart)
        else {
            return nil
        }

        return samples
            .filter {
                $0.kind == .restingHeartRate
                    && $0.start >= previousDayStart
                    && $0.start < dayStart
            }
            .max { $0.end < $1.end }
            .flatMap { sample in
                if case .restingHeartRateBPM(let bpm) = sample.value { bpm } else { nil }
            }
    }

    // MARK: - Blood oxygen

    private static func oxygenSaturationFraction(in samples: [HealthSample],
                                                 at instant: Date) -> Double? {
        let cutoff = instant.addingTimeInterval(-oxygenLookback)
        return samples
            .filter { $0.kind == .oxygenSaturation && $0.end > cutoff }
            .max { $0.end < $1.end }
            .flatMap { sample in
                if case .oxygenSaturationFraction(let fraction) = sample.value {
                    fraction
                } else {
                    nil
                }
            }
    }
}
