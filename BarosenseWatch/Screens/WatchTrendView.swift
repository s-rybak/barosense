import Charts
import SwiftUI

/// The plotted window behind the main screen's number (Figma `W1b`).
///
/// Six hours, bucketed to half-hourly points on the phone (`PressureWatchSeries`). One fixed
/// window and no range selector: the phone's chart has four ranges and twelve screenfuls of
/// scrollback because it has the room, and reproducing that on a wrist would be a control to
/// operate rather than a thing to look at.
struct WatchTrendView: View {

    let snapshot: PressureDisplaySnapshot?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                header

                plot
            }
            .padding(.horizontal, 2)
        }
        .background(WatchPalette.surface)
        .navigationTitle("Pressure")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: - Header

    /// The current figure, labelled as current. The plot's right edge is the same reading,
    /// and saying so is what stops the line's end from being read as a forecast.
    @ViewBuilder
    private var header: some View {
        if let snapshot {
            let reading = PressureFormat.hectopascals(snapshot.sample.pressure.hectopascals)

            HStack(spacing: 4) {
                Text(reading)
                    .font(WatchTypography.gaugeValue)
                    .monospacedDigit()
                    .foregroundStyle(WatchTrendStyle.tint(for: snapshot.trend))

                Text("· Now")
                    .font(WatchTypography.caption)
                    .foregroundStyle(WatchPalette.inkMuted)

                Spacer(minLength: 4)

                // How far back the line reaches. The x-axis fits one timestamp on a 40 mm
                // screen, which anchors the plot but does not say how wide it is — and a
                // six-hour fall and a six-day one are very different pieces of news.
                Text("6 h")
                    .font(WatchTypography.caption)
                    .foregroundStyle(WatchPalette.inkMuted)
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Now \(reading) hPa, over the past 6 hours")
        }
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        let points = snapshot?.recent ?? []
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
                .symbolSize(18)
                .foregroundStyle(WatchPalette.chartLineOnDark)
            }
            .chartYAxis {
                // Two labels, at the extremes of the drawn data. Enough to make the plot a
                // measurement rather than a shape; more would be a grid on a 90 pt canvas.
                AxisMarks(position: .leading, values: .automatic(desiredCount: 2)) { value in
                    AxisValueLabel {
                        if let hectopascals = value.as(Double.self) {
                            // The shared formatter, not the axis default: `Double`'s own
                            // description groups thousands, and a four-digit pressure printed
                            // as `1,015` — or as `1.015` in a locale that groups with a period
                            // — reads as a decimal point in the wrong place. `PressureFormat`
                            // exists for exactly this and turns grouping off.
                            Text(PressureFormat.roundedHectopascals(hectopascals))
                                .font(.system(size: 9))
                                .foregroundStyle(WatchPalette.inkMuted)
                        }
                    }
                }
            }
            .chartXAxis {
                // Two labels, and no more. Three 12-hour timestamps do not fit across a 40 mm
                // screen and run into each other; the two ends are what the window needs to
                // say anyway.
                AxisMarks(values: .automatic(desiredCount: 2)) { value in
                    AxisValueLabel {
                        if let date = value.as(Date.self) {
                            Text(date, format: .dateTime.hour().minute())
                                .font(.system(size: 9))
                                .foregroundStyle(WatchPalette.inkMuted)
                        }
                    }
                }
            }
            // The phone's padding rule, so the two devices frame the same readings the same
            // way — see `PressureChartDomain`.
            .chartYScale(domain: domain)
            .frame(height: 96)
        } else {
            emptyPlot
        }
    }

    /// Under two points there is nothing to draw a line between.
    ///
    /// Worded as a wait rather than as a failure, because that is what it is: the phone
    /// records roughly every fifteen minutes, so a fresh install has a line within the hour
    /// and there is nothing for the user to fix.
    private var emptyPlot: some View {
        VStack(spacing: 6) {
            Image(systemName: "chart.xyaxis.line")
                .imageScale(.large)
                .foregroundStyle(WatchPalette.inkMuted)

            Text("The trend appears once your phone has recorded a few readings")
                .font(WatchTypography.caption)
                .foregroundStyle(WatchPalette.inkMuted)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

#Preview("Six hours") {
    NavigationStack {
        WatchTrendView(snapshot: WatchContext.previewFalling().pressure)
    }
}

#Preview("Empty") {
    NavigationStack {
        WatchTrendView(snapshot: nil)
    }
}
