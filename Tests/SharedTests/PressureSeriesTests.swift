import XCTest
@testable import Barosense

/// The piece that decides what the chart's line, figure and caption mean. Exercised with
/// literals and no sensor anywhere, which is the whole reason it lives in `Shared/`.
final class PressureSeriesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func forecastPoint(hoursAhead: Double,
                               hPa: Double,
                               source: ForecastSource = .weatherKit) -> ForecastPressurePoint {
        ForecastPressurePoint(
            timestamp: now.addingTimeInterval(hoursAhead * 3600),
            pressure: Pressure(hectopascals: hPa),
            uncertaintyHPa: source.uncertaintyHPa(atLeadSeconds: hoursAhead * 3600),
            source: source,
            issuedAt: now
        )
    }

    private func sample(hoursAgo hours: Double, hPa: Double) -> PressureSample {
        PressureSample(timestamp: now.addingTimeInterval(-hours * 3600),
                       pressure: Pressure(hectopascals: hPa))
    }

    /// Absolute epoch seconds, for the bucketing tests. The grid is anchored to the epoch,
    /// so a slot boundary is only nameable in these terms: 900_000 is exactly 1000 slots of
    /// 900 s in, which makes `[900_000, 900_900)` one slot with no arithmetic in the test.
    private func sample(at epoch: TimeInterval, hPa: Double) -> PressureSample {
        PressureSample(timestamp: Date(timeIntervalSince1970: epoch),
                       pressure: Pressure(hectopascals: hPa))
    }

    // MARK: - The ranges themselves

    /// The selector renders `allCases` in declaration order, so a case added in the wrong
    /// place produces a scrambled row of buttons that compiles, passes every other test, and
    /// is only visible to someone looking at the screen.
    func testRangesAreDeclaredShortestToLongest() {
        let seconds: [TimeInterval] = PressureChartRange.allCases.map(\.seconds)
        let expected: [TimeInterval] = [3600, 10_800, 21_600, 86_400]

        XCTAssertEqual(seconds, seconds.sorted())
        XCTAssertEqual(seconds, expected)
    }

    /// The three-hour button and the trend caption describe the same stretch of time. If
    /// either number moves the other has to be reconsidered, otherwise the caption starts
    /// summarising a window the user cannot see on the button that names it.
    func testTheThreeHourWindowIsTheTrendWindow() {
        XCTAssertEqual(PressureChartRange.threeHours.seconds, PressureTrend.windowSeconds)
    }

    /// One store read of `widest` serves every button. If some range were longer, its button
    /// would silently show a truncated window instead of the history it names.
    func testWidestIsTheLongestRange() {
        XCTAssertEqual(PressureChartRange.widest.seconds,
                       PressureChartRange.allCases.map(\.seconds).max())
    }

    /// One read of `widest.historySeconds` has to cover every button's scrollback too. If
    /// some other range reached further back, scrolling it would run off the end of what was
    /// loaded and draw a gap where there is history.
    func testWidestAlsoAsksForTheDeepestScrollback() {
        XCTAssertEqual(PressureChartRange.widest.historySeconds,
                       PressureChartRange.allCases.map(\.historySeconds).max())
    }

    /// Twelve screenfuls on every range: that is what keeps the drawn point count between 48
    /// and 288 and makes the scroll cost the same whichever button is selected.
    func testEveryRangeScrollsBackTwelveScreenfuls() {
        let history = PressureChartRange.allCases.map(\.historySeconds)
        let expected: [TimeInterval] = [12 * 3600, 36 * 3600, 72 * 3600, 288 * 3600]

        XCTAssertEqual(history, expected)
        for range in PressureChartRange.allCases {
            XCTAssertEqual(range.historySeconds / range.seconds, 12, accuracy: 0.0001,
                           "\(range) scrolls a different distance from the rest")
        }
    }

    /// The dot rule counts one screenful, not the whole line — the plot draws up to 288
    /// points now, and comparing against that total would strip the dots off every range but
    /// the narrowest.
    func testPointsPerScreenIsTheLadderTheRangeDocuments() {
        XCTAssertEqual(PressureChartRange.allCases.map(\.pointsPerScreen), [4, 12, 12, 24])
    }

    /// The narrowest window holds four readings at the sampling floor and can hold none at
    /// all after a stretch with no background wake. The card must not fill that gap with a
    /// reading from two hours ago and print it as "поточний тиск".
    ///
    /// Drawn and current are two different claims now that the plot scrolls: the reading is
    /// on the line, a screenful to the left, and the figure is still empty.
    func testAReadingOlderThanTheWindowIsDrawnButIsNotTheCurrentFigure() {
        let series = PressureSeries.make(from: [sample(hoursAgo: 2, hPa: 1013)],
                                         range: .oneHour,
                                         asOf: now)

        XCTAssertEqual(series.observed.count, 1, "inside the scrollback, so the line has it")
        XCTAssertNil(series.latest, "outside the visible window, so the figure does not")
    }

    func testAReadingInsideTheWindowIsTheCurrentFigure() {
        let series = PressureSeries.make(from: [sample(hoursAgo: 0.1, hPa: 1013)],
                                         range: .oneHour,
                                         asOf: now)

        XCTAssertEqual(series.latest?.pressure.hectopascals, 1013)
    }

    /// The ladder `PressureChartRange` documents in its own table. Asserted as a whole
    /// because the numbers only make sense against each other: non-decreasing, and never
    /// finer than the sampling floor — the two narrow ranges sit exactly on it, which is
    /// what makes them draw the log at the cadence it was recorded at.
    func testTheBucketLadderIsTheOneTheRangeDocuments() {
        let buckets = PressureChartRange.allCases.map(\.bucketSeconds)
        let expected: [TimeInterval] = [900, 900, 1800, 3600]

        XCTAssertEqual(buckets, expected)
        XCTAssertEqual(buckets, buckets.sorted())
    }

    // MARK: - Bucketing

    func testTwoReadingsInOneSlotBecomeOnePointAtTheirMean() {
        let readings = [sample(at: 900_060, hPa: 1010), sample(at: 900_360, hPa: 1014)]

        let collapsed = PressureBuckets.collapse(readings, intoBucketsOf: 900)

        XCTAssertEqual(collapsed.count, 1)
        XCTAssertEqual(collapsed.first?.pressure.hectopascals ?? 0, 1012, accuracy: 0.0001)
        XCTAssertEqual(collapsed.first?.timestamp.timeIntervalSince1970 ?? 0, 900_210, accuracy: 0.0001,
                       "the point sits at the mean of the readings' own times")
    }

    func testReadingsInDifferentSlotsStayApart() {
        // 901_000 / 900 is 1001.1, one slot past the first.
        let readings = [sample(at: 900_060, hPa: 1010), sample(at: 901_000, hPa: 1014)]

        let collapsed = PressureBuckets.collapse(readings, intoBucketsOf: 900)

        XCTAssertEqual(collapsed.map(\.pressure.hectopascals), [1010, 1014])
    }

    /// A slot holding one reading is handed back untouched. On the narrow ranges every slot
    /// holds at most one, and a chart that shifted that point to the slot's centre would be
    /// claiming a measurement at an instant nothing was measured.
    func testALoneReadingInItsSlotIsNotMovedOrReidentified() {
        let alone = sample(at: 900_060, hPa: 1010)

        let collapsed = PressureBuckets.collapse([alone, sample(at: 902_000, hPa: 1020)],
                                                 intoBucketsOf: 900)

        XCTAssertEqual(collapsed.first?.id, alone.id)
        XCTAssertEqual(collapsed.first?.timestamp, alone.timestamp)
        XCTAssertEqual(collapsed.first?.pressure.hectopascals, 1010)
    }

    /// Slots are anchored to the epoch, not to `now`. Rebuilding a minute later has to put
    /// every point back where it was — a grid that slid under the line would make an
    /// unchanged history look like it moved on every reload.
    func testTheGridDoesNotShiftWhenNowMoves() {
        let readings = (1...12).map { sample(hoursAgo: Double($0) * 0.25, hPa: 1013 + Double($0)) }

        let early = PressureSeries.make(from: readings, range: .day, asOf: now)
        let later = PressureSeries.make(from: readings, range: .day, asOf: now.addingTimeInterval(60))

        XCTAssertEqual(early.observed.map(\.timestamp), later.observed.map(\.timestamp))
        XCTAssertEqual(early.observed.map(\.id), later.observed.map(\.id))
    }

    /// A day of 15-minute readings has to draw as roughly two dozen hourly means. 96 raw
    /// points in a 92 pt plot is a smear, and it is the reason bucketing exists at all.
    func testADayOfReadingsDrawsAsHourlyMeans() {
        let readings = (1...96).map { sample(hoursAgo: Double($0) * 0.25, hPa: 1013) }

        let series = PressureSeries.make(from: readings, range: .day, asOf: now)

        XCTAssertEqual(series.readingCount, 96)
        // 24 h of readings covers 24 whole hourly slots plus whichever partial slot `now`
        // falls inside, so the drawn count is 24 or 25 depending on the clock.
        XCTAssertGreaterThanOrEqual(series.observed.count, 24)
        XCTAssertLessThanOrEqual(series.observed.count, 25)
    }

    /// The figure on the card is a measurement. Averaging is how the *line* stays readable;
    /// printing a bucket mean as "поточний тиск" would put a number on screen that the
    /// barometer never reported — on a falling day, off by more than the decimal shown.
    func testTheLatestReadingIsRawEvenWhenTheLineIsBucketed() {
        // Both inside one hourly slot: 1010 and 1016 collapse to a 1013 point.
        let readings = [sample(at: 3_600_000 + 60, hPa: 1010),
                        sample(at: 3_600_000 + 600, hPa: 1016)]
        let asOf = Date(timeIntervalSince1970: 3_600_000 + 900)

        let series = PressureSeries.make(from: readings, range: .day, asOf: asOf)

        XCTAssertEqual(series.observed.count, 1)
        XCTAssertEqual(series.observed.first?.pressure.hectopascals ?? 0, 1013, accuracy: 0.0001)
        XCTAssertEqual(series.latest?.pressure.hectopascals, 1016, "the figure is the last reading")
        XCTAssertEqual(series.readingCount, 2, "VoiceOver counts readings, not points")
    }

    // MARK: - Range slicing

    /// The line covers the whole scrollback, not one screenful: everything the gesture can
    /// reach has to be drawn before the gesture starts. And it stops at the scrollback's
    /// edge — the plot scrolls, it is not unbounded.
    func testTheLineCoversTheScrollbackAndStopsAtItsEdge() {
        let samples = [sample(hoursAgo: 80, hPa: 1025),   // past the 72 h scrollback
                       sample(hoursAgo: 20, hPa: 1020),   // inside it, outside the 6 h window
                       sample(hoursAgo: 5, hPa: 1015),
                       sample(hoursAgo: 0.5, hPa: 1010)]

        let series = PressureSeries.make(from: samples, range: .sixHours, asOf: now)

        XCTAssertEqual(series.observed.map(\.pressure.hectopascals), [1020, 1015, 1010])
        XCTAssertEqual(series.latest?.pressure.hectopascals, 1010,
                       "the figure stays inside the visible six hours")
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

        XCTAssertEqual(oneHour.latest?.pressure.hectopascals, 1010,
                       "only the recent sample is inside the visible hour")
        XCTAssertEqual(oneHour.observed.count, 2, "both are inside the twelve-hour scrollback")
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

    /// A day with a week behind it must not be padded flat. The vertical domain is fitted
    /// once, over the whole scrollback — a domain refitted to the viewport would make the
    /// line climb and sink under the finger — so without the cap a 30 hPa span would add
    /// 18 hPa of empty plot on each side and squash a day's movement to nothing.
    func testValueDomainPaddingIsCappedOnAWideSpan() throws {
        let samples = [sample(hoursAgo: 200, hPa: 990), sample(hoursAgo: 1, hPa: 1020)]
        let series = PressureSeries.make(from: samples, range: .day, asOf: now)

        let domain = try XCTUnwrap(series.valueDomainHPa)
        XCTAssertEqual(domain.lowerBound, 987, accuracy: 0.0001)
        XCTAssertEqual(domain.upperBound, 1023, accuracy: 0.0001)
    }

    /// Two readings twelve minutes apart must occupy twelve minutes of the plot, not stretch
    /// across it and claim coverage that was never observed. The plot is now the scrollback;
    /// the hour the button names is the viewport onto it.
    func testTimeDomainSpansTheWholeScrollbackAndTheViewportSpansTheRange() {
        let samples = [sample(hoursAgo: 0.2, hPa: 1013), sample(hoursAgo: 0, hPa: 1013)]
        let series = PressureSeries.make(from: samples, range: .oneHour, asOf: now)

        XCTAssertEqual(series.timeDomain.lowerBound, now.addingTimeInterval(-12 * 3600))
        XCTAssertGreaterThanOrEqual(series.timeDomain.upperBound, now)
        XCTAssertEqual(series.visibleSeconds, 3600)
    }

    // MARK: - Opening position

    /// The plot opens on the newest reading rather than on `now`. At a 15-minute cadence the
    /// narrow windows are empty a good part of the time, and opening on a blank viewport the
    /// user has to drag leftwards out of is worse than opening a few minutes in the past.
    func testThePlotOpensOnTheNewestReadingRatherThanOnNow() {
        let series = PressureSeries.make(from: [sample(hoursAgo: 2, hPa: 1013)],
                                         range: .oneHour,
                                         asOf: now)

        // The viewport ends one headroom past the reading, so it starts an hour before that.
        let headroom = series.trailingHeadroomSeconds
        XCTAssertEqual(series.initialScrollX,
                       now.addingTimeInterval(-2 * 3600 - 3600 + headroom))
    }

    /// The clearance past the newest point is a fraction of the visible window, not a fixed
    /// interval: what has to stay unclipped is a 14 pt check-in dot, and points — not
    /// seconds — are what the plot is measured in.
    func testTrailingHeadroomIsTheSameFractionOfEveryRange() {
        for range in PressureChartRange.allCases {
            let series = PressureSeries.make(from: [sample(hoursAgo: 0, hPa: 1013)],
                                             range: range,
                                             asOf: now)
            XCTAssertEqual(series.trailingHeadroomSeconds / range.seconds, 0.025, accuracy: 1e-9,
                           "range \(range.rawValue)")
        }
    }

    /// A check-in logged a moment ago is the common case, and it lands at the newest point.
    /// It has to be inside the opening viewport, not on its boundary.
    func testACheckInAtTheNewestReadingSitsInsideTheOpeningViewport() {
        let series = PressureSeries.make(from: [sample(hoursAgo: 1, hPa: 1013),
                                                sample(hoursAgo: 0, hPa: 1010)],
                                         checkIns: [CheckIn(timestamp: now,
                                                            intensity: CheckInIntensity(clamping: 8))],
                                         range: .sixHours,
                                         asOf: now)

        let viewportEnd = series.initialScrollX.addingTimeInterval(series.visibleSeconds)
        let marker = try? XCTUnwrap(series.checkIns.first)

        XCTAssertNotNil(marker)
        XCTAssertLessThan(marker?.timestamp ?? .distantFuture, viewportEnd)
        XCTAssertLessThanOrEqual(viewportEnd, series.timeDomain.upperBound)
    }

    /// A reading near the far edge of the scrollback must not drag the viewport off the end
    /// of the plot.
    func testTheOpeningViewportIsClampedIntoThePlot() {
        // `.oneHour` scrolls back twelve hours and this reading sits six minutes inside that
        // edge, so an unclamped viewport would start before the plot does.
        let series = PressureSeries.make(from: [sample(hoursAgo: 11.9, hPa: 1013)],
                                         range: .oneHour,
                                         asOf: now)

        XCTAssertEqual(series.initialScrollX, series.timeDomain.lowerBound)
    }

    // MARK: - Forecast

    func testForecastValuesInThePastAreDropped() {
        let stale = forecastPoint(hoursAhead: -1 / 6, hPa: 1011)
        let ahead = forecastPoint(hoursAhead: 1, hPa: 1009)

        let series = PressureSeries.make(from: [], forecast: [ahead, stale], range: .day, asOf: now)

        XCTAssertEqual(series.forecast.map(\.pressure.hectopascals), [1009])
    }

    /// The archive holds 240 h. A card 92 pt tall that drew all of it would be a horizontal
    /// smear, and the domain it forced would flatten the user's own line — so the series clips
    /// to half a screenful ahead, whatever the caller hands over.
    func testForecastIsClippedToTheRangesOwnForwardWindow() {
        let points = (1...48).map { forecastPoint(hoursAhead: Double($0), hPa: 1010) }

        let series = PressureSeries.make(from: [], forecast: points, range: .day, asOf: now)

        // Half a day's screenful is 12 h.
        XCTAssertEqual(series.forecast.count, 12)
        XCTAssertEqual(series.forecast.last?.timestamp, now.addingTimeInterval(12 * 3600))
    }

    /// The regression the forward half shipped with: **nothing was drawn on the button the
    /// card opens on**.
    ///
    /// Both producers emit on whole hours — WeatherKit's `hourly.forecast` and
    /// `LocalPressureModel`'s iteration alike — while the forward window was half a screenful,
    /// which is 30 min on `.oneHour` and 90 min on `.threeHours`. A 30-minute window holds one
    /// hour mark or none depending on the minute, and `LineMark` renders nothing at all from a
    /// single vertex, so the dashed line and the `now` divider were absent from the default
    /// view whatever the archive or the fit held.
    ///
    /// Swept across the hour because that is the variable: on the old window the same data
    /// drew a line, a stub or nothing at all depending on when the user opened the app.
    func testEveryRangeDrawsAtLeastATwoPointForwardLine() {
        // 1_769_997_600 is the hour mark below the fixture's `now`, so the sweep below covers
        // a whole hour of possible `now`s against one hour-aligned curve.
        let hourMark = Date(timeIntervalSince1970: 1_769_997_600)
        let curve = (1...12).map { mark in
            ForecastPressurePoint(timestamp: hourMark.addingTimeInterval(Double(mark) * 3600),
                                  pressure: Pressure(hectopascals: 1010),
                                  uncertaintyHPa: 1,
                                  source: .weatherKit,
                                  issuedAt: hourMark)
        }

        for range in PressureChartRange.allCases {
            for minute in [0, 1, 29, 30, 59] {
                let asOf = hourMark.addingTimeInterval(Double(minute) * 60)
                let series = PressureSeries.make(from: [], forecast: curve, range: range, asOf: asOf)

                XCTAssertGreaterThanOrEqual(
                    series.forecast.count, 2,
                    "range \(range.rawValue) at :\(minute) drew \(series.forecast.count) point(s)"
                )
            }
        }
    }

    /// And the other half of that fix. The forward window is floored at two hours, which on
    /// the two narrow buttons is wider than the screenful itself — so an opening viewport
    /// pinned to the forecast's far end would show nothing but forecast, a pressure chart
    /// whose first paint carries no pressure.
    func testTheOpeningViewportKeepsMeasuredTimeOnScreenAtTheNarrowRanges() {
        let hourMark = Date(timeIntervalSince1970: 1_769_997_600)
        let curve = (1...2).map { mark in
            ForecastPressurePoint(timestamp: hourMark.addingTimeInterval(Double(mark) * 3600),
                                  pressure: Pressure(hectopascals: 1010),
                                  uncertaintyHPa: 1,
                                  source: .localModel,
                                  issuedAt: hourMark)
        }

        for range in [PressureChartRange.oneHour, .threeHours] {
            let series = PressureSeries.make(from: [sample(hoursAgo: 0.1, hPa: 1013)],
                                             forecast: curve,
                                             range: range,
                                             asOf: now)
            let viewportEnd = series.initialScrollX.addingTimeInterval(series.visibleSeconds)

            XCTAssertLessThan(series.initialScrollX, now, "range \(range.rawValue)")
            // At most half the screenful is future — what the forward half occupied before the
            // floor existed.
            XCTAssertLessThanOrEqual(viewportEnd.timeIntervalSince(now),
                                     series.visibleSeconds / 2 + series.trailingHeadroomSeconds,
                                     "range \(range.rawValue)")
        }
    }

    /// The forward half starts on a whole hour, so the segment that crosses the `now` divider
    /// — at the narrow ranges, the only part of it on screen — has no left end of its own.
    /// The newest drawn reading is that end.
    func testTheDashedLineIsAnchoredToTheNewestDrawnReading() {
        let observed = (1...3).map { sample(hoursAgo: Double($0), hPa: 1013) }
        let series = PressureSeries.make(from: observed,
                                         forecast: [forecastPoint(hoursAhead: 1, hPa: 1011)],
                                         range: .sixHours,
                                         asOf: now)

        XCTAssertEqual(series.forecastJoin?.timestamp, series.observed.last?.timestamp)
    }

    /// And no anchor without something to anchor: the card draws exactly what it drew before
    /// this feature existed on the many devices that will never have a forward half.
    func testThereIsNoAnchorWithoutAForecast() {
        let series = PressureSeries.make(from: [sample(hoursAgo: 1, hPa: 1013)],
                                         range: .sixHours,
                                         asOf: now)

        XCTAssertNil(series.forecastJoin)
    }

    /// Acceptance criterion 3 of PR 3. The forecast arrives already offset-calibrated into
    /// barometer coordinates, so the domain stays about as tall as the user's own line. Drawn
    /// as raw MSLP it would be ~22 hPa away and the domain would triple, squashing a day's
    /// real movement into a flat line.
    func testACalibratedForecastKeepsTheDomainAsTallAsTheObservedLine() {
        let observed = (1...6).map { sample(hoursAgo: Double($0), hPa: 991 + Double($0) * 0.2) }
        let calibrated = (1...6).map { forecastPoint(hoursAhead: Double($0), hPa: 990.5) }

        let series = PressureSeries.make(from: observed,
                                         forecast: calibrated,
                                         range: .sixHours,
                                         asOf: now)

        guard let domain = series.valueDomainHPa else {
            return XCTFail("expected a domain with both halves present")
        }
        let span = domain.upperBound - domain.lowerBound
        XCTAssertLessThan(span, 11, "domain span was \(span) hPa — a regression toward raw MSLP")
    }

    /// And the failure it guards against, stated: the same series with an uncalibrated curve.
    func testAnUncalibratedForecastWouldBlowTheDomainOut() {
        let observed = (1...6).map { sample(hoursAgo: Double($0), hPa: 991 + Double($0) * 0.2) }
        let rawMSLP = (1...6).map { forecastPoint(hoursAhead: Double($0), hPa: 1013) }

        let series = PressureSeries.make(from: observed,
                                         forecast: rawMSLP,
                                         range: .sixHours,
                                         asOf: now)

        guard let domain = series.valueDomainHPa else {
            return XCTFail("expected a domain")
        }
        XCTAssertGreaterThan(domain.upperBound - domain.lowerBound, 22)
    }

    /// The band is part of the drawing, so it is part of the domain. Fitting to the line alone
    /// would clip the shading at exactly the horizons where the band is the point.
    func testTheDomainCoversTheBandAndNotJustTheLine() {
        let observed = [sample(hoursAgo: 1, hPa: 1000)]
        let wide = ForecastPressurePoint(timestamp: now.addingTimeInterval(3600),
                                         pressure: Pressure(hectopascals: 1000),
                                         uncertaintyHPa: 4,
                                         source: .localModel,
                                         issuedAt: now)

        let series = PressureSeries.make(from: observed,
                                         forecast: [wide],
                                         range: .sixHours,
                                         asOf: now)

        XCTAssertEqual(series.valueDomainHPa?.contains(1004), true)
    }

    /// And the limit on that. A local-model band is inflated by how thin the log is, and on a
    /// cold start that reached ±22 hPa — which, included whole, handed the entire plot to the
    /// least certain producer and flattened the user's own readings into a level in the middle
    /// of it. The same failure `testAnUncalibratedForecastWouldBlowTheDomainOut` describes,
    /// arriving from the other side.
    func testAnInflatedBandIsClippedRatherThanSettingTheScale() {
        let observed = (1...6).map { sample(hoursAgo: Double($0), hPa: 1000 + Double($0) * 0.5) }
        let enormous = (1...6).map { hour in
            ForecastPressurePoint(timestamp: now.addingTimeInterval(Double(hour) * 3600),
                                  pressure: Pressure(hectopascals: 1000),
                                  uncertaintyHPa: 22,
                                  source: .localModel,
                                  issuedAt: now)
        }

        let series = PressureSeries.make(from: observed,
                                         forecast: enormous,
                                         range: .sixHours,
                                         asOf: now)

        guard let domain = series.valueDomainHPa else {
            return XCTFail("expected a domain with both halves present")
        }

        // Without the clip this was 50 hPa of plot for 3 hPa of readings.
        XCTAssertLessThan(domain.upperBound - domain.lowerBound, 20)
        XCTAssertFalse(domain.contains(1022))
        XCTAssertEqual(series.valueDomainHPa?.contains(996), true)
    }

    /// Acceptance criterion 4: nothing about the forward half may break the card for the many
    /// devices that will never have one — no location grant, WeatherKit off, a fresh install.
    func testAnEmptyForecastLeavesTheChartExactlyAsItWas() {
        let observed = (1...6).map { sample(hoursAgo: Double($0), hPa: 1013) }

        let series = PressureSeries.make(from: observed, range: .sixHours, asOf: now)

        XCTAssertTrue(series.forecast.isEmpty)
        // `timeDomain` ends at `now` plus the trailing headroom, with nothing added for a
        // forecast — the `now` divider is drawn only when there is a forward half to divide.
        XCTAssertEqual(series.timeDomain.upperBound,
                       now.addingTimeInterval(series.trailingHeadroomSeconds))
        XCTAssertEqual(series.initialScrollX,
                       PressureSeries.make(from: observed, range: .sixHours, asOf: now).initialScrollX)
    }

    /// Forward-looking values are a separate family and must never be mistaken for sensor
    /// readings — the figure on the card is the last thing the barometer actually measured.
    func testForecastNeverBecomesTheLatestReading() {
        let ahead = forecastPoint(hoursAhead: 1, hPa: 1009)
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
        let ahead = forecastPoint(hoursAhead: 1, hPa: 1009)
        let series = PressureSeries.make(from: [], forecast: [ahead], range: .day, asOf: now)

        XCTAssertTrue(series.isEmpty, "the card must show its empty state until the sensor reports")
    }
}
