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

    /// The epoch the cached fit was made in, for the reason `cachedEpochID` exists below: an
    /// AR model carries an absolute pressure level, and 180 m of elevation moves that level by
    /// about 22 hPa. A model fitted at the old place would draw a forward half that far from
    /// the user's own line — the same failure an uncalibrated WeatherKit curve produces, from
    /// the other producer.
    private var localModelEpochID: UUID?

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

    /// The forward half of the chart, whichever producer can supply it.
    ///
    /// **One return type, two producers, no second code path.** WeatherKit when the archive has
    /// something recent enough and the offset is measurable; the local model when it does not —
    /// which is the state of every device with WeatherKit switched off, with location refused,
    /// or waiting on its first request. The caller cannot tell which it got except by reading
    /// `source`, and that is the design: the same table, the same type, the same chart,
    /// differing only in range and in the width of the band
    /// (`.claude/context/pressure-forecast-spec.md` §2.3).
    ///
    /// `anchoredAtNow` asks both producers to include the hour containing `now`. Only the
    /// feature pipeline wants it — see `features(asOf:)`.
    func forecast(asOf now: Date,
                  horizonSeconds: TimeInterval,
                  anchoredAtNow anchored: Bool = false) async -> [ForecastPressurePoint] {
        let fromWeatherKit = await weatherKitForecast(asOf: now,
                                                      horizonSeconds: horizonSeconds,
                                                      anchored: anchored)
        guard fromWeatherKit.isEmpty else { return fromWeatherKit }

        return await localForecast(asOf: now, horizonSeconds: horizonSeconds, anchored: anchored)
    }

    /// The §2.2 feature family at `now`, from whichever producer the chart is drawing.
    ///
    /// Deliberately built on `forecast(asOf:horizonSeconds:anchoredAtNow:)` rather than on the
    /// archive directly: the picture and the feature row then come from the same rows, and the
    /// pipeline stays the single branch §2.3 asks for — it reads a curve and does not know who
    /// wrote it. `forecastSource` and `forecastUncertaintyHPa` are what carry the difference
    /// forward, which is the whole reason they are on the vector.
    func features(asOf now: Date) async -> ForecastPressureFeatures {
        let curve = await forecast(asOf: now,
                                   horizonSeconds: ForecastFeatureExtractor.featureHorizonSeconds,
                                   anchoredAtNow: true)

        return ForecastFeatureExtractor.extract(from: curve, at: now)
    }

    /// How the WeatherKit forecasts of the last 30 days actually did against the barometer.
    ///
    /// `nil` before an offset can be measured, which is also before there is anything to score.
    /// Only WeatherKit is scored here: the local model's own points are never archived — it is
    /// refitted from the barometer log rather than stored — so there is nothing to look back at.
    func skillReport(asOf now: Date) async -> ForecastSkillReport? {
        guard let offset = await offset(asOf: now) else { return nil }

        return try? await ForecastSkillEvaluator.evaluate(archive: archive,
                                                          samples: samples,
                                                          offset: offset,
                                                          asOf: now)
    }

    /// The calibrated WeatherKit curve, or empty.
    ///
    /// Empty — not approximate — whenever the offset cannot be measured or the newest issue is
    /// past the staleness norm. An uncalibrated curve sits ~22 hPa away from the user's own line
    /// and stretches the plot's domain threefold; a ten-day-old one is a different quantity
    /// wearing the current forecast's clothes. Falling through to the local model is the honest
    /// answer to both.
    private func weatherKitForecast(asOf now: Date,
                                    horizonSeconds: TimeInterval,
                                    anchored: Bool) async -> [ForecastPressurePoint] {
        guard let offset = await offset(asOf: now) else { return [] }

        // One hour back when the caller wants the anchor hour, so the row covering `now` is in
        // the read as well as in the curve.
        let start = now.addingTimeInterval(anchored ? -3600 : 0)
        let end = now.addingTimeInterval(min(horizonSeconds,
                                             ForecastSource.weatherKit.rangeSeconds))
        let window = start..<end
        // The leak guard travels with the read: even a chart may only draw what was knowable.
        // It is the same call the feature pipeline makes, so the picture and the model agree
        // about what the app knew.
        let points = (try? await archive.points(issuedAtOrBefore: now, validIn: window)) ?? []
        guard !points.isEmpty else { return [] }

        // The staleness gate is `curve`'s, not repeated here: it is the one place both the
        // chart and the feature pipeline pass through.
        return ForecastPressurePoint.curve(from: points,
                                           offset: offset,
                                           asOf: now,
                                           horizonSeconds: horizonSeconds,
                                           includingHourAt: anchored)
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
                               horizonSeconds: TimeInterval,
                               anchored: Bool) async -> [ForecastPressurePoint] {
        let epochID = (try? await epochs.currentEpoch())?.id

        if localModel == nil || localModelEpochID != epochID
            || localModel?.isStale(asOf: now) == true {
            let window = now.addingTimeInterval(
                -TimeInterval(LocalPressureModel.trainingWindowDays) * 24 * 3600
            )..<now.addingTimeInterval(1)
            let readings = (try? await samples.samples(in: window)) ?? []
            // Fitted on the readings taken **here**. A 30-day window that straddles a move
            // holds a step of tens of hPa in the middle of it, and an AR fit reads a step as
            // a trend to continue rather than as a change of address.
            localModel = LocalPressureModel.fit(
                to: LocationEpochResolver.readings(readings, takenAt: await samePlaceEpochIDs()),
                asOf: now
            )
            localModelEpochID = epochID
        }

        return localModel?.forecast(asOf: now,
                                    horizonSeconds: horizonSeconds,
                                    includingAnchorHour: anchored) ?? []
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
                                                                asOf: now,
                                                                atEpochs: await samePlaceEpochIDs())
        else {
            return nil
        }

        cachedOffset = (measured, now)
        cachedEpochID = epochID
        return measured
    }

    /// The epochs that count as "here", or `nil` when there is no epoch table to filter on.
    ///
    /// Read on the two paths that measure something from a window of history, and on neither
    /// of the cached ones. The table holds a few rows a year — a move of 25 km is what writes
    /// one — so this is a small fetch on a path already doing a 48-hour range query.
    private func samePlaceEpochIDs() async -> Set<UUID>? {
        guard let current = try? await epochs.currentEpoch() else { return nil }

        let all = (try? await epochs.allEpochs()) ?? [current]
        return LocationEpochResolver.samePlaceEpochIDs(as: current, among: all)
    }
}
