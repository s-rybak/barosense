import XCTest
@testable import Barosense

/// Whose convention decides the clock — the reader's region, or the language they picked.
///
/// Two halves, and the second is the one that is easy to lose: the *displayed* time has to
/// follow the rule, and the medication sheet's own time wheel has to agree with it. The wheel
/// does not read a formatted string — it asks the locale for the template it would use for a
/// bare time and shows a period column when that template carries one — so a rule that moved
/// the row but not the template would leave the user picking "4 pm" and reading back "16:00".
final class ClockFormatTests: XCTestCase {

    /// One calendar for building the instant and for reading it back. Pinned to a zone rather
    /// than left to the machine, and used on *both* sides: a date composed in the test host's
    /// zone and printed in another is an hour out, which reads as a formatting failure.
    private static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        return calendar
    }()

    /// 26 Aug 2026, 16:45 — the afternoon is the half that tells the two clocks apart.
    private lazy var afternoon = Self.calendar
        .date(from: DateComponents(year: 2026, month: 8, day: 26, hour: 16, minute: 45))!

    private func time(in locale: Locale) -> String {
        afternoon.formatted(Date.FormatStyle(date: .omitted, time: .shortened,
                                             locale: locale,
                                             calendar: Self.calendar,
                                             timeZone: Self.calendar.timeZone))
    }

    private func applied(_ identifier: String) -> String {
        time(in: ClockFormat.applied(to: Locale(identifier: identifier)))
    }

    /// What `TimeWheel.usesPeriod` reads, asked the same way it asks.
    private func usesPeriod(_ locale: Locale) -> Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?
            .contains("a") ?? false
    }

    // MARK: - The language that gets pinned

    /// The bug as it was reported: Ukrainian copy on an American clock — "4:45 пп" for a dose
    /// taken at 16:45.
    ///
    /// Asserted on the shape rather than against the whole string. ICU separates the reading
    /// from its period marker with a narrow no-break space, and a literal carrying an invisible
    /// character is a test that fails one day with two identical-looking strings on screen.
    func testUkrainianOnAUnitedStatesRegionIsATwelveHourClockUntilTheRuleIsApplied() {
        let reading = time(in: Locale(identifier: "uk_US"))

        XCTAssertTrue(reading.hasPrefix("4:45"), reading)
        XCTAssertTrue(reading.contains("пп"), reading)
    }

    /// Ukrainian has no 12-hour form of its own, so the region does not get to impose one.
    func testUkrainianIsPinnedToTwentyFourHoursWhateverTheRegion() {
        XCTAssertEqual(applied("uk_US"), "16:45")
        XCTAssertEqual(applied("uk_UA"), "16:45")
    }

    // MARK: - The language that is left alone

    /// **The behaviour that was deliberately restored.** English writes 12-hour times, so an
    /// English reader on a United States region keeps the reading they had before `ClockFormat`
    /// existed — this app has no standing to overrule their region or their 24-Hour Time switch.
    func testEnglishOnAUnitedStatesRegionKeepsItsTwelveHourClock() {
        let reading = applied("en_US")

        XCTAssertTrue(reading.hasPrefix("4:45"), reading)
        XCTAssertTrue(reading.uppercased().contains("PM"), reading)
    }

    /// And the other half of leaving English alone: a region that is already on 24 hours stays
    /// there. A rule written per-language rather than per-locale would have put `en_GB` on an
    /// American clock, which is the same bug pointed the other way.
    func testEnglishOnAUnitedKingdomRegionKeepsItsTwentyFourHourClock() {
        XCTAssertEqual(applied("en_GB"), "16:45")
    }

    /// The device's own 24-Hour Time switch reaches the app as an explicit hour cycle on the
    /// locale. English defers to the region, so that switch has to survive the rule untouched.
    func testTheDevicesOwnTwentyFourHourSwitchSurvivesForEnglish() {
        XCTAssertEqual(applied("en_US@hours=h23"), "16:45")
    }

    // MARK: - The wheel

    /// The picker's half of the contract, both ways round. Without this Ukrainian would offer
    /// "дп"/"пп" rows for a reading the rest of the app prints as 16:45 — and English would lose
    /// the rows it needs.
    func testThePeriodColumnFollowsTheSameRuleAsTheReading() {
        XCTAssertFalse(usesPeriod(ClockFormat.applied(to: Locale(identifier: "uk_US"))))
        XCTAssertFalse(usesPeriod(ClockFormat.applied(to: Locale(identifier: "en_GB"))))
        XCTAssertTrue(usesPeriod(ClockFormat.applied(to: Locale(identifier: "en_US"))))
    }

    // MARK: - Blast radius

    /// Only the clock moves. The language decides the words and the region decides the week and
    /// the separators — a rule that quietly re-regioned the app would change far more than the
    /// hour on screen.
    func testNothingElseAboutTheLocaleMoves() {
        let original = Locale(identifier: "uk_US")
        let pinned = ClockFormat.applied(to: original)

        XCTAssertEqual(pinned.language.languageCode, original.language.languageCode)
        XCTAssertEqual(pinned.region, original.region)
        XCTAssertEqual(pinned.calendar.identifier, original.calendar.identifier)
        XCTAssertEqual(pinned.decimalSeparator, original.decimalSeparator)
        XCTAssertEqual(pinned.firstDayOfWeek, original.firstDayOfWeek)
    }

    /// A locale with no language subtag at all is handed back untouched rather than crashing or
    /// guessing. Not reachable from `LanguageController`, which always sets one — but this is a
    /// free function on `Locale` and the guard is the reason it stays free.
    func testALocaleWithNoLanguageIsReturnedUnchanged() {
        let rootLocale = Locale(identifier: "")

        XCTAssertEqual(ClockFormat.applied(to: rootLocale).identifier, rootLocale.identifier)
    }
}
