import Foundation

/// How a run is cut in time.
///
/// Separated from the fitting so the rule is readable on its own, because it is the rule the
/// whole subsystem's credibility rests on: a random split on this data leaks tomorrow into
/// yesterday, reports a better number for doing it, and cannot be caught by looking at the
/// metrics afterwards.
extension WellbeingRiskTrainer {

    /// One forward-chaining fold.
    struct Split: Hashable, Sendable {
        let trainDays: Set<Date>
        let testDays: Set<Date>
    }

    static func orderedDays(of rows: [RiskWindowRow]) -> [Date] {
        Array(Set(rows.map(\.dayStart))).sorted()
    }

    /// Forward-chaining splits over a sorted day list, newest folds last.
    ///
    /// Each fold trains on everything before its test block and tests on the block — the shape
    /// of `TimeSeriesSplit`, cut on **day** boundaries so a fold never splits a day whose
    /// day-level features are shared across its windows.
    static func splits(days: [Date],
                       foldCount: Int,
                       testSize: Int? = nil,
                       gapDays: Int = 0) -> [Split] {
        guard foldCount > 0, days.count > foldCount else { return [] }

        let size = testSize ?? max(1, days.count / (foldCount + 1))
        guard size > 0, days.count > size * foldCount else {
            // Fall back to equal blocks when the requested test size does not leave anything to
            // train the first fold on.
            return splits(days: days, foldCount: foldCount, testSize: nil, gapDays: gapDays)
        }

        var result: [Split] = []
        for fold in 0..<foldCount {
            let testEnd = days.count - (foldCount - 1 - fold) * size
            let testStart = testEnd - size
            let trainEnd = testStart - gapDays
            guard testStart > 0, trainEnd > 0 else { continue }

            result.append(Split(trainDays: Set(days[0..<trainEnd]),
                                testDays: Set(days[testStart..<testEnd])))
        }
        return result
    }

    /// One representative row per day. Day-level features are identical across a day's windows,
    /// so the earliest is as good as any and is chosen for being deterministic.
    static func oneRowPerDay(in rows: [RiskWindowRow]) -> [RiskWindowRow] {
        Dictionary(grouping: rows, by: \.dayStart)
            .compactMapValues { $0.min { $0.start < $1.start } }
            .values
            .sorted { $0.dayStart < $1.dayStart }
    }
}
