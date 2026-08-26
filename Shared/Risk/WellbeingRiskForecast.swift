import Foundation

/// One window of the waking day, scored.
struct ScoredRiskWindow: Hashable, Sendable, Identifiable {

    var id: Date { start }

    let start: Date
    let end: Date

    /// Start of the waking day this window belongs to.
    ///
    /// Carried because the forecast spans several days now. Without it a caller cannot tell
    /// today's windows from tomorrow's, and every figure on screen that says "today" would be
    /// a maximum taken over whatever the forward curve happened to reach.
    let dayStart: Date

    /// The window stage's ranking score. Comparable with the other windows of the same day and
    /// with the gate threshold — **not** a frequency, and never rendered as a percentage.
    let confidence: Double

    /// `P(entry today) × P(this window | entry)`. The joint figure: the one quantity per window
    /// that is a probability rather than a rank, and therefore the only one a surface may print.
    let combined: Double

    /// Share of the window's hours that came from a forecast curve rather than from the log.
    /// 1.0 for anything ahead of now, 0 for a window the sensor covered end to end.
    let forecastShare: Double

    /// Whether the chart marks this window.
    let isMarked: Bool

    var contains: Range<Date> { start..<end }

    /// The joint figure as whole percentage points, or `nil` when it rounds away to nothing.
    ///
    /// `nil` is the "there is no percentage here" state, and it is the rule the surfaces are
    /// built on: a window the model scores at under half a point is a window the app has
    /// nothing to say about, and rendering it as `0%` — or marking it on the chart — would be
    /// dressing an absence up as a measurement.
    var percent: Int? {
        let rounded = Int((combined * 100).rounded())
        return rounded >= 1 ? rounded : nil
    }
}

/// What the app can say about the days the forward curve reaches, from the barometer log and
/// that curve.
///
/// ## The wording rule this type is written against
///
/// Nothing here is a statement about the user's body. `checkInProbability` is the chance that
/// **an entry gets made** — a fact about logging behaviour, which is what the model was trained
/// on and all it can speak to. It is not a chance of feeling unwell, and a surface that renders
/// it as one is a claim the data does not support and that App Review reads closely
/// (`.claude/skills/appstore_compliance/SKILL.md`).
///
/// The marked windows are a **graded state**, not an event: the model ranks the windows of each
/// day and the top two of that day are marked. On 43% of days that hold an entry the marked
/// stretch does not contain it, so any copy attached to this has to read as "your history
/// suggests", never as a forecast of what will happen.
///
/// ## Why it is no longer one day
///
/// The window stage answers "if an entry happens **that day**, when" — a question that is asked
/// per day and composes per day. Scoring only the day `now` falls in threw away every window of
/// the forward curve past midnight, which on the chart's widest button is three days of drawn
/// line with nothing said about it. Every day the curve covers well enough to score is scored;
/// the ones it does not are simply absent, which is what `checkInProbability == nil` and an
/// empty `marked` mean.
struct WellbeingRiskForecast: Hashable, Sendable {

    /// Start of the waking day `now` falls in — "today" for every figure below that names it.
    let dayStart: Date

    /// The figure the card prints, 0–1, or `nil` when today cannot be scored at all.
    ///
    /// **The highest joint probability among today's windows**, not the day stage's own output.
    /// The two answer different questions and only one of them has a window under it: the day
    /// stage says how often a day like today holds an entry, which is a number the user cannot
    /// locate anywhere on the chart, while this is the strongest thing the model will point at
    /// on the plot. A headline that is not the maximum of what is drawn beneath it is a headline
    /// that disagrees with its own chart.
    ///
    /// It is a **joint** probability and therefore always at or below the day stage's figure —
    /// `P(entry today) × P(best window | entry)`. `ScoredRiskWindow.combined` is the same
    /// quantity per window.
    ///
    /// `nil` when today has no scoreable window: before the log covers half of today and there
    /// is no forward curve to fill the rest, there is no day-level average worth the name and
    /// `RiskWindowBuilder.minimumDayCoverage` drops the day. Tomorrow may still be scoreable,
    /// which is why this is `nil` rather than the whole forecast being absent.
    let checkInProbability: Double?

    /// Every scoreable window from `dayStart` to the far end of the forward curve, ascending.
    ///
    /// Days too thinly covered to support day-level features contribute no windows at all,
    /// rather than windows carrying a confidently wrong number.
    let windows: [ScoredRiskWindow]

    /// The windows the chart marks — per day, the highest-ranked ones still ahead of `now`.
    ///
    /// **Empty for any day the day stage calls quiet.** That is the two-stage rule made
    /// visible: the window model is a *conditional* answer to "if an entry happens, when", and
    /// asking it on a day the first stage does not expect one produces a confident answer to a
    /// question nobody asked.
    let marked: [ScoredRiskWindow]

    /// Today's day-stage probability fell below `WellbeingRiskModel.dayDisplayThreshold`.
    ///
    /// True as well when today could not be scored at all — in both cases nothing of today's is
    /// marked, which is the only thing this flag is read for outside the log.
    let isDayQuiet: Bool

    /// The window stage cleared `gateThreshold` on today's best remaining window.
    ///
    /// The permission to interrupt, and nothing else — the chart ignores it. False on roughly
    /// two days in three by design; that is what keeps the messages that do arrive worth
    /// reading. Scoped to today deliberately: a notification about the day after tomorrow is
    /// not an advance warning, it is a thing to forget before it arrives.
    ///
    /// **No consumer yet.** Scheduling the notification is a separate change with its own
    /// permission prompt and its own copy review; this is the decision that change will read,
    /// measured and validated ahead of it rather than invented alongside it.
    let mayNotify: Bool

    /// The forecast leans mostly on the shipped prior rather than on this user's own history.
    let isColdStart: Bool

    /// Fraction of **today's** windows that had any pressure data at all.
    let dayCoverage: Double

    /// Fraction of **today's** windows filled from a forecast curve rather than the log.
    ///
    /// Not decoration. Early in the morning this is near 1 and the whole forecast rests on
    /// WeatherKit or the local model being right about the day; by evening it is near 0 and it
    /// rests on measurements. The same number under both would hide which of the two the app
    /// is standing on.
    let forecastShare: Double

    /// Today's windows, which is what every figure naming "today" is taken over.
    var todayWindows: [ScoredRiskWindow] { windows.filter { $0.dayStart == dayStart } }

    /// The marked windows merged into contiguous stretches — what the chart draws.
    ///
    /// Two adjacent two-hour windows are one four-hour stretch, not two stripes with an
    /// invisible seam between them. Windows from different days never merge: the night the
    /// domain excludes sits between them.
    var markedRanges: [Range<Date>] {
        let ordered = marked.map(\.contains).sorted { $0.lowerBound < $1.lowerBound }
        var merged: [Range<Date>] = []

        for range in ordered {
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound..<max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// The percentage the card prints, rounded to whole points, or `nil` when there is none.
    ///
    /// `nil` covers both absences and they are drawn the same way — the line is not there. A
    /// today that could not be scored and a today whose best window rounds to under a point are
    /// different facts about the model and the same fact about the screen.
    var checkInPercent: Int? {
        guard let checkInProbability else { return nil }

        let rounded = Int((checkInProbability * 100).rounded())
        return rounded >= 1 ? rounded : nil
    }

    /// Whether any surface has something to draw from this.
    ///
    /// A forecast with no percentage and nothing marked is a forecast the model declined to
    /// make. The row is then absent rather than empty — see `RiskSummaryRow`.
    var isPresentable: Bool { checkInPercent != nil || !marked.isEmpty }
}

/// A window with both stages' output on it, while its day is being ranked.
///
/// Never leaves this file: what a caller gets is `ScoredRiskWindow`, which also carries the
/// mark and the day it belongs to.
private struct RankedWindow {

    let row: RiskWindowRow

    /// The window stage's rank within its day.
    let confidence: Double

    /// `P(entry that day) × confidence`.
    let combined: Double
}

extension WellbeingRiskModel {

    /// Scores whatever days `rows` covers.
    ///
    /// `rows` are the windows of one or more waking days, ascending or not, built by the caller
    /// from the geometry this model was fitted with. The **earliest** day is taken to be today,
    /// which is what the engine builds: from the waking day containing `now` out to the far end
    /// of the forward curve.
    ///
    /// Each day is gated on its own coverage. A day the log or the curve touched for two hours
    /// produces a "day average" of two hours, and reporting a percentage off that would be the
    /// confidently-wrong value the registry rules out — so that day contributes no windows and
    /// nothing about it reaches a screen. `nil` when no day survives that gate.
    func forecast(for rows: [RiskWindowRow], asOf now: Date) -> WellbeingRiskForecast? {
        guard let today = rows.map(\.dayStart).min() else { return nil }

        let byDay = Dictionary(grouping: rows, by: \.dayStart)

        var scored: [ScoredRiskWindow] = []
        var todayChance: Double?
        var todayQuiet = true
        var todayCoverage: Double = 0
        var todayForecastShare: Double = 0
        var todayBestAhead: Double = 0

        for day in byDay.keys.sorted() {
            let dayRows = (byDay[day] ?? []).sorted { $0.start < $1.start }
            guard let first = dayRows.first,
                  first.dayCoverage >= RiskWindowBuilder.minimumDayCoverage
            else { continue }

            let dayChance = dayProbability(for: first)
            let isQuiet = dayChance < Self.dayDisplayThreshold

            let entries = dayRows.map { row -> RankedWindow in
                let confidence = windowConfidence(for: row)
                return RankedWindow(row: row,
                                    confidence: confidence,
                                    combined: dayChance * confidence)
            }

            // Only windows that have not finished are eligible for a mark. A red stripe over ten
            // this morning is not a forecast, and the chart draws the day either side of `now`.
            //
            // A window whose joint figure rounds to nothing is not eligible either, whatever its
            // rank: ranking always produces a best window, and marking one the model puts under
            // half a percentage point would be the chart claiming a stretch the row cannot put a
            // number on.
            let ahead = entries.filter { $0.row.end > now }
            let markedStarts: Set<Date> = isQuiet ? [] : Set(
                ahead.filter { Self.isPrintable($0.combined) }
                    .sorted { $0.confidence > $1.confidence }
                    .prefix(Self.markedWindowCount)
                    .map(\.row.start)
            )

            let dayWindows = entries.map { entry in
                ScoredRiskWindow(start: entry.row.start,
                                 end: entry.row.end,
                                 dayStart: day,
                                 confidence: entry.confidence,
                                 combined: entry.combined,
                                 forecastShare: entry.row.forecastShare,
                                 isMarked: markedStarts.contains(entry.row.start))
            }
            scored += dayWindows

            guard day == today else { continue }

            // Today's figures, taken over today's windows and nothing else. The headline is the
            // strongest window rather than the day stage's own number — see
            // `WellbeingRiskForecast.checkInProbability`.
            todayChance = dayWindows.map(\.combined).max()
            todayQuiet = isQuiet
            todayCoverage = first.dayCoverage
            todayForecastShare = dayRows.map(\.forecastShare).reduce(0, +) / Double(dayRows.count)
            todayBestAhead = ahead.map(\.confidence).max() ?? 0
        }

        guard !scored.isEmpty else { return nil }

        let windows = scored.sorted { $0.start < $1.start }

        return WellbeingRiskForecast(
            dayStart: today,
            checkInProbability: todayChance,
            windows: windows,
            marked: windows.filter(\.isMarked),
            isDayQuiet: todayQuiet,
            // Both stages have to agree before the app interrupts: the day stage that today is
            // not quiet, the window stage that it knows which stretch. Either one alone was
            // measured and either one alone is worse.
            mayNotify: !todayQuiet && todayBestAhead >= gateThreshold,
            isColdStart: isColdStart,
            dayCoverage: todayCoverage,
            forecastShare: todayForecastShare
        )
    }

    /// Whether a joint probability survives rounding to whole percentage points.
    ///
    /// One place, so the gate the chart marks on and the figure the row prints cannot disagree
    /// about whether there is anything to say. See `ScoredRiskWindow.percent`.
    static func isPrintable(_ probability: Double) -> Bool {
        Int((probability * 100).rounded()) >= 1
    }
}
