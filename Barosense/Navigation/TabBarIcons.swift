import SwiftUI

/// Tab-bar glyph for one destination.
///
/// The glyphs are vector shapes in Figma (component `7:708`), not exported image assets,
/// so they are rebuilt here at the same dimensions instead of shipped as files. Every
/// glyph is laid out inside the same 22 pt box so the row stays aligned.
struct TabIcon: View {

    let tab: AppTab
    let tint: Color

    static let size: CGFloat = 22

    var body: some View {
        Group {
            switch tab {
            case .now: NowGlyph()
            case .history: HistoryGlyph()
            case .log: PlusGlyph()
            case .insights: InsightsGlyph()
            case .settings: SettingsGlyph()
            }
        }
        .foregroundStyle(tint)
        .frame(width: Self.size, height: Self.size)
    }
}

/// `Log` — plus sign, 18 pt arms 3 pt thick. Used inside the raised accent button.
struct PlusGlyph: View {
    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .frame(width: 18, height: 3)
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .frame(width: 3, height: 18)
        }
        .frame(width: 18, height: 18)
    }
}

/// `Now` — solid 22 pt dot.
private struct NowGlyph: View {
    var body: some View {
        Circle()
    }
}

/// `History` — 2×2 grid of 10 pt squares with 2 pt gutters.
private struct HistoryGlyph: View {
    var body: some View {
        VStack(spacing: 2) {
            row
            row
        }
    }

    private var row: some View {
        HStack(spacing: 2) {
            cell
            cell
        }
    }

    private var cell: some View {
        RoundedRectangle(cornerRadius: 2, style: .continuous)
            .frame(width: 10, height: 10)
    }
}

/// `Insights` — three bottom-aligned bars, 4 pt wide.
private struct InsightsGlyph: View {

    private static let barHeights: [CGFloat] = [10, 18, 14]

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Self.barHeights, id: \.self) { height in
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .frame(width: 4, height: height)
            }
        }
        .frame(height: TabIcon.size, alignment: .bottom)
    }
}

/// `Settings` — 2 pt ring around a 7 pt dot.
private struct SettingsGlyph: View {
    var body: some View {
        Circle()
            .strokeBorder(lineWidth: 2)
            .overlay {
                Circle().frame(width: 7, height: 7)
            }
    }
}

#Preview {
    HStack(spacing: 20) {
        ForEach(AppTab.allCases) { tab in
            TabIcon(tab: tab, tint: Palette.ink)
        }
    }
    .padding()
    .background(Palette.surface)
}
