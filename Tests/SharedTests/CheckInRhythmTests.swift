import XCTest
@testable import Barosense

<<<<<<< HEAD
/// The time of day the user usually logs, read off their own check-ins.
///
/// Every test pins a calendar with a fixed time zone: "time of day" is meaningless without one,
/// and a suite that passed in Kyiv and failed in Cupertino would be worse than no suite.
final class CheckInRhythmTests: XCTestCase {

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        return calendar
    }

    // MARK: - Cold start

    func testTwoCheckInsAreNotEnoughToNameATime() {
        XCTAssertNil(CheckInRhythm.read(fromMinutesOfDay: [9 * 60, 9 * 60]))
    }

    func testThreeCheckInsAreEnough() {
        let rhythm = CheckInRhythm.read(fromMinutesOfDay: [9 * 60, 9 * 60, 9 * 60])

        XCTAssertEqual(rhythm?.minuteOfDay, 9 * 60)
        XCTAssertEqual(rhythm?.sampleCount, 3)
    }

    func testNoCheckInsGiveNoReading() {
        XCTAssertNil(CheckInRhythm.read(fromMinutesOfDay: []))
    }

    // MARK: - The circular mean

    /// The reason this is not an arithmetic mean. Averaging 23:40 and 00:20 as numbers gives
    /// 12:00 — the one time of day the user is demonstrably not logging.
    func testTimesEitherSideOfMidnightAverageToMidnight() {
        let rhythm = CheckInRhythm.read(fromMinutesOfDay: [23 * 60 + 40, 20, 0])

        XCTAssertEqual(rhythm?.minuteOfDay, 0)
        XCTAssertEqual(rhythm?.concentration ?? 0, 1, accuracy: 0.01)
    }

    func testAnEveningHabitReadsAsThatEvening() {
        let rhythm = CheckInRhythm.read(fromMinutesOfDay: [20 * 60, 20 * 60 + 30, 19 * 60 + 30])

        XCTAssertEqual(rhythm?.minuteOfDay, 20 * 60)
    }

    /// Tight cluster, high concentration; spread across the waking day, low. The number is what
    /// separates a habit from a coincidence, so both ends have to be right.
    func testConcentrationFallsAsTheTimesSpreadOut() {
        let tight = CheckInRhythm.read(fromMinutesOfDay: [9 * 60, 9 * 60 + 5, 9 * 60 - 5])
        let scattered = CheckInRhythm.read(fromMinutesOfDay: [7 * 60, 13 * 60, 21 * 60])

        XCTAssertGreaterThan(tight?.concentration ?? 0, 0.99)
        XCTAssertLessThan(scattered?.concentration ?? 1, tight?.concentration ?? 0)
    }

    func testATightClusterIsDependableAndAScatteredOneIsNot() {
        let tight = CheckInRhythm.read(fromMinutesOfDay: [9 * 60, 9 * 60 + 20, 9 * 60 - 20])
        let scattered = CheckInRhythm.read(fromMinutesOfDay: [2 * 60, 10 * 60, 18 * 60])

        XCTAssertEqual(tight?.isDependable, true)
        XCTAssertEqual(scattered?.isDependable, false)
    }

    /// 06:00 and 18:00 cancel to the origin, where there is no angle to read. It must report no
    /// direction rather than invent one.
    func testAntipodalTimesReportNoDirection() {
        let rhythm = CheckInRhythm.read(fromMinutesOfDay: [6 * 60, 18 * 60, 6 * 60, 18 * 60])

        XCTAssertEqual(rhythm?.concentration ?? 1, 0, accuracy: 0.0001)
        XCTAssertEqual(rhythm?.isDependable, false)
    }

    func testTheReadingNeverLandsOutsideTheDay() {
        // Just under midnight from both sides: the angle rounds up onto 1440, which has to wrap.
        let rhythm = CheckInRhythm.read(fromMinutesOfDay: [1439, 1439, 1439])

        XCTAssertEqual(rhythm?.minuteOfDay, 1439)

        let wrapped = CheckInRhythm.read(fromMinutesOfDay: [1439, 1439, 1])
        XCTAssertEqual((wrapped?.minuteOfDay ?? -1) < CheckInRhythm.minutesPerDay, true)
        XCTAssertEqual((wrapped?.minuteOfDay ?? -1) >= 0, true)
    }

    // MARK: - From check-ins

    func testAReadingTakenFromCheckInsUsesTheirLocalTimeOfDay() throws {
        let calendar = calendar
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 10)))
        let checkIns = try (0..<4).map { offset -> CheckIn in
            let stamp = try XCTUnwrap(calendar.date(byAdding: .day, value: offset, to: day))
            let evening = try XCTUnwrap(calendar.date(bySettingHour: 21, minute: 15, second: 0,
                                                      of: stamp))
            return CheckIn(timestamp: evening, intensity: CheckInIntensity(clamping: 5))
        }

        let rhythm = CheckInRhythm.read(from: checkIns, calendar: calendar)

        XCTAssertEqual(rhythm?.hour, 21)
        XCTAssertEqual(rhythm?.minute, 15)
        XCTAssertEqual(rhythm?.sampleCount, 4)
=======
/// When the reminder should ask. The whole value of the feature is in this arithmetic: an hour
/// the user does not use makes the notification an interruption rather than a prompt.
final class CheckInRhythmTests: XCTestCase {

    /// Fixed offset rather than a named zone, so no test in this file can start failing on a
    /// daylight-saving weekend for reasons that have nothing to do with what it asserts.
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // MARK: - Reading the rhythm

    func testTheRhythmIsTheHourTheUserActuallyLogsAt() {
        let history = [checkIn(day: 1, hour: 19, minute: 30),
                       checkIn(day: 2, hour: 20),
                       checkIn(day: 3, hour: 20, minute: 30)]

        let rhythm = CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar)

        XCTAssertEqual(rhythm?.secondsFromMidnight, 20 * 3600)
        XCTAssertEqual(rhythm?.sampleCount, 3)
        XCTAssertEqual(rhythm?.isReliable, true)
    }

    /// The reason this is a circular mean and not an average. A straight arithmetic mean of
    /// 23:40 and 00:20 is **noon** — the middle of the day these two check-ins say nothing
    /// about, and the worst hour to interrupt someone who logs at midnight.
    func testTimesEitherSideOfMidnightAverageToMidnightAndNotToNoon() throws {
        let history = [checkIn(day: 1, hour: 23, minute: 40),
                       checkIn(day: 2, hour: 0),
                       checkIn(day: 2, hour: 0, minute: 20)]

        let rhythm = try XCTUnwrap(CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar))

        // Within a minute of midnight, either side of the wrap.
        let distanceFromMidnight = min(rhythm.secondsFromMidnight, 86_400 - rhythm.secondsFromMidnight)
        XCTAssertLessThan(distanceFromMidnight, 60)
        XCTAssertTrue(rhythm.isReliable)
    }

    /// Check-ins spread across the clock have a mean, and it is meaningless. The consistency
    /// gate is what keeps it from being used.
    func testScatteredTimesAreNotReliableEnoughToTimeAReminderTo() {
        let history = [checkIn(day: 1, hour: 2),
                       checkIn(day: 1, hour: 8),
                       checkIn(day: 2, hour: 13),
                       checkIn(day: 2, hour: 19)]

        let rhythm = CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar)

        XCTAssertEqual(rhythm?.isReliable, false)
        XCTAssertEqual(CheckInRhythmAnalysis.reminderSecondsFromMidnight(for: rhythm),
                       CheckInRhythmAnalysis.defaultSecondsFromMidnight)
    }

    /// The degenerate case: two times exactly twelve hours apart. Their vectors cancel, and
    /// whatever angle survives the floating-point residue points at an hour neither check-in
    /// was near. Nothing rejects it except the consistency gate, which is why the gate exists.
    func testTwoOppositeTimesAreRejectedByTheConsistencyGate() {
        let history = [checkIn(day: 1, hour: 6), checkIn(day: 1, hour: 18)]

        let rhythm = CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar)

        // Not `== false`: whether the cancelling vectors leave a floating-point residue or an
        // exact zero decides between "unreliable" and "no rhythm at all", and both are correct
        // answers to the same question. What must never happen is `true`.
        XCTAssertNotEqual(rhythm?.isReliable, true)
        XCTAssertEqual(CheckInRhythmAnalysis.reminderSecondsFromMidnight(for: rhythm),
                       CheckInRhythmAnalysis.defaultSecondsFromMidnight)
    }

    /// Cold start. Two check-ins is not a habit, and the app has to be useful on day one
    /// anyway (`CLAUDE.md`, constraint 5) — so it falls back to an hour rather than waiting.
    func testTooFewCheckInsFallBackToTheDefaultHour() {
        let history = [checkIn(day: 1, hour: 9), checkIn(day: 2, hour: 9)]

        let rhythm = CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar)

        XCTAssertEqual(rhythm?.sampleCount, 2)
        XCTAssertEqual(rhythm?.isReliable, false)
        XCTAssertEqual(CheckInRhythmAnalysis.reminderSecondsFromMidnight(for: rhythm),
                       CheckInRhythmAnalysis.defaultSecondsFromMidnight)
    }

    func testNoHistoryHasNoRhythmAtAll() {
        XCTAssertNil(CheckInRhythmAnalysis.rhythm(from: [], calendar: calendar))
        XCTAssertEqual(CheckInRhythmAnalysis.reminderSecondsFromMidnight(for: nil),
                       CheckInRhythmAnalysis.defaultSecondsFromMidnight)
    }

    /// The hour is a local reading, so the same instants describe a different habit under a
    /// different clock. Pinned because the coordinator passes the *device's* calendar in, and
    /// a rhythm computed in UTC would put the reminder three hours out for a Kyiv user.
    func testTheHourIsReadInTheCalendarsOwnTimeZone() {
        let history = [checkIn(day: 1, hour: 20),
                       checkIn(day: 2, hour: 20),
                       checkIn(day: 3, hour: 20)]

        var eastern = calendar
        eastern.timeZone = TimeZone(secondsFromGMT: 3 * 3600) ?? .gmt

        let here = CheckInRhythmAnalysis.rhythm(from: history, calendar: calendar)
        let there = CheckInRhythmAnalysis.rhythm(from: history, calendar: eastern)

        XCTAssertEqual(here?.secondsFromMidnight, 20 * 3600)
        XCTAssertEqual(there?.secondsFromMidnight, 23 * 3600)
    }

    // MARK: - The next occurrence

    func testTheNextOccurrenceIsLaterTodayWhenTheHourIsStillAhead() {
        let next = CheckInRhythmAnalysis.nextOccurrence(ofSecondsFromMidnight: 20 * 3600,
                                                        after: date(day: 4, hour: 12),
                                                        calendar: calendar)

        XCTAssertEqual(next, date(day: 4, hour: 20))
    }

    func testTheNextOccurrenceIsTomorrowWhenTodaysHourHasPassed() {
        let next = CheckInRhythmAnalysis.nextOccurrence(ofSecondsFromMidnight: 20 * 3600,
                                                        after: date(day: 4, hour: 21),
                                                        calendar: calendar)

        XCTAssertEqual(next, date(day: 5, hour: 20))
    }

    /// Strictly after, so a pass running at exactly the reminder minute plans tomorrow's
    /// rather than one that is already due and could never be handed to iOS.
    func testTheNextOccurrenceIsStrictlyAfterTheInstantAsked() {
        let next = CheckInRhythmAnalysis.nextOccurrence(ofSecondsFromMidnight: 20 * 3600,
                                                        after: date(day: 4, hour: 20),
                                                        calendar: calendar)

        XCTAssertEqual(next, date(day: 5, hour: 20))
    }

    // MARK: - Fixtures

    private func checkIn(day: Int, hour: Int, minute: Int = 0) -> CheckIn {
        CheckIn(timestamp: date(day: day, hour: hour, minute: minute),
                intensity: CheckInIntensity(clamping: 4))
    }

    private func date(day: Int, hour: Int, minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 3, day: day,
                                           hour: hour, minute: minute)) ?? .distantPast
>>>>>>> 499849d (Ask for Health and barometer access on the onboarding step that explains them)
    }
}
