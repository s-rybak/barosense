import Foundation
import SwiftData

/// On-disk row behind `SwiftDataPressureSampleStore`.
///
/// Kept private to this file so nothing outside the store ever sees a persistence type. The
/// chart and the feature pipeline speak `PressureSample` only.
///
/// The value is stored in **hPa**, the domain unit, not in the kPa CoreMotion reports.
/// Conversion happens once at the sensor boundary (`CoreMotionPressureSource`); a store that
/// accepted either would be a place for the 10× bug to hide at rest, where no test would
/// ever see it.
@Model
final class PersistedPressureSample {

    /// Indexed on `timestamp` because every read is a window over it: the chart asks for a
    /// trailing range on every load, and retention asks for everything older than a date.
    /// Unindexed, both become a full scan of a table that grows by a row an hour forever.
    #Index<PersistedPressureSample>([\.timestamp])

    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var hectopascals: Double

    init(from sample: PressureSample) {
        self.id = sample.id
        self.timestamp = sample.timestamp
        self.hectopascals = sample.pressure.hectopascals
    }

    func apply(_ sample: PressureSample) {
        timestamp = sample.timestamp
        hectopascals = sample.pressure.hectopascals
    }

    func asPressureSample() -> PressureSample {
        PressureSample(id: id, timestamp: timestamp, pressure: Pressure(hectopascals: hectopascals))
    }
}

/// Durable `PressureSampleStore`. Survives process death, which is the whole point: a
/// barometer history that resets on relaunch can never reach the 3–7 days the cold-start
/// requirement is stated against.
///
/// Runs on both targets. On the watch it is the local log the uplink resends from; on the
/// phone it is the training log everything downstream reads. Same code, same rows, and
/// because every sample carries the identifier its originating device generated, the phone
/// can accept the same reading twice without it becoming two training rows.
///
/// `@ModelActor` owns the `ModelContext` on its executor so SwiftData stays off the main
/// actor. Callers still only see `PressureSampleStore`.
@ModelActor
actor SwiftDataPressureSampleStore: PressureSampleStore {

    /// On-disk store in the app's default container.
    ///
    /// Its own named configuration, like `SwiftDataHealthSampleStore` — sensor rows are not
    /// mixed into the profile/tag store. That store's schema is a deliberate list of what
    /// belongs in it, and pressure is not on it.
    static func makePersistent() throws -> SwiftDataPressureSampleStore {
        SwiftDataPressureSampleStore(modelContainer: try makeContainer(inMemory: false))
    }

    /// Process-local store for tests and previews. Same code path as production, nothing on
    /// disk.
    static func makeInMemory() throws -> SwiftDataPressureSampleStore {
        SwiftDataPressureSampleStore(modelContainer: try makeContainer(inMemory: true))
    }

    private static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        let schema = Schema([PersistedPressureSample.self])
        let configuration = ModelConfiguration(inMemory ? "PressureSamples.InMemory" : "PressureSamples",
                                               schema: schema,
                                               isStoredInMemoryOnly: inMemory)
        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    func save(_ samples: [PressureSample]) throws {
        guard !samples.isEmpty else { return }

        // The uplink resends an overlapping window every time, so most of what arrives is
        // already stored. Collapse duplicates inside this batch first — the last value wins
        // — then upsert, so one repeated reading stays one row.
        var samplesByID: [UUID: PressureSample] = [:]
        for sample in samples {
            samplesByID[sample.id] = sample
        }

        let sampleIDs = Array(samplesByID.keys)
        let descriptor = FetchDescriptor<PersistedPressureSample>(
            predicate: #Predicate { sampleIDs.contains($0.id) }
        )
        let existingByID = Dictionary(uniqueKeysWithValues:
            try modelContext.fetch(descriptor).map { ($0.id, $0) })

        for sample in samplesByID.values {
            if let existing = existingByID[sample.id] {
                existing.apply(sample)
            } else {
                modelContext.insert(PersistedPressureSample(from: sample))
            }
        }

        try modelContext.save()
    }

    func samples(in range: Range<Date>) throws -> [PressureSample] {
        let lower = range.lowerBound
        let upper = range.upperBound

        let descriptor = FetchDescriptor<PersistedPressureSample>(
            predicate: #Predicate { $0.timestamp >= lower && $0.timestamp < upper },
            sortBy: [SortDescriptor(\.timestamp, order: .forward)]
        )

        return try modelContext.fetch(descriptor).map { $0.asPressureSample() }
    }

    @discardableResult
    func deleteSamples(before date: Date) throws -> Int {
        let descriptor = FetchDescriptor<PersistedPressureSample>(
            predicate: #Predicate { $0.timestamp < date }
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
