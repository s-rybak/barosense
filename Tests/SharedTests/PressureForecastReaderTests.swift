import XCTest
@testable import Barosense

/// The object the chart, the feature row and the skill report all read through.
///
/// The point of these tests is that there is **one** fall-through, not three. The chart, the
/// §2.2 family and the realised-skill comparison are all built on the same curve, so a device
/// that has fallen back to the local model cannot show one producer and report another
/// (`.claude/context/pressure-forecast-spec.md` §2.3).
final class PressureForecastReaderTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// The Kyiv-ish station-to-MSLP difference the fixtures are built around.
    private let offsetHPa: Double = -22

    // MARK: - Which producer answered

    func testFeaturesComeFromWeatherKitWhileTheArchiveIsFresh() async throws {
        let reader = try await makeReader(issuedAt: now.addingTimeInterval(-3600))

        let features = await reader.features(asOf: now)

        XCTAssertEqual(features.forecastSource, .weatherKit)
        XCTAssertNotNil(features.forecastPressureDeltaHPaPer6h)
        XCTAssertNotNil(features.forecastPressureDeltaHPaPer24h)
        XCTAssertEqual(features.forecastIssueAgeSeconds ?? 0, 3600, accuracy: 1)
    }

    /// The state this whole fix is about. The archive still holds rows — it is kept for 90 days
    /// and one issue reaches 240 h ahead — but they are past the staleness norm, so the family
    /// comes from the local model and **says so**. Before the gate it kept reporting WeatherKit,
    /// with a WeatherKit-sized band, from a run nobody had recomputed in days.
    func testFeaturesFallThroughToTheLocalModelWhenTheArchiveIsStale() async throws {
        let stale = now.addingTimeInterval(-WeatherForecastPolicy.maximumIssueAgeSeconds - 3600)
        let reader = try await makeReader(issuedAt: stale)

        let features = await reader.features(asOf: now)

        XCTAssertEqual(features.forecastSource, .localModel)
        XCTAssertNotNil(features.forecastPressureDeltaHPaPer6h)
        XCTAssertNil(features.forecastPressureDeltaHPaPer12h,
                     "a six-hour producer cannot answer a twelve-hour question")
        XCTAssertNil(features.forecastPressureDeltaHPaPer24h)
    }

    /// The one place the picture and the feature row are allowed to differ, and the reason
    /// `rangeSeconds` and `skillRangeSeconds` are two constants. A device on the local model
    /// draws 18 h, so the day button has something to show; the vector still stops at 6 h,
    /// because moving a chart's range is not a skill measurement. Without the clip the same
    /// eighteen-step extrapolation would fill `Per12h` and be trained on as if it were
    /// WeatherKit's.
    func testTheChartIsDrawnFurtherThanTheFeatureRowIsLearnedFrom() async throws {
        let stale = now.addingTimeInterval(-WeatherForecastPolicy.maximumIssueAgeSeconds - 3600)
        let reader = try await makeReader(issuedAt: stale)

        let widest = PressureChartRange.widest.maximumForecastSeconds
        let curve = await reader.forecast(asOf: now, horizonSeconds: widest)
        let features = await reader.features(asOf: now)

        XCTAssertEqual(curve.first?.source, .localModel)
        // Hourly points from the last observed hour, which is inside the hour before `now`.
        let reach = curve.last?.timestamp.timeIntervalSince(now) ?? 0
        XCTAssertGreaterThan(reach, ForecastSource.localModel.rangeSeconds - 3600)
        XCTAssertLessThanOrEqual(reach, ForecastSource.localModel.rangeSeconds)

        XCTAssertNotNil(features.forecastPressureDeltaHPaPer6h)
        XCTAssertNil(features.forecastPressureDeltaHPaPer12h,
                     "the drawn range moved; the learned range did not")
    }

    /// And the chart agrees with the feature row about who is speaking — that is the whole
    /// reason both go through `forecast(asOf:horizonSeconds:anchoredAtNow:)`.
    func testTheChartAndTheFeatureRowNameTheSameProducer() async throws {
        let stale = now.addingTimeInterval(-WeatherForecastPolicy.maximumIssueAgeSeconds - 3600)
        let reader = try await makeReader(issuedAt: stale)

        let curve = await reader.forecast(asOf: now, horizonSeconds: 12 * 3600)
        let features = await reader.features(asOf: now)

        XCTAssertEqual(curve.first?.source, features.forecastSource)
    }

    /// The band travels with the source. A model handed the local producer's curve has to be
    /// able to see that its input got noisier, which is what `forecastUncertaintyHPa` is for.
    func testTheLocalFamilyCarriesAWiderBandThanTheWeatherKitOne() async throws {
        let fresh = try await makeReader(issuedAt: now.addingTimeInterval(-3600))
        let stale = try await makeReader(
            issuedAt: now.addingTimeInterval(-WeatherForecastPolicy.maximumIssueAgeSeconds - 3600)
        )

        let fromWeatherKit = await fresh.features(asOf: now)
        let fromLocal = await stale.features(asOf: now)

        XCTAssertGreaterThan(fromLocal.forecastUncertaintyHPa ?? 0,
                             fromWeatherKit.forecastUncertaintyHPa ?? 0)
    }

    // MARK: - Realised skill

    /// §7's baseline comparison, running on the device. The ground truth arrives by itself a few
    /// hours after each forecast, so this needs no dataset — which is what makes it the one
    /// skill number the app can honestly produce today.
    func testTheSkillReportScoresArchivedForecastsAgainstTheBarometer() async throws {
        let reader = try await makeReader(issuedAt: now.addingTimeInterval(-3600),
                                          includingRealisedForecasts: true)

        guard let report = await reader.skillReport(asOf: now) else {
            return XCTFail("expected a report once the offset is measurable")
        }

        XCTAssertEqual(report.source, .weatherKit)
        XCTAssertFalse(report.measuredHorizons.isEmpty,
                       "past forecasts and the readings that realised them are both on disk")
        XCTAssertFalse(report.summary.isEmpty)
    }

    /// No offset, nothing comparable, no report. A skill score in MSLP against a truth in
    /// station pressure would be 22 hPa of nonsense reported to one decimal place.
    func testNoOffsetMeansNoSkillReport() async {
        let reader = PressureForecastReader(archive: InMemoryWeatherForecastStore(),
                                            samples: InMemoryPressureSampleStore(),
                                            epochs: InMemoryPressureLocationEpochStore(),
                                            preferences: InMemoryWeatherKitPreferenceStore())

        let report = await reader.skillReport(asOf: now)

        XCTAssertNil(report)
    }

    // MARK: - The switch

    /// Off has to mean off on the next read, not once the archive ages out.
    ///
    /// Turning WeatherKit off stops requests and deliberately leaves the rows already fetched
    /// on disk, so switching back on does not pay a cold start again (§5, PR 2, criterion 4).
    /// Nothing, though, was stopping those rows being *drawn*: the chart went on showing
    /// Apple's curve, with Apple's attribution under it, until the issue passed
    /// `WeatherForecastPolicy.maximumIssueAgeSeconds` — up to **twelve hours** after the user
    /// had switched it off. This is the same archive and the same instant, read twice.
    func testSwitchingWeatherKitOffFallsToTheLocalModelOnTheNextRead() async throws {
        let issuedAt = now.addingTimeInterval(-3600)

        let enabled = try await makeReader(issuedAt: issuedAt, isWeatherKitEnabled: true)
        let withWeatherKit = await enabled.forecast(asOf: now, horizonSeconds: 6 * 3600)
        XCTAssertTrue(withWeatherKit.contains { $0.source == .weatherKit },
                      "an issue an hour old is well inside the staleness norm")

        let disabled = try await makeReader(issuedAt: issuedAt, isWeatherKitEnabled: false)
        let withoutWeatherKit = await disabled.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertFalse(withoutWeatherKit.isEmpty, "the local model answers instead")
        XCTAssertTrue(withoutWeatherKit.allSatisfy { $0.source == .localModel })
    }

    /// The rows stay. The switch decides what may be *used*, and an erase is what deletes.
    ///
    /// Without this the fix would be a regression dressed as one: dropping the archive on the
    /// way past would make switching back on re-measure the offset from nothing and wait for
    /// the next slot before the chart said anything about tomorrow.
    func testSwitchingOffLeavesTheArchiveIntactForSwitchingBackOn() async throws {
        let issuedAt = now.addingTimeInterval(-3600)

        let disabled = try await makeReader(issuedAt: issuedAt, isWeatherKitEnabled: false)
        _ = await disabled.forecast(asOf: now, horizonSeconds: 6 * 3600)

        let switchedBackOn = try await makeReader(issuedAt: issuedAt, isWeatherKitEnabled: true)
        let curve = await switchedBackOn.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertTrue(curve.contains { $0.source == .weatherKit },
                      "the same issue is still on disk and still inside the norm")
    }

    // MARK: - The updated install

    /// The state every device that has been recording for a while lands in the day this
    /// feature ships, and the reason the chart's forward half was missing on exactly the
    /// devices with the most history.
    ///
    /// `PressureSample.locationEpochID` arrived with the forecast work, so the log is weeks of
    /// unstamped readings plus whatever has been recorded since the update. The epoch filter
    /// dropped every unstamped row as soon as one stamped row existed, which left the fit a
    /// handful of readings — below `LocalPressureModel.minimumTrainingRows` — and
    /// `LocalPressureModel.fit` correctly refused to fit them. Measured on a seven-day
    /// opportunistic log: 83 readings in, 6 surviving the filter, no curve.
    ///
    /// The spec asked for this outcome and did not get it: acceptance criterion 5 of the
    /// location epoch PR is *"семпли, записані до міграції … не втрачаються"*.
    func testAnUpdatedInstallStillForecastsFromItsUnstampedHistory() async throws {
        let epoch = PressureLocationEpoch(coordinate: GeoCoordinate(latitude: 50.4, longitude: 30.5),
                                          startedAt: now.addingTimeInterval(-6 * 3600))
        let epochs = InMemoryPressureLocationEpochStore()
        try await epochs.save(epoch)

        // Everything older than six hours predates the update and carries no stamp; the last
        // six hours were recorded by the new build and are stamped.
        let log = barometerLog().map { sample in
            sample.timestamp < now.addingTimeInterval(-6 * 3600)
                ? sample
                : PressureSample(id: sample.id,
                                 timestamp: sample.timestamp,
                                 pressure: sample.pressure,
                                 locationEpochID: epoch.id)
        }
        let samples = InMemoryPressureSampleStore()
        try await samples.save(log)

        let reader = PressureForecastReader(archive: InMemoryWeatherForecastStore(),
                                            samples: samples,
                                            epochs: epochs,
                                            preferences: InMemoryWeatherKitPreferenceStore())

        let curve = await reader.forecast(asOf: now, horizonSeconds: 6 * 3600)

        XCTAssertFalse(curve.isEmpty, "the unstamped history is this device's whole log")
        XCTAssertTrue(curve.allSatisfy { $0.source == .localModel })
    }

    // MARK: - Fixtures

    /// A device with 48 h of hourly barometer history and one WeatherKit issue over the same
    /// window plus 24 h ahead, offset by a constant 22 hPa so the calibrator has something to
    /// find.
    ///
    /// `includingRealisedForecasts` adds earlier issues whose hours have already arrived, which
    /// is what the skill report scores.
    private func makeReader(issuedAt: Date,
                            includingRealisedForecasts: Bool = false,
                            isWeatherKitEnabled: Bool = true) async throws
        -> PressureForecastReader {
        let samples = InMemoryPressureSampleStore()
        try await samples.save(barometerLog())

        var rows = issueRows(issuedAt: issuedAt)
        if includingRealisedForecasts {
            // Six-hour-lead forecasts made through the past two days, so each has a reading at
            // its own hour and a reading at the hour it was issued — the two the baseline needs.
            for hoursAgo in stride(from: 42, through: 8, by: -6) {
                let made = now.addingTimeInterval(-TimeInterval(hoursAgo) * 3600)
                rows += (0...6).map { lead in
                    forecastRow(issuedAt: made,
                                validAt: made.addingTimeInterval(TimeInterval(lead) * 3600))
                }
            }
        }
        let archive = InMemoryWeatherForecastStore()
        try await archive.save(rows)

        return PressureForecastReader(
            archive: archive,
            samples: samples,
            epochs: InMemoryPressureLocationEpochStore(),
            preferences: InMemoryWeatherKitPreferenceStore(isWeatherKitEnabled: isWeatherKitEnabled)
        )
    }

    /// Hourly station-pressure readings for the last 48 h, with the solar semidiurnal tide on
    /// top so the local model has the one thing persistence does not.
    private func barometerLog() -> [PressureSample] {
        (0...48).map { hoursAgo in
            let instant = now.addingTimeInterval(-TimeInterval(hoursAgo) * 3600)
            return PressureSample(timestamp: instant,
                                  pressure: Pressure(hectopascals: level(at: instant) + offsetHPa))
        }
    }

    /// One issue: the 48 h behind `now`, so the calibrator can pair, and 24 h ahead, so every
    /// horizon in the family has something to read.
    private func issueRows(issuedAt: Date) -> [WeatherForecastPoint] {
        (-48...24).map { hour in
            forecastRow(issuedAt: issuedAt,
                        validAt: now.addingTimeInterval(TimeInterval(hour) * 3600))
        }
    }

    private func forecastRow(issuedAt: Date, validAt: Date) -> WeatherForecastPoint {
        WeatherForecastPoint(issuedAt: issuedAt,
                             validAt: validAt,
                             meanSeaLevelPressureHPa: level(at: validAt),
                             temperatureC: 15)
    }

    /// Mean sea level pressure at an instant: a slow fall with the S2 tide on it.
    private func level(at instant: Date) -> Double {
        let hours = instant.timeIntervalSince(now) / 3600
        let secondsIntoDay = instant.timeIntervalSince1970
            .truncatingRemainder(dividingBy: 86_400)

        return 1013 - 0.2 * hours + 0.4 * sin(2 * 2 * Double.pi * secondsIntoDay / 86_400)
    }
}
