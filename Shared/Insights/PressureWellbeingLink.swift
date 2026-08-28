import Foundation

/// How the barometer has lined up with this user's own check-ins, and at what delay.
///
/// ## What this is and is not
///
/// A **correlation over the user's own log**, restated back to them. It is not a model, it
/// makes no forecast, and nothing in `Shared/Features/` or `Shared/Risk/` may read it — the
/// risk model has its own features and its own validation, and a second number describing the
/// same relationship would be a second answer nobody reconciled. This is display only, the same
/// standing `WeatherTriggerIndex` has.
///
/// It is also **not a statement about the user's body**. The wording rule that governs the card
/// drawing it is `.claude/skills/appstore_compliance/SKILL.md`: what this measures is how the
/// numbers the user wrote down move with the numbers the sensor recorded, and the copy has to
/// read as "your history suggests", never as a mechanism.
///
/// ## Why the coefficient is honest and the lag is soft
///
/// The coefficient is an ordinary Pearson *r* over pairs the user themselves produced, so it is
/// checkable. The lag is not: it is the best of `lagHoursSearched` candidates, and taking the
/// maximum over seven searches inflates the magnitude that survives. That is the reason for
/// three deliberate conservatisms — `minimumPairs` is high enough that a handful of check-ins
/// cannot produce a figure at all, the bands are Cohen's rather than something flattering, and
/// the lag is only ever drawn with a `~` in front of it. A single reported *r* here is a
/// **screening** number, not a tested hypothesis, and a card that reads it as the latter would
/// be over-claiming by construction.
///
/// ## Station pressure
///
/// The pairs are built off `HourlyPressureGrid`, so the §3 rate gate has already thrown out
/// lift rides and bad reads. What it cannot remove is a slow one-way climb, which the whole app
/// carries — see `WeatherTriggerIndex`'s own note. A six-hour *change* is the least exposed
/// thing the log offers, which is also why the model is fitted on changes rather than levels.
struct PressureWellbeingLink: Hashable, Sendable {

    /// How the card words the size of the association.
    ///
    /// Three bands rather than a raw number alone, because *r* = 0.31 and *r* = 0.29 are the
    /// same finding and printing only the digits invites the reader to tell them apart.
    enum Strength: String, Hashable, Sendable {
        case weak
        case moderate
        case strong
    }

    /// Pearson *r* between a six-hour **fall** in pressure and the intensity reported
    /// `lagHours` later. −1 to 1.
    ///
    /// **Oriented on the fall.** Positive means a larger fall went with a higher number on the
    /// 1–10 scale — which is worse, since `CheckInIntensity` runs that way. Negative is the
    /// opposite pattern and is a real answer, not a sign error: some people's log lines up with
    /// rising pressure, and flipping the sign to make every user's card read positive would be
    /// telling them something the data did not say.
    let coefficient: Double

    /// The delay, in hours, at which the association was strongest.
    ///
    /// One of `lagHoursSearched`, never an interpolated value: the search is over that list and
    /// reporting "7 h" from a grid that only tried 6 and 9 would imply a resolution the method
    /// does not have.
    let lagHours: Int

    /// Check-ins that had six hours of grid behind them at this lag.
    ///
    /// Reported rather than hidden, and the card prints it: an *r* from eleven pairs and one
    /// from a hundred are different claims, and §5 of the ML spec refuses to let a thin fold
    /// average away silently.
    let pairCount: Int

    /// Which band the magnitude falls in.
    var strength: Strength {
        let magnitude = abs(coefficient)

        if magnitude >= Self.strongThreshold { return .strong }
        if magnitude >= Self.moderateThreshold { return .moderate }
        return .weak
    }

    /// Whether the falling side is the one that lines up with a higher number.
    ///
    /// What the card's sentence is built on — the two directions need different words, and a
    /// single sentence with the sign dropped would describe half the users wrongly.
    var isFallLeading: Bool { coefficient >= 0 }
}

extension PressureWellbeingLink {

    /// The stretch of pressure change each pair is taken over.
    ///
    /// Six hours, the window `pressureDeltaHPaPer6h` is defined over in §2.1 — so this card and
    /// the eventual feature describe the same quantity rather than two that merely sound alike.
    static let changeWindowHours = 6

    /// Delays the search tries, in hours.
    ///
    /// Three-hour steps out to a day. Finer steps would not be resolvable — check-ins are
    /// logged when the user gets round to it, not on the hour — and going past 24 h starts
    /// pairing a check-in with a different weather system than the one it followed.
    static let lagHoursSearched = [0, 3, 6, 9, 12, 18, 24]

    /// Fewest pairs that will produce a coefficient at all.
    ///
    /// Below this the card says the app is still learning instead of printing a number. Ten is
    /// not a power calculation — it is the point at which a single outlying check-in stops
    /// being able to move *r* by more than about a band on its own. *Provisional*: re-derive it
    /// from a real distribution of traces, which this app does not have yet.
    static let minimumPairs = 10

    /// Cohen's conventional medium and large effect sizes. Not tuned, on purpose: a threshold
    /// chosen to make more cards say "strong" is a threshold chosen to flatter.
    static let moderateThreshold: Double = 0.3
    static let strongThreshold: Double = 0.5

    /// The strongest association in `checkIns`, or `nil` when there is not enough to look at.
    ///
    /// `samples` and `checkIns` may be unsorted; both are taken as the whole window the caller
    /// wants examined. `nil` covers every thin case and they are all drawn the same way — the
    /// card says the pattern is still building rather than printing a number off four points.
    ///
    /// Builds its own grid. A caller that needs the same cells for something else should build
    /// them once with `hourlyCells(from:asOf:)` and use the overload below — gridding four
    /// months of samples is the expensive half of this screen and it is on the main actor.
    static func make(checkIns: [CheckIn],
                     samples: [PressureSample],
                     asOf now: Date) -> PressureWellbeingLink? {
        make(checkIns: checkIns, cells: hourlyCells(from: samples, asOf: now))
    }

    /// The same search over a grid the caller already has.
    static func make(checkIns: [CheckIn],
                     cells: [HourlyPressureGrid.Cell]) -> PressureWellbeingLink? {
        let grid = hourlyPressure(from: cells)
        guard !grid.isEmpty else { return nil }

        var best: PressureWellbeingLink?

        for lagHours in lagHoursSearched {
            guard let candidate = link(at: lagHours, checkIns: checkIns, grid: grid) else {
                continue
            }
            // Strictly greater, so the **shortest** lag wins a tie. Two lags that fit equally
            // well are one finding, and the nearer one is the one the log can actually
            // distinguish from coincidence.
            if abs(candidate.coefficient) > abs(best?.coefficient ?? 0) { best = candidate }
        }

        return best
    }

    /// The hourly grid over everything `samples` reaches, excursions already rejected.
    ///
    /// The one place the Insights window is gridded. `WellbeingInsights.make` calls it once and
    /// hands the cells to both this type and `WellbeingPatternNote`, which used to grid the same
    /// four months a second time — the same rows, the same answer, twice the work on the main
    /// actor while the tab is coming up.
    ///
    /// Bridged cells are kept: a two-hour hole spanned linearly is the same value the fit is
    /// allowed to use, and dropping it here would make this card stricter than the model it
    /// sits beside for no stated reason.
    static func hourlyCells(from samples: [PressureSample],
                            asOf now: Date) -> [HourlyPressureGrid.Cell] {
        guard let earliest = samples.map(\.timestamp).min() else { return [] }

        return HourlyPressureGrid.cells(from: samples,
                                        in: earliest..<max(now, earliest.addingTimeInterval(1)))
    }

    /// The grid as an hour lookup.
    private static func hourlyPressure(from cells: [HourlyPressureGrid.Cell]) -> [Date: Double] {
        Dictionary(cells.map { ($0.hour, $0.hectopascals) }, uniquingKeysWith: { first, _ in first })
    }

    /// One lag's worth of correlation, or `nil` when the pairs will not support one.
    private static func link(at lagHours: Int,
                             checkIns: [CheckIn],
                             grid: [Date: Double]) -> PressureWellbeingLink? {
        var falls: [Double] = []
        var intensities: [Double] = []

        for checkIn in checkIns {
            let anchor = checkIn.timestamp.addingTimeInterval(-Double(lagHours) * 3600)
            let hour = alignedHour(of: anchor)
            let earlier = hour.addingTimeInterval(-Double(changeWindowHours) * 3600)

            guard let atAnchor = grid[hour], let atEarlier = grid[earlier] else { continue }

            // Positive is a **fall**, so a positive coefficient reads the way the card's
            // sentence does. Signed, never magnitude: folding a rise and a fall of the same
            // size into one number would make the two indistinguishable and the correlation
            // meaningless.
            falls.append(atEarlier - atAnchor)
            intensities.append(Double(checkIn.intensity.rawValue))
        }

        guard falls.count >= minimumPairs,
              let coefficient = pearson(falls, intensities)
        else { return nil }

        return PressureWellbeingLink(coefficient: coefficient,
                                     lagHours: lagHours,
                                     pairCount: falls.count)
    }

    /// Start of the hour containing `instant`, aligned to the epoch.
    ///
    /// The alignment `HourlyPressureGrid` buckets on — a different one here would look up hours
    /// that are never in the grid and the whole search would return `nil`.
    private static func alignedHour(of instant: Date) -> Date {
        Date(timeIntervalSince1970: (instant.timeIntervalSince1970 / 3600).rounded(.down) * 3600)
    }

    /// Pearson *r*, or `nil` when either side does not vary.
    ///
    /// `nil` rather than zero for a flat side. A week where the user logged 5 every time, or a
    /// dead-calm stretch of weather, has no correlation *to* report — and a printed 0.00 would
    /// read as "measured, no relationship" when the truth is "there was nothing to measure".
    private static func pearson(_ lhs: [Double], _ rhs: [Double]) -> Double? {
        guard lhs.count == rhs.count, !lhs.isEmpty else { return nil }

        let count = Double(lhs.count)
        let meanLHS = lhs.reduce(0, +) / count
        let meanRHS = rhs.reduce(0, +) / count

        var covariance: Double = 0
        var varianceLHS: Double = 0
        var varianceRHS: Double = 0

        for (left, right) in zip(lhs, rhs) {
            let deltaLHS = left - meanLHS
            let deltaRHS = right - meanRHS
            covariance += deltaLHS * deltaRHS
            varianceLHS += deltaLHS * deltaLHS
            varianceRHS += deltaRHS * deltaRHS
        }

        let denominator = (varianceLHS * varianceRHS).squareRoot()
        guard denominator > 0 else { return nil }

        return min(max(covariance / denominator, -1), 1)
    }
}
