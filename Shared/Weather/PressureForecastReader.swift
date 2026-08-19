import Foundation

/// Everything the chart needs about the forward half of the line, read in one place.
///
/// The calibration and the curve are pure functions (`PressureOffsetCalibrator`,
/// `ForecastPressurePoint.curve`); this is the actor that fetches what they need and holds the
/// small piece of state that keeps the fetch cheap — the offset, which changes twice a day and
/// would otherwise be re-measured on every chart reload.
///
/// ## Cost
///
/// A cached offset makes a reload two indexed reads and a map. A cold one adds one 48 h window
/// over each of the two logs — a few hundred rows — and a median. No network: the archive is
/// filled by `WeatherForecastRefresher` on its own schedule, and this only ever reads it.
actor PressureForecastReader {

    private let archive: any WeatherForecastStore
    private let samples: any PressureSampleStore
    private let epochs: any PressureLocationEpochStore

    /// The offset, and when it was measured.
    ///
    /// Re-measured at most once per `offsetRefreshSeconds`. In memory rather than on disk: it
    /// is derived from two tables that are both durable, so recomputing it on a fresh process
    /// costs one pass over 48 h of rows and cannot go stale in a way that outlives the process.
    private var cachedOffset: (value: PressureOffset, measuredAt: Date)?

    /// How often the offset is re-measured.
    ///
    /// **Six hours.** The elevation part does not move at all and the temperature part is
    /// handled analytically, so what is left drifts slowly; re-measuring on every chart reload
    /// would scan a hundred-odd rows to produce the same number. A move to a new place is
    /// caught faster than this by the epoch check below, which drops the cache outright.
    static let offsetRefreshSeconds: TimeInterval = 6 * 3600

    /// The local model, refitted at most daily.
    ///
    /// In memory rather than on disk for the reason the offset is: it is derived from a durable
    /// table, and a fresh process pays microseconds to rebuild it. `LocalPressureModel.fit` is
    /// ~46 000 multiply-adds over a 30-day window — see the battery note in `ml-spec.md`.
    private var localModel: LocalPressureModel?

    /// The epoch the cached offset was measured in. A move past 25 km changes the elevation and
    /// therefore the offset by potentially tens of hPa, so the cache is dropped rather than
    /// aged out — six hours of drawing the previous city's offset would put the forecast line
    /// visibly in the wrong place.
    private var cachedEpochID: UUID?

    init(archive: any WeatherForecastStore,
         samples: any PressureSampleStore,
         epochs: any PressureLocationEpochStore) {
        self.archive = archive
        self.samples = samples
        self.epochs = epochs
    }

    /// The forward half of the chart, in barometer coordinates.
    ///
    /// Empty — not approximate — whenever the offset cannot be measured. An uncalibrated
    /// WeatherKit curve sits ~22 hPa away from the user's own line and stretches the plot's
    /// domain threefold, so drawing nothing is both more honest and more readable than drawing
    /// that.
    /// The forward half of the chart, whichever producer can supply it.
    ///
    /// **One return type, two producers, no second code path.** WeatherKit when the archive has
    /// something and the offset is measurable; the local model when it does not — which is the
    /// state of every device with WeatherKit switched off, with location refused, or waiting on
    /// its first request. The caller cannot tell which it got except by reading `source`, and
    /// that is the design: the same table, the same type, the same chart, differing only in
    /// range and in the width of the band
    /// (`.claude/context/pressure-forecast-spec.md` §2.3).
    func forecast(asOf now: Date, horizonSeconds: TimeInterval) async -> [ForecastPressurePoint] {
        let fromWeatherKit = await weatherKitForecast(asOf: now, horizonSeconds: horizonSeconds)
        guard fromWeatherKit.isEmpty else { return fromWeatherKit }

        return await localForecast(asOf: now, horizonSeconds: horizonSeconds)
    }

    /// The calibrated WeatherKit curve, or empty.
    ///
    /// Empty — not approximate — whenever the offset cannot be measured. An uncalibrated curve
    /// sits ~22 hPa away from the user's own line and stretches the plot's domain threefold, so
    /// falling through to the local model is both more honest and more readable than drawing
    /// that.
    private func weatherKitForecast(asOf now: Date,
                                    horizonSeconds: TimeInterval) async -> [ForecastPressurePoint] {
        guard let offset = await offset(asOf: now) else { return [] }

        let window = now..<now.addingTimeInterval(min(horizonSeconds,
                                                      ForecastSource.weatherKit.rangeSeconds))
        // The leak guard travels with the read: even a chart may only draw what was knowable.
        // It is the same call the feature pipeline makes, so the picture and the model agree
        // about what the app knew.
        let points = (try? await archive.points(issuedAtOrBefore: now, validIn: window)) ?? []
        guard !points.isEmpty else { return [] }

        return ForecastPressurePoint.curve(from: points,
                                           offset: offset,
                                           asOf: now,
                                           horizonSeconds: horizonSeconds)
    }

    /// The on-device autoregressive fit over the user's own log.
    ///
    /// Refitted at most once a day, on whatever activation happens to be first — no timer and no
    /// background task, because the fit is microseconds and a wake scheduled for it would be a
    /// battery debit with nothing to show for it.
    ///
    /// Empty on a device with too little history to fit, which is the honest answer: a line
    /// drawn from four readings is still a claim.
    private func localForecast(asOf now: Date,
                               horizonSeconds: TimeInterval) async -> [ForecastPressurePoint] {
        if localModel == nil || localModel?.isStale(asOf: now) == true {
            let window = now.addingTimeInterval(
                -TimeInterval(LocalPressureModel.trainingWindowDays) * 24 * 3600
            )..<now.addingTimeInterval(1)
            let readings = (try? await samples.samples(in: window)) ?? []
            localModel = LocalPressureModel.fit(to: readings, asOf: now)
        }

        return localModel?.forecast(asOf: now, horizonSeconds: horizonSeconds) ?? []
    }

    /// The place the forecast is about, for the line under the card. `nil` before the first fix.
    func placeName(asOf now: Date) async -> PlaceName? {
        guard let epoch = try? await epochs.currentEpoch(), !epoch.place.isEmpty else {
            return nil
        }

        return epoch.place
    }

    /// The current offset, measured or cached.
    private func offset(asOf now: Date) async -> PressureOffset? {
        let epochID = (try? await epochs.currentEpoch())?.id

        if let cached = cachedOffset,
           cachedEpochID == epochID,
           now.timeIntervalSince(cached.measuredAt) < Self.offsetRefreshSeconds,
           now >= cached.measuredAt {
            return cached.value
        }

        let window = now.addingTimeInterval(-PressureOffsetCalibrator.windowSeconds)..<now
            .addingTimeInterval(1)
        let readings = (try? await samples.samples(in: window)) ?? []
        let archived = (try? await archive.points(issuedAtOrBefore: now, validIn: window)) ?? []

        guard let measured = PressureOffsetCalibrator.calibrate(samples: readings,
                                                                archive: archived,
                                                                asOf: now) else {
            return nil
        }

        cachedOffset = (measured, now)
        cachedEpochID = epochID
        return measured
    }
}
