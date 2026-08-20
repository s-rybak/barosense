import XCTest
@testable import Barosense

/// The number that decides where the forecast line is drawn.
///
/// Every case runs on literals — no store, no sensor, no network — because this is the piece
/// most likely to be wrong in a way the eye cannot check: a 22 hPa error looks like a perfectly
/// ordinary pressure, just not the user's.
final class PressureOffsetCalibratorTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    /// Kyiv, ≈180 m. The offset the design is stated against.
    private let kyivOffsetHPa: Double = -22

    // MARK: - Recovering a known offset

    /// Acceptance criterion 1 of PR 3.
    func testAKnownOffsetIsRecoveredToBetterThanHalfAHectopascal() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa)

        guard let offset = PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                              archive: synthetic.archive,
                                                              asOf: now) else {
            return XCTFail("expected an offset from 24 paired hours")
        }

        XCTAssertEqual(offset.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
        XCTAssertEqual(offset.pairCount, 24)
    }

    /// The reason it is a median. One lift ride inside the window is a 1–2 hPa outlier; a mean
    /// would follow it and put the whole forecast line off by a fraction of that, every hour,
    /// until the excursion aged out of the window.
    func testAnAltitudeExcursionDoesNotMoveTheOffset() {
        // A small alternating wobble so the spread below is a real measurement rather than an
        // artefact of a perfectly clean fixture — real readings are never exactly on a line.
        var synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa, sensorWobbleHPa: 0.15)
        // Ten floors, four times, in the middle of the window.
        for index in 10..<14 {
            let sample = synthetic.samples[index]
            synthetic.samples[index] = PressureSample(
                id: sample.id,
                timestamp: sample.timestamp,
                pressure: Pressure(hectopascals: sample.pressure.hectopascals - 3.5)
            )
        }

        guard let offset = PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                              archive: synthetic.archive,
                                                              asOf: now) else {
            return XCTFail("expected an offset")
        }

        XCTAssertEqual(offset.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
        // And the excursion widens the reported band rather than vanishing, so the chart can
        // say the offset is less certain than usual.
        XCTAssertGreaterThan(offset.uncertaintyHPa, 0)
    }

    /// Weather moving under both series must not leak into the offset: a front changes station
    /// pressure and MSLP together, so the difference stays put.
    func testWeatherMovingUnderBothSeriesLeavesTheOffsetAlone() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa, weatherDriftHPaPerHour: -0.4)

        guard let offset = PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                              archive: synthetic.archive,
                                                              asOf: now) else {
            return XCTFail("expected an offset")
        }

        XCTAssertEqual(offset.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
    }

    // MARK: - Refusing to guess

    /// Fewer than six pairs and one excursion can *be* the median rather than an outlier the
    /// median steps over. `nil` is the right answer: the chart then draws no forecast, which is
    /// honest, where a curve 22 hPa out would not be.
    func testTooFewPairsProduceNoOffsetAtAll() {
        let synthetic = pairs(hours: 4, offsetHPa: kyivOffsetHPa)

        XCTAssertNil(PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                        archive: synthetic.archive,
                                                        asOf: now))
    }

    /// A forecast hour with no reading near it is not a pair. This is the §8 "12 h gap"
    /// fixture in its calibration form: the phone was asleep, so most of the window has MSLP
    /// and no station pressure to put beside it, and too few pairs survive to support a median.
    ///
    /// It is also why the pairing tolerance is 30 minutes rather than "nearest": at a synoptic
    /// 2 hPa/h, pairing a reading with an hour three hours away would invent 6 hPa of offset.
    func testAGapInTheBarometerLogLeavesTooFewPairs() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa)
        // Only the three oldest readings survive; the rest of the window is a hole.
        let sparse = Array(synthetic.samples.prefix(3))

        XCTAssertNil(PressureOffsetCalibrator.calibrate(samples: sparse,
                                                        archive: synthetic.archive,
                                                        asOf: now))
    }

    /// And with the gap half filled, the pairs that do line up are the only ones counted — the
    /// hours with nothing near them are dropped rather than paired with the nearest thing
    /// available.
    func testOnlyHoursWithAReadingNearThemBecomePairs() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa)
        let halfLogged = Array(synthetic.samples.prefix(10))

        guard let offset = PressureOffsetCalibrator.calibrate(samples: halfLogged,
                                                              archive: synthetic.archive,
                                                              asOf: now) else {
            return XCTFail("ten paired hours is above the minimum")
        }

        XCTAssertEqual(offset.pairCount, 10)
        XCTAssertEqual(offset.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
    }

    /// Rows outside the 48 h window are ignored rather than trusted, so one store read can
    /// serve this and the chart.
    func testRowsOlderThanTheWindowAreIgnored() {
        let recent = pairs(hours: 24, offsetHPa: kyivOffsetHPa)
        let ancient = pairs(hours: 24, offsetHPa: -60, endingHoursAgo: 200)

        guard let offset = PressureOffsetCalibrator.calibrate(
            samples: recent.samples + ancient.samples,
            archive: recent.archive + ancient.archive,
            asOf: now
        ) else {
            return XCTFail("expected an offset")
        }

        XCTAssertEqual(offset.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
    }

    // MARK: - Temperature

    /// Acceptance criterion 2 of PR 3: at 180 m and ΔT = 10 °C the correction is 0.4–0.8 hPa.
    ///
    /// From the barometric formula, `∂ΔP/∂T ≈ −ΔP/T`, not from a fit. Teaching a model to
    /// rediscover a formula whose input arrives in the same response is a more expensive way to
    /// get a worse answer.
    func testTheTemperatureCorrectionIsWithinTheExpectedBandAtOneHundredAndEightyMetres() {
        let offset = PressureOffset(offsetHPa: kyivOffsetHPa,
                                    referenceTemperatureC: 15,
                                    pairCount: 24,
                                    uncertaintyHPa: 0.2)

        let correction = abs(offset.offsetHPa(atTemperatureC: 25) - offset.offsetHPa)

        XCTAssertGreaterThanOrEqual(correction, 0.4)
        XCTAssertLessThanOrEqual(correction, 0.8)
    }

    /// The sign has to be right, and it is the half of this that a plausible-looking magnitude
    /// would hide: warmer air is less dense, so the reduction to sea level is smaller and the
    /// station value sits *closer* to MSLP.
    func testWarmerAirShrinksTheOffsetAndColderAirDeepensIt() {
        let offset = PressureOffset(offsetHPa: kyivOffsetHPa,
                                    referenceTemperatureC: 15,
                                    pairCount: 24,
                                    uncertaintyHPa: 0.2)

        XCTAssertGreaterThan(offset.offsetHPa(atTemperatureC: 25), offset.offsetHPa)
        XCTAssertLessThan(offset.offsetHPa(atTemperatureC: 5), offset.offsetHPa)
    }

    /// At 500 m the diurnal remainder is ~2 hPa — comparable with the 1.0 hPa this app calls
    /// as the boundary of meaning, which is why the correction is not optional up there.
    func testAtFiveHundredMetresTheDiurnalRemainderIsAboutTwoHectopascals() {
        let offset = PressureOffset(offsetHPa: -58,
                                    referenceTemperatureC: 15,
                                    pairCount: 24,
                                    uncertaintyHPa: 0.2)

        let correction = abs(offset.offsetHPa(atTemperatureC: 25) - offset.offsetHPa)

        XCTAssertEqual(correction, 2.0, accuracy: 0.3)
    }

    /// The conversion the chart depends on: MSLP in, barometer coordinates out.
    func testMeanSeaLevelPressureIsExpressedInBarometerCoordinates() {
        let offset = PressureOffset(offsetHPa: kyivOffsetHPa,
                                    referenceTemperatureC: 15,
                                    pairCount: 24,
                                    uncertaintyHPa: 0.2)

        let station = offset.stationPressureHPa(fromMeanSeaLevel: 1013, temperatureC: 15)

        XCTAssertEqual(station, 991, accuracy: 0.001)
    }

    // MARK: - Fixtures

    private struct SyntheticPairs {
        var samples: [PressureSample]
        var archive: [WeatherForecastPoint]

        /// The same readings, taken in a named place. Only the samples carry an epoch — the
        /// archive is MSLP, which is the same quantity everywhere by definition.
        func stamped(with epochID: UUID) -> SyntheticPairs {
            SyntheticPairs(samples: samples.map { $0.inLocationEpoch(epochID) },
                           archive: archive)
        }
    }

    // MARK: - One place at a time

    /// What `PressureSample.locationEpochID` is for.
    ///
    /// The 48-hour window straddles a move: 24 hours at the coast, then 24 at Kyiv's 180 m,
    /// where the offset is 22 hPa away. Unfiltered, the median lands between the two and the
    /// forecast line is drawn in a place the user has never been. Filtered to the epochs that
    /// describe where they are **now**, the answer is the one for here.
    func testReadingsFromAnotherPlaceAreNotMedianedIntoTheOffset() {
        let here = UUID()
        let elsewhere = UUID()

        let older = pairs(hours: 24, offsetHPa: 0, endingHoursAgo: 24)
            .stamped(with: elsewhere)
        let recent = pairs(hours: 24, offsetHPa: kyivOffsetHPa).stamped(with: here)

        let samples = older.samples + recent.samples
        let archive = older.archive + recent.archive

        guard let blended = PressureOffsetCalibrator.calibrate(samples: samples,
                                                               archive: archive,
                                                               asOf: now),
              let hereOnly = PressureOffsetCalibrator.calibrate(samples: samples,
                                                                archive: archive,
                                                                asOf: now,
                                                                atEpochs: [here]) else {
            return XCTFail("expected an offset from 48 paired hours")
        }

        // The blend is the failure this guards against — roughly half of a 22 hPa move.
        XCTAssertEqual(blended.offsetHPa, kyivOffsetHPa / 2, accuracy: 1)
        XCTAssertEqual(hereOnly.offsetHPa, kyivOffsetHPa, accuracy: 0.5)
        XCTAssertEqual(hereOnly.pairCount, 24)
    }

    /// A log written before the epoch table existed, or on a device where location was refused.
    /// Nothing is stamped, so there is nothing to filter on and dropping every row would take a
    /// working feature away from a user who simply never granted a permission.
    func testAnUnstampedLogIsNotFilteredAway() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa)

        let offset = PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                        archive: synthetic.archive,
                                                        asOf: now,
                                                        atEpochs: [UUID()])

        XCTAssertEqual(offset?.offsetHPa ?? 0, kyivOffsetHPa, accuracy: 0.5)
    }

    /// And the other side of it: a window that **is** stamped, entirely from somewhere else,
    /// yields no offset at all. The chart then falls through to the local model, which is the
    /// honest answer for the day or two after a move — a curve 22 hPa off would not be.
    func testAWindowEntirelyFromElsewhereYieldsNoOffset() {
        let synthetic = pairs(hours: 24, offsetHPa: kyivOffsetHPa).stamped(with: UUID())

        XCTAssertNil(PressureOffsetCalibrator.calibrate(samples: synthetic.samples,
                                                        archive: synthetic.archive,
                                                        asOf: now,
                                                        atEpochs: [UUID()]))
    }

    /// Hourly MSLP with a barometer reading on each hour, separated by exactly `offsetHPa`.
    ///
    /// `weatherDriftHPaPerHour` moves **both** series together, which is what weather does: the
    /// offset is elevation, and elevation does not change because a front went past.
    private func pairs(hours: Int,
                       offsetHPa: Double,
                       weatherDriftHPaPerHour: Double = 0,
                       sensorWobbleHPa: Double = 0,
                       endingHoursAgo: Double = 0) -> SyntheticPairs {
        var samples: [PressureSample] = []
        var archive: [WeatherForecastPoint] = []

        for hour in 0..<hours {
            let instant = now.addingTimeInterval(-(endingHoursAgo + Double(hours - hour)) * 3600)
            let meanSeaLevel = 1013 + weatherDriftHPaPerHour * Double(hour)

            // Alternating rather than random, so a failure is reproducible.
            let wobble = hour.isMultiple(of: 2) ? sensorWobbleHPa : -sensorWobbleHPa
            samples.append(PressureSample(
                timestamp: instant,
                pressure: Pressure(hectopascals: meanSeaLevel + offsetHPa + wobble)
            ))
            archive.append(WeatherForecastPoint(issuedAt: instant,
                                                validAt: instant,
                                                meanSeaLevelPressureHPa: meanSeaLevel,
                                                temperatureC: 15))
        }

        return SyntheticPairs(samples: samples, archive: archive)
    }
}
