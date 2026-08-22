import Foundation

/// The forecast the app can make from the user's own barometer alone.
///
/// ## Why this is small on purpose
///
/// One sensor at one point cannot see advection. It has no way to know about a front 200 km
/// away, and no amount of history changes that — a five-year log and a five-day log are equally
/// blind to weather that has not arrived yet. On 1–3 h horizons linear extrapolation is close to
/// unbeatable; past that, skill decays toward climatology.
///
/// So the **skill** range is **3–6 h** with a band that opens fast, and that is a decision
/// confirmed by a human rather than a default to be improved on. An agent minded to "finish it
/// off to 24 hours" has to re-read `.claude/context/pressure-forecast-spec.md` §4.7 and produce
/// a measurement first — `ForecastSource.skillRangeSeconds` is the number that claim attaches
/// to, and it is what the feature pipeline reads.
///
/// The curve is **drawn** to 18 h (`ForecastSource.rangeSeconds`, a human decision of
/// 2026-08-22) so the day button has a forward half at all — three times the skill range, not
/// six, after the same decision was narrowed from 36 h that day. Those two numbers being
/// different is the honest arrangement: past ~6 h the band is what the user is looking at, and
/// by 18 h it is twice a day's whole weather. What must not happen is the model learning from
/// the far end, and `PressureForecastReader.features` is where that is ruled out.
///
/// ## It fits the *change*, not the level
///
/// The regression target is the hourly change `y_t − y_{t−1}`, and the regressors are the
/// changes before it. That is not a refinement of fitting levels — it is what keeps the forward
/// iteration from diverging, and the first version of this type shipped without it.
///
/// Station pressure is very nearly a random walk: its lag-1 autocorrelation over an hour is
/// ~0.99, so an unconstrained least-squares fit on **levels** is estimating a root that sits
/// almost exactly on the unit circle, from a handful of rows, with no term stopping it from
/// landing outside. When it does, the forward iteration compounds it once per step and the
/// curve leaves the atmosphere. Measured on this project's own device log on 2026-08-22 — 30
/// observed hourly cells over three days — the fitted level polynomial had a root at
/// **|λ| = 1.207**, and the drawn curve read 1001 hPa at one hour, 1011 at six and **1139 at
/// eighteen**. On screen that is a line that starts flat and then leaves the top of the card,
/// which is exactly what a human reported.
///
/// Differencing imposes the unit root instead of estimating it, which is the standard answer
/// for a near-unit-root series and is also the physically honest one: what the sensor can see
/// is a **tendency**, and the question is how long a tendency lasts, not where the level is
/// heading. `maximumTendencyPersistence` then bounds that lifetime, so the model cannot claim
/// a trend outlives the weather system that made it.
///
/// The remaining structure is unchanged: `S1`/`S2` still enter as regressors, because the
/// derivative of a sinusoid is a sinusoid of the same period — the tide is as visible in the
/// change as it is in the level, and summing a zero-mean oscillation over the forward window
/// leaves the curve bounded.
///
/// ## Why least squares and not Core ML
///
/// The model has one thing to know that persistence does not: the **solar semidiurnal tide**,
/// `S2`. It is deterministic, it follows from the time of day, and at Kyiv's latitude it is
/// order 0.3–0.5 hPa (*provisional* — a literature order of magnitude, to be checked against
/// real traces). Below the 1.0 hPa threshold this app calls meaningful, but it is free skill
/// that persistence cannot have. Three lagged tendencies carry the trend and its curvature.
///
/// Seven parameters, closed-form least squares, a 30-day window of 720 hourly points: about
/// **35 000 multiply-adds**, which is microseconds. A daily refit therefore needs **no new wake
/// source** and fits inside a foreground activation — `CLAUDE.md` constraint 4 satisfied by
/// there being nothing to schedule.
///
/// ## Seven parameters is the ceiling, not the size
///
/// A phone does not record 24 hourly cells a day. iOS grants `BGAppRefreshTask` sparsely and
/// grants nothing overnight, so a real log is a run of waking hours beside a 12-plus-hour hole,
/// and a hole restarts the count of consecutive cells a design row needs. A fixed largest fit
/// therefore asked for more rows than an ordinary day of use produces, and returned `nil` —
/// no forward half at all — on exactly the cold start it exists to serve.
///
/// So the size is chosen from the data: `specificationLadder` tries 3 lags + S1 + S2, then 3
/// lags, 2, 1, and takes the first the log supports. Fewer lags cost a parameter *and* buy
/// rows, which is what makes the ladder work rather than merely lower the bar.
///
/// `MLUpdateTask` and Core ML stay in reserve for the day a measurement shows linearity is the
/// binding constraint. Starting with them would be paying for machinery that holds nothing yet.
struct LocalPressureModel: Sendable {

    /// Lagged hourly **changes** in the richest specification: this hour's change depends on
    /// the three before it.
    ///
    /// Three carries trend, its persistence and its curvature — enough for the shape of a
    /// passing ridge or trough. A fourth buys little at these horizons and costs a parameter
    /// out of a budget that is already tight on one day of data.
    ///
    /// A fit may land on fewer — see `Specification` and `specificationLadder`.
    static let tendencyLagCount = 3

    /// Which terms one candidate fit carries.
    ///
    /// The model is fitted at the largest size the log actually supports rather than at one
    /// fixed size, because the two move in opposite directions: a design row for *k* lagged
    /// changes needs *k + 2* consecutive hours behind it, so **dropping a lag both costs a
    /// parameter and buys rows**. On a real log — a phone put down overnight, iOS granting no
    /// background wakes — that difference is the whole feature. Measured on this project's own
    /// device log, 30 observed hourly cells over three days:
    ///
    /// | specification    | parameters | design rows | rows/parameter |
    /// | ---------------- | ---------: | ----------: | -------------: |
    /// | 3 lags + S1 + S2 |          7 |          20 |            2.9 |
    /// | 3 lags           |          3 |          20 |            6.7 |
    /// | 2 lags           |          2 |          23 |           11.5 |
    /// | 1 lag            |          1 |          26 |           26.0 |
    ///
    /// One consecutive hour more per row than the level fit this replaced, which is what
    /// differencing costs: the target is a change, so it spends a cell of its own.
    struct Specification: Hashable, Sendable {

        /// How many lagged hourly changes the row carries. 1…`tendencyLagCount`.
        let tendencyLags: Int

        /// Whether the solar S1/S2 harmonics are fitted.
        let includesHarmonics: Bool

        /// Lags + (4 harmonic terms). **No intercept**, and that is a decision rather than an
        /// omission: a constant in an equation whose target is a change is a permanent drift,
        /// and eighteen steps of it is a straight ramp with nothing to stop it. The level fit
        /// this replaced carried one, and its estimate implied a long-run level 21 hPa away
        /// from the window mean — a number no barometer log of three days can support.
        var parameterCount: Int {
            tendencyLags + (includesHarmonics ? 4 : 0)
        }

        /// Consecutive hourly cells one design row needs: the target's own hour, the hour
        /// before it that makes the target a change, and one more per lag.
        var consecutiveHoursPerRow: Int { tendencyLags + 2 }

        /// Rows below which this specification is not attempted.
        ///
        /// Two guards, and the lower rungs need both. The ratio is derived from
        /// `minimumRowsPerParameter` rather than written out per size, so there is one number to
        /// argue with instead of four. On its own, though, it lets a one-lag fit sit on two rows
        /// — and three readings is not a model however favourable the ratio looks.
        ///
        /// So `absoluteMinimumRows` floors it. The two together give 11 / 6 / 6 / 6 down the
        /// ladder.
        var minimumRows: Int {
            max(LocalPressureModel.absoluteMinimumRows,
                Int((LocalPressureModel.minimumRowsPerParameter
                     * Double(parameterCount)).rounded(.up)))
        }
    }

    /// Candidate specifications, richest first. The first one the log supports is the fit.
    ///
    /// **Harmonics go before lags.** S1/S2 are worth order 0.3–0.5 hPa at this latitude —
    /// below the 1.0 hPa this app calls meaningful — and they cost **four** parameters, more
    /// than half the budget, for the smallest term in the model. The lags carry the tendency
    /// and how long it lasts, which is the forecast itself. Giving up most of the parameters
    /// for a term under the significance threshold is the cheapest trade available, so it is
    /// taken first.
    static var specificationLadder: [Specification] {
        isOrderLadderEnabled ? fullLadder : [richestSpecification]
    }

    static let richestSpecification = Specification(tendencyLags: tendencyLagCount,
                                                    includesHarmonics: true)

    private static let fullLadder = [
        richestSpecification,
        Specification(tendencyLags: 3, includesHarmonics: false),
        Specification(tendencyLags: 2, includesHarmonics: false),
        Specification(tendencyLags: 1, includesHarmonics: false)
    ]

    /// Feature flag for the ladder (`.claude/skills/swift_conventions/SKILL.md`: anything that
    /// changes forecast output can be switched off without a release).
    ///
    /// `false` restores the single fixed largest fit.
    static let isOrderLadderEnabled = true

    /// Rows a specification needs per parameter before it is attempted.
    ///
    /// **1.5** — the ratio this model has always been fitted at, stated once and applied at
    /// every size instead of only the largest.
    ///
    /// It is thin, and it is allowed to be thin only because the band is computed from the
    /// **residual degrees of freedom** (`design.count − parameterCount`) rather than from the
    /// row count. A fit with two degrees of freedom left reports a visibly wider band than one
    /// with thirty-eight, which is the model saying it knows less — the alternative, a narrow
    /// band from an overfitted residual, is the confidently-wrong output the pipeline rules
    /// forbid.
    static let minimumRowsPerParameter: Double = 1.5

    /// Rows no fit may go below, whatever its size.
    ///
    /// **Six — the skill range, in hours.** A design row is one hour at which the model could
    /// check itself against the hours before it, so this says: a model may not project further
    /// ahead than the number of transitions it has actually observed. `ForecastSource.localModel`
    /// claims skill six hours out, so six is the fewest checks that can stand behind that claim.
    ///
    /// Derived from `skillRangeSeconds` and **not** from `rangeSeconds`, which is 18 h.
    /// Reading the drawn range here would demand eighteen consecutive hourly cells before any
    /// fit at all — a cold-start gate three times harsher, imposed by a change to how far the
    /// chart draws, which is exactly the kind of coupling the two constants exist to break. The
    /// drawn range has already moved twice; this number has not, which is the point.
    ///
    /// It binds on every rung below the top, where the ratio alone would admit a one-lag fit on
    /// two rows. Three readings is not a model — returning `nil` is the honest answer, and the
    /// chart draws no forward half instead.
    static let absoluteMinimumRows =
        Int(ForecastSource.localModel.skillRangeSeconds / 3600)

    /// How much history the fit sees.
    ///
    /// **30 days**, 720 hourly cells. Long enough for the diurnal harmonics to be identifiable
    /// against weather noise, short enough that a seasonal change in their amplitude is not
    /// averaged into a year-round compromise — and short enough that the fit stays microseconds.
    static let trainingWindowDays = 30

    /// Rows below which the **richest** specification is not attempted. **11.**
    ///
    /// It used to be the only gate, and the claim attached to it — "reachable on a single day
    /// of data" — assumed 24 hourly cells a day. A phone does not deliver that: iOS grants
    /// `BGAppRefreshTask` sparsely and grants nothing at all overnight, so a real day is a run
    /// of waking hours with a 12-plus-hour hole beside it, and a hole restarts the count of
    /// consecutive cells. The cold start is met by `specificationLadder` now, not by this
    /// number.
    static let minimumTrainingRows = richestSpecification.minimumRows

    /// How often the fit is renewed. Daily: the coefficients move on the timescale of the
    /// weather regime, not of an activation.
    static let refitIntervalSeconds: TimeInterval = 24 * 3600

    /// Ridge term, relative to the mean diagonal of the normal matrix.
    ///
    /// Tiny, and not there for regularisation in the statistical sense. It is there so that a
    /// perfectly flat log — a phone on a desk in stable air — produces a solvable system
    /// instead of a singular one. Without it the §8 zero-variance fixture crashes rather than
    /// degrading.
    static let ridge: Double = 1e-6

    /// The largest root modulus the fitted tendency polynomial is allowed to keep. **0.9.**
    ///
    /// This is the number that bounds the forecast, and it is chosen from a timescale rather
    /// than from taste. A tendency that decays as `r` per hour has an e-folding life of
    /// `−1 / ln r` hours: 0.9 gives **9.5 h**, the order of a mid-latitude trough's passage.
    /// The alternatives are not close. 0.98 grants the tendency a 49-hour memory — still 70%
    /// alive a full day later, which no barometer trace does — and 0.999 grants it forty days.
    ///
    /// It also bounds what the curve may claim, because a geometrically decaying tendency sums
    /// to `d × r / (1 − r)`: nine times the last hourly change. A 0.6 hPa/h rise, the trace this
    /// was measured on, therefore tops out near **5 hPa** over the whole 18 h; a barometer
    /// falling at a violent 2 hPa/h tops out near 18, which is bomb-cyclone scale and inside
    /// what the atmosphere does. At 0.98 the same two traces would be allowed 28 and 98 hPa.
    ///
    /// Enforced by scaling rather than by rejection — `stabilised(_:)` multiplies every root by
    /// the same factor, which leaves the near-term shape the fit actually measured and only
    /// shortens the tail. Rejection would put a cliff between a fit at 0.90 and one at 0.91,
    /// and it would not bound the claim at all: a root at 0.999 is stable and still draws a
    /// straight ramp for eighteen hours.
    ///
    /// *Provisional* in the same sense as the band constants: the shape of the argument is
    /// physical, the digit is reasoned. PR 4's realised-skill report is what replaces it.
    static let maximumTendencyPersistence: Double = 0.9

    /// The residual spread a band of nominal width is quoted against. Above this, the band is
    /// inflated in proportion.
    ///
    /// Unchanged by the move to tendencies, and it did not need changing: a one-step residual
    /// is `y_t − ŷ_t` whether the equation was written about the level or about the change, so
    /// this is measured against exactly the same quantity as before.
    static let referenceResidualHPa: Double = 0.8

    /// Coverage below which the band stops widening further, so a nearly empty log produces a
    /// very wide band rather than an infinite one.
    static let minimumCoverageForBand: Double = 0.2

    /// Which terms this fit carries. Everything that reads `coefficients` or `recentValues` has
    /// to know their width, and the width is no longer fixed.
    let specification: Specification

    /// `[lag1 … lagK]` over hourly **changes**, plus `[sinS1, cosS1, sinS2, cosS2]` when
    /// `specification.includesHarmonics`. No intercept — see `Specification.parameterCount`.
    ///
    /// Already stabilised: the lag block is what `stabilised(_:)` returned, not the raw
    /// least-squares solution. Nothing downstream has to remember to apply it.
    let coefficients: [Double]

    /// Modulus of the largest root of the fitted tendency polynomial, after stabilising.
    ///
    /// At most `maximumTendencyPersistence`. Stored because it is the one number that says how
    /// long this fit thinks a trend lasts, and because a fit that had to be pulled a long way
    /// down is a fit whose own history it now describes less well — which is visible in
    /// `residualStandardDeviationHPa`, measured after the pull.
    let tendencyPersistence: Double

    /// Root-mean-square one-step residual, hPa. What the band is scaled from.
    ///
    /// Computed against the **stabilised** coefficients, so damping an explosive fit widens the
    /// band it is drawn with instead of hiding behind the residual of a model that is no longer
    /// the one being projected.
    let residualStandardDeviationHPa: Double

    /// Fraction of the observed span actually recorded. Feeds the band, so a log full of holes
    /// produces a visibly less certain forecast rather than a confident one.
    ///
    /// Deliberately **not** a fraction of the 30-day window: see
    /// `HourlyPressureGrid.observedSpan(of:in:)`. Hours before the app was installed are not
    /// missing data, and a cold start is the state this model exists to serve.
    let coverage: Double

    let rowCount: Int

    /// The hour the fit ends at — the last cell it saw. Projections step forward from here.
    let lastHour: Date

    /// The `specification.tendencyLags + 1` most recent consecutive hourly levels, newest last.
    ///
    /// One more than there are lags, because the seed for the forward iteration is a run of
    /// **changes** and *k* changes need *k + 1* levels. `last` is also the level the curve is
    /// anchored at, which is why the two are kept as one array rather than as a level and a
    /// list of differences that could drift apart.
    let recentValues: [Double]

    let fittedAt: Date
}

extension LocalPressureModel {

    /// Fits the model, or `nil` when there is not enough to fit.
    ///
    /// `nil` is an ordinary outcome — a fresh install, a phone that was off — and the caller's
    /// answer to it is to draw no forward half at all. A model fitted on four points would
    /// produce a line, and a line is a claim.
    ///
    /// Pure and synchronous: §8 requires the pipeline to run from XCTest with synthetic input
    /// and no `CMAltimeter` anywhere.
    static func fit(to samples: [PressureSample],
                    asOf now: Date,
                    windowDays: Int = trainingWindowDays) -> LocalPressureModel? {
        let window = now.addingTimeInterval(-TimeInterval(windowDays) * 24 * 3600)..<now
            .addingTimeInterval(3600)
        let cells = HourlyPressureGrid.cells(from: samples, in: window)

        // Richest first, and the first one the log supports wins. Ordering is the whole
        // decision: this must never return a smaller fit while a larger one was available.
        return specificationLadder.lazy
            .compactMap { fit(cells: cells, to: $0, in: window, asOf: now) }
            .first
    }

    /// One candidate fit, or `nil` when the log does not support this specification.
    private static func fit(cells: [HourlyPressureGrid.Cell],
                            to specification: Specification,
                            in window: Range<Date>,
                            asOf now: Date) -> LocalPressureModel? {
        let span = specification.consecutiveHoursPerRow - 1
        guard cells.count > span else { return nil }

        let values = cells.map(\.hectopascals)

        var design: [[Double]] = []
        var targets: [Double] = []

        for index in span..<cells.count {
            // The hours have to be *consecutive*. A row whose lags straddle a hole would be
            // telling the fit that a twelve-hour jump was a one-hour change, which is how a gap
            // becomes a learned trend — and on a differenced target it is worse than it was on
            // a level one, because the whole jump lands in a single value the fit reads as one
            // hour's weather.
            let observed = cells[index].hour.timeIntervalSince(cells[index - span].hour)
            guard abs(observed - Double(span) * 3600) < 1 else { continue }

            let changes = (0...specification.tendencyLags).map {
                values[index - $0] - values[index - $0 - 1]
            }

            design.append(row(tendencies: Array(changes.dropFirst()),
                              hour: cells[index].hour,
                              specification: specification))
            targets.append(changes[0])
        }

        guard design.count >= specification.minimumRows,
              let solution = solveNormalEquations(design: design, targets: targets)
        else {
            return nil
        }

        // The stabilising step, before anything else reads the coefficients. Everything below
        // — the residual, the band, the projection — is about the model that will actually be
        // drawn, not about the one least squares handed back.
        let lags = Array(solution.prefix(specification.tendencyLags))
        let persistence = tendencyPersistence(of: lags)
        let stableLags = stabilised(lags, at: persistence)
        let coefficients = stableLags + solution.dropFirst(specification.tendencyLags)

        // A rung with no harmonics may not keep an oscillating lag block. There is exactly one
        // cycle this app claims to know about, and it has four terms of its own; when those are
        // not affordable the lags are the only place the tide can go, and a lag block that has
        // absorbed it extrapolates it as its own dynamics. Measured on the waking-day fixture,
        // which is a fall with the tide flattening it: the two-lag rung identified the tide as
        // a 20-hour oscillation from a nine-hour window and turned the fall into a **rise** by
        // the second step, scoring RMSE 0.60 hPa over 1–6 h against persistence's 0.35. The
        // one-lag rung below it scores 0.22. Falling through is how the ladder already says
        // "this log does not support this specification", and this is that — read off the fit
        // rather than off the row count.
        //
        // Not applied when the harmonics are fitted: there the tide has its proper home, the
        // lags carry trend, and rejecting them costs real skill (0.03 against 0.35 on a flat
        // log). Damping does not change this either way — scaling every root by one factor
        // leaves their arguments alone — so the check reads the same before it and after.
        if !specification.includesHarmonics, tendencyReversesWhenDrawn(stableLags) {
            return nil
        }

        let residuals = zip(design, targets).map { row, target in
            target - dot(coefficients, row)
        }
        // Divided by the **residual degrees of freedom**, not by the row count. Dividing by `n`
        // understates the spread by `sqrt(n / (n − p))`, which is 10% on a full 30-day fit and
        // **73%** on a six-row one — exactly backwards, since the thin fit is the one whose band
        // has to open. This is what lets `minimumRowsPerParameter` be as low as it is.
        let degreesOfFreedom = max(1, design.count - specification.parameterCount)
        let residualSD = (residuals.reduce(0) { $0 + $1 * $1 } / Double(degreesOfFreedom))
            .squareRoot()

        // The seed obeys the same consecutive-hours rule the design rows do, and for the same
        // reason: `cells` omits holes, so the last entries can be an hour apart at one end and
        // twelve at the other. Handed to the forward iteration as this hour's change, that says
        // half a day of drift happened in one hour. Measured on a twelve-hour overnight gap it
        // moved the first step by 1.3 hPa — above the 1.0 hPa this app calls meaningful — while
        // the band grew 1.5%, because `coverage` is a statement about the whole window and
        // cannot see a hole at the end of it.
        guard let seed = seed(in: cells, length: specification.tendencyLags + 1),
              let lastHour = seed.last?.hour else { return nil }

        return LocalPressureModel(
            specification: specification,
            coefficients: coefficients,
            tendencyPersistence: min(persistence, maximumTendencyPersistence),
            residualStandardDeviationHPa: residualSD,
            // Measured over the span the log reaches across, not over the nominal window.
            // A one-day-old install has 29 days of window that could not have been recorded,
            // and counting those as holes was inflating a perfectly complete cold-start log's
            // band fivefold — ±22 hPa at six hours, which then set the chart's whole y-domain.
            coverage: HourlyPressureGrid.coverage(
                of: cells,
                in: HourlyPressureGrid.observedSpan(of: cells, in: window)
            ),
            rowCount: design.count,
            lastHour: lastHour,
            recentValues: seed.map(\.hectopascals),
            fittedAt: now
        )
    }

    /// The latest run of `length` consecutive hourly cells, oldest first.
    ///
    /// Walks back from the end rather than taking the last few outright. After a gap the
    /// newest cells are not neighbours, and the honest anchor is the last hour at which the
    /// sensor really did record a run — everything after it is a hole, not a trend.
    ///
    /// A model anchored before a gap then says very little, because
    /// `forecast(asOf:horizonSeconds:)` measures its range from the anchor: an anchor eighteen
    /// hours old produces no curve at all, which is the right amount for a model whose whole
    /// drawn range is eighteen hours to say about a stretch it did not observe.
    private static func seed(in cells: [HourlyPressureGrid.Cell],
                             length: Int) -> [HourlyPressureGrid.Cell]? {
        guard cells.count >= length else { return nil }

        for end in stride(from: cells.count, through: length, by: -1) {
            let run = Array(cells[(end - length)..<end])
            guard let first = run.first?.hour, let last = run.last?.hour else { continue }

            let observed = last.timeIntervalSince(first)
            if abs(observed - Double(length - 1) * 3600) < 1 { return run }
        }

        return nil
    }

    /// The forward curve, hourly, from the first whole hour after `now`.
    ///
    /// Clipped to `ForecastSource.localModel.rangeSeconds` whatever is asked for, and clipped
    /// **from `lastHour`** rather than from `now`. A caller that wants 96 hours gets 18, silently
    /// and on purpose: the range is a property of the producer, not a parameter. A caller asking
    /// after a long gap gets less, or nothing — the range is 18 hours of extrapolation from the
    /// last observed hour, and a gap has already spent some of it.
    ///
    /// 18 h is how far this is **drawn**, not how far it is believed: the band reaches ±11.6 hPa
    /// there, and `PressureForecastReader.features` cuts the same curve back to
    /// `skillRangeSeconds` before the model ever sees it.
    ///
    /// The iteration carries a **level and a tendency**. Each step predicts the next hourly
    /// change from the changes before it, feeds that change back in as a lag, and adds it to the
    /// running level — so the curve starts from the last hour the sensor actually recorded and
    /// continues the trend it was on, rather than being pulled toward a thirty-day mean that a
    /// three-day log does not have. Because `tendencyPersistence` is below one, the predicted
    /// change decays geometrically and the level converges instead of ramping.
    ///
    /// `includingAnchorHour` adds the hour **containing** `now` — the level every delta in
    /// `ForecastPressureFeatures` is measured against. The chart does not want it, because that
    /// hour is behind the `now` divider and the past half of the plot is measurements; the
    /// feature pipeline cannot do without it, because "change over the next six hours" with no
    /// starting value is a change over five.
    ///
    /// For a fresh fit the anchor is the last hour the model actually observed. For a fit whose
    /// log has gone quiet it is the model's own projection for that hour, arrived at by the
    /// same iteration as every other point — which is the honest answer in both cases: the
    /// anchor is where the model thinks it is standing.
    func forecast(asOf now: Date,
                  horizonSeconds: TimeInterval,
                  includingAnchorHour anchored: Bool = false) -> [ForecastPressurePoint] {
        let horizon = min(horizonSeconds, ForecastSource.localModel.rangeSeconds)
        guard horizon >= 3600, let anchorLevel = recentValues.last else { return [] }

        // The window an anchor may come from: the hour containing `now`, matching
        // `ForecastPressurePoint.curve`'s own `lowerBound` so both producers anchor alike.
        let anchorWindow = now.addingTimeInterval(-3600)

        // The observed changes, newest first — the same order the coefficients are in.
        var tendencies = zip(recentValues.dropFirst(), recentValues)
            .map { $0 - $1 }
            .reversed()
            .map { $0 }
        var level = anchorLevel
        var hour = lastHour
        var points: [ForecastPressurePoint] = []

        if anchored, lastHour > anchorWindow, lastHour <= now {
            points.append(ForecastPressurePoint(timestamp: lastHour,
                                                pressure: Pressure(hectopascals: anchorLevel),
                                                uncertaintyHPa: uncertaintyHPa(atLeadSeconds: 0),
                                                source: .localModel,
                                                issuedAt: now))
        }

        while true {
            hour = hour.addingTimeInterval(3600)

            // Two clips, answering two different questions. `stepsAhead` is how far the
            // iteration has walked from the last hour the model actually saw, and that is what
            // its range is a statement about — 18 hours of *extrapolation*, not 18 hours of
            // wall clock. `lead` is how far past `now` the point sits, which is what the chart
            // asked for. A log whose last cell is five hours old therefore speaks 13 hours into
            // the future rather than 18.
            let stepsAhead = hour.timeIntervalSince(lastHour)
            guard stepsAhead <= ForecastSource.localModel.rangeSeconds else { break }

            let lead = hour.timeIntervalSince(now)
            if lead > horizon { break }

            let change = dot(coefficients,
                             Self.row(tendencies: tendencies,
                                      hour: hour,
                                      specification: specification))
            tendencies = [change] + tendencies.dropLast()
            level += change

            // Hours already past — the log's last cell can be a couple of hours old — are
            // stepped through to carry the tendency forward, but never drawn: they are not a
            // forecast, they are a gap the sensor left. The one exception is the anchor hour,
            // and only when a caller asked for it.
            guard lead > 0 || (anchored && hour > anchorWindow) else { continue }

            points.append(ForecastPressurePoint(
                timestamp: hour,
                pressure: Pressure(hectopascals: level),
                // From the anchor, for the reason the clip is: each step feeds its own output
                // back in as a lag, so a point six steps out carries six steps of compounded
                // error however recently the user opened the app.
                uncertaintyHPa: uncertaintyHPa(atLeadSeconds: stepsAhead),
                source: .localModel,
                // A local forecast is knowable the moment it is computed, which is `now`. Any
                // earlier stamp would let a feature at `t` read a curve the device had not
                // fitted yet — the same leak the archive's `issuedAt` guards against.
                issuedAt: now
            ))
        }

        return points
    }

    /// Band half-width at a lead time, hPa.
    ///
    /// The source's nominal band, inflated by two things the fit actually measured: how badly
    /// it fits its own history, and how much of that history was there. A log with a
    /// twelve-hour hole in it produces a visibly wider band, which is the point — the model
    /// knows less, and the chart says so.
    func uncertaintyHPa(atLeadSeconds lead: TimeInterval) -> Double {
        let nominal = ForecastSource.localModel.uncertaintyHPa(atLeadSeconds: lead)
        let residualInflation = max(1, residualStandardDeviationHPa
                                    / LocalPressureModel.referenceResidualHPa)
        let coverageInflation = 1 / max(coverage, LocalPressureModel.minimumCoverageForBand)

        return nominal * residualInflation * coverageInflation
    }

    /// Whether this fit is old enough to be worth renewing.
    func isStale(asOf now: Date) -> Bool {
        now.timeIntervalSince(fittedAt) >= LocalPressureModel.refitIntervalSeconds
    }

    // MARK: - The fit itself

    /// One design row: the lagged hourly changes, and the two diurnal harmonics.
    ///
    /// `tendencies` is newest-first. The harmonics are functions of the hour being projected,
    /// not of the lags, which is what lets the model carry a time-of-day shape through a forward
    /// iteration where the lags are its own output.
    private static func row(tendencies: [Double],
                            hour: Date,
                            specification: Specification) -> [Double] {
        guard specification.includesHarmonics else { return tendencies }

        // Hour of day as a fraction, from the epoch. UTC rather than the user's calendar: S1
        // and S2 are solar tides and their phase is a property of the sun's position, and a
        // model refitted after a time-zone change must not have its harmonics jump by an hour.
        let secondsIntoDay = hour.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let angle = 2 * Double.pi * secondsIntoDay / 86_400

        return tendencies + [sin(angle), cos(angle), sin(2 * angle), cos(2 * angle)]
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        LocalPressureModel.dot(lhs, rhs)
    }

    // MARK: - Stability

    /// The lag coefficients with every root pulled inside `maximumTendencyPersistence`.
    ///
    /// Scaling lag *j* by `γ^j` multiplies **every** root of `zᵏ − ψ₁zᵏ⁻¹ − … − ψₖ` by `γ`,
    /// exactly and without finding any of them: substituting `γz` into the scaled polynomial
    /// gives `γᵏ` times the original. So one factor, applied per lag, moves the whole root set
    /// and leaves the fit's shape — the relative weight of one hour against the next — intact.
    ///
    /// A fit already inside the limit is returned untouched, which is the ordinary case.
    static func stabilised(_ lags: [Double], at persistence: Double) -> [Double] {
        guard persistence > maximumTendencyPersistence, persistence > 0 else { return lags }

        let factor = maximumTendencyPersistence / persistence
        return lags.enumerated().map { $1 * pow(factor, Double($0 + 1)) }
    }

    /// Modulus of the largest root of `zᵏ − ψ₁zᵏ⁻¹ − … − ψₖ`.
    ///
    /// Found by bisection on an exact stability test rather than by a root finder, because the
    /// only thing needed is the modulus of the dominant root and a complex-arithmetic solver
    /// for the general cubic is a great deal of code to get one number. Scaling the lags by
    /// `1/c` divides every root by `c`, so "is the scaled polynomial stable" answers "is the
    /// radius below `c`" — a monotone predicate, which is all bisection needs.
    ///
    /// Bounded above by Cauchy's `max(1, Σ|ψⱼ|)`, and 48 halvings put the answer inside 1e-13
    /// of the true modulus. At `k ≤ 3` the whole thing is a few hundred flops, once per refit.
    static func tendencyPersistence(of lags: [Double]) -> Double {
        let cauchy = max(1, lags.reduce(0) { $0 + abs($1) })
        guard cauchy > 0, lags.contains(where: { $0 != 0 }) else { return 0 }

        var low = 0.0
        var high = cauchy
        for _ in 0..<48 {
            let middle = (low + high) / 2
            guard middle > 0 else { break }

            let scaled = lags.enumerated().map { $1 / pow(middle, Double($0 + 1)) }
            if isStable(scaled) { high = middle } else { low = middle }
        }

        return high
    }

    /// Whether a shock to the tendency reverses sign anywhere inside the range this curve is
    /// drawn across.
    ///
    /// The impulse response `hₜ = Σψⱼhₜ₋ⱼ` with `h₀ = 1` — literally what the forward iteration
    /// propagates, so a negative entry at step *t* is the model saying an hour of falling
    /// pressure implies a rising hour *t* hours later, from its own dynamics and not from any
    /// term it fitted the tide with. Over eighteen steps that is an oscillation, and an
    /// oscillation in a tendency is the tide or it is nothing.
    ///
    /// Measured across `rangeSeconds` rather than a fixed count, because the question is about
    /// the curve that will be drawn: a cycle whose first reversal falls past the end of the
    /// curve never appears on screen and is not worth refusing a fit over.
    static func tendencyReversesWhenDrawn(_ lags: [Double]) -> Bool {
        let steps = Int(ForecastSource.localModel.rangeSeconds / 3600)
        guard steps > 0, !lags.isEmpty else { return false }

        var response = [1.0]
        for step in 1...steps {
            let value = lags.indices.reduce(0.0) { total, lag in
                let index = step - 1 - lag
                return index >= 0 ? total + lags[lag] * response[index] : total
            }
            if value < 0 { return true }
            response.append(value)
        }

        return false
    }

    /// Whether every root of `zᵏ − ψ₁zᵏ⁻¹ − … − ψₖ` lies strictly inside the unit circle.
    ///
    /// The Schur–Cohn criterion in its Levinson step-down form: peel one lag at a time, and the
    /// polynomial is stable exactly when every reflection coefficient met on the way down has
    /// modulus below one. Exact, allocation-light, and no complex arithmetic.
    static func isStable(_ lags: [Double]) -> Bool {
        var remaining = lags

        while let reflection = remaining.last {
            guard abs(reflection) < 1 else { return false }
            guard remaining.count > 1 else { return true }

            let order = remaining.count
            let scale = 1 - reflection * reflection
            remaining = (0..<(order - 1)).map { index in
                (remaining[index] + reflection * remaining[order - 2 - index]) / scale
            }
        }

        return true
    }

    /// `(XᵀX + λI) β = Xᵀy`, solved by Gaussian elimination with partial pivoting.
    ///
    /// At most seven by seven — `Specification.parameterCount` wide. Building `XᵀX` costs
    /// `rows × p²` multiply-adds, about 35 000 over a 30-day window at the richest size, and
    /// the solve is a fixed ~230. Every smaller specification on the ladder is cheaper again.
    /// There is no library call here worth the dependency, and Accelerate would not measurably
    /// beat it at this size.
    private static func solveNormalEquations(design: [[Double]], targets: [Double]) -> [Double]? {
        guard let width = design.first?.count, width > 0 else { return nil }

        var normal = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var moment = [Double](repeating: 0, count: width)

        for (row, target) in zip(design, targets) {
            for i in 0..<width {
                moment[i] += row[i] * target
                for j in i..<width {
                    normal[i][j] += row[i] * row[j]
                }
            }
        }
        // Symmetric, so only the upper triangle was accumulated.
        for i in 0..<width where i > 0 {
            for j in 0..<i {
                normal[i][j] = normal[j][i]
            }
        }

        let meanDiagonal = (0..<width).reduce(0) { $0 + normal[$1][$1] } / Double(width)
        for i in 0..<width {
            normal[i][i] += ridge * max(meanDiagonal, 1)
        }

        return gaussianSolve(matrix: &normal, vector: &moment, width: width)
    }

    private static func gaussianSolve(matrix: inout [[Double]],
                                      vector: inout [Double],
                                      width: Int) -> [Double]? {
        for column in 0..<width {
            // Partial pivoting. Without it a near-zero leading coefficient — an entirely
            // plausible outcome on a flat log — turns the elimination into noise.
            guard let pivot = (column..<width).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-12
            else {
                return nil
            }

            if pivot != column {
                matrix.swapAt(pivot, column)
                vector.swapAt(pivot, column)
            }

            for row in (column + 1)..<width {
                let factor = matrix[row][column] / matrix[column][column]
                guard factor != 0 else { continue }
                for inner in column..<width {
                    matrix[row][inner] -= factor * matrix[column][inner]
                }
                vector[row] -= factor * vector[column]
            }
        }

        var solution = [Double](repeating: 0, count: width)
        for row in stride(from: width - 1, through: 0, by: -1) {
            var accumulated = vector[row]
            for column in (row + 1)..<width {
                accumulated -= matrix[row][column] * solution[column]
            }
            solution[row] = accumulated / matrix[row][row]
            guard solution[row].isFinite else { return nil }
        }

        return solution
    }
}
