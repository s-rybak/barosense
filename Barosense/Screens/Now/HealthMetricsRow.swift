import SwiftUI

/// The three Health cards on the Now screen (Figma `7:691`).
///
/// Copy is keyed in English and translated in `Localizable.xcstrings`, like the rest of
/// the app. The design draws this row in Ukrainian (`Пульс` / `SpO2` / `Сон`) and that is
/// exactly what the `uk` entries say — the base language is the source key, not the
/// language a user sees.
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
            // The measured rate, not `restingHeartRateBPM`. Resting heart rate is a daily
            // aggregate HealthKit publishes hours after the day it covers — on a screen
            // headed "now" it showed a figure from yesterday morning.
            Card(kind: .heartRate,
                 label: "Heart rate",
                 // Verbatim: a bare figure is a number, not copy, and running it through a
                 // lookup would let a translation change it.
                 value: snapshot.heartRateBPM.map { Text(verbatim: "\(Int($0.rounded()))") }),
            Card(kind: .oxygenSaturation,
                 label: "SpO2",
                 value: snapshot.oxygenSaturationFraction
                     .map { Text(verbatim: "\(Int(($0 * 100).rounded()))%") }),
            Card(kind: .asleep,
                 label: "Sleep",
                 value: snapshot.asleepHours.map(Self.sleepDurationText))
        ]
    }

    private func cardView(_ card: Card) -> some View {
        VStack(spacing: Metrics.valueLabelSpacing) {
            (card.value ?? Text(verbatim: Self.unavailableValue))
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
        .accessibilityValue(card.value ?? Text("No data"))
    }

    // MARK: - Formatting

    /// Shown where a metric has no reading. Absence is ordinary here — no watch, no blood
    /// oxygen on this model, access not granted, or simply nothing recorded yet — so it
    /// reads as a blank rather than as an error.
    ///
    /// Not translated: an em dash is punctuation, and VoiceOver reads it as nothing at all,
    /// which is why the accessibility value says "No data" in words instead.
    private static let unavailableValue = "—"

    /// `7.333` → `7 h 20 min`, in whichever language the app is running.
    ///
    /// The two numbers go into the string separately rather than being pre-formatted,
    /// because the separator between them is copy: the design writes `7г 20х`, English
    /// writes `7h 20m`, and only the translation knows which.
    private static func sleepDurationText(_ hours: Double) -> Text {
        let split = hoursAndMinutes(hours)
        return Text("\(split.hours)h \(split.minutes)m")
    }

    /// Rounds to whole minutes once, so 59.6 minutes cannot come out as `0 h 60 min`.
    ///
    /// `nonisolated` because a `View` is main-actor isolated and this is arithmetic on a
    /// `Double` — it has no business requiring a hop, and a test should not need one to
    /// call it.
    nonisolated static func hoursAndMinutes(_ hours: Double) -> (hours: Int, minutes: Int) {
        let totalMinutes = Int((hours * 60).rounded())
        return (totalMinutes / 60, totalMinutes % 60)
    }

    private struct Card: Identifiable {
        let kind: HealthMetricKind
        let label: LocalizedStringKey
        /// Already-built `Text` rather than a `String`: a figure is verbatim and a
        /// duration is translated, and the card should not have to know which it holds.
        let value: Text?

        var id: HealthMetricKind { kind }
    }
}

#Preview("With readings") {
    HealthMetricsRow(snapshot: HealthMetricsSnapshot(heartRateBPM: 72,
                                                     restingHeartRateBPM: 62,
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
    HealthMetricsRow(snapshot: HealthMetricsSnapshot(heartRateBPM: 72,
                                                     restingHeartRateBPM: 62,
                                                     oxygenSaturationFraction: 0.97,
                                                     asleepHours: 7 + 20.0 / 60))
    .padding(20)
    .background(Palette.surface)
    .dynamicTypeSize(.accessibility3)
}
