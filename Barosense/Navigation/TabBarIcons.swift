import SwiftUI

/// Tab-bar glyph for one destination.
///
/// The glyphs are vector shapes in Figma (component `7:708`), not exported image assets,
/// so they are rebuilt here at the same dimensions instead of shipped as files. Every
/// glyph is laid out inside the same 22 pt box so the row stays aligned.
struct TabIcon: View {

    let tab: AppTab
    let tint: Color
    /// Rendered size. The tab bar raises this with Dynamic Type; anything other than
    /// `baseSize` is a uniform scale of the 22 pt drawing, so proportions and stroke
    /// weights hold and the shapes stay vector-crisp.
    var size: CGFloat = TabIcon.baseSize

    static let baseSize: CGFloat = 22

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
        .frame(width: Self.baseSize, height: Self.baseSize)
        .scaleEffect(size / Self.baseSize)
        .frame(width: size, height: size)
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

/// `Now` — 2 pt ring around a 7 pt dot.
///
/// This drawing used to be the Settings glyph. It moved here rather than being copied: an
/// aperture reads as "what is true at this moment", which is what the destination shows,
/// and Settings took the cog every platform already uses for it.
private struct NowGlyph: View {
    var body: some View {
        Circle()
            .strokeBorder(lineWidth: 2)
            .overlay {
                Circle().frame(width: 7, height: 7)
            }
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
        .frame(height: TabIcon.baseSize, alignment: .bottom)
    }
}

/// `Settings` — an eight-tooth cog with an open hub.
///
/// Drawn rather than taken from SF Symbols, for the reason every other glyph in this file
/// is: a symbol carries Apple's own optical sizing and stroke weight, and one symbol in a
/// row of four hand-built shapes reads a weight heavier than its neighbours at 22 pt.
private struct SettingsGlyph: View {
    var body: some View {
        // Even-odd, so the hub subpath is a hole rather than a second filled disc.
        GearShape().fill(style: FillStyle(eoFill: true))
    }
}

/// The cog behind `SettingsGlyph`, as one path: the toothed outline, then the hub as a
/// second subpath for an even-odd fill to cut out.
///
/// Proportions are set against the 22 pt box every glyph is drawn in — a 22 pt tip
/// diameter to fill the box the way `NowGlyph` does, and a hub a shade under a third of
/// it, which is what keeps the ring of teeth reading as teeth at tab-bar size rather than
/// as a serrated blob.
private struct GearShape: Shape {

    var teeth = 8
    /// Radius at a tooth tip — the widest point of the glyph.
    var tipRadius: CGFloat = 11
    /// Radius of the body the teeth stand on.
    var rootRadius: CGFloat = 8.2
    var hubRadius: CGFloat = 3.4
    /// How much of one tooth-to-tooth pitch the tooth itself takes, 0 to 1. At 0.5 tooth
    /// and gap are equal, which is the reference drawing.
    var toothWidth = 0.5

    func path(in rect: CGRect) -> Path {
        var path = Path()

        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let pitch = 2 * Double.pi / Double(teeth)
        let halfTooth = pitch * toothWidth / 2

        for index in 0..<teeth {
            // Tooth centres start at twelve o'clock, so the glyph is symmetric about the
            // vertical the label under it is centred on.
            let axis = Double(index) * pitch - Double.pi / 2

            // The arc across the tip. `addArc` draws a line from the current point to the
            // arc's start, which is what forms the radial flank between root and tip — so
            // the four calls per tooth below need no explicit `addLine`.
            path.addArc(center: centre,
                        radius: tipRadius,
                        startAngle: .radians(axis - halfTooth),
                        endAngle: .radians(axis + halfTooth),
                        clockwise: false)

            // Down the far flank and along the gap to where the next tooth begins.
            path.addArc(center: centre,
                        radius: rootRadius,
                        startAngle: .radians(axis + halfTooth),
                        endAngle: .radians(axis + pitch - halfTooth),
                        clockwise: false)
        }

        path.closeSubpath()

        path.addEllipse(in: CGRect(x: centre.x - hubRadius,
                                   y: centre.y - hubRadius,
                                   width: hubRadius * 2,
                                   height: hubRadius * 2))

        return path
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
