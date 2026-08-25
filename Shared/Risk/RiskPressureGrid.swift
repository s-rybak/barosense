import Foundation

/// Where this user's pressure normally sits, and the offset that puts it on the reference axis.
///
/// ## Why the model does not read raw station pressure
///
/// The notebook's level features are `1013 − p`, and 1013 hPa is not a constant of nature
/// there — it is the mean of the synthetic series they were fitted on. `CMAltimeter` reports
/// **station** pressure, which carries the user's elevation: near Kyiv (~180 m) that is about
/// 991 hPa, so `1013 − p` would read a permanent 22 hPa "deficit" on a perfectly ordinary day.
/// Twenty-two hPa is five to seven times a whole day's weather. Fed to coefficients fitted at
/// sea level, it is not a small bias — it saturates the two level features into constants.
///
/// So the series is re-centred once, at the grid boundary: every reading is shifted by
/// `referenceHPa − baseline`, where the baseline is this user's own trailing median. After that
/// the five slot quantities are literally the notebook's formulas, the shipped coefficients
/// apply unchanged, and the level features mean "how far below your own normal", which is the
/// quantity they were always standing in for.
///
/// The two *change* features are untouched by this — a constant offset cancels in a difference —
/// which is a useful check that the shift is doing what it claims.
struct RiskPressureBaseline: Hashable, Sendable, Codable {

    /// The axis the shipped coefficients were fitted on, hPa.
    static let referenceHPa: Double = 1013.0

    /// How far back the median is taken.
    ///
    /// **30 days**, matching `LocalPressureModel.trainingWindowDays`. Long enough that a week
    /// of settled high pressure does not drag the baseline up behind it; short enough to follow
    /// a move to a different elevation, which is the case that would otherwise poison every
    /// level feature at once.
    static let windowDays = 30

    /// Median of the user's own observed hourly cells over the window, hPa.
    let hectopascals: Double

    /// How many cells it was taken over. Carried so a caller can tell a baseline measured over
    /// a month from one measured over an afternoon.
    let cellCount: Int

    /// What every reading is shifted by before a feature is computed.
    var offsetHPa: Double { Self.referenceHPa - hectopascals }

    /// `nil` when there is nothing to measure from. A baseline guessed at is worse than no
    /// features: it would put every level quantity out by however far the guess was wrong.
    static func measured(from cells: [HourlyPressureGrid.Cell]) -> RiskPressureBaseline? {
        let observed = cells.filter(\.isObserved).map(\.hectopascals).sorted()
        guard !observed.isEmpty else { return nil }

        let middle = observed.count / 2
        let median = observed.count.isMultiple(of: 2)
            ? (observed[middle - 1] + observed[middle]) / 2
            : observed[middle]

        return RiskPressureBaseline(hectopascals: median, cellCount: observed.count)
    }
}

/// One hour of the merged series the risk features are read off.
///
/// Merged, because the question the model answers spans the join: at 08:00 the day's later
/// windows have not happened yet, and their six-hour fall has to come from the forecast or it
/// cannot be named in advance at all. Which side a cell came from is carried rather than
/// smoothed over — it is what lets the forecast report how much of the day it is guessing.
struct RiskGridCell: Hashable, Sendable {

    let hour: Date

    /// Re-centred onto `RiskPressureBaseline.referenceHPa`. Never the raw sensor value.
    let hectopascals: Double

    /// True only for an hour a sensor actually recorded in. False for a bridged hole and for
    /// every forward-looking cell — which is what keeps coverage a statement about the sensor.
    let isMeasured: Bool

    /// True when the value came from a forecast curve rather than from the log.
    let isForecast: Bool
}

/// The merged hourly grid, and the five barometric quantities read off it.
///
/// ## The grid is hourly, and the notebook's was quarter-hourly
///
/// Not a simplification to save work — it is what the two producers can actually supply. The
/// forward half is hourly by construction (WeatherKit publishes hourly, `LocalPressureModel`
/// iterates hourly), and the backward half arrives opportunistically, so a quarter-hourly grid
/// behind `now` would be mostly holes and would still be hourly ahead of it. One grid on both
/// sides of the join is the only arrangement in which a window's features mean the same thing
/// before and after `now`.
///
/// What it costs is resolution inside a window: two cells averaged rather than eight. The
/// notebook's own width sweep is the evidence that this is not where the signal lives —
/// ranking quality holds at ROC-AUC 0.764–0.799 all the way from 30-minute to 4-hour windows.
enum RiskPressureGrid {

    /// How far back a feature at `t` reaches: the seven-day mean is the longest window.
    static let historySeconds: TimeInterval = 7 * 24 * 3600

    /// How far a cell may be from a horizon and still answer for it.
    ///
    /// **Half an hour**, which on an hourly grid means the exact cell and nothing else. The
    /// six- and 24-hour falls are the two features that carry the signal, and reading one off
    /// a cell three hours from where it was asked for would report a different quantity under
    /// the same name.
    static let horizonToleranceSeconds: TimeInterval = 30 * 60

    /// The merged grid over `range`, ascending, holes omitted.
    ///
    /// `observed` is passed raw and goes through `HourlyPressureGrid` here — altitude
    /// excursions rejected, short gaps bridged — so this type never sees a lift ride.
    static func cells(observed: [PressureSample],
                      forecast: [ForecastPressurePoint],
                      in range: Range<Date>,
                      asOf now: Date,
                      baseline: RiskPressureBaseline) -> [RiskGridCell] {
        let offset = baseline.offsetHPa

        var byHour: [Date: RiskGridCell] = [:]

        for cell in HourlyPressureGrid.cells(from: observed, in: range) {
            byHour[cell.hour] = RiskGridCell(hour: cell.hour,
                                             hectopascals: cell.hectopascals + offset,
                                             isMeasured: cell.isObserved,
                                             isForecast: false)
        }

        // The forward half fills hours the sensor cannot have reached, and never overwrites one
        // it did. A measurement and a forecast for the same hour are not two opinions to
        // average — the sensor was there.
        for point in forecast where point.timestamp > now {
            let hour = alignedHour(of: point.timestamp)
            guard range.contains(hour), byHour[hour] == nil else { continue }

            byHour[hour] = RiskGridCell(hour: hour,
                                        hectopascals: point.pressure.hectopascals + offset,
                                        isMeasured: false,
                                        isForecast: true)
        }

        return byHour.values.sorted { $0.hour < $1.hour }
    }

    static func alignedHour(of instant: Date) -> Date {
        Date(timeIntervalSince1970: (instant.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// The five slot quantities at one hour of the grid.
    ///
    /// Computed per hour and only then averaged into a window, which is the order the notebook
    /// fixes and the reverse of the convenient one. Averaging pressure first and differencing
    /// afterwards is a low-pass filter in front of the one feature that carries the signal: it
    /// rounds a real six-hour fall down toward "steady".
    static func slotFeatures(at index: Int,
                             in cells: [RiskGridCell],
                             byHour: [Date: RiskGridCell]) -> RiskSlotFeatures? {
        guard cells.indices.contains(index) else { return nil }
        let cell = cells[index]

        return RiskSlotFeatures(
            pressureHPa: cell.hectopascals,
            levelDeficitHPa: max(0, RiskPressureBaseline.referenceHPa - cell.hectopascals),
            drop6hHPa: drop(to: cell, hoursBack: 6, byHour: byHour),
            drop24hHPa: drop(to: cell, hoursBack: 24, byHour: byHour),
            low7dHPa: low7d(at: index, in: cells)
        )
    }

    /// `max(0, p(t − h) − p(t))` — a **fall** is positive and a rise reads as zero.
    ///
    /// Clipped rather than signed because that is what the fitted coefficients expect, and the
    /// clipping is the domain claim: the literature discusses falling pressure, and a rise of
    /// 4 hPa is not "minus four hPa of falling", it is a different kind of day.
    ///
    /// `nil` when the grid has no cell at exactly `t − h`. Never interpolated across the hole —
    /// a fall measured against an invented value is the confidently-wrong number the registry
    /// rules out.
    private static func drop(to cell: RiskGridCell,
                             hoursBack hours: Int,
                             byHour: [Date: RiskGridCell]) -> Double? {
        let earlier = cell.hour.addingTimeInterval(-Double(hours) * 3600)
        guard let past = byHour[earlier] else { return nil }

        return max(0, past.hectopascals - cell.hectopascals)
    }

    /// `max(0, reference − mean(p) over the trailing seven days)` — "pressure has stayed low".
    ///
    /// Expanding at the near end rather than `nil`: with one cell it is that cell, which is a
    /// weaker statement of the same thing and not a wrong one. The notebook's `min_periods=1`,
    /// carried over deliberately — this is the feature that matters least (coefficient 0.04 of
    /// 1.35) and refusing it on a thin log would drop rows the two useful features can answer.
    private static func low7d(at index: Int, in cells: [RiskGridCell]) -> Double {
        let cell = cells[index]
        let from = cell.hour.addingTimeInterval(-historySeconds)

        var sum = 0.0
        var count = 0
        var cursor = index
        while cursor >= 0, cells[cursor].hour > from {
            sum += cells[cursor].hectopascals
            count += 1
            cursor -= 1
        }
        guard count > 0 else { return 0 }

        return max(0, RiskPressureBaseline.referenceHPa - sum / Double(count))
    }
}

/// The five barometric quantities at one hour, before they are averaged into a window.
///
/// Names carry the unit because the two families read very differently: a *level* deficit of
/// 4 hPa is an ordinary low-pressure day, and a *six-hour fall* of 4 hPa is a front arriving.
struct RiskSlotFeatures: Hashable, Sendable {

    let pressureHPa: Double

    /// How far below this user's own normal, hPa. Zero on any day at or above it.
    let levelDeficitHPa: Double

    /// The one that carries the signal: fitted coefficient +1.35 on standardised units,
    /// against +0.16 for the 24-hour fall and −0.06 for the level.
    let drop6hHPa: Double?

    let drop24hHPa: Double?

    let low7dHPa: Double
}
