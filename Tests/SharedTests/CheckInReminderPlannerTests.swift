import XCTest
@testable import Barosense

/// Where the "How are you feeling?" reminder is placed, and when it is not placed at all.
final class CheckInReminderPlannerTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) throws -> Date {
        try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: day,
                                                         hour: hour, minute: minute)))
    }

    private func planner(rhythm: CheckInRhythm?) -> CheckInReminderPlanner {
        CheckInReminderPlanner(rhythm: rhythm, calendar: calendar)
    }

    private func dependableRhythm(atMinute minute: Int) -> CheckInRhythm {
        CheckInRhythm(minuteOfDay: minute, concentration: 0.95, sampleCount: 6)
    }

    // MARK: - Which time of day

    func testAFreshInstallFallsBackToTheFixedHour() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 9), lastCheckIn: nil)

        XCTAssertEqual(slots.first, try date(12, 20))
    }

    func testTheUsersOwnTimeWinsOnceItIsDependable() throws {
        let slots = planner(rhythm: dependableRhythm(atMinute: 7 * 60 + 45))
            .slots(from: try date(12, 6), lastCheckIn: nil)

        XCTAssertEqual(slots.first, try date(12, 7, 45))
    }

    /// A reading taken off check-ins scattered across the waking day names an hour the arithmetic
    /// produced and the user never uses. It must not be acted on.
    func testAScatteredRhythmIsIgnoredInFavourOfTheFallback() throws {
        let scattered = CheckInRhythm(minuteOfDay: 11 * 60, concentration: 0.1, sampleCount: 9)

        let slots = planner(rhythm: scattered).slots(from: try date(12, 6), lastCheckIn: nil)

        XCTAssertEqual(slots.first, try date(12, 20))
    }

    // MARK: - Which days

    func testAPlanCoversAWeekOfDailySlots() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 9), lastCheckIn: nil)

        XCTAssertEqual(slots.count, CheckInReminderPlanner.horizonDays)
        XCTAssertEqual(slots.first, try date(12, 20))
        XCTAssertEqual(slots.last, try date(18, 20))
    }

    /// The one thing that must not shorten the plan: opening the app after today's slot has gone.
    func testAPlanStartedAfterTodaysSlotStillCoversAWeek() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 22), lastCheckIn: nil)

        XCTAssertEqual(slots.count, CheckInReminderPlanner.horizonDays)
        XCTAssertEqual(slots.first, try date(13, 20))
    }

    func testNothingIsPlacedInThePast() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 21), lastCheckIn: nil)

        XCTAssertEqual(slots.contains(try date(12, 20)), false)
    }

    /// A trigger a few seconds out fires while the user is still holding the phone, which is the
    /// one moment a reminder to open the app is pure noise.
    func testASlotInsideTheLeadTimeIsSkipped() throws {
        let almost = try date(12, 20).addingTimeInterval(-CheckInReminderPlanner.minimumLead + 30)

        let slots = planner(rhythm: nil).slots(from: almost, lastCheckIn: nil)

        XCTAssertEqual(slots.first, try date(13, 20))
    }

    // MARK: - Already logged

    /// Reminding somebody to check in hours after they checked in is the app failing to notice
    /// that it got what it asked for.
    func testTodaysSlotDisappearsOnceTheUserHasCheckedIn() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 9),
                                               lastCheckIn: try date(12, 8, 30))

        XCTAssertEqual(slots.first, try date(13, 20))
        XCTAssertEqual(slots.count, CheckInReminderPlanner.horizonDays)
    }

    func testACheckInYesterdayLeavesTodaysSlotAlone() throws {
        let slots = planner(rhythm: nil).slots(from: try date(12, 9),
                                               lastCheckIn: try date(11, 20, 10))

        XCTAssertEqual(slots.first, try date(12, 20))
    }

    // MARK: - The kill switch

    /// Off, the feature plans nothing and the dispatcher then withdraws what is outstanding —
    /// see `NotificationDispatcherTests.testAnEmptyPlanWithdrawsWhatWasScheduled`.
    func testTheFeatureIsOnInThisBuild() {
        XCTAssertTrue(CheckInReminderPlanner.isEnabled)
    }
}
