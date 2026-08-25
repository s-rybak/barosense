import XCTest
@testable import Barosense

/// The Swift fitter, calibrator and metrics against scikit-learn's answers on the same rows.
///
/// This is the test that makes the shipped prior meaningful. `WellbeingRiskPrior` holds
/// coefficients produced by scikit-learn; if the Swift scorer disagrees with scikit-learn about
/// what those coefficients mean, the constants are decoration. Nothing in the rest of the
/// pipeline would notice — the numbers would still be plausible.
final class RiskNumericsTests: XCTestCase {

    /// The imputer, the scaler and the coefficients, all three.
    ///
    /// Tolerances are tight on the preprocessing (1e-9) and loose on the coefficients (1e-3).
    /// The preprocessing is arithmetic and has to agree exactly. The coefficients come out of
    /// two different optimisers stopping at two different points on the same objective, and the
    /// residual difference is scikit-learn's: measured on these rows the Swift solution reaches
    /// a penalised loss 2.0e-7 **below** L-BFGS's, which stops at its own default gradient
    /// tolerance of 1e-4. So the looser bound is the library's convergence, not this fitter's.
    func testFitMatchesScikitLearn() throws {
        let fitted = try XCTUnwrap(LogisticRegressionFitter.fit(rows: SklearnFixture.rows,
                                                               labels: SklearnFixture.labels))

        for index in SklearnFixture.medians.indices {
            XCTAssertEqual(fitted.medians[index], SklearnFixture.medians[index], accuracy: 1e-9)
            XCTAssertEqual(fitted.mean[index], SklearnFixture.mean[index], accuracy: 1e-9)
            XCTAssertEqual(fitted.scale[index], SklearnFixture.scale[index], accuracy: 1e-9)
        }

        for index in SklearnFixture.coefficients.indices {
            XCTAssertEqual(fitted.coefficients[index],
                           SklearnFixture.coefficients[index],
                           accuracy: 1e-3,
                           "coefficient \(index)")
        }
        XCTAssertEqual(fitted.intercept, SklearnFixture.intercept, accuracy: 1e-3)
    }

    /// The decision values themselves, which is what a Platt pair is fitted on and therefore
    /// the quantity a drift would propagate through.
    func testDecisionsMatchScikitLearn() throws {
        let fitted = try XCTUnwrap(LogisticRegressionFitter.fit(rows: SklearnFixture.rows,
                                                               labels: SklearnFixture.labels))

        for (index, row) in SklearnFixture.rows.enumerated() {
            XCTAssertEqual(fitted.decision(row), SklearnFixture.decisions[index], accuracy: 1e-3)
        }
    }

    /// A missing column is filled with the training median, not with zero.
    ///
    /// Zero-filling a column whose median is 1000 hPa is not a small error — it is a different
    /// planet, and the standardised value lands ninety deviations away.
    func testMissingValuesAreFilledWithTheTrainingMedian() throws {
        let fitted = try XCTUnwrap(LogisticRegressionFitter.fit(rows: SklearnFixture.rows,
                                                               labels: SklearnFixture.labels))

        let complete = fitted.medians.map { Optional($0) }
        let empty: [Double?] = [nil, nil, nil]

        XCTAssertEqual(fitted.decision(empty), fitted.decision(complete), accuracy: 1e-12)
    }

    func testPlattCalibrationMatchesScikitLearn() throws {
        let calibration = try XCTUnwrap(PlattCalibration.fit(decisions: SklearnFixture.decisions,
                                                            labels: SklearnFixture.labels))

        // Negated: scikit-learn stores `1/(1+exp(a·d+b))`, this stores `sigmoid(s·d+i)`.
        XCTAssertEqual(-calibration.slope, SklearnFixture.plattA, accuracy: 1e-6)
        XCTAssertEqual(-calibration.intercept, SklearnFixture.plattB, accuracy: 1e-6)
    }

    /// Calibration moves the numbers toward the observed frequency without reordering them.
    ///
    /// Both halves matter. Reliability is the point; preserving the order is what makes it safe
    /// to calibrate a stage the gate ranks with.
    func testCalibrationImprovesReliabilityAndPreservesOrder() throws {
        let calibration = try XCTUnwrap(PlattCalibration.fit(decisions: SklearnFixture.decisions,
                                                            labels: SklearnFixture.labels))

        let raw = SklearnFixture.decisions.map { LogisticMath.sigmoid($0) }
        let calibrated = SklearnFixture.decisions.map { calibration.probability(ofDecision: $0) }

        let rawBrier = try XCTUnwrap(RiskMetrics.brier(probabilities: raw,
                                                       labels: SklearnFixture.labels))
        let calibratedBrier = try XCTUnwrap(RiskMetrics.brier(probabilities: calibrated,
                                                             labels: SklearnFixture.labels))
        XCTAssertLessThan(calibratedBrier, rawBrier)

        let rawAUC = try XCTUnwrap(RiskMetrics.rocAUC(scores: raw, labels: SklearnFixture.labels))
        let calibratedAUC = try XCTUnwrap(RiskMetrics.rocAUC(scores: calibrated,
                                                            labels: SklearnFixture.labels))
        XCTAssertEqual(rawAUC, calibratedAUC, accuracy: 1e-12)
    }

    func testMetricsMatchScikitLearn() throws {
        let fitted = try XCTUnwrap(LogisticRegressionFitter.fit(rows: SklearnFixture.rows,
                                                               labels: SklearnFixture.labels))
        let probabilities = SklearnFixture.rows.map { fitted.probability($0) }

        XCTAssertEqual(try XCTUnwrap(RiskMetrics.averagePrecision(scores: probabilities,
                                                                  labels: SklearnFixture.labels)),
                       SklearnFixture.prAUC, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(RiskMetrics.rocAUC(scores: probabilities,
                                                        labels: SklearnFixture.labels)),
                       SklearnFixture.rocAUC, accuracy: 1e-4)
        XCTAssertEqual(try XCTUnwrap(RiskMetrics.brier(probabilities: probabilities,
                                                       labels: SklearnFixture.labels)),
                       SklearnFixture.brier, accuracy: 1e-4)
    }

    /// Ties, which is where a hand-rolled AUC normally disagrees with the library.
    ///
    /// The pressure-rule baseline produces exactly two distinct scores, so this is not a corner
    /// case — it is how one of the four baselines is measured every run.
    func testMetricsHandleTiesLikeScikitLearn() throws {
        XCTAssertEqual(try XCTUnwrap(RiskMetrics.rocAUC(scores: SklearnFixture.tiedScores,
                                                        labels: SklearnFixture.labels)),
                       SklearnFixture.tiedROCAUC, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(RiskMetrics.averagePrecision(scores: SklearnFixture.tiedScores,
                                                                  labels: SklearnFixture.labels)),
                       SklearnFixture.tiedPRAUC, accuracy: 1e-9)
    }

    /// A constant predictor scores its base rate on PR-AUC and exactly a coin on ROC-AUC. The
    /// majority-class baseline depends on this being true.
    func testConstantPredictorScoresTheBaseRate() throws {
        let constant = [Double](repeating: 0.42, count: SklearnFixture.labels.count)

        XCTAssertEqual(try XCTUnwrap(RiskMetrics.averagePrecision(scores: constant,
                                                                  labels: SklearnFixture.labels)),
                       SklearnFixture.positiveRate, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(RiskMetrics.rocAUC(scores: constant,
                                                        labels: SklearnFixture.labels)),
                       0.5, accuracy: 1e-12)
    }

    /// No positives, no metric. `nil` rather than zero — "not measurable" and "measured as
    /// nothing" are different facts, and a fresh install is in the first state.
    func testMetricsRefuseToScoreWithoutAPositiveClass() {
        let labels = [Bool](repeating: false, count: 8)
        let scores = (0..<8).map(Double.init)

        XCTAssertNil(RiskMetrics.averagePrecision(scores: scores, labels: labels))
        XCTAssertNil(RiskMetrics.rocAUC(scores: scores, labels: labels))
        XCTAssertNil(RiskMetrics.hitRate(scores: scores, labels: labels,
                                         days: [Date](repeating: .init(), count: 8), topK: 1))
    }

    /// One class, no fit. The caller falls back to the shipped prior; a model fitted on a
    /// single class would answer that class for every row with total confidence.
    func testFitterRefusesASingleClass() {
        let rows: [[Double?]] = (0..<40).map { [Double($0), Double($0) * 2] }

        XCTAssertNil(LogisticRegressionFitter.fit(rows: rows,
                                                  labels: [Bool](repeating: false, count: 40)))
        XCTAssertNil(LogisticRegressionFitter.fit(rows: rows,
                                                  labels: [Bool](repeating: true, count: 40)))
    }

    /// Fewer rows than the fit can support, no fit.
    func testFitterRefusesTooFewRows() {
        let rows: [[Double?]] = (0..<4).map { [Double($0), Double($0) * 2] }
        let labels = [true, false, true, false]

        XCTAssertNil(LogisticRegressionFitter.fit(rows: rows, labels: labels))
    }

    /// Balanced weighting is what stops a 1-in-9 positive class being answered with "never".
    func testBalancedWeightingLiftsTheRarePositiveClass() throws {
        var rows: [[Double?]] = []
        var labels: [Bool] = []
        for index in 0..<180 {
            let positive = index % 9 == 0
            rows.append([positive ? 3.0 : 0.5, Double(index % 5)])
            labels.append(positive)
        }

        let balanced = try XCTUnwrap(LogisticRegressionFitter.fit(rows: rows, labels: labels))
        let unweighted = try XCTUnwrap(LogisticRegressionFitter.fit(rows: rows, labels: labels,
                                                                   balanced: false))

        // The rare class sits at the high end of column 0, so a balanced fit puts more of its
        // probability mass there.
        XCTAssertGreaterThan(balanced.probability([3.0, 2.0]), unweighted.probability([3.0, 2.0]))
        XCTAssertGreaterThan(balanced.probability([3.0, 2.0]), 0.5)
    }

    /// The overflow guard. A decision of −800 is reachable from a separable fold, and the naive
    /// `1/(1+exp(-x))` returns NaN there — which then propagates into every metric silently.
    func testSigmoidSurvivesExtremeDecisions() {
        XCTAssertEqual(LogisticMath.sigmoid(-800), 0, accuracy: 1e-12)
        XCTAssertEqual(LogisticMath.sigmoid(800), 1, accuracy: 1e-12)
        XCTAssertTrue(LogisticMath.sigmoid(-800).isFinite)
        XCTAssertTrue(LogisticMath.sigmoid(800).isFinite)
    }

    /// The shipped prior scores; its two headline coefficients keep the signs the notebook
    /// found. This is the constant-file guard — a mis-transcribed sign would flip the model
    /// from "a fall above today's average" to "a fall below it" and nothing else would fail.
    func testShippedPriorCarriesTheNotebooksSigns() {
        let window = WellbeingRiskPrior.window

        XCTAssertGreaterThan(window.coefficients[RiskFeature.drop6hHPa.rawValue], 1.0)
        XCTAssertLessThan(window.coefficients[RiskFeature.dayDrop6hHPa.rawValue], -1.0)
        XCTAssertEqual(window.coefficients.count, RiskFeature.windowColumns.count)
        XCTAssertEqual(WellbeingRiskPrior.day.coefficients.count, RiskFeature.dayColumns.count)
    }

    /// The prior's calibration puts a neutral day at the notebook's own base rate.
    ///
    /// The sign convention of `(a, b)` is the easiest thing in this subsystem to get backwards,
    /// and getting it backwards produces a number that is still between 0 and 1.
    func testPriorCalibrationReproducesTheBaseRate() {
        let neutral = WellbeingRiskPrior.dayCalibration.probability(ofDecision: 0)

        XCTAssertEqual(neutral, WellbeingRiskPrior.dayBaseRate, accuracy: 0.03)
    }
}
