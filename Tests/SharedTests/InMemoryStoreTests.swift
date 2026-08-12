import XCTest
@testable import Barosense

/// Exercised through `any CheckInStore`, not through the concrete actor: the contract is
/// what the feature pipeline depends on, and the durable store has to pass the same file.
final class InMemoryCheckInStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursFromReference hours: Double) -> Date {
        referenceDate.addingTimeInterval(hours * 3600)
    }

    /// Wide enough to hold every check-in these tests create.
    private var dayWindow: Range<Date> {
        referenceDate..<date(hoursFromReference: 24)
    }

    private func checkIn(hours: Double,
                         intensity: Int = 5,
                         id: UUID = UUID()) -> CheckIn {
        CheckIn(id: id,
                timestamp: date(hoursFromReference: hours),
                intensity: CheckInIntensity(clamping: intensity))
    }

    func testSavedCheckInIsReadBack() async throws {
        let store: any CheckInStore = InMemoryCheckInStore()
        let saved = checkIn(hours: 1, intensity: 8)

        try await store.save(saved)

        let read = try await store.checkIns(in: dayWindow)
        XCTAssertEqual(read, [saved])
    }

    func testResultsAreAscendingByTimestamp() async throws {
        let store: any CheckInStore = InMemoryCheckInStore()
        let late = checkIn(hours: 9)
        let early = checkIn(hours: 2)
        let middle = checkIn(hours: 5)

        try await store.save(late)
        try await store.save(early)
        try await store.save(middle)

        let read = try await store.checkIns(in: dayWindow)
        XCTAssertEqual(read.map(\.id), [early.id, middle.id, late.id])
    }

    func testRangeIsHalfOpenSoAdjacentWindowsDoNotOverlap() async throws {
        let store: any CheckInStore = InMemoryCheckInStore()
        let onLowerBound = checkIn(hours: 0)
        let onUpperBound = checkIn(hours: 6)

        try await store.save(onLowerBound)
        try await store.save(onUpperBound)

        let cutOff = date(hoursFromReference: 6)
        let firstWindow = try await store.checkIns(in: referenceDate..<cutOff)
        let secondWindow = try await store.checkIns(in: cutOff..<date(hoursFromReference: 12))

        XCTAssertEqual(firstWindow.map(\.id), [onLowerBound.id])
        XCTAssertEqual(secondWindow.map(\.id), [onUpperBound.id])
    }

    func testSavingTheSameIdTwiceReplacesRatherThanDuplicates() async throws {
        // The watch→phone transfer can deliver the same check-in more than once. Two rows
        // for one report would double-count it in training.
        let store: any CheckInStore = InMemoryCheckInStore()
        let id = UUID()

        try await store.save(checkIn(hours: 1, intensity: 8, id: id))
        try await store.save(checkIn(hours: 1, intensity: 3, id: id))

        let read = try await store.checkIns(in: dayWindow)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.intensity.rawValue, 3)
    }

    func testMostRecentCheckInIsStrictlyBeforeTheGivenInstant() async throws {
        // A feature computed at t must not read the check-in at t — that is its own label.
        let store: any CheckInStore = InMemoryCheckInStore()
        let prior = checkIn(hours: 2, intensity: 10)
        let atCutOff = checkIn(hours: 6, intensity: 1)

        try await store.save(prior)
        try await store.save(atCutOff)

        let found = try await store.mostRecentCheckIn(before: date(hoursFromReference: 6))
        XCTAssertEqual(found?.id, prior.id)
    }

    func testMostRecentCheckInIsNilOnAnEmptyHistory() async throws {
        let store: any CheckInStore = InMemoryCheckInStore()

        let found = try await store.mostRecentCheckIn(before: referenceDate)

        XCTAssertNil(found)
    }

    func testDeleteRemovesOnlyTheNamedCheckIn() async throws {
        let removed = checkIn(hours: 1)
        let kept = checkIn(hours: 2)
        let store: any CheckInStore = InMemoryCheckInStore([removed, kept])

        try await store.delete(id: removed.id)

        let read = try await store.checkIns(in: dayWindow)
        XCTAssertEqual(read.map(\.id), [kept.id])
    }

    func testDeletingAnAbsentCheckInIsNotAnError() async throws {
        let store: any CheckInStore = InMemoryCheckInStore()

        try await store.delete(id: UUID())
    }

    func testDeleteAllCheckInsLeavesNothingBehind() async throws {
        let store: any CheckInStore = InMemoryCheckInStore([checkIn(hours: 1), checkIn(hours: 2)])

        try await store.deleteAllCheckIns()

        let read = try await store.checkIns(in: dayWindow)
        XCTAssertTrue(read.isEmpty)
    }
}

final class InMemoryPressureSampleStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursFromReference hours: Double) -> Date {
        referenceDate.addingTimeInterval(hours * 3600)
    }

    /// Wide enough to hold every sample these tests create, past and future.
    private var historyWindow: Range<Date> {
        date(hoursFromReference: -100)..<date(hoursFromReference: 24)
    }

    private func sample(hours: Double, hectopascals: Double = 1013.25) -> PressureSample {
        PressureSample(timestamp: date(hoursFromReference: hours),
                       pressure: Pressure(hectopascals: hectopascals))
    }

    func testBatchSaveStoresEverySampleInAscendingOrder() async throws {
        let store: any PressureSampleStore = InMemoryPressureSampleStore()
        let batch = [sample(hours: 3, hectopascals: 1009),
                     sample(hours: 1, hectopascals: 1012),
                     sample(hours: 2, hectopascals: 1011)]

        try await store.save(batch)

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.map(\.pressure.hectopascals), [1012, 1011, 1009])
    }

    func testSavingAnEmptyBatchChangesNothing() async throws {
        let store: any PressureSampleStore = InMemoryPressureSampleStore([sample(hours: 1)])

        try await store.save([])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testStoreDoesNotFilterImplausibleReadings() async throws {
        // A kPa value handed in as hPa must reach the caller, not vanish: the store is not
        // where that gate lives, and a silent drop would hide the unit bug.
        let wrongUnit = sample(hours: 1, hectopascals: 101.325)
        XCTAssertFalse(wrongUnit.pressure.isPlausible)
        let store: any PressureSampleStore = InMemoryPressureSampleStore()

        try await store.save([wrongUnit])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testRetentionDropsOlderSamplesAndReportsTheCount() async throws {
        let store: any PressureSampleStore = InMemoryPressureSampleStore(
            [sample(hours: -50), sample(hours: -40), sample(hours: 1)])

        let deleted = try await store.deleteSamples(before: date(hoursFromReference: -24))

        XCTAssertEqual(deleted, 2)
        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testRetentionKeepsASampleExactlyOnTheCutOff() async throws {
        let store: any PressureSampleStore = InMemoryPressureSampleStore(
            [sample(hours: -24)])

        let deleted = try await store.deleteSamples(before: date(hoursFromReference: -24))

        XCTAssertEqual(deleted, 0)
    }
}
