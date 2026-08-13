import SwiftUI

/// The "figure over a bar" card the Now screen draws twice: the weather index, and how much
/// history the model has to work with.
///
/// One component rather than two, because the design draws one. The two differ in their label,
/// their tint and whether they carry an explainer; two copies would be two places for the bar's
/// geometry to drift apart.
///
/// ## Two departures from the design
///
/// 1. **The explainer sits in the figure row, not in the card's top-right corner.** In the frame
///    the ⓘ floats above the label. Drawn that way it either overlaps the label at the default
///    text size or costs the card a third row, and a 16 pt glyph in a corner is not a tap
///    target. In the row it keeps the card at the height the design draws and gets the 44 pt
///    square Apple asks for.
/// 2. **A missing value prints an em dash and a reason, not `0%`.** The design has no empty
///    state. A zero-length bar for "the phone was asleep all night" is a confidently wrong
///    reading, which is the one thing the pipeline rules forbid outright.
struct ProgressMeterCard: View {

    /// What the bar measures, named to the right of the figure.
    let title: LocalizedStringKey

    /// 0–1, or `nil` when there is nothing to report — a fresh install, or a gap wide enough
    /// that a figure would be a guess.
    let value: Double?

    /// The fill. The track is `Palette.controlBorder` on both cards, so only this moves.
    let tint: Color

    /// Why there is no figure. Drawn under the empty track; ignored when `value` is set.
    var unavailableNote: LocalizedStringKey?

    /// Opens the explainer sheet. `nil` on a card with nothing to explain, and the ⓘ is then
    /// absent rather than dimmed.
    var explain: (() -> Void)?

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1
        static let padding: CGFloat = 17
        /// Between the figure row, the bar, and the note under it.
        static let rowSpacing: CGFloat = 12
        static let barHeight: CGFloat = 8
        /// The ⓘ glyph. Its tap target is grown to 44 pt and pulled back out of the layout.
        static let explainGlyph: CGFloat = 17
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            figureRow

            bar

            if value == nil, let unavailableNote {
                Text(unavailableNote)
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.inkSubtle)
            }
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.cardSurface)
        }
        // `strokeBorder` so the 1 pt outline sits inside the card's box — same reasoning as
        // `HealthMetricsRow` and `PressureChartCard`.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: Metrics.borderWidth)
        }
        // One element, not four: VoiceOver reading a figure, a label and an unlabelled bar as
        // three stops says the same thing three times and the bar says nothing at all. The ⓘ
        // stays separate — it is an action, and `children: .contain` keeps it reachable.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
        .accessibilityValue(accessibilityValue)
    }

    // MARK: - Rows

    private var figureRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(verbatim: figure)
                .font(Typography.metricValue)
                .foregroundStyle(Palette.inkStrong)
                .monospacedDigit()
                .lineLimit(1)

            Spacer(minLength: 8)

            Text(title)
                .font(Typography.meterLabel)
                .foregroundStyle(Palette.inkSubtle)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .minimumScaleFactor(0.8)

            if let explain {
                explainButton(explain)
            }
        }
        .accessibilityHidden(true)
    }

    /// The bar. Drawn from the card's own width rather than from a fixed one, so it fills
    /// whatever the screen gives it.
    private var bar: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule(style: .continuous)
                    .fill(Palette.controlBorder)

                Capsule(style: .continuous)
                    .fill(tint)
                    .frame(width: proxy.size.width * (value ?? 0))
            }
        }
        .frame(height: Metrics.barHeight)
        // The figure and the fill arrive together, from the same load. Animating the fill and
        // not the figure is what makes a bar look like it is reporting rather than redrawing.
        .animation(.easeOut(duration: 0.35), value: value)
        .accessibilityHidden(true)
    }

    private func explainButton(_ explain: @escaping () -> Void) -> some View {
        Button(action: explain) {
            Image(systemName: "info.circle")
                .font(.system(size: Metrics.explainGlyph, weight: .regular))
                .foregroundStyle(Palette.inkMuted)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        // Pulled back out of the layout so a 44 pt target does not set the row's height.
        .padding(.vertical, -14)
        .padding(.trailing, -13)
        .accessibilityLabel(Text("What this measures"))
        // Hidden by the row above, which is one element; this puts the action back.
        .accessibilityHidden(false)
    }

    // MARK: - Formatting

    /// `0.48` → `48%`, in whichever locale the app is running. An em dash where there is no
    /// reading — the same blank `HealthMetricsRow` prints, for the same reason.
    private var figure: String {
        guard let value else { return "—" }

        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    /// Spoken rather than drawn: VoiceOver reads an em dash as nothing at all.
    private var accessibilityValue: Text {
        guard let value else { return Text("No data") }

        return Text(verbatim: value.formatted(.percent.precision(.fractionLength(0))))
    }
}

#Preview("Both cards") {
    VStack(spacing: 14) {
        ProgressMeterCard(title: "Weather Trigger Index",
                          value: 0.48,
                          tint: Palette.markerWarm)

        ProgressMeterCard(title: "Model training progress",
                          value: 0.48,
                          tint: Palette.markerCool,
                          explain: {})
    }
    .padding(20)
    .background(Palette.surface)
}

#Preview("Nothing to report") {
    ProgressMeterCard(title: "Weather Trigger Index",
                      value: nil,
                      tint: Palette.markerWarm,
                      unavailableNote: "Not enough readings in the last few hours")
        .padding(20)
        .background(Palette.surface)
}

#Preview("accessibility3") {
    VStack(spacing: 14) {
        ProgressMeterCard(title: "Weather Trigger Index",
                          value: 0.48,
                          tint: Palette.markerWarm)

        ProgressMeterCard(title: "Model training progress",
                          value: 0.9,
                          tint: Palette.markerCool,
                          explain: {})
    }
    .padding(20)
    .background(Palette.surface)
    .dynamicTypeSize(.accessibility3)
}
