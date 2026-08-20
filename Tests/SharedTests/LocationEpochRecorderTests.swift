import XCTest
@testable import Barosense

/// The epoch table's write path: when a row is written, and — the expensive one — how often
/// Apple's throttled geocoder is asked.
final class LocationEpochRecorderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)
    private let kyiv = GeoCoordinate(latitude: 50.45, longitude: 30.52)
    /// ~55 km north of `kyiv`, past the 25 km threshold.
    private let nextTown = GeoCoordinate(latitude: 50.95, longitude: 30.52)

    // MARK: - Geocoding

    /// Acceptance criterion 3. `CLGeocoder`'s limits are not published and it throttles, so an
    /// app that re-geocoded on every foreground activation would end up unable to name
    /// anywhere at all.
    func testTheGeocoderIsCalledAtMostOncePerEpoch() async {
        let namer = CountingPlaceNamer()
        let recorder = makeRecorder(fixes: [fix(at: kyiv), fix(at: kyiv), fix(at: kyiv)],
                                    namer: namer)

        for _ in 0..<3 {
            _ = await recorder.currentEpoch(asOf: now)
        }

        XCTAssertEqual(namer.callCount, 1)
    }

    /// And exactly once more when the user is actually somewhere else. One per epoch, not one
    /// ever.
    func testANewEpochSpendsItsOwnGeocode() async {
        let namer = CountingPlaceNamer()
        let recorder = makeRecorder(fixes: [fix(at: kyiv), fix(at: kyiv), fix(at: nextTown)],
                                    namer: namer)

        for _ in 0..<3 {
            _ = await recorder.currentEpoch(asOf: now)
        }

        XCTAssertEqual(namer.callCount, 2)
    }

    /// A geocode that returned nothing — offline, throttled, mid-ocean — is still spent for
    /// this process. Retrying it on every activation is exactly how an app gets throttled.
    func testAGeocodeThatReturnedNothingIsNotRetriedInTheSameProcess() async {
        let namer = CountingPlaceNamer(name: nil)
        let recorder = makeRecorder(fixes: [fix(at: kyiv), fix(at: kyiv)], namer: namer)

        _ = await recorder.currentEpoch(asOf: now)
        let second = await recorder.currentEpoch(asOf: now)

        XCTAssertEqual(namer.callCount, 1)
        XCTAssertEqual(second?.place.isEmpty, true)
    }

    // MARK: - Rows written

    func testTheFirstFixWritesOneEpochWithItsName() async throws {
        let store = InMemoryPressureLocationEpochStore()
        let recorder = makeRecorder(fixes: [fix(at: kyiv)], store: store)

        let epoch = await recorder.currentEpoch(asOf: now)

        let stored = try await store.allEpochs()
        XCTAssertEqual(stored.count, 1)
        XCTAssertEqual(epoch?.place.locality, "Kyiv")
        XCTAssertEqual(epoch?.coordinate, LocationEpochResolver.rounded(kyiv))
        XCTAssertEqual(epoch?.startedAt, now)
    }

    /// Acceptance criterion 2 seen from the store: a commute writes nothing at all.
    func testMovementInsideACityWritesNoSecondEpoch() async throws {
        let store = InMemoryPressureLocationEpochStore()
        let acrossTown = GeoCoordinate(latitude: 50.54, longitude: 30.52)
        let recorder = makeRecorder(fixes: [fix(at: kyiv), fix(at: acrossTown)], store: store)

        _ = await recorder.currentEpoch(asOf: now)
        _ = await recorder.currentEpoch(asOf: now.addingTimeInterval(3600))

        let stored = try await store.allEpochs()
        XCTAssertEqual(stored.count, 1)
    }

    func testCrossingTheThresholdWritesExactlyOneMore() async throws {
        let store = InMemoryPressureLocationEpochStore()
        let recorder = makeRecorder(fixes: [fix(at: kyiv), fix(at: nextTown), fix(at: nextTown)],
                                    store: store)

        _ = await recorder.currentEpoch(asOf: now)
        _ = await recorder.currentEpoch(asOf: now.addingTimeInterval(3600))
        let third = await recorder.currentEpoch(asOf: now.addingTimeInterval(7200))

        let stored = try await store.allEpochs()
        XCTAssertEqual(stored.count, 2)
        // Newest first, and it is the one new readings get stamped with.
        XCTAssertEqual(stored.first?.id, third?.id)
    }

    // MARK: - Without permission

    /// A refusal must cost nothing: no fix requested, no radio powered, no row written. The
    /// epoch already on disk is what everything keeps using.
    func testARefusalRequestsNoFixAndKeepsTheStoredEpoch() async {
        let store = InMemoryPressureLocationEpochStore()
        let existing = PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5,
                                                                       longitude: 30.5),
                                             startedAt: now.addingTimeInterval(-86_400))
        await store.save(existing)

        let namer = CountingPlaceNamer()
        let fixes = StubLocationFixProvider([fix(at: nextTown)])
        let recorder = LocationEpochRecorder(access: StubLocationAccessReporter(state: .denied),
                                             fixes: fixes,
                                             namer: namer,
                                             store: store)

        let resolved = await recorder.currentEpoch(asOf: now)

        let unconsumedFix = await fixes.currentFix()

        XCTAssertEqual(resolved, existing)
        XCTAssertEqual(namer.callCount, 0)
        // The fix provider was never consulted — the stub would otherwise have advanced past
        // its only scripted fix.
        XCTAssertEqual(unconsumedFix?.coordinate, nextTown)
    }

    /// A fresh install with no grant has no epoch, and that is not a failure: a barometer
    /// reading is written with `locationEpochID == nil` and nothing downstream drops it.
    func testAFreshInstallWithoutPermissionHasNoEpoch() async {
        let recorder = LocationEpochRecorder(
            access: StubLocationAccessReporter(state: .notRequested),
            fixes: StubLocationFixProvider([fix(at: kyiv)]),
            namer: CountingPlaceNamer(),
            store: InMemoryPressureLocationEpochStore()
        )

        let resolved = await recorder.currentEpoch(asOf: now)

        XCTAssertNil(resolved)
    }

    /// The background path. It reads what the last foreground session stored and asks
    /// CoreLocation for nothing — a when-in-use app cannot start location updates from a
    /// `BGAppRefreshTask`.
    func testTheBackgroundPathReadsTheStoreAndTakesNoFix() async {
        let store = InMemoryPressureLocationEpochStore()
        let existing = PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.5,
                                                                       longitude: 30.5),
                                             startedAt: now)
        await store.save(existing)

        let fixes = StubLocationFixProvider([fix(at: nextTown)])
        let recorder = LocationEpochRecorder(
            access: StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
            fixes: fixes,
            namer: CountingPlaceNamer(),
            store: store
        )

        let stored = await recorder.storedEpoch()
        let unconsumedFix = await fixes.currentFix()

        XCTAssertEqual(stored, existing)
        XCTAssertEqual(unconsumedFix?.coordinate, nextTown)
    }

    /// A device that will not produce a fix — indoors, no signal — keeps the last epoch
    /// rather than opening a nameless one.
    func testAFixThatNeverArrivesLeavesTheEpochTableAlone() async throws {
        let store = InMemoryPressureLocationEpochStore()
        let recorder = LocationEpochRecorder(
            access: StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
            fixes: StubLocationFixProvider([nil]),
            namer: CountingPlaceNamer(),
            store: store
        )

        let resolved = await recorder.currentEpoch(asOf: now)
        let stored = try await store.allEpochs()

        XCTAssertNil(resolved)
        XCTAssertEqual(stored.count, 0)
    }

    // MARK: - Helpers

    private func fix(at coordinate: GeoCoordinate) -> LocationFix {
        LocationFix(coordinate: coordinate, takenAt: now)
    }

    private func makeRecorder(fixes: [LocationFix?],
                              namer: CountingPlaceNamer = CountingPlaceNamer(),
                              store: any PressureLocationEpochStore
                                  = InMemoryPressureLocationEpochStore()) -> LocationEpochRecorder {
        LocationEpochRecorder(access: StubLocationAccessReporter(state: .granted(accuracy: .reduced)),
                              fixes: StubLocationFixProvider(fixes),
                              namer: namer,
                              store: store)
    }
}
