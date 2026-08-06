import Foundation

/// Non-persistent `HealthSampleStore` for unit tests, SwiftUI previews, and bring-up
/// before a durable store exists. Contents are lost with the process.
///
/// Filtering and sorting happen on read, as in `InMemoryPressureSampleStore`. Acceptable
/// at the sizes this double holds; the durable store leaves both to SQLite and an index
/// on the end date.
actor InMemoryHealthSampleStore: HealthSampleStore {

    private var storage: [UUID: HealthSample] = [:]

    init(_ samples: [HealthSample] = []) {
        for sample in samples {
            storage[sample.id] = sample
        }
    }

    func save(_ samples: [HealthSample]) {
        for sample in samples {
            storage[sample.id] = sample
        }
    }

    func samples(of kind: HealthMetricKind, in range: Range<Date>) -> [HealthSample] {
        storage.values
            .filter { $0.kind == kind && range.contains($0.end) }
            .sorted { $0.end < $1.end }
    }

    @discardableResult
    func deleteSamples(before date: Date) -> Int {
        let expiredIDs = storage
            .filter { $0.value.end < date }
            .map(\.key)

        for id in expiredIDs {
            storage[id] = nil
        }
        return expiredIDs.count
    }
}
