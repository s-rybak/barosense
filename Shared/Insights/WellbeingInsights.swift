import Foundation

/// The user's own history, restated: what lines up with what, what they wrote down most, and
/// how the last week looked.
///
/// **Counting and one correlation. No model output of its own.** The forecast on the Insights
/// screen comes from `WellbeingRiskEngine` and is passed in beside this rather than computed
/// here — one risk model, one place it is fitted. What this type adds is the part of the screen
/// that is arithmetic over rows the user produced, which is why it is buildable in a plain unit
/// test with synthetic input and holds no store, no clock and no view.
///
/// Every field is independently absent. A log with three check-ins has tags and a trace and no
/// link and no pattern, and the screen draws exactly the cards it has — an empty card under a
/// title reads as a load that failed, which is the rule `RiskOutlookCard` already states.
struct WellbeingInsights: Hashable, Sendable {

    /// How pressure has lined up with the scale, or `nil` while there is too little to look at.
    let link: PressureWellbeingLink?

    /// One point per day of the trailing week, gaps included — what the sparkline draws.
    ///
    /// `ReportTracePoint` rather than a type of its own: the report already resolved "a day of
    /// mean pressure beside that day's worst check-in" and a second spelling of it would be a
    /// second thing to keep in step.
    let trace: [ReportTracePoint]

    /// Most-used first, names already resolved. `ReportBuilder.tagCounts` decides the order.
    let tags: [ReportTagCount]

    /// Check-ins in the analysis window — what the tag counts are out of.
    let checkInCount: Int

    /// The one sentence the app is prepared to say about the pattern, or `nil` when the log
    /// does not support one.
    let pattern: WellbeingPatternNote?

    static let empty = WellbeingInsights(link: nil,
                                         trace: [],
                                         tags: [],
                                         checkInCount: 0,
                                         pattern: nil)
}

/// The pattern card's claim, in parts.
///
/// ## What it is allowed to say
///
/// The same association `PressureWellbeingLink` reports, expressed as a hit rate over the
/// user's own recent weather instead of as a coefficient — and gated on that link existing, so
/// the two cards on the screen cannot disagree about which way the pattern runs or how long it
/// takes. Both halves are the user's history read back: `episodeCount` is a count of weather,
/// `matchedEpisodes` is a count of their own entries.
///
/// ## Why zero is reported
///
/// `matchedEpisodes == 0` produces a note like any other, and the card words it as a miss.
/// Suppressing it — which this type used to do — left the reader seeing only the favourable
/// tail of their own history: the lag being counted against is already the best of
/// `PressureWellbeingLink.lagHoursSearched` on this same log, so the rate is optimistic by
/// construction, and hiding the low end on top of that turns a screening figure into a
/// guaranteed finding. A card that can only ever agree with itself is not evidence.
///
/// ## What it is not allowed to say
///
/// Not a forecast, not a mechanism, and never a threshold in absolute hectopascals. The log
/// holds raw **station** pressure — a claim like "below 1005 hPa" is a claim about the user's
/// altitude as much as about the weather, and it would read differently in Kyiv than at the
/// coast for reasons that have nothing to do with how anybody feels (`ml-spec.md` §3). The
/// episode is a *change*, which is the least altitude-exposed thing the log offers.
struct WellbeingPatternNote: Hashable, Sendable {

    /// What the matching check-ins were most often tagged with, or `nil` when they carried no
    /// tag the vocabulary can still name.
    ///
    /// Carried as a `ReportTagRef` so the drawing side can decide between a shipped name that
    /// needs translating and the user's own words — see that type. A tag the vocabulary cannot
    /// resolve is left out rather than drawn blank.
    let tag: ReportTagRef?

    /// Hours after the pressure move, from `PressureWellbeingLink.lagHours`.
    let lagHours: Int

    /// Whether the moves counted were falls. `false` means this user's log lines up with rises.
    let isFallLeading: Bool

    /// Episodes with a check-in at or above `WellbeingLabel.poorWellbeingThreshold` inside the
    /// match window. May be zero — see the note above.
    let matchedEpisodes: Int

    /// Episodes examined — the most recent `maximumEpisodes` at most.
    let episodeCount: Int

    /// The hit rate, 0–1, for the card's footnote.
    ///
    /// A fraction rather than whole points, so the drawing side formats it in the reader's own
    /// locale instead of this type deciding what a percent sign looks like. Never a percentage
    /// of nothing: `episodeCount` is gated at `minimumEpisodes` before this type exists.
    ///
    /// **Optimistic.** The lag it is counted at was picked as the largest |*r*| over seven
    /// candidates on this same log (`ml-spec.md` §2.1), so this figure is a screening number
    /// like the coefficient beside it, not an out-of-sample rate.
    var matchRate: Double {
        guard episodeCount > 0 else { return 0 }

        return Double(matchedEpisodes) / Double(episodeCount)
    }

    /// Whether the sentence is allowed the word "usually".
    ///
    /// Zero matches is a different claim from a weak one, and the card has separate copy for
    /// it: "a harder stretch usually follows" over a footnote reading 0 % would be the two
    /// halves of one card contradicting each other.
    var isMatched: Bool { matchedEpisodes > 0 }
}

extension WellbeingInsights {

    /// How far back the link, the pattern and the tag counts are taken over.
    ///
    /// 120 days — `WellbeingRiskTrainer.trainingWindowDays`, deliberately the same stretch the
    /// model is fitted on. Two surfaces describing "your history" over two different windows is
    /// how a user ends up with a card that disagrees with the chart above it.
    static let analysisWindowDays = 120

    /// Days the sparkline draws. A week, which is what the design's axis label names.
    static let traceDays = 7

    /// The half-open window everything but the trace is taken over.
    static func analysisWindow(endingAt now: Date) -> Range<Date> {
        now.addingTimeInterval(-Double(analysisWindowDays) * 24 * 3600)..<now
    }

    /// The half-open window the sparkline covers: `traceDays` whole days ending with today.
    ///
    /// Whole days in the caller's calendar, ending at the start of tomorrow, so the last column
    /// is today and a reload an hour later draws the same seven columns.
    static func traceWindow(endingAt now: Date, calendar: Calendar) -> Range<Date> {
        let startOfToday = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: startOfToday) ?? now
        let start = calendar.date(byAdding: .day, value: -(traceDays - 1), to: startOfToday)
            ?? startOfToday

        return start..<end
    }

    /// Everything the screen's three history cards draw.
    ///
    /// `checkIns` and `samples` are the analysis window; the trace is sliced out of them here
    /// rather than read separately, so one pass over the stores serves the whole screen.
    static func make(checkIns: [CheckIn],
                     samples: [PressureSample],
                     tagsByID: [WellbeingTag.ID: WellbeingTag],
                     calendar: Calendar,
                     asOf now: Date) -> WellbeingInsights {
        // Gridded once and used twice. The link searches it for a coefficient and the note walks
        // it for episodes; building it per consumer meant hashing four months of samples twice
        // on the main actor for two identical answers.
        let cells = PressureWellbeingLink.hourlyCells(from: samples, asOf: now)
        let link = PressureWellbeingLink.make(checkIns: checkIns, cells: cells)
        let window = traceWindow(endingAt: now, calendar: calendar)

        return WellbeingInsights(
            link: link,
            trace: ReportBuilder.trace(window: window,
                                       checkIns: checkIns.filter { window.contains($0.timestamp) },
                                       pressureSamples: samples.filter { window.contains($0.timestamp) },
                                       calendar: calendar),
            tags: ReportBuilder.tagCounts(in: checkIns, tagsByID: tagsByID),
            checkInCount: checkIns.count,
            pattern: WellbeingPatternNote.make(link: link,
                                               checkIns: checkIns,
                                               cells: cells,
                                               tagsByID: tagsByID)
        )
    }
}

extension WellbeingPatternNote {

    /// Most recent episodes the hit rate is taken over. Ten, which is what a footnote can say
    /// without a reader having to hold a fraction in their head.
    static let maximumEpisodes = 10

    /// Fewest episodes that will produce a note at all.
    ///
    /// Five. Below it the card is absent rather than printing "2 of 3 · 67%", which is a
    /// percentage of nothing dressed as a finding — the same refusal `ScoredRiskWindow.percent`
    /// makes at the other end of the scale.
    static let minimumEpisodes = 5

    /// How far either side of the expected moment a check-in still counts as matching.
    ///
    /// Three hours, which is the spacing of `PressureWellbeingLink.lagHoursSearched`: a tighter
    /// window would be finer than the lag it is measured against, and a wider one would start
    /// matching a check-in to whichever episode it is nearest rather than to the one it
    /// followed.
    static let matchToleranceHours = 3

    /// The note, or `nil` when the link or the weather will not support one.
    ///
    /// Gated on `link` on purpose: the lag and the direction both come from it, and a note
    /// invented without one would be a second, unreconciled answer to the question the card
    /// above it already asked.
    ///
    /// `cells` is the Insights window already gridded — `PressureWellbeingLink.hourlyCells`.
    /// Taken rather than built so the screen grids its samples once.
    ///
    /// A note with `matchedEpisodes == 0` is a note, not a `nil`. See the type's own comment.
    static func make(link: PressureWellbeingLink?,
                     checkIns: [CheckIn],
                     cells: [HourlyPressureGrid.Cell],
                     tagsByID: [WellbeingTag.ID: WellbeingTag]) -> WellbeingPatternNote? {
        guard let link else { return nil }

        let onsets = episodeOnsets(in: cells, isFall: link.isFallLeading)
            .suffix(maximumEpisodes)
        guard onsets.count >= minimumEpisodes else { return nil }

        let events = checkIns.filter(\.isPoorWellbeing)
        let tolerance = Double(matchToleranceHours) * 3600

        var matched = 0
        var matching: [CheckIn] = []
        // One entry counts once however many onsets it sits near. Two fronts three hours apart
        // put the same evening inside both match windows, and letting it be counted twice would
        // weight whatever it was tagged with by an accident of the weather.
        var counted: Set<CheckIn.ID> = []

        for onset in onsets {
            let expected = onset.addingTimeInterval(Double(link.lagHours) * 3600)
            let hits = events.filter {
                abs($0.timestamp.timeIntervalSince(expected)) <= tolerance
            }

            guard !hits.isEmpty else { continue }
            matched += 1
            matching += hits.filter { counted.insert($0.id).inserted }
        }

        return WellbeingPatternNote(tag: ReportBuilder.tagCounts(in: matching, tagsByID: tagsByID).first?.tag,
                                    lagHours: link.lagHours,
                                    isFallLeading: link.isFallLeading,
                                    matchedEpisodes: matched,
                                    episodeCount: onsets.count)
    }

    /// The first hour of each maximal run of hours whose trailing six-hour change is a move in
    /// `isFall`'s direction, ascending.
    ///
    /// One onset per weather system rather than one per hour: a front takes most of a day to go
    /// through, and counting each of its hours as an episode would put ten "episodes" inside
    /// one afternoon and report a hit rate over a single event.
    private static func episodeOnsets(in cells: [HourlyPressureGrid.Cell],
                                      isFall: Bool) -> [Date] {
        let byHour = Dictionary(cells.map { ($0.hour, $0.hectopascals) },
                                uniquingKeysWith: { first, _ in first })
        let span = Double(PressureWellbeingLink.changeWindowHours) * 3600

        var onsets: [Date] = []
        var wasMoving = false

        for cell in cells {
            guard let earlier = byHour[cell.hour.addingTimeInterval(-span)] else {
                // No six hours behind this cell, so nothing can be said about it — and it must
                // not close a run either, or a hole would split one system into two episodes.
                continue
            }

            let change = cell.hectopascals - earlier
            let isMoving = isFall
                ? change <= -PressureTrend.significantChangeHPa
                : change >= PressureTrend.significantChangeHPa

            if isMoving, !wasMoving { onsets.append(cell.hour) }
            wasMoving = isMoving
        }

        return onsets
    }
}
