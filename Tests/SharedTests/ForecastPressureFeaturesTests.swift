import XCTest
@testable import Barosense

/// The §2.2 feature family, and the rule that keeps it honest.
final class ForecastPressureFeaturesTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    private let offset = PressureOffset(offsetHPa: -22,
                                        referenceTemperatureC: 15,
                                        pairCount: 24,
                                        uncertaintyHPa: 0.2)

    // MARK: - The leak guard

    /// **The main test of PR 4.** A feature computed at `t` may read only issues made at or
    /// before `t`. Let a newer issue through and "the forecast for 14:00 last Tuesday" becomes
    /// hindsight: the model then validates beautifully and collapses in production, which is
    /// the random-split failure in different clothes.
    func testAFeatureAtTCannotSeeAnIssueMadeAfterT() {
        let stale = curve(issuedAt: now.addingTimeInterval(-3600), deltaPerHour: -0.2)
        // A far better forecast, issued an hour into the future. It must not appear at all.
        let future = curve(issuedAt: now.addingTimeInterval(3600), deltaPerHour: -3.0)

        let features = ForecastFeatureExtractor.extract(from: stale + future, at: now)

        XCTAssertEqual(features.forecastPressureDeltaHPaPer6h ?? 0, -1.2, accuracy: 0.001)
        XCTAssertEqual(features.forecastIssueAgeSeconds ?? 0, 3600, accuracy: 0.001)
    }

    /// And the same rule through the store-backed path, which is the one the app uses.
    func testTheStoreBackedPathAppliesTheSameRule() async throws {
        let archive = InMemoryWeatherForecastStore()
        try await archive.save(archived(issuedAt: now.addingTimeInterval(-3600), deltaPerHour: -0.2))
        try await archive.save(archived(issuedAt: now.addingTimeInterval(3600), deltaPerHour: -3.0))

        let features = try await ForecastFeatureExtractor.extract(from: archive,
                                                                  offset: offset,
                                                                  at: now)

        XCTAssertEqual(features.forecastPressureDeltaHPaPer6h ?? 0, -1.2, accuracy: 0.001)
    }

    /// Two issues covering the same hour: the newest **knowable** one wins, not the newest one
    /// in the table.
    func testTheNewestKnowableIssueWinsPerHour() {
        let older = curve(issuedAt: now.addingTimeInterval(-6 * 3600), deltaPerHour: -0.1)
        let newer = curve(issuedAt: now.addingTimeInterval(-1800), deltaPerHour: -0.5)

        let features = ForecastFeatureExtractor.extract(from: older + newer, at: now)

        XCTAssertEqual(features.forecastPressureDeltaHPaPer6h ?? 0, -3.0, accuracy: 0.001)
        XCTAssertEqual(features.forecastIssueAgeSeconds ?? 0, 1800, accuracy: 0.001)
    }

    // MARK: - Absence

    /// Acceptance criterion 2. A curve that reaches six hours cannot answer a twelve-hour
    /// question, and the answer is `nil` rather than a line extended past what the producer
    /// said. In the WeatherKit-off case that is the ordinary reading of this whole family.
    func testHorizonsPastTheSourcesRangeAreNilRatherThanExtrapolated() {
        let local = curve(issuedAt: now,
                          deltaPerHour: -0.4,
                          hours: 6,
                          source: .localModel)

        let features = ForecastFeatureExtractor.extract(from: local, at: now)

        XCTAssertEqual(features.forecastPressureDeltaHPaPer6h ?? 0, -2.4, accuracy: 0.001)
        XCTAssertNil(features.forecastPressureDeltaHPaPer12h)
        XCTAssertNil(features.forecastPressureDeltaHPaPer24h)
        // The 24 h minimum is over what exists, and six hours of curve is not 24 h of evidence.
        XCTAssertNotNil(features.forecastMinPressureHPaNext24h)
        XCTAssertEqual(features.forecastSource, .localModel)
    }

    /// A hole in the curve is a hole in what the producer said. Interpolating across it would
    /// be the "confidently wrong value" §2.1 rules out; that convenience stays on the chart.
    func testAHoleInTheCurveLeavesTheFeatureNil() {
        let punctured = curve(issuedAt: now, deltaPerHour: -0.3)
            .filter { point in
                let hoursAhead = point.timestamp.timeIntervalSince(now) / 3600
                return !(hoursAhead > 4.5 && hoursAhead < 8.5)
            }

        let features = ForecastFeatureExtractor.extract(from: punctured, at: now)

        XCTAssertNil(features.forecastPressureDeltaHPaPer6h)
        XCTAssertNotNil(features.forecastPressureDeltaHPaPer12h)
    }

    /// Nothing knowable at all — no location grant, WeatherKit off, a fresh install. Every
    /// field absent, and no crash.
    func testAnEmptyCurveYieldsTheUnavailableRow() {
        XCTAssertEqual(ForecastFeatureExtractor.extract(from: [], at: now), .unavailable)
    }

    func testNoOffsetMeansNoFeatures() async throws {
        let archive = InMemoryWeatherForecastStore()
        try await archive.save(archived(issuedAt: now, deltaPerHour: -0.3))

        let features = try await ForecastFeatureExtractor.extract(from: archive,
                                                                  offset: nil,
                                                                  at: now)

        XCTAssertEqual(features, .unavailable)
    }

    // MARK: - The quality fields

    /// Not bookkeeping. Coefficients fitted on WeatherKit-quality inputs and applied to the
    /// local model's curve would be applied with the same confidence and never learn the input
    /// had got worse.
    func testTheVectorCarriesWhoProducedItAndHowUncertainItIs() {
        let weatherKit = ForecastFeatureExtractor.extract(from: curve(issuedAt: now,
                                                                      deltaPerHour: -0.3),
                                                          at: now)
        let local = ForecastFeatureExtractor.extract(from: curve(issuedAt: now,
                                                                  deltaPerHour: -0.3,
                                                                  hours: 6,
                                                                  source: .localModel),
                                                     at: now)

        XCTAssertEqual(weatherKit.forecastSource, .weatherKit)
        XCTAssertEqual(local.forecastSource, .localModel)
        guard let weatherKitBand = weatherKit.forecastUncertaintyHPa,
              let localBand = local.forecastUncertaintyHPa else {
            return XCTFail("both sources must report a band")
        }
        XCTAssertGreaterThan(localBand, weatherKitBand)
    }

    /// Quoted at a fixed horizon so the number means the same thing on every row: it describes
    /// input quality, and a value that moved with whichever horizon happened to be available
    /// would confound quality with coverage.
    func testTheBandIsQuotedAtAFixedHorizonRatherThanTheLongestAvailable() {
        let short = ForecastFeatureExtractor.extract(from: curve(issuedAt: now,
                                                                  deltaPerHour: -0.3,
                                                                  hours: 6),
                                                     at: now)
        let long = ForecastFeatureExtractor.extract(from: curve(issuedAt: now,
                                                                 deltaPerHour: -0.3,
                                                                 hours: 24),
                                                    at: now)

        XCTAssertEqual(short.forecastUncertaintyHPa, long.forecastUncertaintyHPa)
    }

    // MARK: - Values

    func testTheMinimumIsTakenOverTheNextTwentyFourHoursOnly() {
        // Falls for twelve hours, then climbs back past where it started.
        var points = curve(issuedAt: now, deltaPerHour: -0.5, hours: 12)
        points += (13...30).map { hour in
            ForecastPressurePoint(timestamp: now.addingTimeInterval(TimeInterval(hour) * 3600),
                                  pressure: Pressure(hectopascals: 991 - 6 + Double(hour - 12) * 0.5),
                                  uncertaintyHPa: 1,
                                  source: .weatherKit,
                                  issuedAt: now)
        }

        let features = ForecastFeatureExtractor.extract(from: points, at: now)

        XCTAssertEqual(features.forecastMinPressureHPaNext24h ?? 0, 985, accuracy: 0.001)
    }

    /// The deltas are measured against the hour containing `t`, from the same curve — not
    /// against a barometer reading. Mixing the two would put a station value and a calibrated
    /// forecast value into one subtraction and bake the offset's residual into every delta.
    func testDeltasAreMeasuredAgainstTheCurvesOwnAnchorHour() {
        let features = ForecastFeatureExtractor.extract(from: curve(issuedAt: now,
                                                                     deltaPerHour: -0.25),
                                                        at: now)

        XCTAssertEqual(features.forecastPressureDeltaHPaPer6h ?? 0, -1.5, accuracy: 0.001)
        XCTAssertEqual(features.forecastPressureDeltaHPaPer12h ?? 0, -3.0, accuracy: 0.001)
        XCTAssertEqual(features.forecastPressureDeltaHPaPer24h ?? 0, -6.0, accuracy: 0.001)
    }

    // MARK: - Fixtures

    /// An hourly curve from `now` to `now + hours`, starting at 991 hPa (Kyiv station pressure)
    /// and moving by `deltaPerHour`.
    private func curve(issuedAt: Date,
                       deltaPerHour: Double,
                       hours: Int = 24,
                       source: ForecastSource = .weatherKit) -> [ForecastPressurePoint] {
        (0...hours).map { hour in
            ForecastPressurePoint(
                timestamp: now.addingTimeInterval(TimeInterval(hour) * 3600),
                pressure: Pressure(hectopascals: 991 + deltaPerHour * Double(hour)),
                uncertaintyHPa: source.uncertaintyHPa(atLeadSeconds: TimeInterval(hour) * 3600),
                source: source,
                issuedAt: issuedAt
            )
        }
    }

    /// The same curve as raw archive rows — MSLP, so the calibrated result matches `curve`.
    private func archived(issuedAt: Date, deltaPerHour: Double) -> [WeatherForecastPoint] {
        (0...24).map { hour in
            WeatherForecastPoint(
                issuedAt: issuedAt,
                validAt: now.addingTimeInterval(TimeInterval(hour) * 3600),
                meanSeaLevelPressureHPa: 1013 + deltaPerHour * Double(hour),
                temperatureC: 15
            )
        }
    }
}
