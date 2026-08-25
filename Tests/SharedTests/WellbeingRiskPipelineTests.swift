import XCTest
@testable import Barosense

/// The whole pipeline on the research notebook's own trace, plus the fixtures `ml_pipeline`
/// requires: a thin log, a 12-hour hole, an altitude step, a user who has never logged.
final class WellbeingRiskPipelineTests: XCTestCase {

    /// UTC, so the waking-day boundaries in the fixture do not move with the machine running
    /// the test. The trace's own hours are what the notebook's 06:00 boundary was read off.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private func geometry(for checkIns: [CheckIn]) -> RiskWindowGeometry {
        RiskWindowGeometry.measured(from: checkIns, calendar: calendar)
    }

    private func rows(asOf now: Date,
                      samples: [PressureSample],
                      checkIns: [CheckIn],
                      geometry: RiskWindowGeometry) -> [RiskWindowRow] {
        RiskWindowBuilder.rows(observed: samples,
                               checkIns: checkIns,
                               geometry: geometry,
                               in: SyntheticTraceFixture.start..<now,
                               asOf: now)
    }

    // MARK: - End to end

    /// The result the notebook found, reproduced through the app's own types.
    ///
    /// The thresholds are deliberately below the notebook's point estimates rather than at
    /// them. This runs on an hourly grid where the notebook ran on a quarter-hourly one, blends
    /// a shipped prior in, and fits the personal window stage on six columns rather than nine —
    /// so matching to three decimals would mean something had been rigged. What must survive is
    /// the finding: pressure ranks the windows of a day, comfortably above chance and above
    /// every trivial rule.
    func testReproducesTheNotebookResultOnItsOwnTrace() throws {
        let checkIns = SyntheticTraceFixture.checkIns()
        let geometry = geometry(for: checkIns)
        let now = SyntheticTraceFixture.now

        let built = rows(asOf: now,
                         samples: SyntheticTraceFixture.samples(),
                         checkIns: checkIns,
                         geometry: geometry)
        let training = try XCTUnwrap(
            WellbeingRiskTrainer.train(rows: built, geometry: geometry, asOf: now)
        )
        let report = try XCTUnwrap(training.report)

        for line in report.logLines { print("[risk] " + line) }

        // The waking day the trace implies: earliest entry at 07:00, less an hour of margin.
        XCTAssertEqual(geometry.dayStartHour, 6)
        XCTAssertEqual(geometry.windowsPerDay, 9)

        let windowROC = try XCTUnwrap(report.window.rocAUC)
        let windowPR = try XCTUnwrap(report.window.prAUC)
        XCTAssertGreaterThan(windowROC, 0.65, "window stage should rank well above chance")
        XCTAssertGreaterThan(windowPR, report.window.baseRate * 2, "PR-AUC should lift the base rate")

        // The product metric, against picking a window at random.
        let hitAtOne = try XCTUnwrap(report.hitAtOne)
        let hitAtTwo = try XCTUnwrap(report.hitAtTwo)
        XCTAssertGreaterThan(hitAtOne, report.randomHitAtOne * 2)
        XCTAssertGreaterThan(hitAtTwo, report.randomHitAtTwo * 2)
        XCTAssertGreaterThan(hitAtTwo, hitAtOne)

        // The day stage: it ranks days above chance, and the Platt correction earns its place.
        //
        // What is deliberately **not** asserted is that the calibrated probability beats simply
        // answering the base rate. On this trace it does not — 53 of the last 60 days hold an
        // entry, so the constant scores 0.103 and the model 0.124. That is a property of a
        // person who logs almost every day, not a defect: there is nearly nothing to
        // discriminate. The report carries `beatsConstantBrier` so the comparison is on the
        // record every run rather than discovered later.
        XCTAssertGreaterThan(try XCTUnwrap(report.day.rocAUC), 0.6)
        XCTAssertLessThan(try XCTUnwrap(report.day.brier),
                          try XCTUnwrap(report.day.uncalibratedBrier),
                          "calibration has to improve reliability or it should not run")

        XCTAssertTrue(report.beatsEveryBaseline,
                      "learned window stage must beat every trivial rule: "
                        + report.baselines.map { "\($0.baseline.rawValue)=\($0.prAUC ?? -1)" }
                        .joined(separator: " "))
    }

    /// The gate, which is the piece that decides whether the app is allowed to interrupt.
    func testGateStaysInsideItsMessageBudgetAtUsablePrecision() throws {
        let checkIns = SyntheticTraceFixture.checkIns()
        let geometry = geometry(for: checkIns)
        let now = SyntheticTraceFixture.now

        let training = try XCTUnwrap(WellbeingRiskTrainer.train(
            rows: rows(asOf: now,
                       samples: SyntheticTraceFixture.samples(),
                       checkIns: checkIns,
                       geometry: geometry),
            geometry: geometry,
            asOf: now
        ))
        let gate = try XCTUnwrap(training.report?.gate)

        // Tuned to 2.5 a week; the quantile lands on whole days, so it cannot hit it exactly.
        XCTAssertEqual(gate.messagesPerWeek, WellbeingRiskTrainer.messagesPerWeekTarget, accuracy: 1)

        // §6's provisional ship gate. Failing this is a publishable result, not a broken test —
        // it would mean the messages are not worth sending and the gate should stay shut.
        let precision = try XCTUnwrap(gate.precision)
        XCTAssertGreaterThan(precision, 0.5)

        // Silence is the point. A gate that fires on most days is not a gate.
        XCTAssertLessThan(Double(gate.firedDayCount), Double(gate.evaluatedDayCount) * 0.6)

        // And the threshold the run chose is what the shipped model carries forward.
        XCTAssertEqual(training.model.gateThreshold, gate.threshold)
    }

    /// A day's forecast: a calibrated percentage, nine ranked windows, two of them marked.
    func testForecastMarksTwoWindowsAndRanksThemAll() throws {
        let checkIns = SyntheticTraceFixture.checkIns()
        let geometry = geometry(for: checkIns)
        let now = SyntheticTraceFixture.now

        let training = try XCTUnwrap(WellbeingRiskTrainer.train(
            rows: rows(asOf: now,
                       samples: SyntheticTraceFixture.samples(),
                       checkIns: checkIns,
                       geometry: geometry),
            geometry: geometry,
            asOf: now
        ))

        // A day early in the trace, scored as if it were now — every window still ahead.
        let day = geometry.wakingDayStart(of: SyntheticTraceFixture.start.addingTimeInterval(60 * 24 * 3600))
        let asOf = day.addingTimeInterval(-3600)
        let dayRows = RiskWindowBuilder.rows(
            observed: SyntheticTraceFixture.samples(),
            checkIns: checkIns,
            geometry: geometry,
            in: day..<day.addingTimeInterval(Double(geometry.windowsPerDay) * geometry.windowSeconds),
            asOf: asOf
        )
        let forecast = try XCTUnwrap(training.model.forecast(for: dayRows, asOf: asOf))

        XCTAssertEqual(forecast.windows.count, geometry.windowsPerDay)
        XCTAssertEqual(forecast.dayStart, day)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(forecast.checkInProbability)))
        XCTAssertEqual(forecast.windows, forecast.windows.sorted { $0.start < $1.start })

        if forecast.isDayQuiet {
            XCTAssertTrue(forecast.marked.isEmpty, "a quiet day names no window")
            XCTAssertFalse(forecast.mayNotify)
        } else {
            // Only windows the row could put a number on are eligible — see
            // `WellbeingRiskModel.isPrintable`.
            let printable = forecast.windows.filter { $0.percent != nil }
            XCTAssertEqual(forecast.marked.count,
                           min(WellbeingRiskModel.markedWindowCount, printable.count))
            // The marked ones are the highest-ranked, not merely two of them.
            let best = printable.map(\.confidence).sorted(by: >)
                .prefix(WellbeingRiskModel.markedWindowCount)
            XCTAssertEqual(forecast.marked.map(\.confidence).sorted(by: >), Array(best))
        }
    }

    /// Before the user wakes, the whole waking day is ahead — and every window is markable.
    ///
    /// The regression this guards is a crash, not a bad number: at 03:00 with a 06:00 boundary
    /// the day this forecast is about starts *later* than `now`, and any code that assumed
    /// otherwise built a range running backwards.
    func testPreDawnScoresTheWholeDayAhead() throws {
        let geometry = RiskWindowGeometry(calendar: calendar)
        let midTrace = SyntheticTraceFixture.start.addingTimeInterval(80 * 24 * 3600)
        let day = geometry.wakingDayStart(of: midTrace)
        let preDawn = day.addingTimeInterval(-3 * 3600)

        XCTAssertFalse(geometry.isWaking(preDawn))
        XCTAssertEqual(geometry.wakingDayStart(of: preDawn), day)
        XCTAssertNil(geometry.windowStart(containing: preDawn))

        let dayRows = RiskWindowBuilder.rows(
            observed: SyntheticTraceFixture.samples().filter { $0.timestamp < preDawn },
            forecast: forecastCurve(from: preDawn, hours: 30),
            checkIns: [],
            geometry: geometry,
            in: day..<day.addingTimeInterval(Double(geometry.windowsPerDay) * geometry.windowSeconds),
            asOf: preDawn
        )
        let forecast = try XCTUnwrap(
            WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: preDawn)
                .forecast(for: dayRows, asOf: preDawn)
        )

        XCTAssertEqual(forecast.windows.count, geometry.windowsPerDay)
        XCTAssertEqual(forecast.forecastShare, 1, accuracy: 1e-9,
                       "nothing in a day that has not started can have been measured")
    }

    /// The forecast reaches every day the forward curve covers, and marks each one on its own.
    ///
    /// The window stage answers "if an entry happens **that day**, when", so the top two are
    /// picked per day rather than globally — otherwise a strong Tuesday would silently take both
    /// of Wednesday's marks and the chart would draw four days of line with nothing on three of
    /// them. A day the curve barely reaches carries day-level features that are the mean of a
    /// morning, and is dropped whole rather than scored thinly.
    func testEveryCoveredDayAheadIsScoredAndMarkedOnItsOwn() throws {
        let geometry = RiskWindowGeometry(calendar: calendar)
        let now = geometry.wakingDayStart(
            of: SyntheticTraceFixture.start.addingTimeInterval(60 * 24 * 3600)
        )
        let built = threeDaysAhead(from: now, geometry: geometry)
        let model = WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: now)
        let forecast = try XCTUnwrap(model.forecast(for: built, asOf: now))

        let days = Set(forecast.windows.map(\.dayStart)).sorted()
        XCTAssertEqual(days.count, 2, "the third day is too thinly covered to score")
        XCTAssertEqual(forecast.dayStart, now, "today is the earliest day asked for")
        XCTAssertEqual(forecast.windows.count, 2 * geometry.windowsPerDay)
        XCTAssertEqual(forecast.windows, forecast.windows.sorted { $0.start < $1.start })
        XCTAssertEqual(days.last, now.addingTimeInterval(24 * 3600))

        // Per day, never more than the mark budget — and a day that is quiet names nothing.
        for day in days {
            let marked = forecast.marked.filter { $0.dayStart == day }
            XCTAssertLessThanOrEqual(marked.count, WellbeingRiskModel.markedWindowCount)
            XCTAssertTrue(marked.allSatisfy { $0.percent != nil },
                          "a marked window the row cannot put a number on is not marked")
            XCTAssertTrue(marked.allSatisfy { $0.end > now }, "nothing behind now is marked")
        }

        // The whole of both days is still ahead, so every window of both is a candidate — and
        // today's hours are the curve's, not the log's. Not exactly all of them: the hourly grid
        // bridges the last reading before the boundary into the 06:00 cell, so one of today's
        // eighteen hours is measured.
        XCTAssertTrue(forecast.windows.allSatisfy { $0.end > now })
        XCTAssertGreaterThan(forecast.forecastShare, 0.9)
    }

    /// The headline is the strongest **window** of today, not the day stage's own figure.
    ///
    /// The two are different questions and only one of them has something drawn under it. A
    /// headline that is not the maximum of what the plot marks is a headline that disagrees with
    /// its own chart — and, being a joint probability, it can never exceed the day stage.
    func testHeadlineIsTheStrongestWindowOfTodayAndNeverExceedsTheDayStage() throws {
        let geometry = RiskWindowGeometry(calendar: calendar)
        let now = geometry.wakingDayStart(
            of: SyntheticTraceFixture.start.addingTimeInterval(60 * 24 * 3600)
        )

        let built = threeDaysAhead(from: now, geometry: geometry)
        let model = WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: now)
        let forecast = try XCTUnwrap(model.forecast(for: built, asOf: now))

        let today = forecast.todayWindows
        XCTAssertEqual(today.count, geometry.windowsPerDay)
        XCTAssertEqual(try XCTUnwrap(forecast.checkInProbability),
                       try XCTUnwrap(today.map(\.combined).max()),
                       accuracy: 1e-12)

        // Tomorrow's windows do not move today's figure, however strong they are.
        let tomorrow = forecast.windows.filter { $0.dayStart != forecast.dayStart }
        XCTAssertFalse(tomorrow.isEmpty)

        // A joint probability is bounded by the day stage it was multiplied by.
        let dayChance = model.dayProbability(for: try XCTUnwrap(built.first))
        XCTAssertLessThanOrEqual(try XCTUnwrap(forecast.checkInProbability), dayChance + 1e-12)
    }

    /// Two adjacent marked windows read as one stretch, not two stripes with a seam.
    func testAdjacentMarkedWindowsMergeIntoOneStretch() {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let two = TimeInterval(RiskWindowGeometry.windowMinutes) * 60

        func window(_ index: Int, marked: Bool) -> ScoredRiskWindow {
            ScoredRiskWindow(start: start.addingTimeInterval(Double(index) * two),
                             end: start.addingTimeInterval(Double(index + 1) * two),
                             dayStart: start,
                             confidence: 0.5, combined: 0.4, forecastShare: 1, isMarked: marked)
        }

        let adjacent = WellbeingRiskForecast(
            dayStart: start, checkInProbability: 0.8,
            windows: [], marked: [window(1, marked: true), window(2, marked: true)],
            isDayQuiet: false, mayNotify: true, isColdStart: false,
            dayCoverage: 1, forecastShare: 1
        )
        XCTAssertEqual(adjacent.markedRanges.count, 1)
        XCTAssertEqual(adjacent.markedRanges.first?.upperBound.timeIntervalSince(
            adjacent.markedRanges.first?.lowerBound ?? start), 2 * two)

        let apart = WellbeingRiskForecast(
            dayStart: start, checkInProbability: 0.8,
            windows: [], marked: [window(1, marked: true), window(5, marked: true)],
            isDayQuiet: false, mayNotify: true, isColdStart: false,
            dayCoverage: 1, forecastShare: 1
        )
        XCTAssertEqual(apart.markedRanges.count, 2)
    }

    // MARK: - Cold start and degradation

    /// Three days of history: output, and output that leans on the prior.
    ///
    /// The requirement is that something usable comes out, not that it is personal. With three
    /// days there are at most a handful of entries and no personal model worth the name — which
    /// is exactly what the shipped prior is for.
    func testColdStartWithThreeDaysStillProducesAForecast() throws {
        let start = SyntheticTraceFixture.start
        let now = start.addingTimeInterval(3.5 * 24 * 3600)
        let geometry = RiskWindowGeometry(calendar: calendar)
        let day = geometry.wakingDayStart(of: now)

        let checkIns = SyntheticTraceFixture.checkIns().filter { $0.timestamp < now }
        XCTAssertLessThan(checkIns.count, 8, "three days cannot produce many entries")

        let dayRows = RiskWindowBuilder.rows(
            observed: SyntheticTraceFixture.samples().filter { $0.timestamp < now },
            forecast: forecastCurve(from: now, hours: 24),
            checkIns: checkIns,
            geometry: geometry,
            in: day..<day.addingTimeInterval(Double(geometry.windowsPerDay) * geometry.windowSeconds),
            asOf: now
        )

        let model = WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: now)
        let forecast = try XCTUnwrap(model.forecast(for: dayRows, asOf: now))

        XCTAssertTrue(forecast.isColdStart)
        XCTAssertTrue((0...1).contains(try XCTUnwrap(forecast.checkInProbability)))
        XCTAssertEqual(forecast.windows.count, geometry.windowsPerDay)
        XCTAssertGreaterThan(forecast.forecastShare, 0, "the afternoon is the forecast's half")
    }

    /// Without a forward curve, the day is only scoreable once the sensor has covered half of
    /// it — which is early afternoon.
    ///
    /// Not a defect and worth having a test on: the day-level features are averages over the
    /// whole waking day, so a morning with no forecast is a morning the app has to stay silent
    /// through rather than average three hours and call it a day.
    func testWithoutAForwardCurveTheMorningHasNoForecast() {
        let start = SyntheticTraceFixture.start
        let now = start.addingTimeInterval(3.5 * 24 * 3600)
        let geometry = RiskWindowGeometry(calendar: calendar)
        let day = geometry.wakingDayStart(of: now)

        let dayRows = RiskWindowBuilder.rows(
            observed: SyntheticTraceFixture.samples().filter { $0.timestamp < now },
            checkIns: [],
            geometry: geometry,
            in: day..<day.addingTimeInterval(Double(geometry.windowsPerDay) * geometry.windowSeconds),
            asOf: now
        )

        XCTAssertLessThan(dayRows.first?.dayCoverage ?? 1, RiskWindowBuilder.minimumDayCoverage)
        XCTAssertNil(WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: now)
            .forecast(for: dayRows, asOf: now))
    }

    /// Three waking days asked for from `now`, with ~50 h of forward curve under them.
    ///
    /// The third day gets one window of nine and falls under `minimumDayCoverage`, which is the
    /// arrangement both multi-day tests are about: two days scored, the thin one dropped whole.
    private func threeDaysAhead(from now: Date, geometry: RiskWindowGeometry) -> [RiskWindowRow] {
        RiskWindowBuilder.rows(
            observed: SyntheticTraceFixture.samples().filter { $0.timestamp < now },
            forecast: forecastCurve(from: now, hours: 50),
            checkIns: [],
            geometry: geometry,
            in: now..<now.addingTimeInterval(3 * 24 * 3600),
            asOf: now
        )
    }

    /// A stand-in forward curve, read off the trace's own later hours.
    ///
    /// It stands in for WeatherKit's coverage, not for its accuracy: these tests assert that a
    /// forward half **exists** and reaches the features, never how right it is. A curve taken
    /// from the future would flatter any accuracy claim made on it, so none is made.
    private func forecastCurve(from now: Date, hours: Int) -> [ForecastPressurePoint] {
        let byHour = Dictionary(
            SyntheticTraceFixture.samples().map {
                (RiskPressureGrid.alignedHour(of: $0.timestamp), $0.pressure)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let anchor = RiskPressureGrid.alignedHour(of: now)

        return (1...hours).compactMap { step in
            let hour = anchor.addingTimeInterval(Double(step) * 3600)
            guard let pressure = byHour[hour] else { return nil }
            return ForecastPressurePoint(id: UUID(),
                                         timestamp: hour,
                                         pressure: pressure,
                                         uncertaintyHPa: 1,
                                         source: .weatherKit,
                                         issuedAt: now)
        }
    }

    /// Under the training floor, no fit at all — and the caller is left with the prior.
    func testTrainerRefusesTooLittleHistory() {
        let start = SyntheticTraceFixture.start
        let now = start.addingTimeInterval(4 * 24 * 3600)
        let geometry = RiskWindowGeometry(calendar: calendar)

        let built = rows(asOf: now,
                         samples: SyntheticTraceFixture.samples().filter { $0.timestamp < now },
                         checkIns: SyntheticTraceFixture.checkIns().filter { $0.timestamp < now },
                         geometry: geometry)

        XCTAssertNil(WellbeingRiskTrainer.train(rows: built, geometry: geometry, asOf: now))
    }

    /// Enough history to fit, not enough to validate: a model, no report, and no claim.
    func testFitWithoutValidationProducesNoReport() throws {
        let start = SyntheticTraceFixture.start
        let now = start.addingTimeInterval(20 * 24 * 3600)
        let geometry = RiskWindowGeometry(calendar: calendar)

        let training = try XCTUnwrap(WellbeingRiskTrainer.train(
            rows: rows(asOf: now,
                       samples: SyntheticTraceFixture.samples().filter { $0.timestamp < now },
                       checkIns: SyntheticTraceFixture.checkIns().filter { $0.timestamp < now },
                       geometry: geometry),
            geometry: geometry,
            asOf: now
        ))

        XCTAssertNil(training.report)
        XCTAssertEqual(training.model.gateThreshold, WellbeingRiskPrior.gateThreshold)
    }

    /// A user who has never logged. Nothing may divide by zero, and nothing may claim a window.
    func testUserWithNoEntriesDegradesInsteadOfCrashing() {
        let now = SyntheticTraceFixture.now
        let geometry = RiskWindowGeometry(calendar: calendar)

        let built = rows(asOf: now,
                         samples: SyntheticTraceFixture.samples(),
                         checkIns: [],
                         geometry: geometry)
        XCTAssertFalse(built.isEmpty)
        XCTAssertFalse(built.contains(where: \.isLogged))

        let training = WellbeingRiskTrainer.train(rows: built, geometry: geometry, asOf: now)
        // A fit is still returned — the prior does not need this user's entries — but nothing
        // personal was fitted and the report cannot be scored.
        XCTAssertNil(training?.model.personalWindow)
        XCTAssertNil(training?.model.personalDay)
        XCTAssertEqual(training?.model.personalWeight, 0)
    }

    /// A 12-hour hole. Coverage falls, features go `nil` where the grid cannot reach, and
    /// nothing crashes or invents a value.
    func testTwelveHourGapReducesCoverageWithoutFabricatingValues() {
        let now = SyntheticTraceFixture.now
        let holeStart = now.addingTimeInterval(-40 * 3600)
        let holeEnd = now.addingTimeInterval(-28 * 3600)

        let punctured = SyntheticTraceFixture.samples().filter {
            !($0.timestamp >= holeStart && $0.timestamp < holeEnd)
        }
        let geometry = RiskWindowGeometry(calendar: calendar)

        let intact = rows(asOf: now, samples: SyntheticTraceFixture.samples(),
                          checkIns: [], geometry: geometry)
        let holed = rows(asOf: now, samples: punctured, checkIns: [], geometry: geometry)

        let inHole = holed.filter { $0.start >= holeStart && $0.end <= holeEnd }
        XCTAssertTrue(inHole.isEmpty, "a 12 h hole is longer than the bridge policy allows")

        let intactCoverage = intact.map(\.coverage).reduce(0, +)
        let holedCoverage = holed.map(\.coverage).reduce(0, +)
        XCTAssertLessThan(holedCoverage, intactCoverage)

        // Everything still produced is a real value or an admitted absence — never a NaN.
        for row in holed {
            for value in row.features { XCTAssertNotEqual(value?.isNaN, true) }
        }
    }

    /// An altitude step — 10 hPa in five minutes — is rejected, not learned.
    func testAltitudeStepIsRejectedRatherThanLearned() {
        let now = SyntheticTraceFixture.now
        let geometry = RiskWindowGeometry(calendar: calendar)
        var samples = SyntheticTraceFixture.samples()

        // A lift ride placed inside a window, as two readings five minutes apart.
        let excursionAt = now.addingTimeInterval(-6 * 3600)
        // swiftlint:disable:next force_unwrapping
        let neighbour = samples.last { $0.timestamp <= excursionAt }!
        samples.append(PressureSample(id: UUID(),
                                      timestamp: excursionAt.addingTimeInterval(60),
                                      pressure: Pressure(hectopascals: neighbour.pressure.hectopascals)))
        samples.append(PressureSample(
            id: UUID(),
            timestamp: excursionAt.addingTimeInterval(360),
            pressure: Pressure(hectopascals: neighbour.pressure.hectopascals - 10)
        ))

        let clean = rows(asOf: now, samples: SyntheticTraceFixture.samples(),
                         checkIns: [], geometry: geometry)
        let contaminated = rows(asOf: now, samples: samples, checkIns: [], geometry: geometry)

        let cleanByStart = Dictionary(clean.map { ($0.start, $0) }, uniquingKeysWith: { first, _ in first })
        for row in contaminated {
            guard let match = cleanByStart[row.start],
                  let contaminatedValue = row[.pressureHPa],
                  let cleanValue = match[.pressureHPa] else { continue }
            XCTAssertEqual(contaminatedValue, cleanValue, accuracy: 0.5,
                           "a 10 hPa step in 5 min must not reach a feature")
        }
    }

    /// A kPa-valued reading — the classic unit mix-up — must not reach a feature.
    func testKilopascalValuedReadingIsRejectedAtThePlausibilityGate() {
        XCTAssertFalse(Pressure(hectopascals: 101.3).isPlausible)
        XCTAssertTrue(Pressure(hectopascals: 1013).isPlausible)
    }

    // MARK: - Leakage

    /// The forward-chaining splits never put a test day before a training day, and never share
    /// one. This is the guard that a random shuffle cannot sneak back in.
    func testSplitsAreForwardChainingWithAGap() {
        let days = (0..<60).map { Date(timeIntervalSince1970: 1_700_000_000 + Double($0) * 86_400) }
        let splits = WellbeingRiskTrainer.splits(days: days, foldCount: 4, testSize: 10, gapDays: 1)

        XCTAssertEqual(splits.count, 4)
        for split in splits {
            // swiftlint:disable:next force_unwrapping
            let lastTrain = split.trainDays.max()!
            // swiftlint:disable:next force_unwrapping
            let firstTest = split.testDays.min()!
            XCTAssertTrue(split.trainDays.isDisjoint(with: split.testDays))
            XCTAssertLessThan(lastTrain, firstTest)
            XCTAssertGreaterThanOrEqual(firstTest.timeIntervalSince(lastTrain), 2 * 86_400,
                                        "one day of gap on top of the boundary itself")
        }

        // Each fold trains on strictly more history than the one before it.
        let sizes = splits.map(\.trainDays.count)
        XCTAssertEqual(sizes, sizes.sorted())
    }

    /// Training rejects anything built from a forecast, and anything that has not finished.
    func testTrainerRejectsForecastAndFutureRows() {
        let now = SyntheticTraceFixture.now
        let geometry = RiskWindowGeometry(calendar: calendar)
        let day = geometry.wakingDayStart(of: now)

        let forwardRow = RiskWindowRow(start: day, dayStart: day,
                                       features: [Double?](repeating: 1, count: RiskFeature.allCases.count),
                                       coverage: 0, forecastShare: 1, dayCoverage: 1, isLogged: true)

        XCTAssertNil(WellbeingRiskTrainer.train(rows: [forwardRow], geometry: geometry, asOf: now))
    }

    // MARK: - Blend

    /// `w(n) = n / (n + 30)`, and the cold-start boundary is where the two halves are equal.
    func testPriorBlendWeightFollowsTheStatedCurve() {
        XCTAssertEqual(WellbeingRiskModel.priorBlendWeight(labelledEntryCount: 0), 0)
        XCTAssertEqual(WellbeingRiskModel.priorBlendWeight(labelledEntryCount: 30), 0.5, accuracy: 1e-12)
        XCTAssertEqual(WellbeingRiskModel.priorBlendWeight(labelledEntryCount: 90), 0.75, accuracy: 1e-12)
        XCTAssertLessThan(WellbeingRiskModel.priorBlendWeight(labelledEntryCount: 10_000), 1)

        // The card the user watches counts the same rows the weight is a function of.
        XCTAssertGreaterThan(
            WellbeingRiskModel.priorBlendWeight(
                labelledEntryCount: TrainingDataProgress.targetCheckInCount),
            0.5
        )
    }

    /// The personal component is inside the feature budget §4 sets.
    func testPersonalComponentStaysInsideTheFeatureBudget() {
        XCTAssertLessThanOrEqual(RiskFeature.personalWindowColumns.count, 6)
        XCTAssertLessThanOrEqual(RiskFeature.dayColumns.count, 6)
        XCTAssertEqual(Set(RiskFeature.personalWindowColumns).count,
                       RiskFeature.personalWindowColumns.count)
    }
}
