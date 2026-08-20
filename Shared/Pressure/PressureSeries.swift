import Foundation

/// How much history the chart shows, and how finely it is drawn.
///
/// The four the design draws (Figma `7:682`): 1 / 3 / 6 / День.
///
/// ## Window and bucket are two different numbers
///
/// The phone aims to record one reading per 15 min (`PressureSamplingPolicy`). Drawing a
/// day of that raw is 96 points inside a 92 pt-tall plot — a smear, and one that moves
/// under a reading that lands while the user is looking at it. So every range wider than
/// the sampling interval collapses its readings onto a fixed grid and draws the mean of
/// each occupied slot.
///
/// At the nominal cadence that yields:
///
/// | Range | Bucket | Points |
/// | ----- | ------ | ------ |
/// | 1 год | 15 min | 4      |
/// | 3 год | 15 min | 12     |
/// | 6 год | 30 min | 12     |
/// | День  | 1 h    | 24     |
///
/// The two narrow ranges sit on the sampling floor and therefore draw the log at the
/// cadence it was recorded at. `.threeHours` is `PressureTrend.windowSeconds` wide on
/// purpose: the button that matches the caption shows the same readings the caption was
/// computed from, which is the shortest window either of them can say anything about.
///
/// ## The window is what is visible, not what is loaded
///
/// The plot scrolls. `seconds` is the width of one screenful; `historySeconds` is how far
/// back the gesture reaches. Every range draws twelve screenfuls and opens on the newest.
///
/// Declaration order is the order the selector renders. A case inserted in the wrong place
/// produces a scrambled row of buttons and nothing else complains, so the ordering has a
/// test.
///
/// Only the arithmetic lives here. The labels are presentation and stay in the view —
/// `Shared/` holds no user-facing copy.
enum PressureChartRange: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case threeHours
    case sixHours
    case day

    var id: String { rawValue }

    /// Width of one screenful — the window the button names, and the only part of the plot
    /// visible without scrolling.
    var seconds: TimeInterval {
        switch self {
        case .oneHour: 3600
        case .threeHours: 3 * 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        }
    }

    /// How far back the plot can be scrolled, ending at `now`.
    ///
    /// Twelve screenfuls on every range. The multiplier is a point budget rather than a
    /// taste: the line is drawn from `historySeconds / bucketSeconds` points, so twelve
    /// lands every range between 48 and 288 of them — enough history to be worth a gesture,
    /// few enough that Swift Charts is still drawing a line and not a solid block. It also
    /// makes the scroll cost the same on every button.
    ///
    /// | Range | Reaches back | Points drawn |
    /// | ----- | ------------ | ------------ |
    /// | 1 год | 12 год       | 48           |
    /// | 3 год | 36 год       | 144          |
    /// | 6 год | 3 доби       | 144          |
    /// | День  | 12 діб       | 288          |
    ///
    /// Older rows than this are on disk — `PressureRetentionPolicy` keeps five years of
    /// them — and reaching those is a History screen's job. A card 92 pt tall is not the
    /// place to scroll through a year.
    var historySeconds: TimeInterval { seconds * Self.scrollbackScreens }

    /// Screenfuls of history behind the visible window. See `historySeconds`.
    private static let scrollbackScreens: Double = 12

    /// Points one screenful holds at the nominal cadence — 4, 12, 12, 24 up the ladder.
    ///
    /// The plot marks its points only while this is small. Derived from the range rather
    /// than counted off the data, so the dots do not blink in and out as the scroll passes
    /// over a densely sampled afternoon.
    var pointsPerScreen: Int {
        Int((seconds / bucketSeconds).rounded())
    }

    /// Width of one averaged point.
    ///
    /// Chosen to land every range between 4 and 24 points per screenful: enough to show the
    /// shape of the window, few enough that `PressureChartPlot` can still mark them. Never
    /// finer than `PressureSamplingPolicy.minimumIntervalSeconds`, because a bucket smaller
    /// than the sampling interval averages nothing and only shifts the point off the instant
    /// it was measured. The two narrow ranges sit exactly on that floor, so they draw the
    /// log at the cadence it was recorded at.
    var bucketSeconds: TimeInterval {
        switch self {
        case .oneHour: 15 * 60
        case .threeHours: 15 * 60
        case .sixHours: 30 * 60
        case .day: 3600
        }
    }

    /// How far past `now` the forecast half of the line is drawn.
    ///
    /// **Half a screenful**, so the divider lands two-thirds of the way across the viewport and
    /// both halves are legible at every range: 30 min ahead on the narrowest button, 12 h on
    /// the widest.
    ///
    /// A fraction of the window rather than a fixed horizon, for the reason the trailing
    /// headroom is: what has to stay constant is how much of the *plot* the forecast occupies,
    /// and a fixed 24 h would be a quarter of the day range and twenty-four screenfuls of the
    /// one-hour one. The archive holds 240 h; this is how much of it the card draws.
    var forecastSeconds: TimeInterval { seconds / 2 }

    /// The widest option, and therefore the deepest history any range asks for. One store
    /// read of `widest.historySeconds` serves every range, so switching between them is a
    /// re-slice rather than another query.
    static let widest = PressureChartRange.day
}

/// Collapses readings onto a fixed grid, one averaged point per occupied slot.
///
/// Separate from `PressureSeries` because it is arithmetic on a list and nothing else, and
/// because it is the piece most likely to be wrong in a way the eye cannot check.
///
/// **Display only.** The model is fitted on the raw log; averaging is how a chart stays
/// readable, not how a feature is computed. Nothing in `Shared/Features/` may call this.
enum PressureBuckets {

    /// Averages `samples` into slots `widthSeconds` wide, ascending by time.
    ///
    /// Slots are aligned to the epoch rather than to `now`, so a rebuild one second later
    /// puts every point back where it was. Anchoring to `now` would slide the whole grid
    /// under the line on every reload and make an unchanged history look like it moved.
    ///
    /// A slot holding a single reading is returned untouched — same identifier, same
    /// timestamp, same value. That matters for the narrow ranges, where every slot holds at
    /// most one row and the chart must not claim a measurement at an instant nothing was
    /// measured.
    static func collapse(_ samples: [PressureSample],
                         intoBucketsOf widthSeconds: TimeInterval) -> [PressureSample] {
        guard widthSeconds > 0, samples.count > 1 else { return samples }

        let slots = Dictionary(grouping: samples) { sample in
            (sample.timestamp.timeIntervalSince1970 / widthSeconds).rounded(.down)
        }

        return slots.values
            .compactMap(mean)
            .sorted { $0.timestamp < $1.timestamp }
    }

    /// The arithmetic mean of a slot, in both value and time.
    ///
    /// The timestamp is the mean of the readings' own timestamps, not the centre of the
    /// slot: a slot covering 10:00–10:30 that holds one reading taken at 10:01 must draw at
    /// 10:01. Averaging the times keeps a half-empty slot from pretending to be full.
    ///
    /// The identifier is the earliest reading's, so `ForEach` sees the same point across
    /// rebuilds instead of a fresh identity every time the chart reloads.
    private static func mean(of slot: [PressureSample]) -> PressureSample? {
        let ordered = slot.sorted { $0.timestamp < $1.timestamp }
        guard let earliest = ordered.first else { return nil }
        guard ordered.count > 1 else { return earliest }

        let count = Double(ordered.count)
        let hectopascals = ordered.reduce(0) { $0 + $1.pressure.hectopascals } / count
        let instant = ordered.reduce(0) { $0 + $1.timestamp.timeIntervalSince1970 } / count

        return PressureSample(id: earliest.id,
                              timestamp: Date(timeIntervalSince1970: instant),
                              pressure: Pressure(hectopascals: hectopascals))
    }
}

/// How a pressure figure is printed, on both platforms.
///
/// Shared because the watch and the phone must not disagree about it: seeing `1013.2` on one
/// screen and `1 013` on the other reads as two different measurements.
///
/// Grouping is off deliberately. A locale that groups thousands with a period renders 1013.2
/// as `1.013,2`, which in a four-digit measurement looks like a decimal point in the wrong
/// place. Pressure is never large enough for grouping to help.
enum PressureFormat {

    /// One decimal — the resolution the barometer actually has. Printing more claims
    /// precision the sensor does not deliver.
    static func hectopascals(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(1)).grouping(.never))
    }

    /// Whole hectopascals, for a watch screen read at a glance.
    static func roundedHectopascals(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0)).grouping(.never))
    }
}

/// Which way pressure has moved recently, as a caption under the chart.
///
/// **Display only.** This is not a model feature and has no row in the feature registry:
/// the model consumes `pressureDeltaHPaPer3h` and friends as continuous values, and
/// collapsing those to three buckets throws away exactly the resolution it needs. Nothing
/// in `Shared/Features/` may read this type.
///
/// `String`-backed and `Codable` because it crosses to the watch inside
/// `PressureDisplaySnapshot`. A raw value the wire format can carry is cheaper than teaching
/// the payload to encode a bare enum, and it keeps the four states readable in a log.
enum PressureTrend: String, Hashable, Codable, Sendable {
    case rising
    case falling
    case steady

    /// Not enough history to say. The ordinary state on a fresh install and after a gap —
    /// the caption is simply absent, never a guess.
    case unknown
}

extension PressureTrend {

    /// Meteorological pressure tendency: the change across the trailing three hours.
    ///
    /// Three hours because that is the interval weather services report tendency over, and
    /// because it is the shortest delta window the feature registry defines — the caption
    /// and the model then describe the same stretch of time rather than two different ones.
    static let windowSeconds: TimeInterval = 3 * 3600

    /// Below this, the caption says "steady".
    ///
    /// *Provisional.* 1 hPa over three hours is the order of magnitude at which a change is
    /// synoptic rather than noise, but it was chosen from that reasoning and not from a
    /// measured distribution of this app's own traces. Re-derive it once there is real
    /// history.
    static let significantChangeHPa: Double = 1.0

    /// Two readings closer together than this cannot support a tendency.
    ///
    /// Without it, two samples four minutes apart would be scaled into a confident arrow,
    /// which is the "confidently wrong value" the pipeline rules forbid. Under an hour of
    /// span the caption stays `.unknown`.
    static let minimumSpanSeconds: TimeInterval = 3600

    /// Classifies the change across the trailing window.
    ///
    /// `samples` may be unsorted and may cover more than the window; anything outside it is
    /// ignored. The delta is taken raw between the window's first and last reading and is
    /// deliberately **not** scaled up to a full three hours: extrapolating a 65-minute span
    /// by 2.8× turns sensor noise into an arrow.
    ///
    /// Fed the raw log, never the bucketed points: an average is a smoother, and a smoother
    /// applied before a difference is how a real fall gets rounded down into "steady".
    static func make(from samples: [PressureSample], asOf now: Date) -> PressureTrend {
        let window = now.addingTimeInterval(-windowSeconds)...now
        let inWindow = samples
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }

        guard let first = inWindow.first, let last = inWindow.last else { return .unknown }
        guard last.timestamp.timeIntervalSince(first.timestamp) >= minimumSpanSeconds else {
            return .unknown
        }

        let deltaHPa = last.pressure.delta(from: first.pressure)
        if deltaHPa <= -significantChangeHPa { return .falling }
        if deltaHPa >= significantChangeHPa { return .rising }
        return .steady
    }
}

/// Everything the pressure chart draws, derived once from stored samples.
///
/// Pure and synchronous, like `HealthMetricsSnapshot.make`: this is the piece that decides
/// what the line, the figure and the caption mean, so it has to be exercisable from a test
/// with a handful of literals and no sensor anywhere.
struct PressureSeries: Hashable, Sendable {

    /// The points the line draws, ascending by timestamp — bucket means on every range that
    /// asks for them, raw readings on the ones that do not. Sensor data only.
    ///
    /// Covers the whole scrollable extent (`PressureChartRange.historySeconds`), not the
    /// visible window: the plot is one long line the viewport slides along, so everything
    /// the gesture can reach has to be in here before the gesture starts.
    let observed: [PressureSample]

    /// Forward-looking values, ascending, all timestamped after `now`.
    ///
    /// A separate array **and a separate type**, because the two are separate feature families
    /// and must stay distinguishable downstream: the phone is ground truth for "now", the
    /// forecast archive for "next" (`.claude/context/ml-spec.md` §2.2). A `PressureSample` here
    /// would be a measurement of a time nobody has measured yet.
    ///
    /// Still empty on plenty of ordinary devices — no location grant, WeatherKit switched off
    /// before the local model has fitted, a fresh install — so the chart has to render without
    /// it, and there is a test that says so.
    let forecast: [ForecastPressurePoint]

    /// The user's own check-ins, placed onto `observed` so the chart can mark when each one
    /// was logged. Ascending, and a subset of what was passed in: a check-in with no line
    /// near it is dropped rather than pinned somewhere (`CheckInMarker.place`).
    ///
    /// Display only, like `trend` — the model aligns check-ins with pressure under its own
    /// coverage rules and never reads this.
    let checkIns: [CheckInMarker]

    /// The instant the series was built. The divider between observed and forecast.
    let now: Date

    /// Which window is on screen. Carried on the series so the chart can draw the *whole*
    /// window even when only part of it was observed — two readings twelve minutes apart
    /// stretched across an hour of plot would claim an hour of coverage that does not exist.
    let range: PressureChartRange

    let trend: PressureTrend

    /// Most recent **raw** reading inside the *visible* window — the figure the card prints.
    ///
    /// Stored rather than taken from `observed.last`, for two reasons. That is a bucket mean
    /// on most ranges, and "поточний тиск" has to be a measurement, not an average of the
    /// last hour — on a falling day the two differ by more than the decimal the card prints.
    /// And it sits at the far end of the scrollback, which may be twelve days ago.
    ///
    /// Bounded by `range.seconds` and not by the scrollable extent, and deliberately not
    /// moved by the scroll: the figure is a claim about the present, so scrolling into last
    /// Tuesday must not relabel last Tuesday as "now". `nil` when nothing was recorded in
    /// the visible window — background wakes are granted rather than scheduled, so an hour
    /// with no reading in it is an ordinary outcome on the narrowest button.
    let latest: PressureSample?

    /// How many raw readings the scrollable extent holds, before bucketing. What VoiceOver
    /// reports — announcing the bucket count would understate the history by up to 4×, and
    /// VoiceOver cannot scroll the plot, so the summary describes all of it.
    let readingCount: Int

    var isEmpty: Bool { observed.isEmpty }

    /// Vertical extent to draw, in hPa, padded so the line sits in the middle of the plot
    /// rather than touching its edges.
    ///
    /// `nil` when there is nothing to draw. A padded domain is also what keeps a flat day
    /// from rendering as a straight line pinned to one edge: without padding, a series
    /// whose min equals its max has a zero-height domain and the chart has nowhere to put
    /// it.
    /// The band widens the domain, but only so far — `bandDomainAllowance` — and past that it
    /// is clipped by the plot instead.
    ///
    /// Both halves of that are deliberate. A domain fitted to the lines alone would cut the top
    /// and bottom off the shaded area at exactly the horizons where the band is the point. A
    /// domain fitted to the band outright hands the whole plot to whichever producer is least
    /// certain: the local model quotes ±4.4 hPa at six hours before any inflation, so a
    /// nine-hectopascal band sits under a day of real movement that spans two, and the user's
    /// own line flattens into the middle — the same failure §4.1 names for an uncalibrated
    /// WeatherKit curve, arriving from the other producer.
    ///
    /// The measured half of the picture wins the argument: what is drawn from the barometer is
    /// what the plot is scaled to.
    var valueDomainHPa: ClosedRange<Double>? {
        let drawn = observed.map(\.pressure.hectopascals)
            + forecast.map(\.pressure.hectopascals)
        guard let lowest = drawn.min(), let highest = drawn.max() else { return nil }

        // 0.6× the span leaves the line occupying roughly the middle 45% of the plot, which
        // is how the design draws it. The 1 hPa floor covers a span of zero.
        //
        // The 3 hPa ceiling is what scrolling added. The domain is fitted once, over the
        // whole scrollable extent, because a domain refitted to the viewport would make the
        // line climb and sink under the finger while the readings stood still. Twelve days
        // of weather spans tens of hPa, and 60% of that as padding on each side squashes a
        // day's movement into a flat line.
        let padding = min(max((highest - lowest) * 0.6, 1.0), 3.0)
        let low = lowest - padding
        let high = highest + padding
        guard !forecast.isEmpty else { return low...high }

        let allowance = max((high - low) * Self.bandDomainAllowance, Self.bandDomainFloorHPa)
        let bandLow = forecast.map(\.lowerHPa).min() ?? low
        let bandHigh = forecast.map(\.upperHPa).max() ?? high

        return min(low, max(bandLow, low - allowance))...max(high, min(bandHigh, high + allowance))
    }

    /// How far past the drawn lines the uncertainty band may stretch the y-domain, as a
    /// fraction of the domain those lines set, each side.
    ///
    /// **0.5**, so on an ordinary day the band can at most double the plot's height — which
    /// leaves the observed line about a fifth of it, the point past which it stops reading as a
    /// line and starts reading as a level.
    static let bandDomainAllowance: Double = 0.5

    /// The allowance on a short or flat series, where half of a nearly-zero span would clip
    /// every band there is.
    ///
    /// An **uninflated local band at its own range** — 0.8 hPa at issue plus 0.6 per hour, six
    /// hours out. Read as a rule: a producer quoting no more uncertainty than the shortest-range
    /// producer quotes at full stretch is drawn whole, and anything wider than that is inflation
    /// — a thin log, a hole, a fit that does not fit — and is clipped at the edge of the plot
    /// instead of being allowed to set its scale. Clipping is the honest failure: a band running
    /// off the top of the chart reads as "wider than this chart", which is what it is.
    static let bandDomainFloorHPa =
        ForecastSource.localModel.uncertaintyHPa(atLeadSeconds: 6 * 3600)

    /// Builds the series for one range.
    ///
    /// `samples` is the whole trailing-`PressureChartRange.widest.historySeconds` window,
    /// not a pre-sliced one: the trend caption always describes the last three hours, so
    /// changing the range must not change it. Slicing here rather than in the store also
    /// means switching range costs no I/O.
    ///
    /// Three different windows come out of one input, and they are not interchangeable. The
    /// line covers the scrollable extent, the figure covers the visible window, and the
    /// caption covers the trailing three hours whatever the button says.
    ///
    /// `checkIns` is filtered to the same extent as the line and then placed onto it. Passing
    /// more than the extent holds is fine and is what the caller does — one store read serves
    /// every range, the same way `samples` does.
    static func make(from samples: [PressureSample],
                     forecast: [ForecastPressurePoint] = [],
                     checkIns: [CheckIn] = [],
                     range: PressureChartRange,
                     asOf now: Date) -> PressureSeries {
        let extent = now.addingTimeInterval(-range.historySeconds)...now
        let inExtent = samples
            .filter { extent.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }

        let drawn = PressureBuckets.collapse(inExtent, intoBucketsOf: range.bucketSeconds)

        let visibleFrom = now.addingTimeInterval(-range.seconds)

        // Clipped to the range's own forward window as well as to `now`. The archive reaches
        // 240 h and the caller hands over whatever it has; drawing all of it would flatten the
        // user's own line into the top of the plot.
        let forecastHorizon = now.addingTimeInterval(range.forecastSeconds)

        return PressureSeries(
            observed: drawn,
            forecast: forecast
                .filter { $0.timestamp > now && $0.timestamp <= forecastHorizon }
                .sorted { $0.timestamp < $1.timestamp },
            // Placed against `drawn` rather than `inExtent`, so the dots land on the line the
            // chart actually renders instead of on the raw log behind it.
            checkIns: CheckInMarker.place(checkIns.filter { extent.contains($0.timestamp) },
                                          on: drawn),
            now: now,
            range: range,
            // From the full input, not from `inExtent`: the one-hour range holds too little
            // to judge a three-hour tendency, and it would otherwise report `.unknown`
            // purely because of which button is selected.
            trend: PressureTrend.make(from: samples, asOf: now),
            latest: inExtent.last { $0.timestamp >= visibleFrom },
            readingCount: inExtent.count
        )
    }

    static func empty(range: PressureChartRange = .oneHour,
                      asOf now: Date = .now) -> PressureSeries {
        PressureSeries(observed: [], forecast: [], checkIns: [], now: now, range: range,
                       trend: .unknown, latest: nil, readingCount: 0)
    }

    /// Horizontal extent of the whole plot — twelve screenfuls of history, plus whatever the
    /// forecast reaches into. This is what the scroll travels over; `visibleSeconds` is how
    /// much of it is on screen at once.
    ///
    /// Fixed by the range rather than by the data, so a thin day looks thin: two readings
    /// twelve minutes apart must occupy twelve minutes of the plot instead of being
    /// stretched across it to claim coverage that was never observed.
    var timeDomain: ClosedRange<Date> {
        let start = now.addingTimeInterval(-range.historySeconds)
        let end = max(forecast.last?.timestamp ?? now, now)
            .addingTimeInterval(trailingHeadroomSeconds)
        return start...end
    }

    /// Empty plot past the newest point, so whatever sits at `now` is not half clipped by the
    /// right edge.
    ///
    /// A fraction of the visible window rather than a fixed interval, because the clearance
    /// that matters is in **points**, and a fixed number of seconds buys 12× more of them on
    /// the narrowest range than on the widest. 2.5% of a screenful is ~8 pt on the plot widths
    /// this card is drawn at.
    ///
    /// It was one minute while the rightmost thing was a 3 pt line cap. A check-in dot is
    /// 14 pt across with its ring (`CheckInDot`), and a check-in logged just now lands exactly
    /// there — which is the common case, not the edge case.
    var trailingHeadroomSeconds: TimeInterval { range.seconds * 0.025 }

    /// How much of `timeDomain` is on screen at once: one screenful, the window the selected
    /// button names.
    var visibleSeconds: TimeInterval { range.seconds }

    /// Leading edge of the screenful the plot opens on.
    ///
    /// Anchored to the newest reading rather than to `now`. iOS grants background wakes, it
    /// does not schedule them, so a phone left alone can leave the narrowest window empty;
    /// opening on a blank viewport that the user has to scroll leftwards out of is worse
    /// than opening a little way into the past with the line in view. Clamped into
    /// `timeDomain` so a stale log cannot scroll the viewport off the end of the plot.
    var initialScrollX: Date {
        // The forecast's far end when there is one, so the card opens with the forward half in
        // view. Opening on the newest reading instead would put the whole point of this
        // feature just off the right edge, behind a gesture nobody knows to make.
        let newest = forecast.last?.timestamp ?? observed.last?.timestamp ?? now
        // The same headroom `timeDomain` leaves. It has to be applied here too: the viewport
        // is what clips, so widening the plot alone would move the edge without moving what
        // is on screen.
        let trailingEdge = min(newest.addingTimeInterval(trailingHeadroomSeconds),
                               timeDomain.upperBound)
        return max(trailingEdge.addingTimeInterval(-visibleSeconds), timeDomain.lowerBound)
    }
}
