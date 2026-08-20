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

    /// Which `PressureLocationEpoch` this reading was taken in.
    ///
    /// **Optional in storage, and stays optional.** Every row written before the epoch table
    /// existed reads back `nil`, which is what makes this a lightweight SwiftData migration
    /// rather than a history the user loses. `nil` is also the ordinary state of a reading
    /// taken before the first location fix of an install, or with location refused
    /// altogether — the barometer works either way, and a sample is never dropped for
    /// wanting a place.
    ///
    /// Not a SwiftData relationship. A relationship would put the epoch's cascade rules and
    /// its fetch cost on the hot write path of a table that gains a row every fifteen
    /// minutes, to express a join the calibrator makes once per pass.
    var locationEpochID: UUID?

    init(from sample: PressureSample) {
        self.id = sample.id
        self.timestamp = sample.timestamp
        self.hectopascals = sample.pressure.hectopascals
        self.locationEpochID = sample.locationEpochID
    }

    func apply(_ sample: PressureSample) {
        timestamp = sample.timestamp
        hectopascals = sample.pressure.hectopascals
        locationEpochID = sample.locationEpochID
    }

    func asPressureSample() -> PressureSample {
        PressureSample(id: id,
                       timestamp: timestamp,
                       pressure: Pressure(hectopascals: hectopascals),
                       locationEpochID: locationEpochID)
    }
}

/// Durable `PressureSampleStore`. Survives process death, which is the whole point: a
/// barometer history that resets on relaunch can never reach the 3–7 days the cold-start
/// requirement is stated against.
///
/// Phone-only. The watch neither samples nor stores — it is a display onto the newest
/// reading (`PressureDisplayLink`) — so this is the single copy of the barometer history,
/// and the same rows serve the chart and the model. One history, not two nearly-identical
/// ones.
///
    /// Retention is enforced by `PressureSampleRecorder` on the write path (at most once per day),
    /// not by a dedicated timer/background task. `deleteSamples(before:)` exists for that
    /// housekeeping.
///
/// `@ModelActor` owns the `ModelContext` on its executor so SwiftData stays off the main
/// actor. Callers still only see `PressureSampleStore`.
@ModelActor
actor SwiftDataPressureSampleStore: PressureSampleStore {

    /// File name of the on-disk store. Part of the storage contract — renaming it orphans
    /// every existing install's history.
    private static let storeFileName = "PressureSamples.store"

    /// On-disk store in the app's own Application Support directory.
    ///
    /// Its own file, like `SwiftDataHealthSampleStore` — sensor rows are not mixed into the
    /// profile/tag store. That store's schema is a deliberate list of what belongs in it,
    /// and pressure is not on it.
    ///
    /// The URL is explicit rather than derived from a configuration name. The name-based
    /// initialiser defaults to `groupContainer: .automatic`, which follows this target's
    /// app-group entitlement into a container whose `Library/Application Support` does not
    /// exist — the open then throws, both app targets catch it and fall back to
    /// `InMemoryPressureSampleStore`, and the barometer history silently restarts from
    /// empty on every launch. See `BarosenseModelContainer.storeURL(fileName:)`.
    static func makePersistent() throws -> SwiftDataPressureSampleStore {
        SwiftDataPressureSampleStore(modelContainer: try makeContainer(inMemory: false))
    }

    /// Process-local store for tests and previews. Same code path as production, nothing on
    /// disk.
    static func makeInMemory() throws -> SwiftDataPressureSampleStore {
        SwiftDataPressureSampleStore(modelContainer: try makeContainer(inMemory: true))
    }

    /// The barometer container, shared with `SwiftDataPressureLocationEpochStore`.
    ///
    /// Internal rather than private because the epoch table lives in this same file and this
    /// same schema — a sample references an epoch, so two containers opened separately could
    /// disagree about which epochs exist, the way check-ins and the tag vocabulary would. The
    /// composition root opens it once and hands it to both actors.
    static func makeContainer(inMemory: Bool) throws -> ModelContainer {
        // Adding `PersistedPressureLocationEpoch` to an existing store file is a lightweight
        // SwiftData migration — a new entity and a new optional attribute — so an install
        // upgrading into this version keeps its barometer history and reads every old row
        // back with `locationEpochID == nil`.
        let schema = Schema([PersistedPressureSample.self, PersistedPressureLocationEpoch.self])
        do {
            let configuration = if inMemory {
                ModelConfiguration("PressureSamples.InMemory",
                                   schema: schema,
                                   isStoredInMemoryOnly: true,
                                   cloudKitDatabase: .none)
            } else {
                ModelConfiguration(schema: schema,
                                   url: try BarosenseModelContainer.storeURL(fileName: storeFileName),
                                   cloudKitDatabase: .none)
            }
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            throw PersistenceError.containerUnavailable(underlying: error)
        }
    }

    func save(_ samples: [PressureSample]) throws {
        guard !samples.isEmpty else { return }

        // Upsert, not insert. The recorder writes one reading at a time under a freshly
        // generated identifier, so nothing collides today; the path is here because a
        // restored backup or a later backfill would otherwise turn one reading into two
        // training rows. Duplicates inside the batch collapse first, last value wins.
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
