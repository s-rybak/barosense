import SwiftUI

/// The three Health cards on the Now screen (Figma `7:691`).
///
/// Copy is Ukrainian because the design is: `Пульс` / `SpO2` / `Сон`. The tab bar around
/// it is still English, which is the design's own inconsistency — neither is localised
/// yet, and both become string catalogue entries in one pass rather than one screen at a
/// time.
struct HealthMetricsRow: View {

    let snapshot: HealthMetricsSnapshot

    private enum Metrics {
        /// Gap between the three cards.
        static let spacing: CGFloat = 10
        static let cornerRadius: CGFloat = 18
        static let borderWidth: CGFloat = 1
        static let cardPadding: CGFloat = 15
        /// Between a figure and its caption.
        static let valueLabelSpacing: CGFloat = 6
        /// Height the design draws at the default content size. A floor, not a fixed
        /// height: the cards grow with Dynamic Type rather than clipping.
        static let minCardHeight: CGFloat = 78
    }

    var body: some View {
        HStack(alignment: .top, spacing: Metrics.spacing) {
            ForEach(cards, content: cardView)
        }
    }

    // MARK: - Cards

    private var cards: [Card] {
        [
            Card(kind: .restingHeartRate,
                 label: "Пульс",
                 value: snapshot.restingHeartRateBPM.map { "\(Int($0.rounded()))" }),
            Card(kind: .oxygenSaturation,
                 label: "SpO2",
                 value: snapshot.oxygenSaturationFraction.map { "\(Int(($0 * 100).rounded()))%" }),
            Card(kind: .asleep,
                 label: "Сон",
                 value: snapshot.asleepHours.map(Self.formattedHours))
        ]
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: Metrics.valueLabelSpacing) {
            Text(card.value ?? Self.unavailableValue)
                .font(Typography.metricValue)
                .foregroundStyle(Palette.inkStrong)
                .lineLimit(1)
                // A long value ("12г 05х" at an accessibility size) shrinks a little
                // rather than truncating: a clipped figure is a wrong figure.
                .minimumScaleFactor(0.6)

            Text(card.label)
                .font(Typography.metricLabel)
                .foregroundStyle(Palette.inkSubtle)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(Metrics.cardPadding)
        // Fills the tallest card in the row, so three cards stay a row and not a staircase.
        .frame(maxHeight: .infinity)
        .frame(minHeight: Metrics.minCardHeight)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.cardSurface)
        }
        // `strokeBorder`, not `stroke`: the design's 1 pt outline sits inside the card's
        // box, so a centred stroke would spill half of it outside the 97×78 the row is
        // laid out from.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: Metrics.borderWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(card.label))
        .accessibilityValue(Text(card.value ?? Self.unavailableAccessibilityValue))
    }

    // MARK: - Formatting

    /// Shown where a metric has no reading. Absence is ordinary here — no watch, no blood
    /// oxygen on this model, access not granted, or simply nothing recorded yet — so it
    /// reads as a blank rather than as an error.
    private static let unavailableValue = "—"

    /// VoiceOver reads the dash as nothing at all, so it gets words instead.
    private static let unavailableAccessibilityValue = "Немає даних"

    /// `7.333` → `"7г 20х"`, matching the design.
    ///
    /// Rounds to whole minutes once, so 59.6 minutes cannot show as `0г 60х`.
    ///
    /// `nonisolated` because a `View` is main-actor isolated and this is arithmetic on a
    /// `Double` — it has no business requiring a hop, and a test should not need one to
    /// call it.
    nonisolated static func formattedHours(_ hours: Double) -> String {
        let totalMinutes = Int((hours * 60).rounded())
        return "\(totalMinutes / 60)г \(totalMinutes % 60)х"
    }

    private struct Card: Identifiable {
        let kind: HealthMetricKind
        let label: String
        let value: String?

        var id: HealthMetricKind { kind }
    }
}

#Preview("With readings") {
    HealthMetricsRow(snapshot: HealthMetricsSnapshot(restingHeartRateBPM: 62,
                                                     oxygenSaturationFraction: 0.97,
                                                     asleepHours: 7 + 20.0 / 60))
    .padding(20)
    .background(Palette.surface)
}

#Preview("Nothing recorded") {
    HealthMetricsRow(snapshot: .empty)
        .padding(20)
        .background(Palette.surface)
}

#Preview("accessibility3") {
    HealthMetricsRow(snapshot: HealthMetricsSnapshot(restingHeartRateBPM: 62,
                                                     oxygenSaturationFraction: 0.97,
                                                     asleepHours: 7 + 20.0 / 60))
    .padding(20)
    .background(Palette.surface)
    .dynamicTypeSize(.accessibility3)
}
