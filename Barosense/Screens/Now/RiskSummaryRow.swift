import SwiftUI

/// What the model says about today: a chance of a check-in, and — when both stages agree there
/// is something to name — the next stretch the plot has marked.
///
/// ## The wording, which is the constrained part
///
/// The figure is the chance that **an entry gets made**, which is what the model was trained
/// on. It is not a chance of feeling unwell, and the copy says so by naming the entry rather
/// than the person: "Check-in likely today", not "a harder day ahead". The stretch is
/// introduced with "usually" for the same reason — the model is reporting this user's own
/// pattern back to them, and on 40% of days that hold an entry the marked stretch does not
/// contain it (`.claude/skills/appstore_compliance/SKILL.md`).
///
/// ## Every line is optional, and the row is never a placeholder
///
/// The percentage is absent when today has none — too thinly covered to score, or a best window
/// under half a point — and the stretch is absent whenever nothing is marked. A row with all
/// three lines gone renders as an empty box under a title, which reads as a load that failed;
/// the card checks `WellbeingRiskForecast.isPresentable` and leaves it out entirely instead.
///
/// Its own type, and its own file, for two reasons: `PressureChartCard`'s preview host renders
/// the real row rather than a copy of it that can drift, and a test can render it to a bitmap
/// without reaching into the card.
struct RiskSummaryRow: View {

    let risk: WellbeingRiskForecast

    /// The app's language, which is not `Locale.current` — that one is still whatever the app
    /// launched in. See `LanguageController.locale`.
    @Environment(\.locale) private var locale

    /// Day boundaries are taken in the user's own calendar, so "not today" means what the phone
    /// means by it.
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            // Absent rather than zero when the model has no figure for today. The forecast can
            // still name a stretch tomorrow, which is why this line and the next are decided
            // separately.
            if let percent = risk.checkInPercent {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("Check-in likely today")
                        .font(Typography.captionEmphasis)
                        .foregroundStyle(Palette.inkSubtle)

                    Text(verbatim: "\(percent)%")
                        .font(Typography.captionEmphasis)
                        .foregroundStyle(Palette.heading)
                        .monospacedDigit()

                    Spacer(minLength: 0)
                }
            }

            if let stretch = markedStretchText {
                Text(stretch)
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.markerWarm)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Cold start is stated, not implied by a smaller number. §4 of the ML spec: through
            // the first weeks the figure is mostly the shipped prior speaking, and a percentage
            // that does not say so reads as a measurement of this user.
            if risk.isColdStart {
                Text("Still learning your pattern — this is a general estimate")
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.inkSubtle)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The next marked stretch in words, or `nil` when nothing is marked.
    ///
    /// Adjacent windows have already been merged into one stretch by
    /// `WellbeingRiskForecast.markedRanges`, and the marked set holds only windows still ahead,
    /// so the first is the next one. `nil` on a quiet day, which is the day stage refusing to
    /// hand the question on — not a formatting failure.
    ///
    /// A stretch on a later day is named with its weekday. The forecast reaches four days out
    /// now, and "Usually around 14:00–18:00" printed on Monday about Wednesday is not a smaller
    /// claim than the true one — it is a different and wrong one.
    private var markedStretchText: LocalizedStringKey? {
        guard let stretch = risk.markedRanges.first else { return nil }

        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let end = stretch.upperBound.formatted(time)

        guard calendar.isDate(stretch.lowerBound, inSameDayAs: risk.dayStart) else {
            let dayAndTime = Date.FormatStyle.dateTime
                .weekday(.abbreviated).hour().minute().locale(locale)
            return "Usually around \(stretch.lowerBound.formatted(dayAndTime))–\(end)"
        }
        return "Usually around \(stretch.lowerBound.formatted(time))–\(end)"
    }
}

#Preview("Marked stretch") {
    RiskSummaryRow(risk: .previewMarked)
        .padding(17)
        .background(Palette.cardSurface)
}

#Preview("Quiet day, cold start") {
    RiskSummaryRow(risk: .previewQuiet)
        .padding(17)
        .background(Palette.cardSurface)
}

extension WellbeingRiskForecast {

    /// A day the model has something to say about: two adjacent windows marked.
    static var previewMarked: WellbeingRiskForecast { .preview(marked: [2, 3], chance: 0.78, cold: false) }

    /// A quiet day in the first weeks. Nothing marked, and the cold-start note showing.
    static var previewQuiet: WellbeingRiskForecast { .preview(marked: [], chance: 0.31, cold: true) }

    /// Nine two-hour windows from the next whole hour, with `marked` named.
    ///
    /// Shared by this file's previews, `PressureChartCard`'s and the rendering test, so all
    /// three look at one arrangement rather than three that drift.
    ///
    /// `chance` is the **day stage's** figure, as the model produces it; what the row prints is
    /// the strongest window's joint probability, which this derives the same way the model does.
    static func preview(marked: Set<Int>,
                        chance: Double,
                        cold: Bool,
                        asOf now: Date = .now) -> WellbeingRiskForecast {
        let width = TimeInterval(RiskWindowGeometry.windowMinutes) * 60
        let dayStart = RiskPressureGrid.alignedHour(of: now)

        let windows = (0..<9).map { index in
            ScoredRiskWindow(start: dayStart.addingTimeInterval(Double(index) * width),
                             end: dayStart.addingTimeInterval(Double(index + 1) * width),
                             dayStart: dayStart,
                             confidence: marked.contains(index) ? 0.9 : 0.2,
                             combined: chance * (marked.contains(index) ? 0.9 : 0.2),
                             forecastShare: 1,
                             isMarked: marked.contains(index))
        }

        return WellbeingRiskForecast(dayStart: dayStart,
                                     checkInProbability: windows.map(\.combined).max(),
                                     windows: windows,
                                     marked: windows.filter(\.isMarked),
                                     isDayQuiet: marked.isEmpty,
                                     mayNotify: !marked.isEmpty,
                                     isColdStart: cold,
                                     dayCoverage: 1,
                                     forecastShare: 1)
    }
}
