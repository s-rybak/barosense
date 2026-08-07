import Charts
import SwiftUI

/// The pressure chart card on the Now screen (Figma `7:671`).
///
/// ## Two deliberate departures from the design
///
/// 1. **No "Точність 87%" caption.** There is no model yet, so any number in that slot would
///    be invented. A figure describing how well the app knows the user is also the kind of
///    claim App Review reads closely (`.claude/skills/appstore_compliance/SKILL.md`), and it
///    has to be a measured value from the validation folds before it appears at all.
/// 2. **Hectopascals, not inHg.** The design prints `29.91 inHg`. Inches of mercury is a US
///    convention; the app is Ukrainian, and hPa is the domain unit everywhere else in this
///    codebase (`.claude/skills/swift_conventions/SKILL.md`). Rendering the one figure on
///    screen in a different unit from every stored value is how a unit bug survives review.
struct PressureChartCard: View {

    @State private var model: PressureChartModel

    private let ingest: PressureIngestController

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1
        static let padding: CGFloat = 17
        /// Gap between the four rows of the card.
        static let rowSpacing: CGFloat = 10
        /// Height of the plot region, label included.
        static let plotHeight: CGFloat = 92
    }

    init(ingest: PressureIngestController) {
        self.ingest = ingest
        _model = State(initialValue: PressureChartModel(ingest: ingest))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text("Графік тиску")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            plot

            valueRow

            PressureRangeSelector(selection: $model.range)
        }
        .padding(Metrics.padding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.cardSurface)
        }
        // `strokeBorder` so the design's 1 pt outline sits inside the card's box rather than
        // straddling it — same reasoning as `HealthMetricsRow`.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: Metrics.borderWidth)
        }
        .task { await model.load() }
        // A reading that lands from the watch while this screen is open should appear.
        // Watching the controller beats a timer that ticks whether or not anything changed.
        .onChange(of: ingest.lastIngestAt) { _, _ in
            Task { await model.load() }
        }
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        if model.series.isEmpty {
            PressureChartEmptyState()
                .frame(height: Metrics.plotHeight)
        } else {
            PressureChartPlot(series: model.series)
                .frame(height: Metrics.plotHeight)
        }
    }

    // MARK: - Value

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(model.latestValueText)
                .font(Typography.pressureValue)
                .foregroundStyle(Palette.heading)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.6)

            Spacer(minLength: 8)

            if let trend = model.trendText {
                Text(trend)
                    .font(Typography.captionEmphasis)
                    .foregroundStyle(Palette.inkSubtle)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Поточний тиск"))
    }
}

/// State behind the card.
///
/// Holds no domain logic: what the line, the figure and the caption mean is decided by
/// `PressureSeries.make` in `Shared/`, where a test can reach it without a screen.
@MainActor
@Observable
final class PressureChartModel {

    private(set) var series: PressureSeries = .empty()

    /// Selected range. Changing it re-slices what is already loaded — no store read, so the
    /// four buttons feel instant and cost nothing.
    var range: PressureChartRange = .oneHour {
        didSet {
            guard oldValue != range else { return }
            rebuild()
        }
    }

    private let ingest: PressureIngestController

    /// The full widest window, kept so a range change is a re-slice. At one row an hour this
    /// is a couple of dozen samples — cheaper to hold than to re-query four times.
    private var samples: [PressureSample] = []

    init(ingest: PressureIngestController) {
        self.ingest = ingest
    }

    /// Reads the log and rebuilds the series. Safe to call repeatedly.
    func load() async {
        samples = await ingest.samples(trailing: PressureChartRange.widest.seconds)
        rebuild()
    }

    private func rebuild() {
        series = PressureSeries.make(from: samples, range: range, asOf: .now)
    }

    /// The figure the card prints. One decimal, which is the resolution the barometer
    /// actually has — printing more would claim precision the sensor does not deliver.
    var latestValueText: String {
        guard let hectopascals = series.latest?.pressure.hectopascals else { return "—" }
        return "\(PressureFormat.hectopascals(hectopascals)) гПа"
    }

    /// `nil` when there is not enough history to say. The caption is then simply absent —
    /// never a guessed arrow.
    var trendText: String? {
        switch series.trend {
        case .rising: "↗ росте"
        case .falling: "↘ падає"
        case .steady: "→ стабільно"
        case .unknown: nil
        }
    }
}

// MARK: - Plot

/// The line itself (Figma `7:304`).
///
/// Sensor readings are drawn solid; forward-looking values are dashed and separated by the
/// "зараз" divider, so the two are never confusable at a glance — the same boundary the
/// feature registry draws between the barometer and WeatherKit families. The forecast side
/// stays empty until WeatherKit is wired, which is why the divider only appears with it.
private struct PressureChartPlot: View {

    let series: PressureSeries

    /// Above this many readings the dots become a smear and the line reads better alone.
    /// The design draws roughly seven of them, which is a six-hour window at the target
    /// cadence.
    private static let maximumVisiblePoints = 12

    private static let lineWidth: CGFloat = 3

    var body: some View {
        Chart {
            ForEach(series.observed) { sample in
                LineMark(x: .value("Час", sample.timestamp),
                         y: .value("Тиск", sample.pressure.hectopascals),
                         series: .value("Ряд", "observed"))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Palette.chartLine)
            }

            if series.observed.count <= Self.maximumVisiblePoints {
                ForEach(series.observed) { sample in
                    PointMark(x: .value("Час", sample.timestamp),
                              y: .value("Тиск", sample.pressure.hectopascals))
                    .symbolSize(40)
                    .foregroundStyle(Palette.chartLine)
                }
            }

            if !series.forecast.isEmpty {
                RuleMark(x: .value("Зараз", series.now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Palette.controlBorder)
                    .annotation(position: .top, spacing: 2) {
                        Text("зараз")
                            .font(Typography.chartAnnotation)
                            .foregroundStyle(Palette.inkSubtle)
                    }

                ForEach(series.forecast) { sample in
                    LineMark(x: .value("Час", sample.timestamp),
                             y: .value("Тиск", sample.pressure.hectopascals),
                             series: .value("Ряд", "forecast"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [5, 5]))
                    .foregroundStyle(Palette.chartLine.opacity(0.65))
                }
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartXScale(domain: series.timeDomain)
        .chartYScale(domain: yDomain)
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Графік тиску"))
        .accessibilityValue(Text(accessibilitySummary))
    }

    /// Falls back to a nominal sea-level band when there is nothing to measure from, so the
    /// chart still has a coordinate space. Unreachable in practice — the empty series takes
    /// the placeholder path instead — but a `Chart` with no domain draws nothing at all.
    private var yDomain: ClosedRange<Double> {
        series.valueDomainHPa ?? 1000...1020
    }

    /// VoiceOver gets the two facts the line carries: how many readings, and over how long.
    /// Reading out every point would be unusable.
    private var accessibilitySummary: String {
        let count = series.observed.count
        guard let first = series.observed.first, let last = series.observed.last else {
            return "Немає даних"
        }
        let hours = Int((last.timestamp.timeIntervalSince(first.timestamp) / 3600).rounded())
        return "\(count) вимірів за \(hours) год"
    }
}

/// Shown before the first reading arrives from the watch.
///
/// Deliberately not an error: an empty log is the ordinary state on a fresh install, on a
/// phone whose watch has not been worn yet, and on any device without a barometer.
private struct PressureChartEmptyState: View {

    var body: some View {
        ZStack {
            // A flat hairline where the line will be, so the card keeps its shape instead of
            // collapsing into a gap.
            HorizontalRule()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Palette.controlBorder)
                .frame(height: 1)

            Text("Дані з’являться після перших вимірів з годинника")
                .font(Typography.cardNote)
                .foregroundStyle(Palette.inkSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.cardSurface)
        }
        .frame(maxWidth: .infinity)
    }
}

/// A single horizontal line across its frame. `Rectangle` at one point tall would stroke all
/// four edges, which leaves visible stubs where the dash pattern turns the corners.
private struct HorizontalRule: Shape {

    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

// MARK: - Range selector

/// The four range buttons (Figma `7:682`).
private struct PressureRangeSelector: View {

    @Binding var selection: PressureChartRange

    private enum Metrics {
        static let trackRadius: CGFloat = 12
        static let itemRadius: CGFloat = 9
        static let trackPadding: CGFloat = 4
        static let itemSpacing: CGFloat = 4
        static let itemTopPadding: CGFloat = 12
        static let itemBottomPadding: CGFloat = 9
    }

    var body: some View {
        HStack(spacing: Metrics.itemSpacing) {
            ForEach(PressureChartRange.allCases) { range in
                Button {
                    selection = range
                } label: {
                    Text(Self.title(for: range))
                        .font(range == selection ? Typography.segmentLabelSelected : Typography.segmentLabel)
                        .foregroundStyle(range == selection ? Palette.heading : Palette.inkSubtle)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: .infinity)
                        .padding(.top, Metrics.itemTopPadding)
                        .padding(.bottom, Metrics.itemBottomPadding)
                        .background {
                            if range == selection {
                                RoundedRectangle(cornerRadius: Metrics.itemRadius, style: .continuous)
                                    .fill(Palette.cardSurface)
                                    .shadow(color: .black.opacity(0.08), radius: 0.75, x: 0, y: 1)
                            }
                        }
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(range == selection ? [.isButton, .isSelected] : .isButton)
            }
        }
        .padding(Metrics.trackPadding)
        .background {
            RoundedRectangle(cornerRadius: Metrics.trackRadius, style: .continuous)
                .fill(Palette.segmentedTrack)
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private static func title(for range: PressureChartRange) -> String {
        switch range {
        case .oneHour: "1год"
        case .threeHours: "3год"
        case .sixHours: "6год"
        case .day: "День"
        }
    }
}

// MARK: - Previews

#Preview("With readings") {
    PressureChartPreviewHost(series: .sampleFalling)
}

#Preview("Nothing recorded") {
    PressureChartPreviewHost(series: .empty(range: .oneHour))
}

/// Renders the card's pieces against a fixed series. The card itself needs a controller and
/// therefore a store, which a preview has no business opening.
private struct PressureChartPreviewHost: View {

    let series: PressureSeries

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Графік тиску")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            Group {
                if series.isEmpty {
                    PressureChartEmptyState()
                } else {
                    PressureChartPlot(series: series)
                }
            }
            .frame(height: 92)

            Text(latestText)
                .font(Typography.pressureValue)
                .foregroundStyle(Palette.heading)

            PressureRangeSelector(selection: .constant(series.range))
        }
        .padding(17)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Palette.cardSurface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
        .padding(20)
        .background(Palette.surface)
    }

    private var latestText: String {
        guard let hectopascals = series.latest?.pressure.hectopascals else { return "—" }
        return "\(PressureFormat.hectopascals(hectopascals)) гПа"
    }
}

private extension PressureSeries {

    /// Six hours of gently falling pressure, one reading an hour.
    static var sampleFalling: PressureSeries {
        let now = Date.now
        let values: [Double] = [1016.2, 1015.8, 1015.1, 1014.2, 1013.4, 1012.6, 1012.1]
        let samples = values.enumerated().map { index, hectopascals in
            PressureSample(timestamp: now.addingTimeInterval(TimeInterval(index - 6) * 3600),
                           pressure: Pressure(hectopascals: hectopascals))
        }
        return .make(from: samples, range: .sixHours, asOf: now)
    }
}
