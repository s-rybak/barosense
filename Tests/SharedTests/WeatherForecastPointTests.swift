import XCTest
@testable import Barosense

/// The archive's value types: the two dates, and the two unit conversions on the WeatherKit
/// boundary.
final class WeatherForecastPointTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Units

    /// The 10× test §8 of `.claude/context/ml-spec.md` asks for, on the WeatherKit side.
    ///
    /// `Measurement<UnitPressure>`'s runtime unit is not documented, so a client that read
    /// `.value` directly would ship 101.3 as "101.3 hPa" the day WeatherKit answered in
    /// kilopascals — a pressure a tenth of anything the barometer records, and one that
    /// `Pressure.isPlausible` would then reject as a broken sensor.
    func testKilopascalsAreConvertedRatherThanReadRaw() {
        let kilopascals = Measurement(value: 101.3, unit: UnitPressure.kilopascals)

        XCTAssertEqual(WeatherMeasurement.hectopascals(kilopascals), 1013, accuracy: 0.001)
        // The failure this guards against, stated: the raw value is 10× off.
        XCTAssertNotEqual(WeatherMeasurement.hectopascals(kilopascals),
                          kilopascals.value,
                          accuracy: 1)
    }

    func testMillibarsAndHectopascalsAreTheSameNumber() {
        let millibars = Measurement(value: 1013.2, unit: UnitPressure.millibars)

        XCTAssertEqual(WeatherMeasurement.hectopascals(millibars), 1013.2, accuracy: 0.001)
    }

    /// Inches of mercury is the other unit a US-locale response could plausibly carry, and it
    /// is off by a factor of 33.
    func testInchesOfMercuryAreConverted() {
        let inches = Measurement(value: 29.92, unit: UnitPressure.inchesOfMercury)

        XCTAssertEqual(WeatherMeasurement.hectopascals(inches), 1013.2, accuracy: 0.5)
    }

    func testFahrenheitIsConvertedToCelsius() {
        let fahrenheit = Measurement(value: 68, unit: UnitTemperature.fahrenheit)

        XCTAssertEqual(WeatherMeasurement.celsius(fahrenheit), 20, accuracy: 0.001)
    }

    // MARK: - The two dates

    func testLeadTimeIsTheGapBetweenIssueAndValidity() {
        let point = WeatherForecastPoint(issuedAt: now,
                                         validAt: now.addingTimeInterval(6 * 3600),
                                         meanSeaLevelPressureHPa: 1013,
                                         temperatureC: 12)

        XCTAssertEqual(point.leadTimeSeconds, 6 * 3600, accuracy: 0.001)
    }

    /// An observation is knowable at the hour it describes and at no earlier one. That single
    /// choice is what makes bootstrap history structurally unable to leak: a feature at `t`
    /// reads issues with `issuedAt <= t` and looks at hours after `t`, and no row with
    /// `issuedAt == validAt` can satisfy both.
    func testAnObservationIsArchivedAsKnowableOnlyAtItsOwnHour() {
        let observation = WeatherObservation(validAt: now,
                                             meanSeaLevelPressureHPa: 1008,
                                             temperatureC: 5)

        let point = observation.asArchivedPoint()

        XCTAssertEqual(point.issuedAt, point.validAt)
        XCTAssertEqual(point.leadTimeSeconds, 0)
    }

    func testAnIssueSortsItsPointsByValidity() {
        let issue = WeatherForecastIssue(issuedAt: now, points: [
            point(validAt: now.addingTimeInterval(7200)),
            point(validAt: now.addingTimeInterval(3600))
        ])

        XCTAssertEqual(issue.points.map(\.validAt),
                       [now.addingTimeInterval(3600), now.addingTimeInterval(7200)])
    }

    // MARK: - Staleness

    /// The norm the feature registry used to state was ≤3 h, and it was wrong rather than
    /// merely tight: with slots at 08/12/16/20 the newest issue at 07:00 is eleven hours old,
    /// so a 3 h rule was violated most of the day — for a curve that still holds 229 valid
    /// hours ahead of it.
    func testAnElevenHourOldIssueIsStillInsideTheStalenessNorm() {
        let issue = WeatherForecastIssue(issuedAt: now, points: [point(validAt: now)])
        let elevenHoursLater = now.addingTimeInterval(11 * 3600)

        XCTAssertLessThanOrEqual(issue.ageSeconds(at: elevenHoursLater),
                                 WeatherForecastPolicy.maximumIssueAgeSeconds)
    }

    func testAnIssueOlderThanTwelveHoursIsOutsideIt() {
        let issue = WeatherForecastIssue(issuedAt: now, points: [point(validAt: now)])
        let nextDay = now.addingTimeInterval(13 * 3600)

        XCTAssertGreaterThan(issue.ageSeconds(at: nextDay),
                             WeatherForecastPolicy.maximumIssueAgeSeconds)
    }

    // MARK: - The requested horizon

    /// The number at the network boundary against the numbers on screen.
    ///
    /// The defect this pins: the provider asked for `.hourly` with no range, WeatherKit served
    /// its ~24 h default, and the 48 h and 96 h chart columns drew the archive dry less than a
    /// day out. Nothing downstream was wrong — the hours had never been fetched — and nothing
    /// anywhere said so, because the two numbers lived in different files with no relation
    /// between them. This is that relation.
    func testTheRequestReachesFurtherThanTheWidestColumnDraws() {
        for range in PressureChartRange.allCases {
            XCTAssertLessThanOrEqual(
                range.forecastSeconds(for: .weatherKit),
                WeatherForecastPolicy.requestedHorizonSeconds,
                "the \(range.rawValue) column draws hours the request never asks for"
            )
        }
    }

    /// A curve is measured forward from `now`, not from `issuedAt`, so the request has to
    /// cover the widest column **plus** the age an issue may reach and still be drawn. Twelve
    /// hours after it was fetched, the same issue is still expected to fill the day button.
    func testTheRequestCoversTheWidestColumnFromAnIssueAtTheEndOfItsLife() {
        XCTAssertGreaterThanOrEqual(
            WeatherForecastPolicy.requestedHorizonSeconds,
            PressureChartRange.widest.maximumForecastSeconds
                + WeatherForecastPolicy.maximumIssueAgeSeconds
        )
    }

    /// The two hours between "96 + 12" and what is actually asked for, pinned.
    ///
    /// WeatherKit answers with whole hours strictly inside the window, so a request made at
    /// `h:mm` comes back reaching `requested − 1 h − mm`. Measured on the device: 108 h asked
    /// at 22:06:57 returned a max lead of 106.88 h. At `:59` the loss is 1.98 h, so anything
    /// less than two hours of slack leaves the widest column short at the end of an issue's
    /// life — the defect this whole horizon exists to have fixed, one boundary further in.
    func testTheRequestCarriesEnoughSlackForTheServicesHourBoundary() {
        let worstCaseLossSeconds: TimeInterval = 2 * 3600

        XCTAssertGreaterThanOrEqual(
            WeatherForecastPolicy.requestedHorizonSeconds - worstCaseLossSeconds,
            PressureChartRange.widest.maximumForecastSeconds
                + WeatherForecastPolicy.maximumIssueAgeSeconds,
            "a request made at :59 would leave the day column short at the end of an issue's life"
        )
    }

    /// And no further than Apple documents. Asking past the source's own horizon is quota
    /// spent on rows that cannot come back.
    func testTheRequestStaysInsideTheSourcesDocumentedHorizon() {
        XCTAssertLessThanOrEqual(WeatherForecastPolicy.requestedHorizonSeconds,
                                 ForecastSource.weatherKit.rangeSeconds)
    }

    private func point(validAt: Date) -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: now,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: 1013,
                             temperatureC: 12)
    }
}
