import XCTest
@testable import Barosense

/// The daily cap, and what does and does not spend against it.
final class NotificationBudgetTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                                         hour: hour, minute: minute)))
    }

    private func record(at date: Date, state: NotificationDeliveryState) -> NotificationRecord {
        NotificationRecord(kind: .checkInReminder,
                           language: .english,
                           scheduledFor: date,
                           state: state,
                           createdAt: date)
    }

    // MARK: - The number

    func testTheShippedLimitIsThreeADay() {
        XCTAssertEqual(NotificationBudget.dailySendLimit, 3)
        XCTAssertEqual(NotificationBudget().dailySendLimit, 3)
    }

    func testAnEmptyDayHasItsWholeAllowance() throws {
        let budget = NotificationBudget()

        XCTAssertEqual(budget.remainingSends(on: try date(12, 9), given: [], calendar: calendar), 3)
    }

    func testEachScheduledNotificationSpendsOne() throws {
        let budget = NotificationBudget()
        let spent = [record(at: try date(12, 9), state: .scheduled),
                     record(at: try date(12, 13), state: .delivered)]

        XCTAssertEqual(budget.remainingSends(on: try date(12, 20), given: spent, calendar: calendar), 1)
    }

    func testAFourthIsRefused() throws {
        let budget = NotificationBudget()
        let spent = try [date(12, 9), date(12, 13), date(12, 18)]
            .map { record(at: $0, state: .scheduled) }

        XCTAssertFalse(budget.admitsAnotherSend(on: try date(12, 20),
                                                given: spent,
                                                calendar: calendar))
    }

    /// The cap has to bite from the moment a row is written, not from the moment it fires:
    /// a whole week is planned in one pass, and a limit that only counted what had already
    /// arrived would let a day be filled entirely in advance.
    func testAScheduledNotificationCountsBeforeItFires() throws {
        let budget = NotificationBudget()
        let future = try [date(20, 9), date(20, 13), date(20, 18)]
            .map { record(at: $0, state: .scheduled) }

        XCTAssertEqual(budget.remainingSends(on: try date(20, 8), given: future, calendar: calendar), 0)
    }

    // MARK: - What does not count

    func testSuppressedAndCancelledRowsSpendNothing() throws {
        let budget = NotificationBudget()
        let spent = [record(at: try date(12, 9), state: .suppressed),
                     record(at: try date(12, 13), state: .cancelled)]

        XCTAssertEqual(budget.remainingSends(on: try date(12, 20), given: spent, calendar: calendar), 3)
    }

    // MARK: - The window

    /// A fresh allowance at local midnight, not a rolling twenty-four hours. Three notifications
    /// last night must not make this morning silent.
    func testYesterdaysSendsDoNotSpendTodays() throws {
        let budget = NotificationBudget()
        let yesterday = try [date(11, 9), date(11, 13), date(11, 22)]
            .map { record(at: $0, state: .delivered) }

        XCTAssertEqual(budget.remainingSends(on: try date(12, 8),
                                             given: yesterday,
                                             calendar: calendar), 3)
    }

    func testTheDayWindowIsTheLocalDay() throws {
        let window = NotificationBudget().day(containing: try date(12, 15), calendar: calendar)

        XCTAssertEqual(window.lowerBound, try date(12, 0))
        XCTAssertEqual(window.upperBound, try date(13, 0))
    }

    /// A caller that hands over a wider window than one day must not get a smaller answer than
    /// the truth — the filter is inside, not the caller's responsibility.
    func testRecordsOutsideTheDayAreIgnored() throws {
        let budget = NotificationBudget()
        let mixed = [record(at: try date(11, 9), state: .delivered),
                     record(at: try date(12, 9), state: .delivered),
                     record(at: try date(13, 9), state: .scheduled)]

        XCTAssertEqual(budget.remainingSends(on: try date(12, 20), given: mixed, calendar: calendar), 2)
    }

    /// Possible only if the cap were lowered in an update while rows were in flight. It has to
    /// report zero rather than a negative every caller would have to remember to clamp.
    func testAnOverspentDayReportsZeroRatherThanANegative() throws {
        let budget = NotificationBudget(dailySendLimit: 1)
        let spent = try [date(12, 9), date(12, 13), date(12, 18)]
            .map { record(at: $0, state: .delivered) }

        XCTAssertEqual(budget.remainingSends(on: try date(12, 20), given: spent, calendar: calendar), 0)
    }

    // MARK: - What the Settings row reports

    func testTheSpentCountIsWhatTheRemainingCountIsTakenFrom() throws {
        let budget = NotificationBudget()
        let spent = [record(at: try date(12, 9), state: .scheduled),
                     record(at: try date(12, 13), state: .delivered)]

        XCTAssertEqual(budget.spentSends(on: try date(12, 20), given: spent, calendar: calendar), 2)
    }

    func testTheSpentCountIgnoresWhatNeverReachedAnyone() throws {
        let budget = NotificationBudget()
        let mixed = [record(at: try date(12, 9), state: .delivered),
                     record(at: try date(12, 13), state: .suppressed),
                     record(at: try date(12, 18), state: .cancelled)]

        XCTAssertEqual(budget.spentSends(on: try date(12, 20), given: mixed, calendar: calendar), 1)
    }

    func testTheSpentCountIsTakenOverTheDayAlone() throws {
        let budget = NotificationBudget()
        let mixed = [record(at: try date(11, 22), state: .delivered),
                     record(at: try date(12, 9), state: .delivered),
                     record(at: try date(13, 1), state: .scheduled)]

        XCTAssertEqual(budget.spentSends(on: try date(12, 20), given: mixed, calendar: calendar), 1)
    }

    /// The difference from `remainingSends`, which clamps. This number is on screen to be
    /// checked against the promise, so on a day that somehow holds more rows than the cap it has
    /// to be able to say so rather than quietly report the cap back.
    func testTheSpentCountIsNotClampedToTheLimit() throws {
        let budget = NotificationBudget(dailySendLimit: 1)
        let spent = try [date(12, 9), date(12, 13), date(12, 18)]
            .map { record(at: $0, state: .delivered) }

        XCTAssertEqual(budget.spentSends(on: try date(12, 20), given: spent, calendar: calendar), 3)
    }
}
