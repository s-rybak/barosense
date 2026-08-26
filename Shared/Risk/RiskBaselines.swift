import Foundation

/// The trivial baselines, scored the way §7 of `ml-spec.md` requires: every constant fitted on
/// the training half of a fold and applied unseen to its test half.
///
/// Split out of `WellbeingRiskTrainer` because it is a separate claim. The trainer's job is to
/// produce a model; this file's job is to make it possible for that model to lose — and losing
/// is a publishable outcome, because a learned model that cannot beat a threshold rule costs
/// battery and adds risk for nothing.
extension WellbeingRiskTrainer {

    /// Candidate thresholds for the pressure-rule baseline, hPa of six-hour fall.
    ///
    /// Tuned on train alone, never on test. A rule whose constant was picked by looking at the
    /// test half is not a baseline, it is a second model with an unfair advantage — and it
    /// would make the learned model look worse than it is, which is the same failure in the
    /// opposite direction.
    static var pressureRuleCandidatesHPa: [Double] { [1, 2, 3, 4, 5, 6, 8, 10] }

    /// Scores every baseline on the fold's test rows, with each one's constants fitted on the
    /// fold's training rows and nothing else.
    static func baselineScores(train: [RiskWindowRow],
                               test: [RiskWindowRow],
                               geometry: RiskWindowGeometry) -> [[RiskBaseline: Double]] {
        let rate = train.isEmpty
            ? 0 : Double(train.count(where: \.isLogged)) / Double(train.count)

        // "Fell more than X hPa in six hours", X chosen on the training rows by F1 alone.
        let ruleThreshold = pressureRuleCandidatesHPa.max { left, right in
            f1(of: train, threshold: left) < f1(of: train, threshold: right)
        } ?? 5

        // Frequency of entries by window index — the clock, learned rather than assumed.
        var byIndex: [Int: (logged: Int, total: Int)] = [:]
        for row in train {
            let index = windowIndex(of: row, geometry: geometry)
            let running = byIndex[index] ?? (0, 0)
            byIndex[index] = (running.logged + (row.isLogged ? 1 : 0), running.total + 1)
        }
        let frequencyByIndex = byIndex.mapValues { $0.total > 0 ? Double($0.logged) / Double($0.total) : 0 }

        // Persistence, read causally: the window index of the last entry in the fold's
        // **training** half, scored 1 wherever a test row shares it. One index for the whole
        // test block, not one per test day — a test day may never look at another test day,
        // and forward-chaining puts every training row before every test row, so the last
        // training entry is exactly "yesterday again" seen from the first test day.
        let lastLoggedIndexBefore = lastLoggedWindowIndex(in: train, geometry: geometry)

        return test.map { row in
            let index = windowIndex(of: row, geometry: geometry)
            return [
                .majorityClass: rate,
                .pressureRule: (row[.drop6hHPa] ?? 0) >= ruleThreshold ? 1 : 0,
                .timeOfDay: frequencyByIndex[index] ?? rate,
                .persistence: lastLoggedIndexBefore == index ? 1 : 0
            ]
        }
    }

    private static func f1(of rows: [RiskWindowRow], threshold: Double) -> Double {
        let flagged = rows.map { ($0[.drop6hHPa] ?? 0) >= threshold }
        let labels = rows.map(\.isLogged)
        guard let precision = RiskMetrics.precision(flagged: flagged, labels: labels),
              let recall = RiskMetrics.recall(flagged: flagged, labels: labels),
              precision + recall > 0
        else { return 0 }

        return 2 * precision * recall / (precision + recall)
    }

    /// The window index of the latest logged row in `rows`. `nil` when none of them is logged.
    private static func lastLoggedWindowIndex(in rows: [RiskWindowRow],
                                              geometry: RiskWindowGeometry) -> Int? {
        rows.filter(\.isLogged)
            .max { $0.start < $1.start }
            .map { windowIndex(of: $0, geometry: geometry) }
    }

    private static func windowIndex(of row: RiskWindowRow, geometry: RiskWindowGeometry) -> Int {
        Int(row.start.timeIntervalSince(row.dayStart) / geometry.windowSeconds)
    }
}
