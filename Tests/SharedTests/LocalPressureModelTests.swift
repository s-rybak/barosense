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
    func testACompleteFirstDayIsNotTreatedAsAThreePercentCoveredMonth() {
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

    /// Asking for 24 hours gets 6, silently and on purpose. The limit is physical — one sensor
    /// at one point cannot see advection — so it is not something a caller may raise.
    func testTheHorizonIsClippedToWhatASingleBarometerCanKnow() {
        guard let model = LocalPressureModel.fit(to: hourlyLog(hours: 72, hPaPerHour: -0.2),
                                                 asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 24 * 3600)

        XCTAssertEqual(curve.count, 6)
        XCTAssertLessThanOrEqual(curve.last?.timestamp.timeIntervalSince(now) ?? .infinity,
                                 ForecastSource.localModel.rangeSeconds)
    }

    // MARK: - Skill against persistence

    /// The §7 comparison, on the one case where the model should clearly win: a steady trend.
    /// Persistence projects no change at all; three autoregressive lags carry the slope.
    ///
    /// The result at 1/3/6 h goes in the PR body whichever way it comes out.
    func testItBeatsPersistenceOnASteadyTrend() {
        let log = hourlyLog(hours: 24 * 10, hPaPerHour: -0.25)
        guard let model = LocalPressureModel.fit(to: log, asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)
        let lastObserved = log.last?.pressure.hectopascals ?? 0

        for point in curve {
            let hoursAhead = point.timestamp.timeIntervalSince(now) / 3600
            let truth = lastObserved - 0.25 * hoursAhead
            let modelError = abs(point.pressure.hectopascals - truth)
            let persistenceError = abs(lastObserved - truth)

            XCTAssertLessThan(modelError, persistenceError,
                              "at \(hoursAhead) h the model must beat persistence on a pure trend")
        }
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
        XCTAssertEqual(model.recentValues.count, LocalPressureModel.autoregressiveOrder)
    }

    /// And the consequence: a model anchored before a twelve-hour gap says nothing at all,
    /// because its whole range is six hours of extrapolation from the last hour it saw.
    func testAnAnchorOlderThanTheRangeProducesNoCurve() {
        let gapped = hourlyLog(hours: 24 * 7, hPaPerHour: -0.15).filter { sample in
            let hoursAgo = now.timeIntervalSince(sample.timestamp) / 3600
            return !(hoursAgo > 0.5 && hoursAgo < 12)
        }

        guard let model = LocalPressureModel.fit(to: gapped, asOf: now) else {
            return XCTFail("expected a fit")
        }

        XCTAssertTrue(model.forecast(asOf: now, horizonSeconds: 6 * 3600).isEmpty)
    }

    /// A log that stopped three hours ago has already spent three of its six, so it speaks for
    /// three more — and the band on the first of them is a four-step band, not a one-step one.
    func testTheRangeAndTheBandAreMeasuredFromTheLastObservedHour() {
        let stale = hourlyLog(hours: 72, hPaPerHour: -0.2).filter {
            $0.timestamp <= now.addingTimeInterval(-3 * 3600)
        }

        guard let model = LocalPressureModel.fit(to: stale, asOf: now) else {
            return XCTFail("expected a fit")
        }

        let curve = model.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertFalse(curve.isEmpty)
        XCTAssertLessThanOrEqual(curve.count, 3, "six hours from an anchor three hours old")
        let firstLead = (curve.first?.timestamp ?? now).timeIntervalSince(model.lastHour)
        XCTAssertEqual(curve.first?.uncertaintyHPa ?? 0,
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

    // MARK: - Fixtures

    /// Hourly readings ending at `now`, starting from 991 hPa — Kyiv station pressure — and
    /// moving at a constant rate, with the solar semidiurnal tide laid on top.
    ///
    /// The tide is in the fixture because it is the one thing this model knows that persistence
    /// does not, and a fixture without it would let a model that ignored the harmonics pass.
    private func hourlyLog(hours: Int, hPaPerHour: Double) -> [PressureSample] {
        (0...hours).map { step in
            let instant = now.addingTimeInterval(-TimeInterval(hours - step) * 3600)
            let secondsIntoDay = instant.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
            let tide = 0.4 * sin(2 * 2 * Double.pi * secondsIntoDay / 86_400)

            return PressureSample(timestamp: instant,
                                  pressure: Pressure(hectopascals: 991 + hPaPerHour * Double(step) + tide))
        }
    }
}
