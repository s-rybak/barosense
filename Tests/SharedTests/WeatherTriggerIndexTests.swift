import XCTest
@testable import Barosense

/// The weather index. The arithmetic is four lines; what needs pinning is the two things it
/// refuses to do — report a figure off a window it barely saw, and report movement that is
/// really sensor noise.
final class WeatherTriggerIndexTests: XCTestCase {

    // MARK: - Scale

    func testAFullScaleFallReadsAsOne() {
        let index = makeIndex(from: fullWindow(startHPa: 1015, endHPa: 1015 - WeatherTriggerIndex.fullScaleHPa))

        XCTAssertEqual(index?.value, 1.0)
    }

    func testAFullScaleRiseReadsTheSameAsAFall() {
        // The index is unsigned: it says how far the weather moved, not which way. `deltaHPa`
        // is where the direction survives.
        let rise = makeIndex(from: fullWindow(startHPa: 1000,
                                              endHPa: 1000 + WeatherTriggerIndex.fullScaleHPa))
        let fall = makeIndex(from: fullWindow(startHPa: 1000,
                                              endHPa: 1000 - WeatherTriggerIndex.fullScaleHPa))

        XCTAssertEqual(rise?.value, fall?.value)
        XCTAssertEqual(rise?.deltaHPa ?? 0, WeatherTriggerIndex.fullScaleHPa, accuracy: 0.0001)
        XCTAssertEqual(fall?.deltaHPa ?? 0, -WeatherTriggerIndex.fullScaleHPa, accuracy: 0.0001)
    }

    func testMovementUnderTheNoiseFloorReadsAsZero() {
        // Not "a small number". The chart's caption calls this same window steady, and the two
        // surfaces must not disagree about where weather starts.
        let barelyMoved = WeatherTriggerIndex.noiseFloorHPa / 2
        let index = makeIndex(from: fullWindow(startHPa: 1008, endHPa: 1008 - barelyMoved))

        XCTAssertEqual(index?.value, 0)
    }

    func testTheNoiseFloorItselfIsStillZero() {
        let index = makeIndex(from: fullWindow(startHPa: 1008,
                                               endHPa: 1008 - WeatherTriggerIndex.noiseFloorHPa))

        XCTAssertEqual(index?.value, 0)
    }

    func testHalfwayBetweenTheFloorAndFullScaleReadsAsAHalf() {
        let midpoint = (WeatherTriggerIndex.noiseFloorHPa + WeatherTriggerIndex.fullScaleHPa) / 2
        let index = makeIndex(from: fullWindow(startHPa: 1020, endHPa: 1020 - midpoint))

        XCTAssertEqual(index?.value ?? 0, 0.5, accuracy: 0.0001)
    }

    func testAMovementPastFullScaleIsClampedRatherThanOverflowing() {
        let index = makeIndex(from: fullWindow(startHPa: 1030, endHPa: 1000))

        XCTAssertEqual(index?.value, 1.0)
    }

    // MARK: - Coverage

    func testAWindowWithNothingInItHasNoIndex() {
        XCTAssertNil(WeatherTriggerIndex.make(from: [], asOf: now))
    }

    func testTwoReadingsMinutesApartDoNotSupportAnIndex() {
        // The failure this gate exists for: a 3 hPa gap between two samples eight minutes apart
        // is a sensor glitch or a lift, and scaling it into a full bar is the confidently-wrong
        // value the pipeline rules forbid.
        let samples = [
            sample(minutesAgo: 8, hectopascals: 1013),
            sample(minutesAgo: 0, hectopascals: 1010)
        ]

        XCTAssertNil(WeatherTriggerIndex.make(from: samples, asOf: now))
    }

    func testCoverageIsCountedInHourlyCellsNotInReadings() {
        // Twelve readings, all inside one hour: one cell of six, well under the minimum.
        let crowded = (0..<12).map { sample(minutesAgo: Double($0) * 4, hectopascals: 1013 - Double($0) / 4) }

        XCTAssertNil(WeatherTriggerIndex.make(from: crowded, asOf: now))
    }

    func testExactlyTheMinimumCoverageIsEnough() {
        let samples = [0.5, 1.5, 2.5].map { sample(hoursAgo: $0, hectopascals: 1013) }
        let index = WeatherTriggerIndex.make(from: samples, asOf: now)

        XCTAssertNotNil(index)
        XCTAssertEqual(index?.coverage ?? 0, WeatherTriggerIndex.minimumCoverage, accuracy: 0.0001)
    }

    func testAFullyObservedWindowReportsFullCoverage() {
        XCTAssertEqual(makeIndex(from: fullWindow(startHPa: 1013, endHPa: 1013))?.coverage, 1)
    }

    // MARK: - Window

    func testReadingsOlderThanTheWindowAreIgnored() {
        // One store read serves this and the chart, so the input reaches much further back than
        // six hours. A reading from yesterday must not become the start of today's delta.
        let stale = sample(hoursAgo: 20, hectopascals: 980)
        let index = makeIndex(from: [stale] + fullWindow(startHPa: 1013, endHPa: 1013))

        XCTAssertEqual(index?.deltaHPa ?? .nan, 0, accuracy: 0.0001)
    }

    func testUnsortedInputGivesTheSameAnswerAsSortedInput() {
        let ordered = fullWindow(startHPa: 1018, endHPa: 1014)

        XCTAssertEqual(WeatherTriggerIndex.make(from: ordered, asOf: now),
                       WeatherTriggerIndex.make(from: ordered.reversed(), asOf: now))
    }

    func testTheDeltaIsNotScaledUpToTheFullWindow() {
        // Three hours of a six-hour window, moved by 3 hPa. Extrapolating would report 6 and a
        // full bar; the raw delta reports 3.
        let samples = [3.0, 2.0, 1.0, 0.0].map { hoursAgo in
            sample(hoursAgo: hoursAgo, hectopascals: 1013 - (3 - hoursAgo))
        }
        let index = WeatherTriggerIndex.make(from: samples, asOf: now)

        XCTAssertEqual(index?.deltaHPa ?? .nan, -3, accuracy: 0.0001)
        XCTAssertLessThan(index?.value ?? 1, 1)
    }

    // MARK: - Agreement with the chart caption

    func testTheFloorIsTheSameRateTheChartCallsSignificant() {
        // Both surfaces describe the same weather. If these drift apart, the chart says "steady"
        // while the card draws a bar, on the same six hours.
        XCTAssertEqual(WeatherTriggerIndex.noiseFloorHPa,
                       PressureTrend.significantChangeHPa * 2)
    }

    func testTheWindowIsTheOneTheFeatureRegistryDefines() {
        XCTAssertEqual(WeatherTriggerIndex.windowSeconds, 6 * 3600)
    }

    // MARK: - Helpers

    /// Fixed to the top of an hour, so a test's six-hour window lines up with the hourly cells
    /// coverage is counted in and does not straddle a boundary differently on each run.
    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func makeIndex(from samples: [PressureSample]) -> WeatherTriggerIndex? {
        WeatherTriggerIndex.make(from: samples, asOf: now)
    }

    /// One reading in every hourly cell of the window, moving linearly from `startHPa` to
    /// `endHPa`.
    private func fullWindow(startHPa: Double, endHPa: Double) -> [PressureSample] {
        let steps = 5
        return (0...steps).map { step in
            let progress = Double(step) / Double(steps)
            return sample(hoursAgo: 5 - Double(step),
                          hectopascals: startHPa + (endHPa - startHPa) * progress)
        }
    }

    private func sample(hoursAgo: Double = 0,
                        minutesAgo: Double = 0,
                        hectopascals: Double) -> PressureSample {
        PressureSample(timestamp: now.addingTimeInterval(-(hoursAgo * 3600 + minutesAgo * 60)),
                       pressure: Pressure(hectopascals: hectopascals))
    }
}
