import Foundation

/// Who produced a forecast point.
///
/// Carried on every point and **all the way into the feature vector**, which is a correctness
/// requirement rather than provenance bookkeeping. A model fitted on WeatherKit-quality inputs
/// and then handed a ten-times noisier local curve would apply the same coefficients with the
/// same confidence and have no way to notice the input had got worse. Quiet degradation that
/// nobody sees is the failure this enum exists to make impossible.
///
/// `String`-backed so it can be stored and logged without a mapping table.
enum ForecastSource: String, Hashable, Codable, Sendable, CaseIterable {

    /// Apple's numerical weather model, offset-calibrated into barometer coordinates.
    case weatherKit

    /// The on-device autoregressive fit over the user's own barometer log. One sensor at one
    /// point cannot see a front 200 km away, and no amount of history changes that
    /// (`.claude/context/pressure-forecast-spec.md` §4.7) — which is why it is drawn out to
    /// `rangeSeconds` but only ever learned from out to `skillRangeSeconds`.
    case localModel
}

extension ForecastSource {

    /// How far ahead this source may be **drawn**.
    ///
    /// WeatherKit's is Apple's documented 240 h horizon. The local model's **18 h** is a display
    /// range confirmed by a human on 2026-08-22, and it is deliberately not the same number as
    /// `skillRangeSeconds`: the chart may extrapolate further than the fit is argued to be
    /// skilful, because the band is what carries that distinction — by 18 h it quotes ±11.6 hPa
    /// against a day's weather of ~5, which reads as "this producer does not know" rather than
    /// as a forecast.
    ///
    /// Three times the skill range and not six. The first setting of this constant was 36 h and
    /// was narrowed the same day: a curve is only worth drawing while the band still reads as a
    /// band, and past ~18 h the linear growth law below is quoting more than twice a day's whole
    /// weather, which is not a wider claim but a differently shaped one — see
    /// `uncertaintyGrowthHPaPerHour`.
    ///
    /// What may not follow the picture is the training input. See `skillRangeSeconds`.
    var rangeSeconds: TimeInterval {
        switch self {
        case .weatherKit: 240 * 3600
        case .localModel: 18 * 3600
        }
    }

    /// How far ahead this source may feed **the model**.
    ///
    /// The physical claim, unchanged and unaffected by the drawn range: advection is not visible
    /// from a single point, so the local fit is argued out to **6 h** and no further
    /// (`.claude/context/pressure-forecast-spec.md` §4.7, §7.1). An agent that wants to raise
    /// *this* number still has to show a skill measurement first; widening the chart is not one.
    ///
    /// Kept apart from `rangeSeconds` so that widening the picture cannot quietly widen what is
    /// learned from: a `forecastPressureDeltaHPaPer24h` filled by twenty-four compounding AR
    /// steps would enter the feature vector looking exactly like WeatherKit's, and the only
    /// thing telling them apart would be `forecastUncertaintyHPa` — one number against a delta
    /// the model would read at face value.
    var skillRangeSeconds: TimeInterval {
        switch self {
        case .weatherKit: 240 * 3600
        case .localModel: 6 * 3600
        }
    }

    /// Band half-width at zero lead: how far off the curve can be even about *now*.
    ///
    /// For WeatherKit this is mostly the offset calibration's own error; for the local model it
    /// is that plus the fit's residual. *Provisional* — both are reasoned, and PR 4's realised
    /// skill report is what replaces them with measurements.
    var baseUncertaintyHPa: Double {
        switch self {
        case .weatherKit: 0.5
        case .localModel: 0.8
        }
    }

    /// How fast the band opens, hPa per hour of lead.
    ///
    /// The asymmetry is the honest part of this whole feature and is not cosmetic: at 6 h the
    /// local model's band is ~4.4 hPa against WeatherKit's ~1.0. That is the difference between
    /// "pressure will fall about 3 hPa" and "pressure will do something", and the chart has to
    /// show which one it is saying.
    ///
    /// *Provisional*, both of them — and the local one is extrapolated past the lead it was
    /// reasoned at: linear growth puts it at ~11.6 hPa by `rangeSeconds`, about twice the
    /// y-domain an ordinary day sets, so the far end of the band is clipped rather than drawn
    /// (`PressureSeries.bandDomainAllowance`). Real forecast error grows sub-linearly and
    /// saturates near the climatological spread of pressure, so this shape is still wrong in the
    /// far half of the local curve — less wrong than it was at 36 h, where it reached ~22.
    /// Replacing it is a measurement task (PR 4's skill report), not a constant to guess at.
    var uncertaintyGrowthHPaPerHour: Double {
        switch self {
        case .weatherKit: 0.08
        case .localModel: 0.6
        }
    }

    /// Band half-width at a given lead time, in hPa. Never negative.
    func uncertaintyHPa(atLeadSeconds lead: TimeInterval) -> Double {
        let hours = max(0, lead) / 3600
        return baseUncertaintyHPa + uncertaintyGrowthHPaPerHour * hours
    }
}

/// One forward-looking pressure value, ready to draw and ready to feature-engineer.
///
/// ## One type, two producers
///
/// The calibrated WeatherKit curve **is** the local pressure forecast — there is no second
/// entity for it. WeatherKit fills this when it is on and `LocalPressureModel` fills it when it
/// is off, into the same table, with the same type, onto the same chart. What differs is
/// `source`, the range, and the width of the band; nothing else branches, and the feature
/// pipeline does not know who wrote a row.
///
/// ## Deliberately not a `PressureSample`
///
/// A sample is a measurement. This is a claim about a time nobody has measured yet. Once a
/// forecast value can stand in for a missing reading the two are indistinguishable downstream
/// and "now" stops being ground truth — the rule `PressureSample`'s own documentation states,
/// enforced here by there being no conversion between them.
struct ForecastPressurePoint: Identifiable, Hashable, Codable, Sendable {

    let id: UUID

    /// The instant this value describes. Always after the `now` it was built against.
    let timestamp: Date

    /// **In barometer coordinates.** A WeatherKit point has already had the station-to-MSLP
    /// offset applied (`PressureOffsetCalibrator`), so it can be drawn on the same axis as the
    /// user's own readings and compared with them without a second conversion anywhere.
    ///
    /// Drawing raw MSLP instead would stretch `PressureSeries.valueDomainHPa` from ~11 hPa to
    /// ~33 hPa across 92 pt of plot and squash the user's own line to a third of its height.
    let pressure: Pressure

    /// Half-width of the band, hPa. Widens with lead time — see `ForecastSource`.
    ///
    /// Not decoration. It is the honest statement of how much the producer knows, and it is
    /// what makes a 3-hour local curve and a 3-day WeatherKit curve legible as different
    /// claims rather than as the same one drawn twice.
    let uncertaintyHPa: Double

    let source: ForecastSource

    /// When this value became knowable. Kept on the point so staleness is an observed field
    /// rather than an assumption — see `WeatherForecastPolicy.maximumIssueAgeSeconds`.
    let issuedAt: Date

    init(id: UUID = UUID(),
         timestamp: Date,
         pressure: Pressure,
         uncertaintyHPa: Double,
         source: ForecastSource,
         issuedAt: Date) {
        self.id = id
        self.timestamp = timestamp
        self.pressure = pressure
        self.uncertaintyHPa = uncertaintyHPa
        self.source = source
        self.issuedAt = issuedAt
    }

    /// Bottom of the band, hPa.
    var lowerHPa: Double { pressure.hectopascals - uncertaintyHPa }

    /// Top of the band, hPa.
    var upperHPa: Double { pressure.hectopascals + uncertaintyHPa }
}

extension ForecastPressurePoint {

    /// Builds the drawable curve from archived WeatherKit rows.
    ///
    /// Four things happen here and each of them is load-bearing.
    ///
    /// 1. **Only the newest issue at or before `now`.** Mixing issues would draw a line that
    ///    zig-zags between two model runs. `points` is expected to be one issue's worth; rows
    ///    from more than one are collapsed to the newest per hour.
    /// 2. **Nothing past the staleness norm.** An issue older than
    ///    `WeatherForecastPolicy.maximumIssueAgeSeconds` yields **no curve at all**, and the
    ///    caller then falls through to whatever else can speak — in the app, the local model.
    ///    The gate lives here rather than at each call site because the archive outlives the
    ///    requests by design: rows are kept 90 days and one issue reaches 240 h ahead, so a
    ///    device that stopped asking would otherwise redraw the same ten-day-old run every day
    ///    and label it the forecast.
    /// 3. **Offset applied**, so the curve lands in barometer coordinates — see `pressure`.
    /// 4. **Clipped to `horizonSeconds` and to the source's own range.** A 240 h curve drawn on
    ///    a card 92 pt tall is a horizontal smear, and the domain it forces would flatten the
    ///    user's own line.
    ///
    /// Points at or before `now` are dropped: this is the forward half of the chart, and the
    /// past half is measurements.
    static func curve(from points: [WeatherForecastPoint],
                      offset: PressureOffset,
                      asOf now: Date,
                      horizonSeconds: TimeInterval,
                      includingHourAt anchor: Bool = false) -> [ForecastPressurePoint] {
        let cutoff = now.addingTimeInterval(min(horizonSeconds, ForecastSource.weatherKit.rangeSeconds))
        // The chart wants the forward half only; the feature pipeline also wants the hour
        // *containing* `now`, because every delta is measured against it. One flag rather than
        // two builders, so the picture and the model are drawn from the same rows.
        let lowerBound = anchor ? now.addingTimeInterval(-3600) : now

        // Both ends of the issue window. `<= now` is the leak guard — the store applies it too,
        // and it is repeated here so a hand-assembled curve cannot skip it — and the lower
        // bound is the staleness norm.
        let usableIssues = WeatherForecastPolicy.oldestUsableIssue(asOf: now)...now

        // Newest issue wins per hour. Sorting by `issuedAt` and letting later entries overwrite
        // is cheaper than grouping, and it is the same rule the feature pipeline applies.
        var newestByHour: [Date: WeatherForecastPoint] = [:]
        for point in points.sorted(by: { $0.issuedAt < $1.issuedAt })
        where usableIssues.contains(point.issuedAt)
            && point.validAt > lowerBound && point.validAt <= cutoff {
            newestByHour[point.validAt] = point
        }

        return newestByHour.values
            .sorted { $0.validAt < $1.validAt }
            .map { point in
                let station = offset.stationPressureHPa(
                    fromMeanSeaLevel: point.meanSeaLevelPressureHPa,
                    temperatureC: point.temperatureC
                )
                return ForecastPressurePoint(
                    timestamp: point.validAt,
                    pressure: Pressure(hectopascals: station),
                    // Lead is measured from `issuedAt`, not from `now`. How wrong a value is
                    // was settled by the model run that produced it; the clock advancing does
                    // not improve a number nobody has recomputed. Measuring from `now` would
                    // quote a thirteen-hour-lead value — a twelve-hour-old issue read one hour
                    // before its hour — as if it were a one-hour forecast, understating the
                    // band by most of its width at exactly the moment the issue is oldest.
                    uncertaintyHPa: ForecastSource.weatherKit.uncertaintyHPa(
                        atLeadSeconds: max(0, point.leadTimeSeconds)
                    ) + offset.uncertaintyHPa,
                    source: .weatherKit,
                    issuedAt: point.issuedAt
                )
            }
    }
}
