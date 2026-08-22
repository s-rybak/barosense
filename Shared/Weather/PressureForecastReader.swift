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

    /// The user's switch, read on **every** forecast rather than at construction.
    ///
    /// `WeatherForecastRefresher` reads the same switch to decide whether to make a request,
    /// and for a while that was thought to be enough. It is not: turning WeatherKit off stops
    /// new rows arriving and deliberately leaves the archive alone (§5, PR 2, criterion 4), so
    /// the curve on screen went on being drawn from the last issue until it aged past
    /// `WeatherForecastPolicy.maximumIssueAgeSeconds`. That is **up to twelve hours** of a
    /// switch that reads "off" above a chart still showing Apple's forecast, with the Apple
    /// Weather mark under it. Switched off has to mean off on the next read, and the next read
    /// is a second away — the barometer drives one on every sample.
    ///
    /// Synchronous and unstored, so there is nothing to invalidate: it is a `UserDefaults`
    /// boolean, and reading it costs less than deciding whether to.
    private let preferences: any WeatherKitPreferenceStore

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
         epochs: any PressureLocationEpochStore,
         preferences: any WeatherKitPreferenceStore) {
        self.archive = archive
        self.samples = samples
        self.epochs = epochs
        self.preferences = preferences
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

        // The one place the picture and the feature row are allowed to differ, and it is a
        // deliberate difference rather than a drift: a producer may be *drawn* further than it
        // may be *learned from*. The local model is drawn to 18 h so the chart can say
        // something about tonight with a band that admits how little it knows; a delta read
        // off that same 18-hour extrapolation would enter the vector as a plain number, look
        // exactly like WeatherKit's, and be trained on as if it were one.
        //
        // Points past the skill range are dropped rather than downweighted, which is the same
        // answer §2.2 gives everywhere else: outside a source's range the family is `nil`, not
        // a value with a caveat attached.
        let skilful = curve.filter {
            $0.timestamp <= now.addingTimeInterval($0.source.skillRangeSeconds)
        }

        return ForecastFeatureExtractor.extract(from: skilful, at: now)
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
        // First, and before the archive is even opened. The switch is about what the app may
        // *use*, not only about what it may fetch — see `preferences`. The rows stay on disk
        // untouched, which is what makes switching back on instant rather than a cold start.
        guard preferences.isWeatherKitEnabled() else { return [] }

        guard let offset = await offset(asOf: now) else {
            BarosenseLog.pressure.debug("forecast: no weatherKit curve — offset not measurable")
            return []
        }

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
        guard !points.isEmpty else {
            BarosenseLog.pressure.debug("forecast: no weatherKit curve — archive empty in window")
            return []
        }

        // The staleness gate is `curve`'s, not repeated here: it is the one place both the
        // chart and the feature pipeline pass through.
        let curve = ForecastPressurePoint.curve(from: points,
                                                offset: offset,
                                                asOf: now,
                                                horizonSeconds: horizonSeconds,
                                                includingHourAt: anchored)
        // Counts and states only, never a value — `BarosenseLog`'s rule. An empty curve here
        // means every archived row was issued past the staleness norm, which is the one gate
        // in this chain that is invisible from both the screen and the store.
        if curve.isEmpty {
            BarosenseLog.pressure.debug(
                "forecast: no weatherKit curve — \(points.count, privacy: .public) rows, all stale"
            )
        }

        return curve
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
            // Unstamped rows are kept. `PressureSample.locationEpochID` shipped with this
            // feature, so on an install that predates it the 30-day window is unstamped
            // history plus whatever has been recorded since the update — and dropping the
            // former leaves a device with weeks of readings unable to fit anything for a week
            // more. See `LocationEpochResolver.UnstampedPolicy` for why the offset calibrator
            // answers this differently.
            let here = LocationEpochResolver.readings(readings,
                                                      takenAt: await samePlaceEpochIDs(),
                                                      unstamped: .included)
            localModel = LocalPressureModel.fit(to: here, asOf: now)
            localModelEpochID = epochID

            // The cold-start gate, made visible. `fit` walks `specificationLadder` and returns
            // `nil` only when even AR(1) — two parameters, three rows of two consecutive hours —
            // cannot be supported, which is a log with essentially no consecutive hours in it.
            // Without this line the chart's forward half is simply absent, with nothing anywhere
            // saying which of the two producers fell short. Counts only, per `BarosenseLog`.
            if localModel == nil {
                // Both counts, because the gap between them is a whole class of failure: a log
                // full of readings that the epoch filter reduces to a handful looks identical
                // on screen to a log that is genuinely empty.
                BarosenseLog.pressure.debug("""
                    forecast: no local fit — \(readings.count, privacy: .public) readings, \
                    \(here.count, privacy: .public) after the epoch filter
                    """)
            }
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
