import Foundation

/// Owns the risk model: refits it, holds it, and answers "what about today".
///
/// ## Battery
///
/// **No new wake source.** Both paths run inside work the app was already doing — a foreground
/// activation, or the barometer's existing background refresh landing a reading. Nothing here
/// schedules a timer, registers an observer, or asks for a second background task identifier.
///
/// - **Refit**: at most once a day (`refitIntervalSeconds`), the same cadence
///   `LocalPressureModel` uses and for the same reason — the fit is over a 120-day window and
///   yesterday's coefficients are not meaningfully worse than today's. It reads rows already on
///   disk: no sensor, no network, no location, no HealthKit.
/// - **Forecast**: a short read (eight days of barometer rows plus the forward curve the chart
///   asked for anyway) memoised for `forecastCacheSeconds`, which is the barometer's own
///   sampling floor. A chart reload inside that window costs nothing. It stays eight days
///   because the 30-day baseline is measured once per refit and carried — see `baseline`.
///
/// The arithmetic: the fit is a Newton solve on a 10×10 system over at most ~1 000 window rows,
/// which is on the order of 10⁵ multiply–adds — an order of magnitude above
/// `LocalPressureModel`'s measured 16.6 ms, and still far inside the 100 ms at which the
/// forecast spec asks for the window to be reconsidered. Measured on device before this is
/// quoted anywhere as fact.
actor WellbeingRiskEngine {

    /// Whether the app produces a risk forecast at all.
    ///
    /// The kill switch `swift_conventions` requires for anything that changes forecast output.
    /// Off, `forecast(asOf:)` returns `nil` and every surface renders exactly as it did before
    /// this subsystem existed.
    static let isEnabled = true

    /// At most one refit a day.
    static let refitIntervalSeconds: TimeInterval = 24 * 3600

    /// How long a forecast is reused before it is recomputed.
    ///
    /// **15 minutes**, `PressureSamplingPolicy`'s own floor: below it there cannot be a new
    /// reading to change the answer, so recomputing would re-read eight days of rows to
    /// produce the same numbers.
    static let forecastCacheSeconds: TimeInterval = 15 * 60

    /// How far ahead the forward curve is asked for.
    ///
    /// **96 hours**, which is exactly what `PressureChartRange.day` draws of a WeatherKit curve.
    /// The two numbers are the same on purpose: every hour of forward line the chart can put on
    /// screen is an hour the model is asked about, so there is no stretch of drawn curve the app
    /// silently declines to score. It was 30 h while the forecast was one day, which left three
    /// of the four days on the widest button unscored.
    ///
    /// **No new wake source and no second read.** The chart already asks the same reader for
    /// `PressureChartRange.widest.maximumForecastSeconds` — the same 96 h — so this rides the
    /// same cached curve rather than adding a request. What grows is arithmetic: the hourly grid
    /// goes from ~9 days to ~12 (≈290 cells) and the scored windows from 9 to ~45, both of which
    /// are linear passes costing on the order of 10³ multiply–adds against the fit's 10⁵.
    static let forecastHorizonSeconds: TimeInterval = 96 * 3600

    private let samples: any PressureSampleStore
    private let checkIns: any CheckInStore

    /// The forward half. `nil` on a build with no forecast wiring, in which case the day's
    /// later windows are scored from measurement alone and the forecast is a statement about
    /// what has already happened — honest, and much less useful.
    private let forecastReader: PressureForecastReader?

    private let calendar: Calendar

    private var training: WellbeingRiskTraining?
    private var lastFitAt: Date?
    private var geometry: RiskWindowGeometry

    /// This user's trailing pressure median, measured over `RiskPressureBaseline.windowDays`.
    ///
    /// Held here because the two paths read different spans and the features have to be centred
    /// the same way on both. The refit reads 120 days, so it can measure the real 30-day
    /// median; the forecast reads eight, so it cannot — and left to measure its own it produced
    /// an eight-day median under a coefficient fitted against a thirty-day one. On a settled
    /// week that is a couple of hPa, and `dayLow7dHPa` carries it at 0.83 over a scale of 5.86:
    /// about 0.42 in log-odds, or ten points of the percentage on screen.
    ///
    /// Up to a day stale, which the quantity tolerates — a 30-day median does not move
    /// perceptibly in 24 h, and the case it exists to follow (a move to a different elevation)
    /// takes longer than that to matter.
    private var baseline: RiskPressureBaseline?

    private var cached: (forecast: WellbeingRiskForecast, at: Date)?

    init(samples: any PressureSampleStore,
         checkIns: any CheckInStore,
         forecast: PressureForecastReader? = nil,
         calendar: Calendar = .current) {
        self.samples = samples
        self.checkIns = checkIns
        self.forecastReader = forecast
        self.calendar = calendar
        self.geometry = RiskWindowGeometry(calendar: calendar)
    }

    /// Today's forecast, or `nil` when the device cannot support one.
    ///
    /// `nil` is ordinary and has several causes that are not worth distinguishing here: the
    /// switch above is off, there is no barometer, the log is too thin to place a baseline, or
    /// today is too thinly covered for a day-level average to mean anything. Every caller draws
    /// nothing rather than a placeholder number.
    func forecast(asOf now: Date = .now) async -> WellbeingRiskForecast? {
        guard Self.isEnabled else { return nil }

        if let cached, now.timeIntervalSince(cached.at) < Self.forecastCacheSeconds {
            return cached.forecast
        }

        await refitIfNeeded(asOf: now)

        guard let model = training?.model
                ?? WellbeingRiskModel.prior(dayStartHour: geometry.dayStartHour, trainedAt: now),
              let rows = await forwardRows(asOf: now),
              let forecast = model.forecast(for: rows, asOf: now)
        else { return nil }

        cached = (forecast, now)
        return forecast
    }

    /// The most recent validation run, or `nil` when there has not been one.
    ///
    /// For the log and for tests. Nothing user-facing reads it — a measured accuracy on screen
    /// is a claim about how well the app knows the user and needs a human decision first.
    func report() -> RiskModelReport? { training?.report }

    /// Forces the next call to refit and to rebuild, whatever the clocks say. Called when
    /// check-ins change under the model — a saved entry, or an erase.
    func invalidate() {
        lastFitAt = nil
        cached = nil
    }

    /// The most recent fit's baseline, for tests. Nothing user-facing reads it.
    func measuredBaseline() -> RiskPressureBaseline? { baseline }

    // MARK: - Fitting

    /// Refits, at most once a day.
    ///
    /// The throttle is on `lastFitAt` alone. It used to also require `training != nil`, which
    /// inverted it: a device with under `minimumTrainingDays` of history — the state every new
    /// install is in, and the longest-lived one — produced no training, failed the condition
    /// every time, and re-read 120 days of samples and check-ins on every cache miss, which is
    /// every 15 minutes. A fit that declined to happen is still an answer for today, and
    /// `invalidate()` is what makes a new check-in visible before tomorrow.
    ///
    /// `lastFitAt` is set only after the reads succeed, so a store that could not be opened is
    /// retried on the next call rather than waited out for a day.
    private func refitIfNeeded(asOf now: Date) async {
        if let lastFitAt, now.timeIntervalSince(lastFitAt) < Self.refitIntervalSeconds {
            return
        }

        let window = now.addingTimeInterval(-Double(WellbeingRiskTrainer.trainingWindowDays) * 24 * 3600)
            ..< now
        guard let history = try? await samples.samples(in: window),
              let entries = try? await checkIns.checkIns(in: window)
        else { return }

        geometry = RiskWindowGeometry.measured(from: entries, calendar: calendar)

        // Measured here and nowhere else: this is the only read wide enough to contain the
        // whole baseline window.
        baseline = RiskWindowBuilder.baseline(observed: history, asOf: now)

        let rows = RiskWindowBuilder.rows(observed: history,
                                          checkIns: entries,
                                          geometry: geometry,
                                          baseline: baseline,
                                          in: window,
                                          asOf: now)

        lastFitAt = now
        guard let fitted = WellbeingRiskTrainer.train(rows: rows, geometry: geometry, asOf: now)
        else {
            training = nil
            return
        }

        training = fitted
        if let report = fitted.report {
            for line in report.logLines {
                BarosenseLog.pressure.info("risk model \(line, privacy: .public)")
            }
        }
    }

    // MARK: - The days ahead

    /// Every waking window from the day containing `now` out to the end of the forward curve.
    ///
    /// Whole waking days only. A day the horizon cuts in half would carry day-level features
    /// that are the mean of a morning under the name of a day, which is exactly what
    /// `RiskWindowBuilder.minimumDayCoverage` exists to reject — so it is cheaper to ask for the
    /// whole day and let that gate drop it than to invent a short one here.
    private func forwardRows(asOf now: Date) async -> [RiskWindowRow]? {
        let dayStart = geometry.wakingDayStart(of: now)
        let horizon = now.addingTimeInterval(Self.forecastHorizonSeconds)
        let lastDayStart = max(geometry.wakingDayStart(of: horizon), dayStart)
        let dayEnd = lastDayStart.addingTimeInterval(
            Double(geometry.windowsPerDay) * geometry.windowSeconds
        )

        // Eight days back: seven for the trailing mean, one for the 24-hour fall at the first
        // window of the day. Deliberately not the baseline's thirty — that median is carried
        // from the refit instead, so this read stays short and both paths centre their level
        // features on the same number. No baseline, no forecast: a level feature centred on a
        // guess is the confidently-wrong value the registry rules out.
        let historyFrom = dayStart.addingTimeInterval(-(RiskPressureGrid.historySeconds + 24 * 3600))
        guard let baseline,
              historyFrom < now,
              let history = try? await samples.samples(in: historyFrom..<now)
        else { return nil }

        let curve = await forecastReader?.forecast(asOf: now,
                                                   horizonSeconds: Self.forecastHorizonSeconds) ?? []

        // `max(dayStart, now)`, because before the user wakes `now` is *earlier* than the day
        // this forecast is about: at 03:00 with a 06:00 boundary the whole waking day is still
        // ahead, and `dayStart..<now` is a range running backwards. The window is then empty,
        // which is also the truth — nothing can have been logged in a day that has not started.
        let entries = (try? await checkIns.checkIns(in: dayStart..<max(dayStart, now))) ?? []

        let rows = RiskWindowBuilder.rows(observed: history,
                                          forecast: curve,
                                          checkIns: entries,
                                          geometry: geometry,
                                          baseline: baseline,
                                          in: dayStart..<dayEnd,
                                          asOf: now)
        return rows.isEmpty ? nil : rows
    }
}
