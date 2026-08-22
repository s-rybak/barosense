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
    func testLagsSummingToOneAreRejected() {
        XCTAssertFalse(LocalPressureModel.isStable([1]))
        XCTAssertFalse(LocalPressureModel.isStable([0.5, 0.5]))
        XCTAssertTrue(LocalPressureModel.isStable([0.5, 0.4]))
    }

    // MARK: - The reversal horizon

    /// The scan reaches past the range the curve is drawn across, and it has to.
    ///
    /// These lags are an AR(2) with a complex pair at radius 0.97 and a period of **40 hours**:
    /// its impulse response `r^t · sin((t+1)θ) / sin θ` first turns negative at step 20. Scanned
    /// across the 18 h the chart draws — which is what this check used to read — a 40-hour
    /// oscillation passed, and then drew its own reversal at hour 18 of an 18-hour curve.
    ///
    /// A 40-hour cycle is S1 mis-estimated by a factor of 1.7, which is exactly what a lag block
    /// does with a tide it cannot afford the terms for. The horizon is its own constant so that
    /// the answer here cannot change when somebody changes what the chart shows.
    func testAnOscillationSlowerThanTheDrawnRangeIsStillCaught() {
        let fortyHourCycle = [1.9161, -0.9409]

        XCTAssertTrue(LocalPressureModel.tendencyReversesWithinTideHorizon(fortyHourCycle))
        XCTAssertGreaterThanOrEqual(LocalPressureModel.tendencyReversalHorizonHours, 24,
                                    "below 24 the scan stops covering S1's own half-period")
    }

    /// And the horizon is not the drawn range wearing a different name.
    ///
    /// The coupling this pins is the one `absoluteMinimumRows` breaks in the other direction:
    /// `rangeSeconds` is a decision about a picture, and a picture must not decide which fits
    /// the model accepts. If these two ever become equal again it is a coincidence to look at,
    /// not a refactor to keep.
    func testTheReversalHorizonIsNotTheDrawnRange() {
        XCTAssertNotEqual(
            TimeInterval(LocalPressureModel.tendencyReversalHorizonHours) * 3600,
            ForecastSource.localModel.rangeSeconds
        )
    }

    // MARK: - The floor under the ladder

    /// Every rung refused is no forward curve at all, and that is the one outcome the ladder
    /// exists to avoid.
    ///
    /// A perfect hour-by-hour alternation is the worst case for the reversal check: the target
    /// is exactly the negative of its own first lag, so the three-lag and two-lag rungs both fit
    /// an oscillating block and both are refused. Twelve cells is too few to afford the
    /// harmonics (8 rows against the 11 they need), so before the one-lag exemption this log
    /// fell off the bottom of the ladder and the chart drew nothing forward.
    ///
    /// The exemption is safe on its own terms: one lag has one real root, so the only thing it
    /// can oscillate at is period 2, and the tide has no two-hour component.
    func testAnAlternatingLogStillFitsOnTheOneLagRung() {
        let start = Date(timeIntervalSince1970: 1_756_000_000)
        let samples = (0...11).map { hour in
            PressureSample(
                timestamp: start.addingTimeInterval(TimeInterval(hour) * 3600),
                pressure: Pressure(hectopascals: 1013 + (hour.isMultiple(of: 2) ? 0.5 : -0.5))
            )
        }
        let now = start.addingTimeInterval(11 * 3600)

        guard let model = LocalPressureModel.fit(to: samples, asOf: now) else {
            return XCTFail("the one-lag rung is the floor; falling through it draws no curve")
        }

        XCTAssertEqual(model.specification.tendencyLags, 1)
        XCTAssertLessThan(model.coefficients[0], 0,
                          "anti-persistent noise is what this log is, and it may say so")
        XCTAssertFalse(model.forecast(asOf: now, horizonSeconds: 6 * 3600).isEmpty)
    }

    /// The exemption stops at one lag. Two lags can carry a complex pair, which is a cycle, and
    /// a cycle in a rung with no harmonics is the tide in the wrong place — still refused.
    func testTheExemptionDoesNotReachTheTwoLagRung() {
        XCTAssertTrue(LocalPressureModel.tendencyReversesWithinTideHorizon([1.804, -0.899]),
                      "a 20-hour oscillation is still an oscillation")
    }
}
