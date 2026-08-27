import Foundation

/// When the next stretch the model points at begins.
///
/// Two cases rather than a `TimeInterval?`, because "no lead time" and "zero lead time" are
/// different facts and a single optional would collapse them: `nil` means the model marked
/// nothing, `.underWay` means it marked a stretch the clock is already inside. A card that
/// printed "in 0 min" for the second would be reporting a countdown that has already expired.
enum RiskLead: Hashable, Sendable {

    /// The stretch has begun and has not finished.
    case underWay

    /// It begins in this many seconds. Never below `RiskOutlook.minimumLeadSeconds`.
    case ahead(TimeInterval)
}

/// What the risk card on the Now screen draws (Figma `7:654`).
///
/// A projection of `WellbeingRiskForecast` plus the user's own recent log, assembled once so
/// the card is a pure function of it. Every field is a restatement of something already
/// measured — nothing here scores, ranks or thresholds anything, and nothing here is a claim
/// about the user's body.
///
/// ## The two figures that are not the model's
///
/// `recent` and `expectedIntensity` come from the log, not from the forecast. The model was
/// trained on **whether an entry gets made**, never on how intense it will be
/// (`.claude/context/ml-spec.md` §1.1), so the card cannot ask it what a coming entry would
/// feel like. What it can do is restate the user's own trailing average back to them, which is
/// what `expectedIntensity` is: the mean of the last `projectionWindowDays` days of entries,
/// carried forward unchanged. It is a description of the recent past drawn in the forecast's
/// place, and the card has to read that way — "your recent entries have averaged 6", never
/// "you will feel a 6".
struct RiskOutlook: Hashable, Sendable {

    /// How many past entries the card draws to the left of the divider.
    ///
    /// Three, which is the design's own count. It is a glance at the recent log rather than a
    /// history — the History tab is where a user counts entries.
    static let recentCheckInCount = 3

    /// How many forecast rings the card draws to the right of the divider.
    ///
    /// Three, the design's own count and the same as `recentCheckInCount`, so the row reads as
    /// three behind and three ahead rather than three against however many the model happened
    /// to mark — which runs to eight over a four-day curve.
    ///
    /// A glance, not a census, and nothing is hidden by it: `PressureChartCard` sits directly
    /// below and draws **every** marked stretch on its forward line.
    static let expectedChipCount = 3

    /// The trailing window `expectedIntensity` averages over.
    ///
    /// Two weeks. Short enough that a change in how the user has been feeling reaches the card
    /// within a fortnight, long enough that at this app's cadence — a few entries a week — the
    /// mean rests on more than one or two rows.
    static let projectionWindowDays = 14

    /// Below this a stretch is reported as under way rather than as a countdown.
    ///
    /// One minute, which is the smallest unit the card prints. A shorter lead formats to an
    /// empty string with minutes as the smallest allowed unit, and "in 0 min" is not a lead
    /// time.
    static let minimumLeadSeconds: TimeInterval = 60

    /// The chance that **an entry gets made** today, whole percentage points, or `nil` when
    /// today has no figure. See `WellbeingRiskForecast.checkInPercent`.
    let checkInPercent: Int?

    /// When the next marked stretch begins, or `nil` when nothing is marked.
    let lead: RiskLead?

    /// That stretch, for the card to print in clock time. `nil` alongside `lead`.
    let stretch: Range<Date>?

    /// Start of the waking day the forecast calls today — what `stretch` is dated against.
    let dayStart: Date

    /// The last `recentCheckInCount` entries, **oldest first**, so the row runs toward `now`.
    let recent: [CheckInIntensity]

    /// How many dashed rings the card draws: the next `expectedChipCount` stretches the model
    /// still points at, over every day the forward curve reaches.
    ///
    /// Stretches, not windows: two adjacent two-hour windows are one occasion, and drawing
    /// them as two rings would double-count a single four-hour band the chart draws once.
    ///
    /// Capped, not complete — see `expectedChipCount`. It is the count of rings rather than
    /// the count of marked stretches, so the card can be drawn from it without deciding
    /// anything itself.
    let expectedCount: Int

    /// What a coming entry would carry if it carried what the recent ones did — the trailing
    /// mean, rounded onto the scale. `nil` when the window holds no entries.
    ///
    /// **Not a model output.** See the type comment.
    let expectedIntensity: CheckInIntensity?

    /// The forecast leans mostly on the shipped prior rather than on this user's own history.
    let isColdStart: Bool

    /// Whether the chip row has anything in it at all.
    var hasChips: Bool { !recent.isEmpty || expectedCount > 0 }

    /// Assembles what the card draws, or `nil` when there is nothing to draw.
    ///
    /// `nil` on every absence the user cannot act on from this screen and they are deliberately
    /// indistinguishable here: no engine on this build, a forecast the model declined to make,
    /// or one with neither a percentage nor a marked stretch. The card is then absent rather
    /// than empty — an outlined box under a heading reads as a load that failed.
    ///
    /// - Parameter checkIns: the user's log up to `now`, in any order. Only the trailing
    ///   `projectionWindowDays` and the last few rows are read.
    static func make(risk: WellbeingRiskForecast?,
                     checkIns: [CheckIn],
                     asOf now: Date,
                     calendar: Calendar = .current) -> RiskOutlook? {
        guard let risk, risk.isPresentable else { return nil }

        // Re-filtered rather than trusted. The engine only ever marks windows still ahead, but
        // a forecast is a value that can outlive the instant it was built for — it is memoised
        // for `WellbeingRiskEngine.forecastCacheSeconds` — and a stretch that finished while
        // the card was on screen is not an occasion to draw a ring for.
        let ahead = risk.markedRanges.filter { $0.upperBound > now }
        let stretch = ahead.first

        // `isPresentable` is measured against the forecast's own `marked`, which can be entirely
        // behind `now` by the time the card asks. A percentage or a stretch — one of the two has
        // to survive that filter, or there is nothing on the card but a heading.
        guard risk.checkInPercent != nil || stretch != nil else { return nil }

        let past = checkIns.filter { $0.timestamp <= now }.sorted { $0.timestamp < $1.timestamp }

        return RiskOutlook(checkInPercent: risk.checkInPercent,
                           lead: stretch.map { lead(to: $0.lowerBound, asOf: now) },
                           stretch: stretch,
                           dayStart: risk.dayStart,
                           recent: past.suffix(recentCheckInCount).map(\.intensity),
                           expectedCount: min(ahead.count, expectedChipCount),
                           expectedIntensity: trailingMean(of: past, asOf: now, calendar: calendar),
                           isColdStart: risk.isColdStart)
    }

    private static func lead(to start: Date, asOf now: Date) -> RiskLead {
        let seconds = start.timeIntervalSince(now)
        return seconds >= minimumLeadSeconds ? .ahead(seconds) : .underWay
    }

    /// The mean intensity over the trailing window, rounded onto the scale.
    ///
    /// The window is taken in **calendar days** rather than as `14 × 86 400` seconds, so it
    /// stays two weeks of wall clock across a DST transition instead of sliding by an hour.
    private static func trailingMean(of past: [CheckIn],
                                     asOf now: Date,
                                     calendar: Calendar) -> CheckInIntensity? {
        let start = calendar.date(byAdding: .day, value: -projectionWindowDays, to: now)
            ?? now.addingTimeInterval(-Double(projectionWindowDays) * 24 * 3600)

        let window = past.filter { $0.timestamp >= start }
        guard let digest = ReportIntensityDigest(checkIns: window) else { return nil }

        return CheckInIntensity(clamping: Int(digest.mean.rounded()))
    }
}
