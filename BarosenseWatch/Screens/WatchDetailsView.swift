import SwiftUI

/// The two figures behind the main screen, as gauges (Figma `W3`).
///
/// ## What the second gauge is, and what it is not
///
/// The frame puts a **forecast risk percentage** in the right-hand tile ("87% · in 2h 30m").
/// That tile is not implemented, for two independent reasons, either of which alone would be
/// enough:
///
/// 1. **There is no model.** Every forecast feature in `.claude/context/ml-spec.md` §2.2 is
///    still marked `planned`, and nothing in the repo produces a risk value. A number drawn
///    here today would be invented.
/// 2. **It could not ship in that form even with a model behind it.** A percentage attached
///    to a named condition, counting down to an hour, is model output presented as certainty
///    — forbidden by `.claude/skills/appstore_compliance/SKILL.md` and by
///    `.claude/context/ml-spec.md` §6, which requires a graded risk state instead.
///
/// What is in the tile instead is the three-hour tendency in hPa: a real measurement, already
/// computed on the phone from the raw log, and the signal the domain notes single out as the
/// one that matters physiologically. When the forecast exists, this is where its graded state
/// goes — the layout is the frame's.
struct WatchDetailsView: View {

    let snapshot: PressureDisplaySnapshot?

    var body: some View {
        ScrollView {
            HStack(spacing: 6) {
                pressureTile

                tendencyTile
            }
            .padding(.horizontal, 2)
        }
        .background(WatchPalette.surface)
        .navigationTitle("Readings")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Tiles

    private var pressureTile: some View {
        WatchGaugeTile(
            value: snapshot.map { PressureFormat.roundedHectopascals($0.sample.pressure.hectopascals) },
            unit: "hPa",
            caption: "Pressure",
            fraction: snapshot.map { Self.band(for: $0.sample.pressure.hectopascals) },
            tint: WatchPalette.chartLineOnDark,
            accessibilityValue: snapshot.map {
                String(localized: "\(PressureFormat.roundedHectopascals($0.sample.pressure.hectopascals)) hectopascals")
            }
        )
    }

    private var tendencyTile: some View {
        let delta = snapshot?.deltaHPaPer3h

        return WatchGaugeTile(
            value: delta.map(PressureFormat.signedHectopascals),
            unit: "hPa",
            caption: "Past 3 h",
            fraction: delta.map { min(abs($0) / Self.strongChangeHPa, 1) },
            tint: WatchTrendStyle.tint(for: snapshot?.trend ?? .unknown),
            accessibilityValue: delta.map {
                String(localized: "\(PressureFormat.signedHectopascals($0)) hectopascals over three hours")
            }
        )
    }

    // MARK: - Scales

    /// Where a reading sits on the ring, 0 to 1.
    ///
    /// **A display scale, not a judgement.** 980–1040 hPa is the band ordinary sea-level
    /// weather lives in; it is narrower than `Pressure.isPlausible` (800–1100), which has to
    /// admit a mountain pass and a sensor fault and would leave every real reading within a
    /// few degrees of the same arc. Nothing reads a position on this ring as good or bad,
    /// and the figure printed inside it is the measurement itself.
    private static let displayBand: ClosedRange<Double> = 980...1040

    /// The change at which the ring is full.
    ///
    /// Six hPa in three hours is a fast-moving front — roughly six times
    /// `PressureTrend.significantChangeHPa`, the point at which the tendency stops being
    /// "steady". Chosen from that reasoning and not from a measured distribution of this
    /// app's own traces, exactly as the threshold it is derived from was; re-derive both
    /// together once there is real history.
    private static let strongChangeHPa: Double = 6

    private static func band(for hectopascals: Double) -> Double {
        let span = displayBand.upperBound - displayBand.lowerBound
        return min(max((hectopascals - displayBand.lowerBound) / span, 0), 1)
    }
}

// MARK: - Gauge tile

/// One figure inside a ring, with the noun that names it underneath.
///
/// `Gauge` rather than a hand-drawn `Circle().trim(...)`: the system style already handles
/// Dynamic Type, the Always-On dimmed rendering and VoiceOver, and a hand-rolled ring gets
/// none of those for free.
private struct WatchGaugeTile: View {

    /// `nil` before the phone has published anything. The ring then draws empty and the
    /// figure is a dash — no reading is a state, not an error.
    let value: String?

    /// Already localised by the caller, which is why this is a `String` and not a
    /// `LocalizedStringKey`: it interpolates a formatted measurement, so the caller is the
    /// only place that can put the number and its noun together in the right order.
    let unit: LocalizedStringKey
    let caption: LocalizedStringKey
    let fraction: Double?
    let tint: Color
    let accessibilityValue: String?

    var body: some View {
        VStack(spacing: 4) {
            Gauge(value: fraction ?? 0) {
                EmptyView()
            } currentValueLabel: {
                VStack(spacing: -1) {
                    Text(value ?? "—")
                        .font(WatchTypography.gaugeValue)
                        .monospacedDigit()
                        .foregroundStyle(WatchPalette.ink)

                    Text(unit)
                        .font(.system(size: 9))
                        .foregroundStyle(WatchPalette.inkMuted)
                }
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            }
            .gaugeStyle(.accessoryCircular)
            .tint(tint)

            Text(caption)
                .font(WatchTypography.caption)
                .foregroundStyle(WatchPalette.inkMuted)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(WatchPalette.cardSurface)
        )
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(caption)
        .accessibilityValue(accessibilityValue ?? String(localized: "no reading"))
    }
}

#Preview("Falling") {
    NavigationStack {
        WatchDetailsView(snapshot: WatchContext.previewFalling().pressure)
    }
}

#Preview("No data") {
    NavigationStack {
        WatchDetailsView(snapshot: nil)
    }
}
