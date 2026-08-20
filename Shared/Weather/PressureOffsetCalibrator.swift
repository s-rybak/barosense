import Foundation

/// The measured difference between what the barometer reads and what WeatherKit reports.
///
/// One number and the temperature it was measured at, because the difference is not constant:
/// Apple reduces station pressure to sea level "by using observed conditions", so the reduction
/// — and therefore this offset — moves with temperature.
struct PressureOffset: Hashable, Sendable {

    /// `station − MSLP` in hPa at `referenceTemperatureC`. **Negative** anywhere above sea
    /// level: the air weighs less where the user is than it would at sea level. Around Kyiv
    /// (≈180 m) it is about −22.
    let offsetHPa: Double

    /// The temperature the offset was measured at, °C. The anchor the correction below pivots
    /// on, so it has to be stored with the offset rather than assumed.
    let referenceTemperatureC: Double

    /// How many station/MSLP pairs went into the median. Carried rather than dropped: an offset
    /// from six pairs and one from two hundred are different claims, and the band on the
    /// forecast is allowed to say so.
    let pairCount: Int

    /// Half the spread of the paired differences, hPa — the offset's own contribution to the
    /// forecast band.
    ///
    /// Median absolute deviation rather than a standard deviation, for the same reason the
    /// offset itself is a median: one altitude excursion in the window would otherwise widen
    /// this by several hPa on its own.
    let uncertaintyHPa: Double

    /// The offset at a given temperature.
    ///
    /// From the barometric formula rather than from a fit. Reducing to sea level multiplies by
    /// roughly `exp(gh / RT)`, so `∂ΔP/∂T ≈ −ΔP / T` with `T` absolute. At −22 hPa and 288 K
    /// that is **0.077 hPa/°C**, which over a 10 °C day is 0.77 hPa at 180 m and about 2 hPa at
    /// 500 m — the latter being comparable with `PressureTrend.significantChangeHPa` and the
    /// reason this correction is not optional.
    ///
    /// Teaching a model to rediscover a formula whose input is sitting in the same response is
    /// a more expensive way to get a worse answer.
    func offsetHPa(atTemperatureC temperature: Double) -> Double {
        let referenceKelvin = referenceTemperatureC + PressureOffsetCalibrator.absoluteZeroC
        guard referenceKelvin > 0 else { return offsetHPa }

        let sensitivityPerDegree = -offsetHPa / referenceKelvin
        return offsetHPa + sensitivityPerDegree * (temperature - referenceTemperatureC)
    }

    /// An MSLP value expressed in barometer coordinates.
    func stationPressureHPa(fromMeanSeaLevel meanSeaLevel: Double,
                            temperatureC temperature: Double) -> Double {
        meanSeaLevel + offsetHPa(atTemperatureC: temperature)
    }

    /// The offset to use before anything has been measured: none at all.
    ///
    /// Drawing an uncalibrated WeatherKit curve is worse than drawing no curve — it puts the
    /// forecast 22 hPa away from the user's own line and stretches the plot's domain threefold
    /// — so this is deliberately **not** the fallback anywhere. Callers with no offset draw no
    /// WeatherKit curve. It exists for tests and for a device genuinely at sea level.
    static let none = PressureOffset(offsetHPa: 0,
                                     referenceTemperatureC: 15,
                                     pairCount: 0,
                                     uncertaintyHPa: 0)
}

/// Measures `station − MSLP` from the two histories the device already holds.
///
/// Pure and synchronous, like `HealthMetricsSnapshot.make` and `PressureSeries.make`: this
/// decides where the forecast line is drawn, so it has to be checkable from a test with a
/// handful of literals and no store, no sensor and no network.
///
/// ## Why a median, and why not a model
///
/// The offset is dominated by elevation, which does not change, plus a temperature term with a
/// known analytic form. What is left is noise plus the user's own altitude excursions — lifts,
/// stairs, a drive up a hill — which are exactly the outliers a mean would follow and a median
/// ignores. There is nothing here for a learned model to find that the barometric formula does
/// not already state.
enum PressureOffsetCalibrator {

    static let absoluteZeroC: Double = 273.15

    /// How far back pairs are drawn from.
    ///
    /// **48 hours**, inside the 24–72 h the design allows. Long enough to average out a day's
    /// weather and to see both ends of a diurnal temperature swing, short enough that a move
    /// to a new place shows up within two days. The epoch filter — `atEpochs` below — is the
    /// guard against mixing two places; this is the guard against mixing two weeks.
    static let windowSeconds: TimeInterval = 48 * 3600

    /// How close in time a barometer reading and an MSLP value have to be to form a pair.
    ///
    /// **30 minutes.** The comparison is only meaningful if both describe the same air: at a
    /// synoptic rate of ~2 hPa/h, half an hour of drift is ~1 hPa, which is the noise floor
    /// this whole app calls the boundary of meaning. WeatherKit is hourly and the barometer
    /// aims at 15-minute samples, so most hours pair comfortably.
    static let maximumPairSeparationSeconds: TimeInterval = 30 * 60

    /// Below this many pairs, no offset is reported at all.
    ///
    /// **Six.** With fewer, a single altitude excursion can be the median rather than an
    /// outlier the median steps over. Returning `nil` is the right answer: the chart then draws
    /// no WeatherKit curve, which is honest, where a curve 22 hPa off would not be.
    static let minimumPairCount = 6

    /// The offset at `now`, or `nil` when the two histories do not overlap enough.
    ///
    /// `samples` and `archive` may both be wider than the window and may be unsorted; anything
    /// outside it is ignored, so one store read serves this and the chart.
    ///
    /// Only archive rows with `issuedAt <= validAt + tolerance` would be a forecast rather than
    /// an analysis — but that distinction does not matter here and is deliberately not made.
    /// Calibration is a **synchronous** comparison at one instant, so it leaks nothing whichever
    /// row supplies the MSLP value; that is precisely why bootstrap history is safe to use for
    /// this and unsafe as a forward-looking feature
    /// (`.claude/context/pressure-forecast-spec.md` §4.5).
    ///
    /// `atEpochs` is the set of `PressureLocationEpoch` identities that describe where the user
    /// is now (`LocationEpochResolver.samePlaceEpochIDs(as:among:)`). Readings taken anywhere
    /// else are dropped **before** the median, which is the point of stamping them: the offset
    /// is dominated by elevation, and a window straddling a move would otherwise return the
    /// median of two places — at Kyiv's 180 m against sea level, tens of hPa apart. Passing
    /// `nil` filters nothing, which is right for a device that has no epoch table because
    /// location was never granted.
    ///
    /// After a move the window holds too few readings from the new place to clear
    /// `minimumPairCount`, and `nil` comes back until it does. That is the intended answer:
    /// the chart falls through to the local model rather than drawing the previous city's
    /// curve for two days.
    static func calibrate(samples: [PressureSample],
                          archive: [WeatherForecastPoint],
                          asOf now: Date,
                          atEpochs epochIDs: Set<UUID>? = nil) -> PressureOffset? {
        let window = now.addingTimeInterval(-windowSeconds)...now
        let inWindow = samples.filter { window.contains($0.timestamp) }
        let readings = LocationEpochResolver.readings(inWindow, takenAt: epochIDs)
            .sorted { $0.timestamp < $1.timestamp }
        guard !readings.isEmpty else { return nil }

        // Newest issue per hour, so one hour cannot contribute two pairs and weight itself
        // double in the median.
        var newestByHour: [Date: WeatherForecastPoint] = [:]
        for point in archive.sorted(by: { $0.issuedAt < $1.issuedAt })
        where window.contains(point.validAt) {
            newestByHour[point.validAt] = point
        }

        var differences: [Double] = []
        var temperatures: [Double] = []

        for point in newestByHour.values.sorted(by: { $0.validAt < $1.validAt }) {
            guard let reading = nearestReading(to: point.validAt, in: readings) else { continue }

            differences.append(reading.pressure.hectopascals - point.meanSeaLevelPressureHPa)
            temperatures.append(point.temperatureC)
        }

        guard differences.count >= minimumPairCount,
              let offset = median(of: differences),
              let referenceTemperature = median(of: temperatures)
        else {
            return nil
        }

        return PressureOffset(offsetHPa: offset,
                              referenceTemperatureC: referenceTemperature,
                              pairCount: differences.count,
                              uncertaintyHPa: medianAbsoluteDeviation(of: differences,
                                                                      around: offset))
    }

    /// The reading closest in time to `instant`, or `nil` if the nearest one is too far away.
    ///
    /// Binary search over the sorted readings: the window can hold ~190 samples at the target
    /// cadence and is scanned once per archive hour, so the linear version is ~9 000
    /// comparisons for a number that changes twice a day.
    private static func nearestReading(to instant: Date,
                                       in readings: [PressureSample]) -> PressureSample? {
        var low = 0
        var high = readings.count
        while low < high {
            let middle = (low + high) / 2
            if readings[middle].timestamp < instant {
                low = middle + 1
            } else {
                high = middle
            }
        }

        // The insertion point's neighbours are the only two candidates.
        let candidates = [low - 1, low]
            .filter { readings.indices.contains($0) }
            .map { readings[$0] }

        return candidates
            .min { abs($0.timestamp.timeIntervalSince(instant)) < abs($1.timestamp.timeIntervalSince(instant)) }
            .flatMap { abs($0.timestamp.timeIntervalSince(instant)) <= maximumPairSeparationSeconds ? $0 : nil }
    }

    /// The middle value, or the mean of the two middle ones.
    static func median(of values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }

    /// Median absolute deviation — the robust spread, matching the robust centre.
    private static func medianAbsoluteDeviation(of values: [Double], around centre: Double) -> Double {
        median(of: values.map { abs($0 - centre) }) ?? 0
    }
}
