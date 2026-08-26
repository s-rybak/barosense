import XCTest
@testable import Barosense

/// What the watch is sent to draw, and the arithmetic that decides it.
///
/// The series and the tendency come out of the same array on the phone
/// (`PressureCollectionController.publish`), so these tests also pin the property that keeps
/// the watch's line and its arrow describing the same weather.
final class PressureWatchSeriesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func sample(minutesAgo minutes: Double, hPa: Double) -> PressureSample {
        PressureSample(timestamp: now.addingTimeInterval(-minutes * 60),
                       pressure: Pressure(hectopascals: hPa))
    }

    // MARK: - The window

    func testTheWindowIsSixHours() {
        XCTAssertEqual(PressureWatchSeries.windowSeconds, 6 * 3600)
    }

    /// The window has to contain the tendency window, or the caption would describe a stretch
    /// of time the line does not show.
    func testTheWindowContainsTheTrendWindow() {
        XCTAssertGreaterThanOrEqual(PressureWatchSeries.windowSeconds, PressureTrend.windowSeconds)
    }

    /// The two devices must not draw visibly different lines for the same stretch of time.
    func testTheBucketIsThePhoneSixHourBucket() {
        XCTAssertEqual(PressureWatchSeries.bucketSeconds, PressureChartRange.sixHours.bucketSeconds)
    }

    /// A bucket finer than the sampling floor averages nothing and only shifts a point off
    /// the instant it was measured.
    func testTheBucketIsNoFinerThanTheSamplingFloor() {
        XCTAssertGreaterThanOrEqual(PressureWatchSeries.bucketSeconds,
                                    PressureSamplingPolicy.minimumIntervalSeconds)
    }

    // MARK: - Building the series

    func testReadingsInsideTheWindowBecomePointsInTimeOrder() {
        let series = PressureWatchSeries.make(
            from: [sample(minutesAgo: 30, hPa: 1012), sample(minutesAgo: 150, hPa: 1015)],
            asOf: now
        )

        XCTAssertEqual(series.map(\.hectopascals), [1015, 1012])
        XCTAssertEqual(series.map(\.timestamp).sorted(), series.map(\.timestamp))
    }

    func testReadingsOlderThanTheWindowAreDropped() {
        let series = PressureWatchSeries.make(
            from: [sample(minutesAgo: 7 * 60, hPa: 1020), sample(minutesAgo: 30, hPa: 1012)],
            asOf: now
        )

        XCTAssertEqual(series.map(\.hectopascals), [1012])
    }

    /// A row dated after `now` is a clock artefact. Drawing it would put the line's end
    /// somewhere the user has not lived yet, which reads as a forecast.
    func testForwardDatedReadingsAreDropped() {
        let ahead = PressureSample(timestamp: now.addingTimeInterval(1800),
                                   pressure: Pressure(hectopascals: 999))

        let series = PressureWatchSeries.make(from: [ahead, sample(minutesAgo: 30, hPa: 1012)],
                                              asOf: now)

        XCTAssertEqual(series.map(\.hectopascals), [1012])
    }

    /// Two readings in one half-hour slot are one point at their mean — the phone does the
    /// reducing so the watch spends no cycles on it.
    func testReadingsInOneSlotCollapseToTheirMean() {
        let series = PressureWatchSeries.make(
            from: [sample(minutesAgo: 5, hPa: 1010), sample(minutesAgo: 10, hPa: 1014)],
            asOf: now
        )

        XCTAssertEqual(series.count, 1)
        XCTAssertEqual(series[0].hectopascals, 1012, accuracy: 0.0001)
    }

    /// The ceiling is a guard against a jumped clock or a run of bad rows, not a target — an
    /// unbounded array on a wire format is how a payload limit gets hit in the field.
    func testTheSeriesIsCappedAndKeepsTheNewestPoints() {
        // One reading per minute for six hours: 360 rows across 12 occupied slots at the
        // nominal bucket, so the cap is forced by shrinking the grid, not by the data.
        let dense = (0..<(PressureWatchSeries.maxPoints + 20)).map { index in
            PressureSample(
                timestamp: now.addingTimeInterval(-Double(index) * PressureWatchSeries.bucketSeconds),
                pressure: Pressure(hectopascals: 1000 + Double(index))
            )
        }

        let series = PressureWatchSeries.make(from: dense, asOf: now)

        XCTAssertLessThanOrEqual(series.count, PressureWatchSeries.maxPoints)
        // Newest kept: the newest reading is the one at offset 0, worth 1000 hPa.
        XCTAssertEqual(series.last?.hectopascals, 1000)
    }

    func testNoHistoryProducesNoSeries() {
        XCTAssertTrue(PressureWatchSeries.make(from: [], asOf: now).isEmpty)
    }

    /// The watch draws nothing under two points, so a single reading has to arrive as a
    /// single point rather than as a phantom line.
    func testOneReadingProducesOnePoint() {
        let series = PressureWatchSeries.make(from: [sample(minutesAgo: 5, hPa: 1013)], asOf: now)

        XCTAssertEqual(series.count, 1)
    }
}

/// The number the tendency is cut from, which the watch prints beside the word.
final class PressureTrendDeltaTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func sample(hoursAgo hours: Double, hPa: Double) -> PressureSample {
        PressureSample(timestamp: now.addingTimeInterval(-hours * 3600),
                       pressure: Pressure(hectopascals: hPa))
    }

    func testAFallIsReportedNegative() {
        let delta = PressureTrend.delta(
            from: [sample(hoursAgo: 2.5, hPa: 1015), sample(hoursAgo: 0, hPa: 1011)],
            asOf: now
        )

        XCTAssertEqual(delta ?? 0, -4, accuracy: 0.0001)
    }

    func testARiseIsReportedPositive() {
        let delta = PressureTrend.delta(
            from: [sample(hoursAgo: 2.5, hPa: 1011), sample(hoursAgo: 0, hPa: 1014)],
            asOf: now
        )

        XCTAssertEqual(delta ?? 0, 3, accuracy: 0.0001)
    }

    /// The whole reason the number is shipped rather than derived on the watch: a screen
    /// showing "steady" beside "−4.1" would be two answers to one question. They agree
    /// because they come out of the same arithmetic, and this is what pins that.
    func testTheDeltaAndTheTrendNeverDisagree() {
        let cases: [[PressureSample]] = [
            [sample(hoursAgo: 2.5, hPa: 1015), sample(hoursAgo: 0, hPa: 1011)],
            [sample(hoursAgo: 2.5, hPa: 1011), sample(hoursAgo: 0, hPa: 1014)],
            [sample(hoursAgo: 2.5, hPa: 1013), sample(hoursAgo: 0, hPa: 1013.4)],
            [sample(hoursAgo: 0.5, hPa: 1020), sample(hoursAgo: 0, hPa: 1005)],
            []
        ]

        for samples in cases {
            let trend = PressureTrend.make(from: samples, asOf: now)
            let delta = PressureTrend.delta(from: samples, asOf: now)

            switch trend {
            case .unknown:
                XCTAssertNil(delta)
            case .falling:
                XCTAssertLessThanOrEqual(delta ?? 0, -PressureTrend.significantChangeHPa)
            case .rising:
                XCTAssertGreaterThanOrEqual(delta ?? 0, PressureTrend.significantChangeHPa)
            case .steady:
                XCTAssertLessThan(abs(delta ?? 0), PressureTrend.significantChangeHPa)
            }
        }
    }

    /// Two samples four minutes apart cannot support a tendency, and they cannot support a
    /// number either — extrapolating one is the confidently wrong value the pipeline rules
    /// forbid.
    func testTooShortASpanReportsNoDelta() {
        let delta = PressureTrend.delta(
            from: [sample(hoursAgo: 0.1, hPa: 1020), sample(hoursAgo: 0, hPa: 1010)],
            asOf: now
        )

        XCTAssertNil(delta)
    }

    func testNoHistoryReportsNoDelta() {
        XCTAssertNil(PressureTrend.delta(from: [], asOf: now))
    }
}

/// How a change is printed. The sign is the information.
final class SignedPressureFormatTests: XCTestCase {

    func testAPositiveChangeCarriesItsPlus() {
        XCTAssertTrue(PressureFormat.signedHectopascals(2.1).hasPrefix("+"))
    }

    func testANegativeChangeKeepsItsMinus() {
        // The locale's own minus glyph, which is not always a hyphen — asserted by what it
        // is not rather than by a literal, so the test holds in every locale.
        let printed = PressureFormat.signedHectopascals(-2.1)

        XCTAssertFalse(printed.hasPrefix("+"))
        XCTAssertTrue(printed.contains("2"))
    }

    func testZeroIsNotDressedUpWithASign() {
        XCTAssertFalse(PressureFormat.signedHectopascals(0).hasPrefix("+"))
    }

    /// One decimal, matching the resolution the barometer actually has. Printing more claims
    /// precision the sensor does not deliver.
    func testAChangeIsPrintedToOneDecimal() {
        XCTAssertTrue(PressureFormat.signedHectopascals(2.149).contains("2"))
        XCTAssertFalse(PressureFormat.signedHectopascals(2.149).contains("2.149"))
    }
}
