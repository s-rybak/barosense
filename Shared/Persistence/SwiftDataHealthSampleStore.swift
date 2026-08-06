import Foundation
import SwiftData

/// On-disk row behind `SwiftDataHealthSampleStore`.
///
/// Kept private to this file so nothing outside the store ever sees a persistence type.
/// The feature pipeline and the UI speak `HealthSample` only.
@Model
final class PersistedHealthSample {

    @Attribute(.unique) var id: UUID
    var start: Date
    var end: Date
    var kindRaw: String
    /// bpm or SpO₂ fraction; `nil` for `.asleep`, where the duration is `end - start`.
    var quantity: Double?

    init(from sample: HealthSample) {
        self.id = sample.id
        self.start = sample.start
        self.end = sample.end
        self.kindRaw = sample.kind.rawValue
        switch sample.value {
        case .restingHeartRateBPM(let bpm):
            self.quantity = bpm
        case .oxygenSaturationFraction(let fraction):
            self.quantity = fraction
        case .asleep:
            self.quantity = nil
        }
    }

    func apply(_ sample: HealthSample) {
        start = sample.start
        end = sample.end
        kindRaw = sample.kind.rawValue
        switch sample.value {
        case .restingHeartRateBPM(let bpm):
            quantity = bpm
        case .oxygenSaturationFraction(let fraction):
            quantity = fraction
        case .asleep:
            quantity = nil
        }
    }

    func asHealthSample() -> HealthSample? {
        guard let kind = HealthMetricKind(rawValue: kindRaw) else { return nil }
        let value: HealthMetricValue
        switch kind {
        case .restingHeartRate:
            guard let quantity else { return nil }
            value = .restingHeartRateBPM(quantity)
        case .oxygenSaturation:
            guard let quantity else { return nil }
            value = .oxygenSaturationFraction(quantity)
        case .asleep:
            value = .asleep
        }
        return HealthSample(id: id, start: start, end: end, value: value)
    }
}

/// Durable `HealthSampleStore`. Survives process death; the training log actually grows.
///
/// `@ModelActor` owns the `ModelContext` on its executor so SwiftData stays off the main
/// actor and off every other actor. Callers still only see `HealthSampleStore`.
@ModelActor
actor SwiftDataHealthSampleStore: HealthSampleStore {

    /// On-disk store in the app's default container. One named configuration so health
    /// rows are not mixed into a later check-in / pressure store by accident.
    static func makePersistent() throws -> SwiftDataHealthSampleStore {
        let schema = Schema([PersistedHealthSample.self])
        let configuration = ModelConfiguration("HealthSamples",
                                               schema: schema,
                                               isStoredInMemoryOnly: false)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataHealthSampleStore(modelContainer: container)
    }

    /// Process-local store for tests. Same code path as production, nothing on disk.
    static func makeInMemory() throws -> SwiftDataHealthSampleStore {
        let schema = Schema([PersistedHealthSample.self])
        let configuration = ModelConfiguration("HealthSamples.InMemory",
                                               schema: schema,
                                               isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        return SwiftDataHealthSampleStore(modelContainer: container)
    }

    func save(_ samples: [HealthSample]) throws {
        guard !samples.isEmpty else { return }

        for sample in samples {
            let id = sample.id
            var descriptor = FetchDescriptor<PersistedHealthSample>(
                predicate: #Predicate { $0.id == id }
            )
            descriptor.fetchLimit = 1

            if let existing = try modelContext.fetch(descriptor).first {
                existing.apply(sample)
            } else {
                modelContext.insert(PersistedHealthSample(from: sample))
            }
        }

        try modelContext.save()
    }

    func samples(of kind: HealthMetricKind, in range: Range<Date>) throws -> [HealthSample] {
        let kindRaw = kind.rawValue
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<PersistedHealthSample>(
            predicate: #Predicate {
                $0.kindRaw == kindRaw && $0.end >= lower && $0.end < upper
            },
            sortBy: [SortDescriptor(\.end, order: .forward)]
        )

        return try modelContext.fetch(descriptor).compactMap { $0.asHealthSample() }
    }

    @discardableResult
    func deleteSamples(before date: Date) throws -> Int {
        let descriptor = FetchDescriptor<PersistedHealthSample>(
            predicate: #Predicate { $0.end < date }
        )
        let expired = try modelContext.fetch(descriptor)
        let count = expired.count
        for row in expired {
            modelContext.delete(row)
        }
        if count > 0 {
            try modelContext.save()
        }
        return count
    }
}
