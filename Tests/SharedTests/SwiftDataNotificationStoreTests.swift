import SwiftData
import XCTest
@testable import Barosense

/// The durable notification log against the same contract `InMemoryNotificationStore` satisfies.
///
/// On an in-memory `ModelContainer` built from the real `BarosenseModelContainer` schema, so the
/// mapping under test is the shipped one — only the file on disk is missing.
final class SwiftDataNotificationStoreTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeStore() throws -> any NotificationStore {
        SwiftDataNotificationStore(modelContainer: try BarosenseModelContainer.makeInMemory())
    }

    private func record(_ offsetHours: Double,
                        state: NotificationDeliveryState = .scheduled) -> NotificationRecord {
        let slot = referenceDate.addingTimeInterval(offsetHours * 3600)
        return NotificationRecord(kind: .checkInReminder,
                                  language: .english,
                                  scheduledFor: slot,
                                  state: state,
                                  createdAt: referenceDate)
    }

    func testARecordRoundTrips() async throws {
        let store = try makeStore()
        let written = record(6)

        try await store.save(written)

        let read = try await store.records(in: referenceDate..<referenceDate.addingTimeInterval(86_400))
        XCTAssertEqual(read, [written])
    }

    /// The log is registered on the app's own schema. A `@Model` missing from it compiles and
    /// then fails at runtime on first use, so this is the assertion that the registry was updated.
    func testTheLogIsOnTheAppSchema() {
        let names = BarosenseModelContainer.schema.entities.map(\.name)

        XCTAssertTrue(names.contains("StoredNotification"))
    }

    /// The state change is a save of the same `id`, which is what makes `moved(to:at:)` a one-call
    /// update rather than a delete and an insert.
    func testSavingTheSameIdReplacesTheRowRatherThanAddingOne() async throws {
        let store = try makeStore()
        let written = record(6)
        try await store.save(written)

        let moved = try XCTUnwrap(written.moved(to: .delivered, at: referenceDate))
        try await store.save(moved)

        let read = try await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.state, .delivered)
        XCTAssertEqual(read.first?.id, written.id)
    }

    func testTheWindowIsHalfOpen() async throws {
        let store = try makeStore()
        try await store.save(record(0))
        try await store.save(record(1))

        let read = try await store.records(in: referenceDate..<referenceDate.addingTimeInterval(3600))

        XCTAssertEqual(read.count, 1)
        XCTAssertEqual(read.first?.scheduledFor, referenceDate)
    }

    func testPendingIsScheduledRowsFromNowOnward() async throws {
        let store = try makeStore()
        let past = record(-2)
        let ahead = record(2)
        let cancelled = record(3, state: .cancelled)
        for row in [past, ahead, cancelled] {
            try await store.save(row)
        }

        let pending = try await store.pendingRecords(notBefore: referenceDate)

        XCTAssertEqual(pending, [ahead])
    }

    func testPruningRemovesOnlyRowsBeforeTheCutoff() async throws {
        let store = try makeStore()
        try await store.save(record(-48))
        try await store.save(record(4))

        let pruned = try await store.deleteNotifications(before: referenceDate)

        XCTAssertEqual(pruned, 1)
        let read = try await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertEqual(read.count, 1)
    }

    func testErasingEmptiesTheLog() async throws {
        let store = try makeStore()
        try await store.save(record(1))
        try await store.save(record(2))

        try await store.deleteAllNotifications()

        let read = try await store.records(in: Date.distantPast..<Date.distantFuture)
        XCTAssertTrue(read.isEmpty)
    }

    /// A row written by a build that knew a kind or a state this one does not is dropped on read.
    /// Coercing it into a neighbouring value is how a `.delivered` row becomes `.suppressed` and
    /// hands the day an allowance it has already spent.
    func testARowWithAnUnknownStateIsSkippedRatherThanCoerced() async throws {
        let container = try BarosenseModelContainer.makeInMemory()
        let context = ModelContext(container)
        let row = StoredNotification(record: record(1))
        row.stateRawValue = "postponed"
        context.insert(row)
        try context.save()

        let store: any NotificationStore = SwiftDataNotificationStore(modelContainer: container)
        let read = try await store.records(in: Date.distantPast..<Date.distantFuture)

        XCTAssertTrue(read.isEmpty)
    }
}
