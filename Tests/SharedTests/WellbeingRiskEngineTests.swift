import XCTest
@testable import Barosense

/// The engine's own arithmetic: which windows it asks the model about.
///
/// The model's scoring is exercised on rows built by hand in `WellbeingRiskPipelineTests`.
/// What is only reachable here is the range `WellbeingRiskEngine` builds those rows over —
/// today's waking day out to `forecastHorizonSeconds` — and the two ends of it that are easy to
/// get wrong: a device with no forward curve at all, and a device asked before its user wakes.
final class WellbeingRiskEngineTests: XCTestCase {

    /// UTC, so the waking-day boundaries in the fixture do not move with the machine running
    /// the test.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// Ten in the evening on a day 60 days into the trace: today is nearly all measured, and
    /// there is a month of history behind it to fit on.
    private var referenceNow: Date {
        let geometry = RiskWindowGeometry(calendar: calendar)
        let day = geometry.wakingDayStart(
            of: SyntheticTraceFixture.start.addingTimeInterval(60 * 24 * 3600)
        )
        return day.addingTimeInterval(16 * 3600)
    }

    private func engine(asOf now: Date) -> WellbeingRiskEngine {
        WellbeingRiskEngine(
            samples: InMemoryPressureSampleStore(
                SyntheticTraceFixture.samples().filter { $0.timestamp < now }
            ),
            checkIns: InMemoryCheckInStore(
                SyntheticTraceFixture.checkIns().filter { $0.timestamp < now }
            ),
            calendar: calendar
        )
    }

    /// Widening the horizon to four days must not cost a device without a forward curve the one
    /// day it *can* answer for.
    ///
    /// The regression this guards is silent: the extra days have no cells, and a range that
    /// produced an empty or a half-covered day would take the whole forecast down with it — the
    /// engine returns `nil` on empty rows, and every surface then draws nothing at all.
    func testWithoutAForwardCurveOnlyTodayIsScored() async throws {
        let now = referenceNow
        let produced = await engine(asOf: now).forecast(asOf: now)
        let forecast = try XCTUnwrap(produced)

        let geometry = RiskWindowGeometry.measured(
            from: SyntheticTraceFixture.checkIns().filter { $0.timestamp < now },
            calendar: calendar
        )
        XCTAssertEqual(forecast.dayStart, geometry.wakingDayStart(of: now))
        XCTAssertEqual(Set(forecast.windows.map(\.dayStart)), [forecast.dayStart],
                       "nothing ahead of the log has a cell to be scored from")
        XCTAssertEqual(forecast.forecastShare, 0, accuracy: 1e-9,
                       "with no curve every scored hour is a measured one")
        XCTAssertTrue(forecast.marked.allSatisfy { $0.end > now },
                      "the evening is what is left of today")
    }

    /// Asked at three in the morning, the forecast is about a day none of which has happened.
    ///
    /// `wakingDayStart` returns 06:00 *today*, which is still ahead — so the range the engine
    /// builds runs forwards from a boundary later than `now`. Any arithmetic that assumed
    /// otherwise builds a range running backwards, which traps rather than returning `nil`.
    func testPreDawnDoesNotBuildARangeRunningBackwards() async throws {
        let geometry = RiskWindowGeometry(calendar: calendar)
        let preDawn = geometry.wakingDayStart(of: referenceNow).addingTimeInterval(-3 * 3600)

        // No curve and no measured hours inside a day that has not started: there is nothing to
        // score, and saying so is the correct answer rather than a failure.
        let forecast = await engine(asOf: preDawn).forecast(asOf: preDawn)
        XCTAssertNil(forecast)
    }

    /// The horizon is the one the chart draws, not a number of its own.
    ///
    /// Both sides of this are load-bearing: shorter and the widest button draws days the model
    /// silently declines to score; longer and the engine asks the reader for a curve nothing on
    /// screen can show.
    func testHorizonMatchesTheWidestDrawnForecast() {
        XCTAssertEqual(WellbeingRiskEngine.forecastHorizonSeconds,
                       PressureChartRange.day.forecastSeconds(for: .weatherKit))
        XCTAssertEqual(WellbeingRiskEngine.forecastHorizonSeconds,
                       PressureChartRange.widest.maximumForecastSeconds)
    }
}
