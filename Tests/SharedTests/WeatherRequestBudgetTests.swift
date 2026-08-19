import XCTest
@testable import Barosense

/// Four requests a day, at four moments, counted off stored rows.
final class WeatherRequestBudgetTests: XCTestCase {

    private let budget = WeatherRequestBudget()

    /// A fixed zone, so a slot at "12:00" is 12:00 in the test as well as in the arithmetic.
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        // swiftlint:disable:next force_unwrapping
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv")!
        return calendar
    }

    // MARK: - Slots

    func testTheDefaultSlotsAreEightNoonFourAndEight() {
        let slots = budget.slots(on: date(hour: 9), calendar: calendar)

        XCTAssertEqual(slots.map { calendar.component(.hour, from: $0) }, [8, 12, 16, 20])
    }

    /// The first slot follows the user's own morning. Read from `.sleepAnalysis`, which is
    /// already authorised — no new HealthKit type is requested for this.
    func testTheFirstSlotMovesToTheUsersWakeHour() {
        let slots = budget.slots(on: date(hour: 12),
                                 calendar: calendar,
                                 wakeTime: date(hour: 6, minute: 40))

        XCTAssertEqual(slots.map { calendar.component(.hour, from: $0) }, [6, 12, 16, 20])
    }

    /// One bad night — a flight, a newborn, a sleep sample Health recorded badly — must not
    /// move the morning request to the middle of the night.
    func testAnAbsurdlyEarlyWakeIsClampedIntoTheMorning() {
        let slots = budget.slots(on: date(hour: 12),
                                 calendar: calendar,
                                 wakeTime: date(hour: 2))

        XCTAssertEqual(slots.first.map { calendar.component(.hour, from: $0) },
                       WeatherRequestBudget.earliestFirstSlotHour)
    }

    func testALateWakeIsClampedBelowTheNoonSlot() {
        let slots = budget.slots(on: date(hour: 15),
                                 calendar: calendar,
                                 wakeTime: date(hour: 14))

        XCTAssertEqual(slots.map { calendar.component(.hour, from: $0) }, [11, 12, 16, 20])
    }

    /// Waking at exactly noon must not produce two slots at 12:00 — and therefore must not
    /// let one activation spend two of the day's four.
    func testAWakeOnAFixedSlotHourDoesNotDuplicateIt() {
        let slots = budget.slots(on: date(hour: 15),
                                 calendar: calendar,
                                 wakeTime: date(hour: 11))

        XCTAssertEqual(slots.count, 4)
        XCTAssertEqual(Set(slots).count, 4)
    }

    // MARK: - Counting

    func testTheCountComesFromIssuesInsideTheLocalDay() {
        let issues = [date(hour: 8), date(hour: 12), date(hour: 8, dayOffset: -1)]

        XCTAssertEqual(budget.spentRequests(on: date(hour: 13),
                                            given: issues,
                                            calendar: calendar), 2)
    }

    /// Not clamped to the cap. The number exists to be checked against, so it has to be able
    /// to disagree with the promise.
    func testADayOverTheCapReportsWhatIsActuallyThere() {
        let issues = (0..<5).map { date(hour: 6 + $0) }

        XCTAssertEqual(budget.spentRequests(on: date(hour: 20),
                                            given: issues,
                                            calendar: calendar), 5)
        XCTAssertEqual(budget.remainingRequests(on: date(hour: 20),
                                                given: issues,
                                                calendar: calendar), 0)
    }

    // MARK: - Due slots

    func testNothingIsDueBeforeTheFirstSlot() {
        XCTAssertNil(budget.dueSlot(asOf: date(hour: 7), given: [], calendar: calendar))
    }

    func testThePassedSlotIsDueWhenNothingHasBeenFetched() {
        let due = budget.dueSlot(asOf: date(hour: 9), given: [], calendar: calendar)

        XCTAssertEqual(due, date(hour: 8))
    }

    /// A slot already served is not due again, however many times the app is opened.
    func testASlotAlreadyServedIsNotDueAgain() {
        let issues = [date(hour: 8, minute: 5)]

        XCTAssertNil(budget.dueSlot(asOf: date(hour: 11), given: issues, calendar: calendar))
    }

    /// A phone asleep all morning makes **one** request on waking, not three catching up. The
    /// forecast is a curve, not a stream: the newest issue contains everything the missed ones
    /// would have.
    func testAPhoneAsleepAllMorningMakesOneRequestNotThree() {
        let due = budget.dueSlot(asOf: date(hour: 17), given: [], calendar: calendar)

        XCTAssertEqual(due, date(hour: 16))
    }

    /// Acceptance criterion 1, in its cheapest form: fifty activations across a day cannot
    /// exceed four requests, because each one is answered against the rows the previous ones
    /// wrote.
    func testFiftyActivationsInADaySpendAtMostFourRequests() {
        var issues: [Date] = []

        // Every quarter hour from 06:00 to 22:30 — 67 activations, more than the fifty asked
        // for, spread across every slot boundary.
        for step in 0..<67 {
            let now = date(hour: 6).addingTimeInterval(TimeInterval(step) * 15 * 60)
            if budget.dueSlot(asOf: now, given: issues, calendar: calendar) != nil {
                issues.append(now)
            }
        }

        XCTAssertEqual(issues.count, 4)
        XCTAssertEqual(budget.remainingRequests(on: date(hour: 23),
                                                given: issues,
                                                calendar: calendar), 0)
    }

    /// And the allowance is per local day, not a rolling window: yesterday's four do not eat
    /// into this morning.
    func testYesterdaysRequestsDoNotSpendTodaysAllowance() {
        let yesterday = (0..<4).map { date(hour: 8 + $0 * 4, dayOffset: -1) }

        XCTAssertEqual(budget.remainingRequests(on: date(hour: 9),
                                                given: yesterday,
                                                calendar: calendar), 4)
        XCTAssertEqual(budget.dueSlot(asOf: date(hour: 9),
                                      given: yesterday,
                                      calendar: calendar),
                       date(hour: 8))
    }

    // MARK: - Helpers

    /// 2026-08-19 in Europe/Kyiv, at the given wall-clock time.
    private func date(hour: Int, minute: Int = 0, dayOffset: Int = 0) -> Date {
        var components = DateComponents()
        components.year = 2026
        components.month = 8
        components.day = 19 + dayOffset
        components.hour = hour
        components.minute = minute
        // swiftlint:disable:next force_unwrapping
        return calendar.date(from: components)!
    }
}
