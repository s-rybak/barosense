import XCTest
@testable import Barosense

/// The rule that decides how many epoch rows a year get written and how often Apple's
/// throttled geocoder is called.
///
/// Every case here runs on literals. `CLLocationManager` and `CLLocation` appear nowhere —
/// acceptance criterion 1 in `.claude/context/pressure-forecast-spec.md` §5.
final class LocationEpochResolverTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Kyiv, near enough. The reference point every distance below is measured from.
    private let kyiv = GeoCoordinate(latitude: 50.45, longitude: 30.52)

    // MARK: - Rounding

    /// 0.1° is the storage contract. A coordinate that reached storage unrounded would be a
    /// street address in a table that promises ~11 km.
    func testACoordinateIsRoundedOntoTheTenthOfADegreeGrid() {
        let rounded = LocationEpochResolver.rounded(kyiv)

        XCTAssertEqual(rounded.latitude, 50.5, accuracy: 1e-9)
        XCTAssertEqual(rounded.longitude, 30.5, accuracy: 1e-9)
    }

    /// Floating-point multiplication lands 0.1 × 504 on 50.400000000000006, which is not the
    /// literal anybody writes and not the value the same fix produces on the next launch.
    func testRoundingIsStableAcrossRepeatedResolution() {
        let once = LocationEpochResolver.rounded(GeoCoordinate(latitude: 50.44, longitude: 30.44))
        let twice = LocationEpochResolver.rounded(once)

        XCTAssertEqual(once, twice)
        XCTAssertEqual(once.latitude, 50.4, accuracy: 1e-9)
    }

    func testRoundingWorksInTheSouthernAndWesternHemispheres() {
        let rounded = LocationEpochResolver.rounded(
            GeoCoordinate(latitude: -33.87, longitude: -70.66)
        )

        XCTAssertEqual(rounded.latitude, -33.9, accuracy: 1e-9)
        XCTAssertEqual(rounded.longitude, -70.7, accuracy: 1e-9)
    }

    // MARK: - Distance

    /// One degree of latitude is ~111 km anywhere on the sphere. If this drifts, the 25 km
    /// threshold stops meaning 25 km.
    func testOneDegreeOfLatitudeIsAboutOneHundredAndElevenKilometres() {
        let travelled = LocationEpochResolver.distanceMetres(
            from: GeoCoordinate(latitude: 50, longitude: 30),
            to: GeoCoordinate(latitude: 51, longitude: 30)
        )

        XCTAssertEqual(travelled, 111_195, accuracy: 500)
    }

    /// Longitude converges toward the poles: at 50° N a degree of longitude is ~71 km, not
    /// ~111. A resolver that used flat differences would open an epoch for a shorter
    /// east–west trip than a north–south one.
    func testLongitudeDistanceShrinksWithLatitude() {
        let travelled = LocationEpochResolver.distanceMetres(
            from: GeoCoordinate(latitude: 50, longitude: 30),
            to: GeoCoordinate(latitude: 50, longitude: 31)
        )

        XCTAssertEqual(travelled, 71_600, accuracy: 800)
    }

    // MARK: - The threshold

    /// The first fix an install ever takes has nothing to be near.
    func testTheFirstFixOpensAnEpoch() {
        let decision = LocationEpochResolver.resolve(fix: kyiv, against: nil)

        guard case .open(let coordinate) = decision else {
            return XCTFail("expected the first fix to open an epoch, got \(decision)")
        }
        // Already on the grid: the caller stores what it is handed and never rounds again.
        XCTAssertEqual(coordinate, LocationEpochResolver.rounded(kyiv))
    }

    /// Acceptance criterion 2, half one: movement inside a city creates nothing. A ~10 km
    /// crossing is an ordinary commute and must not spend a geocode.
    func testMovingAcrossACityReusesTheEpoch() {
        let epoch = makeEpoch(at: kyiv)
        // ~0.09° of latitude ≈ 10 km due north.
        let acrossTown = GeoCoordinate(latitude: 50.54, longitude: 30.52)

        XCTAssertEqual(LocationEpochResolver.resolve(fix: acrossTown, against: epoch),
                       .reuse(epoch))
    }

    /// Acceptance criterion 2, other half: crossing the threshold creates exactly one epoch.
    func testCrossingTheThresholdOpensExactlyOneEpoch() {
        let epoch = makeEpoch(at: kyiv)
        // ~0.5° of latitude ≈ 55 km due north, comfortably past 25 km.
        let nextTown = GeoCoordinate(latitude: 50.95, longitude: 30.52)

        guard case .open(let coordinate) = LocationEpochResolver.resolve(fix: nextTown,
                                                                        against: epoch) else {
            return XCTFail("expected a move past the threshold to open an epoch")
        }

        // And the newly opened epoch then absorbs a second fix at the same place, rather than
        // opening a second one — which is what "exactly one" means in practice.
        let opened = makeEpoch(at: coordinate)
        XCTAssertEqual(LocationEpochResolver.resolve(fix: nextTown, against: opened),
                       .reuse(opened))
    }

    /// The threshold is measured against the **rounded** fix, so a coordinate that lands in
    /// the epoch's own grid cell is zero metres away by construction. Without that, the
    /// comparison and the stored value could disagree at the boundary.
    func testDistanceIsMeasuredAgainstTheStoredGrid() {
        let epoch = makeEpoch(at: kyiv)
        let sameCell = GeoCoordinate(latitude: 50.4999, longitude: 30.4999)

        XCTAssertEqual(LocationEpochResolver.resolve(fix: sameCell, against: epoch),
                       .reuse(epoch))
    }

    // MARK: - Helpers

    private func makeEpoch(at coordinate: GeoCoordinate) -> PressureLocationEpoch {
        PressureLocationEpoch(coordinate: LocationEpochResolver.rounded(coordinate),
                              startedAt: now)
    }
}

extension LocationEpochResolverTests {

    // MARK: - Which epochs count as here

    /// The epoch table is a list of *arrivals*, not of places. `resolve` only ever compares a
    /// fix against the current epoch, so a commute past the threshold writes one row per leg
    /// and coming home writes a **third** row carrying the first one's coordinate. Counting
    /// those two as different places would throw away half the history of where the user
    /// lives.
    func testComingBackHomeCountsAsTheSamePlaceAsHavingLivedThere() {
        let home = GeoCoordinate(latitude: 50.5, longitude: 30.5)
        let away = GeoCoordinate(latitude: 51.0, longitude: 31.5)

        let first = PressureLocationEpoch(coordinate: home, startedAt: date(daysAgo: 10))
        let trip = PressureLocationEpoch(coordinate: away, startedAt: date(daysAgo: 3))
        let back = PressureLocationEpoch(coordinate: home, startedAt: date(daysAgo: 1))

        let here = LocationEpochResolver.samePlaceEpochIDs(as: back,
                                                           among: [first, trip, back])

        XCTAssertEqual(here, [first.id, back.id])
    }

    /// No current epoch is not the same as no epochs matching. `nil` means "nothing to filter
    /// on"; an empty set would mean "nothing qualifies" and would discard every reading on a
    /// device where location was simply never granted.
    func testNoCurrentEpochFiltersNothing() {
        XCTAssertNil(LocationEpochResolver.samePlaceEpochIDs(as: nil, among: []))

        let readings = [PressureSample(timestamp: date(daysAgo: 1),
                                       pressure: Pressure(hectopascals: 1013),
                                       locationEpochID: UUID())]

        XCTAssertEqual(LocationEpochResolver.readings(readings, takenAt: nil).count, 1)
    }

    /// A log with no stamps at all — written before the epoch table existed, or before this
    /// install's first fix — passes through whole. A log that *is* stamped is filtered.
    func testOnlyAStampedLogIsFiltered() {
        let here = UUID()
        let unstamped = (0..<3).map {
            PressureSample(timestamp: date(daysAgo: $0 + 1),
                           pressure: Pressure(hectopascals: 1013))
        }
        let mixed = unstamped + [PressureSample(timestamp: date(daysAgo: 0),
                                                pressure: Pressure(hectopascals: 1013),
                                                locationEpochID: here)]

        XCTAssertEqual(LocationEpochResolver.readings(unstamped, takenAt: [here]).count, 3)
        XCTAssertEqual(LocationEpochResolver.readings(mixed, takenAt: [here]).count, 1)
        XCTAssertEqual(LocationEpochResolver.readings(mixed, takenAt: [UUID()]).count, 0)
    }

    /// Acceptance criterion 5 of the location epoch PR: *"семпли, записані до міграції,
    /// читаються з `locationEpochID == nil` і не втрачаються"*.
    ///
    /// The all-unstamped log above satisfies it. The **mixed** log did not, and that is the
    /// shape every existing install takes on the day this feature lands: weeks of unstamped
    /// history, then one stamped reading, and the strict rule discards the weeks. The AR fit
    /// then has nothing to fit and the chart draws no forward half — on the device with the
    /// most history, which is the opposite of what a cold-start rule should do.
    func testUnstampedReadingsSurviveAMixedLogForTheFit() {
        let here = UUID()
        let history = (1...30).map {
            PressureSample(timestamp: date(daysAgo: $0), pressure: Pressure(hectopascals: 1013))
        }
        let sinceUpdate = [PressureSample(timestamp: date(daysAgo: 0),
                                          pressure: Pressure(hectopascals: 1011),
                                          locationEpochID: here)]
        let mixed = history + sinceUpdate

        XCTAssertEqual(
            LocationEpochResolver.readings(mixed, takenAt: [here], unstamped: .included).count,
            mixed.count
        )
        // A reading stamped with somewhere else is still dropped: "no stamp" and "elsewhere"
        // are different facts and only one of them is silence.
        let elsewhere = mixed + [PressureSample(timestamp: date(daysAgo: 0),
                                                pressure: Pressure(hectopascals: 990),
                                                locationEpochID: UUID())]
        XCTAssertEqual(
            LocationEpochResolver.readings(elsewhere, takenAt: [here], unstamped: .included).count,
            mixed.count
        )
    }

    /// And the calibrator keeps the strict rule, which is why the policy is a parameter rather
    /// than a change of behaviour. Its quantity is a median of `station − MSLP`, and elevation
    /// *is* that quantity — a window blending two places returns a number describing nowhere.
    func testTheOffsetCalibratorStillExcludesUnstampedReadings() {
        let here = UUID()
        let mixed = [PressureSample(timestamp: date(daysAgo: 1), pressure: Pressure(hectopascals: 1013)),
                     PressureSample(timestamp: date(daysAgo: 0),
                                    pressure: Pressure(hectopascals: 991),
                                    locationEpochID: here)]

        XCTAssertEqual(LocationEpochResolver.readings(mixed, takenAt: [here]).count, 1)
    }

    private func date(daysAgo: Int) -> Date {
        Date(timeIntervalSince1970: 1_700_000_000).addingTimeInterval(-Double(daysAgo) * 86_400)
    }
}
