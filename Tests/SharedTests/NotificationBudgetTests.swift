import XCTest
@testable import Barosense

<<<<<<< HEAD
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
=======
/// Three a day, counted off the log. The number the Settings section prints is this one, so a
/// mistake here is visible to the user as well as felt by them.
final class NotificationBudgetTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    func testAnEmptyLogHasTheWholeAllowance() {
        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: [], calendar: calendar)

        XCTAssertEqual(status.used, 0)
        XCTAssertEqual(status.limit, NotificationBudget.dailyLimit)
        XCTAssertEqual(status.remaining, NotificationBudget.dailyLimit)
        XCTAssertTrue(status.hasRoom)
    }

    /// Scheduled counts from the moment it is handed over, not from delivery. The user is
    /// going to receive it, and a limit that waited for confirmation would let a day's whole
    /// allowance be spent three times over before the first one fired.
    func testScheduledAndDeliveredNotificationsBothSpendTheAllowance() {
        let log = [notification(day: 4, hour: 8, state: .delivered),
                   notification(day: 4, hour: 20, state: .scheduled)]

        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: log, calendar: calendar)

        XCTAssertEqual(status.used, 2)
        XCTAssertEqual(status.remaining, 1)
    }

    /// The rule the whole design turns on. A notification held back by the limit must not
    /// itself consume the limit — otherwise one busy day would spend the next day's
    /// allowance, and a suppressed row would make the shortage permanent.
    func testSuppressedAndCancelledNotificationsSpendNothing() {
        let log = [notification(day: 4, hour: 8, state: .suppressed(reason: .dailyLimit)),
                   notification(day: 4, hour: 9, state: .suppressed(reason: .remindersOff)),
                   notification(day: 4, hour: 10, state: .cancelled)]

        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: log, calendar: calendar)

        XCTAssertEqual(status.used, 0)
        XCTAssertTrue(status.hasRoom)
    }

    /// A row in the queue has not reached anyone yet. Counting it would make the app refuse to
    /// send notifications it has merely thought about.
    func testAPendingNotificationSpendsNothingUntilItIsScheduled() {
        let log = [notification(day: 4, hour: 20, state: .pending)]

        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: log, calendar: calendar)

        XCTAssertEqual(status.used, 0)
    }

    func testOnlyTheDayAskedAboutIsCounted() {
        let log = [notification(day: 3, hour: 20, state: .delivered),
                   notification(day: 4, hour: 20, state: .delivered),
                   notification(day: 5, hour: 20, state: .scheduled)]

        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: log, calendar: calendar)

        XCTAssertEqual(status.used, 1)
    }

    /// The day is the user's, not UTC's. Pinned because the coordinator hands its own calendar
    /// in and the device's time zone changes when the user travels — a 23:30 notification is
    /// tomorrow's in Kyiv and today's in London.
    func testTheDayBoundaryFollowsTheCalendarsTimeZone() {
        let log = [notification(day: 4, hour: 23, minute: 30, state: .delivered)]
        let asked = date(day: 4, hour: 12)

        var eastern = calendar
        eastern.timeZone = TimeZone(secondsFromGMT: 3 * 3600) ?? .gmt

        XCTAssertEqual(NotificationBudget.status(on: asked, log: log, calendar: calendar).used, 1)
        // 02:30 the next morning over there, so it belongs to a different day's allowance.
        XCTAssertEqual(NotificationBudget.status(on: asked, log: log, calendar: eastern).used, 0)
    }

    /// A day can overrun — the ceiling was lowered, or the clock moved under rows already
    /// scheduled. "−1 left" is arithmetic, not an answer.
    func testRemainingNeverGoesNegative() {
        let log = (0..<5).map { notification(day: 4, hour: 8 + $0, state: .delivered) }

        let status = NotificationBudget.status(on: date(day: 4, hour: 12), log: log, calendar: calendar)

        XCTAssertEqual(status.used, 5)
        XCTAssertEqual(status.remaining, 0)
        XCTAssertFalse(status.hasRoom)
    }

    func testTheAllowanceRunsOutAtExactlyTheLimit() {
        let log = (0..<NotificationBudget.dailyLimit).map {
            notification(day: 4, hour: 8 + $0, state: .scheduled)
        }
        let asked = date(day: 4, hour: 12)

        XCTAssertFalse(NotificationBudget.hasRoom(on: asked, log: log, calendar: calendar))
        XCTAssertTrue(NotificationBudget.hasRoom(on: asked, log: Array(log.dropLast()), calendar: calendar))
    }

    // MARK: - Fixtures

    private func notification(day: Int,
                              hour: Int,
                              minute: Int = 0,
                              state: NotificationDeliveryState) -> AppNotification {
        let instant = date(day: day, hour: hour, minute: minute)
        return AppNotification(kind: .checkInReminder,
                               createdAt: instant,
                               scheduledFor: instant,
                               state: state)
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day,
                                           hour: hour, minute: minute)) ?? .distantPast
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
    }
}
