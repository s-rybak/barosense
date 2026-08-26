import SwiftUI

/// The app mark, drawn rather than shipped as an image.
///
/// ## Why a `Shape` and not an asset
///
/// This repository has no asset catalogue at all, and adding one for a single mark would put
/// a rasterised logo on a display whose sizes range from 40 mm to 49 mm — the case where a
/// bitmap either ships at several scales or looks soft on one of them. A path is exact at
/// every size, costs no bytes in the bundle, and takes the palette's own colours, so the mark
/// and the screen behind it cannot drift apart the way an exported PNG does.
///
/// ## What it draws
///
/// A barometer dial cut open at two points, with a pressure trace running through it: the
/// olive outer ring is the instrument, the cream inner arc is its face, and the line is the
/// same falling-then-recovering trace the rest of the app draws. The two accents are the
/// two states the app has words for — a warm spike where pressure moves sharply, a calm dot
/// where it settles.
///
/// Geometry is expressed in fractions of the frame so the mark scales cleanly; nothing here
/// is a pixel value.
struct BarosenseLogoMark: View {

    /// Side of the square the mark is drawn in.
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(WatchPalette.logoField)

            // The instrument's body: a ring broken at the two points the trace crosses it, so
            // the line reads as passing through the dial rather than sitting on top of it.
            DialRing(gaps: [(-18, 18), (162, 198)])
                .stroke(WatchPalette.logoRing,
                        style: StrokeStyle(lineWidth: size * 0.055, lineCap: .butt))
                .padding(size * 0.055)

            // The face, open at the lower right where the trace exits.
            DialRing(gaps: [(-40, 70)])
                .stroke(WatchPalette.ink,
                        style: StrokeStyle(lineWidth: size * 0.05, lineCap: .round))
                .padding(size * 0.20)

            PressureTrace()
                .stroke(WatchPalette.ink,
                        style: StrokeStyle(lineWidth: size * 0.055,
                                           lineCap: .round,
                                           lineJoin: .round))

            // The spike, drawn over the trace in the accent rather than as a separate path
            // shape, so the two share one geometry and cannot fall out of alignment.
            PressureTrace(clippedTo: 0.20...0.36)
                .stroke(WatchPalette.markerWarm,
                        style: StrokeStyle(lineWidth: size * 0.055,
                                           lineCap: .round,
                                           lineJoin: .round))

            Circle()
                .fill(WatchPalette.positive)
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(x: size * 0.335, y: -size * 0.075)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Geometry

/// A circle with arcs removed, given as degree ranges measured clockwise from three o'clock.
private struct DialRing: Shape {

    /// Start and end of each removed span, in degrees. May start negative, which is how a gap
    /// straddling three o'clock is written without splitting it into two.
    let gaps: [(Double, Double)]

    func path(in rect: CGRect) -> Path {
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let radius = min(rect.width, rect.height) / 2

        // The kept spans are the complement of the gaps: walk the gap ends in order and draw
        // from each one to the start of the next. Written this way because the gaps are what
        // the design specifies, and deriving the arcs is less error-prone than listing both.
        let ordered = gaps.map { (start: $0.0, end: $0.1) }.sorted { $0.start < $1.start }

        var path = Path()
        for (index, gap) in ordered.enumerated() {
            let next = ordered[(index + 1) % ordered.count]
            let sweepEnd = next.start < gap.end ? next.start + 360 : next.start

            // `move` before every arc, and it is load-bearing rather than tidiness: `addArc`
            // draws a line from the current point to the arc's start when there is one, so
            // without this the gaps fill in with chords and the ring renders as a crosshair.
            path.move(to: CGPoint(x: centre.x + radius * cos(gap.end * .pi / 180),
                                  y: centre.y + radius * sin(gap.end * .pi / 180)))
            path.addArc(center: centre,
                        radius: radius,
                        startAngle: .degrees(gap.end),
                        endAngle: .degrees(sweepEnd),
                        clockwise: false)
        }
        return path
    }
}

/// The trace across the dial: a fall into a sharp trough, a recovery, and a level run out to
/// the right where the dot sits.
///
/// Control points are fractions of the frame. `clippedTo` returns only the span between two
/// fractions of the horizontal extent, which is how the accent is drawn from the same curve
/// as the line under it.
private struct PressureTrace: Shape {

    var clippedTo: ClosedRange<Double> = 0...1

    /// The trace's vertices, left to right, as fractions of the frame.
    private static let points: [CGPoint] = [
        CGPoint(x: 0.06, y: 0.60),
        CGPoint(x: 0.22, y: 0.60),
        CGPoint(x: 0.28, y: 0.44),
        CGPoint(x: 0.34, y: 0.66),
        CGPoint(x: 0.46, y: 0.60),
        CGPoint(x: 0.58, y: 0.52),
        CGPoint(x: 0.72, y: 0.46),
        CGPoint(x: 0.84, y: 0.42)
    ]

    func path(in rect: CGRect) -> Path {
        let kept = Self.points.filter { clippedTo.contains($0.x) }
        guard kept.count > 1 else { return Path() }

        let scaled = kept.map {
            CGPoint(x: rect.minX + $0.x * rect.width, y: rect.minY + $0.y * rect.height)
        }

        var path = Path()
        path.move(to: scaled[0])
        for point in scaled.dropFirst() {
            path.addLine(to: point)
        }
        return path
    }
}

#Preview("Mark") {
    ZStack {
        WatchPalette.surface.ignoresSafeArea()
        BarosenseLogoMark(size: 96)
    }
}
