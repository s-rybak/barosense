import XCTest
@testable import Barosense

/// The one type both producers write, and the band that says which of them wrote it.
final class ForecastPressurePointTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let offset = PressureOffset(offsetHPa: -22,
                                        referenceTemperatureC: 15,
                                        pairCount: 24,
                                        uncertaintyHPa: 0.2)

    // MARK: - The band

    /// Acceptance criterion 5 of PR 3. Both sources carry a band, and the local model's is
    /// **wider** — that asymmetry is the honest statement of what a single sensor at one point
    /// can and cannot see, and it is what stops a 6 h local guess reading like a 6 h WeatherKit
    /// curve.
    func testTheLocalModelsBandIsWiderThanWeatherKitsAtEveryHorizon() {
        for hours in [1.0, 3.0, 6.0] {
            let lead = hours * 3600
            let weatherKit = ForecastSource.weatherKit.uncertaintyHPa(atLeadSeconds: lead)
            let local = ForecastSource.localModel.uncertaintyHPa(atLeadSeconds: lead)

            XCTAssertGreaterThan(weatherKit, 0, "a band of zero would be a claim of certainty")
            XCTAssertGreaterThan(local, weatherKit, "at \(hours) h ahead")
        }
    }

    func testTheBandWidensWithHorizon() {
        for source in ForecastSource.allCases {
            XCTAssertGreaterThan(source.uncertaintyHPa(atLeadSeconds: 6 * 3600),
                                 source.uncertaintyHPa(atLeadSeconds: 3600))
        }
    }

    /// The local model sees hours, WeatherKit days. Not a placeholder — a human confirmed the
    /// 3–6 h range, and extending it needs a skill measurement rather than a wider constant.
    func testTheLocalModelsRangeIsHoursAndWeatherKitsIsDays() {
        XCTAssertEqual(ForecastSource.localModel.rangeSeconds, 6 * 3600)
        XCTAssertEqual(ForecastSource.weatherKit.rangeSeconds, 240 * 3600)
    }

    func testTheBandEdgesStraddleTheValue() {
        let point = ForecastPressurePoint(timestamp: now,
                                          pressure: Pressure(hectopascals: 1000),
                                          uncertaintyHPa: 1.5,
                                          source: .weatherKit,
                                          issuedAt: now)

        XCTAssertEqual(point.lowerHPa, 998.5, accuracy: 0.001)
        XCTAssertEqual(point.upperHPa, 1001.5, accuracy: 0.001)
    }

    // MARK: - Building the curve

    /// The whole reason the offset exists: the drawn curve has to land on the user's own axis.
    func testTheCurveIsBuiltInBarometerCoordinates() {
        let curve = ForecastPressurePoint.curve(from: [archived(hoursAhead: 1, mslp: 1013)],
                                                offset: offset,
                                                asOf: now,
                                                horizonSeconds: 24 * 3600)

        XCTAssertEqual(curve.count, 1)
        XCTAssertEqual(curve.first?.pressure.hectopascals ?? 0, 991, accuracy: 0.05)
    }

    func testPastHoursAreNotPartOfTheForwardHalf() {
        let curve = ForecastPressurePoint.curve(
            from: [archived(hoursAhead: -2, mslp: 1013), archived(hoursAhead: 2, mslp: 1011)],
            offset: offset,
            asOf: now,
            horizonSeconds: 24 * 3600
        )

        XCTAssertEqual(curve.count, 1)
        XCTAssertEqual(curve.first?.timestamp, now.addingTimeInterval(2 * 3600))
    }

    /// Two issues covering the same hour would otherwise draw a line zig-zagging between two
    /// model runs. The newest wins, which is the same rule the feature pipeline applies.
    func testTheNewestIssueWinsForAnHourCoveredTwice() {
        let hour = now.addingTimeInterval(3 * 3600)
        let older = WeatherForecastPoint(issuedAt: now.addingTimeInterval(-6 * 3600),
                                         validAt: hour,
                                         meanSeaLevelPressureHPa: 1013,
                                         temperatureC: 15)
        let newer = WeatherForecastPoint(issuedAt: now.addingTimeInterval(-3600),
                                         validAt: hour,
                                         meanSeaLevelPressureHPa: 1005,
                                         temperatureC: 15)

        let curve = ForecastPressurePoint.curve(from: [newer, older],
                                                offset: offset,
                                                asOf: now,
                                                horizonSeconds: 24 * 3600)

        XCTAssertEqual(curve.count, 1)
        XCTAssertEqual(curve.first?.pressure.hectopascals ?? 0, 983, accuracy: 0.05)
    }

    func testTheCurveIsClippedToTheHorizonAsked() {
        let points = (1...48).map { archived(hoursAhead: Double($0), mslp: 1013) }

        let curve = ForecastPressurePoint.curve(from: points,
                                                offset: offset,
                                                asOf: now,
                                                horizonSeconds: 12 * 3600)

        XCTAssertEqual(curve.count, 12)
    }

    /// Lead is measured from the moment the user is looking, not from when the issue was made:
    /// an hour that was six hours out at 08:00 is one hour out at 13:00, and the band has to
    /// close as it approaches.
    func testTheBandIsMeasuredFromNowRatherThanFromTheIssue() {
        let stale = WeatherForecastPoint(issuedAt: now.addingTimeInterval(-11 * 3600),
                                         validAt: now.addingTimeInterval(3600),
                                         meanSeaLevelPressureHPa: 1013,
                                         temperatureC: 15)

        let curve = ForecastPressurePoint.curve(from: [stale],
                                                offset: offset,
                                                asOf: now,
                                                horizonSeconds: 24 * 3600)

        let expected = ForecastSource.weatherKit.uncertaintyHPa(atLeadSeconds: 3600)
            + offset.uncertaintyHPa
        XCTAssertEqual(curve.first?.uncertaintyHPa ?? 0, expected, accuracy: 0.001)
    }

    /// The offset's own spread is part of the band. A forecast drawn from a shakily measured
    /// offset is less certain than one drawn from a firm one, and the chart may say so.
    func testTheOffsetsOwnUncertaintyWidensTheBand() {
        let shaky = PressureOffset(offsetHPa: -22,
                                   referenceTemperatureC: 15,
                                   pairCount: 6,
                                   uncertaintyHPa: 2.5)

        let firm = ForecastPressurePoint.curve(from: [archived(hoursAhead: 1, mslp: 1013)],
                                               offset: offset,
                                               asOf: now,
                                               horizonSeconds: 24 * 3600)
        let loose = ForecastPressurePoint.curve(from: [archived(hoursAhead: 1, mslp: 1013)],
                                                offset: shaky,
                                                asOf: now,
                                                horizonSeconds: 24 * 3600)

        XCTAssertGreaterThan(loose.first?.uncertaintyHPa ?? 0, firm.first?.uncertaintyHPa ?? 0)
    }

    private func archived(hoursAhead: Double, mslp: Double) -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: now,
                             validAt: now.addingTimeInterval(hoursAhead * 3600),
                             meanSeaLevelPressureHPa: mslp,
                             temperatureC: 15)
    }
}
