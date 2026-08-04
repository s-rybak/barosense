import Foundation

/// Non-persistent `CheckInStore` for unit tests, SwiftUI previews, and bring-up before a
/// durable store exists. Contents are lost with the process.
///
/// An actor rather than a lock: the store is reached from the check-in UI and from
/// feature computation, and the project builds with complete strict concurrency.
actor InMemoryCheckInStore: CheckInStore {

    private var storage: [UUID: CheckIn] = [:]

    init(_ checkIns: [CheckIn] = []) {
        for checkIn in checkIns {
            storage[checkIn.id] = checkIn
        }
    }

    func save(_ checkIn: CheckIn) {
        storage[checkIn.id] = checkIn
    }

    func checkIns(in range: Range<Date>) -> [CheckIn] {
        storage.values
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    func mostRecentCheckIn(before date: Date) -> CheckIn? {
        storage.values
            .filter { $0.timestamp < date }
            .max { $0.timestamp < $1.timestamp }
    }

    func delete(id: UUID) {
        storage[id] = nil
    }
}
