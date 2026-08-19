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
