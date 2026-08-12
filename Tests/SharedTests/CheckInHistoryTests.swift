import XCTest
@testable import Barosense

/// What the History screen draws, given a list of check-ins.
///
/// Every test pins its own `Calendar` — fixed identifier, fixed time zone, fixed first
/// weekday. `.current` would make these pass or fail by the machine they run on, and the
/// grid's leading blanks in particular are entirely a function of `firstWeekday`.
final class CheckInHistoryTests: XCTestCase {

    /// Monday-first, Kyiv, as a Ukrainian user's device is configured.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        calendar.locale = Locale(identifier: "uk_UA")
        calendar.firstWeekday = 2
        return calendar
    }()

    // MARK: - Window

    func testTheMonthWindowIsExactlyThatMonth() {
        let window = CheckInHistory.window(for: .month,
                                           anchoredOn: date(2026, 5, 17),
                                           calendar: calendar)

        XCTAssertEqual(window.lowerBound, date(2026, 5, 1, hour: 0))
        XCTAssertEqual(window.upperBound, date(2026, 6, 1, hour: 0))
    }

    func testTheWindowIsHalfOpenSoTwoMonthsNeverBothClaimMidnight() {
        // The same rule `CheckInStore.checkIns(in:)` is written to: adjacent windows must be
        // requestable without the check-in on the boundary landing in both.
        let may = CheckInHistory.window(for: .month, anchoredOn: date(2026, 5, 17), calendar: calendar)
        let june = CheckInHistory.window(for: .month, anchoredOn: date(2026, 6, 2), calendar: calendar)

        XCTAssertEqual(may.upperBound, june.lowerBound)
        XCTAssertFalse(may.contains(june.lowerBound))
        XCTAssertTrue(june.contains(june.lowerBound))
    }

    func testTheWiderWindowsEndWithTheAnchorMonthRatherThanStartingFromIt() {
        // The property the whole screen leans on: the ‹ › arrows move the grid *and* the
        // counts card, so the card cannot describe a stretch of time the grid is not showing.
        let anchor = date(2026, 5, 17)

        let quarter = CheckInHistory.window(for: .threeMonths, anchoredOn: anchor, calendar: calendar)
        XCTAssertEqual(quarter.lowerBound, date(2026, 3, 1, hour: 0))
        XCTAssertEqual(quarter.upperBound, date(2026, 6, 1, hour: 0))

        let year = CheckInHistory.window(for: .year, anchoredOn: anchor, calendar: calendar)
        XCTAssertEqual(year.lowerBound, date(2025, 6, 1, hour: 0))
        XCTAssertEqual(year.upperBound, date(2026, 6, 1, hour: 0))
    }

    func testAllHasNoLowerBoundButStillStopsAtTheAnchorMonth() {
        let window = CheckInHistory.window(for: .all,
                                           anchoredOn: date(2026, 5, 17),
                                           calendar: calendar)

        XCTAssertEqual(window.lowerBound, .distantPast)
        XCTAssertEqual(window.upperBound, date(2026, 6, 1, hour: 0))
    }

    func testSteppingAMonthCrossesTheYearBoundary() {
        XCTAssertEqual(CheckInHistory.month(offsetBy: 1, from: date(2026, 12, 20), calendar: calendar),
                       date(2027, 1, 1, hour: 0))
        XCTAssertEqual(CheckInHistory.month(offsetBy: -1, from: date(2026, 1, 3), calendar: calendar),
                       date(2025, 12, 1, hour: 0))
    }

    // MARK: - Grid

    func testTheGridPadsTheLeadingBlanksToTheCalendarsFirstWeekday() {
        // 1 May 2026 is a Friday, so a Monday-first grid opens with four blanks.
        let grid = CheckInHistory.grid(forMonthContaining: date(2026, 5, 17), calendar: calendar)

        XCTAssertEqual(grid.month, date(2026, 5, 1, hour: 0))
        XCTAssertEqual(grid.cells.prefix(4).filter { $0 == nil }.count, 4)
        XCTAssertEqual(grid.cells[4], date(2026, 5, 1, hour: 0))
    }

    func testASundayFirstCalendarShiftsTheSameMonthByOne() {
        // Proof the offset comes from `firstWeekday` and is not baked in: the identical month
        // opens with five blanks when the week starts on Sunday.
        var sundayFirst = calendar
        sundayFirst.firstWeekday = 1

        let grid = CheckInHistory.grid(forMonthContaining: date(2026, 5, 17), calendar: sundayFirst)

        XCTAssertEqual(grid.cells.prefix(5).filter { $0 == nil }.count, 5)
        XCTAssertEqual(grid.weekdays, [1, 2, 3, 4, 5, 6, 7])
    }

    func testTheWeekdayHeaderStartsWhereTheCalendarSaysTheWeekDoes() {
        let grid = CheckInHistory.grid(forMonthContaining: date(2026, 5, 17), calendar: calendar)

        XCTAssertEqual(grid.weekdays, [2, 3, 4, 5, 6, 7, 1])
    }

    func testEveryGridIsWholeWeeksAndHoldsEveryDayOfTheMonth() {
        // February in a leap year: 29 days from a Thursday, so 3 blanks + 29 = 32, padded to
        // 35. Trailing padding is what keeps the last row from collapsing to four columns.
        let grid = CheckInHistory.grid(forMonthContaining: date(2024, 2, 14), calendar: calendar)

        XCTAssertEqual(grid.cells.count % 7, 0)
        XCTAssertEqual(grid.cells.count, 35)
        XCTAssertEqual(grid.cells.compactMap { $0 }.count, 29)
    }

    func testEveryCellIsTheStartOfItsOwnDay() {
        let grid = CheckInHistory.grid(forMonthContaining: date(2026, 5, 17), calendar: calendar)

        for cell in grid.cells.compactMap({ $0 }) {
            XCTAssertEqual(cell, calendar.startOfDay(for: cell))
        }
    }

    // MARK: - Counting

    func testNoCheckInsSummarisesToNothingRatherThanToZeroesWithAFabricatedDay() {
        let summary = CheckInHistory.summary(of: [], calendar: calendar)

        XCTAssertEqual(summary, .empty)
        XCTAssertTrue(summary.days.isEmpty)
        XCTAssertTrue(summary.tagCounts.isEmpty)
    }

    func testTheCardCountsCheckInsTagsAndEveryMedicationEntry() {
        let summary = CheckInHistory.summary(of: [
            checkIn(day: 4, intensity: 3, tags: ["headache"], doses: 1),
            checkIn(day: 6, intensity: 8, tags: ["headache", "fatigue"], doses: 2),
            checkIn(day: 9, intensity: 2, tags: ["fatigue"], doses: 0)
        ], calendar: calendar)

        XCTAssertEqual(summary.checkInCount, 3)
        XCTAssertEqual(summary.medicationCount, 3)
        XCTAssertEqual(summary.tagCounts.map(\.count), [2, 2])
    }

    func testADaysColourComesFromItsWorstCheckInAndNotItsAverage() {
        // The reason the grid stores a peak: averaging one 9 with two 2s reports a 4 and draws
        // the day green, hiding exactly the day the user opened the calendar to find.
        let summary = CheckInHistory.summary(of: [
            checkIn(day: 12, intensity: 2, hour: 8),
            checkIn(day: 12, intensity: 9, hour: 14),
            checkIn(day: 12, intensity: 2, hour: 21)
        ], calendar: calendar)

        let day = summary.days[date(2026, 5, 12, hour: 0)]

        XCTAssertEqual(day?.peakIntensity.rawValue, 9)
        XCTAssertEqual(day?.checkInCount, 3)
    }

    func testCheckInsAreBucketedByLocalDayAndNotByUTC() {
        // 22:30 in Kyiv is still the 12th there and already the 13th in UTC. Bucketing on the
        // wrong calendar moves a late-evening check-in onto the next day's cell.
        let summary = CheckInHistory.summary(of: [checkIn(day: 12, intensity: 5, hour: 22)],
                                             calendar: calendar)

        XCTAssertNotNil(summary.days[date(2026, 5, 12, hour: 0)])
        XCTAssertNil(summary.days[date(2026, 5, 13, hour: 0)])
    }

    func testMedicationEntriesAccumulateOntoTheDayThatCarriesThem() {
        let summary = CheckInHistory.summary(of: [
            checkIn(day: 3, intensity: 4, doses: 2, hour: 9),
            checkIn(day: 3, intensity: 6, doses: 1, hour: 18)
        ], calendar: calendar)

        XCTAssertEqual(summary.days[date(2026, 5, 3, hour: 0)]?.medicationCount, 3)
    }

    func testTagsAreRankedMostUsedFirst() {
        let summary = CheckInHistory.summary(of: [
            checkIn(day: 1, intensity: 3, tags: ["fatigue"]),
            checkIn(day: 2, intensity: 3, tags: ["headache"]),
            checkIn(day: 3, intensity: 3, tags: ["headache"]),
            checkIn(day: 4, intensity: 3, tags: ["headache"])
        ], calendar: calendar)

        XCTAssertEqual(summary.tagCounts.first?.id, .seeded("headache"))
        XCTAssertEqual(summary.tagCounts.first?.count, 3)
        XCTAssertEqual(summary.tagCounts.last?.id, .seeded("fatigue"))
    }

    func testEquallyUsedTagsKeepTheSameOrderOnEveryPass() {
        // The card shows the top two. A dictionary enumerates in an order that is not stable
        // across runs, so without a tie-break two equally used tags would swap on a redraw.
        let checkIns = [
            checkIn(day: 1, intensity: 3, tags: ["fatigue"]),
            checkIn(day: 2, intensity: 3, tags: ["headache"]),
            checkIn(day: 3, intensity: 3, tags: ["joints"]),
            checkIn(day: 4, intensity: 3, tags: ["mood"])
        ]

        let first = CheckInHistory.summary(of: checkIns, calendar: calendar).tagCounts
        let reversed = CheckInHistory.summary(of: checkIns.reversed(), calendar: calendar).tagCounts

        XCTAssertEqual(first, reversed)
        XCTAssertEqual(first.map(\.count), [1, 1, 1, 1])
    }

    // MARK: - Helpers

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 9) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return calendar.date(from: components)!
    }

    /// A check-in in May 2026, which is the month every counting test works in.
    private func checkIn(day: Int,
                         intensity: Int,
                         tags: [String] = [],
                         doses: Int = 0,
                         hour: Int = 9) -> CheckIn {
        let timestamp = date(2026, 5, day, hour: hour)
        let medications = (0..<doses).map {
            MedicationEntry(name: "Ibuprofen",
                            dose: "400 mg",
                            takenAt: timestamp.addingTimeInterval(Double($0) * 3600))!
        }

        return CheckIn(timestamp: timestamp,
                       intensity: CheckInIntensity(clamping: intensity),
                       tagIDs: Set(tags.map { WellbeingTag.ID.seeded($0) }),
                       medications: medications)
    }
}
