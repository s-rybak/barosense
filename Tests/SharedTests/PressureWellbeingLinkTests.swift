import XCTest
@testable import Barosense

/// The correlation the Insights screen prints, and the three ways it refuses to print one.
final class PressureWellbeingLinkTests: XCTestCase {

    /// Fixed, so the fixture's own hours do not move with the machine running the test.
    private let start = Date(timeIntervalSince1970: 1_740_960_000)

    private var now: Date { start.addingTimeInterval(hours: 10 * 24) }

    // MARK: - Finding the lag

    /// A log built so that a six-hour fall is followed six hours later by a heavier entry.
    /// The search has to land on that lag and report the association as positive.
    func testFindsTheLagTheLogWasBuiltWith() throws {
        let samples = wave()
        let checkIns = entriesDriven(by: samples, lagHours: 6, byHours: 6)

        let link = try XCTUnwrap(PressureWellbeingLink.make(checkIns: checkIns,
                                                            samples: samples,
                                                            asOf: now))

        XCTAssertEqual(link.lagHours, 6)
        XCTAssertGreaterThan(link.coefficient, 0.8)
        XCTAssertTrue(link.isFallLeading)
        XCTAssertEqual(link.strength, .strong)
        XCTAssertEqual(link.pairCount, checkIns.count)
    }

    /// The same trace with the relationship inverted: heavier entries follow a *rise*.
    ///
    /// The coefficient has to come back **negative** rather than being flipped to keep the card
    /// reading positively. Some people's log runs this way and telling them otherwise would be
    /// reporting something the data did not say.
    func testAnInvertedLogReportsANegativeCoefficient() throws {
        let samples = wave()
        let checkIns = entriesDriven(by: samples, lagHours: 6, byHours: 6, inverted: true)

        let link = try XCTUnwrap(PressureWellbeingLink.make(checkIns: checkIns,
                                                            samples: samples,
                                                            asOf: now))

        XCTAssertLessThan(link.coefficient, -0.8)
        XCTAssertFalse(link.isFallLeading)
    }

    // MARK: - The three refusals

    /// Below `minimumPairs` there is no figure, however clean the relationship is.
    func testTooFewPairsProduceNothing() {
        let samples = wave()
        let checkIns = Array(entriesDriven(by: samples, lagHours: 6, byHours: 6)
            .prefix(PressureWellbeingLink.minimumPairs - 1))

        XCTAssertEqual(checkIns.count, PressureWellbeingLink.minimumPairs - 1)
        XCTAssertNil(PressureWellbeingLink.make(checkIns: checkIns, samples: samples, asOf: now))
    }

    /// A user who logs the same number every time. There is no correlation to report, and a
    /// printed `0.00` would read as "measured, no relationship" — see `pearson`.
    func testAFlatScaleProducesNothing() {
        let samples = wave()
        let checkIns = entriesDriven(by: samples, lagHours: 6, byHours: 6).map {
            CheckIn(id: $0.id, timestamp: $0.timestamp, intensity: CheckInIntensity(clamping: 5))
        }

        XCTAssertNil(PressureWellbeingLink.make(checkIns: checkIns, samples: samples, asOf: now))
    }

    /// Dead-calm weather. Same rule from the other side: the pressure column does not vary, so
    /// there is nothing for the scale to line up against.
    func testFlatWeatherProducesNothing() {
        let samples = (0..<(10 * 24)).map { hour in
            PressureSample(timestamp: start.addingTimeInterval(hours: Double(hour)),
                           pressure: Pressure(hectopascals: 1013))
        }
        let checkIns = (0..<20).map { index in
            CheckIn(timestamp: start.addingTimeInterval(hours: 30 + Double(index) * 6),
                    intensity: CheckInIntensity(clamping: 1 + index % 10))
        }

        XCTAssertNil(PressureWellbeingLink.make(checkIns: checkIns, samples: samples, asOf: now))
    }

    /// An empty log is the ordinary state of a fresh install, not an error.
    func testAnEmptyLogProducesNothing() {
        XCTAssertNil(PressureWellbeingLink.make(checkIns: [], samples: [], asOf: now))
    }

    // MARK: - Bands

    /// Cohen's cut points, and the fact that the band reads off the **magnitude**: a strong
    /// negative association is a strong one.
    func testStrengthBandsReadTheMagnitude() {
        XCTAssertEqual(link(0.29).strength, .weak)
        XCTAssertEqual(link(0.3).strength, .moderate)
        XCTAssertEqual(link(0.49).strength, .moderate)
        XCTAssertEqual(link(0.5).strength, .strong)
        XCTAssertEqual(link(-0.72).strength, .strong)
        XCTAssertFalse(link(-0.72).isFallLeading)
    }

    // MARK: - Fixture

    private func link(_ coefficient: Double) -> PressureWellbeingLink {
        PressureWellbeingLink(coefficient: coefficient, lagHours: 6, pairCount: 20)
    }

    /// Ten days of hourly pressure on a 48-hour wave.
    ///
    /// A wave rather than a straight ramp so the six-hour change itself varies in sign and
    /// size; on a ramp every pair carries the same *x* and there is no correlation to find.
    private func wave() -> [PressureSample] {
        (0..<(10 * 24)).map { hour in
            let value = 1010 + 5 * sin(2 * Double.pi * Double(hour) / 48)
            return PressureSample(timestamp: start.addingTimeInterval(hours: Double(hour)),
                                  pressure: Pressure(hectopascals: value))
        }
    }

    /// Entries whose intensity is a monotone function of the fall that preceded them.
    ///
    /// `lagHours` is the delay the entry is placed at; `byHours` is the spacing between
    /// entries. The mapping is deliberately rounded onto the 1–10 scale, so the correlation
    /// that comes back is high and not 1.0 — a fixture that produced exactly 1.0 would be
    /// testing the arithmetic rather than the method.
    private func entriesDriven(by samples: [PressureSample],
                               lagHours: Int,
                               byHours: Int,
                               inverted: Bool = false) -> [CheckIn] {
        let byHour = Dictionary(samples.map { ($0.timestamp, $0.pressure.hectopascals) },
                                uniquingKeysWith: { first, _ in first })

        return stride(from: 30, to: 10 * 24 - 6, by: byHours).compactMap { hour -> CheckIn? in
            let stamp = start.addingTimeInterval(hours: Double(hour))
            let anchor = stamp.addingTimeInterval(hours: -Double(lagHours))
            let earlier = anchor.addingTimeInterval(
                hours: -Double(PressureWellbeingLink.changeWindowHours)
            )

            guard let atAnchor = byHour[anchor], let atEarlier = byHour[earlier] else { return nil }

            // Full scale of the wave's six-hour change is about ±5 hPa; mapped onto 1–10.
            let fall = (atEarlier - atAnchor) * (inverted ? -1 : 1)
            let position = (fall + 5) / 10

            return CheckIn(timestamp: stamp, intensity: CheckInIntensity(position: position))
        }
    }
}

private extension Date {
    func addingTimeInterval(hours: Double) -> Date {
        addingTimeInterval(hours * 3600)
    }
}
