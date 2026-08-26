import XCTest
@testable import Barosense

/// The domain rules the two stages are built on, and the places each one used to be got wrong.
///
/// Every test here is a regression: the assertion is the fixed behaviour, and the comment says
/// what the broken behaviour produced. They live apart from `WellbeingRiskPipelineTests`
/// because none of them scores anything — they are about geometry, blending and splits, which
/// is where a silent mistake costs a whole training window rather than one row.
final class RiskDomainRulesTests: XCTestCase {

    /// UTC unless a test needs a zone with a transition in it.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    // MARK: - Where the waking day starts

    /// One entry in the small hours must not redraw the domain for the next 120 days.
    ///
    /// Read off the minimum, a single 00:30 entry among a hundred put `dayStartHour` at 0: a
    /// twelve-window day instead of nine, a base rate and a `randomHitAtOne` to match, and the
    /// whole log scored against a domain the shipped coefficients were never fitted on.
    func testASingleEarlyOutlierDoesNotMoveTheWakingBoundary() {
        let day = Date(timeIntervalSince1970: 1_740_960_000)
        var entries = (0..<40).map { index in
            CheckIn(timestamp: day.addingTimeInterval(Double(index) * 24 * 3600 + 9 * 3600),
                    intensity: CheckInIntensity(clamping: 3))
        }
        let regular = RiskWindowGeometry.measured(from: entries, calendar: calendar)
        XCTAssertEqual(regular.dayStartHour, 9 - RiskWindowGeometry.dayStartMarginHours)

        entries.append(CheckIn(timestamp: day.addingTimeInterval(30 * 60),
                               intensity: CheckInIntensity(clamping: 3)))
        let withOutlier = RiskWindowGeometry.measured(from: entries, calendar: calendar)

        XCTAssertEqual(withOutlier.dayStartHour, regular.dayStartHour,
                       "one 00:30 entry is an anecdote, not a waking hour")
        XCTAssertEqual(withOutlier.windowsPerDay, regular.windowsPerDay)
    }

    /// A real early habit still moves it — the trim is a quantile, not a floor.
    func testASustainedEarlyHabitDoesMoveTheWakingBoundary() {
        let day = Date(timeIntervalSince1970: 1_740_960_000)
        let entries = (0..<40).map { index in
            CheckIn(timestamp: day.addingTimeInterval(Double(index) * 24 * 3600 + 5 * 3600),
                    intensity: CheckInIntensity(clamping: 3))
        }

        XCTAssertEqual(RiskWindowGeometry.measured(from: entries, calendar: calendar).dayStartHour,
                       5 - RiskWindowGeometry.dayStartMarginHours)
    }

    /// The boundary is a wall-clock hour, so a DST transition must not slide it.
    ///
    /// Built by adding `dayStartHour * 3600` to local midnight, the spring-forward day opened at
    /// 07:00 and its last window ran an hour past the geometry's own idea of the day — one day a
    /// year scored against a domain shifted by a whole window.
    func testTheWakingBoundaryHoldsItsWallClockHourAcrossDST() throws {
        var kyiv = Calendar(identifier: .gregorian)
        kyiv.timeZone = try XCTUnwrap(TimeZone(identifier: "Europe/Kyiv"))
        let geometry = RiskWindowGeometry(dayStartHour: 6, calendar: kyiv)

        // 2026-03-29 is the spring-forward day in Kyiv: 03:00 becomes 04:00.
        let transition = try XCTUnwrap(
            kyiv.date(from: DateComponents(year: 2026, month: 3, day: 29, hour: 12))
        )

        let start = geometry.wakingDayStart(of: transition)
        XCTAssertEqual(kyiv.component(.hour, from: start), 6,
                       "06:00 means 06:00 on the clock the user reads")
        XCTAssertEqual(kyiv.component(.day, from: start), 29)
    }

    // MARK: - Cold start

    /// A stage that could not be fitted is a cold start whatever `n` says.
    ///
    /// A user who logs every day gives the day stage no negative class, the fitter refuses, and
    /// the blend falls through to the shipped prior. Keyed on `w(n)` alone, `isColdStart` then
    /// read false on a figure that was 100% prior — and the "still learning your pattern"
    /// disclosure came off the screen exactly where it was needed.
    func testAModelMissingAStageIsColdStartAtAnyEntryCount() throws {
        let now = Date(timeIntervalSince1970: 1_740_960_000)
        let stage = RiskStage(model: WellbeingRiskPrior.window,
                              calibration: nil,
                              columns: RiskFeature.windowColumns)

        let halfFitted = try XCTUnwrap(WellbeingRiskModel.blending(personalDay: nil,
                                                                   personalWindow: stage,
                                                                   labelledEntryCount: 500,
                                                                   dayStartHour: 6,
                                                                   trainedAt: now))
        XCTAssertGreaterThan(halfFitted.personalWeight, 0.9, "n is large by any measure")
        XCTAssertTrue(halfFitted.isColdStart, "a stage that fell through to the prior is cold")

        let dayStage = RiskStage(model: WellbeingRiskPrior.day,
                                 calibration: WellbeingRiskPrior.dayCalibration,
                                 columns: RiskFeature.dayColumns)
        let fitted = try XCTUnwrap(WellbeingRiskModel.blending(personalDay: dayStage,
                                                              personalWindow: stage,
                                                              labelledEntryCount: 500,
                                                              dayStartHour: 6,
                                                              trainedAt: now))
        XCTAssertFalse(fitted.isColdStart)
    }

    /// The shipped prior alone is always a cold start, and it is what a fresh device gets.
    func testThePriorAloneIsColdStart() throws {
        let model = try XCTUnwrap(
            WellbeingRiskModel.prior(trainedAt: Date(timeIntervalSince1970: 1_740_960_000))
        )

        XCTAssertTrue(model.isColdStart)
        XCTAssertEqual(model.personalWeight, 0)
        XCTAssertEqual(model.gateThreshold, WellbeingRiskPrior.gateThreshold)
    }

    // MARK: - Forward chaining

    /// A test size that leaves nothing to train on falls back to equal blocks and terminates.
    ///
    /// The fallback used to re-enter `splits` with the arguments it was called with. Reachable
    /// only through a caller passing a `testSize` the day count cannot support — which nothing
    /// does today — but the failure mode was a stack overflow, not a bad split.
    func testAnImpossibleTestSizeFallsBackInsteadOfRecursing() {
        let days = (0..<12).map { Date(timeIntervalSince1970: 1_740_960_000 + Double($0) * 86_400) }

        let folds = WellbeingRiskTrainer.splits(days: days, foldCount: 4, testSize: 99)
        XCTAssertFalse(folds.isEmpty)

        let equal = WellbeingRiskTrainer.splits(days: days, foldCount: 4)
        XCTAssertEqual(folds, equal, "the fallback is the equal-block split, computed once")

        for fold in folds {
            XCTAssertFalse(fold.trainDays.isEmpty)
            XCTAssertFalse(fold.testDays.isEmpty)
            XCTAssertTrue(fold.trainDays.isDisjoint(with: fold.testDays))
            // Forward-chaining: every training day precedes every test day.
            XCTAssertLessThan(try XCTUnwrap(fold.trainDays.max()),
                              try XCTUnwrap(fold.testDays.min()))
        }
    }

    // MARK: - Baseline

    /// A baseline measured over an afternoon is refused rather than returned.
    ///
    /// `cellCount` was carried and never read, so a short read produced a well-formed baseline
    /// over whatever it happened to cover and every level feature shifted with it, silently.
    func testABaselineOverTooFewHoursIsRefused() {
        let now = Date(timeIntervalSince1970: 1_740_960_000)
        let thin = (0..<8).map { index in
            PressureSample(timestamp: now.addingTimeInterval(Double(index - 8) * 3600),
                           pressure: Pressure(hectopascals: 1000))
        }

        XCTAssertNil(RiskWindowBuilder.baseline(observed: thin, asOf: now))
        XCTAssertTrue(RiskWindowBuilder.rows(observed: thin,
                                             geometry: RiskWindowGeometry(calendar: calendar),
                                             in: now..<now.addingTimeInterval(3600),
                                             asOf: now).isEmpty)
    }
}
