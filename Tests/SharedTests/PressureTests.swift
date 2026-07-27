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
}
