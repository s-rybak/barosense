import Foundation

/// How well the forecast actually did, measured against what the barometer went on to record.
///
/// ## Why this exists on the device at all
///
/// `.claude/context/ml-spec.md` §7 requires every forecast to be reported against a trivial
/// baseline, and until now there was no way to satisfy that: there is no dataset, and the
/// wellbeing model is not trained. A pressure forecast is different — the ground truth arrives
/// by itself, a few hours later, in the barometer log. Keeping past forecasts for 30 days buys
/// the §7 comparison with no dataset and no network, and it is the only skill number this app
/// can honestly show.
///
/// ## The baseline is persistence, and it is not a formality
///
/// "Pressure in six hours will be what it is now" is genuinely hard to beat at short horizons.
/// A model that loses to it costs battery and adds risk for nothing, and the honest response to
/// a loss at 6 h is to shorten the range rather than hide the table
/// (`.claude/context/pressure-forecast-spec.md` §8, risk 4).
///
/// ## Not precision/recall
///
/// Those belong to the wellbeing classifier, whose label comes from check-ins. This measures a
/// continuous quantity against a continuous truth, so it reports **mean absolute error** and a
/// skill score. Reporting a PR-AUC here would be a number about nothing.
struct ForecastSkillReport: Hashable, Sendable {

    /// One horizon's worth of comparison.
    struct Horizon: Hashable, Sendable {

        /// Lead time in hours.
        let hours: Int

        /// How many forecast/observation pairs were found. Reported rather than hidden: a
        /// skill score from four pairs is not the same claim as one from four hundred, and §5
        /// forbids averaging a thin fold away silently.
        let pairCount: Int

        /// Mean absolute error of the forecast, hPa.
        let forecastMeanAbsoluteErrorHPa: Double

        /// Mean absolute error of "it will stay where it is", hPa — over the **same pairs**,
        /// so the two numbers are comparable rather than merely adjacent.
        let persistenceMeanAbsoluteErrorHPa: Double

        /// `1 − forecastMAE / persistenceMAE`. Positive is better than persistence, zero is
        /// indistinguishable from it, negative is worse.
        ///
        /// `nil` when persistence made no error at all — a dead-flat stretch, where the ratio
        /// is undefined and the honest answer is "this window says nothing" rather than a
        /// division by zero (§8's zero-variance fixture, in its pressure form).
        var skillScore: Double? {
            guard persistenceMeanAbsoluteErrorHPa > 0 else { return nil }

            return 1 - forecastMeanAbsoluteErrorHPa / persistenceMeanAbsoluteErrorHPa
        }

        /// Whether the forecast earned its place at this horizon.
        var beatsPersistence: Bool { (skillScore ?? 0) > 0 }
    }

    /// Who produced the forecasts being scored. Scores from two producers are not comparable
    /// and are never merged — that is the whole reason `ForecastSource` travels on every point.
    let source: ForecastSource

    /// One row per horizon, ascending. Horizons with no pairs are still present with
    /// `pairCount == 0`, so a missing row can never be mistaken for a horizon that was skipped.
    let horizons: [Horizon]

    /// Horizons that produced at least one pair.
    var measuredHorizons: [Horizon] { horizons.filter { $0.pairCount > 0 } }

    /// A one-line summary for a PR body or a log. Deliberately states losses as plainly as
    /// wins — §7 asks for the comparison "or say so plainly", not for the flattering half.
    var summary: String {
        guard !measuredHorizons.isEmpty else {
            return "\(source.rawValue): no realised forecasts to score yet"
        }

        let rows = measuredHorizons.map { horizon in
            let skill = horizon.skillScore.map { String(format: "%+.2f", $0) } ?? "n/a"
            return String(format: "%dh n=%d MAE %.2f vs persistence %.2f (skill %@)",
                          horizon.hours,
                          horizon.pairCount,
                          horizon.forecastMeanAbsoluteErrorHPa,
                          horizon.persistenceMeanAbsoluteErrorHPa,
                          skill)
        }
        return "\(source.rawValue): " + rows.joined(separator: " · ")
    }
}

/// Scores past forecasts against the barometer log.
///
/// Pure and synchronous, like every other piece of this pipeline: §8 requires it to run from a
/// plain XCTest with synthetic input and no store, no sensor and no network.
enum ForecastSkillEvaluator {

    /// The horizons the report covers.
    ///
    /// 1 / 3 / 6 h, which is exactly the range the local model claims and the range where
    /// persistence is hardest to beat. Extending it is cheap; claiming skill at 24 h without
    /// measuring it is not.
    static let horizonHours = [1, 3, 6]

    /// How close a barometer reading has to be to a forecast hour to score it.
    ///
    /// 30 minutes — tighter than the feature tolerance, because here the reading *is* the truth
    /// and half an hour of drift at a synoptic 2 hPa/h is already 1 hPa of invented error.
    static let matchToleranceSeconds: TimeInterval = 30 * 60

    /// How long realised forecasts are worth keeping.
    ///
    /// **30 days.** Long enough for a few hundred pairs per horizon at four issues a day,
    /// short enough that the table stays a rounding error next to the barometer log: 24 points
    /// × 4 issues × 30 days is ~2 880 rows against 175 000.
    static let retentionDays = 30

    /// Scores `forecasts` against `observed`.
    ///
    /// A pair is formed when a forecast point and a barometer reading describe the same instant
    /// (within `matchToleranceSeconds`) **and** the log also holds a reading at the moment the
    /// forecast was issued — the second one is what persistence needs, and scoring a forecast
    /// against a baseline that had no starting value would flatter it.
    ///
    /// `forecasts` may hold more than one source; rows whose `source` differs from `source` are
    /// ignored rather than merged.
    static func evaluate(forecasts: [ForecastPressurePoint],
                         observed: [PressureSample],
                         source: ForecastSource,
                         asOf now: Date) -> ForecastSkillReport {
        let readings = observed.sorted { $0.timestamp < $1.timestamp }
        // Only forecasts whose hour has already arrived can be scored. The rest are still
        // claims about the future and belong in the chart, not in a skill table.
        let realised = forecasts.filter { $0.source == source && $0.timestamp <= now }

        let horizons = horizonHours.map { hours -> ForecastSkillReport.Horizon in
            let lead = TimeInterval(hours) * 3600
            var forecastErrors: [Double] = []
            var persistenceErrors: [Double] = []

            for point in realised {
                // The forecast's own lead is measured from its issue, which is what makes a
                // "6 h forecast" mean the same thing here as it does on the chart.
                guard abs(point.timestamp.timeIntervalSince(point.issuedAt) - lead)
                        <= matchToleranceSeconds,
                      let truth = reading(at: point.timestamp, in: readings),
                      let start = reading(at: point.issuedAt, in: readings)
                else { continue }

                forecastErrors.append(abs(point.pressure.hectopascals - truth))
                persistenceErrors.append(abs(start - truth))
            }

            return ForecastSkillReport.Horizon(
                hours: hours,
                pairCount: forecastErrors.count,
                forecastMeanAbsoluteErrorHPa: mean(of: forecastErrors),
                persistenceMeanAbsoluteErrorHPa: mean(of: persistenceErrors)
            )
        }

        return ForecastSkillReport(source: source, horizons: horizons)
    }

    /// Store-backed entry point: scores the last `retentionDays` of WeatherKit issues against
    /// the barometer log.
    ///
    /// **There is deliberately no second table of realised forecasts.** The raw archive already
    /// keeps 90 days of `(issuedAt, validAt, …)` rows, which is a superset of the 30 days this
    /// needs, and every point it would hold is derivable from them. A parallel table would be
    /// ~2 880 rows duplicating rows already on disk, plus a second thing to keep in step with
    /// the retention pass and with `BarosenseDataEraser`.
    ///
    /// The offset is applied so the errors are in barometer coordinates — the same axis the
    /// truth is measured on. Without one there is nothing comparable and the report is empty.
    static func evaluate(archive: any WeatherForecastStore,
                         samples: any PressureSampleStore,
                         offset: PressureOffset,
                         asOf now: Date) async throws -> ForecastSkillReport {
        let since = now.addingTimeInterval(-TimeInterval(retentionDays) * 24 * 3600)
        // `issuedAtOrBefore: now` is not decoration even here: scoring a forecast against an
        // issue made after the hour it describes would be scoring hindsight, and the number
        // that came out would be flattering and meaningless.
        //
        // The ≤12 h staleness gate deliberately does **not** apply. That gate answers "may this
        // issue still be read as the current forecast"; this asks "how did the issues we made
        // actually do", and every one of them is old by the time its hour arrives. Applying it
        // here would score nothing at all.
        let rows = try await archive.points(issuedAtOrBefore: now, validIn: since..<now)
        let readings = try await samples.samples(in: since..<now.addingTimeInterval(1))

        let points = rows.map { row in
            ForecastPressurePoint(
                timestamp: row.validAt,
                pressure: Pressure(hectopascals: offset.stationPressureHPa(
                    fromMeanSeaLevel: row.meanSeaLevelPressureHPa,
                    temperatureC: row.temperatureC
                )),
                uncertaintyHPa: ForecastSource.weatherKit.uncertaintyHPa(
                    atLeadSeconds: row.leadTimeSeconds
                ),
                source: .weatherKit,
                issuedAt: row.issuedAt
            )
        }

        return evaluate(forecasts: points, observed: readings, source: .weatherKit, asOf: now)
    }

    /// The reading closest to `instant`, or `nil` when the nearest one is too far away.
    ///
    /// A gap in the log is a horizon that cannot be scored, not one scored against the nearest
    /// thing available. Overnight gaps are ordinary here — the phone is asleep — so this is the
    /// common path rather than the edge case.
    private static func reading(at instant: Date, in readings: [PressureSample]) -> Double? {
        readings
            .min { abs($0.timestamp.timeIntervalSince(instant)) < abs($1.timestamp.timeIntervalSince(instant)) }
            .flatMap {
                abs($0.timestamp.timeIntervalSince(instant)) <= matchToleranceSeconds
                    ? $0.pressure.hectopascals
                    : nil
            }
    }

    /// Zero for an empty set rather than a crash. A horizon with no pairs reports
    /// `pairCount == 0`, and the zero beside it is never read as "no error" because the count
    /// is right there — §8's "degrade gracefully, do not divide by zero".
    private static func mean(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }

        return values.reduce(0, +) / Double(values.count)
    }
}
