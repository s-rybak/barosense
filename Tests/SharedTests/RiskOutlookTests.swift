import XCTest
@testable import Barosense

/// What the risk card is allowed to say, decided away from the card.
///
/// `RiskOutlookCard` is a pure function of `RiskOutlook`, so everything that can be wrong about
/// the card without being visibly wrong lives here: a countdown to a stretch that has already
/// finished, a ring drawn for an occasion that is over, a trailing average taken over the
/// wrong fortnight, or a card that renders at all when the model declined to speak.
final class RiskOutlookTests: XCTestCase {

    /// UTC. None of these rules is time-zone sensitive; pinning it keeps them from depending
    /// on the machine that runs them.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    private let now = Date(timeIntervalSince1970: 1_772_000_000)

    // MARK: - When there is no card

    func testNoForecastMeansNoCard() {
        XCTAssertNil(RiskOutlook.make(risk: nil, checkIns: [], asOf: now, calendar: calendar))
    }

    /// A forecast the model declined to make draws nothing, however much log there is.
    ///
    /// The log alone is not a reason to show this card: it is the risk card, and one carrying
    /// three dots and no statement is an outlined box under a heading.
    func testAnUnpresentableForecastMeansNoCard() {
        let quiet = Self.forecast(percent: nil, markedOffsets: [], asOf: now)
        XCTAssertFalse(quiet.isPresentable)

        XCTAssertNil(RiskOutlook.make(risk: quiet,
                                      checkIns: Self.checkIns([3, 5, 7], asOf: now),
                                      asOf: now,
                                      calendar: calendar))
    }

    /// A forecast whose every marked stretch has finished, and which has no percentage, is a
    /// forecast with nothing left in it.
    ///
    /// `isPresentable` is measured against `marked` as the engine built it, and a forecast is
    /// memoised for 15 minutes — long enough for its last stretch to end while the card is on
    /// screen. Trusted rather than re-filtered, this drew a card with a headline and no
    /// content.
    func testAStretchThatHasFinishedIsNotACard() {
        let stale = Self.forecast(percent: nil, markedOffsets: [-4, -3], asOf: now)
        XCTAssertTrue(stale.isPresentable, "the forecast still holds marked windows")

        XCTAssertNil(RiskOutlook.make(risk: stale, checkIns: [], asOf: now, calendar: calendar))
    }

    // MARK: - Lead time

    func testLeadIsMeasuredToTheStartOfTheNextStretch() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2, 3], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        guard case .ahead(let seconds) = outlook.lead else {
            return XCTFail("a stretch two windows out is ahead, not under way")
        }
        XCTAssertEqual(seconds, 4 * 3600, accuracy: 1)
    }

    /// Two adjacent windows are one stretch, and the lead runs to the start of the pair — not
    /// to the start of the second one.
    func testAdjacentWindowsAreOneOccasion() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2, 3], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.expectedCount, 1, "one four-hour band, one ring")
        XCTAssertEqual(try XCTUnwrap(outlook.stretch).upperBound
            .timeIntervalSince(try XCTUnwrap(outlook.stretch).lowerBound), 4 * 3600)
    }

    func testSeparatedWindowsAreSeparateOccasions() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [1, 4], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.expectedCount, 2)
    }

    /// The row draws three rings at most, whatever the model marked.
    ///
    /// Two windows a day over a four-day curve is up to eight stretches, and eight rings beside
    /// three recorded dots is not the row the card was designed as. The chart below keeps every
    /// one of them, so the cap costs the user nothing.
    func testTheRingsAreCappedAtTheDesignsCount() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [1, 3, 5, 7], asOf: now)
        XCTAssertEqual(risk.markedRanges.count, 4, "four separated stretches, or this proves nothing")

        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.expectedCount, RiskOutlook.expectedChipCount)
    }

    /// The cap counts from the front: it drops the furthest stretches, never the nearest.
    ///
    /// `stretch` and `lead` both name the first one, so a cap taken off the wrong end would
    /// leave the card counting down to a ring it no longer draws.
    func testTheCapKeepsTheNearestStretches() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [1, 3, 5, 7], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        let first = try XCTUnwrap(risk.markedRanges.first)
        XCTAssertEqual(try XCTUnwrap(outlook.stretch).lowerBound, first.lowerBound)
    }

    /// A stretch the clock is already inside is reported as under way, never as a countdown.
    ///
    /// The card's smallest printed unit is a minute, so a lead under one formats to an empty
    /// string; "in 0 min" is not a lead time either way.
    func testAStretchAlreadyRunningIsUnderWay() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [0], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.lead, .underWay)
        XCTAssertEqual(outlook.expectedCount, 1, "it has not finished, so it still counts")
    }

    func testAQuietDayHasAPercentageAndNoRings() throws {
        let risk = Self.forecast(percent: 0.31, markedOffsets: [], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.checkInPercent, 31)
        XCTAssertNil(outlook.lead)
        XCTAssertNil(outlook.stretch)
        XCTAssertEqual(outlook.expectedCount, 0)
    }

    // MARK: - The log side

    /// Oldest first, so the row reads left to right toward the divider that stands for now.
    func testRecentChipsAreTheNewestEntriesOldestFirst() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2], asOf: now)
        let log = Self.checkIns([9, 1, 4, 6, 2], asOf: now)   // oldest 9, newest 2

        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: log.shuffled(),
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.recent.map(\.rawValue), [4, 6, 2])
        XCTAssertEqual(outlook.recent.count, RiskOutlook.recentCheckInCount)
    }

    func testAnEmptyLogDrawsNoChipsAndNoProjection() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: [],
                                                     asOf: now, calendar: calendar))

        XCTAssertTrue(outlook.recent.isEmpty)
        XCTAssertNil(outlook.expectedIntensity)
        XCTAssertTrue(outlook.hasChips, "the forecast rings are still drawn")
    }

    /// The projection is the trailing fortnight, rounded onto the scale.
    func testProjectedIntensityIsTheTrailingMean() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2], asOf: now)
        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk,
                                                     checkIns: Self.checkIns([4, 6, 5], asOf: now),
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.expectedIntensity, CheckInIntensity(clamping: 5))
    }

    /// Entries older than the window do not move it.
    ///
    /// Read over the whole log instead, a user who logged 9s for a month last winter and 2s
    /// this week gets rings drawn at the winter's colour — a projection of a fortnight that
    /// is not the one being projected from.
    func testEntriesOlderThanTheWindowAreNotAveraged() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2], asOf: now)

        let day = 24.0 * 3600
        let recent = [2, 2, 2].enumerated().map { offset, value in
            CheckIn(timestamp: now.addingTimeInterval(-Double(offset + 1) * day),
                    intensity: CheckInIntensity(clamping: value))
        }
        let ancient = (0..<20).map { index in
            CheckIn(timestamp: now.addingTimeInterval(-Double(RiskOutlook.projectionWindowDays + index + 1) * day),
                    intensity: CheckInIntensity(clamping: 9))
        }

        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: recent + ancient,
                                                     asOf: now, calendar: calendar))

        XCTAssertEqual(outlook.expectedIntensity, CheckInIntensity(clamping: 2))
    }

    /// Nothing in the last fortnight means no projection at all — not a zero, and not the
    /// colour of whatever was logged last.
    func testASilentFortnightHasNoProjection() throws {
        let risk = Self.forecast(percent: 0.62, markedOffsets: [2], asOf: now)
        let day = 24.0 * 3600
        let old = (0..<3).map { index in
            CheckIn(timestamp: now.addingTimeInterval(-Double(RiskOutlook.projectionWindowDays + index + 1) * day),
                    intensity: CheckInIntensity(clamping: 8))
        }

        let outlook = try XCTUnwrap(RiskOutlook.make(risk: risk, checkIns: old,
                                                     asOf: now, calendar: calendar))

        XCTAssertNil(outlook.expectedIntensity)
        XCTAssertEqual(outlook.recent.count, 3, "they are still the last entries there are")
    }

    // MARK: - Fixtures

    /// A forecast whose windows are two hours wide, laid out from `now`.
    ///
    /// `markedOffsets` are window indices relative to `now`: 0 is the one in progress, negative
    /// ones have finished. `percent` is the joint figure the card prints, or `nil` for a day
    /// that could not be scored.
    private static func forecast(percent: Double?,
                                 markedOffsets: Set<Int>,
                                 asOf now: Date) -> WellbeingRiskForecast {
        let width = TimeInterval(RiskWindowGeometry.windowMinutes) * 60
        let range = -4...8

        let windows = range.map { offset in
            ScoredRiskWindow(start: now.addingTimeInterval(Double(offset) * width),
                             end: now.addingTimeInterval(Double(offset + 1) * width),
                             dayStart: now.addingTimeInterval(Double(range.lowerBound) * width),
                             confidence: markedOffsets.contains(offset) ? 0.9 : 0.2,
                             combined: (percent ?? 0) * (markedOffsets.contains(offset) ? 0.9 : 0.2),
                             forecastShare: 1,
                             isMarked: markedOffsets.contains(offset))
        }

        return WellbeingRiskForecast(dayStart: now.addingTimeInterval(Double(range.lowerBound) * width),
                                     checkInProbability: percent,
                                     windows: windows,
                                     marked: windows.filter(\.isMarked),
                                     isDayQuiet: markedOffsets.isEmpty,
                                     mayNotify: false,
                                     isColdStart: false,
                                     dayCoverage: 1,
                                     forecastShare: 1)
    }

    /// One entry a day back from `now`, `intensities` given oldest first.
    private static func checkIns(_ intensities: [Int], asOf now: Date) -> [CheckIn] {
        intensities.enumerated().map { offset, value in
            CheckIn(timestamp: now.addingTimeInterval(-Double(intensities.count - offset) * 24 * 3600),
                    intensity: CheckInIntensity(clamping: value))
        }
    }
}
