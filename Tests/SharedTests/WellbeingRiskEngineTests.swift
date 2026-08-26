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

    // MARK: - What the two paths read

    /// A device too thin to fit on still refits at most once a day.
    ///
    /// The throttle used to require `training != nil` as well, which inverted it: under
    /// `minimumTrainingDays` of history there is no training, the condition never held, and the
    /// engine re-read 120 days of samples and check-ins on every cache miss — every 15 minutes,
    /// for as long as the device stayed in the state every new install starts in.
    func testAThinDeviceStillRefitsAtMostOnceADay() async throws {
        let start = SyntheticTraceFixture.start
        let now = start.addingTimeInterval(3.5 * 24 * 3600)
        let store = RecordingSampleStore(
            SyntheticTraceFixture.samples().filter { $0.timestamp < now }
        )
        let engine = WellbeingRiskEngine(samples: store,
                                         checkIns: InMemoryCheckInStore(),
                                         calendar: calendar)

        _ = await engine.forecast(asOf: now)
        // Past `forecastCacheSeconds`, so the memoised answer is gone and the work is redone.
        _ = await engine.forecast(asOf: now.addingTimeInterval(WellbeingRiskEngine.forecastCacheSeconds + 60))

        let trainingSpan = Double(WellbeingRiskTrainer.trainingWindowDays) * 24 * 3600
        let refits = await store.requestedRanges.count {
            $0.upperBound.timeIntervalSince($0.lowerBound) >= trainingSpan
        }
        XCTAssertEqual(refits, 1, "the second call inside a day must not re-read the window")
    }

    /// Two callers arriving at once get one fit between them, not one each.
    ///
    /// The Now screen has exactly two, `NowMetersModel` and `PressureChartModel`, on concurrent
    /// `.task`s of the same view — and after a saved check-in `invalidate()` puts both of them
    /// in front of a cold engine. An actor is reentrant at every `await`, and the cache is
    /// written last, so uncoalesced both miss it, both pass the `lastFitAt` guard while the
    /// other is suspended on the 120-day read, and the Newton solve runs twice for one screen.
    func testConcurrentCallersShareOneFit() async throws {
        let now = referenceNow
        let store = RecordingSampleStore(
            SyntheticTraceFixture.samples().filter { $0.timestamp < now }
        )
        let engine = WellbeingRiskEngine(
            samples: store,
            checkIns: InMemoryCheckInStore(
                SyntheticTraceFixture.checkIns().filter { $0.timestamp < now }
            ),
            calendar: calendar
        )

        async let first = engine.forecast(asOf: now)
        async let second = engine.forecast(asOf: now)
        let both = await [first, second]

        let trainingSpan = Double(WellbeingRiskTrainer.trainingWindowDays) * 24 * 3600
        let refits = await store.requestedRanges.count {
            $0.upperBound.timeIntervalSince($0.lowerBound) >= trainingSpan
        }
        XCTAssertEqual(refits, 1, "the second caller has to join the build, not start one")
        XCTAssertEqual(both[0], both[1], "and it has to get the same forecast out of it")
        XCTAssertNotNil(both[0])
    }

    /// The baseline is the 30-day median the fit used, not one measured over the forecast read.
    ///
    /// The forecast path reads eight days. Left to measure its own baseline from that, it
    /// centred every level feature on an eight-day median while the coefficients above it had
    /// been fitted against a thirty-day one — a train/serve skew that shows up nowhere, since
    /// both halves stay perfectly well-formed.
    func testTheForecastPathReusesTheFitsThirtyDayBaseline() async throws {
        let now = SyntheticTraceFixture.start.addingTimeInterval(30 * 24 * 3600)
        // A month at 995 hPa with the last eight days ten hPa above it: the two spans disagree
        // by more than any real day's weather, so a test that passes cannot be reading the
        // short one. Fifteen-minute spacing keeps the step outside the grid's excursion window,
        // which is ten minutes — it is a change of air mass here, not a lift ride.
        let step = now.addingTimeInterval(-8 * 24 * 3600)
        let samples = stride(from: -30 * 24 * 3600.0, to: 0, by: 900).map { offset -> PressureSample in
            let taken = now.addingTimeInterval(offset)
            return PressureSample(timestamp: taken,
                                  pressure: Pressure(hectopascals: taken < step ? 995 : 1005))
        }

        let store = RecordingSampleStore(samples)
        let engine = WellbeingRiskEngine(samples: store,
                                         checkIns: InMemoryCheckInStore(),
                                         calendar: calendar)
        _ = await engine.forecast(asOf: now)

        let measured = await engine.measuredBaseline()
        let baseline = try XCTUnwrap(measured)
        XCTAssertEqual(baseline.hectopascals, 995, accuracy: 0.5,
                       "the median of the month, not of the last eight days")
        XCTAssertNotEqual(
            baseline.hectopascals,
            try XCTUnwrap(RiskWindowBuilder.baseline(
                observed: samples.filter { $0.timestamp >= step }, asOf: now
            )).hectopascals,
            accuracy: 1,
            "the two spans have to disagree, or this test proves nothing"
        )

        let baselineSpan = Double(RiskPressureBaseline.windowDays) * 24 * 3600
        let wideReads = await store.requestedRanges.count {
            $0.upperBound.timeIntervalSince($0.lowerBound) >= baselineSpan
        }
        XCTAssertEqual(wideReads, 1, "one wide read a day, and the forecast path is not it")
    }
}

/// A `PressureSampleStore` that remembers what it was asked for.
///
/// The point of these two tests is *which ranges* the engine reads, so the double records them
/// rather than counting calls: a refit and a forecast read are told apart by their span.
private actor RecordingSampleStore: PressureSampleStore {

    private let stored: [PressureSample]
    private(set) var requestedRanges: [Range<Date>] = []

    init(_ samples: [PressureSample]) {
        stored = samples.sorted { $0.timestamp < $1.timestamp }
    }

    func save(_ samples: [PressureSample]) {}

    func samples(in range: Range<Date>) -> [PressureSample] {
        requestedRanges.append(range)
        return stored.filter { range.contains($0.timestamp) }
    }

    @discardableResult
    func deleteSamples(before date: Date) -> Int { 0 }
}
