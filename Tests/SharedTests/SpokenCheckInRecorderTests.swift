import XCTest
@testable import Barosense

/// The rules behind the voice shortcuts (`Barosense/Intents/`).
///
/// The App Intents types themselves are adapters — they parse what was said and print what
/// happened. Everything that decides *what gets written* is here, which is why these tests
/// need no Siri, no intent runtime and no store on disk.
final class SpokenCheckInRecorderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_780_000_000)

    private func recorder(_ store: any CheckInStore,
                          window: TimeInterval = 6 * 60 * 60,
                          at instant: Date? = nil) -> SpokenCheckInRecorder {
        let clock = instant ?? now
        return SpokenCheckInRecorder(store: store,
                                     recentCheckInWindow: window,
                                     now: { clock })
    }

    // MARK: - A spoken check-in

    func testASpokenCheckInIsWrittenAtTheIntensityGiven() async throws {
        let store = InMemoryCheckInStore()

        try await recorder(store).record(intensity: CheckInIntensity(clamping: 7))

        let saved = try await store.checkIns(in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.intensity.rawValue, 7)
        XCTAssertEqual(saved.first?.timestamp, now)
    }

    func testASpokenCheckInCarriesNoHealthStamp() async throws {
        let store = InMemoryCheckInStore()

        let checkIn = try await recorder(store).record(intensity: CheckInIntensity(clamping: 3))

        // `nil` is the documented "no stamp was taken", which is what this path is — and it
        // must stay distinguishable from a stamp whose three fields came back empty.
        XCTAssertNil(checkIn.health)
    }

    // MARK: - A spoken medication

    func testAMedicationJoinsTheCheckInAlreadyLoggedInsideTheWindow() async throws {
        let earlier = now.addingTimeInterval(-2 * 60 * 60)
        let existing = CheckIn(timestamp: earlier, intensity: CheckInIntensity(clamping: 6))
        let store = InMemoryCheckInStore([existing])
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: now))

        let outcome = try await recorder(store).record(entry)

        XCTAssertEqual(outcome, .appended(checkInAt: earlier))

        // Appended to the same row, not written as a second one: the id decides, and a
        // second row here would be a second training label for one moment.
        let saved = try await store.checkIns(in: earlier.addingTimeInterval(-1)..<now)
        XCTAssertEqual(saved.count, 1)
        XCTAssertEqual(saved.first?.id, existing.id)
        XCTAssertEqual(saved.first?.intensity.rawValue, 6)
        XCTAssertEqual(saved.first?.medications.map(\.name), ["Ibuprofen"])
    }

    func testAMedicationIsAppendedRatherThanMergedWithOneOfTheSameName() async throws {
        let earlier = now.addingTimeInterval(-60 * 60)
        let first = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: earlier))
        let existing = CheckIn(timestamp: earlier,
                               intensity: CheckInIntensity(clamping: 4),
                               medications: [first])
        let store = InMemoryCheckInStore([existing])
        let second = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: now))

        _ = try await recorder(store).record(second)

        // Two of the same thing is two entries — the rule `LogModel.add(medication:)` holds,
        // and this path is not in a position to decide the user only took one.
        let saved = try await store.checkIns(in: earlier.addingTimeInterval(-1)..<now)
        XCTAssertEqual(saved.first?.medications.count, 2)
    }

    func testAMedicationAsksForACheckInWhenTheLastOneIsOutsideTheWindow() async throws {
        let stale = now.addingTimeInterval(-7 * 60 * 60)
        let store = InMemoryCheckInStore([CheckIn(timestamp: stale,
                                                  intensity: CheckInIntensity(clamping: 5))])
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: now))

        let outcome = try await recorder(store).record(entry)

        XCTAssertEqual(outcome, .needsCheckIn)

        // And nothing was written to the stale row on the way past.
        let saved = try await store.checkIns(in: stale.addingTimeInterval(-1)..<now)
        XCTAssertEqual(saved.first?.medications, [])
    }

    func testTheWindowBoundaryItselfStillCounts() async throws {
        let window: TimeInterval = 6 * 60 * 60
        let store = InMemoryCheckInStore([CheckIn(timestamp: now.addingTimeInterval(-window),
                                                  intensity: CheckInIntensity(clamping: 5))])
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: now))

        let outcome = try await recorder(store, window: window).record(entry)

        XCTAssertEqual(outcome, .appended(checkInAt: now.addingTimeInterval(-window)))
    }

    func testAMedicationAsksForACheckInWhenThereIsNoHistoryAtAll() async throws {
        let store = InMemoryCheckInStore()
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: now))

        let outcome = try await recorder(store).record(entry)

        XCTAssertEqual(outcome, .needsCheckIn)
    }

    func testTheCheckInWrittenForARejectedMedicationCarriesIt() async throws {
        let store = InMemoryCheckInStore()
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", dose: "two", takenAt: now))

        try await recorder(store).record(intensity: CheckInIntensity(clamping: 8),
                                         medications: [entry])

        let saved = try await store.checkIns(in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1))
        XCTAssertEqual(saved.first?.intensity.rawValue, 8)
        XCTAssertEqual(saved.first?.medications.map(\.dose), ["two"])
    }
}
