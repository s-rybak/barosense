import XCTest
@testable import Barosense

/// The §7 baseline comparison, made possible on-device by keeping past forecasts.
///
/// The point of these cases is that a **loss** is reported as clearly as a win. A forecast that
/// cannot beat "pressure will stay where it is" costs battery and adds risk for nothing, and the
/// honest response is to shorten the range rather than to stop printing the table.
final class ForecastSkillReportTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Winning and losing

    /// A forecast that tracked a real fall beats persistence, which by definition predicted no
    /// fall at all.
    func testAForecastThatTrackedTheFallBeatsPersistence() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.8)
        let forecasts = perfectForecasts(from: truth, leadHours: 6)

        let report = ForecastSkillEvaluator.evaluate(forecasts: forecasts,
                                                    observed: truth,
                                                    source: .weatherKit,
                                                    asOf: now)

        guard let sixHour = report.horizons.first(where: { $0.hours == 6 }) else {
            return XCTFail("expected a 6 h row")
        }
        XCTAssertGreaterThan(sixHour.pairCount, 0)
        XCTAssertTrue(sixHour.beatsPersistence)
        XCTAssertEqual(sixHour.forecastMeanAbsoluteErrorHPa, 0, accuracy: 0.001)
        // Persistence was wrong by the whole six hours of fall.
        XCTAssertEqual(sixHour.persistenceMeanAbsoluteErrorHPa, 4.8, accuracy: 0.001)
    }

    /// The case the risk register names: a forecast that is worse than doing nothing. It has to
    /// come out of the table as a negative number, not as an absent row.
    func testAForecastWorseThanPersistenceReportsANegativeSkillScore() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.2)
        // Predicts a sharp rise while pressure actually eased down.
        let forecasts = perfectForecasts(from: truth, leadHours: 6, biasHPa: 6)

        let report = ForecastSkillEvaluator.evaluate(forecasts: forecasts,
                                                    observed: truth,
                                                    source: .weatherKit,
                                                    asOf: now)

        guard let sixHour = report.horizons.first(where: { $0.hours == 6 }),
              let skill = sixHour.skillScore else {
            return XCTFail("expected a scored 6 h row")
        }
        XCTAssertLessThan(skill, 0)
        XCTAssertFalse(sixHour.beatsPersistence)
        XCTAssertTrue(report.summary.contains("6h"), report.summary)
    }

    // MARK: - Degrading gracefully

    /// §8's zero-variance fixture in its pressure form. A dead-flat stretch makes persistence
    /// perfect, so the skill ratio is undefined — and the honest answer is "this window says
    /// nothing", not a division by zero and not a fabricated zero.
    func testAFlatStretchLeavesTheSkillScoreUndefinedRatherThanDividingByZero() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: 0)
        let forecasts = perfectForecasts(from: truth, leadHours: 6)

        let report = ForecastSkillEvaluator.evaluate(forecasts: forecasts,
                                                    observed: truth,
                                                    source: .weatherKit,
                                                    asOf: now)

        guard let sixHour = report.horizons.first(where: { $0.hours == 6 }) else {
            return XCTFail("expected a 6 h row")
        }
        XCTAssertGreaterThan(sixHour.pairCount, 0)
        XCTAssertNil(sixHour.skillScore)
        XCTAssertFalse(sixHour.beatsPersistence)
    }

    /// Every horizon is present even with nothing to score, so a missing row can never be read
    /// as a horizon somebody quietly skipped.
    func testEveryHorizonIsReportedEvenWithNothingToScore() {
        let report = ForecastSkillEvaluator.evaluate(forecasts: [],
                                                    observed: [],
                                                    source: .weatherKit,
                                                    asOf: now)

        XCTAssertEqual(report.horizons.map(\.hours), ForecastSkillEvaluator.horizonHours)
        XCTAssertTrue(report.horizons.allSatisfy { $0.pairCount == 0 })
        XCTAssertTrue(report.measuredHorizons.isEmpty)
        XCTAssertTrue(report.summary.contains("no realised forecasts"), report.summary)
    }

    /// An overnight gap is ordinary — the phone is asleep. An hour with no reading near it is
    /// dropped rather than scored against the nearest thing available.
    func testHoursWithNoReadingNearThemAreNotScored() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.5)
        let forecasts = perfectForecasts(from: truth, leadHours: 6)
        // Keep only the oldest four hours of the log: most forecast hours now have no truth.
        let gapped = Array(truth.prefix(4))

        let report = ForecastSkillEvaluator.evaluate(forecasts: forecasts,
                                                    observed: gapped,
                                                    source: .weatherKit,
                                                    asOf: now)

        let sixHour = report.horizons.first { $0.hours == 6 }
        XCTAssertEqual(sixHour?.pairCount, 0)
    }

    // MARK: - What is scored

    /// A forecast whose hour has not arrived is still a claim about the future. Scoring it
    /// against the nearest reading available would be scoring it against the present.
    func testForecastsWhoseHourHasNotArrivedAreNotScored() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.5)
        let future = [
            ForecastPressurePoint(timestamp: now.addingTimeInterval(6 * 3600),
                                  pressure: Pressure(hectopascals: 900),
                                  uncertaintyHPa: 1,
                                  source: .weatherKit,
                                  issuedAt: now)
        ]

        let report = ForecastSkillEvaluator.evaluate(forecasts: future,
                                                    observed: truth,
                                                    source: .weatherKit,
                                                    asOf: now)

        XCTAssertTrue(report.measuredHorizons.isEmpty)
    }

    /// Two producers are two different claims and are never averaged into one score. That is
    /// the whole reason `ForecastSource` travels on every point.
    func testAnotherSourcesForecastsAreIgnoredRatherThanMerged() {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.8)
        let weatherKit = perfectForecasts(from: truth, leadHours: 6)
        let local = perfectForecasts(from: truth,
                                     leadHours: 6,
                                     biasHPa: 9,
                                     source: .localModel)

        let report = ForecastSkillEvaluator.evaluate(forecasts: weatherKit + local,
                                                    observed: truth,
                                                    source: .weatherKit,
                                                    asOf: now)

        guard let sixHour = report.horizons.first(where: { $0.hours == 6 }) else {
            return XCTFail("expected a 6 h row")
        }
        XCTAssertEqual(sixHour.forecastMeanAbsoluteErrorHPa, 0, accuracy: 0.001)
    }

    /// The store-backed path, which is what the app runs. The archive is the only table
    /// involved: there is no parallel store of realised forecasts to keep in step.
    func testTheStoreBackedPathScoresAgainstTheBarometerLog() async throws {
        let truth = fallingLog(hoursBack: 12, hPaPerHour: -0.8)
        let samples = InMemoryPressureSampleStore(truth)
        let archive = InMemoryWeatherForecastStore()
        let offset = PressureOffset(offsetHPa: -22,
                                    referenceTemperatureC: 15,
                                    pairCount: 24,
                                    uncertaintyHPa: 0.2)

        // Issued six hours before each hour it describes, and exactly right — expressed as
        // MSLP, which is how the archive stores it.
        for sample in truth {
            try await archive.save([
                WeatherForecastPoint(issuedAt: sample.timestamp.addingTimeInterval(-6 * 3600),
                                     validAt: sample.timestamp,
                                     meanSeaLevelPressureHPa: sample.pressure.hectopascals + 22,
                                     temperatureC: 15)
            ])
        }

        let report = try await ForecastSkillEvaluator.evaluate(archive: archive,
                                                               samples: samples,
                                                               offset: offset,
                                                               asOf: now)

        guard let sixHour = report.horizons.first(where: { $0.hours == 6 }) else {
            return XCTFail("expected a 6 h row")
        }
        XCTAssertGreaterThan(sixHour.pairCount, 0)
        XCTAssertEqual(sixHour.forecastMeanAbsoluteErrorHPa, 0, accuracy: 0.05)
        XCTAssertTrue(sixHour.beatsPersistence)
    }

    // MARK: - Fixtures

    /// Hourly barometer readings ending at `now`.
    private func fallingLog(hoursBack: Int, hPaPerHour: Double) -> [PressureSample] {
        (0...hoursBack).map { step in
            PressureSample(timestamp: now.addingTimeInterval(-TimeInterval(hoursBack - step) * 3600),
                           pressure: Pressure(hectopascals: 991 + hPaPerHour * Double(step)))
        }
    }

    /// A forecast for each logged hour, issued `leadHours` earlier, optionally wrong by
    /// `biasHPa`.
    private func perfectForecasts(from log: [PressureSample],
                                  leadHours: Int,
                                  biasHPa: Double = 0,
                                  source: ForecastSource = .weatherKit) -> [ForecastPressurePoint] {
        log.map { sample in
            ForecastPressurePoint(
                timestamp: sample.timestamp,
                pressure: Pressure(hectopascals: sample.pressure.hectopascals + biasHPa),
                uncertaintyHPa: source.uncertaintyHPa(atLeadSeconds: TimeInterval(leadHours) * 3600),
                source: source,
                issuedAt: sample.timestamp.addingTimeInterval(-TimeInterval(leadHours) * 3600)
            )
        }
    }
}
