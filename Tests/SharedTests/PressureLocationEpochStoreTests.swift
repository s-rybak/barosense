import XCTest
@testable import Barosense

/// The epoch table, on both implementations, plus the one migration promise the barometer log
/// has to keep.
final class PressureLocationEpochStoreTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Contract, on both implementations

    func testTheCurrentEpochIsTheNewestOne() async throws {
        for store in try makeStores() {
            let older = epoch(startedAt: now.addingTimeInterval(-86_400), locality: "Lviv")
            let newer = epoch(startedAt: now, locality: "Kyiv")

            // Saved out of order on purpose — "current" is decided by `startedAt`, not by
            // write order, so a backfill cannot silently relabel where the user is.
            try await store.save(newer)
            try await store.save(older)

            let current = try await store.currentEpoch()
            XCTAssertEqual(current?.id, newer.id)
            XCTAssertEqual(current?.place.locality, "Kyiv")
        }
    }

    func testAFreshStoreHasNoCurrentEpoch() async throws {
        for store in try makeStores() {
            let current = try await store.currentEpoch()
            XCTAssertNil(current)
        }
    }

    /// The write path an epoch actually takes: the row lands as soon as the fix does, and the
    /// name is attached when the throttled geocoder answers. Two saves, one row.
    func testSavingTheSameEpochAgainUpdatesItRatherThanDuplicating() async throws {
        for store in try makeStores() {
            let unnamed = PressureLocationEpoch(
                coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                startedAt: now
            )
            try await store.save(unnamed)
            try await store.save(unnamed.namingPlace(PlaceName(locality: "Kyiv",
                                                               country: "Ukraine")))

            let all = try await store.allEpochs()
            XCTAssertEqual(all.count, 1)
            XCTAssertEqual(all.first?.place.locality, "Kyiv")
            XCTAssertEqual(all.first?.id, unnamed.id)
        }
    }

    func testAnEpochRoundTripsEveryField() async throws {
        for store in try makeStores() {
            let written = PressureLocationEpoch(
                coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                place: PlaceName(locality: "Kyiv",
                                 administrativeArea: "Kyiv Oblast",
                                 country: "Ukraine"),
                altitudeMetres: 179,
                startedAt: now
            )
            try await store.save(written)

            let read = try await store.epoch(id: written.id)
            XCTAssertEqual(read, written)
        }
    }

    /// Acceptance criterion 4's other half: the erase reaches this store, and it empties.
    func testDeletingEmptiesTheTable() async throws {
        for store in try makeStores() {
            try await store.save(epoch(startedAt: now, locality: "Kyiv"))
            try await store.deleteAllEpochs()

            let remaining = try await store.allEpochs()
            let current = try await store.currentEpoch()
            XCTAssertEqual(remaining.count, 0)
            XCTAssertNil(current)
        }
    }

    // MARK: - Migration

    /// Acceptance criterion 5. `locationEpochID` is a new optional attribute on a table that
    /// already has rows on every existing install: those rows must read back with `nil` and
    /// must not be dropped.
    func testASampleWrittenWithoutAnEpochReadsBackWithNilAndSurvives() async throws {
        let samples = try SwiftDataPressureSampleStore.makeInMemory()
        let written = PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1013))

        try await samples.save([written])

        let read = try await samples.samples(
            in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1)
        )
        XCTAssertEqual(read.count, 1)
        XCTAssertNil(read.first?.locationEpochID)
        XCTAssertEqual(read.first?.pressure.hectopascals, 1013)
    }

    /// And a stamped sample keeps its stamp across the same round trip, so the join the
    /// calibrator makes is actually available on disk.
    func testAStampedSampleKeepsItsEpochAcrossTheStore() async throws {
        let container = try SwiftDataPressureSampleStore.makeContainer(inMemory: true)
        let samples = SwiftDataPressureSampleStore(modelContainer: container)
        let epochs = SwiftDataPressureLocationEpochStore(modelContainer: container)

        let place = epoch(startedAt: now, locality: "Kyiv")
        try await epochs.save(place)
        try await samples.save([PressureSample(timestamp: now,
                                               pressure: Pressure(hectopascals: 1013),
                                               locationEpochID: place.id)])

        let read = try await samples.samples(
            in: now.addingTimeInterval(-1)..<now.addingTimeInterval(1)
        )
        let storedEpoch = try await epochs.epoch(id: place.id)
        XCTAssertEqual(read.first?.locationEpochID, place.id)
        XCTAssertEqual(storedEpoch?.place.locality, "Kyiv")
    }

    // MARK: - Helpers

    /// Both implementations, run through the same assertions. The in-memory double exists to
    /// stand in for the durable one, and a contract only one of them keeps is not a contract.
    private func makeStores() throws -> [any PressureLocationEpochStore] {
        [InMemoryPressureLocationEpochStore(),
         try SwiftDataPressureLocationEpochStore.makeInMemory()]
    }

    private func epoch(startedAt: Date, locality: String) -> PressureLocationEpoch {
        PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5, longitude: 30.5),
                              place: PlaceName(locality: locality, country: "Ukraine"),
                              startedAt: startedAt)
    }
}
