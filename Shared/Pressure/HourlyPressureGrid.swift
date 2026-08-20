import Foundation

/// The barometer log on an hourly grid, with altitude excursions removed.
///
/// The one place raw samples become something a fit can consume. Two jobs, and they are
/// deliberately in this order:
///
/// 1. **Reject excursions.** A lift ride moves station pressure as much as a meaningful
///    six-hour weather change (`.claude/context/ml-spec.md` §3). Left in, a model learns "the
///    user took the stairs" and forecasts it.
/// 2. **Bucket to the hour.** Sampling is opportunistic and irregular by design, and a linear
///    fit needs a regular index.
///
/// Gaps stay gaps. Nothing is interpolated across a hole longer than the policy allows, because
/// an invented value is indistinguishable downstream from a measured one — and the coverage
/// number this type reports is what lets a caller widen its band instead of pretending.
enum HourlyPressureGrid {

    /// A change larger than this inside `excursionWindowSeconds` is altitude or a bad read,
    /// never weather.
    ///
    /// **3 hPa in 10 minutes**, the §3 rate gate. Synoptic pressure change is ≤2 hPa/h even in
    /// a rapidly deepening system, so 18 hPa/h is two orders of magnitude past anything the
    /// atmosphere does. *Provisional* — reasoned from the rate, not measured on real traces.
    static let excursionThresholdHPa: Double = 3

    static let excursionWindowSeconds: TimeInterval = 10 * 60

    /// Holes up to this long are bridged linearly; longer ones stay holes.
    ///
    /// **2 hours**, the §2.1 gap policy. Interpolated cells never count toward coverage, which
    /// is what stops a bridged hour from looking like an observed one.
    static let maximumInterpolatedGapSeconds: TimeInterval = 2 * 3600

    /// One hour of the grid.
    struct Cell: Hashable, Sendable {

        /// Start of the hour, aligned to the hour in the given calendar.
        let hour: Date

        let hectopascals: Double

        /// Whether a reading was actually recorded in this hour, or the value was bridged
        /// across a short gap. Interpolated cells are usable for a fit and **not** counted as
        /// coverage — the distinction §2.1 insists on.
        let isObserved: Bool
    }

    /// The grid over `range`, ascending, holes omitted.
    ///
    /// Aligned to the epoch rather than to `now`, like `PressureBuckets`: a rebuild one second
    /// later must put every cell back where it was, or a daily refit would produce a different
    /// model from the same data.
    static func cells(from samples: [PressureSample], in range: Range<Date>) -> [Cell] {
        let usable = rejectingExcursions(in: samples)
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
        guard !usable.isEmpty else { return [] }

        var meansByHour: [Date: (sum: Double, count: Int)] = [:]
        for sample in usable {
            let hour = Date(timeIntervalSince1970:
                (sample.timestamp.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
            let running = meansByHour[hour] ?? (0, 0)
            meansByHour[hour] = (running.sum + sample.pressure.hectopascals, running.count + 1)
        }

        let observed = meansByHour
            .map { Cell(hour: $0.key, hectopascals: $0.value.sum / Double($0.value.count), isObserved: true) }
            .sorted { $0.hour < $1.hour }

        return bridgingShortGaps(in: observed)
    }

    /// The stretch of `range` the log actually reaches across, first observed hour to last.
    ///
    /// The denominator `coverage` should be measured against, and the difference is not a
    /// refinement. A 30-day window on an install that is one day old is 96% hours that could
    /// not have been recorded because the app did not exist yet — counting them as missing
    /// reads a complete log as 3% covered, and the band inflates fivefold on the strength of
    /// it. What coverage is *for* is holes: hours the sensor could have recorded and did not.
    ///
    /// A hole at the near end shortens the span rather than lowering the number, which is
    /// correct and is why it is not the only guard: the seed rule in `LocalPressureModel` is
    /// what handles a log that has gone quiet.
    ///
    /// Falls back to `range` when nothing was observed, so a caller dividing by it gets zero
    /// rather than a degenerate span.
    static func observedSpan(of cells: [Cell], in range: Range<Date>) -> Range<Date> {
        let observed = cells.filter(\.isObserved).map(\.hour)
        guard let first = observed.min(), let last = observed.max() else { return range }

        let start = max(first, range.lowerBound)
        let end = min(last.addingTimeInterval(3600), range.upperBound)
        guard end > start else { return range }

        return start..<end
    }

    /// Fraction of the hours in `range` that were actually recorded.
    ///
    /// Observed cells only — bridged ones are excluded by construction, which is what makes
    /// this number a statement about the sensor rather than about the interpolator.
    static func coverage(of cells: [Cell], in range: Range<Date>) -> Double {
        let hours = range.upperBound.timeIntervalSince(range.lowerBound) / 3600
        guard hours > 0 else { return 0 }

        return min(1, Double(cells.count { $0.isObserved }) / hours)
    }

    /// Drops readings that moved faster than the atmosphere can.
    ///
    /// A step is judged against its **neighbours in time**, not against a rolling mean: an
    /// excursion is a step, and a mean smeared across it would put half the step into every
    /// nearby value. Both readings either side of an implausible jump are dropped, because from
    /// two samples alone there is no way to say which of them was taken in the lift.
    ///
    /// This is rejection, not correction. §3 chose it deliberately: `CMAltimeter`'s relative
    /// altitude is derived *from pressure*, so it cannot separate the two, and there is no
    /// other altitude reference on the device.
    static func rejectingExcursions(in samples: [PressureSample]) -> [PressureSample] {
        let ordered = samples.sorted { $0.timestamp < $1.timestamp }
        guard ordered.count > 1 else { return ordered }

        var rejected = Set<Int>()
        for index in 1..<ordered.count {
            let previous = ordered[index - 1]
            let current = ordered[index]

            let seconds = current.timestamp.timeIntervalSince(previous.timestamp)
            guard seconds <= excursionWindowSeconds else { continue }

            let jump = abs(current.pressure.hectopascals - previous.pressure.hectopascals)
            if jump > excursionThresholdHPa {
                rejected.insert(index - 1)
                rejected.insert(index)
            }
        }

        return ordered.enumerated()
            .filter { !rejected.contains($0.offset) }
            .map(\.element)
    }

    /// Fills holes of at most `maximumInterpolatedGapSeconds`, marking what it filled.
    private static func bridgingShortGaps(in observed: [Cell]) -> [Cell] {
        guard observed.count > 1 else { return observed }

        var result: [Cell] = []
        for (index, cell) in observed.enumerated() {
            result.append(cell)
            guard index + 1 < observed.count else { continue }

            let next = observed[index + 1]
            let gap = next.hour.timeIntervalSince(cell.hour)
            guard gap > 3600, gap <= maximumInterpolatedGapSeconds + 3600 else { continue }

            let steps = Int(gap / 3600)
            for step in 1..<steps {
                let fraction = Double(step) / Double(steps)
                result.append(Cell(
                    hour: cell.hour.addingTimeInterval(TimeInterval(step) * 3600),
                    hectopascals: cell.hectopascals
                        + (next.hectopascals - cell.hectopascals) * fraction,
                    isObserved: false
                ))
            }
        }

        return result.sorted { $0.hour < $1.hour }
    }
}
