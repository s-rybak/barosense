import XCTest
@testable import Barosense

/// How far past `now` each button draws, per producer.
///
/// Its own file because the table is the decision, not an implementation detail of
/// `PressureSeries`: it is what the user is asking for when they tap a wider range, and it is
/// the one number a change here is allowed to move. `PressureSeriesTests` covers what the
/// series does with a curve; this covers how much curve it is given.
final class PressureForecastWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func forecastPoint(hoursAhead: Double,
                               hPa: Double,
                               source: ForecastSource) -> ForecastPressurePoint {
        ForecastPressurePoint(
            timestamp: now.addingTimeInterval(hoursAhead * 3600),
            pressure: Pressure(hectopascals: hPa),
            uncertaintyHPa: source.uncertaintyHPa(atLeadSeconds: hoursAhead * 3600),
            source: source,
            issuedAt: now
        )
    }

    /// The table itself, both columns. Stated as literals rather than derived from the enum, so
    /// a change to what the card shows fails here and is read by a human before it ships.
    func testEachRangeDrawsItsOwnForwardWindowPerProducer() {
        let expected: [PressureChartRange: (weatherKit: Double, localModel: Double)] = [
            .oneHour: (4, 2.5),
            .threeHours: (12, 6),
            .sixHours: (48, 11),
            .day: (96, 18)
        ]

        for (range, hours) in expected {
            XCTAssertEqual(range.forecastSeconds(for: .weatherKit), hours.weatherKit * 3600,
                           "weatherKit column of \(range.rawValue)")
            XCTAssertEqual(range.forecastSeconds(for: .localModel), hours.localModel * 3600,
                           "localModel column of \(range.rawValue)")
        }
    }

    /// A column entry past its source's range is a horizon the producer silently refuses to
    /// fill: the chart would ask for it, the curve would stop short, and nothing would say why.
    func testNoColumnAsksForMoreThanItsProducerCanDraw() {
        for range in PressureChartRange.allCases {
            for source in ForecastSource.allCases {
                XCTAssertLessThanOrEqual(range.forecastSeconds(for: source), source.rangeSeconds,
                                         "\(range.rawValue) × \(source.rawValue)")
            }
        }
    }

    /// The window is a property of the producer as well as of the button. A local curve on the
    /// day range stops at 18 h where a WeatherKit one runs to 96 — clipped per point, so a curve
    /// that changed producer midway is cut correctly at both.
    func testTheLocalColumnIsClippedShorterThanTheWeatherKitOne() {
        let hours = (1...96).map(Double.init)
        let local = hours.map { forecastPoint(hoursAhead: $0, hPa: 1010, source: .localModel) }

        let series = PressureSeries.make(from: [], forecast: local, range: .day, asOf: now)

        XCTAssertEqual(series.forecast.count, 18)
        XCTAssertEqual(series.forecast.last?.timestamp, now.addingTimeInterval(18 * 3600))
    }

    /// The floor under every entry, checked where it actually binds: the local column's 2.5 h
    /// on the narrowest button.
    ///
    /// Both producers emit on whole hours, so a window shorter than 2 h holds one hour mark at
    /// some minutes of the hour and two at others — and `LineMark` renders nothing from a single
    /// vertex. 2.5 h is what makes two the worst case rather than the lucky one, which is why
    /// the entry is not the 2 h it could otherwise have been. Swept across the hour, because the
    /// minute `now` falls on is the variable that used to decide whether anything was drawn.
    func testTheNarrowestColumnStillDrawsALineAtEveryMinuteOfTheHour() {
        let hourMark = Date(timeIntervalSince1970: 1_769_997_600)
        let curve = (1...4).map { mark in
            ForecastPressurePoint(timestamp: hourMark.addingTimeInterval(Double(mark) * 3600),
                                  pressure: Pressure(hectopascals: 1010),
                                  uncertaintyHPa: 1,
                                  source: .localModel,
                                  issuedAt: hourMark)
        }

        for minute in [0, 1, 29, 30, 31, 59] {
            let asOf = hourMark.addingTimeInterval(Double(minute) * 60)
            let series = PressureSeries.make(from: [], forecast: curve, range: .oneHour, asOf: asOf)

            XCTAssertGreaterThanOrEqual(
                series.forecast.count, 2,
                "the local column at :\(minute) drew \(series.forecast.count) point(s)"
            )
        }
    }

    /// What the card asks the reader for: enough for whichever producer answers, which is not
    /// knowable before the read.
    func testTheLoadedWindowCoversTheWidestColumnOfTheWidestRange() {
        XCTAssertEqual(PressureChartRange.widest.maximumForecastSeconds, 96 * 3600)
    }
}
