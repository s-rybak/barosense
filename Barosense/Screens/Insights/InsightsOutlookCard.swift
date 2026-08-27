import SwiftUI

/// The 1–3 day outlook on the Insights screen (Figma `7:994`).
///
/// One tile per day the forward curve reaches and the model could score, graded by the two
/// stages' own decision points — `RiskOutlookDay.level` and `WellbeingRiskModel.level` hold the
/// reasoning. The window stage's ranking score is what decides the band, which is why the card
/// can only exist for days that still have a window ahead of them.
///
/// ## Three deliberate departures from the design
///
/// 1. **No fixed three tiles.** The design draws Today / Tomorrow / a weekday. The forward curve
///    reaches four days at its widest and rather fewer with no WeatherKit grant, and every day
///    is gated on its own coverage — so the card draws what the model actually scored, up to
///    `maximumTiles`, and is left out entirely when that is nothing. Padding it to three with
///    grey placeholders would be inventing two days.
/// 2. **A state, never a number.** `RiskOutlookDay.percent` exists and is deliberately not
///    printed here. A percentage per tile reads as a measurement of the day; the graded state
///    is what `CLAUDE.md` asks this surface to show, and the one figure the app does print sits
///    on the chart where the windows under it are visible.
/// 3. **A note under the tiles.** The design has none. The compliance checklist requires the
///    plain-language "not medical advice" line to sit where the user sees the forecast, and
///    this card is the forecast on this screen.
///
/// Named apart from the Now screen's `RiskOutlookCard`: that one is the chip-row forecast
/// (Figma `7:654`); this is the 1–3 day tile row. Same model, two surfaces, two types.
struct InsightsOutlookCard: View {

    let risk: WellbeingRiskForecast

    /// The app's language, not `Locale.current` — see `LanguageController.locale`.
    @Environment(\.locale) private var locale

    /// Day boundaries in the user's own calendar, so "tomorrow" means what the phone means.
    @Environment(\.calendar) private var calendar

    /// Widest the row goes. Three, as the design draws it: a fourth tile at this width leaves
    /// each one too narrow for "Moderate" to fit at an accessibility type size.
    private static let maximumTiles = 3

    private var days: [RiskOutlookDay] { Array(risk.outlook.prefix(Self.maximumTiles)) }

    var body: some View {
        InsightsCard(spacing: 12) {
            Text("1–3 day risk outlook")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(alignment: .top, spacing: 10) {
                ForEach(days) { day in
                    tile(for: day)
                }
            }
            .frame(maxWidth: .infinity)

            // Cold start is stated rather than implied by a paler tile, for the reason
            // the Now screen's `RiskOutlookCard` states it: through the first weeks these
            // bands are mostly the shipped prior speaking, and a grade that does not say so
            // reads as a measurement of this user.
            if risk.isColdStart {
                Text("Still learning your pattern — these are general estimates")
                    .font(Typography.insightCaption)
                    .foregroundStyle(Palette.placeholder)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("A graded state from your own history, not medical advice.")
                .font(Typography.insightCaption)
                .foregroundStyle(Palette.placeholder)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Tile

    private func tile(for day: RiskOutlookDay) -> some View {
        VStack(spacing: 4) {
            dayName(of: day)
                .font(Typography.captionEmphasis)
                .foregroundStyle(day.level.textColour)

            // 10 pt as the design draws it, and fixed rather than scaled with type: it is a
            // second channel on a state the tile also prints in words, and a dot that grows
            // with Dynamic Type crowds out the word that is doing the actual work.
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(day.level.dotColour)
                .frame(width: 10, height: 10)

            Text(day.level.label)
                .font(Typography.riskLevelLabel)
                .foregroundStyle(day.level.textColour)
                .multilineTextAlignment(.center)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(day.level.fillColour)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel(for: day))
    }

    /// "Today", "Tomorrow", or the weekday's short name.
    ///
    /// Named relatively for the two days a reader does not have to translate, and by weekday
    /// after that. A date would be exact and unreadable at this size; "in 3 days" would make
    /// the reader do the arithmetic the tile is meant to save them.
    private func dayName(of day: RiskOutlookDay) -> Text {
        // The waking day starts at the user's own wake hour, which is not midnight — so the
        // comparison is against the *calendar* day the window falls in, not against `dayStart`
        // arithmetic. A window at 07:00 belongs to today whatever hour the model calls the
        // day's beginning.
        let reference = day.window.lowerBound

        if calendar.isDateInToday(reference) { return Text("Today") }
        if calendar.isDateInTomorrow(reference) { return Text("Tomorrow") }

        // Capitalised through the locale, because several of them do not capitalise a weekday
        // on its own — Ukrainian renders "пт", which reads as a typo beside "Завтра" and is not
        // what the design draws. `capitalized(with:)` rather than `.uppercased()`: the tile
        // names a day, and shouting it would make it the loudest thing on the card.
        let name = reference.formatted(
            Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale)
        )
        return Text(verbatim: name.capitalized(with: locale))
    }

    /// The tile in one sentence, with the stretch it was read off.
    ///
    /// The stretch is spoken and not drawn: there is no room for it on a tile this wide, and a
    /// reader using VoiceOver has no chart beside them to find it on.
    private func accessibilityLabel(for day: RiskOutlookDay) -> Text {
        let time = Date.FormatStyle.dateTime.hour().minute().locale(locale)
        let stretch = "\(day.window.lowerBound.formatted(time))–\(day.window.upperBound.formatted(time))"

        return Text("\(dayName(of: day)): \(Text(day.level.label)), usually around \(stretch)")
    }
}

// MARK: - Level

/// How a graded state is drawn and named.
///
/// In the app target rather than beside `RiskLevel` in `Shared/`, for the reason
/// `HistoryPeriod.label` is: `Shared/` is UI-free, the domain owns the band and the design
/// system owns what it looks like.
extension RiskLevel {

    var label: LocalizedStringKey {
        switch self {
        case .low: "Low"
        case .moderate: "Moderate"
        case .high: "High"
        }
    }

    var fillColour: Color {
        switch self {
        case .low: Palette.riskLowFill
        case .moderate: Palette.riskModerateFill
        case .high: Palette.riskHighFill
        }
    }

    var textColour: Color {
        switch self {
        case .low: Palette.riskLowText
        case .moderate: Palette.riskModerateText
        case .high: Palette.riskHighText
        }
    }

    var dotColour: Color {
        switch self {
        case .low: Palette.positive
        case .moderate: Palette.markerWarm
        case .high: Palette.health
        }
    }
}

#Preview("Three days") {
    InsightsOutlookCard(risk: .previewOutlook(levels: [.moderate, .low, .high], cold: false))
        .padding(20)
        .background(Palette.surface)
}

#Preview("Cold start") {
    InsightsOutlookCard(risk: .previewOutlook(levels: [.low, .moderate], cold: true))
        .padding(20)
        .background(Palette.surface)
}

extension WellbeingRiskForecast {

    /// A forecast carrying exactly the tiles named, one day apart from the next whole hour.
    ///
    /// Built from `preview(marked:chance:cold:)` so the previews here and the ones on
    /// `RiskOutlookCard` describe the same arrangement rather than two that drift.
    static func previewOutlook(levels: [RiskLevel], cold: Bool) -> WellbeingRiskForecast {
        let base = preview(marked: [2, 3], chance: 0.62, cold: cold)
        let width = TimeInterval(RiskWindowGeometry.windowMinutes) * 60

        let outlook = levels.enumerated().map { index, level in
            let start = base.dayStart.addingTimeInterval(Double(index) * 24 * 3600 + 8 * 3600)
            return RiskOutlookDay(dayStart: base.dayStart.addingTimeInterval(Double(index) * 24 * 3600),
                                  level: level,
                                  confidence: 0.7,
                                  combined: 0.31,
                                  window: start..<start.addingTimeInterval(width))
        }

        return WellbeingRiskForecast(dayStart: base.dayStart,
                                     checkInProbability: base.checkInProbability,
                                     windows: base.windows,
                                     marked: base.marked,
                                     isDayQuiet: base.isDayQuiet,
                                     mayNotify: base.mayNotify,
                                     isColdStart: base.isColdStart,
                                     dayCoverage: base.dayCoverage,
                                     forecastShare: base.forecastShare,
                                     outlook: outlook)
    }
}
