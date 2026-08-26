import XCTest
@testable import Barosense

/// Dismissing a medication chip stops it being offered — and removes nothing from the log.
///
/// That second half is the point of the feature and is what most of these assert: the chips are
/// `MedicationHistory` reading the user's own check-ins back, so a removal that reached the
/// entries would be deleting a record to tidy a row. See `MedicationChipStore`.
final class MedicationChipPreferencesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func entry(_ name: String, _ dose: String?, hoursAgo: Double) -> MedicationEntry? {
        MedicationEntry(name: name, dose: dose, takenAt: now.addingTimeInterval(-hoursAgo * 3600))
    }

    private var history: [MedicationEntry] {
        [
            entry("Ібупрофен", "400 мг", hoursAgo: 1),
            entry("Суматриптан", "50 мг", hoursAgo: 24),
            entry("Ібупрофен", "1 таблетка", hoursAgo: 48)
        ].compactMap { $0 }
    }

    // MARK: - Filtering

    func testHiddenNameIsNotOffered() {
        let offered = MedicationHistory.names(in: history,
                                              hiding: [MedicationHistory.key("Ібупрофен")])

        XCTAssertEqual(offered, ["Суматриптан"])
    }

    func testHidingIsCaseInsensitive() {
        // The user dismissed the chip when it read "Ібупрофен"; a later entry spelled
        // "ібупрофен" is the same medication and must stay dismissed.
        let offered = MedicationHistory.names(in: history,
                                              hiding: [MedicationHistory.key("  ІБУПРОФЕН ")])

        XCTAssertEqual(offered, ["Суматриптан"])
    }

    func testHiddenDoseIsNotOffered() {
        let offered = MedicationHistory.doses(in: history,
                                              for: "Ібупрофен",
                                              hiding: [MedicationHistory.key("400 мг")])

        XCTAssertEqual(offered, ["1 таблетка"])
    }

    /// The limit counts what is shown. Filtering after the cut would return fewer chips than
    /// asked for every time something was hidden.
    func testLimitCountsVisibleChips() {
        let entries = (1...10).compactMap { entry("Med \($0)", nil, hoursAgo: Double($0)) }

        let offered = MedicationHistory.names(in: entries,
                                              hiding: [MedicationHistory.key("Med 1")],
                                              limit: 3)

        XCTAssertEqual(offered, ["Med 2", "Med 3", "Med 4"])
    }

    // MARK: - The log is untouched

    func testHidingLeavesTheSummariesAlone() {
        let store = InMemoryMedicationChipStore()
        store.hideName("Ібупрофен")

        // What the "My medications" screen and the report read. It takes no hidden set at all,
        // which is the guarantee: there is no way for a dismissed chip to reach it.
        let summaries = MedicationHistory.summaries(in: history)

        XCTAssertEqual(summaries.map(\.name).sorted(), ["Ібупрофен", "Суматриптан"])
        XCTAssertEqual(summaries.first { $0.name == "Ібупрофен" }?.timesTaken, 2)
    }

    // MARK: - Store

    func testHidingIsObservedByTheNextRead() {
        let store = InMemoryMedicationChipStore()
        XCTAssertTrue(store.hiddenNames().isEmpty)

        store.hideName("Ібупрофен")

        XCTAssertEqual(store.hiddenNames(), [MedicationHistory.key("Ібупрофен")])
    }

    func testDosesAreHiddenPerMedication() {
        let store = InMemoryMedicationChipStore()
        store.hideDose("400 мг", for: "Ібупрофен")

        XCTAssertEqual(store.hiddenDoses(for: "Ібупрофен"), [MedicationHistory.key("400 мг")])
        // The same amount recorded for something else is a different chip and stays on offer.
        XCTAssertTrue(store.hiddenDoses(for: "Суматриптан").isEmpty)
    }

    /// The row drawn before a medication is chosen has its own bucket, not the union of the
    /// per-medication ones.
    func testUnfilteredDoseBucketIsSeparate() {
        let store = InMemoryMedicationChipStore()
        store.hideDose("50 мг", for: nil)

        XCTAssertEqual(store.hiddenDoses(for: nil), [MedicationHistory.key("50 мг")])
        XCTAssertTrue(store.hiddenDoses(for: "Суматриптан").isEmpty)
    }

    func testBlankInputIsNotStored() {
        let store = InMemoryMedicationChipStore()
        store.hideName("   ")
        store.hideDose("", for: "Ібупрофен")

        XCTAssertTrue(store.hiddenNames().isEmpty)
        XCTAssertTrue(store.hiddenDoses(for: "Ібупрофен").isEmpty)
    }

    func testResetOffersEverythingAgain() {
        let store = InMemoryMedicationChipStore()
        store.hideName("Ібупрофен")
        store.hideDose("400 мг", for: "Ібупрофен")

        store.reset()

        XCTAssertTrue(store.hiddenNames().isEmpty)
        XCTAssertTrue(store.hiddenDoses(for: "Ібупрофен").isEmpty)
    }

    /// The `UserDefaults` implementation round-trips through a property list, where a `Set` has
    /// no representation — the array cast is the thing that would break silently.
    func testUserDefaultsStoreRoundTrips() throws {
        let suite = try XCTUnwrap(UserDefaults(suiteName: "MedicationChipPreferencesTests"))
        defer { suite.removePersistentDomain(forName: "MedicationChipPreferencesTests") }

        let store = UserDefaultsMedicationChipStore(defaults: suite)
        store.hideName("Ібупрофен")
        store.hideDose("400 мг", for: "Ібупрофен")

        let reopened = UserDefaultsMedicationChipStore(defaults: suite)

        XCTAssertEqual(reopened.hiddenNames(), [MedicationHistory.key("Ібупрофен")])
        XCTAssertEqual(reopened.hiddenDoses(for: "Ібупрофен"),
                       [MedicationHistory.key("400 мг")])
    }
}
