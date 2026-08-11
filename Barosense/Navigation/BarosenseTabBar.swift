import SwiftUI

/// Root tab bar (Figma `7:708`).
///
/// Hand-built rather than a system `TabView` bar because the design raises the centre
/// action 26 pt above the bar, uses its own palette, and its own glyph set — none of
/// which a system bar exposes.
///
/// Dynamic Type is not capped. Up to `xxxLarge` the bar keeps its labelled layout and
/// grows with the type ramp; from the accessibility sizes on it switches to an
/// icon-only layout and hands the label to the system large content viewer, the same
/// trade `UITabBar` makes. Five labels cannot fit across the bar at those sizes, and
/// shrinking or truncating them would defeat the setting the user chose.
struct BarosenseTabBar: View {

    @Binding var selection: AppTab

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// Icon and label track `.caption2` — the style `Typography.tabLabel` is declared
    /// against — so the whole item scales as one piece.
    @ScaledMetric(relativeTo: .caption2) private var scaledIconSize = Metrics.baseIconSize
    @ScaledMetric(relativeTo: .caption2) private var scaledLabelHeight = Metrics.baseLabelHeight

    private enum Metrics {
        /// Size the glyphs in `TabBarIcons` are drawn at.
        static let baseIconSize: CGFloat = 22
        /// The icon stops growing here: five slots still have to fit across the
        /// narrowest supported iPhone (375 pt ⇒ ~64 pt per slot), and the raised
        /// centre action has to stay the biggest thing in the row.
        static let maxIconSize: CGFloat = 34
        /// Line box of the 11 pt label at the default content size.
        static let baseLabelHeight: CGFloat = 13
        static let minItemWidth: CGFloat = 52
        static let minRowHeight: CGFloat = 46
        static let topPadding: CGFloat = 10
        static let bottomPadding: CGFloat = 8
        static let horizontalPadding: CGFloat = 26
        /// Side inset once the labels outgrow the slot the design drew for them.
        static let compactHorizontalPadding: CGFloat = 8
        static let iconLabelSpacing: CGFloat = 5
        static let accentDiameter: CGFloat = 52
        /// How far the centre action is lifted out of the item row.
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
        .padding(.horizontal, horizontalPadding)
        .background {
            Palette.surface
                .overlay(alignment: .top) {
                    Palette.separator.frame(height: Metrics.separatorHeight)
                }
                .ignoresSafeArea(edges: .bottom)
        }
        // Reserve the lift above the painted surface. Touches are only delivered inside
        // the bar's own bounds — the part of the raised action that hangs over the top
        // edge draws but receives nothing — so the bounds have to cover it.
        .padding(.top, Metrics.accentLift)
    }

    // MARK: - Layout

    /// Labels are dropped at the accessibility sizes. `AppTab.label` stays reachable
    /// there through VoiceOver and the large content viewer, so nothing is lost.
    private var showsLabels: Bool { !dynamicTypeSize.isAccessibilitySize }

    private var iconSize: CGFloat { min(scaledIconSize, Metrics.maxIconSize) }

    /// From `xxLarge` up the side inset yields to the labels: at that point "Insights"
    /// and "Settings" have grown wide enough to meet across the slot boundary, and the
    /// margin buys ~7 pt of separation back on the narrowest supported iPhone. The
    /// icon-only layout above the ramp gets the full inset back.
    private var horizontalPadding: CGFloat {
        showsLabels && dynamicTypeSize >= .xxLarge
            ? Metrics.compactHorizontalPadding
            : Metrics.horizontalPadding
    }

    /// One item row: the scaled icon plus, when shown, the scaled label — never less
    /// than the 46 pt the design draws, so the default layout is untouched.
    private var rowHeight: CGFloat {
        let content = showsLabels
            ? iconSize + Metrics.iconLabelSpacing + scaledLabelHeight
            : iconSize
        return max(Metrics.minRowHeight, content)
    }

    /// Tap target of the centre action: one row plus the height it is lifted by, so
    /// the raised circle stays inside its own button instead of hanging over it.
    private var accentItemHeight: CGFloat { rowHeight + Metrics.accentLift }

    // MARK: - Items

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
        // The accent item is a full `accentItemHeight` button lifted as one piece, tap
        // target included; the outer frame keeps every item one row tall so the raised
        // one does not stretch the bar.
        .offset(y: tab.isAccent ? -Metrics.accentLift : 0)
        .frame(height: rowHeight, alignment: .top)
        .accessibilityLabel(tab.label)
        .accessibilityAddTraits(selection == tab ? [.isButton, .isSelected] : .isButton)
        // Long-press HUD at accessibility sizes. This is what replaces the on-screen
        // label once the icon-only layout takes over.
        .accessibilityShowsLargeContentViewer {
            Label {
                Text(tab.label)
            } icon: {
                TabIcon(tab: tab, tint: Palette.ink)
            }
        }
    }

    private func plainLabel(for tab: AppTab) -> some View {
        let tint = selection == tab ? Palette.ink : Palette.inkMuted

        return VStack(spacing: Metrics.iconLabelSpacing) {
            TabIcon(tab: tab, tint: tint, size: iconSize)

            if showsLabels {
                Text(tab.label)
                    .font(Typography.tabLabel)
                    .foregroundStyle(tint)
                    .lineLimit(1)
                    // Shrinks rather than truncates. The design was drawn against the
                    // English labels; "Налаштування" is twice the width of "Settings" and
                    // would come out as "Налаштува…", which is not a word.
                    .minimumScaleFactor(0.7)
            }
        }
        // The label gets the whole slot rather than the 52 pt the glyph needs, so it
        // stays intact a few steps further up the ramp before the icon-only layout
        // takes over. Widening the hit area to match is a bonus, not a side effect.
        .frame(minWidth: Metrics.minItemWidth, maxWidth: .infinity)
        .frame(maxHeight: .infinity, alignment: showsLabels ? .top : .center)
        .contentShape(.rect)
    }

    /// The centre action. Its label is always `ink`: it reads as the primary action
    /// rather than as a selection state.
    ///
    /// The circle keeps its 52 pt diameter at every content size — it already exceeds
    /// the 44 pt minimum target and is the widest thing in a ~64 pt slot, so growing
    /// it would collide with its neighbours rather than help anyone.
    private func accentLabel(for tab: AppTab) -> some View {
        VStack(spacing: Metrics.iconLabelSpacing) {
            Circle()
                .fill(Palette.ink)
                .frame(width: Metrics.accentDiameter, height: Metrics.accentDiameter)
                .overlay {
                    PlusGlyph().foregroundStyle(Palette.onInk)
                }
                .shadow(color: Palette.accentShadow, radius: 3.5, y: 6)

            if showsLabels {
                Text(tab.label)
                    .font(Typography.tabLabel)
                    .foregroundStyle(Palette.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        }
        .frame(minWidth: Metrics.minItemWidth, maxWidth: .infinity)
        .frame(height: accentItemHeight, alignment: .top)
        .contentShape(.rect)
    }
}

#Preview("Default") {
    @Previewable @State var selection: AppTab = .now

    VStack {
        Spacer()
        BarosenseTabBar(selection: $selection)
    }
    .background(Palette.surface)
}

#Preview("xxxLarge — largest labelled layout") {
    @Previewable @State var selection: AppTab = .now

    VStack {
        Spacer()
        BarosenseTabBar(selection: $selection)
    }
    .background(Palette.surface)
    .dynamicTypeSize(.xxxLarge)
}

#Preview("accessibility5 — icon-only layout") {
    @Previewable @State var selection: AppTab = .now

    VStack {
        Spacer()
        BarosenseTabBar(selection: $selection)
    }
    .background(Palette.surface)
    .dynamicTypeSize(.accessibility5)
}
