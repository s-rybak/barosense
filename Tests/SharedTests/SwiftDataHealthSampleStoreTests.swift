import XCTest
@testable import Barosense

/// Same contract as `InMemoryHealthSampleStoreTests`, exercised on the durable store so a
/// SwiftData regression cannot silently diverge from what the feature pipeline depends on.
final class SwiftDataHealthSampleStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func date(hoursFromReference hours: Double) -> Date {
        referenceDate.addingTimeInterval(hours * 3600)
    }

    private var historyWindow: Range<Date> {
        date(hoursFromReference: -100)..<date(hoursFromReference: 24)
    }

    private func heartRate(hours: Double, bpm: Double = 60, id: UUID = UUID()) -> HealthSample {
        let instant = date(hoursFromReference: hours)
        return HealthSample(id: id, start: instant, end: instant, value: .restingHeartRateBPM(bpm))
    }

    private func makeStore() throws -> any HealthSampleStore {
        try SwiftDataHealthSampleStore.makeInMemory()
    }

    func testSavedSamplesReadBackAscendingByEnd() async throws {
        let store = try makeStore()

        try await store.save([heartRate(hours: 3, bpm: 58),
                              heartRate(hours: 1, bpm: 61),
                              heartRate(hours: 2, bpm: 59)])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.map(\.value), [.restingHeartRateBPM(61),
                                           .restingHeartRateBPM(59),
                                           .restingHeartRateBPM(58)])
    }

    func testRereadingTheSameSampleReplacesRatherThanDuplicates() async throws {
        let store = try makeStore()
        let id = UUID()

        try await store.save([heartRate(hours: 1, bpm: 60, id: id)])
        try await store.save([heartRate(hours: 1, bpm: 62, id: id)])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.value, .restingHeartRateBPM(62))
    }

    func testDuplicateIdentifiersWithinOneBatchKeepTheLastValue() async throws {
        let store = try makeStore()
        let id = UUID()

        try await store.save([heartRate(hours: 1, bpm: 60, id: id),
                              heartRate(hours: 1, bpm: 63, id: id)])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.value, .restingHeartRateBPM(63))
    }

    func testAsleepRoundTripsWithoutAQuantity() async throws {
        let store = try makeStore()
        let night = HealthSample(id: UUID(),
                                 start: date(hoursFromReference: -8),
                                 end: date(hoursFromReference: -1),
                                 value: .asleep)

        try await store.save([night])

        let read = try await store.samples(of: .asleep, in: historyWindow)
        XCTAssertEqual(read, [night])
    }

    func testRetentionDropsOlderSamplesAndReportsTheCount() async throws {
        let store = try makeStore()
        try await store.save([heartRate(hours: -50), heartRate(hours: -40), heartRate(hours: 1)])

        let deleted = try await store.deleteSamples(before: date(hoursFromReference: -24))

        XCTAssertEqual(deleted, 2)
        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testSavingAnEmptyBatchChangesNothing() async throws {
        let store = try makeStore()
        try await store.save([heartRate(hours: 1)])
        try await store.save([])

        let read = try await store.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(read.count, 1)
    }

    func testHistorySurvivesAcrossStoreInstancesOnTheSameContainer() async throws {
        // Two actors over one in-memory container still share the store — this is the
        // stand-in for "relaunch reads what the previous launch wrote".
        let container = try SwiftDataHealthSampleStore.makeInMemoryContainer()
        let first = SwiftDataHealthSampleStore(modelContainer: container)
        let sample = heartRate(hours: 1, bpm: 64)
        try await first.save([sample])

        let second = SwiftDataHealthSampleStore(modelContainer: container)
        let reread = try await second.samples(of: .restingHeartRate, in: historyWindow)
        XCTAssertEqual(reread.map(\.id), [sample.id])
        XCTAssertEqual(reread.first?.value, .restingHeartRateBPM(64))
    }
}
