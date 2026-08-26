import Foundation

/// The feature registry for the risk model, as an ordered enum.
///
/// The order **is** the column order of every vector in this subsystem, and the shipped
/// coefficients in `WellbeingRiskPrior` are indexed by it. Inserting a case in the middle
/// silently re-labels every coefficient, so new cases go on the end and nothing is renumbered.
///
/// ## Why each quantity appears twice
///
/// Once per window and once per day, and they answer different questions. The day copies are
/// constant inside a day by construction, so they cannot rank one window above another — they
/// say *whether* today is a day for an entry. The window copies move inside the day, so they
/// say *when*. Measured apart: window features alone reach hit@1 = 0.43, day features alone
/// 0.11 at ROC-AUC 0.535, which is a coin. Fitting one model on both and calling it "the
/// forecast" is what the two-stage arrangement in `WellbeingRiskModel` exists to avoid.
enum RiskFeature: Int, CaseIterable, Hashable, Sendable, Codable {
    case pressureHPa = 0
    case levelDeficitHPa = 1
    case drop6hHPa = 2
    case drop24hHPa = 3
    case low7dHPa = 4
    case dayLevelDeficitHPa = 5
    case dayDrop6hHPa = 6
    case dayDrop24hHPa = 7
    case dayLow7dHPa = 8

    /// Every column, in registry order. What the shipped window model reads.
    static let windowColumns: [RiskFeature] = allCases

    /// The day-level columns. What both the shipped and the personal day model read — one row
    /// per day, so a window column here would be a value picked arbitrarily out of nine.
    static let dayColumns: [RiskFeature] = [
        .dayLevelDeficitHPa, .dayDrop6hHPa, .dayDrop24hHPa, .dayLow7dHPa
    ]

    /// What the **personal** window model is allowed to fit.
    ///
    /// Six columns, which is the budget §4 of `ml-spec.md` sets for the personal component:
    /// at 2–3 entries a day, three weeks of history is a few dozen rows and more parameters
    /// than events is memorisation dressed as a model. The prior may be richer; this may not.
    ///
    /// Three matched window/day pairs, so the personal fit can still learn the comparison the
    /// shipped coefficients turn on — a fall that **exceeds today's own average** rather than a
    /// fall that is merely large. Dropped: raw `pressureHPa`, which is a level and therefore
    /// the column most exposed to a change of place; and both seven-day terms, which barely
    /// move inside a 30-day window and carry the two smallest coefficients in the prior
    /// (0.042 and −0.040 against 1.35).
    static let personalWindowColumns: [RiskFeature] = [
        .drop6hHPa, .dayDrop6hHPa, .drop24hHPa, .dayDrop24hHPa,
        .levelDeficitHPa, .dayLevelDeficitHPa
    ]
}

/// One scored unit: a two-hour window, its features, and whether the user made an entry in it.
///
/// A value type with no store behind it, so the whole pipeline runs from a plain unit test with
/// literals — the seam `ml_pipeline` asks for.
struct RiskWindowRow: Hashable, Sendable, Identifiable {

    var id: Date { start }

    let start: Date

    /// Start of the waking day this window belongs to. The grouping key for the day model and
    /// for every forward-chaining split — folds are cut on day boundaries, never mid-day.
    let dayStart: Date

    /// Values in `RiskFeature.allCases` order. `nil` where the grid could not answer: no cell
    /// six hours back, no cell in the window at all. Absence travels; it is not filled here.
    let features: [Double?]

    /// Fraction of the window's hours a sensor actually recorded in. Zero on a window that is
    /// entirely forecast, which is the ordinary state of every window after `now`.
    let coverage: Double

    /// Fraction of the window's hours that came from a forecast curve.
    let forecastShare: Double

    /// Fraction of the **day's** windows that held any cell at all.
    ///
    /// Carried on every row of the day rather than derived, because the day-level features are
    /// means over those windows: a day with two windows covered produces day features that are
    /// a statement about two hours under the name of a whole day, and the trainer drops it.
    let dayCoverage: Double

    /// Whether the user made an entry in this window. The label — meaningful only for a window
    /// that has already happened, and always `false` ahead of `now`.
    let isLogged: Bool

    subscript(feature: RiskFeature) -> Double? {
        features.indices.contains(feature.rawValue) ? features[feature.rawValue] : nil
    }

    /// The row projected onto a column set, in that set's order.
    func vector(_ columns: [RiskFeature]) -> [Double?] {
        columns.map { self[$0] }
    }

    var end: Date { start.addingTimeInterval(TimeInterval(RiskWindowGeometry.windowMinutes) * 60) }
}

/// Turns two logs and a forecast curve into scored rows.
///
/// Pure and synchronous. Everything asynchronous — opening a store, measuring the WeatherKit
/// offset, refitting the local model — has already happened by the time anything reaches here.
enum RiskWindowBuilder {

    /// A day needs at least this share of its windows covered before its day-level features
    /// are worth anything.
    ///
    /// **50%.** Below it the day mean is a mean of a morning, and the day model's whole claim
    /// is about the day. The trainer drops such days; the forecast reports them as thin rather
    /// than pretending.
    static let minimumDayCoverage: Double = 0.5

    /// Rows for every waking window that overlaps `range`.
    ///
    /// `range` is the span of **windows** wanted. The grid is built further back than that on
    /// its own — the 24-hour fall and the seven-day mean at the first window need history from
    /// before it — so a caller asks for the days it wants scored and nothing more.
    /// `baseline` is measured from `observed` when it is not supplied, which is only right
    /// when `observed` covers `RiskPressureBaseline.windowDays`. A caller that reads a shorter
    /// span — the forecast path reads eight days, not thirty — must measure the baseline over
    /// the full window separately and pass it in, or every level feature it produces will be
    /// centred differently from the ones the model was fitted on.
    static func rows(observed: [PressureSample],
                     forecast: [ForecastPressurePoint] = [],
                     checkIns: [CheckIn] = [],
                     geometry: RiskWindowGeometry,
                     baseline measuredBaseline: RiskPressureBaseline? = nil,
                     in range: Range<Date>,
                     asOf now: Date) -> [RiskWindowRow] {
        let gridRange = range.lowerBound.addingTimeInterval(-RiskPressureGrid.historySeconds)
            ..< range.upperBound.addingTimeInterval(3600)

        guard let baseline = measuredBaseline ?? baseline(observed: observed, asOf: now),
              baseline.isUsable
        else { return [] }

        let cells = RiskPressureGrid.cells(observed: observed,
                                           forecast: forecast,
                                           in: gridRange,
                                           asOf: now,
                                           baseline: baseline)
        guard !cells.isEmpty else { return [] }

        let byHour = Dictionary(cells.map { ($0.hour, $0) }, uniquingKeysWith: { first, _ in first })
        let slots = cells.indices.compactMap { index -> (RiskGridCell, RiskSlotFeatures)? in
            guard let features = RiskPressureGrid.slotFeatures(at: index, in: cells, byHour: byHour)
            else { return nil }
            return (cells[index], features)
        }

        let loggedWindows = Set(checkIns.compactMap { geometry.windowStart(containing: $0.timestamp) })

        return assemble(slots: slots,
                        loggedWindows: loggedWindows,
                        geometry: geometry,
                        in: range)
    }

    /// The window the baseline median is taken over.
    static func baselineRange(endingAt now: Date) -> Range<Date> {
        now.addingTimeInterval(-Double(RiskPressureBaseline.windowDays) * 24 * 3600)
            ..< now.addingTimeInterval(3600)
    }

    /// This user's trailing median over `baselineRange`, for a caller that has the whole window
    /// in hand and wants to reuse it across several `rows` calls.
    ///
    /// `nil` when `observed` cannot fill `RiskPressureBaseline.minimumCells` of it.
    static func baseline(observed: [PressureSample], asOf now: Date) -> RiskPressureBaseline? {
        RiskPressureBaseline
            .measured(from: HourlyPressureGrid.cells(from: observed,
                                                     in: baselineRange(endingAt: now)))
            .flatMap { $0.isUsable ? $0 : nil }
    }

    // MARK: - Assembly

    private static func assemble(slots: [(cell: RiskGridCell, features: RiskSlotFeatures)],
                                 loggedWindows: Set<Date>,
                                 geometry: RiskWindowGeometry,
                                 in range: Range<Date>) -> [RiskWindowRow] {
        // Group the hours into the windows the geometry defines. An hour in the night the
        // domain excludes belongs to no window and is dropped here — it still contributed to
        // the six-hour falls above, which is the point of doing this after the slot features
        // rather than before.
        var byWindow: [Date: [(cell: RiskGridCell, features: RiskSlotFeatures)]] = [:]
        for slot in slots {
            guard let window = geometry.windowStart(containing: slot.cell.hour),
                  range.contains(window) else { continue }
            byWindow[window, default: []].append(slot)
        }
        guard !byWindow.isEmpty else { return [] }

        let hoursPerWindow = Double(RiskWindowGeometry.windowMinutes) / 60

        // Window-level means of the five slot quantities, before the day means are taken off
        // them. This is the notebook's order: mean of window means, not mean of hours.
        var windowMeans: [Date: [RiskFeature: Double]] = [:]
        var windowCoverage: [Date: (measured: Double, forecast: Double)] = [:]

        for (window, group) in byWindow {
            windowMeans[window] = [
                .pressureHPa: mean(group.map(\.features.pressureHPa)),
                .levelDeficitHPa: mean(group.map(\.features.levelDeficitHPa)),
                .low7dHPa: mean(group.map(\.features.low7dHPa))
            ].compactMapValues { $0 }

            windowMeans[window]?[.drop6hHPa] = mean(group.compactMap(\.features.drop6hHPa))
            windowMeans[window]?[.drop24hHPa] = mean(group.compactMap(\.features.drop24hHPa))

            windowCoverage[window] = (
                measured: Double(group.count { $0.cell.isMeasured }) / hoursPerWindow,
                forecast: Double(group.count { $0.cell.isForecast }) / hoursPerWindow
            )
        }

        // Day means, taken over the windows of the day that have a value for that column.
        let windowsByDay = Dictionary(grouping: windowMeans.keys) { geometry.wakingDayStart(of: $0) }
        var dayMeans: [Date: [RiskFeature: Double]] = [:]
        var dayCoverage: [Date: Double] = [:]

        for (day, windows) in windowsByDay {
            var means: [RiskFeature: Double] = [:]
            for (source, target) in Self.dayColumnSources {
                means[target] = mean(windows.compactMap { windowMeans[$0]?[source] })
            }
            dayMeans[day] = means
            dayCoverage[day] = Double(windows.count) / Double(geometry.windowsPerDay)
        }

        return windowMeans.keys.sorted().map { window in
            let day = geometry.wakingDayStart(of: window)
            let slot = windowMeans[window] ?? [:]
            let daily = dayMeans[day] ?? [:]
            let cover = windowCoverage[window] ?? (0, 0)

            let values = RiskFeature.allCases.map { feature -> Double? in
                RiskFeature.dayColumns.contains(feature) ? daily[feature] : slot[feature]
            }

            return RiskWindowRow(start: window,
                                 dayStart: day,
                                 features: values,
                                 coverage: min(1, cover.measured),
                                 forecastShare: min(1, cover.forecast),
                                 dayCoverage: min(1, dayCoverage[day] ?? 0),
                                 isLogged: loggedWindows.contains(window))
        }
    }

    /// Which window column each day column is the mean of.
    private static let dayColumnSources: [(RiskFeature, RiskFeature)] = [
        (.levelDeficitHPa, .dayLevelDeficitHPa),
        (.drop6hHPa, .dayDrop6hHPa),
        (.drop24hHPa, .dayDrop24hHPa),
        (.low7dHPa, .dayLow7dHPa)
    ]

    private static func mean(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}
