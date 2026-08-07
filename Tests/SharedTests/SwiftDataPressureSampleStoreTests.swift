import XCTest
@testable import Barosense

/// Same contract as `InMemoryPressureSampleStoreTests`, exercised on the durable store so a
/// SwiftData regression cannot silently diverge from what the chart and the model read.
final class SwiftDataPressureSampleStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursFromReference hours: Double) -> Date {
        referenceDate.addingTimeInterval(hours * 3600)
    }

    private var historyWindow: Range<Date> {
        date(hoursFromReference: -100)..<date(hoursFromReference: 100)
    }

    private func sample(hours: Double, hPa: Double = 1013, id: UUID = UUID()) -> PressureSample {
        PressureSample(id: id, timestamp: date(hoursFromReference: hours), pressure: Pressure(hectopascals: hPa))
    }

    private func makeStore() throws -> any PressureSampleStore {
        try SwiftDataPressureSampleStore.makeInMemory()
    }

    func testSavedSamplesReadBackAscendingByTimestamp() async throws {
        let store = try makeStore()

        try await store.save([sample(hours: 3, hPa: 1010),
                              sample(hours: 1, hPa: 1014),
                              sample(hours: 2, hPa: 1012)])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.map(\.pressure.hectopascals), [1014, 1012, 1010])
    }

    /// The uplink resends an overlapping window on every hand-off. Without this, an hour of
    /// history would multiply into a row per delivery.
    func testResendingTheSameSampleReplacesRatherThanDuplicates() async throws {
        let store = try makeStore()
        let id = UUID()

        try await store.save([sample(hours: 1, hPa: 1013, id: id)])
        try await store.save([sample(hours: 1, hPa: 1013, id: id)])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testDuplicateIdentifiersWithinOneBatchKeepTheLastValue() async throws {
        let store = try makeStore()
        let id = UUID()

        try await store.save([sample(hours: 1, hPa: 1013, id: id),
                              sample(hours: 1, hPa: 1016, id: id)])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.pressure.hectopascals, 1016)
    }

    func testWindowIsHalfOpen() async throws {
        let store = try makeStore()
        try await store.save([sample(hours: 0, hPa: 1010), sample(hours: 4, hPa: 1020)])

        let read = try await store.samples(in: date(hoursFromReference: 0)..<date(hoursFromReference: 4))

        XCTAssertEqual(read.map(\.pressure.hectopascals), [1010],
                       "lower bound is in, upper bound is out")
    }

    func testEmptyBatchIsANoOp() async throws {
        let store = try makeStore()
        try await store.save([])

        let read = try await store.samples(in: historyWindow)
        XCTAssertTrue(read.isEmpty)
    }

    /// The hectopascal value has to survive the round trip through disk exactly. This is the
    /// one place a stored unit could drift 10× without any code noticing.
    func testHectopascalsSurviveTheRoundTripUnchanged() async throws {
        let store = try makeStore()
        try await store.save([sample(hours: 1, hPa: 987.6)])

        let read = try await store.samples(in: historyWindow)
        XCTAssertEqual(read.first?.pressure.hectopascals ?? 0, 987.6, accuracy: 0.0001)
    }

    func testRetentionDropsOlderSamplesAndReportsHowMany() async throws {
        let store = try makeStore()
        try await store.save([sample(hours: -50), sample(hours: -40), sample(hours: 1)])

        let removed = try await store.deleteSamples(before: date(hoursFromReference: -30))
        let remaining = try await store.samples(in: historyWindow)

        XCTAssertEqual(removed, 2)
        XCTAssertEqual(remaining.count, 1)
    }

    func testRetentionWithNothingToDropRemovesNothing() async throws {
        let store = try makeStore()
        try await store.save([sample(hours: 1)])

        let removed = try await store.deleteSamples(before: date(hoursFromReference: -10))
        let remaining = try await store.samples(in: historyWindow)

        XCTAssertEqual(removed, 0)
        XCTAssertEqual(remaining.count, 1)
    }

    // MARK: - Durability

    /// The store the app actually opens must open, and rows written through one instance
    /// must be there for the next one.
    ///
    /// The regression it guards: the store used to take `ModelConfiguration`'s name-based
    /// initialiser, whose default `groupContainer: .automatic` follows the target's
    /// app-group entitlement into a directory nothing creates. The open then threw, both app
    /// targets caught it and fell back to `InMemoryPressureSampleStore`, and the barometer
    /// history restarted from empty on every launch — with nothing visible anywhere except
    /// a pressure chart that stayed blank.
    ///
    /// Both instances are separate `@ModelActor`s over the same file, which is what makes
    /// this a durability assertion rather than a cache one.
    func testThePersistentStoreOpensAndRowsSurviveANewInstance() async throws {
        // Well before any reading this app could ever have taken, so the cleanup below
        // cannot reach a row that is not this test's.
        let planted = PressureSample(timestamp: Date(timeIntervalSince1970: 100),
                                     pressure: Pressure(hectopascals: 1002.5))
        let cleanupBoundary = Date(timeIntervalSince1970: 1_000)

        let writer = try SwiftDataPressureSampleStore.makePersistent()
        try await writer.save([planted])

        let reader = try SwiftDataPressureSampleStore.makePersistent()
        let read = try await reader.samples(in: Date(timeIntervalSince1970: 0)..<cleanupBoundary)

        _ = try? await reader.deleteSamples(before: cleanupBoundary)

        XCTAssertEqual(read.map(\.id), [planted.id])
        XCTAssertEqual(read.first?.pressure.hectopascals ?? 0, 1002.5, accuracy: 0.0001)
    }
}
