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
