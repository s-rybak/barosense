import Charts
import SwiftUI

/// The pressure chart card on the Now screen (Figma `7:671`).
///
/// ## Three deliberate departures from the design
///
/// 1. **No "Точність 87%" caption.** There is no model yet, so any number in that slot would
///    be invented. A figure describing how well the app knows the user is also the kind of
///    claim App Review reads closely (`.claude/skills/appstore_compliance/SKILL.md`), and it
///    has to be a measured value from the validation folds before it appears at all.
/// 2. **Hectopascals, not inHg.** The design prints `29.91 inHg`. Inches of mercury is a US
///    convention; the app is Ukrainian, and hPa is the domain unit everywhere else in this
///    codebase (`.claude/skills/swift_conventions/SKILL.md`). Rendering the one figure on
///    screen in a different unit from every stored value is how a unit bug survives review.
/// 3. **A time axis under the plot.** The design has none, and none was needed while the
///    window was fixed: the selected button named it. The plot scrolls now, so "which hours
///    am I looking at" stopped being answerable from the button alone, and an unlabelled
///    scrollable chart is a chart the user cannot locate themselves in. It costs the 18 pt
///    `Metrics.plotHeight` gained.
struct PressureChartCard: View {

    @State private var model: PressureChartModel

    private let collection: PressureCollectionController

    private enum Metrics {
        static let cornerRadius: CGFloat = 20
        static let borderWidth: CGFloat = 1
        static let padding: CGFloat = 17
        /// Gap between the four rows of the card.
        static let rowSpacing: CGFloat = 10
        /// Height of the plot region, label included. 92 pt of line as the design draws it,
        /// plus 18 pt for the time axis the scroll made necessary.
        static let plotHeight: CGFloat = 110
    }

    init(collection: PressureCollectionController) {
        self.collection = collection
        _model = State(initialValue: PressureChartModel(collection: collection))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text("Pressure chart")
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
        // A reading taken while this screen is open should appear. Watching the controller
        // beats a timer that ticks whether or not anything changed.
        .onChange(of: collection.lastUpdateAt) { _, _ in
            Task { await model.load() }
        }
    }

    // MARK: - Plot

    @ViewBuilder
    private var plot: some View {
        if model.series.isEmpty {
            PressureChartEmptyState(reason: model.emptyReason)
                .frame(height: Metrics.plotHeight)
        } else {
            PressureChartPlot(series: model.series)
                .frame(height: Metrics.plotHeight)
                // Rebuilds the chart when the range changes so `chartScrollPosition(initialX:)`
                // is applied again — it is an *initial* position and is otherwise ignored for
                // the life of the view. Without this, tapping "1h" after scrolling back a
                // week leaves the viewport wherever the previous range's offset landed, in a
                // plot that no longer reaches that far. Keyed on the range alone, so a reading
                // arriving every 15 min does not tear the chart down.
                .id(model.series.range)
        }
    }

    // MARK: - Value

    private var valueRow: some View {
        HStack(alignment: .firstTextBaseline) {
            model.latestValueText
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
        .accessibilityLabel(Text("Current pressure"))
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

    /// Selected range. Changing it re-slices and re-buckets what is already loaded — no
    /// store read, so the four buttons feel instant and cost nothing.
    var range: PressureChartRange = .oneHour {
        didSet {
            guard oldValue != range else { return }
            rebuild()
        }
    }

    private let collection: PressureCollectionController

    /// The deepest history any range scrolls over, kept so a range change is a re-slice. At
    /// one row per 15 min twelve days is ~1 150 samples of 40-odd bytes — under 50 kB, and
    /// cheaper to hold than to re-query on every button.
    private var samples: [PressureSample] = []

    init(collection: PressureCollectionController) {
        self.collection = collection
    }

    /// Why the plot has nothing to draw. Three states that need three different sentences,
    /// because each is acted on differently — or, in one case, not at all.
    var emptyReason: PressureChartEmptyReason {
        if !collection.isBarometerAvailable { return .noBarometer }
        return samples.isEmpty ? .noHistory : .nothingInRange
    }

    /// Reads the log and rebuilds the series. Safe to call repeatedly.
    func load() async {
        samples = await collection.samples(trailing: PressureChartRange.widest.historySeconds)
        rebuild()
    }

    private func rebuild() {
        series = PressureSeries.make(from: samples, range: range, asOf: .now)
    }

    /// The figure the card prints. One decimal, which is the resolution the barometer
    /// actually has — printing more would claim precision the sensor does not deliver.
    ///
    /// A `Text` rather than a `String`: the unit is copy (`hPa` / `гПа`) and has to come
    /// from the catalogue, while the figure itself must not — `Text(someString)` is
    /// verbatim and would leave the unit untranslated.
    var latestValueText: Text {
        guard let hectopascals = series.latest?.pressure.hectopascals else {
            return Text(verbatim: "—")
        }
        return Text("\(PressureFormat.hectopascals(hectopascals)) hPa")
    }

    /// `nil` when there is not enough history to say. The caption is then simply absent —
    /// never a guessed arrow.
    var trendText: LocalizedStringKey? {
        switch series.trend {
        case .rising: "↗ rising"
        case .falling: "↘ falling"
        case .steady: "→ steady"
        case .unknown: nil
        }
    }
}

// MARK: - Plot

/// The line itself (Figma `7:304`).
///
/// Sensor readings are drawn solid; forward-looking values are dashed and separated by the
/// "now" divider, so the two are never confusable at a glance — the same boundary the
/// feature registry draws between the barometer and WeatherKit families. The forecast side
/// stays empty until WeatherKit is wired, which is why the divider only appears with it.
///
/// The plot is twelve screenfuls wide and scrolls horizontally, opening on the newest
/// reading. Vertically it does not rescale as it scrolls — see `PressureSeries.valueDomainHPa`
/// for why a domain that refitted under the finger is worse than a slightly flatter line.
private struct PressureChartPlot: View {

    let series: PressureSeries

    /// Above this many points *per screenful* the dots become a smear and the line reads
    /// better alone. The design draws roughly seven of them, which is a six-hour window at
    /// the target cadence.
    ///
    /// Compared against `PressureChartRange.pointsPerScreen` rather than `observed.count`:
    /// the latter now counts twelve screenfuls, so every range but the narrowest would lose
    /// its dots to history the user is not even looking at.
    private static let maximumVisiblePoints = 12

    private static let lineWidth: CGFloat = 3

    var body: some View {
        Chart {
            ForEach(series.observed) { sample in
                LineMark(x: .value("Time", sample.timestamp),
                         y: .value("Pressure", sample.pressure.hectopascals),
                         series: .value("Series", "observed"))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Palette.chartLine)
            }

            if series.range.pointsPerScreen <= Self.maximumVisiblePoints {
                ForEach(series.observed) { sample in
                    PointMark(x: .value("Time", sample.timestamp),
                              y: .value("Pressure", sample.pressure.hectopascals))
                    .symbolSize(40)
                    .foregroundStyle(Palette.chartLine)
                }
            }

            if !series.forecast.isEmpty {
                RuleMark(x: .value("Now", series.now))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    .foregroundStyle(Palette.controlBorder)
                    .annotation(position: .top, spacing: 2) {
                        Text("now")
                            .font(Typography.chartAnnotation)
                            .foregroundStyle(Palette.inkSubtle)
                    }

                ForEach(series.forecast) { sample in
                    LineMark(x: .value("Time", sample.timestamp),
                             y: .value("Pressure", sample.pressure.hectopascals),
                             series: .value("Series", "forecast"))
                    .interpolationMethod(.catmullRom)
                    .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, dash: [5, 5]))
                    .foregroundStyle(Palette.chartLine.opacity(0.65))
                }
            }
        }
        // Labels only — no grid lines, no ticks — so the axis says where the line is without
        // becoming furniture the design never had. `AxisValueLabel()` with no format is
        // deliberate: Swift Charts picks the format from the stride it chose, so the narrow
        // ranges read as times and the day range as dates, without this file inventing a
        // per-range format table.
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) {
                AxisValueLabel()
                    .font(Typography.chartAnnotation)
                    .foregroundStyle(Palette.inkSubtle)
            }
        }
        .chartYAxis(.hidden)
        // With scrolling on, `chartXScale` is the whole scrollable extent and
        // `chartXVisibleDomain` is the viewport onto it. Both are needed: the scale alone
        // would squeeze twelve screenfuls into 92 pt.
        .chartXScale(domain: series.timeDomain)
        .chartYScale(domain: yDomain)
        .chartScrollableAxes(.horizontal)
        .chartXVisibleDomain(length: series.visibleSeconds)
        .chartScrollPosition(initialX: series.initialScrollX)
        .chartLegend(.hidden)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text("Pressure chart"))
        .accessibilityValue(accessibilitySummary)
    }

    /// Falls back to a nominal sea-level band when there is nothing to measure from, so the
    /// chart still has a coordinate space. Unreachable in practice — the empty series takes
    /// the placeholder path instead — but a `Chart` with no domain draws nothing at all.
    private var yDomain: ClosedRange<Double> {
        series.valueDomainHPa ?? 1000...1020
    }

    /// VoiceOver gets the two facts the line carries: how many readings, and over how long.
    /// Reading out every point would be unusable.
    ///
    /// `readingCount`, not `observed.count` — on the day range the line is hourly means over
    /// four times as many readings, and announcing the smaller number would understate the
    /// history by 4×. It covers the whole scrollable extent, which is the honest scope:
    /// VoiceOver cannot scroll the plot, so a summary of the viewport alone would describe a
    /// twelfth of what is there.
    ///
    /// The span is formatted rather than printed as hours: the day range now covers twelve
    /// of them, and "over 288 h" is a number VoiceOver can read but nobody can picture.
    /// `Duration.UnitsFormatStyle` also gets the Ukrainian plural agreement right, which
    /// string interpolation would not.
    ///
    /// The count is stated as a labelled figure rather than as "N readings", because
    /// Ukrainian agrees the noun with the number in three forms and a plural rule in the
    /// catalogue would be a translation defect waiting to happen for a string nobody sees.
    private var accessibilitySummary: Text {
        let count = series.readingCount
        guard let first = series.observed.first, let last = series.observed.last else {
            return Text("No data")
        }
        let span = Duration.seconds(last.timestamp.timeIntervalSince(first.timestamp))
        let formattedSpan = span.formatted(.units(allowed: [.days, .hours], width: .wide))
        return Text("Readings: \(count) · \(formattedSpan)")
    }
}

/// Why the plot is empty. Three states, three different sentences.
///
/// They are not interchangeable. `noBarometer` is permanent and the user can do nothing
/// about it — an iPad has no pressure sensor — so telling them to wait would be telling them
/// to wait forever. `noHistory` resolves itself in minutes. `nothingInRange` is fixed by
/// pressing a wider button: iOS grants background wakes rather than scheduling them, so a
/// phone left alone overnight can have nothing at all inside the last hour.
enum PressureChartEmptyReason {
    case noBarometer
    case noHistory
    case nothingInRange
}

/// Shown when the plot has nothing to draw.
///
/// Deliberately not an error in any of its wordings: every one of the three is an ordinary
/// state of a working app. None says anything about health, and none promises when data will
/// appear.
private struct PressureChartEmptyState: View {

    let reason: PressureChartEmptyReason

    var body: some View {
        ZStack {
            // A flat hairline where the line will be, so the card keeps its shape instead of
            // collapsing into a gap.
            HorizontalRule()
                .stroke(style: StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .foregroundStyle(Palette.controlBorder)
                .frame(height: 1)

            message
                .font(Typography.cardNote)
                .foregroundStyle(Palette.inkSubtle)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.cardSurface)
        }
        .frame(maxWidth: .infinity)
    }

    /// Every literal sits at a `Text` call site rather than behind a `String` so the string
    /// catalog keeps extracting them. A `Text(someString)` is not a localisable key.
    private var message: Text {
        switch reason {
        case .noBarometer: Text("This device has no barometer")
        case .noHistory: Text("Readings appear once the first samples land")
        case .nothingInRange: Text("Nothing recorded in this range — try a wider one")
        }
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

/// The range buttons (Figma `7:682`).
///
/// Four, as the design draws them. On the narrowest device this app runs on — 375 pt — the
/// track has 375 − 2×20 screen margin − 2×17 card padding − 2×4 track padding − 3×4 gaps =
/// 281 pt to divide, so 70 pt per button against a widest label ("Day") of roughly 32 pt
/// at `segmentLabel`'s 12 pt.
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

    private static func title(for range: PressureChartRange) -> LocalizedStringKey {
        switch range {
        case .oneHour: "1h"
        case .threeHours: "3h"
        case .sixHours: "6h"
        case .day: "Day"
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

#Preview("Nothing in this range") {
    PressureChartPreviewHost(series: .empty(range: .oneHour), emptyReason: .nothingInRange)
}

#Preview("No barometer") {
    PressureChartPreviewHost(series: .empty(range: .oneHour), emptyReason: .noBarometer)
}

/// Renders the card's pieces against a fixed series. The card itself needs a controller and
/// therefore a store, which a preview has no business opening.
private struct PressureChartPreviewHost: View {

    let series: PressureSeries

    /// Which of the three empty messages to render. The card derives this from the log and
    /// the device; a preview has neither, so it is stated.
    var emptyReason: PressureChartEmptyReason = .noHistory

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Pressure chart")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            Group {
                if series.isEmpty {
                    PressureChartEmptyState(reason: emptyReason)
                } else {
                    PressureChartPlot(series: series)
                }
            }
            .frame(height: 110)

            latestText
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

    private var latestText: Text {
        guard let hectopascals = series.latest?.pressure.hectopascals else {
            return Text(verbatim: "—")
        }
        return Text("\(PressureFormat.hectopascals(hectopascals)) hPa")
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
