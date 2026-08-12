import SwiftUI

// "My medications", pushed from the row under the History calendar.
//
// The design has no frame for this screen; the layout below is built out of the components the
// rest of the app already uses (`Typography.screenTitle`, the card fill and border from the
// Now screen's cards) rather than invented, so it does not have to be redrawn when a frame
// arrives.
//
// ## What this screen is allowed to say
//
// It groups the user's own entries and reports four facts per medication: the name they typed,
// the amounts they typed, how many times they wrote it down, and when that last was. It does
// **not** total anything into a daily amount, work out an interval, relate a medication to how
// the user felt, or suggest a next one. Each of those would be the app giving guidance about
// medication, which is squarely outside what `MedicationEntry` and `CLAUDE.md` allow this app
// to do — and is also the kind of screen App Review reads closely.

/// The order picker's copy. Here rather than beside `MedicationOrder` in `Shared/`, which is
/// UI-free and therefore holds no `LocalizedStringKey` — the same split `HistoryPeriod.label`
/// makes one file over.
extension MedicationOrder {
    var label: LocalizedStringKey {
        switch self {
        case .recent: "Recent"
        case .name: "A–Z"
        }
    }
}

struct MedicationsScreen: View {

    let checkInStore: any CheckInStore

    /// The window the History screen was showing when the row was tapped, so the figures here
    /// reconcile with the medication count on the card the user came from.
    let window: Range<Date>

    /// The window in words, carried over from the card the user tapped rather than re-derived,
    /// so the two screens cannot end up naming the same range differently.
    let periodTitle: Text

    /// As the store gives them: most recently taken first. `ordered` applies the user's choice
    /// on top, so switching the order does not go back to the store for rows already in hand.
    @State private var summaries: [MedicationSummary] = []
    @State private var order: MedicationOrder = .recent
    @State private var hasLoaded = false

    private static let horizontalMargin: CGFloat = 20

    /// Below this there is one row, and one row has no order.
    private static let orderPickerMinimumRows = 2

    private var ordered: [MedicationSummary] {
        MedicationHistory.ordered(summaries, by: order)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                header

                if summaries.count >= Self.orderPickerMinimumRows {
                    SegmentedSelector(options: MedicationOrder.allCases, selection: $order) {
                        Text($0.label)
                    }
                }

                if summaries.isEmpty {
                    // Only once a read has finished. An empty state during the first few
                    // hundred milliseconds tells a user with a full history that they have none.
                    if hasLoaded {
                        Text("Nothing added yet")
                            .font(Typography.cardNote)
                            .foregroundStyle(Palette.inkSubtle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                    ForEach(ordered) { summary in
                        MedicationSummaryRow(summary: summary)
                    }
                }
            }
            // Keyed on `order` alone: the rows should slide past each other when the user
            // switches, and appear without a flourish when the first read lands.
            .animation(.easeInOut(duration: 0.2), value: order)
            .padding(.horizontal, Self.horizontalMargin)
            // Clears the inline navigation bar the push puts over the content — without it the
            // heading sits against the back chevron.
            .padding(.top, 12)
            .padding(.bottom, 14)
        }
        .background(Palette.surface)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: window) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("My medications")
                .font(Typography.screenTitle)
                .foregroundStyle(Palette.heading)
                .accessibilityAddTraits(.isHeader)

            Text("What you have logged, grouped by name")
                .font(Typography.onboardingBodySmall)
                .foregroundStyle(Palette.bodyText)

            periodTitle
                .font(Typography.captionEmphasis)
                .foregroundStyle(Palette.inkSubtle)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 4)
    }

    /// A failed read shows the same empty state as an empty window. Nothing on this screen is
    /// actionable when the store will not open, and the wording does not claim the user has
    /// taken nothing — it says nothing has been added.
    private func load() async {
        let checkIns = (try? await checkInStore.checkIns(in: window)) ?? []
        summaries = MedicationHistory.summaries(in: checkIns.flatMap(\.medications))
        hasLoaded = true
    }
}

// MARK: - Row

/// One medication: what it is called, what was taken, how often, and when last.
private struct MedicationSummaryRow: View {

    let summary: MedicationSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(verbatim: summary.name)
                    .font(Typography.choiceLabel)
                    .foregroundStyle(Palette.heading)

                Spacer(minLength: 8)

                Text("\(summary.timesTaken) times")
                    .font(Typography.captionEmphasis)
                    .foregroundStyle(Palette.inkSubtle)
                    .monospacedDigit()
                    .lineLimit(1)
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                if !summary.doses.isEmpty {
                    // The user's own words, joined — never re-formatted into a unit the app
                    // chose. "400 мг" and "1 таблетка" are both valid answers here.
                    Text(verbatim: summary.doses.joined(separator: " · "))
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.bodyText)
                        .lineLimit(2)
                }

                Spacer(minLength: 8)

                Text("Last taken \(lastTaken)")
                    .font(Typography.fieldUnit)
                    .foregroundStyle(Palette.inkSubtle)
                    .lineLimit(1)
            }
        }
        .padding(17)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Palette.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
        .accessibilityElement(children: .combine)
    }

    private var lastTaken: String {
        summary.lastTakenAt.formatted(.dateTime.day().month(.abbreviated))
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        MedicationsScreen(checkInStore: InMemoryCheckInStore(PreviewHistory.checkIns),
                          window: Date.distantPast..<Date.distantFuture,
                          periodTitle: Text("All time"))
    }
}
