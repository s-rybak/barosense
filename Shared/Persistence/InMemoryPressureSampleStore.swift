import Foundation

/// Non-persistent `PressureSampleStore` for unit tests, SwiftUI previews, and bring-up
/// before a durable store exists. Contents are lost with the process.
///
/// Filtering and sorting happen on read. That is acceptable at the sizes this double
/// holds; the durable store leaves both to SQLite and an index on the timestamp.
actor InMemoryPressureSampleStore: PressureSampleStore {

    private var storage: [UUID: PressureSample] = [:]

    init(_ samples: [PressureSample] = []) {
        for sample in samples {
            storage[sample.id] = sample
        }
    }

    func save(_ samples: [PressureSample]) {
        for sample in samples {
            storage[sample.id] = sample
        }
    }

    func samples(in range: Range<Date>) -> [PressureSample] {
        storage.values
            .filter { range.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }
    }

    @discardableResult
    func deleteSamples(before date: Date) -> Int {
        let expiredIDs = storage
            .filter { $0.value.timestamp < date }
            .map(\.key)

        for id in expiredIDs {
            storage[id] = nil
        }
        return expiredIDs.count
    }
}
