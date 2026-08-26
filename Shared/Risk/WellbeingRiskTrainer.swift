import Foundation

/// A fitted model and the run that produced it.
struct WellbeingRiskTraining: Hashable, Sendable {
    let model: WellbeingRiskModel

    /// `nil` when there was not enough history to validate on — the model is then the shipped
    /// prior, possibly blended with a thin personal fit, and nothing has been measured about
    /// it. A missing report is a fact about the device, not a failure of the run.
    let report: RiskModelReport?
}

/// Fits both stages and measures them, forward-chaining throughout.
///
/// ## The one rule this file exists to enforce
///
/// **Every number here comes from a model that had not seen the day it is scoring.** Not the
/// coefficients, not the Platt correction, not the threshold the gate fires at, not the
/// baselines' tuned constants. A random split on this data leaks tomorrow into yesterday and
/// reports an accuracy the app will never reproduce, and it does so quietly — the metrics look
/// better, which is exactly why it has to be structural rather than a matter of care.
///
/// Concretely: each fold rebuilds the whole shipped arrangement from its own past — personal
/// day fit, personal window fit, calibration, blend weight — and scores the fold's future with
/// it. The out-of-fold scores are therefore what this device would actually have shown on those
/// days, which is what makes the gate threshold derived from them mean anything.
enum WellbeingRiskTrainer {

    /// Fewest days of history before a fit is attempted at all.
    ///
    /// **Seven**, the top of the 3–7 day cold-start requirement. Below it the model is the
    /// shipped prior alone, which is the point of shipping one — not a degraded state to be
    /// apologised for.
    static let minimumTrainingDays = 7

    /// Fewest days before the run is *validated* rather than just fitted.
    ///
    /// **35**. Four folds need four test blocks plus something to train the first on, and a
    /// report from two days of test data would put a precision figure on two coin flips.
    static let minimumValidationDays = 35

    static let foldCount = 4

    /// Largest test block per fold, days. Smaller when there is less history.
    static let maximumTestDays = 15

    /// Days dropped between a fold's training end and its test start.
    ///
    /// **One.** The day-level features average a whole waking day, so a row from the last
    /// training day and one from the first test day are built from overlapping hours; the gap
    /// removes that overlap. It does **not** cover the seven-day mean, which still reaches
    /// across — that would cost seven days between every fold, a quarter of a month's history,
    /// for the feature carrying the smallest coefficient in the model (0.042 against 1.35).
    /// Stated rather than silently accepted.
    static let foldGapDays = 1

    /// How much history a fit uses.
    ///
    /// **120 days**, the span the research run covered. Longer would let a season-old
    /// relationship outvote a current one; the barometer log itself is kept for five years and
    /// is deliberately not all fed in here.
    static let trainingWindowDays = 120

    /// How often the app is willing to interrupt, and therefore what the gate is tuned to.
    ///
    /// **2.5 a week.** A product decision, not a metric — the threshold falls out of it once
    /// the ranking is fixed. Raising it raises recall and lowers precision along the measured
    /// curve, and the curve crosses the "people switch this off" line at about 0.5.
    static let messagesPerWeekTarget: Double = 2.5

    // MARK: - Entry point

    /// Fits from rows that have already happened.
    ///
    /// Rows ahead of `now`, or built from a forecast, are rejected here rather than by
    /// convention: training on a forecast value teaches the model the forecaster's biases and
    /// then applies them again at inference, twice.
    static func train(rows: [RiskWindowRow],
                      geometry: RiskWindowGeometry,
                      asOf now: Date) -> WellbeingRiskTraining? {
        let usable = rows
            .filter { $0.end <= now }
            .filter { $0.forecastShare == 0 }
            .filter { $0.dayCoverage >= RiskWindowBuilder.minimumDayCoverage }
            .filter { $0.dayStart >= now.addingTimeInterval(-Double(trainingWindowDays) * 24 * 3600) }
            .sorted { $0.start < $1.start }

        let days = orderedDays(of: usable)
        guard days.count >= minimumTrainingDays else { return nil }

        let entryCount = usable.count(where: \.isLogged)
        let stages = personalStages(from: usable)

        // `nil` only with the prior switched off and no personal fit to stand in for it — the
        // device then has no model, which is the switch working rather than a failure.
        guard let model = WellbeingRiskModel.blending(personalDay: stages.day,
                                                      personalWindow: stages.window,
                                                      labelledEntryCount: entryCount,
                                                      dayStartHour: geometry.dayStartHour,
                                                      trainedAt: now)
        else { return nil }

        guard days.count >= minimumValidationDays,
              let validation = validate(rows: usable, days: days, geometry: geometry, asOf: now)
        else {
            return WellbeingRiskTraining(model: model, report: nil)
        }

        // The threshold the run measured replaces the shipped one. It has to: a personal fit
        // has its own scale, so carrying 0.848 across would gate at whatever share of days that
        // number happened to land on for this user rather than at the budget it was chosen for.
        return WellbeingRiskTraining(
            model: model.withGateThreshold(validation.report.gate.threshold),
            report: validation.report
        )
    }

    // MARK: - Fitting one arrangement

    /// The personal half of the model, fitted on whatever rows it is given.
    ///
    /// Two different row sets, and the difference is the whole two-stage idea:
    ///
    /// - the **day** stage sees one row per day, every day, because "was today quiet" is asked
    ///   of every day;
    /// - the **window** stage sees only days that held an entry, because its question is
    ///   *conditional*. Trained on all days it would spend its capacity learning which days are
    ///   quiet — the first stage's job — and its base rate would drift with how often this user
    ///   logs at all, instead of sitting at a fixed one-in-nine.
    static func personalStages(from rows: [RiskWindowRow]) -> (day: RiskStage?, window: RiskStage?) {
        let dayRows = oneRowPerDay(in: rows)
        let loggedDays = Set(rows.filter(\.isLogged).map(\.dayStart))

        let dayStage = fitDayStage(dayRows: dayRows, loggedDays: loggedDays)

        let conditional = rows.filter { loggedDays.contains($0.dayStart) }
        let windowModel = LogisticRegressionFitter.fit(
            rows: conditional.map { $0.vector(RiskFeature.personalWindowColumns) },
            labels: conditional.map(\.isLogged)
        )

        return (dayStage,
                windowModel.map { RiskStage(model: $0,
                                            calibration: nil,
                                            columns: RiskFeature.personalWindowColumns) })
    }

    /// Fits the day stage and the Platt pair that makes its output a frequency.
    ///
    /// The calibration is fitted on **out-of-fold** decisions from an inner forward chain, never
    /// on the decisions the same rows produced in training. In-sample decisions are optimistic,
    /// and a sigmoid taught to undo an optimism that only exists in-sample comes back worse on
    /// a day it has not seen.
    private static func fitDayStage(dayRows: [RiskWindowRow], loggedDays: Set<Date>) -> RiskStage? {
        guard let model = LogisticRegressionFitter.fit(
            rows: dayRows.map { $0.vector(RiskFeature.dayColumns) },
            labels: dayRows.map { loggedDays.contains($0.dayStart) }
        ) else { return nil }

        var decisions: [Double] = []
        var labels: [Bool] = []
        let innerDays = dayRows.map(\.dayStart)

        for split in splits(days: innerDays, foldCount: 3, gapDays: 0) {
            let train = dayRows.filter { split.trainDays.contains($0.dayStart) }
            let test = dayRows.filter { split.testDays.contains($0.dayStart) }
            guard let fold = LogisticRegressionFitter.fit(
                rows: train.map { $0.vector(RiskFeature.dayColumns) },
                labels: train.map { loggedDays.contains($0.dayStart) }
            ) else { continue }

            decisions.append(contentsOf: test.map { fold.decision($0.vector(RiskFeature.dayColumns)) })
            labels.append(contentsOf: test.map { loggedDays.contains($0.dayStart) })
        }

        return RiskStage(model: model,
                         calibration: PlattCalibration.fit(decisions: decisions, labels: labels),
                         columns: RiskFeature.dayColumns)
    }

    // MARK: - Validation

    private struct Validation {
        let report: RiskModelReport
    }

    /// Runs the forward chain and measures everything off it.
    private static func validate(rows: [RiskWindowRow],
                                 days: [Date],
                                 geometry: RiskWindowGeometry,
                                 asOf now: Date) -> Validation? {
        let testSize = min(maximumTestDays, max(2, days.count / (foldCount + 2)))
        let folds = splits(days: days, foldCount: foldCount, testSize: testSize, gapDays: foldGapDays)
        guard !folds.isEmpty else { return nil }

        var scored: [ScoredRow] = []

        for fold in folds {
            let train = rows.filter { fold.trainDays.contains($0.dayStart) }
            let test = rows.filter { fold.testDays.contains($0.dayStart) }
            guard !train.isEmpty, !test.isEmpty else { continue }

            let stages = personalStages(from: train)
            guard let foldModel = WellbeingRiskModel.blending(
                personalDay: stages.day,
                personalWindow: stages.window,
                labelledEntryCount: train.count(where: \.isLogged),
                dayStartHour: geometry.dayStartHour,
                trainedAt: now
            ) else { continue }

            let baselineScores = baselineScores(train: train, test: test, geometry: geometry)

            let uncalibrated = foldModel.withoutDayCalibration()

            for (index, row) in test.enumerated() {
                scored.append(ScoredRow(
                    row: row,
                    dayProbability: foldModel.dayProbability(for: row),
                    uncalibratedDayProbability: uncalibrated.dayProbability(for: row),
                    windowConfidence: foldModel.windowConfidence(for: row),
                    baselines: baselineScores[index]
                ))
            }
        }

        guard !scored.isEmpty else { return nil }

        return Validation(report: report(from: scored,
                                         geometry: geometry,
                                         foldCount: folds.count,
                                         asOf: now))
    }

    /// One test row with everything measured on it.
    private struct ScoredRow {
        let row: RiskWindowRow
        let dayProbability: Double
        /// The same figure with the Platt correction removed, so the correction can be shown
        /// to have earned its place instead of being assumed to.
        let uncalibratedDayProbability: Double
        let windowConfidence: Double
        let baselines: [RiskBaseline: Double]
    }

    // MARK: - Report

    private static func report(from scored: [ScoredRow],
                               geometry: RiskWindowGeometry,
                               foldCount: Int,
                               asOf now: Date) -> RiskModelReport {
        let labels = scored.map(\.row.isLogged)
        let days = scored.map(\.row.dayStart)
        let windowScores = scored.map(\.windowConfidence)

        let dayRows = oneRowPerDay(in: scored.map(\.row))
        let loggedDays = Set(scored.filter(\.row.isLogged).map(\.row.dayStart))
        let dayProbabilityByDay = Dictionary(scored.map { ($0.row.dayStart, $0.dayProbability) },
                                             uniquingKeysWith: { first, _ in first })
        let dayProbabilities = dayRows.compactMap { dayProbabilityByDay[$0.dayStart] }
        let dayLabels = dayRows.map { loggedDays.contains($0.dayStart) }

        let uncalibratedByDay = Dictionary(
            scored.map { ($0.row.dayStart, $0.uncalibratedDayProbability) },
            uniquingKeysWith: { first, _ in first }
        )
        let uncalibratedDayProbabilities = dayRows.compactMap { uncalibratedByDay[$0.dayStart] }

        let gate = gateScore(scored: scored, loggedDays: loggedDays)

        return RiskModelReport(
            evaluatedAt: now,
            dayCount: dayRows.count,
            loggedDayCount: loggedDays.count,
            foldCount: foldCount,
            day: RiskModelReport.Stage(
                rocAUC: RiskMetrics.rocAUC(scores: dayProbabilities, labels: dayLabels),
                prAUC: RiskMetrics.averagePrecision(scores: dayProbabilities, labels: dayLabels),
                baseRate: dayLabels.isEmpty
                    ? 0 : Double(dayLabels.count(where: { $0 })) / Double(dayLabels.count),
                brier: RiskMetrics.brier(probabilities: dayProbabilities, labels: dayLabels),
                uncalibratedBrier: RiskMetrics.brier(probabilities: uncalibratedDayProbabilities,
                                                     labels: dayLabels),
                rowCount: dayRows.count,
                positiveCount: dayLabels.count(where: { $0 })
            ),
            window: RiskModelReport.Stage(
                rocAUC: RiskMetrics.rocAUC(scores: windowScores, labels: labels),
                prAUC: RiskMetrics.averagePrecision(scores: windowScores, labels: labels),
                baseRate: labels.isEmpty
                    ? 0 : Double(labels.count(where: { $0 })) / Double(labels.count),
                // Ranking only — the window stage is never compared with a fixed number except
                // the gate, which is a quantile of its own output. A Brier score here would be
                // measuring a property nothing reads.
                brier: nil,
                uncalibratedBrier: nil,
                rowCount: labels.count,
                positiveCount: labels.count(where: { $0 })
            ),
            hitAtOne: RiskMetrics.hitRate(scores: windowScores, labels: labels, days: days, topK: 1),
            hitAtTwo: RiskMetrics.hitRate(scores: windowScores, labels: labels, days: days,
                                          topK: WellbeingRiskModel.markedWindowCount),
            randomHitAtOne: 1 / Double(geometry.windowsPerDay),
            randomHitAtTwo: Double(WellbeingRiskModel.markedWindowCount)
                / Double(geometry.windowsPerDay),
            daysWithoutEntry: dayRows.count - loggedDays.count,
            baselines: RiskBaseline.allCases.map { baseline in
                let scores = scored.map { $0.baselines[baseline] ?? 0 }
                return RiskModelReport.BaselineScore(
                    baseline: baseline,
                    prAUC: RiskMetrics.averagePrecision(scores: scores, labels: labels),
                    rocAUC: RiskMetrics.rocAUC(scores: scores, labels: labels),
                    hitAtOne: RiskMetrics.hitRate(scores: scores, labels: labels, days: days, topK: 1)
                )
            },
            gate: gate
        )
    }

    /// Where the gate goes, and what it buys.
    ///
    /// The threshold is a **quantile of the per-day best window score**, not a fixed
    /// probability: the app's willingness to interrupt is a rate, and a rate is what survives
    /// the model being refitted next week on a different scale.
    private static func gateScore(scored: [ScoredRow], loggedDays: Set<Date>) -> RiskModelReport.GateScore {
        var bestByDay: [Date: (confidence: Double, hit: Bool)] = [:]

        for day in Set(scored.map(\.row.dayStart)) {
            let rows = scored.filter { $0.row.dayStart == day }
            let marked = rows.sorted { $0.windowConfidence > $1.windowConfidence }
                .prefix(WellbeingRiskModel.markedWindowCount)
            guard let best = marked.first else { continue }
            bestByDay[day] = (best.windowConfidence, marked.contains { $0.row.isLogged })
        }

        let ordered = bestByDay.values.map(\.confidence).sorted(by: >)
        let share = messagesPerWeekTarget / 7
        let count = max(1, Int((Double(ordered.count) * share).rounded()))
        let threshold = ordered.count >= count ? ordered[count - 1] : WellbeingRiskPrior.gateThreshold

        let fired = bestByDay.values.filter { $0.confidence >= threshold }
        let hits = fired.count(where: \.hit)

        return RiskModelReport.GateScore(
            threshold: threshold,
            messagesPerWeek: bestByDay.isEmpty
                ? 0 : Double(fired.count) / Double(bestByDay.count) * 7,
            precision: fired.isEmpty ? nil : Double(hits) / Double(fired.count),
            precisionInterval: RiskMetrics.wilsonInterval(hits: hits, of: fired.count),
            recall: loggedDays.isEmpty ? nil : Double(hits) / Double(loggedDays.count),
            firedDayCount: fired.count,
            evaluatedDayCount: bestByDay.count
        )
    }
}
