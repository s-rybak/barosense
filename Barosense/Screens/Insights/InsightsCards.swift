import Charts
import SwiftUI

// MARK: - Chrome

/// The white card every block on the Insights screen sits in (Figma `7:970`, `7:994`, `7:1017`).
///
/// One type rather than the modifier stack repeated four times: the three light cards on this
/// screen differ only in their internal spacing, and a border that is 1 pt on two of them and
/// 1.5 on a third is the kind of drift a shared container makes impossible.
struct InsightsCard<Content: View>: View {

    var spacing: CGFloat = 10

    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            content
        }
        .padding(InsightsMetrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: InsightsMetrics.cardRadius, style: .continuous)
                .fill(Palette.cardSurface)
        }
        // `strokeBorder` so the 1 pt outline sits inside the card's box rather than straddling
        // it — the same reasoning as `PressureChartCard`.
        .overlay {
            RoundedRectangle(cornerRadius: InsightsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }
}

enum InsightsMetrics {
    static let cardRadius: CGFloat = 18
    static let cardPadding: CGFloat = 17
    static let screenInset: CGFloat = 20
    static let blockSpacing: CGFloat = 16
    /// Height of the sparkline's plot box, as the design draws it.
    static let sparklineHeight: CGFloat = 70
}

/// The small all-caps line naming what a card is about.
struct InsightsEyebrow: View {

    let title: LocalizedStringKey
    var tint: Color = Palette.inkSubtle

    var body: some View {
        Text(title)
            .font(Typography.cardEyebrow)
            .tracking(0.44)
            .textCase(.uppercase)
            .foregroundStyle(tint)
    }
}

// MARK: - Pressure × wellbeing

/// The link card (Figma `7:970`): how the barometer has lined up with this user's own scale.
///
/// ## What the card is allowed to claim
///
/// `PressureWellbeingLink` is a correlation over the user's own log with the lag chosen by
/// search, which inflates it — that type's own documentation is blunt about it. So the card
/// prints the coefficient beside the number of pairs it came from, words the lag with a `~`,
/// and words the relationship as something the history *suggests*. It never says the pressure
/// caused anything.
///
/// ## Two departures from the design
///
/// 1. **The orange series is named for what it is.** The design labels it "Самопочуття"
///    (wellbeing), and the line is the day's **peak check-in intensity**, which runs the other
///    way — 10 is the worst day, not the best. A line labelled with a scale pointing the
///    opposite way to the one it plots is a chart that misreads at a glance, so it is named
///    for the intensity it draws.
/// 2. **No figure until there is one.** Below `PressureWellbeingLink.minimumPairs` the card
///    keeps the picture — the week is the user's own data and needs no model — and replaces
///    the coefficient with a line saying the pattern is still building.
struct PressureWellbeingCard: View {

    let link: PressureWellbeingLink?
    let trace: [ReportTracePoint]

    @Environment(\.locale) private var locale

    var body: some View {
        InsightsCard {
            HStack(alignment: .center, spacing: 12) {
                InsightsEyebrow(title: "Pressure × how you felt")

                Spacer(minLength: 0)

                if let link {
                    strengthBadge(link.strength)
                }
            }

            if let link {
                Text(verbatim: coefficientText(link))
                    .font(Typography.insightValue)
                    .tracking(-0.72)
                    .foregroundStyle(Palette.heading)
                    .monospacedDigit()
                    .accessibilityLabel(Text("Correlation \(coefficientText(link))"))

                Text(sentence(for: link))
                    .font(Typography.insightBody)
                    .lineSpacing(5)
                    .foregroundStyle(Palette.bodyText)
                    .fixedSize(horizontal: false, vertical: true)

                Text("From \(link.pairCount) check-ins with pressure behind them")
                    .font(Typography.insightLegend)
                    .foregroundStyle(Palette.placeholder)
            } else {
                Text("""
                    Keep checking in — the pattern needs about \
                    \(PressureWellbeingLink.minimumPairs) entries with pressure behind them \
                    before there is anything to report.
                    """)
                    .font(Typography.insightBody)
                    .lineSpacing(5)
                    .foregroundStyle(Palette.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            legend

            InsightsSparkline(trace: trace)
        }
    }

    /// `+0.72` — the sign is always drawn, because it carries the direction.
    private func coefficientText(_ link: PressureWellbeingLink) -> String {
        link.coefficient.formatted(
            .number.precision(.fractionLength(2)).sign(strategy: .always()).locale(locale)
        )
    }

    private func strengthBadge(_ strength: PressureWellbeingLink.Strength) -> some View {
        Text(strength.label)
            .font(Typography.cardEyebrow)
            .foregroundStyle(Palette.strengthBadgeText)
            .padding(.horizontal, 10)
            .padding(.top, 9)
            .padding(.bottom, 6)
            .background {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Palette.markerWarm.opacity(0.15))
            }
    }

    /// The relationship in words. Two sentences, because the two directions are different
    /// findings and one of them would be wrong for half the people who see it.
    private func sentence(for link: PressureWellbeingLink) -> LocalizedStringKey {
        link.isFallLeading
            ? "When pressure falls, your history suggests a higher entry about ~\(link.lagHours) h later."
            : "When pressure rises, your history suggests a higher entry about ~\(link.lagHours) h later."
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendItem(colour: Palette.chartLine, title: "Pressure")
            legendItem(colour: Palette.markerWarm, title: "Intensity")

            Spacer(minLength: 8)

            if let span = traceSpan {
                Text(verbatim: span)
                    .font(Typography.insightLegend)
                    .foregroundStyle(Palette.inkSubtle)
            }
        }
        .accessibilityHidden(true)
    }

    private func legendItem(colour: Color, title: LocalizedStringKey) -> some View {
        HStack(spacing: 6) {
            Capsule(style: .continuous)
                .fill(colour)
                .frame(width: 12, height: 2)

            Text(title)
                .font(Typography.insightLegend)
                .foregroundStyle(Palette.inkSubtle)
        }
    }

    /// "Mon → Sun", read off the trace rather than hard-coded.
    ///
    /// The design writes the week out as Пн → Нд. The trace is the seven days ending today, so
    /// the pair is whatever weekday that lands on — printing a fixed Monday would be wrong on
    /// six days out of seven.
    private var traceSpan: String? {
        guard let first = trace.first, let last = trace.last, first.day != last.day else {
            return nil
        }

        let weekday = Date.FormatStyle.dateTime.weekday(.abbreviated).locale(locale)
        return "\(first.day.formatted(weekday)) → \(last.day.formatted(weekday))"
    }
}

extension PressureWellbeingLink.Strength {

    /// In the app target rather than beside the type in `Shared/`, for the reason
    /// `RiskLevel.label` is: `Shared/` is UI-free.
    var label: LocalizedStringKey {
        switch self {
        case .weak: "Weak link"
        case .moderate: "Some link"
        case .strong: "Strong link"
        }
    }
}

// MARK: - Sparkline

/// The two-series plot at the foot of the link card (Figma `7:980`).
///
/// ## Why both series are normalised
///
/// They share one Y axis and are measured in different things — hectopascals near 1 000 and a
/// 1–10 scale. Swift Charts has no second axis, and plotting them raw would draw the intensity
/// as a flat line at the bottom of a 40 hPa range. Each is scaled onto 0–1 across the week the
/// card is drawing, which is also why the plot carries **no axis labels**: the shapes are
/// comparable, the heights are not, and a tick mark would invite reading a value off it.
///
/// Days with nothing recorded are holes rather than joins. A line drawn straight through a day
/// the phone was asleep claims coverage that does not exist — the rule `ReportBuilder.trace`
/// already states, kept here by plotting `nil` and letting the mark break.
///
/// Interpolation is **linear** for the same reason it is not smoothed anywhere else in this
/// app: a spline through seven daily means draws curvature between two points that nothing
/// measured, and at this size that invented shape is most of what the reader sees.
struct InsightsSparkline: View {

    let trace: [ReportTracePoint]

    var body: some View {
        Chart {
            ForEach(trace) { point in
                if let pressure = normalisedPressure(point) {
                    LineMark(x: .value("Day", point.day),
                             y: .value("Pressure", pressure),
                             series: .value("Series", "pressure"))
                        .foregroundStyle(Palette.chartLine)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.linear)
                }

                if let intensity = point.peakIntensity {
                    LineMark(x: .value("Day", point.day),
                             y: .value("Intensity", intensity.normalized),
                             series: .value("Series", "intensity"))
                        .foregroundStyle(Palette.markerWarm)
                        .lineStyle(StrokeStyle(lineWidth: 2,
                                               lineCap: .round,
                                               lineJoin: .round,
                                               dash: [3, 3]))
                        .interpolationMethod(.linear)
                }
            }
        }
        // Padded off both ends, so a series that touches its own extreme is a line and not a
        // stroke clipped in half against the edge of the box.
        .chartYScale(domain: -0.1...1.1)
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartLegend(.hidden)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(height: InsightsMetrics.sparklineHeight)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Palette.surface)
        }
        .accessibilityElement()
        .accessibilityLabel(Text("Pressure and check-in intensity over the last \(trace.count) days"))
    }

    /// Pressure scaled onto 0–1 across the week, or `nil` for a day with no reading.
    ///
    /// A week with one single reading, or a dead-flat one, has no range to scale against: those
    /// days are drawn at the middle rather than at zero, so a flat week reads as flat instead
    /// of as a week spent at the bottom of the chart.
    private func normalisedPressure(_ point: ReportTracePoint) -> Double? {
        guard let value = point.meanPressureHPa else { return nil }

        let values = trace.compactMap(\.meanPressureHPa)
        guard let lowest = values.min(), let highest = values.max() else { return nil }
        guard highest > lowest else { return 0.5 }

        return (value - lowest) / (highest - lowest)
    }
}

// MARK: - Tags

/// What the user has written down most (Figma `7:1017`).
///
/// **Titled "Most-used tags", not "Top symptoms" as the design does.** `symptom` is on the
/// forbidden list in `.claude/skills/appstore_compliance/SKILL.md` and is caught by
/// `scripts/ci/check-copy-vocabulary.sh`; the tag vocabulary is user-owned free text and
/// calling it a list of symptoms is the app asserting what those words mean.
///
/// Counting and nothing else. No tag is related to the pressure here — that claim, where the
/// app makes it at all, is made once, on the link card, with the pair count beside it.
struct TopTagsCard: View {

    let tags: [ReportTagCount]
    let checkInCount: Int
    let tagsByID: [WellbeingTag.ID: WellbeingTag]

    /// Rows the design draws. A fourth would push the card past the fold on the smallest
    /// phone, and the tail of a tag list is where the one-offs live.
    private static let rowCount = 3

    var body: some View {
        InsightsCard {
            HStack(alignment: .center, spacing: 12) {
                Text("Most-used tags")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.heading)

                Spacer(minLength: 0)

                Text("\(checkInCount) entries")
                    .font(Typography.insightCaption)
                    .foregroundStyle(Palette.inkSubtle)
            }

            ForEach(tags.prefix(Self.rowCount)) { entry in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    // The vocabulary rather than the count's copied name: a seeded tag the user
                    // never renamed is app copy and has to be looked up in the reader's own
                    // language. See `WellbeingTag.label`.
                    (tagsByID[entry.id]?.label ?? Text(verbatim: entry.tag.name))
                        .font(Typography.insightBody)
                        .foregroundStyle(Palette.heading)

                    Spacer(minLength: 8)

                    Text("\(entry.count)×")
                        .font(Typography.insightRowValue)
                        .foregroundStyle(Palette.bodyText)
                        .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

// MARK: - Pattern

/// The dark card at the foot of the screen (Figma `7:1038`).
///
/// Restates the link card's finding as a hit rate over the user's own recent weather —
/// `WellbeingPatternNote` holds the reasoning, including why the episode is a *change* and
/// never an absolute hectopascal threshold the way the design's placeholder copy has it.
///
/// Absent, not empty, whenever the note is `nil`. A dark card is the loudest thing on the
/// screen and it has to have earned its place.
struct PatternNoteCard: View {

    let note: WellbeingPatternNote
    let tagsByID: [WellbeingTag.ID: WellbeingTag]

    @Environment(\.locale) private var locale

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Palette.markerCool.opacity(0.25))
                        .frame(width: 26, height: 26)

                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(Palette.markOnInk)
                        .frame(width: 8, height: 8)
                }

                InsightsEyebrow(title: "Pattern in your history", tint: Palette.bodyTextOnInk)
            }

            headline
                .font(Typography.cardTitle)
                .lineSpacing(6)
                .foregroundStyle(Palette.onInk)
                .fixedSize(horizontal: false, vertical: true)

            footnote
                .font(Typography.insightCaption)
                .foregroundStyle(Palette.bodyTextOnInk)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: InsightsMetrics.cardRadius, style: .continuous)
                .fill(Palette.ink)
        }
        .accessibilityElement(children: .combine)
    }

    /// Four wordings: a fall or a rise, with or without a tag to name.
    ///
    /// Written out rather than assembled from fragments. A sentence built by concatenation
    /// cannot be translated — Ukrainian declines the tag name after "після", and a translator
    /// handed three separate pieces has no way to make the joins agree.
    private var headline: Text {
        guard let tag = note.tag, let named = tagsByID[tag.id]?.label else {
            return note.isFallLeading
                ? Text("""
                    Your history suggests a harder stretch usually follows a falling \
                    barometer by about ~\(note.lagHours) h.
                    """)
                : Text("""
                    Your history suggests a harder stretch usually follows a rising \
                    barometer by about ~\(note.lagHours) h.
                    """)
        }

        return note.isFallLeading
            ? Text("""
                Your history suggests \(named) usually turns up about ~\(note.lagHours) h \
                after the barometer starts falling.
                """)
            : Text("""
                Your history suggests \(named) usually turns up about ~\(note.lagHours) h \
                after the barometer starts rising.
                """)
    }

    /// What the sentence rests on, in the reader's own locale.
    private var footnote: Text {
        let rate = note.matchRate.formatted(
            .percent.precision(.fractionLength(0)).locale(locale)
        )

        return note.isFallLeading
            ? Text("Matched \(note.matchedEpisodes) of the last \(note.episodeCount) pressure falls · \(rate)")
            : Text("Matched \(note.matchedEpisodes) of the last \(note.episodeCount) pressure rises · \(rate)")
    }
}
