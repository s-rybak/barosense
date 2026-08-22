import XCTest
@testable import Barosense

/// The forecast the app can make with no network at all, and the fixtures §8 requires it to
/// survive.
final class LocalPressureModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Cold start

    /// Acceptance criterion 1 of PR 5, and `CLAUDE.md` constraint 5 in its smallest form: the
    /// model has to produce something useful from **one day**. A design that needed weeks
    /// before it said anything would be the wrong design however good it eventually got.
    func testItFitsAndForecastsOnASingleDayOfHistory() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 24, hPaPerHour: -0.3),
                                                 asOf: now) else {
            return XCTFail("one day of hourly readings must be enough to fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertGreaterThanOrEqual(model.rowCount, LocalPressureModel.minimumTrainingRows)
        XCTAssertFalse(curve.isEmpty)
        XCTAssertTrue(curve.allSatisfy { $0.source == .localModel })
    }

    /// The cold-start band. A complete day of readings is a *complete* log, not a 3%-covered
    /// one — the other 29 days of the training window are hours the app did not exist for.
    ///
    /// Measured against the window they inflated the band fivefold: ±22 hPa at six hours, which
    /// then set the whole y-domain of the chart and flattened the user's own line into it.
    /// Measured against the span the log reaches across, a clean day is a clean day.
    func testACompleteFirstDayIsNotCountedAsAThreePercentCoveredMonth() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 24, hPaPerHour: -0.3),
                                                 asOf: now) else {
            return XCTFail("one day of hourly readings must be enough to fit")
        }

        XCTAssertEqual(model.coverage, 1, accuracy: 0.05)
        // The nominal six-hour band is 0.8 + 0.6 × 6 = 4.4 hPa; a clean fixture adds almost
        // nothing to it. The number this replaces was 22.
        XCTAssertLessThan(model.uncertaintyHPa(atLeadSeconds: 6 * 3600), 6)
    }

    /// And the §8 "user with 3 days" fixture, which is the cold-start case the whole product is
    /// specified against.
    func testThreeDaysOfHistoryProducesAUsableCurve() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("three days must fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertEqual(curve.count, 6)
        // A steady fall continues rather than reverting to the mean.
        XCTAssertLessThan(curve.last?.pressure.hectopascals ?? 0,
                          curve.first?.pressure.hectopascals ?? 0)
    }

    /// Four readings is not a model. Returning `nil` is the honest answer — a line drawn from
    /// them would still be a claim, and the chart draws no forward half instead.
    func testTooLittleHistoryProducesNoModelAtAll() {
        XCTAssertNil(LocalPressureModel.fit(to: hourlyLog(hours: 4, hPaPerHour: -0.3), asOf: now))
    }

    // MARK: - The range is a property, not a parameter

    /// Asking for the chart's widest window — 96 h, WeatherKit's column on the day range — gets
    /// 18, silently and on purpose. The range is a property of the producer, not a parameter.
    func testTheHorizonIsClippedToTheProducersOwnRange() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 96 * 3600)

        XCTAssertEqual(curve.count, 18)
        XCTAssertLessThanOrEqual(curve.last?.timestamp.timeIntervalSince(now) ?? .infinity,
                                 ForecastSource.localModel.rangeSeconds)
    }

    /// The cold-start gate must not move when the drawn range does. `absoluteMinimumRows` is
    /// derived from the **skill** range, so drawing the chart to 18 h may not demand eighteen
    /// consecutive hourly cells before a device gets any forward half at all. The drawn range
    /// has moved twice already; this assertion is what keeps the gate out of it.
    func testTheDrawnRangeDoesNotMoveTheColdStartGate() {
        XCTAssertEqual(LocalPressureModel.absoluteMinimumRows, 6)
    }

    // MARK: - Skill against persistence

    /// The §7 comparison, on the one case where the model should clearly win: a steady trend.
    /// Persistence projects no change at all; three lagged tendencies carry the slope — damped,
    /// so the model claims rather less than the whole trend and still beats a claim of nothing.
    ///
    /// The result at 1/3/6 h goes in the PR body whichever way it comes out.
    func testItBeatsPersistenceOnASteadyTrend() {
        let log = hourlyLog(hours: 24 * 10, hPaPerHour: -0.25)
        guard let model = LocalPressureModel.fit(to: log, asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        for point in curve {
            let hoursAhead = point.timestamp.timeIntervalSince(now) / 3600
            let truth = continuation(of: log, at: point.timestamp, hPaPerHour: -0.25)
            let modelError = abs(point.pressure.hectopascals - truth)
            let persistenceError = abs((log.last?.pressure.hectopascals ?? 0) - truth)

            XCTAssertLessThan(modelError, persistenceError,
                              "at \(hoursAhead) h the model must beat persistence on a pure trend")
        }
    }

    /// The same §7 comparison on the log shape a phone actually produces — a waking-hours run
    /// beside an overnight hole, fitted on a reduced rung of the ladder — and the one place the
    /// answer is not a clean win.
    ///
    /// Scored against the fixture's own continuation over the six hours the skill range covers:
    ///
    /// | horizon | reduced rung | persistence |
    /// | ------- | -----------: | ----------: |
    /// | 0.8 h   |     0.18 hPa |    0.00 hPa |
    /// | 1.8 h   |     0.25     |    0.05     |
    /// | 2.8 h   |     0.30     |    0.10     |
    /// | 3.8 h   |     0.28     |    0.21     |
    /// | 4.8 h   |     0.17     |    0.40     |
    /// | 5.8 h   |     0.06     |    0.71     |
    /// | RMSE    |     0.22     |    0.35     |
    ///
    /// **Persistence wins the first four hours and the model wins the last two**, which is not
    /// a defect to fix — it is what the literature says and what this model's own documentation
    /// opens with: on 1–3 h horizons linear extrapolation is close to unbeatable, and what a fit
    /// buys is the part of the range where "no change" has stopped being true. So the assertion
    /// is over the window rather than at each hour, and the per-horizon split is written down
    /// here rather than smoothed away.
    ///
    /// The claim this replaces was a per-horizon win at every step. It passed only because it
    /// scored against a trend-only truth that the fixture — trend **plus** tide — never had.
    func testAReducedRungBeatsPersistenceAcrossTheSkillRange() {
        let log = wakingDayLog(hPaPerHour: -0.25)
        guard let model = LocalPressureModel.fit(to: log, asOf: now) else {
            return XCTFail("expected a fit")
        }
        XCTAssertLessThan(model.specification.parameterCount,
                          LocalPressureModel.richestSpecification.parameterCount,
                          "this fixture is only interesting while it lands below the top rung")

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)
        let persisted = log.last?.pressure.hectopascals ?? 0

        var modelSquares = 0.0
        var persistenceSquares = 0.0
        for point in curve {
            let truth = continuation(of: log, at: point.timestamp, hPaPerHour: -0.25)
            modelSquares += pow(point.pressure.hectopascals - truth, 2)
            persistenceSquares += pow(persisted - truth, 2)
        }

        let count = Double(max(curve.count, 1))
        let modelRMSE = (modelSquares / count).squareRoot()
        let persistenceRMSE = (persistenceSquares / count).squareRoot()

        XCTAssertFalse(curve.isEmpty)
        XCTAssertLessThan(modelRMSE, persistenceRMSE,
                          "reduced rung \(modelRMSE) hPa against persistence \(persistenceRMSE)")
    }

    // MARK: - §8 fixtures

    /// Acceptance criterion 5. A 10 hPa step in five minutes is a lift, not weather. It must
    /// never reach the fit — a model that learned it would forecast the user taking the stairs.
    func testAnAltitudeExcursionNeverReachesTheFit() {
        var log = hourlyLog(hours: 72, hPaPerHour: 0)
        // A ten-floor descent and its return, five minutes apart, in the middle of the log.
        let middle = log[36].timestamp
        log.append(PressureSample(timestamp: middle.addingTimeInterval(60),
                                  pressure: Pressure(hectopascals: 1001)))
        log.append(PressureSample(timestamp: middle.addingTimeInterval(360),
                                  pressure: Pressure(hectopascals: 991)))

        let kept = HourlyPressureGrid.rejectingExcursions(in: log)

        XCTAssertFalse(kept.contains { $0.pressure.hectopascals == 1001 })
        // And the fit still succeeds on what is left.
        XCTAssertNotNil(LocalPressureModel.fit(to: log, asOf: now))
    }

    /// Acceptance criterion 3. A twelve-hour hole is the ordinary overnight case on a phone
    /// that was not picked up; it must not break the fit, and the band has to open in response.
    func testATwelveHourHoleWidensTheBandRatherThanBreakingTheFit() {
        let full = hourlyLog(hours: 24 * 7, hPaPerHour: -0.15)
        let gapped = full.filter { sample in
            let hoursAgo = now.timeIntervalSince(sample.timestamp) / 3600
            return !(hoursAgo > 20 && hoursAgo < 32)
        }

        guard let dense = LocalPressureModel.fit(to: full, asOf: now),
              let sparse = LocalPressureModel.fit(to: gapped, asOf: now) else {
            return XCTFail("both logs must still fit")
        }

        XCTAssertLessThan(sparse.coverage, dense.coverage)
        XCTAssertGreaterThan(sparse.uncertaintyHPa(atLeadSeconds: 6 * 3600),
                             dense.uncertaintyHPa(atLeadSeconds: 6 * 3600))
        XCTAssertFalse(sparse.forecast(asOf: now, horizonSeconds: 6 * 3600).isEmpty)
    }

    /// The zero-variance fixture. A dead-flat log makes the normal matrix nearly singular; the
    /// ridge term is what turns that into a boring answer instead of a crash.
    func testAPerfectlyFlatLogDegradesGracefully() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: 0),
                                                 asOf: now) else {
            return XCTFail("a flat log is boring, not unfittable")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertFalse(curve.isEmpty)
        XCTAssertTrue(curve.allSatisfy { $0.pressure.hectopascals.isFinite })
        XCTAssertEqual(curve.last?.pressure.hectopascals ?? 0, 991, accuracy: 0.5)
    }

    // MARK: - The seed

    /// The seed lags have to be three **consecutive** hours. The grid omits holes, so the last
    /// three cells after an overnight gap can be an hour apart at one end and twelve at the
    /// other; fed in as lag1/lag2/lag3 they told the iteration that half a day of drift happened
    /// in two hours. Measured before the fix: 1.30 hPa of error at the first step, against a
    /// band that grew 1.5% — coverage is a statement about the whole window and cannot see a
    /// hole at the end of it.
    func testTheSeedNeverStraddlesAGap() {
        let gapped = hourlyLog(hours: 24 * 7, hPaPerHour: -0.15).filter { sample in
            let hoursAgo = now.timeIntervalSince(sample.timestamp) / 3600
            return !(hoursAgo > 0.5 && hoursAgo < 12)
        }

        guard let model = LocalPressureModel.fit(to: gapped, asOf: now) else {
            return XCTFail("a log with a gap at the end must still fit")
        }

        // The anchor is the last hour the sensor really did record three in a row, which is
        // before the gap — not the isolated cell on the near side of it.
        XCTAssertLessThan(model.lastHour, now.addingTimeInterval(-11 * 3600))
        // One level more than there are lags: the seed is a run of *changes*, and k changes
        // need k + 1 levels to exist at all.
        XCTAssertEqual(model.recentValues.count, LocalPressureModel.tendencyLagCount + 1)
    }

    /// And the consequence: a model whose last observed hour is further back than its range
    /// says nothing at all. The range is 18 hours of extrapolation **from that hour**, not
    /// 18 hours of wall clock, so a gap wider than it leaves nothing to say.
    func testAnAnchorOlderThanTheRangeProducesNoCurve() {
        let gapped = hourlyLog(hours: 24 * 7, hPaPerHour: -0.15).filter { sample in
            let hoursAgo = now.timeIntervalSince(sample.timestamp) / 3600
            return !(hoursAgo > 0.5 && hoursAgo < 20)
        }

        guard let model = LocalPressureModel.fit(to: gapped, asOf: now) else {
            return XCTFail("expected a fit")
        }

        XCTAssertTrue(model.forecast(asOf: now, horizonSeconds: 6 * 3600).isEmpty)
    }

    /// A log that stopped three hours ago has spent three of its eighteen. Both halves of that
    /// are measured from `lastHour` rather than from `now`: the curve stops three hours short of
    /// a full range, and the band on its first point is a four-step band, not a one-step one.
    func testTheRangeAndTheBandAreMeasuredFromTheLastObservedHour() {
        let stale = hourlyLog(hours: 72, hPaPerHour: -0.2).filter {
            $0.timestamp <= now.addingTimeInterval(-3 * 3600)
        }

        guard let model = LocalPressureModel.fit(to: stale, asOf: now) else {
            return XCTFail("expected a fit")
        }

        let full = model.forecast(asOf: now,
                                  horizonSeconds: ForecastSource.localModel.rangeSeconds)

        XCTAssertFalse(full.isEmpty)
        XCTAssertLessThanOrEqual(full.count, 15, "18 h from an anchor three hours old")
        let firstLead = (full.first?.timestamp ?? now).timeIntervalSince(model.lastHour)
        XCTAssertEqual(full.first?.uncertaintyHPa ?? 0,
                       model.uncertaintyHPa(atLeadSeconds: firstLead),
                       accuracy: 0.001)
    }

    // MARK: - The anchor hour

    /// The chart does not want the hour containing `now` — that half of the plot is
    /// measurements — and the feature pipeline cannot do without it, because a six-hour delta
    /// measured from the hour after `now` is a five-hour delta.
    func testTheAnchorHourIsEmittedOnlyWhenAskedFor() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        let chart = model.forecast(asOf: now, horizonSeconds: 6 * 3600)
        let features = model.forecast(asOf: now,
                                      horizonSeconds: 6 * 3600,
                                      includingAnchorHour: true)

        XCTAssertTrue(chart.allSatisfy { $0.timestamp > now })
        XCTAssertEqual(features.count, chart.count + 1)
        XCTAssertLessThanOrEqual(features.first?.timestamp ?? now, now)
        XCTAssertTrue(features.allSatisfy { $0.source == .localModel })
    }

    // MARK: - The band

    func testTheBandOpensWithHorizon() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        let widths = curve.map(\.uncertaintyHPa)
        XCTAssertEqual(widths, widths.sorted())
        XCTAssertGreaterThan(widths.last ?? 0, widths.first ?? 0)
    }

    /// And it is wider than WeatherKit's at the same horizon — the asymmetry the whole feature
    /// is honest about.
    func testTheBandIsWiderThanWeatherKitsAtTheSameHorizon() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        XCTAssertGreaterThan(model.uncertaintyHPa(atLeadSeconds: 6 * 3600),
                             ForecastSource.weatherKit.uncertaintyHPa(atLeadSeconds: 6 * 3600))
    }

    // MARK: - Cost

    /// Acceptance criterion 4: the refit is measured, and the number goes in the battery note.
    ///
    /// The bound is deliberately loose — this is a Debug build on a simulator sharing a machine
    /// with a compiler — because what it is guarding is the design claim that a daily refit
    /// needs no background task. Anything in this range does; a fit that took seconds would not.
    func testAFullThirtyDayRefitIsFastEnoughToRunOnAnActivation() {
        let log = hourlyLog(hours: 24 * 30, hPaPerHour: -0.05)

        let started = Date()
        let model = LocalPressureModel.fit(to: log, asOf: now)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertNotNil(model)
        XCTAssertLessThan(elapsed, 0.1, "refit took \(Int(elapsed * 1000)) ms")
    }

    // MARK: - The specification ladder

    /// The bug this ladder exists for, as the device actually produced it.
    ///
    /// A phone used through one afternoon and put down overnight: a run of waking hours beside
    /// a 14 h hole. 29 readings, 10 observed hourly cells — and **six** AR(3) design rows,
    /// because a hole restarts the count of consecutive lags and the three cells after one
    /// yield no row at all. Against the fixed eight-parameter fit that is `nil`: no forward
    /// half on the chart, on a day of entirely ordinary use.
    func testItFitsOnAWakingDayBesideAnOvernightGap() {
        guard let model = LocalPressureModel.fit(to: wakingDayLog(), asOf: now) else {
            return XCTFail("a waking day beside an overnight gap must produce a forecast")
        }

        XCTAssertFalse(model.forecast(asOf: now, horizonSeconds: 6 * 3600).isEmpty)
        // Not the richest size — the log cannot support eight parameters, and saying so is the
        // point. What it must not do is stay silent.
        XCTAssertLessThan(model.specification.parameterCount,
                          LocalPressureModel.richestSpecification.parameterCount)
    }

    /// The ladder must never trade down while a larger fit was available: a full hourly log
    /// still gets every term it can pay for.
    func testAFullLogStillFitsTheRichestSpecification() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("three days must fit")
        }

        XCTAssertEqual(model.specification, LocalPressureModel.richestSpecification)
        XCTAssertTrue(model.specification.includesHarmonics)
        // Three lagged changes and four harmonic terms. No intercept — a constant in an
        // equation about change is a permanent drift, and eighteen steps of one is a ramp.
        XCTAssertEqual(model.coefficients.count, 7)
    }

    /// Every rung is honestly sized: coefficients and seed are as wide as the specification
    /// says, never the old fixed three.
    func testTheFitIsAsWideAsItsSpecification() {
        guard let model = LocalPressureModel.fit(to: wakingDayLog(), asOf: now) else {
            return XCTFail("must fit")
        }

        XCTAssertEqual(model.coefficients.count, model.specification.parameterCount)
        XCTAssertEqual(model.recentValues.count, model.specification.tendencyLags + 1)
    }

    /// The row budget is one ratio applied at every size, and it reproduces the shipped gate
    /// exactly at the top of the ladder. A change to `minimumRowsPerParameter` that quietly
    /// loosened the richest fit would fail here rather than in review.
    func testTheRichestRungKeepsTheShippedRowBudget() {
        XCTAssertEqual(LocalPressureModel.richestSpecification.minimumRows, 11)
        XCTAssertEqual(LocalPressureModel.minimumTrainingRows, 11)
    }

    /// A thin fit has to *say* it is thin. The band comes off the residual degrees of freedom,
    /// so the six-row model cannot report the same confidence as the seventy-row one.
    func testAThinFitReportsAWiderBandThanAFullOne() {
        guard let thin = LocalPressureModel.fit(to: wakingDayLog(), asOf: now),
              let full = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                asOf: now) else {
            return XCTFail("both must fit")
        }

        XCTAssertGreaterThan(thin.uncertaintyHPa(atLeadSeconds: 6 * 3600),
                             full.uncertaintyHPa(atLeadSeconds: 6 * 3600))
    }

    /// The floor is still a floor. A log with no run of consecutive hours in it cannot support
    /// even AR(1), and the honest answer stays `nil` — a line drawn from that is still a claim.
    func testALogWithNoConsecutiveHoursStillFitsNothing() {
        // One reading every four hours. `HourlyPressureGrid` bridges holes of up to two hours,
        // so the spacing has to clear that plus the hour itself before no two cells are ever
        // neighbours.
        let scattered = (0..<12).map { step -> PressureSample in
            PressureSample(timestamp: now.addingTimeInterval(-TimeInterval(step) * 4 * 3600),
                           pressure: Pressure(hectopascals: 991 + Double(step) * 0.1))
        }

        XCTAssertNil(LocalPressureModel.fit(to: scattered, asOf: now))
    }

    // MARK: - The curve stays in the atmosphere

    /// The defect, reproduced from the trace that produced it.
    ///
    /// These are the 30 observed hourly cells the connected iPhone actually held on
    /// 2026-08-22. Fitted on **levels**, as this model was until that day, the least-squares
    /// polynomial came out with a root at **|λ| = 1.207** — station pressure is so nearly a
    /// random walk that an unconstrained fit is estimating a root sitting on the unit circle,
    /// and nothing was stopping it landing outside. The forward iteration then compounded it
    /// once per step: 1001 hPa at one hour, 1011 at six, and **1139 at eighteen**, against a
    /// world record of 1084. On screen that is a line that starts flat and leaves the top of
    /// the card, which is what a human reported.
    ///
    /// The bound here is deliberately physical rather than tuned: 20 hPa in 18 h is past
    /// bomb-cyclone scale, so anything failing it is not a forecast that is merely poor.
    func testTheRealDeviceTraceStaysInsideTheAtmosphere() {
        guard let model = LocalPressureModel.fit(to: deviceTrace(), asOf: now) else {
            return XCTFail("thirty observed cells over three days must fit")
        }

        let curve = model.forecast(asOf: now,
                                   horizonSeconds: ForecastSource.localModel.rangeSeconds)
        let anchor = model.recentValues.last ?? 0

        XCTAssertFalse(curve.isEmpty)
        for point in curve {
            XCTAssertLessThan(
                abs(point.pressure.hectopascals - anchor), 20,
                "\(point.timestamp.timeIntervalSince(now) / 3600) h out: "
                    + "\(point.pressure.hectopascals) hPa against an anchor of \(anchor)"
            )
        }
    }

    /// The mechanism, stated once and checked on every fixture in this file. Whatever the log,
    /// the fitted tendency may not outlive `maximumTendencyPersistence` — which is what makes
    /// the forward iteration converge instead of compound.
    func testNoFitEverKeepsAnExplosiveTendency() {
        let logs: [(String, [PressureSample])] = [
            ("the device trace", deviceTrace()),
            ("a steady fall", hourlyLog(hours: 72, hPaPerHour: -0.25)),
            ("a steady rise", hourlyLog(hours: 72, hPaPerHour: 0.25)),
            ("a flat log", hourlyLog(hours: 72, hPaPerHour: 0)),
            ("a waking day", wakingDayLog()),
            ("a month", hourlyLog(hours: 24 * 30, hPaPerHour: -0.05))
        ]

        for (label, log) in logs {
            guard let model = LocalPressureModel.fit(to: log, asOf: now) else {
                return XCTFail("\(label) must fit")
            }

            XCTAssertLessThanOrEqual(model.tendencyPersistence,
                                     LocalPressureModel.maximumTendencyPersistence,
                                     "\(label) kept a tendency that outlives the cap")
        }
    }

    /// What the cap buys, in hPa. A tendency decaying at `r` per hour sums to `d × r / (1 − r)`,
    /// so 0.9 caps the whole curve at nine times the last hourly change however long it is drawn
    /// for. A constant 1 hPa/h rise is therefore allowed to claim about 9 hPa and no more —
    /// where the level fit, on a gentler 0.57 hPa/h trace, claimed 139.
    func testTheCurveIsBoundedByNineTimesTheLastHourlyChange() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: 1),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now,
                                   horizonSeconds: ForecastSource.localModel.rangeSeconds)
        let anchor = model.recentValues.last ?? 0
        let ceiling = 9 * 1.0 + 2 * 0.4  // the trend's bound, plus room for the tide in the fixture

        XCTAssertFalse(curve.isEmpty)
        XCTAssertLessThan(curve.map { abs($0.pressure.hectopascals - anchor) }.max() ?? 0,
                          ceiling)
    }

    /// The other half of the same defect, and the reason damping the level fit was not the fix.
    ///
    /// A model fitted on levels reverts to its window mean, so on a log that has been rising
    /// the first projected hour came out *below* the last observed one — a forecast pointing
    /// the opposite way to the trace it was fitted on, at the one horizon where this model has
    /// any skill at all. Anchoring on the last level and projecting the change cannot do that:
    /// the first step is the anchor plus a damped copy of the tendency, so its sign is the
    /// observed tendency's.
    func testTheFirstStepContinuesTheObservedTendencyRatherThanRevertingToTheMean() {
        for rate in [0.5, -0.5] {
            guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: rate),
                                                     asOf: now) else {
                return XCTFail("expected a fit")
            }

            let anchor = model.recentValues.last ?? 0
            guard let first = model.forecast(asOf: now, horizonSeconds: 3600).first else {
                return XCTFail("expected a first point")
            }

            XCTAssertEqual((first.pressure.hectopascals - anchor).sign, rate.sign,
                           "a log moving at \(rate) hPa/h must not be forecast the other way")
        }
    }

    // MARK: - The ladder rejects an oscillating lag block

    /// The rung the tide leaked into, and the measurement that condemned it.
    ///
    /// On the waking-day fixture — a fall with the solar tide flattening it — the two-lag rung
    /// is the richest the rows allow, and it has no harmonic terms to put the tide in. It
    /// therefore identifies the tide *as its own dynamics*: a 20-hour oscillation inferred from
    /// a nine-hour window, which turns the fall into a rise by the second step. Scored against
    /// the fixture's own continuation over 1–6 h it reached **RMSE 0.60 hPa against
    /// persistence's 0.35** — a learned model losing to doing nothing, which
    /// `.claude/skills/ml_pipeline/SKILL.md` says must be reported rather than shipped. The
    /// one-lag rung below it scores 0.22.
    ///
    /// Damping is not what fixes this and was measured not to be: the two-lag rung loses at
    /// every cap from 0.85 to no damping at all.
    func testAnOscillatingRungWithNoHarmonicsIsPassedOver() {
        guard let model = LocalPressureModel.fit(to: wakingDayLog(), asOf: now) else {
            return XCTFail("must fit")
        }

        XCTAssertFalse(model.specification.includesHarmonics,
                       "this fixture cannot afford the harmonics; that is what makes it the case")
        XCTAssertEqual(model.specification.tendencyLags, 1,
                       "the two-lag fit here is the tide wearing the lags")
        XCTAssertFalse(
            LocalPressureModel.tendencyReversesWhenDrawn(Array(model.coefficients.prefix(1)))
        )
    }

    /// The check reads the impulse response, which is what the forward iteration propagates:
    /// a negative entry is the model turning a falling hour into a rising one from its own
    /// dynamics. A plain decay never does; a strongly negative second lag does.
    func testAReversalIsDetectedOnlyWhenTheLagsActuallyOscillate() {
        XCTAssertFalse(LocalPressureModel.tendencyReversesWhenDrawn([0.9]))
        XCTAssertFalse(LocalPressureModel.tendencyReversesWhenDrawn([0.5, 0.3]))
        XCTAssertTrue(LocalPressureModel.tendencyReversesWhenDrawn([1.804, -0.899]))
        XCTAssertTrue(LocalPressureModel.tendencyReversesWhenDrawn([-0.6]))
    }

    /// And the rung that *can* afford the harmonics keeps them, oscillating lags and all. The
    /// check applied everywhere would have cost the flat-log fixture an RMSE of 0.03 for one of
    /// 0.35 — the tide modelled properly, thrown away for the shape of the terms beside it.
    func testAHarmonicRungIsNotSubjectToTheOscillationCheck() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: 0),
                                                 asOf: now) else {
            return XCTFail("a flat log is boring, not unfittable")
        }

        XCTAssertEqual(model.specification, LocalPressureModel.richestSpecification)
    }

    // MARK: - Fixtures

    /// The shape the device really recorded: a 15 h hole, two hours of readings before it, and
    /// a nine-hour run of waking-hour sampling ending at `now`. Four readings an hour, which is
    /// `PressureSamplingPolicy`'s nominal cadence — the log is not thin because the sensor is
    /// slow, it is thin because iOS grants no wakes overnight.
    private func wakingDayLog(hPaPerHour: Double = -0.2) -> [PressureSample] {
        let hoursAgo = Array((22...23).reversed()) + Array((0...8).reversed())

        return hoursAgo.flatMap { hour -> [PressureSample] in
            (0..<4).map { slot in
                let instant = now.addingTimeInterval(-TimeInterval(hour) * 3600
                                                     + TimeInterval(slot) * 900)

                return PressureSample(
                    timestamp: instant,
                    pressure: Pressure(hectopascals: 991 + hPaPerHour * Double(-hour)
                                       + tideHPa(at: instant))
                )
            }
        }
    }

    /// What the fixture's own generating process holds at `instant`, forward of the log as
    /// well as inside it: the trend continued, plus the tide at that hour.
    ///
    /// Both fixtures are a linear trend with the solar semidiurnal tide laid on top, so a
    /// truth of "trend only" is a truth the fixture never had. Scoring against it credited the
    /// model for missing the tide when the tide happened to be near zero and punished it when
    /// it was not — and hid a rung that had turned a fall into a rise, because the trend-only
    /// line kept falling past it.
    private func continuation(of log: [PressureSample],
                              at instant: Date,
                              hPaPerHour: Double) -> Double {
        guard let last = log.last else { return 0 }

        let hours = instant.timeIntervalSince(last.timestamp) / 3600
        return last.pressure.hectopascals + hPaPerHour * hours
            + tideHPa(at: instant) - tideHPa(at: last.timestamp)
    }

    /// The S2 term both fixtures carry. One definition, so the fixtures and the truth they are
    /// scored against cannot drift apart.
    private func tideHPa(at instant: Date) -> Double {
        let secondsIntoDay = instant.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        return 0.4 * sin(2 * 2 * Double.pi * secondsIntoDay / 86_400)
    }

    /// The 30 observed hourly cells the connected iPhone held on 2026-08-22, as
    /// `(hours before now, hPa)`.
    ///
    /// Real data rather than a generated shape, because the generated shapes all passed. What
    /// broke the level fit is what a real opportunistic log looks like: two readings on the
    /// first evening, a 13-hour hole, an afternoon, a 9-hour hole, a morning that is missing
    /// its middle, and then five consecutive hours rising at 0.55 hPa/h at the very end. The
    /// bridged cells are left out — `HourlyPressureGrid` re-creates them, and hard-coding them
    /// would be asserting the grid's behaviour inside a model fixture.
    private func deviceTrace() -> [PressureSample] {
        let trace: [(Double, Double)] = [
            (67, 990.33), (66, 989.62),
            (52, 994.85), (50, 994.50), (49, 994.38), (48, 994.15), (47, 993.89),
            (46, 993.94), (45, 994.18), (44, 994.19), (43, 993.98), (42, 993.74),
            (33, 995.05), (31, 995.15), (28, 994.53), (26, 993.77), (25, 992.90),
            (24, 993.05), (23, 992.54), (22, 990.72), (21, 990.02), (20, 989.03),
            (19, 988.49), (18, 987.05),
            (8, 996.28),
            (4, 997.84), (3, 998.33), (2, 998.94), (1, 999.48), (0, 1000.05)
        ]

        return trace.map { hoursAgo, hectopascals in
            PressureSample(timestamp: now.addingTimeInterval(-hoursAgo * 3600),
                           pressure: Pressure(hectopascals: hectopascals))
        }
    }

    /// Hourly readings ending at `now`, starting from 991 hPa — Kyiv station pressure — and
    /// moving at a constant rate, with the solar semidiurnal tide laid on top.
    ///
    /// The tide is in the fixture because it is the one thing this model knows that persistence
    /// does not, and a fixture without it would let a model that ignored the harmonics pass.
    private func hourlyLog(hours: Int, hPaPerHour: Double) -> [PressureSample] {
        (0...hours).map { step in
            let instant = now.addingTimeInterval(-TimeInterval(hours - step) * 3600)

            return PressureSample(
                timestamp: instant,
                pressure: Pressure(hectopascals: 991 + hPaPerHour * Double(step)
                                   + tideHPa(at: instant))
            )
        }
    }
}
