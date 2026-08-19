import Foundation

/// Forward-looking pressure features at one instant.
///
/// The §2.2 family of `.claude/context/ml-spec.md`. Every field is optional and absence is the
/// ordinary case: no location grant, WeatherKit switched off, a horizon past what the producer
/// can see. Nothing here invents a number to fill a hole — a confidently wrong value is the one
/// outcome the registry forbids outright.
///
/// ## Why the last three fields exist
///
/// They are not provenance bookkeeping. A model fitted on WeatherKit-quality inputs and then
/// handed the local model's curve would apply the same coefficients with the same confidence
/// and never learn that the input had got ten times noisier. Quiet degradation nobody sees is
/// the failure `forecastSource` and `forecastUncertaintyHPa` are there to make visible, and
/// `forecastIssueAgeSeconds` turns staleness from an assumption into an observation
/// (`.claude/context/pressure-forecast-spec.md` §4.6, §4.9).
struct ForecastPressureFeatures: Hashable, Sendable {

    /// Change from the hour containing `t` to `t + 6 h`, hPa. Negative means falling.
    let forecastPressureDeltaHPaPer6h: Double?

    let forecastPressureDeltaHPaPer12h: Double?

    let forecastPressureDeltaHPaPer24h: Double?

    /// Lowest forecast value in `(t, t + 24 h]`, hPa, in barometer coordinates.
    ///
    /// The one absolute value in the family, which is why the curve has to be offset-calibrated
    /// before it reaches here: raw MSLP would be ~22 hPa away from every other pressure the
    /// model sees.
    let forecastMinPressureHPaNext24h: Double?

    /// Who produced the curve these were read off. `nil` when there was no curve at all.
    let forecastSource: ForecastSource?

    /// The producer's band at a **fixed 6 h horizon**, hPa.
    ///
    /// Fixed rather than per-feature so the number is comparable across rows: it is a statement
    /// about input quality, and a value that moved with which horizon happened to be available
    /// would confound quality with coverage. Six hours because it is the one horizon both
    /// producers can speak to.
    let forecastUncertaintyHPa: Double?

    /// How old the newest issue behind these values was at `t`, seconds.
    ///
    /// An observation, not a gate. The staleness norm (≤12 h) decides whether a row is usable;
    /// this lets a model learn that an eleven-hour-old curve is a worse input than a
    /// one-hour-old one, instead of being told they are the same.
    let forecastIssueAgeSeconds: TimeInterval?

    /// Nothing was knowable at `t`. The ordinary state on a device with no location grant, and
    /// on every device before its first successful request.
    static let unavailable = ForecastPressureFeatures(
        forecastPressureDeltaHPaPer6h: nil,
        forecastPressureDeltaHPaPer12h: nil,
        forecastPressureDeltaHPaPer24h: nil,
        forecastMinPressureHPaNext24h: nil,
        forecastSource: nil,
        forecastUncertaintyHPa: nil,
        forecastIssueAgeSeconds: nil
    )
}

/// Builds `ForecastPressureFeatures` at an instant from a forecast curve.
///
/// One code path, whichever producer filled the curve. That is the point of
/// `ForecastPressurePoint` existing at all: the pipeline reads a list of points and does not
/// know whether WeatherKit or `LocalPressureModel` wrote them
/// (`.claude/context/pressure-forecast-spec.md` §2.3).
enum ForecastFeatureExtractor {

    /// The horizons the registry names, in hours.
    static let deltaHorizonHours = [6, 12, 24]

    /// How much curve the family needs: the longest horizon, plus the hour containing `t`.
    ///
    /// Named rather than repeated at each call site so the reader and the store-backed path
    /// cannot ask for different amounts and produce different `Per24h` values from one archive.
    static let featureHorizonSeconds: TimeInterval = 24 * 3600

    /// The horizon `forecastUncertaintyHPa` is quoted at.
    static let uncertaintyReferenceHorizonSeconds: TimeInterval = 6 * 3600

    /// How far a curve point may be from a horizon and still answer for it.
    ///
    /// **90 minutes**, the same tolerance `pressureHPa` is defined with in §2.1. An hourly
    /// curve lands well inside it; a curve with a hole in it does not, and the feature then
    /// goes `nil` rather than being interpolated across the hole.
    static let horizonToleranceSeconds: TimeInterval = 90 * 60

    /// Features at `t`.
    ///
    /// **`curve` must already be restricted to what was knowable at `t`.** The store applies
    /// that filter (`WeatherForecastStore.points(issuedAtOrBefore:validIn:)`) and the
    /// store-backed entry point below goes through it; a caller assembling a curve by hand is
    /// responsible for the same rule, which is why the rule lives in one place rather than at
    /// every call site.
    ///
    /// Pure and synchronous, so §8's fixtures reach it with literals and no store.
    static func extract(from curve: [ForecastPressurePoint], at instant: Date) -> ForecastPressureFeatures {
        // Three rules, in this order, and each is load-bearing.
        //
        // 1. `issuedAt <= instant` — the leak guard. A feature at `t` may read only what the
        //    device actually had at `t`.
        // 2. `issuedAt >= instant − 12 h` — the staleness norm §2.2 states. A row from an issue
        //    older than that is not a worse input, it is a different quantity, and the family
        //    goes `nil` rather than carrying it. Local-model points never trip this: they are
        //    stamped with the instant they were computed.
        // 3. Newest **knowable** issue per hour. Without it an hour covered by two issues
        //    contributes twice and whichever the sort happened to put first wins, which makes
        //    the feature depend on insertion order rather than on what the app knew. It is the
        //    same rule `ForecastPressurePoint.curve` applies for the chart, so the picture and
        //    the model read the same numbers.
        let usableIssues = WeatherForecastPolicy.oldestUsableIssue(asOf: instant)...instant

        var newestByHour: [Date: ForecastPressurePoint] = [:]
        for point in curve.filter({ usableIssues.contains($0.issuedAt) })
            .sorted(by: { $0.issuedAt < $1.issuedAt }) {
            newestByHour[point.timestamp] = point
        }
        let knowable = newestByHour.values.sorted { $0.timestamp < $1.timestamp }

        guard let anchor = value(at: instant, in: knowable) else { return .unavailable }

        // Read off the same rows the deltas are, so a curve whose source changed midway cannot
        // report one source's band against another's numbers.
        let source = nearest(to: instant, in: knowable)?.source
        let issuedAt = knowable.map(\.issuedAt).max()

        let deltas = deltaHorizonHours.map { hours -> Double? in
            let target = instant.addingTimeInterval(TimeInterval(hours) * 3600)
            guard let ahead = value(at: target, in: knowable) else { return nil }
            return ahead - anchor
        }

        return ForecastPressureFeatures(
            forecastPressureDeltaHPaPer6h: deltas[0],
            forecastPressureDeltaHPaPer12h: deltas[1],
            forecastPressureDeltaHPaPer24h: deltas[2],
            forecastMinPressureHPaNext24h: minimum(in: knowable, after: instant, hours: 24),
            forecastSource: source,
            forecastUncertaintyHPa: source?.uncertaintyHPa(
                atLeadSeconds: uncertaintyReferenceHorizonSeconds
            ),
            forecastIssueAgeSeconds: issuedAt.map { instant.timeIntervalSince($0) }
        )
    }

    /// Store-backed entry point. The `issuedAt <= t` filter is the store's, not a caller's.
    ///
    /// Reads the raw archive and calibrates it into barometer coordinates on the way through,
    /// so the values here are on the same axis as `pressureHPa` and every §2.1 feature.
    /// Without an offset there is nothing comparable to report and the family is `nil`.
    static func extract(from archive: any WeatherForecastStore,
                        offset: PressureOffset?,
                        at instant: Date) async throws -> ForecastPressureFeatures {
        guard let offset else { return .unavailable }

        // One hour back so the anchor hour is included, 24 h forward for the longest horizon
        // plus the tolerance either side.
        let window = instant.addingTimeInterval(-3600)..<instant.addingTimeInterval(25 * 3600)
        let points = try await archive.points(issuedAtOrBefore: instant, validIn: window)

        let curve = ForecastPressurePoint.curve(from: points,
                                                offset: offset,
                                                asOf: instant,
                                                horizonSeconds: featureHorizonSeconds,
                                                includingHourAt: true)
        return extract(from: curve, at: instant)
    }

    // MARK: - Reading the curve

    /// The curve's value at an instant, or `nil` when nothing is close enough.
    ///
    /// Deliberately **not** interpolated across a hole. A gap in the curve is a gap in what the
    /// producer said, and inventing the midpoint of a two-hour hole is the "confidently wrong
    /// value" §2.1 rules out. Interpolation is a display convenience and stays on the chart.
    private static func value(at instant: Date, in curve: [ForecastPressurePoint]) -> Double? {
        nearest(to: instant, in: curve)?.pressure.hectopascals
    }

    private static func nearest(to instant: Date,
                                in curve: [ForecastPressurePoint]) -> ForecastPressurePoint? {
        curve
            .min { abs($0.timestamp.timeIntervalSince(instant)) < abs($1.timestamp.timeIntervalSince(instant)) }
            .flatMap {
                abs($0.timestamp.timeIntervalSince(instant)) <= horizonToleranceSeconds ? $0 : nil
            }
    }

    /// Lowest value strictly after `instant`, within `hours`.
    ///
    /// `nil` when the window holds nothing — a curve that reaches six hours cannot answer a
    /// 24-hour question, and saying so is the whole reason this family is optional.
    private static func minimum(in curve: [ForecastPressurePoint],
                                after instant: Date,
                                hours: Int) -> Double? {
        let horizon = instant.addingTimeInterval(TimeInterval(hours) * 3600)
        return curve
            .filter { $0.timestamp > instant && $0.timestamp <= horizon }
            .map(\.pressure.hectopascals)
            .min()
    }
}
