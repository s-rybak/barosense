import Foundation

/// How much history the chart shows. The four options the design offers (Figma `7:682`).
///
/// Only the window length lives here. The labels are presentation and stay in the view —
/// `Shared/` holds no user-facing copy.
enum PressureChartRange: String, CaseIterable, Identifiable, Sendable {
    case oneHour
    case threeHours
    case sixHours
    case day

    var id: String { rawValue }

    var seconds: TimeInterval {
        switch self {
        case .oneHour: 3600
        case .threeHours: 3 * 3600
        case .sixHours: 6 * 3600
        case .day: 24 * 3600
        }
    }

    /// The widest option. One store read of this length serves every range, so switching
    /// between them is a re-slice rather than another query.
    static let widest = PressureChartRange.day
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
enum PressureTrend: Hashable, Sendable {
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

    /// Readings inside the selected range, ascending by timestamp. Sensor data only.
    let observed: [PressureSample]

    /// Forward-looking values, ascending, all timestamped after `now`.
    ///
    /// A separate array rather than a flag on the sample, because the two are separate
    /// feature families and must stay distinguishable downstream: the watch is ground truth
    /// for "now", WeatherKit for "next" (`.claude/context/ml-spec.md` §2.2). Empty until
    /// WeatherKit is wired, which is why the chart has to render without it.
    let forecast: [PressureSample]

    /// The instant the series was built. The divider between observed and forecast.
    let now: Date

    /// Which window is on screen. Carried on the series so the chart can draw the *whole*
    /// window even when only part of it was observed — two readings twelve minutes apart
    /// stretched across an hour of plot would claim an hour of coverage that does not exist.
    let range: PressureChartRange

    let trend: PressureTrend

    /// Most recent observed reading — the figure the card prints.
    var latest: PressureSample? { observed.last }

    var isEmpty: Bool { observed.isEmpty }

    /// Vertical extent to draw, in hPa, padded so the line sits in the middle of the plot
    /// rather than touching its edges.
    ///
    /// `nil` when there is nothing to draw. A padded domain is also what keeps a flat day
    /// from rendering as a straight line pinned to one edge: without padding, a series
    /// whose min equals its max has a zero-height domain and the chart has nowhere to put
    /// it.
    var valueDomainHPa: ClosedRange<Double>? {
        let values = (observed + forecast).map(\.pressure.hectopascals)
        guard let lowest = values.min(), let highest = values.max() else { return nil }

        // 0.6× the span leaves the line occupying roughly the middle 45% of the plot, which
        // is how the design draws it. The 1 hPa floor covers a span of zero.
        let padding = max((highest - lowest) * 0.6, 1.0)
        return (lowest - padding)...(highest + padding)
    }

    /// Builds the series for one range.
    ///
    /// `samples` is the whole trailing-`PressureChartRange.widest` window, not a
    /// pre-sliced one: the trend caption always describes the last three hours, so changing
    /// the range must not change it. Slicing here rather than in the store also means
    /// switching range costs no I/O.
    static func make(from samples: [PressureSample],
                     forecast: [PressureSample] = [],
                     range: PressureChartRange,
                     asOf now: Date) -> PressureSeries {
        let window = now.addingTimeInterval(-range.seconds)...now
        let observed = samples
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }

        return PressureSeries(
            observed: observed,
            forecast: forecast.filter { $0.timestamp > now }.sorted { $0.timestamp < $1.timestamp },
            now: now,
            range: range,
            // From the full input, not from `observed`: the one-hour range holds too little
            // to judge a three-hour tendency, and it would otherwise report `.unknown`
            // purely because of which button is selected.
            trend: PressureTrend.make(from: samples, asOf: now)
        )
    }

    static func empty(range: PressureChartRange = .oneHour,
                      asOf now: Date = .now) -> PressureSeries {
        PressureSeries(observed: [], forecast: [], now: now, range: range, trend: .unknown)
    }

    /// Horizontal extent to draw: the whole selected window, plus whatever the forecast
    /// reaches into. Fixed by the range rather than by the data, so a thin day looks thin.
    var timeDomain: ClosedRange<Date> {
        let start = now.addingTimeInterval(-range.seconds)
        // A minute of headroom past `now` keeps the newest reading and the divider off the
        // right edge of the plot, where a 3 pt line would be half clipped.
        let end = max(forecast.last?.timestamp ?? now, now).addingTimeInterval(60)
        return start...end
    }
}
