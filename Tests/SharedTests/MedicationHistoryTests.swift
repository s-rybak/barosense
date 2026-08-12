import XCTest
@testable import Barosense

/// What the medication sheet offers back as chips.
///
/// The rule under test throughout: everything returned is something the user typed, and the
/// only ordering is when they last used it. Nothing here may invent, rank or normalise what
/// somebody takes.
final class MedicationHistoryTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Names

    func testNamesComeBackMostRecentlyTakenFirst() {
        let entries = [
            entry("Magnesium", takenAt: hoursAgo(48)),
            entry("Ibuprofen", takenAt: hoursAgo(1)),
            entry("Sumatriptan", takenAt: hoursAgo(6))
        ]

        XCTAssertEqual(MedicationHistory.names(in: entries),
                       ["Ibuprofen", "Sumatriptan", "Magnesium"])
    }

    func testARepeatedNameAppearsOnceAndKeepsItsMostRecentSpelling() {
        // Two chips for one thing is the failure this de-duplication guards against, and
        // the spelling shown has to be the one the user most recently chose to write.
        let entries = [
            entry("ibuprofen", takenAt: hoursAgo(48)),
            entry("IBUPROFEN", takenAt: hoursAgo(24)),
            entry("Ibuprofen", takenAt: hoursAgo(1))
        ]

        XCTAssertEqual(MedicationHistory.names(in: entries), ["Ibuprofen"])
    }

    func testNamesThatDifferOnlyByUkrainianLettersStayApart() {
        // Deliberately *not* diacritic-folded: `й` and `и` are different letters here, not a
        // letter and its accented form, and folding them would merge two real medications.
        let entries = [
            entry("Найз", takenAt: hoursAgo(2)),
            entry("Наиз", takenAt: hoursAgo(1))
        ]

        XCTAssertEqual(MedicationHistory.names(in: entries).count, 2)
    }

    func testTheNameListIsCappedSoTheChipRowStaysReadable() {
        let entries = (1...20).map { entry("Medication \($0)", takenAt: hoursAgo(Double($0))) }

        XCTAssertEqual(MedicationHistory.names(in: entries, limit: 3),
                       ["Medication 1", "Medication 2", "Medication 3"])
        XCTAssertTrue(MedicationHistory.names(in: entries, limit: 0).isEmpty)
    }

    func testNoHistoryOffersNothingRatherThanSomethingInvented() {
        XCTAssertTrue(MedicationHistory.names(in: []).isEmpty)
        XCTAssertTrue(MedicationHistory.doses(in: []).isEmpty)
    }

    // MARK: - Doses

    func testDosesAreNarrowedToTheChosenName() {
        // What makes a thing the user always takes the same amount of a two-tap entry.
        let entries = [
            entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(3)),
            entry("Magnesium", dose: "1 sachet", takenAt: hoursAgo(2)),
            entry("Ibuprofen", dose: "200 mg", takenAt: hoursAgo(1))
        ]

        XCTAssertEqual(MedicationHistory.doses(in: entries, for: "Ibuprofen"),
                       ["200 mg", "400 mg"])
    }

    func testTheNameIsMatchedIgnoringCaseAndSurroundingSpace() {
        let entries = [entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(1))]

        XCTAssertEqual(MedicationHistory.doses(in: entries, for: "  IBUPROFEN "), ["400 mg"])
    }

    func testAnUnknownNameFallsBackToEveryDoseRatherThanToNone() {
        // A name being typed for the first time still deserves the user's own words back;
        // an empty row would just be a dead end.
        let entries = [
            entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(2)),
            entry("Magnesium", dose: "1 sachet", takenAt: hoursAgo(1))
        ]

        XCTAssertEqual(MedicationHistory.doses(in: entries, for: "Paracetamol"),
                       ["1 sachet", "400 mg"])
        XCTAssertEqual(MedicationHistory.doses(in: entries, for: nil),
                       ["1 sachet", "400 mg"])
    }

    func testEntriesWithoutADoseContributeNoChip() {
        // No dose is a real answer, not a blank one to be filled in — it must not become an
        // empty chip the user can tap.
        let entries = [
            entry("Ibuprofen", takenAt: hoursAgo(2)),
            entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(1))
        ]

        XCTAssertEqual(MedicationHistory.doses(in: entries, for: "Ibuprofen"), ["400 mg"])
    }

    // MARK: - Summaries

    func testSummariesGroupByNameMostRecentlyTakenFirst() {
        let entries = [
            entry("Magnesium", dose: "1 sachet", takenAt: hoursAgo(48)),
            entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(6)),
            entry("Ibuprofen", dose: "200 mg", takenAt: hoursAgo(1))
        ]

        let summaries = MedicationHistory.summaries(in: entries)

        XCTAssertEqual(summaries.map(\.name), ["Ibuprofen", "Magnesium"])
        XCTAssertEqual(summaries.first?.timesTaken, 2)
        XCTAssertEqual(summaries.first?.doses, ["200 mg", "400 mg"])
        XCTAssertEqual(summaries.first?.lastTakenAt, hoursAgo(1))
    }

    func testOneSpellingIsShownAndItIsTheMostRecentOne() {
        // The screen lists one row per medication, so the same rule the chips follow: entries
        // differing only by case are one thing, and the label is what the user last typed.
        let entries = [
            entry("ibuprofen", takenAt: hoursAgo(24)),
            entry("Ibuprofen", takenAt: hoursAgo(1))
        ]

        let summaries = MedicationHistory.summaries(in: entries)

        XCTAssertEqual(summaries.map(\.name), ["Ibuprofen"])
        XCTAssertEqual(summaries.first?.timesTaken, 2)
    }

    func testASummaryCountsEveryEntryEvenWhenTheDoseIsAlwaysTheSame() {
        // `timesTaken` counts entries, not distinct doses. Two identical entries are two
        // takings, and collapsing them would under-report the user's own log.
        let entries = (1...4).map { entry("Ibuprofen", dose: "400 mg", takenAt: hoursAgo(Double($0))) }

        let summaries = MedicationHistory.summaries(in: entries)

        XCTAssertEqual(summaries.first?.timesTaken, 4)
        XCTAssertEqual(summaries.first?.doses, ["400 mg"])
    }

    func testAMedicationRecordedWithoutADoseHasNoDosesRatherThanABlankOne() {
        let summaries = MedicationHistory.summaries(in: [entry("Magnesium", takenAt: hoursAgo(1))])

        XCTAssertEqual(summaries.first?.doses, [])
        XCTAssertEqual(summaries.first?.timesTaken, 1)
    }

    func testNoEntriesSummariseToNothing() {
        XCTAssertTrue(MedicationHistory.summaries(in: []).isEmpty)
    }

    // MARK: - Summary order

    func testTheRecentOrderIsWhateverGroupingProduced() {
        let summaries = MedicationHistory.summaries(in: [
            entry("Zinc", takenAt: hoursAgo(1)),
            entry("Aspirin", takenAt: hoursAgo(48))
        ])

        XCTAssertEqual(MedicationHistory.ordered(summaries, by: .recent).map(\.name),
                       ["Zinc", "Aspirin"])
    }

    func testTheNameOrderIsAlphabeticalRegardlessOfWhenEachWasTaken() {
        let summaries = MedicationHistory.summaries(in: [
            entry("Zinc", takenAt: hoursAgo(1)),
            entry("Magnesium", takenAt: hoursAgo(24)),
            entry("Aspirin", takenAt: hoursAgo(48))
        ])

        XCTAssertEqual(MedicationHistory.ordered(summaries, by: .name).map(\.name),
                       ["Aspirin", "Magnesium", "Zinc"])
    }

    func testCyrillicNamesSortIntoTheAlphabetRatherThanAfterEveryLatinOne() {
        // The point of `localizedStandardCompare`. Comparing `String` with `<` orders by Unicode
        // scalar, which puts every Cyrillic name after every Latin one — an "alphabetical" list
        // that is not the reader's alphabet.
        let summaries = MedicationHistory.summaries(in: [
            entry("Ібупрофен", takenAt: hoursAgo(1)),
            entry("Аспірин", takenAt: hoursAgo(2)),
            entry("Магній", takenAt: hoursAgo(3))
        ])

        XCTAssertEqual(MedicationHistory.ordered(summaries, by: .name).map(\.name),
                       ["Аспірин", "Ібупрофен", "Магній"])
    }

    func testAlphabeticalOrderIgnoresCase() {
        // Two different medications, so grouping does not merge them; only the sort is at stake.
        let summaries = MedicationHistory.summaries(in: [
            entry("zinc", takenAt: hoursAgo(1)),
            entry("Aspirin", takenAt: hoursAgo(2))
        ])

        XCTAssertEqual(MedicationHistory.ordered(summaries, by: .name).map(\.name),
                       ["Aspirin", "zinc"])
    }

    func testOrderingIsATotalFunctionOfTheInputOrder() {
        // Names a locale can collate as equal must not swap between two calls: the list would
        // reshuffle under the user on an unrelated redraw.
        let summaries = MedicationHistory.summaries(in: [
            entry("Vitamin D", takenAt: hoursAgo(1)),
            entry("vitamin  d", takenAt: hoursAgo(2)),
            entry("Aspirin", takenAt: hoursAgo(3))
        ])

        let first = MedicationHistory.ordered(summaries, by: .name).map(\.name)
        XCTAssertEqual(first, MedicationHistory.ordered(summaries, by: .name).map(\.name))
        XCTAssertEqual(first.first, "Aspirin")
    }

    func testOrderingNothingIsNotAnError() {
        XCTAssertTrue(MedicationHistory.ordered([], by: .name).isEmpty)
        XCTAssertTrue(MedicationHistory.ordered([], by: .recent).isEmpty)
    }

    // MARK: - Ordering

    func testEntriesTakenAtTheSameMomentComeBackInAStableOrder() {
        // These feed a chip row the user builds muscle memory on. `Array.sorted` is not
        // documented as stable, so ties are broken by name rather than left to the sort.
        let entries = [
            entry("Sumatriptan", takenAt: referenceDate),
            entry("Ibuprofen", takenAt: referenceDate),
            entry("Magnesium", takenAt: referenceDate)
        ]

        let expected = ["Ibuprofen", "Magnesium", "Sumatriptan"]
        XCTAssertEqual(MedicationHistory.names(in: entries), expected)
        XCTAssertEqual(MedicationHistory.names(in: entries.reversed()), expected)
    }

    // MARK: - Helpers

    private func hoursAgo(_ hours: Double) -> Date {
        referenceDate.addingTimeInterval(-hours * 3600)
    }

    /// Force-unwrapped deliberately: `Tests/.swiftlint.yml` allows it, and a name that is
    /// blank in a fixture is a broken test rather than a case worth handling.
    private func entry(_ name: String, dose: String? = nil, takenAt: Date) -> MedicationEntry {
        MedicationEntry(name: name, dose: dose, takenAt: takenAt)!
    }
}
