import XCTest
@testable import Barosense

/// What goes into a shareable report, given what the stores hold.
///
/// The document is the one surface another person reads, so what it says has to be checkable
/// without generating a file and looking at it. Everything here runs on values.
///
/// Every test pins its own `Calendar` — the window's boundaries are day boundaries, and a
/// builder tested under the machine's own time zone passes in Kyiv and fails in Los Angeles.
final class ReportBuilderTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        calendar.locale = Locale(identifier: "uk_UA")
        calendar.firstWeekday = 2
        return calendar
    }()

    private let headache = WellbeingTag(id: .seeded("headache"), // barosense:copy-allow frozen slug
                                        name: "Headache") // barosense:copy-allow default tag
    private let fatigue = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

    private var vocabulary: [WellbeingTag.ID: WellbeingTag] {
        [headache.id: headache, fatigue.id: fatigue]
    }

    // MARK: - Window

    func testTheWindowEndsWithTodayRatherThanWithTheMomentItWasAsked() {
        // A window running from "now minus three months" would cut this morning's check-in out
        // of a report generated this afternoon, while the header still names today.
        let window = ReportPeriod.threeMonths.window(endingOn: date(2026, 8, 14, hour: 15),
                                                     calendar: calendar)

        XCTAssertEqual(window.lowerBound, date(2026, 5, 14, hour: 0))
        XCTAssertEqual(window.upperBound, date(2026, 8, 15, hour: 0))
        XCTAssertTrue(window.contains(date(2026, 8, 14, hour: 8)))
        XCTAssertTrue(window.contains(date(2026, 8, 14, hour: 23)))
    }

    func testTheWindowIsHalfOpenAtMidnight() {
        let window = ReportPeriod.oneMonth.window(endingOn: date(2026, 8, 14, hour: 12),
                                                  calendar: calendar)

        XCTAssertFalse(window.contains(window.upperBound))
        XCTAssertTrue(window.contains(window.upperBound.addingTimeInterval(-1)))
    }

    func testEveryPeriodSpansItsOwnNumberOfMonths() {
        XCTAssertEqual(ReportPeriod.allCases.map(\.months), [1, 3, 6, 12])
    }

    // MARK: - Totals

    func testDaysWithEntriesCountsDaysAndNotCheckIns() {
        // Five entries on one day and five across five days are different periods, and the
        // check-in count alone cannot tell them apart.
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 3),
            checkIn(2026, 8, 10, hour: 14, intensity: 6),
            checkIn(2026, 8, 10, hour: 21, intensity: 4),
            checkIn(2026, 8, 12, hour: 9, intensity: 5)
        ])

        XCTAssertEqual(report.totals.checkInCount, 4)
        XCTAssertEqual(report.totals.daysWithEntries, 2)
    }

    func testCheckInsOutsideTheWindowAreNotCounted() {
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 3),
            checkIn(2026, 1, 4, hour: 9, intensity: 9)
        ])

        XCTAssertEqual(report.totals.checkInCount, 1)
    }

    func testTheSameThingTakenTwiceCountsTwice() {
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 6, doses: 2),
            checkIn(2026, 8, 11, hour: 9, intensity: 4, doses: 1)
        ])

        XCTAssertEqual(report.totals.medicationEntryCount, 3)
        XCTAssertEqual(report.medications.first?.timesTaken, 3)
    }

    // MARK: - Intensity

    func testTheIntensityDigestRestatesWhatTheUserWrote() {
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 2),
            checkIn(2026, 8, 11, hour: 9, intensity: 8),
            checkIn(2026, 8, 12, hour: 9, intensity: 5)
        ])

        XCTAssertEqual(report.intensity?.mean ?? 0, 5, accuracy: 0.0001)
        XCTAssertEqual(report.intensity?.lowest.rawValue, 2)
        XCTAssertEqual(report.intensity?.peak.rawValue, 8)
    }

    func testAnEmptyWindowHasNoIntensityRatherThanAZero() {
        // 0 is off the bottom of a 1–10 scale, and a document someone else reads must not
        // print a value the scale cannot hold.
        XCTAssertNil(make(checkIns: []).intensity)
    }

    // MARK: - Trace

    func testTheTraceHasOnePointPerDayIncludingDaysWithNothingInThem() {
        // A chart built only from occupied days draws a straight segment across a fortnight of
        // silence and claims coverage the log does not have.
        let report = make(checkIns: [checkIn(2026, 8, 10, hour: 9, intensity: 4)],
                          pressure: [sample(2026, 8, 10, hour: 9, hPa: 1011)])

        XCTAssertEqual(report.trace.count, 32)

        let tenth = report.trace.first { calendar.isDate($0.day, inSameDayAs: date(2026, 8, 10)) }
        XCTAssertEqual(tenth?.meanPressureHPa, 1011)
        XCTAssertEqual(tenth?.peakIntensity?.rawValue, 4)

        let eleventh = report.trace.first { calendar.isDate($0.day, inSameDayAs: date(2026, 8, 11)) }
        XCTAssertNil(eleventh?.meanPressureHPa)
        XCTAssertNil(eleventh?.peakIntensity)
    }

    func testADayAveragesItsPressureAndTakesThePeakOfItsCheckIns() {
        // Peak rather than mean, for the reason `HistoryDay.peakIntensity` gives: averaging
        // hides the day the reader opened the document to find.
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 2),
            checkIn(2026, 8, 10, hour: 18, intensity: 9)
        ], pressure: [
            sample(2026, 8, 10, hour: 9, hPa: 1010),
            sample(2026, 8, 10, hour: 18, hPa: 1004)
        ])

        let day = report.trace.first { calendar.isDate($0.day, inSameDayAs: date(2026, 8, 10)) }
        XCTAssertEqual(day?.meanPressureHPa ?? 0, 1007, accuracy: 0.0001)
        XCTAssertEqual(day?.peakIntensity?.rawValue, 9)
    }

    // MARK: - Tags

    func testTagsAreRankedByUseAndCarryTheirIdentity() {
        // Identity as well as name: a seeded tag the user never renamed is app copy and has to
        // be looked up in the reader's language, which the name alone cannot decide.
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 4, tags: [headache.id]),
            checkIn(2026, 8, 11, hour: 9, intensity: 4, tags: [headache.id, fatigue.id]),
            checkIn(2026, 8, 12, hour: 9, intensity: 4, tags: [headache.id])
        ])

        XCTAssertEqual(report.tags.map(\.count), [3, 1])
        XCTAssertEqual(report.tags.first?.tag.id, headache.id)
        XCTAssertEqual(report.tags.first?.tag.name, headache.name)
    }

    func testATagTheVocabularyCannotNameIsLeftOutRatherThanPrintedBlank() {
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 4, tags: [.user(UUID()), headache.id])
        ])

        XCTAssertEqual(report.tags.count, 1)
        XCTAssertEqual(report.entries.first?.tags.count, 1)
        // The check-in itself still counts — only the label it cannot resolve is dropped.
        XCTAssertEqual(report.totals.checkInCount, 1)
    }

    // MARK: - Entries

    func testTheLogIsNewestFirst() {
        let report = make(checkIns: [
            checkIn(2026, 8, 10, hour: 9, intensity: 3),
            checkIn(2026, 8, 12, hour: 9, intensity: 7)
        ])

        XCTAssertEqual(report.entries.map(\.intensity.rawValue), [7, 3])
    }

    func testALongNoteIsCutAndSaysSo() {
        // A PDF page cannot scroll, so an unbounded note would be taller than the page it has
        // to fit on. The document reports the cut rather than ending mid-word.
        let long = String(repeating: "я", count: ReportEntry.noteCharacterLimit + 40)
        let report = make(checkIns: [checkIn(2026, 8, 10, hour: 9, intensity: 5, note: long)])

        XCTAssertEqual(report.entries.first?.note?.count, ReportEntry.noteCharacterLimit)
        XCTAssertEqual(report.entries.first?.isNoteTruncated, true)
    }

    func testAShortNoteIsKeptWholeAndABlankOneBecomesNil() {
        let kept = make(checkIns: [checkIn(2026, 8, 10, hour: 9, intensity: 5, note: "боліла голова")])
        XCTAssertEqual(kept.entries.first?.note, "боліла голова")
        XCTAssertEqual(kept.entries.first?.isNoteTruncated, false)

        let blank = make(checkIns: [checkIn(2026, 8, 10, hour: 9, intensity: 5, note: "   ")])
        XCTAssertNil(blank.entries.first?.note)
    }

    // MARK: - Sources

    func testEverySourceIsListedIncludingTheEmptyOnes() {
        // A period the app was not recording in and a period the user felt fine in look
        // identical on the chart. The block exists to tell them apart, so a source with
        // nothing in it has to appear.
        let report = make(checkIns: [checkIn(2026, 8, 10, hour: 9, intensity: 5)])

        XCTAssertEqual(report.sources.map(\.kind), ReportSource.Kind.allCases)
        XCTAssertEqual(report.sources.first { $0.kind == .checkIns }?.isPresent, true)
        XCTAssertEqual(report.sources.first { $0.kind == .barometer }?.isPresent, false)
        XCTAssertEqual(report.sources.first { $0.kind == .appleHealth }?.rowCount, 0)
    }

    // MARK: - Profile

    func testAProfileWithNothingInItIsEmptyRatherThanThreeBlankRows() {
        XCTAssertTrue(make(checkIns: []).profile.isEmpty)
        XCTAssertTrue(ReportProfile(displayName: "   ").isEmpty)
        XCTAssertFalse(ReportProfile(ageYears: 34).isEmpty)
    }

    // MARK: - Helpers

    /// A report over August 2026, generated on the 14th.
    private func make(checkIns: [CheckIn],
                      pressure: [PressureSample] = [],
                      healthReadingCount: Int = 0,
                      profile: UserProfile? = nil) -> WellbeingReport {
        let generatedAt = date(2026, 8, 14, hour: 15)
        return ReportBuilder.make(period: .oneMonth,
                                  window: ReportPeriod.oneMonth.window(endingOn: generatedAt,
                                                                       calendar: calendar),
                                  generatedAt: generatedAt,
                                  from: ReportInput(profile: profile,
                                                    checkIns: checkIns,
                                                    pressureSamples: pressure,
                                                    healthReadingCount: healthReadingCount,
                                                    tagsByID: vocabulary),
                                  calendar: calendar)
    }

    private func checkIn(_ year: Int, _ month: Int, _ day: Int,
                         hour: Int,
                         intensity: Int,
                         tags: Set<WellbeingTag.ID> = [],
                         doses: Int = 0,
                         note: String? = nil) -> CheckIn {
        let timestamp = date(year, month, day, hour: hour)
        let medications = (0..<doses).compactMap {
            MedicationEntry(name: "Ібупрофен",
                            dose: "400 мг",
                            takenAt: timestamp.addingTimeInterval(Double($0) * 3600))
        }

        return CheckIn(timestamp: timestamp,
                       intensity: CheckInIntensity(clamping: intensity),
                       tagIDs: tags,
                       medications: medications,
                       note: note)
    }

    private func sample(_ year: Int, _ month: Int, _ day: Int,
                        hour: Int,
                        hPa: Double) -> PressureSample {
        PressureSample(timestamp: date(year, month, day, hour: hour),
                       pressure: Pressure(hectopascals: hPa))
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
