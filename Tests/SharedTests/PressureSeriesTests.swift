import XCTest
@testable import Barosense

/// The piece that decides what the chart's line, figure and caption mean. Exercised with
/// literals and no sensor anywhere, which is the whole reason it lives in `Shared/`.
final class PressureSeriesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func sample(hoursAgo hours: Double, hPa: Double) -> PressureSample {
        PressureSample(timestamp: now.addingTimeInterval(-hours * 3600),
                       pressure: Pressure(hectopascals: hPa))
    }

    // MARK: - Range slicing

    func testRangeKeepsOnlySamplesInsideTheSelectedWindow() {
        let samples = [sample(hoursAgo: 20, hPa: 1020),
                       sample(hoursAgo: 5, hPa: 1015),
                       sample(hoursAgo: 0.5, hPa: 1010)]

        let series = PressureSeries.make(from: samples, range: .sixHours, asOf: now)

        XCTAssertEqual(series.observed.map(\.pressure.hectopascals), [1015, 1010])
    }

    func testObservedSamplesComeBackAscendingWhateverTheInputOrder() {
        let samples = [sample(hoursAgo: 1, hPa: 1011),
                       sample(hoursAgo: 5, hPa: 1015),
                       sample(hoursAgo: 3, hPa: 1013)]

        let series = PressureSeries.make(from: samples, range: .day, asOf: now)

        XCTAssertEqual(series.observed.map(\.pressure.hectopascals), [1015, 1013, 1011])
        XCTAssertEqual(series.latest?.pressure.hectopascals, 1011)
    }

    /// Switching the range must not change the caption. It describes the last three hours,
    /// not whichever button happens to be selected.
    func testTrendIsComputedFromFullHistoryNotFromTheSelectedRange() {
        let samples = [sample(hoursAgo: 2.5, hPa: 1016),
                       sample(hoursAgo: 0.1, hPa: 1010)]

        let oneHour = PressureSeries.make(from: samples, range: .oneHour, asOf: now)
        let day = PressureSeries.make(from: samples, range: .day, asOf: now)

        XCTAssertEqual(oneHour.observed.count, 1, "only the recent sample is inside one hour")
        XCTAssertEqual(oneHour.trend, .falling)
        XCTAssertEqual(day.trend, .falling)
    }

    // MARK: - Trend

    func testFallingPressureAcrossThreeHoursReadsAsFalling() {
        let samples = [sample(hoursAgo: 2.5, hPa: 1016), sample(hoursAgo: 0, hPa: 1012)]
        XCTAssertEqual(PressureTrend.make(from: samples, asOf: now), .falling)
    }

    func testRisingPressureAcrossThreeHoursReadsAsRising() {
        let samples = [sample(hoursAgo: 2.5, hPa: 1008), sample(hoursAgo: 0, hPa: 1013)]
        XCTAssertEqual(PressureTrend.make(from: samples, asOf: now), .rising)
    }

    func testChangeBelowThresholdReadsAsSteady() {
        let samples = [sample(hoursAgo: 2.5, hPa: 1013), sample(hoursAgo: 0, hPa: 1013.4)]
        XCTAssertEqual(PressureTrend.make(from: samples, asOf: now), .steady)
    }

    /// A large change measured across a few minutes is noise or an elevator, not a tendency.
    /// It must not be scaled up into a confident arrow.
    func testTooShortASpanRefusesToReportATendency() {
        let samples = [sample(hoursAgo: 0.2, hPa: 1016), sample(hoursAgo: 0, hPa: 1010)]
        XCTAssertEqual(PressureTrend.make(from: samples, asOf: now), .unknown)
    }

    func testSamplesOlderThanTheTrendWindowAreIgnored() {
        // A big fall, but it finished four hours ago; the last three hours are flat.
        let samples = [sample(hoursAgo: 6, hPa: 1025),
                       sample(hoursAgo: 4, hPa: 1013),
                       sample(hoursAgo: 2.5, hPa: 1013.2),
                       sample(hoursAgo: 0, hPa: 1013)]

        XCTAssertEqual(PressureTrend.make(from: samples, asOf: now), .steady)
    }

    func testNoHistoryReportsUnknown() {
        XCTAssertEqual(PressureTrend.make(from: [], asOf: now), .unknown)
        XCTAssertEqual(PressureSeries.empty(asOf: now).trend, .unknown)
    }

    // MARK: - Domains

    func testValueDomainPadsAroundTheObservedRange() throws {
        let samples = [sample(hoursAgo: 2, hPa: 1010), sample(hoursAgo: 1, hPa: 1015)]
        let series = PressureSeries.make(from: samples, range: .sixHours, asOf: now)

        let domain = try XCTUnwrap(series.valueDomainHPa)
        XCTAssertLessThan(domain.lowerBound, 1010)
        XCTAssertGreaterThan(domain.upperBound, 1015)
    }

    /// A day with no movement at all must still have somewhere to draw. Without padding the
    /// domain would have zero height.
    func testFlatSeriesStillProducesANonDegenerateDomain() throws {
        let samples = [sample(hoursAgo: 2, hPa: 1013), sample(hoursAgo: 1, hPa: 1013)]
        let series = PressureSeries.make(from: samples, range: .sixHours, asOf: now)

        let domain = try XCTUnwrap(series.valueDomainHPa)
        XCTAssertGreaterThanOrEqual(domain.upperBound - domain.lowerBound, 2)
    }

    func testEmptySeriesHasNoValueDomain() {
        XCTAssertNil(PressureSeries.empty(asOf: now).valueDomainHPa)
    }

    /// Two readings twelve minutes apart must occupy twelve minutes of a one-hour plot, not
    /// stretch across it and claim an hour of coverage that was never observed.
    func testTimeDomainSpansTheWholeRangeNotJustTheObservedSamples() {
        let samples = [sample(hoursAgo: 0.2, hPa: 1013), sample(hoursAgo: 0, hPa: 1013)]
        let series = PressureSeries.make(from: samples, range: .oneHour, asOf: now)

        XCTAssertEqual(series.timeDomain.lowerBound, now.addingTimeInterval(-3600))
        XCTAssertGreaterThanOrEqual(series.timeDomain.upperBound, now)
    }

    // MARK: - Forecast

    func testForecastValuesInThePastAreDropped() {
        let stale = PressureSample(timestamp: now.addingTimeInterval(-600),
                                   pressure: Pressure(hectopascals: 1011))
        let ahead = PressureSample(timestamp: now.addingTimeInterval(3600),
                                   pressure: Pressure(hectopascals: 1009))

        let series = PressureSeries.make(from: [], forecast: [ahead, stale], range: .day, asOf: now)

        XCTAssertEqual(series.forecast.map(\.pressure.hectopascals), [1009])
    }

    /// Forward-looking values are a separate family and must never be mistaken for sensor
    /// readings — the figure on the card is the last thing the barometer actually measured.
    func testForecastNeverBecomesTheLatestReading() {
        let ahead = PressureSample(timestamp: now.addingTimeInterval(3600),
                                   pressure: Pressure(hectopascals: 1009))
        let series = PressureSeries.make(from: [sample(hoursAgo: 1, hPa: 1014)],
                                         forecast: [ahead],
                                         range: .sixHours,
                                         asOf: now)

        XCTAssertEqual(series.latest?.pressure.hectopascals, 1014)
        XCTAssertFalse(series.isEmpty)
    }

    // MARK: - Formatting

    /// A locale that groups thousands with a period turns 1013.2 into `1.013,2`, which in a
    /// four-digit measurement reads as a decimal point in the wrong place.
    ///
    /// Asserted by counting characters rather than against a literal, so the test says the
    /// same thing in every locale: the decimal separator is the only non-digit allowed, and
    /// a whole figure has none at all.
    func testHectopascalsAreNeverGroupedIntoThousands() {
        let whole = PressureFormat.roundedHectopascals(1013)
        XCTAssertEqual(whole.count, 4, "four bare digits, no grouping separator: \(whole)")
        XCTAssertTrue(whole.allSatisfy(\.isNumber))

        let precise = PressureFormat.hectopascals(1013.2)
        XCTAssertEqual(precise.filter(\.isNumber).count, 5, "1013.2 is five digits: \(precise)")
        XCTAssertEqual(precise.filter { !$0.isNumber }.count, 1,
                       "only the decimal separator may be a non-digit: \(precise)")
    }

    func testForecastAloneStillLeavesTheSeriesEmpty() {
        let ahead = PressureSample(timestamp: now.addingTimeInterval(3600),
                                   pressure: Pressure(hectopascals: 1009))
        let series = PressureSeries.make(from: [], forecast: [ahead], range: .day, asOf: now)

        XCTAssertTrue(series.isEmpty, "the card must show its empty state until the sensor reports")
    }
}
