import SwiftUI

// The four sections of the document that draw something more than a stack of labels: the
// chart, the two ranked lists, and the log table. Split out of `ReportDocument.swift` to keep
// both files inside the 900-line limit in `.swiftlint.yml`.

// MARK: - Trace

/// Two series on one timeline: what the barometer averaged each day, and the highest check-in
/// the user reported that day.
///
/// **Two bands, not one line with dots on it.** Placing a check-in marker onto the pressure
/// line — which is what the Now screen's chart does — puts the two values at the same point and
/// invites the reader to join them. On a screen the user is looking at their own data; in a
/// document handed to somebody else, that visual join is the claim this app does not make. Two
/// stacked bands with their own scales show the same information and assert nothing, and the
/// check-in band also shows every check-in, including those on days the phone recorded no
/// pressure at all.
///
/// Hand-drawn with `Path` rather than Swift Charts, which the Now screen uses. A chart in this
/// document has to render identically at measurement time and at draw time inside
/// `ImageRenderer`, with no interaction, no gesture and no axis inference — and it has to do it
/// over up to 366 daily points at 507 pt wide. A path over a fixed domain is the whole of what
/// is needed here.
struct ReportTraceBlock: View {

    let trace: [ReportTracePoint]

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private enum Metrics {
        /// Room for the two hPa labels down the left edge.
        static let axisWidth: CGFloat = 38
        static let pressureHeight: CGFloat = 78
        static let bandGap: CGFloat = 10
        static let intensityHeight: CGFloat = 34
        static let dotDiameter: CGFloat = 5

        static var plotHeight: CGFloat { pressureHeight + bandGap + intensityHeight }
    }

    var body: some View {
        ReportSection(title: ReportDocumentCopy.traceSection) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 6) {
                    axis
                    plot
                }
                .frame(height: Metrics.plotHeight)

                dayAxis
                legend
            }
        }
    }

    // MARK: Plot

    private var plot: some View {
        GeometryReader { proxy in
            let width = proxy.size.width

            ZStack(alignment: .topLeading) {
                Rectangle()
                    .fill(Palette.surface)
                    .frame(height: Metrics.pressureHeight)

                if let domain {
                    pressureLine(width: width, domain: domain)
                } else {
                    Text(ReportDocumentCopy.noPressure)
                        .font(Typography.chartAnnotation)
                        .foregroundStyle(Palette.inkSubtle)
                        .frame(height: Metrics.pressureHeight, alignment: .center)
                        .frame(maxWidth: .infinity)
                }

                intensityBand(width: width)
                    .offset(y: Metrics.pressureHeight + Metrics.bandGap)
            }
        }
    }

    /// The pressure line, broken wherever a day holds no reading.
    ///
    /// A break rather than a join. The phone samples opportunistically, so a stretch with no
    /// reading is ordinary — and a straight segment drawn across four unrecorded days claims
    /// four days of coverage the log does not have.
    private func pressureLine(width: CGFloat, domain: ClosedRange<Double>) -> some View {
        Path { path in
            var isDrawing = false

            for (index, point) in trace.enumerated() {
                guard let value = point.meanPressureHPa else {
                    isDrawing = false
                    continue
                }

                let position = CGPoint(x: x(at: index, width: width),
                                       y: y(value, in: domain))
                if isDrawing {
                    path.addLine(to: position)
                } else {
                    path.move(to: position)
                    isDrawing = true
                }
            }
        }
        .stroke(Palette.chartLine, style: StrokeStyle(lineWidth: 1.4,
                                                     lineCap: .round,
                                                     lineJoin: .round))
        .frame(height: Metrics.pressureHeight)
    }

    /// One dot per day carrying a check-in, placed by intensity and coloured by it.
    ///
    /// Both channels say the same thing, which is the rule `Palette.intensity(_:)` states: a
    /// ten-step ramp is not distinguishable by hue alone, so height carries the value too.
    private func intensityBand(width: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(Palette.surface)
                .frame(height: Metrics.intensityHeight)

            ForEach(Array(trace.enumerated()), id: \.element.id) { index, point in
                if let intensity = point.peakIntensity {
                    Circle()
                        .fill(Palette.intensity(intensity))
                        .frame(width: Metrics.dotDiameter, height: Metrics.dotDiameter)
                        .offset(x: x(at: index, width: width) - Metrics.dotDiameter / 2,
                                y: intensityY(intensity) - Metrics.dotDiameter / 2)
                }
            }
        }
        .frame(height: Metrics.intensityHeight)
    }

    // MARK: Axes

    private var axis: some View {
        VStack(alignment: .trailing, spacing: 0) {
            if let domain {
                Text(verbatim: PressureFormat.roundedHectopascals(domain.upperBound))
                    .font(Typography.chartAnnotation)
                    .foregroundStyle(Palette.inkSubtle)

                Spacer(minLength: 0)

                Text(verbatim: PressureFormat.roundedHectopascals(domain.lowerBound))
                    .font(Typography.chartAnnotation)
                    .foregroundStyle(Palette.inkSubtle)
            }
        }
        .frame(width: Metrics.axisWidth, height: Metrics.pressureHeight, alignment: .trailing)
    }

    /// First and last day of the window, under the plot. Two labels rather than a tick scale:
    /// the reader needs to know which stretch of time the line covers, and a document that
    /// cannot be zoomed has no use for intermediate ticks at 366 points.
    private var dayAxis: some View {
        HStack {
            if let first = trace.first {
                Text(verbatim: ReportDateFormat.shortDay(first.day, in: calendar, locale: locale))
            }
            Spacer(minLength: 8)
            if let last = trace.last {
                Text(verbatim: ReportDateFormat.shortDay(last.day, in: calendar, locale: locale))
            }
        }
        .font(Typography.chartAnnotation)
        .foregroundStyle(Palette.inkSubtle)
        .padding(.leading, Metrics.axisWidth + 6)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            marker(Palette.chartLine, ReportDocumentCopy.pressureLegend)
            marker(Palette.intensity(CheckInIntensity(clamping: 7)),
                   ReportDocumentCopy.checkInLegend)
        }
        .padding(.leading, Metrics.axisWidth + 6)
    }

    private func marker(_ colour: Color, _ label: LocalizedStringKey) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(colour)
                .frame(width: Metrics.dotDiameter, height: Metrics.dotDiameter)

            Text(label)
                .font(Typography.chartAnnotation)
                .foregroundStyle(Palette.bodyText)
        }
    }

    // MARK: Geometry

    /// Vertical extent of the pressure band, padded so the line does not touch either edge.
    ///
    /// `nil` when no day in the window holds a reading, which is what puts the "no readings"
    /// note in the band instead of a flat line at an arbitrary height.
    private var domain: ClosedRange<Double>? {
        let values = trace.compactMap(\.meanPressureHPa)
        guard let lowest = values.min(), let highest = values.max() else { return nil }

        // The same shape of rule as `PressureSeries.valueDomainHPa`, with a wider ceiling:
        // that one fits at most twelve days, this one up to a year, and a year of weather
        // spans far more than 3 hPa.
        let padding = min(max((highest - lowest) * 0.15, 1.0), 6.0)
        return (lowest - padding)...(highest + padding)
    }

    private func x(at index: Int, width: CGFloat) -> CGFloat {
        // A single-day window has no span to divide by, and its one point belongs at the left
        // edge rather than at a NaN.
        guard trace.count > 1 else { return 0 }
        return width * CGFloat(index) / CGFloat(trace.count - 1)
    }

    private func y(_ value: Double, in domain: ClosedRange<Double>) -> CGFloat {
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return Metrics.pressureHeight / 2 }

        let position = (value - domain.lowerBound) / span
        return Metrics.pressureHeight * (1 - position)
    }

    private func intensityY(_ intensity: CheckInIntensity) -> CGFloat {
        // Inset by the dot's own radius at both ends, so a 1 and a 10 sit inside the band
        // rather than half outside it.
        let inset = Metrics.dotDiameter / 2
        let usable = Metrics.intensityHeight - Metrics.dotDiameter
        return inset + usable * (1 - intensity.normalized)
    }
}

// MARK: - Tags

/// The tags the window carried, most-used first, with a bar for the eye.
struct ReportTagsBlock: View {

    let tags: [ReportTagCount]

    /// How many rows the section prints. A long tail of tags used once each says less than the
    /// space it costs, and the full breakdown is in the log below.
    private static let rowLimit = 8

    private var shown: [ReportTagCount] { Array(tags.prefix(Self.rowLimit)) }

    /// Bars are scaled against the most-used tag rather than against the check-in count: with a
    /// top tag at 12 of 60 check-ins, every bar would otherwise be a sliver.
    private var highest: Int { tags.first?.count ?? 1 }

    var body: some View {
        ReportSection(title: ReportDocumentCopy.tagsSection) {
            VStack(spacing: 6) {
                ForEach(shown) { entry in
                    row(entry)
                }
            }
        }
    }

    private func row(_ entry: ReportTagCount) -> some View {
        HStack(spacing: 10) {
            WellbeingTag(id: entry.tag.id, name: entry.tag.name).label
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.heading)
                .lineLimit(1)
                .frame(width: 150, alignment: .leading)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Palette.segmentedTrack)

                    Capsule()
                        .fill(Palette.link)
                        .frame(width: proxy.size.width * fraction(of: entry))
                }
            }
            .frame(height: 6)

            Text("\(entry.count)")
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.bodyText)
                .monospacedDigit()
                .frame(width: 30, alignment: .trailing)
        }
    }

    private func fraction(of entry: ReportTagCount) -> CGFloat {
        guard highest > 0 else { return 0 }
        return CGFloat(entry.count) / CGFloat(highest)
    }
}

// MARK: - Medications

/// What the user recorded taking, grouped by name.
///
/// Counts and their own words, like everything else here. Nothing totals a dose, works out an
/// interval or says anything about what was taken — the rule `MedicationHistory` states, and it
/// matters more in a document a prescriber may read.
struct ReportMedicationsBlock: View {

    let medications: [MedicationSummary]

    /// Whether this is the opening slice of the section, which decides whether the heading
    /// reads "Recorded medications" or "(continued)".
    let isFirst: Bool

    /// Whether this slice prints a heading at all. See `ReportBlockView.drawsHeading`.
    let drawsHeading: Bool

    private static let nameWidth: CGFloat = 190
    private static let timesWidth: CGFloat = 54

    /// Line budget for the two cells that grow with what the user typed, for the reason
    /// `ReportEntriesBlock.Metrics` gives at length: `MedicationEntry.name` carries no length
    /// limit, and one medication can be recorded at any number of distinct doses, so without a
    /// bound here a slice of `ReportBlock.medicationsPerBlock` rows has no bounded height and
    /// the page silently crops whatever did not fit.
    private static let cellLines = 2

    var body: some View {
        ReportOptionalSection(title: isFirst
            ? ReportDocumentCopy.medicationsSection
            : ReportDocumentCopy.medicationsContinued,
                              isTitled: drawsHeading) {
            VStack(spacing: 0) {
                if drawsHeading { header }

                // A separator above every row, including the first: under a column header it
                // is the header's underline, and at the top of a slice that continues the
                // table above it, it is the line between two rows.
                ForEach(Array(medications.enumerated()), id: \.element.id) { _, medication in
                    Rectangle()
                        .fill(Palette.rowSeparator)
                        .frame(height: 0.5)

                    row(medication)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            columnLabel(ReportDocumentCopy.medicationColumn, width: Self.nameWidth, .leading)
            columnLabel(ReportDocumentCopy.doseColumn, width: nil, .leading)
            columnLabel(ReportDocumentCopy.timesColumn, width: Self.timesWidth, .trailing)
        }
        .padding(.bottom, 5)
    }

    private func row(_ medication: MedicationSummary) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            // The name and the doses are the user's own text — verbatim, never through a
            // localisation lookup.
            Text(verbatim: medication.name)
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.heading)
                .lineLimit(Self.cellLines)
                .frame(width: Self.nameWidth, alignment: .leading)

            Text(verbatim: medication.doses.joined(separator: ", "))
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.bodyText)
                .lineLimit(Self.cellLines)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text("\(medication.timesTaken)")
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.bodyText)
                .monospacedDigit()
                .frame(width: Self.timesWidth, alignment: .trailing)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
    }

    private func columnLabel(_ title: LocalizedStringKey,
                             width: CGFloat?,
                             _ alignment: Alignment) -> some View {
        Text(title)
            .font(Typography.metricLabel)
            .foregroundStyle(Palette.inkSubtle)
            .textCase(.uppercase)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

// MARK: - Entries

/// One slice of the log: up to `ReportBlock.entriesPerBlock` check-ins as the user wrote them.
struct ReportEntriesBlock: View {

    let entries: [ReportEntry]

    /// Whether this is the opening slice of the log, which decides whether the heading reads
    /// "Entry log" or "(continued)".
    let isFirst: Bool

    /// Whether this slice prints a heading at all. See `ReportBlockView.drawsHeading`.
    let drawsHeading: Bool

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    private enum Metrics {
        static let dateWidth: CGFloat = 96
        static let intensityWidth: CGFloat = 26
        static let tagsWidth: CGFloat = 148

        /// Line budgets for the three cells that grow with what the user recorded.
        ///
        /// These are what make a row's height bounded, and a bounded row is what lets
        /// `ReportBlock.entriesPerBlock` be a fixed number at all. Without them the row has
        /// three unbounded axes — a check-in carries any number of tags, any number of
        /// medications, and `MedicationEntry.name` has no length limit of its own — so a slice
        /// of six could measure anything, and whatever did not fit the page was cropped out of
        /// the document with nothing to show for it.
        ///
        /// Nothing is lost from the *document* by the two truncating cells: every distinct
        /// medication of the period is listed in full, with its doses and how often it was
        /// taken, in `ReportMedicationsBlock` above. The tag column is the one place where a
        /// rarely used tag on a heavily tagged check-in can fall past the cut — three lines
        /// hold six or so, and `ReportTagsBlock` prints the eight most-used.
        static let tagLines = 3
        static let takenLines = 3

        /// The note is already cut to `ReportEntry.noteCharacterLimit` characters, which is
        /// about five lines at this width. This is a backstop, not a second policy: it exists
        /// so the bound holds by construction rather than by arithmetic about how a language
        /// happens to wrap.
        static let noteLines = 6
    }

    var body: some View {
        ReportOptionalSection(title: isFirst
            ? ReportDocumentCopy.entriesSection
            : ReportDocumentCopy.entriesContinued,
                              isTitled: drawsHeading) {
            VStack(spacing: 0) {
                if drawsHeading { header }

                // See `ReportMedicationsBlock` for why every row carries a separator above it.
                ForEach(Array(entries.enumerated()), id: \.element.id) { _, entry in
                    Rectangle()
                        .fill(Palette.rowSeparator)
                        .frame(height: 0.5)

                    row(entry)
                }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            columnLabel(ReportDocumentCopy.dateColumn, width: Metrics.dateWidth, .leading)
            columnLabel(ReportDocumentCopy.intensityColumn,
                        width: Metrics.intensityWidth, .center)
            columnLabel(ReportDocumentCopy.tagsColumn, width: Metrics.tagsWidth, .leading)
            columnLabel(ReportDocumentCopy.takenColumn, width: nil, .leading)
        }
        .padding(.bottom, 5)
    }

    private func row(_ entry: ReportEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 8) {
                Text(verbatim: ReportDateFormat.shortDay(entry.timestamp, in: calendar,
                                                         locale: locale)
                    + ", " + ReportDateFormat.time(entry.timestamp, in: calendar, locale: locale))
                    .font(Typography.settingsRowValue)
                    .foregroundStyle(Palette.heading)
                    .frame(width: Metrics.dateWidth, alignment: .leading)

                intensityPill(entry.intensity)

                tagList(entry.tags)
                    .lineLimit(Metrics.tagLines)
                    .frame(width: Metrics.tagsWidth, alignment: .leading)

                Text(verbatim: takenText(entry.medications))
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.bodyText)
                    .lineLimit(Metrics.takenLines)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let note = entry.note {
                noteText(note, isTruncated: entry.isNoteTruncated)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 5)
    }

    /// The value on its own ramp colour, with the numeral on top — the two channels
    /// `Palette.intensity(_:)` requires, in the width of one column.
    private func intensityPill(_ intensity: CheckInIntensity) -> some View {
        Text("\(intensity.rawValue)")
            .font(Typography.metricLabel)
            .foregroundStyle(Palette.onInk)
            .monospacedDigit()
            .frame(width: Metrics.intensityWidth, height: 16)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Palette.intensity(intensity))
            }
    }

    /// Tag names joined with commas, wrapping inside their column.
    ///
    /// Built by concatenating `Text` rather than by joining strings, because a seeded tag the
    /// user never renamed is app copy that has to be looked up in the reader's language while a
    /// tag they wrote is their own words — `WellbeingTag.label` is what tells the two apart, and
    /// it returns `Text`.
    ///
    /// `Text.+` is deprecated from iOS 26. It is still the right tool here and the codebase
    /// already relies on it (`HistorySummaryCard`): the replacement, interpolating one `Text`
    /// into another, would register a meaningless `"%@, %@"` entry in the string catalogue for
    /// translators to stare at. A wrapping row of separate views is not an option either — the
    /// names have to flow as one paragraph inside a fixed-width column.
    private func tagList(_ tags: [ReportTagRef]) -> Text {
        guard let first = tags.first else { return Text(verbatim: "") }

        let separator = Text(verbatim: ", ")
        return tags.dropFirst()
            .reduce(label(for: first)) { $0 + separator + label(for: $1) }
            .font(Typography.settingsCaption)
            .foregroundColor(Palette.bodyText)
    }

    private func label(for tag: ReportTagRef) -> Text {
        WellbeingTag(id: tag.id, name: tag.name).label
    }

    /// "Ібупрофен 400 мг · Суматриптан", the user's own words throughout.
    private func takenText(_ medications: [MedicationEntry]) -> String {
        medications
            .map { entry in
                guard let dose = entry.dose else { return entry.name }
                return "\(entry.name) \(dose)"
            }
            .joined(separator: " · ")
    }

    /// The note, and under it the marker when the document had to cut it.
    ///
    /// Two views rather than one concatenated `Text`. `Text.+` is deprecated from iOS 26, and
    /// the marker reads better on its own line anyway: it is the document speaking about the
    /// note, not part of what the user wrote.
    private func noteText(_ note: String, isTruncated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            // The user's own text — verbatim, never through a localisation lookup.
            Text(verbatim: note)
                .font(Typography.cardNote)
                .foregroundStyle(Palette.bodyText)
                .lineLimit(Metrics.noteLines)

            if isTruncated {
                Text(ReportDocumentCopy.noteTruncated)
                    .font(Typography.chartAnnotation)
                    .foregroundStyle(Palette.inkSubtle)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, Metrics.dateWidth + 8)
    }

    private func columnLabel(_ title: LocalizedStringKey,
                             width: CGFloat?,
                             _ alignment: Alignment) -> some View {
        Text(title)
            .font(Typography.metricLabel)
            .foregroundStyle(Palette.inkSubtle)
            .textCase(.uppercase)
            .frame(width: width, alignment: alignment)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: alignment)
    }
}

// MARK: - Continuable section

/// A `ReportSection` whose heading can be dropped.
///
/// For the two tables that are cut into slices: a slice landing mid-page continues the rows
/// above it and must not repeat the heading, while the same slice at the top of a page has to
/// carry one. Which of the two it is only becomes known after pagination, so both shapes come
/// out of one view.
struct ReportOptionalSection<Content: View>: View {

    let title: LocalizedStringKey
    let isTitled: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        if isTitled {
            ReportSection(title: title, content: content)
        } else {
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
