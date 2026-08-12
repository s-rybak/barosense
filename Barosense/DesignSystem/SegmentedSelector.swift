import SwiftUI

/// Outside `SegmentedSelector` because a generic type cannot hold static stored properties —
/// the same reason `ScaffoldMetrics` sits outside `OnboardingStepScaffold`.
private enum SelectorMetrics {
    static let trackRadius: CGFloat = 12
    static let itemRadius: CGFloat = 9
    static let trackPadding: CGFloat = 4
    static let itemSpacing: CGFloat = 4
    static let itemTopPadding: CGFloat = 12
    static let itemBottomPadding: CGFloat = 9
}

/// The app's segmented picker: a rounded track with a white pill under the selected option
/// (Figma `7:682` on the chart card, `M3 · Історія` above the calendar).
///
/// Generic over the option type rather than copied per screen. Both places it is used draw the
/// same control at the same size, and the second copy is where a design change starts landing
/// on one screen and not the other.
///
/// Not `Picker(.segmented)`: the system control takes its geometry and its selected-pill fill
/// from the platform, and the design specifies both.
struct SegmentedSelector<Option: Hashable & Identifiable>: View {

    let options: [Option]

    @Binding var selection: Option

    /// The label for one option. A `Text`, not a `String`, so a call site can hand over either
    /// a localisable key or verbatim user text.
    let title: (Option) -> Text

    var body: some View {
        HStack(spacing: SelectorMetrics.itemSpacing) {
            ForEach(options) { option in
                Button {
                    selection = option
                } label: {
                    label(for: option)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(option == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(SelectorMetrics.trackPadding)
        .background {
            RoundedRectangle(cornerRadius: SelectorMetrics.trackRadius, style: .continuous)
                .fill(Palette.segmentedTrack)
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func label(for option: Option) -> some View {
        let isSelected = option == selection

        return title(option)
            .font(isSelected ? Typography.segmentLabelSelected : Typography.segmentLabel)
            .foregroundStyle(isSelected ? Palette.heading : Palette.inkSubtle)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .frame(maxWidth: .infinity)
            .padding(.top, SelectorMetrics.itemTopPadding)
            .padding(.bottom, SelectorMetrics.itemBottomPadding)
            .background {
                if isSelected {
                    RoundedRectangle(cornerRadius: SelectorMetrics.itemRadius, style: .continuous)
                        .fill(Palette.cardSurface)
                        .shadow(color: .black.opacity(0.08), radius: 0.75, x: 0, y: 1)
                }
            }
            .contentShape(.rect)
    }
}

#Preview {
    @Previewable @State var selection: HistoryPeriod = .month

    SegmentedSelector(options: HistoryPeriod.allCases, selection: $selection) { period in
        Text(period.label)
    }
    .padding(20)
    .background(Palette.surface)
}
