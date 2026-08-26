import Charts
import SwiftUI

/// The watch's main screen: the pressure the phone last measured (Figma `W1`).
///
/// One number, its unit and its tendency, over the short line it came out of. Everything
/// with more in it — the plotted window, the two gauges, the check-in form — is a push away,
/// so the glance is never competing with a second thing to read.
///
/// ## One deliberate divergence from the frame
///
/// The frame prints inches of mercury (`29.91 inHg`). This prints hectopascals. The domain
/// layer carries one unit and one only (`Pressure`, and the rule in
/// `.claude/skills/swift_conventions/SKILL.md`), the phone's chart already draws hPa, and a
/// watch that disagreed with the phone about the number would read as two measurements. A
/// user-selectable unit is a real feature and belongs to both platforms at once, not to this
/// screen — see the follow-ups.
struct WatchNowView: View {

    let display: PressureDisplayController

    var body: some View {
        VStack(spacing: 4) {
            reading

            caption

            NavigationLink(value: WatchRoute.trend) {
                sparkline
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Pressure trend")

            NavigationLink(value: WatchRoute.log) {
                Text("Check in")
                    .font(WatchTypography.control)
                    .foregroundStyle(WatchPalette.ink)
                    .frame(maxWidth: .infinity, minHeight: 34)
                    .background(
                        Capsule(style: .continuous).fill(WatchPalette.controlFill)
                    )
            }
            .buttonStyle(.plain)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(WatchPalette.surface)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink(value: WatchRoute.details) {
                    // Explicit, because the toolbar button's own fill is the accent colour
                    // and a glyph left to inherit it disappears into its background.
                    Image(systemName: "ellipsis")
                        .foregroundStyle(WatchPalette.ink)
                }
                .accessibilityLabel("Reading details")
            }
        }
    }

    // MARK: - Number

    /// The dash is the ordinary state until the phone's first reading arrives. Not an error
    /// worth wording: a fresh install, a phone out of range, and a phone that has simply not
    /// sampled yet all look the same from here and all resolve themselves.
    private var reading: some View {
        Text(readingText)
            .font(WatchTypography.reading)
            .foregroundStyle(WatchPalette.ink)
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .contentTransition(.numericText())
            .accessibilityLabel(accessibilityReading)
    }

    private var readingText: String {
        guard let hectopascals = display.snapshot?.sample.pressure.hectopascals else { return "—" }
        return PressureFormat.roundedHectopascals(hectopascals)
    }

    /// The unit, the tendency, and the one thing that would otherwise be a lie.
    ///
    /// **The age**, whenever the reading is older than the phone's own sampling floor: a
    /// watch out of range for a day would otherwise present yesterday's pressure as the
    /// current one, and the user has no way to tell.
    @ViewBuilder
    private var caption: some View {
        if let snapshot = display.snapshot {
            VStack(spacing: 1) {
                HStack(spacing: 4) {
                    Text("hPa")
                        .foregroundStyle(WatchPalette.inkMuted)

                    if let symbol = WatchTrendStyle.symbol(for: snapshot.trend),
                       let word = WatchTrendStyle.caption(for: snapshot.trend) {
                        Image(systemName: symbol)
                            .imageScale(.small)
                        Text(word)
                    }
                }
                .foregroundStyle(WatchTrendStyle.tint(for: snapshot.trend))

                if let age = staleness(of: snapshot) {
                    Text(age)
                        .foregroundStyle(WatchPalette.inkMuted)
                }
            }
            .font(WatchTypography.caption)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityHidden(true)
        } else {
            Text("waiting for your phone")
                .font(WatchTypography.caption)
                .foregroundStyle(WatchPalette.inkMuted)
        }
    }

    private func staleness(of snapshot: PressureDisplaySnapshot) -> String? {
        let age = Date.now.timeIntervalSince(snapshot.sample.timestamp)
        guard age > PressureSamplingPolicy.minimumIntervalSeconds else { return nil }

        return snapshot.sample.timestamp.formatted(.relative(presentation: .numeric))
    }

    /// Spoken as one sentence. VoiceOver reading "1013", "hPa", "falling" as three separate
    /// elements makes the user assemble the measurement themselves.
    private var accessibilityReading: Text {
        guard let snapshot = display.snapshot else { return Text("Pressure unknown") }

        guard let word = WatchTrendStyle.caption(for: snapshot.trend) else {
            return Text("Pressure \(readingText) hPa")
        }
        // The tendency is interpolated as a `Text` rather than concatenated with `+`, which
        // watchOS 26 deprecates, and rather than as a `String`, which would drop it out of
        // the localisation table the display copy goes through.
        return Text("Pressure \(readingText) hPa, \(Text(word))")
    }

    // MARK: - Sparkline

    /// The trailing six hours, as shape only — no axes, no labels, no numbers.
    ///
    /// It is here to answer "which way, and how sharply", which is the question the single
    /// figure above cannot answer. Anything that needs reading rather than glancing is on the
    /// trend screen behind it.
    @ViewBuilder
    private var sparkline: some View {
        let points = display.snapshot?.recent ?? []
        let domain = PressureChartDomain.padded(around: points.map(\.hectopascals))

        if points.count >= 2, let domain {
            Chart(points, id: \.timestamp) { point in
                LineMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Pressure", point.hectopascals)
                )
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round))
                .foregroundStyle(WatchPalette.chartLineOnDark)

                PointMark(
                    x: .value("Time", point.timestamp),
                    y: .value("Pressure", point.hectopascals)
                )
                .symbolSize(10)
                .foregroundStyle(WatchPalette.chartLineOnDark)
            }
            .chartXAxis(.hidden)
            .chartYAxis(.hidden)
            // Scaled to its own padded extent, not to a fixed pressure band: over six hours
            // the whole span is often under 3 hPa, and against a fixed axis that is a flat
            // line. The padding is the phone's, so the same afternoon is framed the same way
            // on both devices (`PressureChartDomain`).
            .chartYScale(domain: domain)
            .frame(height: 44)
            .padding(.vertical, 2)
        } else {
            // Under two points there is no line to draw. A single dot in an empty frame
            // reads as a broken chart, so the space simply stays empty.
            Color.clear.frame(height: 44)
        }
    }
}

// MARK: - Previews

#Preview("Falling") {
    NavigationStack {
        WatchNowView(display: .previewing(.previewFalling()))
    }
}

#Preview("Waiting for the phone") {
    NavigationStack {
        WatchNowView(display: PressureDisplayController())
    }
}
