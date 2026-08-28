import XCTest
@testable import Barosense

/// What the Insights screen is built on: the trailing-week trace, the tag counts, the pattern
/// note's gates, and the per-day outlook the 1–3 day card draws.
final class WellbeingInsightsTests: XCTestCase {

    /// UTC, so day boundaries do not move with the machine running the test.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let start = Date(timeIntervalSince1970: 1_740_960_000)

    private var now: Date { start.addingTimeInterval(20 * 24 * 3600) }

    // MARK: - Trace

    /// Seven columns, ending with today, whatever the log holds.
    ///
    /// Days with nothing recorded are present and empty rather than absent — the rule
    /// `ReportBuilder.trace` states, and the reason the sparkline can draw a hole.
    func testTheTraceIsSevenWholeDaysEndingToday() {
        let insights = WellbeingInsights.make(checkIns: [],
                                              samples: [],
                                              tagsByID: [:],
                                              calendar: calendar,
                                              asOf: now)

        XCTAssertEqual(insights.trace.count, WellbeingInsights.traceDays)
        XCTAssertEqual(insights.trace.last?.day, calendar.startOfDay(for: now))
        XCTAssertTrue(insights.trace.allSatisfy(\.isEmpty))
    }

    /// The window is half-open at the start of tomorrow, so a check-in logged late tonight
    /// lands in the last column rather than falling off the end.
    func testTonightLandsInTheLastColumn() {
        let tonight = calendar.startOfDay(for: now).addingTimeInterval(23 * 3600)
        let insights = WellbeingInsights.make(
            checkIns: [CheckIn(timestamp: tonight, intensity: CheckInIntensity(clamping: 8))],
            samples: [],
            tagsByID: [:],
            calendar: calendar,
            asOf: now
        )

        XCTAssertEqual(insights.trace.last?.peakIntensity, CheckInIntensity(clamping: 8))
    }

    // MARK: - Tags

    /// Counted over the analysis window and ordered by use. Identity, not text — the vocabulary
    /// is renameable and a count keyed on the word would split the moment somebody edits it.
    func testTagsAreCountedByIdentity() {
        let fatigue = WellbeingTag.ID.seeded("fatigue")
        let joints = WellbeingTag.ID.seeded("joints")
        let vocabulary: [WellbeingTag.ID: WellbeingTag] = [
            fatigue: WellbeingTag(id: fatigue, name: "Fatigue"),
            joints: WellbeingTag(id: joints, name: "Joints")
        ]

        let checkIns = (0..<5).map { index in
            CheckIn(timestamp: now.addingTimeInterval(Double(-index) * 3600),
                    intensity: CheckInIntensity(clamping: 4),
                    tagIDs: index < 3 ? [fatigue] : [joints])
        }

        let insights = WellbeingInsights.make(checkIns: checkIns,
                                              samples: [],
                                              tagsByID: vocabulary,
                                              calendar: calendar,
                                              asOf: now)

        XCTAssertEqual(insights.checkInCount, 5)
        XCTAssertEqual(insights.tags.map(\.id), [fatigue, joints])
        XCTAssertEqual(insights.tags.map(\.count), [3, 2])
    }

    // MARK: - Pattern note

    /// No link, no note. The lag and the direction both come from the link, and a note invented
    /// without one would be a second answer to the question the card above it already asked.
    func testNoNoteWithoutALink() {
        XCTAssertNil(patternNote(link: nil,
                                 checkIns: entriesOnEveryFall(),
                                 samples: sawtooth(days: 10)))
    }

    /// Fewer episodes than `minimumEpisodes` and there is no note either — a hit rate over
    /// three falls is a percentage of nothing dressed as a finding.
    func testTooFewEpisodesProduceNoNote() {
        let days = WellbeingPatternNote.minimumEpisodes - 2

        XCTAssertNil(patternNote(link: link(lagHours: 6),
                                 checkIns: entriesOnEveryFall(days: days),
                                 samples: sawtooth(days: days)))
    }

    /// A log where every fall is followed six hours later by a heavy entry: every episode
    /// matches, the count is capped at `maximumEpisodes`, and the tag comes back named.
    func testEveryFallMatchedIsReportedAsSuch() throws {
        let headache = WellbeingTag.ID.seeded("headache")
        let vocabulary = [headache: WellbeingTag(id: headache, name: "Headache")]

        let note = try XCTUnwrap(
            patternNote(link: link(lagHours: 6),
                        checkIns: entriesOnEveryFall(tagID: headache),
                        samples: sawtooth(days: 14),
                        tagsByID: vocabulary)
        )

        XCTAssertEqual(note.episodeCount, WellbeingPatternNote.maximumEpisodes)
        XCTAssertEqual(note.matchedEpisodes, note.episodeCount)
        XCTAssertEqual(note.matchRate, 1, accuracy: 1e-12)
        XCTAssertEqual(note.lagHours, 6)
        XCTAssertTrue(note.isFallLeading)
        XCTAssertEqual(note.tag?.id, headache)
    }

    /// Entries that never land near the expected moment are reported as a miss, not hidden.
    ///
    /// The lag being counted against is already the best of seven searched on this same log, so
    /// a note that could only ever come back positive would be showing the reader one tail of
    /// their own history and calling it a finding.
    func testNothingMatchingIsReportedAsZero() throws {
        // The link says six hours after the fall; these sit half a day away from that.
        let strays = entriesOnEveryFall(offsetHours: 18)

        let miss = try XCTUnwrap(patternNote(link: link(lagHours: 6),
                                             checkIns: strays,
                                             samples: sawtooth(days: 14)))

        XCTAssertEqual(miss.matchedEpisodes, 0)
        XCTAssertEqual(miss.episodeCount, WellbeingPatternNote.maximumEpisodes)
        XCTAssertEqual(miss.matchRate, 0, accuracy: 1e-12)
        XCTAssertFalse(miss.isMatched, "the card words a miss as a miss, never as `usually`")
        XCTAssertNil(miss.tag, "nothing matched, so there is nothing to have been tagged")
    }

    /// Entries below `WellbeingLabel.poorWellbeingThreshold` are not events, so they cannot
    /// match. The note counts the same label the model is trained against and no other.
    func testOnlyPoorWellbeingEntriesMatch() throws {
        let mild = entriesOnEveryFall(intensity: 3)

        let miss = try XCTUnwrap(patternNote(link: link(lagHours: 6),
                                             checkIns: mild,
                                             samples: sawtooth(days: 14)))

        XCTAssertEqual(miss.matchedEpisodes, 0)
    }

    // MARK: - Outlook grading

    /// The band is the two stages' own decision points and introduces no third constant.
    func testTheBandIsTheTwoStagesOwnThresholds() {
        XCTAssertEqual(WellbeingRiskModel.level(isDayQuiet: true,
                                                confidence: 0.99,
                                                gateThreshold: 0.6),
                       .low,
                       "a quiet day is low however sharply the window stage ranks it")

        XCTAssertEqual(WellbeingRiskModel.level(isDayQuiet: false,
                                                confidence: 0.59,
                                                gateThreshold: 0.6),
                       .moderate)

        XCTAssertEqual(WellbeingRiskModel.level(isDayQuiet: false,
                                                confidence: 0.6,
                                                gateThreshold: 0.6),
                       .high,
                       "the gate is inclusive, as `mayNotify` reads it")
    }

    /// A joint figure under half a percentage point has no percentage — the same refusal
    /// `ScoredRiskWindow.percent` makes.
    func testATileUnderHalfAPointHasNoPercentage() {
        XCTAssertNil(outlookDay(combined: 0.004).percent)
        XCTAssertEqual(outlookDay(combined: 0.005).percent, 1)
        XCTAssertEqual(outlookDay(combined: 0.31).percent, 31)
    }

    // MARK: - Outlook, end to end

    /// The forecast on the research notebook's own trace, read as the outlook card reads it.
    ///
    /// What has to hold is structural rather than numeric: one tile per day at most, ascending,
    /// every tile about a stretch that has not happened yet, and every band the one
    /// `WellbeingRiskModel.level` would produce from the two stages.
    func testTheOutlookIsOneTilePerDayAndAllOfItAhead() throws {
        let forecast = try notebookForecast()

        XCTAssertFalse(forecast.outlook.isEmpty, "the trace scores at least today")
        XCTAssertEqual(forecast.outlook.map(\.dayStart),
                       forecast.outlook.map(\.dayStart).sorted(),
                       "tiles are ascending")
        XCTAssertEqual(Set(forecast.outlook.map(\.dayStart)).count,
                       forecast.outlook.count,
                       "one tile per day")

        for day in forecast.outlook {
            XCTAssertGreaterThan(day.window.upperBound, SyntheticTraceFixture.now,
                                 "a tile is about what is still ahead")
            XCTAssertTrue(forecast.windows.contains { $0.start == day.window.lowerBound },
                          "the tile's stretch is one of the scored windows")
            XCTAssertLessThanOrEqual(day.combined, day.confidence + 1e-12,
                                     "the joint figure cannot exceed the ranking it is scaled by")
        }
    }

    /// The tile is read off the best window **still ahead**, and nothing else.
    ///
    /// The one assertion the structural test above cannot make: today's row has finished
    /// windows in it by construction, and a tile that ranked over all of them would be grading
    /// the day on a stretch the user has already lived through. Ranking is on `confidence`
    /// because that is the figure `WellbeingRiskModel.level` compares against the gate — see
    /// the note in `WellbeingRiskForecast` on why it cannot reorder anything within a day.
    func testTodaysTileIgnoresWindowsThatHaveFinished() throws {
        // Partway into the last waking day of the trace, so some of it is behind the model.
        let instant = SyntheticTraceFixture.now.addingTimeInterval(-10 * 3600)
        let forecast = try notebookForecast(asOf: instant)
        let today = try XCTUnwrap(forecast.outlook.first)
        let rows = forecast.windows.filter { $0.dayStart == today.dayStart }
        let ahead = rows.filter { $0.end > instant }

        XCTAssertFalse(ahead.isEmpty)
        XCTAssertLessThan(ahead.count, rows.count,
                          "the fixture has to contain finished windows for this to prove anything")

        let best = try XCTUnwrap(ahead.max { $0.confidence < $1.confidence })
        XCTAssertEqual(today.confidence, best.confidence, accuracy: 1e-12)
        XCTAssertEqual(today.combined, best.combined, accuracy: 1e-12)
        XCTAssertEqual(today.window.lowerBound, best.start)
        XCTAssertEqual(today.window.upperBound, best.end)
    }

    /// The first tile is today's, and it agrees with the flag the chart's row reads.
    func testTodaysTileAgreesWithTheQuietFlag() throws {
        let forecast = try notebookForecast()
        let today = try XCTUnwrap(forecast.outlook.first)

        XCTAssertEqual(today.dayStart, forecast.dayStart)
        XCTAssertEqual(today.level == .low, forecast.isDayQuiet)
    }

    // MARK: - Fixtures

    /// `WellbeingPatternNote.make` with the grid built for it, as `WellbeingInsights.make` does.
    private func patternNote(link: PressureWellbeingLink?,
                             checkIns: [CheckIn],
                             samples: [PressureSample],
                             tagsByID: [WellbeingTag.ID: WellbeingTag] = [:]) -> WellbeingPatternNote? {
        WellbeingPatternNote.make(link: link,
                                         checkIns: checkIns,
                                         cells: PressureWellbeingLink.hourlyCells(from: samples,
                                                                                  asOf: now),
                                         tagsByID: tagsByID)
    }

    private func link(lagHours: Int) -> PressureWellbeingLink {
        PressureWellbeingLink(coefficient: 0.6, lagHours: lagHours, pairCount: 20)
    }

    private func outlookDay(combined: Double) -> RiskOutlookDay {
        RiskOutlookDay(dayStart: start,
                       level: .moderate,
                       confidence: 0.7,
                       combined: combined,
                       window: start..<start.addingTimeInterval(7200))
    }

    /// The prior model's forecast over the notebook trace, assembled the way the engine does.
    ///
    /// The window is `dayStart..<dayEnd` with a forward curve behind it — not the whole history
    /// — because that is what `WellbeingRiskEngine.forwardRows` builds and what the outlook is a
    /// view onto. Scoring the whole log instead would make the *first* day of the trace "today"
    /// and every window in it long finished, which is a forecast of nothing.
    ///
    /// `asOf` defaults to the fixture's own instant, which sits before that day's waking start
    /// — so every window of it is still ahead. A test that needs finished windows to look at
    /// passes an instant partway into the day instead, and the observed rows are cut at it so
    /// the model is never handed a reading from after the moment it is scoring.
    private func notebookForecast(asOf instant: Date = SyntheticTraceFixture.now) throws -> WellbeingRiskForecast {
        let checkIns = SyntheticTraceFixture.checkIns()
        let geometry = RiskWindowGeometry.measured(from: checkIns, calendar: calendar)
        let samples = SyntheticTraceFixture.samples().filter { $0.timestamp < instant }

        let dayStart = geometry.wakingDayStart(of: instant)
        let horizon = instant.addingTimeInterval(Self.horizonHours * 3600)
        let lastDayStart = max(geometry.wakingDayStart(of: horizon), dayStart)
        let dayEnd = lastDayStart.addingTimeInterval(
            Double(geometry.windowsPerDay) * geometry.windowSeconds
        )

        let rows = RiskWindowBuilder.rows(
            observed: samples,
            forecast: forwardCurve(from: samples.last, asOf: instant),
            checkIns: checkIns.filter { ($0.timestamp >= dayStart) && ($0.timestamp < instant) },
            geometry: geometry,
            in: dayStart..<dayEnd,
            asOf: instant
        )
        let model = try XCTUnwrap(WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour,
                                                           trainedAt: instant))

        return try XCTUnwrap(model.forecast(for: rows, asOf: instant))
    }

    /// How far the fixture's forward curve reaches. Two days, which is enough for the card's
    /// three tiles and short enough that the whole run stays fast.
    private static let horizonHours: Double = 48

    /// A flat continuation of the last reading, hour by hour.
    ///
    /// Flat on purpose: the outlook tests are about the *shape* of the result — one tile a day,
    /// all of it ahead, every band the one the two stages imply — and a curve with weather in it
    /// would make those assertions depend on the prior's coefficients.
    private func forwardCurve(from last: PressureSample?, asOf now: Date) -> [ForecastPressurePoint] {
        guard let last else { return [] }

        return stride(from: 1.0, through: Self.horizonHours, by: 1).map { hour in
            ForecastPressurePoint(timestamp: now.addingTimeInterval(hour * 3600),
                                  pressure: last.pressure,
                                  uncertaintyHPa: 1,
                                  source: .weatherKit,
                                  issuedAt: now)
        }
    }

    /// A 24-hour sawtooth: twelve hours up, twelve down, 6 hPa peak to trough.
    ///
    /// One falling episode a day, and a six-hour change of about 3 hPa inside it — comfortably
    /// past `PressureTrend.significantChangeHPa`, so the run is detected and its onset is
    /// unambiguous.
    private func sawtooth(days: Int) -> [PressureSample] {
        (0..<(days * 24)).map { hour in
            let phase = hour % 24
            let value = phase < 12
                ? 1007 + Double(phase) * 0.5
                : 1013 - Double(phase - 12) * 0.5

            return PressureSample(timestamp: start.addingTimeInterval(Double(hour) * 3600),
                                  pressure: Pressure(hectopascals: value))
        }
    }

    /// One entry per day of `sawtooth`, placed `offsetHours` after that day's fall begins.
    ///
    /// The fall's six-hour change first clears the threshold at hour 18 of each day — twelve
    /// hours of rise, then six hours of fall behind it.
    private func entriesOnEveryFall(days: Int = 14,
                                    offsetHours: Int = 6,
                                    intensity: Int = 8,
                                    tagID: WellbeingTag.ID? = nil) -> [CheckIn] {
        (0..<days).map { day in
            let onset = Double(day * 24 + 18) * 3600
            return CheckIn(timestamp: start.addingTimeInterval(onset + Double(offsetHours) * 3600),
                           intensity: CheckInIntensity(clamping: intensity),
                           tagIDs: tagID.map { [$0] } ?? [])
        }
    }
}
