import SwiftUI

/// Root tab bar (Figma `7:708`).
///
/// Hand-built rather than a system `TabView` bar because the design raises the centre
/// action 26 pt above the bar, uses its own palette, and its own glyph set — none of
/// which a system bar exposes.
struct BarosenseTabBar: View {

    @Binding var selection: AppTab

    private enum Metrics {
        static let itemWidth: CGFloat = 52
        static let rowHeight: CGFloat = 46
        static let topPadding: CGFloat = 10
        static let bottomPadding: CGFloat = 8
        static let horizontalPadding: CGFloat = 26
        static let iconLabelSpacing: CGFloat = 5
        static let accentDiameter: CGFloat = 52
        /// How far the centre action sits above the bar's top edge.
        static let accentLift: CGFloat = 26
        static let separatorHeight: CGFloat = 1
    }

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(AppTab.allCases) { tab in
                item(for: tab)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.top, Metrics.topPadding)
        .padding(.bottom, Metrics.bottomPadding)
        .padding(.horizontal, Metrics.horizontalPadding)
        .background {
            Palette.surface
                .overlay(alignment: .top) {
                    Palette.separator.frame(height: Metrics.separatorHeight)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        // The bar is a fixed-height row of 11 pt labels; letting it grow to the largest
        // accessibility sizes would push the raised action off the design grid.
        .dynamicTypeSize(...DynamicTypeSize.accessibility1)
    }

    private func item(for tab: AppTab) -> some View {
        Button {
            selection = tab
        } label: {
            if tab.isAccent {
                accentLabel(for: tab)
            } else {
                plainLabel(for: tab)
            }
        }
        .buttonStyle(.plain)
        .frame(height: Metrics.rowHeight, alignment: .top)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
    }

    private func plainLabel(for tab: AppTab) -> some View {
        let tint = selection == tab ? Palette.ink : Palette.inkMuted

        return VStack(spacing: Metrics.iconLabelSpacing) {
            TabIcon(tab: tab, tint: tint)
            Text(tab.label)
                .font(Typography.tabLabel)
                .foregroundStyle(tint)
        }
        .frame(width: Metrics.itemWidth)
        .contentShape(.rect)
    }

    /// The centre action. Its label is always `ink`: it reads as the primary action
    /// rather than as a selection state.
    private func accentLabel(for tab: AppTab) -> some View {
        VStack(spacing: Metrics.iconLabelSpacing) {
            Circle()
                .fill(Palette.ink)
                .frame(width: Metrics.accentDiameter, height: Metrics.accentDiameter)
                .overlay {
                    PlusGlyph().foregroundStyle(Palette.onInk)
                }
                .shadow(color: Palette.accentShadow, radius: 3.5, y: 6)

            Text(tab.label)
                .font(Typography.tabLabel)
                .foregroundStyle(Palette.ink)
        }
        .frame(width: Metrics.itemWidth)
        .offset(y: -Metrics.accentLift)
        .contentShape(.rect)
    }
}

#Preview {
    @Previewable @State var selection: AppTab = .now

    VStack {
        Spacer()
        BarosenseTabBar(selection: $selection)
    }
    .background(Palette.surface)
}
