import Foundation

/// One check-in placed onto the pressure line, so the chart can show *when* the user logged
/// how they felt against the weather around it.
///
/// **Display only.** This is the chart's join between two series and nothing else — it has no
/// row in the feature registry and nothing in `Shared/Features/` may read it. The model reads
/// `CheckIn` and `PressureSample` from their stores and computes its own alignment with the
/// gap and coverage rules in `.claude/context/ml-spec.md` §2.1, which are stricter than what a
/// 110 pt-tall plot needs.
///
/// Carries the intensity rather than a colour: `Shared/` is UI-free, and which colour belongs
/// to which point of the 1–10 scale is a design decision that lives in `Palette`.
struct CheckInMarker: Identifiable, Hashable, Sendable {

    /// The check-in's own identifier, so a redraw keeps `ForEach` identity and a check-in
    /// delivered twice cannot become two dots.
    let id: UUID

    /// When the user reported this — the check-in's own timestamp, never the drawn point's.
    /// The dot has to sit at the instant it was logged, not at the nearest reading.
    let timestamp: Date

    let intensity: CheckInIntensity

    /// Where on the vertical axis the dot goes: the pressure the drawn line is at, in hPa.
    ///
    /// Not a measurement, and never printed as one. It exists so the dot rides the line
    /// instead of floating in the plot — see `place(_:on:tolerance:)`.
    let hectopascals: Double
}

extension CheckInMarker {

    /// How far a check-in may sit from the nearest drawn point and still be placed.
    ///
    /// Two hours, matching the interpolation limit the feature pipeline uses for pressure
    /// gaps (`.claude/context/ml-spec.md` §2.1). Beyond it there is no line worth attaching a
    /// dot to: iOS grants background wakes rather than scheduling them, so a phone left alone
    /// overnight leaves a real hole, and a dot drawn across it would sit on a segment the
    /// chart interpolated out of nothing.
    ///
    /// *Provisional*, and a display threshold rather than a modelling one — chosen so the two
    /// numbers do not disagree, not because a chart needs the same tolerance a feature does.
    static let placementToleranceSeconds: TimeInterval = 2 * 3600

    /// Places check-ins onto the line the chart draws.
    ///
    /// `line` is `PressureSeries.observed` — the **drawn** points, bucket means included, not
    /// the raw log. That is deliberate: the dot's whole job is to sit on the line the user can
    /// see, and interpolating against raw readings the chart never drew would leave it
    /// hovering beside the curve on every range that buckets.
    ///
    /// A check-in inside the line's span takes the linear interpolation between its two
    /// neighbours; one outside the span but within `tolerance` of an end clamps to that end.
    /// Anything further out is dropped rather than guessed — a dot pinned to a flat default
    /// would read as a measurement that was never taken.
    ///
    /// One caveat worth stating: the plot joins its points with `catmullRom`, so on a sharply
    /// curving stretch the straight-line placement can sit a fraction of a hPa off the drawn
    /// curve. At the domains this chart uses that is a couple of points on screen, and the
    /// alternative — reimplementing Swift Charts' spline here — would be a second copy of
    /// somebody else's interpolation to keep in sync.
    ///
    /// `line` must be ascending by timestamp, which is `PressureSeries.observed`'s contract.
    /// `checkIns` may be in any order; the result is ascending.
    static func place(_ checkIns: [CheckIn],
                      on line: [PressureSample],
                      tolerance: TimeInterval = placementToleranceSeconds) -> [CheckInMarker] {
        guard !checkIns.isEmpty, !line.isEmpty else { return [] }

        return checkIns
            .sorted { $0.timestamp < $1.timestamp }
            .compactMap { checkIn in
                guard let hectopascals = value(at: checkIn.timestamp, on: line, tolerance: tolerance)
                else { return nil }

                return CheckInMarker(id: checkIn.id,
                                     timestamp: checkIn.timestamp,
                                     intensity: checkIn.intensity,
                                     hectopascals: hectopascals)
            }
    }

    /// The line's value at `instant`, or `nil` when there is nothing close enough to attach to.
    private static func value(at instant: Date,
                              on line: [PressureSample],
                              tolerance: TimeInterval) -> Double? {
        // `partitioningIndex`-free on purpose: the line is at most 288 points
        // (`PressureChartRange.historySeconds / bucketSeconds`) and this runs once per rebuild,
        // so a scan is cheaper to read than a binary search and cannot be off by one.
        let before = line.last { $0.timestamp <= instant }
        let after = line.first { $0.timestamp >= instant }

        switch (before, after) {
        case let (earlier?, later?):
            return interpolate(at: instant, between: earlier, and: later)

        // Past the newest drawn point — the ordinary case for a check-in logged right now,
        // since the newest reading is by definition already in the past.
        case let (earlier?, nil):
            guard instant.timeIntervalSince(earlier.timestamp) <= tolerance else { return nil }
            return earlier.pressure.hectopascals

        // Before the oldest drawn point: a check-in that survived a barometer history the
        // retention horizon or the scroll extent has since cut off.
        case let (nil, later?):
            guard later.timestamp.timeIntervalSince(instant) <= tolerance else { return nil }
            return later.pressure.hectopascals

        case (nil, nil):
            return nil
        }
    }

    /// Linear interpolation between two drawn points.
    ///
    /// The gap between them is checked against nothing here on purpose: two points the chart
    /// has already joined with a visible segment are a line, however far apart they are, and
    /// the dot belongs on it. The tolerance guards the ends, where there is no segment at all.
    private static func interpolate(at instant: Date,
                                    between earlier: PressureSample,
                                    and later: PressureSample) -> Double {
        let span = later.timestamp.timeIntervalSince(earlier.timestamp)
        // Same point on both sides, or two readings sharing a timestamp: nothing to divide by.
        guard span > 0 else { return earlier.pressure.hectopascals }

        let progress = instant.timeIntervalSince(earlier.timestamp) / span
        let rise = later.pressure.hectopascals - earlier.pressure.hectopascals
        return earlier.pressure.hectopascals + rise * progress
    }
}
