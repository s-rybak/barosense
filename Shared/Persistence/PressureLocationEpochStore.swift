import Foundation

/// Storage for location epochs.
///
/// Tiny by design. There is one row per place the user has been, which for most installs is a
/// handful ever, so there is no batch write and no windowed read — the two questions anything
/// asks are "where are we now" and "what did epoch X call itself".
protocol PressureLocationEpochStore: Sendable {

    /// Inserts an epoch, replacing any stored epoch carrying the same `id`.
    ///
    /// Upsert rather than insert because an epoch is written twice on the ordinary path: once
    /// as soon as the fix lands, so a forecast can be requested without waiting on the
    /// geocoder, and once more when the name arrives. See `PressureLocationEpoch.namingPlace`.
    func save(_ epoch: PressureLocationEpoch) async throws

    /// The epoch with the newest `startedAt`, or `nil` on a fresh install.
    ///
    /// This is "where is the user now" — the row every new sample is stamped with, and the row
    /// a fix is measured against to decide whether the user has moved.
    func currentEpoch() async throws -> PressureLocationEpoch?

    /// One epoch by identity, for a sample that carries its id.
    func epoch(id: UUID) async throws -> PressureLocationEpoch?

    /// Every epoch, newest first. Read by the erase and by nothing on a hot path.
    func allEpochs() async throws -> [PressureLocationEpoch]

    /// Retention. Epochs are removed with everything else rather than on a horizon of their
    /// own: an epoch outlives the samples pointing at it by construction, so pruning it
    /// separately would orphan rows the calibrator still reads.
    func deleteAllEpochs() async throws
}

/// Non-persistent `PressureLocationEpochStore` for unit tests and previews.
actor InMemoryPressureLocationEpochStore: PressureLocationEpochStore {

    private var storage: [UUID: PressureLocationEpoch] = [:]

    init(_ epochs: [PressureLocationEpoch] = []) {
        for epoch in epochs {
            storage[epoch.id] = epoch
        }
    }

    func save(_ epoch: PressureLocationEpoch) {
        storage[epoch.id] = epoch
    }

    func currentEpoch() -> PressureLocationEpoch? {
        storage.values.max { $0.startedAt < $1.startedAt }
    }

    func epoch(id: UUID) -> PressureLocationEpoch? {
        storage[id]
    }

    func allEpochs() -> [PressureLocationEpoch] {
        storage.values.sorted { $0.startedAt > $1.startedAt }
    }

    func deleteAllEpochs() {
        storage.removeAll()
    }
}
