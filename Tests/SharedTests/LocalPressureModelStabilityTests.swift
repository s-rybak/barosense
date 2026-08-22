import XCTest
@testable import Barosense

/// The guard that keeps the forward iteration inside the atmosphere.
///
/// Its own file because it is arithmetic on a coefficient vector and nothing else — no fixture,
/// no fit, no grid — and because it is the piece a reader most needs to be able to check against
/// a textbook. `LocalPressureModelTests` covers what the model does with a log; this covers the
/// one calculation that decides whether the curve it draws converges.
final class LocalPressureModelStabilityTests: XCTestCase {

    // MARK: - The stability arithmetic

    /// The root modulus, against an independent root finder. The first case is the polynomial
    /// the device really fitted; the rest cover a real dominant root, a complex pair, a
    /// negative lag and the degenerate all-zero fit a flat log produces.
    func testTheDominantRootModulusMatchesADirectSolve() {
        let cases: [(lags: [Double], modulus: Double)] = [
            ([1.0359, -0.0937, 0.3617], 1.2067),
            ([0.742], 0.742),
            ([0.463, 0.424], 0.9226),
            ([0.289, 0.198, 0.367], 0.9282),
            ([-0.5, 0.2], 0.7623),
            ([0, 0, 0], 0)
        ]

        for (lags, modulus) in cases {
            XCTAssertEqual(LocalPressureModel.tendencyPersistence(of: lags), modulus,
                           accuracy: 0.0005, "\(lags)")
        }
    }

    /// Scaling lag *j* by `γ^j` multiplies every root by `γ`, so one factor lands the whole
    /// root set exactly on the cap. That exactness is why this is scaling rather than rejection:
    /// there is no cliff between a fit at 0.90 and one at 0.91, and the relative weight of one
    /// hour against the next survives untouched.
    func testStabilisingLandsTheRootsExactlyOnTheCap() {
        let explosive = [1.0359, -0.0937, 0.3617]
        let radius = LocalPressureModel.tendencyPersistence(of: explosive)

        let pulled = LocalPressureModel.stabilised(explosive, at: radius)

        XCTAssertEqual(LocalPressureModel.tendencyPersistence(of: pulled),
                       LocalPressureModel.maximumTendencyPersistence,
                       accuracy: 0.0005)
        XCTAssertTrue(LocalPressureModel.isStable(pulled))
    }

    /// A fit already inside the cap is left alone. Damping everything would be a second,
    /// invisible model on top of the fitted one.
    func testAFitInsideTheCapIsNotTouched() {
        let calm = [0.4, 0.2]
        let radius = LocalPressureModel.tendencyPersistence(of: calm)

        XCTAssertLessThan(radius, LocalPressureModel.maximumTendencyPersistence)
        XCTAssertEqual(LocalPressureModel.stabilised(calm, at: radius), calm)
    }

    /// The unit-root case, which is what a perfectly steady trend fits to: lags summing to
    /// exactly one. It is not stable, it is the boundary — and it is the case that made the
    /// level model draw a straight ramp for eighteen hours before it started curving upward.
    func testLagsSummingToOneAreNotTreatedAsStable() {
        XCTAssertFalse(LocalPressureModel.isStable([1]))
        XCTAssertFalse(LocalPressureModel.isStable([0.5, 0.5]))
        XCTAssertTrue(LocalPressureModel.isStable([0.5, 0.4]))
    }
}
