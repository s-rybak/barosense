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

    /// File name of the on-disk store. Part of the storage contract — renaming it orphans
    /// every existing install's history.
    private static let storeFileName = "HealthSamples.store"

    /// On-disk store in the app's own Application Support directory. Its own file so health
    /// rows are not mixed into the check-in / pressure stores by accident.
    ///
    /// The URL is explicit for the same reason it is on the pressure store: the name-based
    /// initialiser defaults to `groupContainer: .automatic` and follows this target's
    /// app-group entitlement into a directory that does not exist, so the open throws and
    /// `BarosenseApp` falls back to memory. The Health *row* still renders — it is re-read
    /// from HealthKit on every screen load — so the failure is invisible on screen and only
    /// shows up as a training log that never grows.
    static func makePersistent() throws -> SwiftDataHealthSampleStore {
        let schema = Schema([PersistedHealthSample.self])
        do {
            let configuration = ModelConfiguration(
                schema: schema,
                url: try BarosenseModelContainer.storeURL(fileName: storeFileName),
                cloudKitDatabase: .none
            )
            let container = try ModelContainer(for: schema, configurations: [configuration])
            return SwiftDataHealthSampleStore(modelContainer: container)
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    /// Process-local store for tests. Same code path as production, nothing on disk.
    static func makeInMemory() throws -> SwiftDataHealthSampleStore {
        SwiftDataHealthSampleStore(modelContainer: try makeInMemoryContainer())
    }

    /// Shared in-memory container for tests that exercise more than one store actor.
    static func makeInMemoryContainer() throws -> ModelContainer {
        let schema = Schema([PersistedHealthSample.self])
        let configuration = ModelConfiguration("HealthSamples.InMemory",
                                               schema: schema,
                                               isStoredInMemoryOnly: true)
        return try ModelContainer(for: schema, configurations: [configuration])
    }

    func save(_ samples: [HealthSample]) throws {
        guard !samples.isEmpty else { return }

        // A refresh can overlap the previous window, so collapse duplicate identifiers
        // within this batch before touching SwiftData. The last value is the freshest.
        var samplesByID: [UUID: HealthSample] = [:]
        for sample in samples {
            samplesByID[sample.id] = sample
        }

        let sampleIDs = Array(samplesByID.keys)
        let descriptor = FetchDescriptor<PersistedHealthSample>(
            predicate: #Predicate { sampleIDs.contains($0.id) }
        )
        let existingRows = try modelContext.fetch(descriptor)
        let existingByID = Dictionary(uniqueKeysWithValues: existingRows.map { ($0.id, $0) })

        for sample in samplesByID.values {
            let id = sample.id
            if let existing = existingByID[id] {
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
