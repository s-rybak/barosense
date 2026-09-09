import XCTest
@testable import Barosense

final class PressureTests: XCTestCase {

    func testKilopascalConversionMatchesMeteorologicalUnit() {
        // A CoreMotion reading of 101.325 kPa is standard sea-level pressure.
        let pressure = Pressure(kilopascals: 101.325)
        XCTAssertEqual(pressure.hectopascals, 1013.25, accuracy: 0.001)
    }

    func testRoundTripThroughKilopascals() {
        let original = Pressure(hectopascals: 987.6)
        XCTAssertEqual(Pressure(kilopascals: original.kilopascals).hectopascals,
                       original.hectopascals,
                       accuracy: 0.001)
    }

    func testRawKilopascalValueIsRejectedAsImplausible() {
        // The classic unit bug: kPa handed straight in as hPa.
        XCTAssertFalse(Pressure(hectopascals: 101.325).isPlausible)
        XCTAssertTrue(Pressure(kilopascals: 101.325).isPlausible)
    }

    func testFallingPressureProducesNegativeDelta() {
        let earlier = Pressure(hectopascals: 1015)
        let later = Pressure(hectopascals: 1006)
        XCTAssertEqual(later.delta(from: earlier), -9, accuracy: 0.001)
    }

    // MARK: - Non-finite input

    func testNonFiniteReadingsAreNotPlausible() {
        // NaN and the infinities are what a divide-by-zero or a corrupt sensor word arrives
        // as. `isPlausible` is the only thing between them and the hourly grid, where one
        // NaN turns every mean, SD and delta over the window into NaN without an error.
        for value in [Double.nan, .signalingNaN, .infinity, -.infinity] {
            XCTAssertFalse(Pressure(hectopascals: value).isPlausible, "hPa \(value)")
            XCTAssertFalse(Pressure(kilopascals: value).isPlausible, "kPa \(value)")
        }
    }

    func testPhysicallyImpossibleReadingsAreNotPlausible() {
        for value in [-1.0, 0, 799.9, 1100.1, 1e9] {
            XCTAssertFalse(Pressure(hectopascals: value).isPlausible, "hPa \(value)")
        }
    }

    func testTheRangeBoundsThemselvesAreAccepted() {
        // Pins the gate as closed, not half-open: a reading exactly on either bound is a
        // reading, and narrowing this silently drops rows at the extremes of real weather.
        XCTAssertTrue(Pressure(hectopascals: 800).isPlausible)
        XCTAssertTrue(Pressure(hectopascals: 1100).isPlausible)
    }
}
