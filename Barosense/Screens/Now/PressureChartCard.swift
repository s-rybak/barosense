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

    /// Bumped by the root when a check-in is written, so the markers are re-read without the
    /// card being rebuilt — a rebuild would also reset the range the user picked.
    private let checkInRevision: Int

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

    init(collection: PressureCollectionController,
         checkIns: any CheckInStore,
         checkInRevision: Int = 0) {
        self.checkInRevision = checkInRevision
        self.collection = collection
        _model = State(initialValue: PressureChartModel(collection: collection,
                                                        checkIns: checkIns))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.rowSpacing) {
            Text("Графік тиску")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            plot

            valueRow

            // Only once there is a dot to explain. A legend for something not on screen is
            // noise, and this card already carries four rows.
            if !model.series.checkIns.isEmpty {
                Text("Coloured dots are your check-ins")
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.inkSubtle)
            }

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
        .task(id: checkInRevision) { await model.load() }
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
                // the life of the view. Without this, tapping "1год" after scrolling back a
                // week leaves the viewport wherever the previous range's offset landed, in a
                // plot that no longer reaches that far. Keyed on the range alone, so a reading
                // arriving every 15 min does not tear the chart down.
                .id(model.series.range)
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

    /// Selected range. Changing it re-slices and re-buckets what is already loaded — no
    /// store read, so the four buttons feel instant and cost nothing.
    var range: PressureChartRange = .oneHour {
        didSet {
            guard oldValue != range else { return }
            rebuild()
        }
    }

    private let collection: PressureCollectionController
    private let checkInStore: any CheckInStore

    /// The deepest history any range scrolls over, kept so a range change is a re-slice. At
    /// one row per 15 min twelve days is ~1 150 samples of 40-odd bytes — under 50 kB, and
    /// cheaper to hold than to re-query on every button.
    private var samples: [PressureSample] = []

    /// The same window's check-ins, held for the same reason. Far fewer rows: a few a day at
    /// the cadence the cold-start arithmetic assumes, so tens over twelve days.
    private var checkIns: [CheckIn] = []

    init(collection: PressureCollectionController, checkIns: any CheckInStore) {
        self.collection = collection
        self.checkInStore = checkIns
    }

    /// Why the plot has nothing to draw. Three states that need three different sentences,
    /// because each is acted on differently — or, in one case, not at all.
    var emptyReason: PressureChartEmptyReason {
        if !collection.isBarometerAvailable { return .noBarometer }
        return samples.isEmpty ? .noHistory : .nothingInRange
    }

    /// Reads both logs and rebuilds the series. Safe to call repeatedly.
    func load() async {
        let now = Date.now
        samples = await collection.samples(trailing: PressureChartRange.widest.historySeconds)
        checkIns = await loadCheckIns(asOf: now)
        rebuild()
    }

    /// The check-ins the widest range can reach. Half-open at `now`, which is the instant
    /// before either read started — so a check-in saved a moment ago is strictly earlier and
    /// is picked up, and one saved *during* the read arrives on the next load rather than
    /// half-appearing in this one.
    ///
    /// A failure reads as no check-ins. The chart is a pressure chart that also marks
    /// check-ins; there is nothing useful it could say about a store it could not open, and
    /// the empty states below all describe the pressure log instead.
    private func loadCheckIns(asOf now: Date) async -> [CheckIn] {
        let window = now.addingTimeInterval(-PressureChartRange.widest.historySeconds)..<now
        return (try? await checkInStore.checkIns(in: window)) ?? []
    }

    private func rebuild() {
        series = PressureSeries.make(from: samples, checkIns: checkIns, range: range, asOf: .now)
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
                LineMark(x: .value("Час", sample.timestamp),
                         y: .value("Тиск", sample.pressure.hectopascals),
                         series: .value("Ряд", "observed"))
                .interpolationMethod(.catmullRom)
                .lineStyle(StrokeStyle(lineWidth: Self.lineWidth, lineCap: .round, lineJoin: .round))
                .foregroundStyle(Palette.chartLine)
            }

            if series.range.pointsPerScreen <= Self.maximumVisiblePoints {
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

            // Declared last, so the dots land on top of every line rather than under one.
            //
            // Unlike the reading dots above, these are never thinned out by range: a
            // check-in is the user's own entry and a few a day is the whole density, so the
            // smear the `maximumVisiblePoints` gate guards against cannot happen here.
            ForEach(series.checkIns) { marker in
                PointMark(x: .value("Час", marker.timestamp),
                          y: .value("Тиск", marker.hectopascals))
                .symbol {
                    CheckInDot(colour: Palette.intensity(marker.intensity))
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
    ///
    /// `readingCount`, not `observed.count` — on the day range the line is hourly means over
    /// four times as many readings, and announcing the smaller number would understate the
    /// history by 4×. It covers the whole scrollable extent, which is the honest scope:
    /// VoiceOver cannot scroll the plot, so a summary of the viewport alone would describe a
    /// twelfth of what is there.
    ///
    /// The span is formatted rather than printed as hours: the day range now covers twelve
    /// of them, and "за 288 год" is a number VoiceOver can read but nobody can picture.
    /// `Duration.UnitsFormatStyle` also gets the Ukrainian plural agreement right, which
    /// string interpolation would not.
    private var accessibilitySummary: String {
        let count = series.readingCount
        guard let first = series.observed.first, let last = series.observed.last else {
            return "Немає даних"
        }
        let span = Duration.seconds(last.timestamp.timeIntervalSince(first.timestamp))
        return "\(count) вимірів за \(span.formatted(.units(allowed: [.days, .hours], width: .wide)))"
    }
}

/// One check-in on the plot, in the colour of the point the user chose on the Log screen.
///
/// A ring in the card's own fill, not a bare disc: the pressure line is 3 pt of saturated
/// blue and a 10 pt dot sitting on it would merge with it wherever the two colours are close
/// in value. The ring is what keeps the dot legible against the line it marks.
///
/// A custom symbol rather than `symbolSize` + `foregroundStyle`, because that pair cannot
/// draw the ring — and because a `foregroundStyle` per mark would have Swift Charts build a
/// five-entry colour scale and a legend out of the five scores.
private struct CheckInDot: View {

    let colour: Color

    private enum Metrics {
        static let diameter: CGFloat = 10
        static let ringWidth: CGFloat = 2
    }

    var body: some View {
        Circle()
            .fill(colour)
            .frame(width: Metrics.diameter, height: Metrics.diameter)
            .padding(Metrics.ringWidth)
            .background {
                Circle().fill(Palette.cardSurface)
            }
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
        case .noBarometer: Text("Цей пристрій не має барометра")
        case .noHistory: Text("Дані з’являться після перших вимірів")
        case .nothingInRange: Text("За цей проміжок вимірів немає — оберіть ширший")
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
/// 281 pt to divide, so 70 pt per button against a widest label ("День") of roughly 32 pt
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

#Preview("With check-ins") {
    PressureChartPreviewHost(series: .sampleFallingWithCheckIns)
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
            Text("Графік тиску")
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
        return .make(from: fallingSamples(asOf: now), range: .sixHours, asOf: now)
    }

    /// The same six hours with three check-ins on it, one per colour band, so the ramp and
    /// the ring against the line can both be looked at.
    static var sampleFallingWithCheckIns: PressureSeries {
        let now = Date.now
        let checkIns = [
            CheckIn(timestamp: now.addingTimeInterval(-5 * 3600),
                    intensity: CheckInIntensity(clamping: 1)),
            CheckIn(timestamp: now.addingTimeInterval(-3 * 3600 - 1800),
                    intensity: CheckInIntensity(clamping: 6)),
            CheckIn(timestamp: now.addingTimeInterval(-1200),
                    intensity: CheckInIntensity(clamping: 10))
        ]
        return .make(from: fallingSamples(asOf: now),
                     checkIns: checkIns,
                     range: .sixHours,
                     asOf: now)
    }

    private static func fallingSamples(asOf now: Date) -> [PressureSample] {
        let values: [Double] = [1016.2, 1015.8, 1015.1, 1014.2, 1013.4, 1012.6, 1012.1]
        return values.enumerated().map { index, hectopascals in
            PressureSample(timestamp: now.addingTimeInterval(TimeInterval(index - 6) * 3600),
                           pressure: Pressure(hectopascals: hectopascals))
        }
    }
}
