import XCTest
@testable import Barosense

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
            let at = try XCTUnwrap(calendar.date(bySettingHour: 21, minute: 15, second: 0, of: stamp))
            return CheckIn(timestamp: at, intensity: CheckInIntensity(clamping: 5))
        }

        let rhythm = CheckInRhythm.read(from: checkIns, calendar: calendar)

        XCTAssertEqual(rhythm?.hour, 21)
        XCTAssertEqual(rhythm?.minute, 15)
        XCTAssertEqual(rhythm?.sampleCount, 4)
    }
}
