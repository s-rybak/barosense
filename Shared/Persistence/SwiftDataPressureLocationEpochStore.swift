import Foundation
import SwiftData

/// On-disk row behind `SwiftDataPressureLocationEpochStore`.
///
/// Stored on the **barometer container**, not on `BarosenseModelContainer`, and for the reason
/// check-ins share a container with the tag vocabulary they point at: every `PressureSample`
/// references an epoch, and two containers opened separately could disagree about which
/// epochs exist.
///
/// The place name is flattened into three optional strings rather than stored as an embedded
/// `PlaceName`. SwiftData would need a `@Model` or a `Codable` attribute for the nested type,
/// and neither buys anything for three optional strings that are only ever read together.
@Model
final class PersistedPressureLocationEpoch {

    /// Indexed on `startedAt` because the only hot read is "the newest one".
    #Index<PersistedPressureLocationEpoch>([\.startedAt])

    @Attribute(.unique) var id: UUID
    var latitude: Double
    var longitude: Double
    var locality: String?
    var administrativeArea: String?
    var country: String?
    var altitudeMetres: Double?
    var startedAt: Date

    init(from epoch: PressureLocationEpoch) {
        self.id = epoch.id
        self.latitude = epoch.coordinate.latitude
        self.longitude = epoch.coordinate.longitude
        self.locality = epoch.place.locality
        self.administrativeArea = epoch.place.administrativeArea
        self.country = epoch.place.country
        self.altitudeMetres = epoch.altitudeMetres
        self.startedAt = epoch.startedAt
    }

    func apply(_ epoch: PressureLocationEpoch) {
        latitude = epoch.coordinate.latitude
        longitude = epoch.coordinate.longitude
        locality = epoch.place.locality
        administrativeArea = epoch.place.administrativeArea
        country = epoch.place.country
        altitudeMetres = epoch.altitudeMetres
        startedAt = epoch.startedAt
    }

    func asEpoch() -> PressureLocationEpoch {
        PressureLocationEpoch(
            id: id,
            coordinate: GeoCoordinate(latitude: latitude, longitude: longitude),
            place: PlaceName(locality: locality,
                             administrativeArea: administrativeArea,
                             country: country),
            altitudeMetres: altitudeMetres,
            startedAt: startedAt
        )
    }
}

/// Durable `PressureLocationEpochStore`.
///
/// Shares the barometer container with `SwiftDataPressureSampleStore` — same file, same
/// schema, one open. Built by handing both actors the container the composition root opened
/// once; opening two containers over one SQLite file is the mistake the comment in
/// `BarosenseApp` warns about.
@ModelActor
actor SwiftDataPressureLocationEpochStore: PressureLocationEpochStore {

    /// Convenience for tests and previews: its own in-memory container, nothing on disk.
    static func makeInMemory() throws -> SwiftDataPressureLocationEpochStore {
        SwiftDataPressureLocationEpochStore(
            modelContainer: try SwiftDataPressureSampleStore.makeContainer(inMemory: true)
        )
    }

    func save(_ epoch: PressureLocationEpoch) throws {
        let epochID = epoch.id
        let descriptor = FetchDescriptor<PersistedPressureLocationEpoch>(
            predicate: #Predicate { $0.id == epochID }
        )

        if let existing = try modelContext.fetch(descriptor).first {
            existing.apply(epoch)
        } else {
            modelContext.insert(PersistedPressureLocationEpoch(from: epoch))
        }

        try modelContext.save()
    }

    func currentEpoch() throws -> PressureLocationEpoch? {
        var descriptor = FetchDescriptor<PersistedPressureLocationEpoch>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )
        descriptor.fetchLimit = 1

        return try modelContext.fetch(descriptor).first?.asEpoch()
    }

    func epoch(id: UUID) throws -> PressureLocationEpoch? {
        let descriptor = FetchDescriptor<PersistedPressureLocationEpoch>(
            predicate: #Predicate { $0.id == id }
        )

        return try modelContext.fetch(descriptor).first?.asEpoch()
    }

    func allEpochs() throws -> [PressureLocationEpoch] {
        let descriptor = FetchDescriptor<PersistedPressureLocationEpoch>(
            sortBy: [SortDescriptor(\.startedAt, order: .reverse)]
        )

        return try modelContext.fetch(descriptor).map { $0.asEpoch() }
    }

    func deleteAllEpochs() throws {
        let rows = try modelContext.fetch(FetchDescriptor<PersistedPressureLocationEpoch>())
        guard !rows.isEmpty else { return }

        for row in rows {
            modelContext.delete(row)
        }
        try modelContext.save()
    }
}
