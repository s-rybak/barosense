import SwiftUI

/// Fixed geometry of the generated page.
///
/// **A4, not US Letter.** The reader of this document is in the same country as the person who
/// made it, and that is Europe: a Letter page handed to a European printer comes out with a
/// margin the tray does not have. A Letter printer scales A4 down to fit, which costs a few
/// per cent of size and nothing else — the failure is asymmetric, so the default follows the
/// audience.
///
/// Points at 72 dpi, which is the PDF user-space unit: 595.28 × 841.89 pt is 210 × 297 mm.
enum ReportDocumentMetrics {

    static let pageSize = CGSize(width: 595.28, height: 841.89)

    static let horizontalMargin: CGFloat = 44
    static let topMargin: CGFloat = 40
    static let bottomMargin: CGFloat = 30

    /// Reserved at the foot of every page for the running footer, outside the block budget.
    static let footerHeight: CGFloat = 22

    /// Gap between two blocks stacked on one page.
    static let blockSpacing: CGFloat = 18

    static var contentWidth: CGFloat { pageSize.width - horizontalMargin * 2 }

    /// Vertical room one page has for blocks. What `ReportPagination` packs against.
    static var contentHeight: CGFloat {
        pageSize.height - topMargin - bottomMargin - footerHeight
    }
}

// MARK: - Blocks

/// One indivisible piece of the document.
///
/// Pagination works in these rather than in points of continuous content, so a page break can
/// never land inside a section heading or halfway through a table row. The one unbounded
/// section — the entry log — is pre-cut into fixed-size slices before it gets here, which is
/// what keeps "indivisible" true for it too.
enum ReportBlock: Hashable {
    case header
    case about
    case summary
    case trace
    case tags
    case sources

    /// A slice of `WellbeingReport.medications`, and below it one of `entries`.
    ///
    /// Both lists are unbounded — a person can record any number of distinct medications and
    /// any number of check-ins — so both are cut into slices small enough that one always fits
    /// on a page. `isFirst` carries the section heading, which keeps a heading from being
    /// orphaned at the foot of a page away from its own table.
    case medications(range: Range<Int>, isFirst: Bool)
    case entries(range: Range<Int>, isFirst: Bool)

    case disclaimer
}

/// Draws one block.
///
/// The same view is used to measure a block, to draw it into the PDF, and to draw the preview
/// on screen. That is the point: a preview built from a second set of views is a preview that
/// drifts, and this one is a promise about a file the user is about to hand to someone.
struct ReportBlockView: View {

    let block: ReportBlock
    let report: WellbeingReport

    /// Whether this block prints its own section heading and column labels.
    ///
    /// Only ever `false` for a continuation slice that lands on the same page as the slice
    /// before it, where a second "(continued)" heading would cut one table into two halfway
    /// down a page. Which slice that is cannot be known until the packer has run, so the
    /// decision is made by `ReportPageView` and not by the block list.
    ///
    /// Measurement always passes `true`, the taller of the two. A block that draws shorter
    /// than it measured leaves a little white at the foot of a page; one that draws taller
    /// would run off it.
    var drawsHeading = true

    var body: some View {
        switch block {
        case .header: ReportHeaderBlock(report: report)
        case .about: ReportAboutBlock(profile: report.profile)
        case .summary: ReportSummaryBlock(report: report)
        case .trace: ReportTraceBlock(trace: report.trace)
        case .tags: ReportTagsBlock(tags: report.tags)
        case .sources: ReportSourcesBlock(sources: report.sources)
        case .medications(let range, let isFirst):
            ReportMedicationsBlock(medications: Array(report.medications[range]),
                                   isFirst: isFirst,
                                   drawsHeading: drawsHeading)
        case .entries(let range, let isFirst):
            ReportEntriesBlock(entries: Array(report.entries[range]),
                               isFirst: isFirst,
                               drawsHeading: drawsHeading)
        case .disclaimer: ReportDisclaimerBlock()
        }
    }
}

extension ReportBlock {

    /// Whether this block continues the table immediately above it on the same page.
    ///
    /// Both sides have to match: a medications slice under an entries slice is a new section
    /// and keeps its heading.
    func continues(_ previous: ReportBlock) -> Bool {
        switch (previous, self) {
        case (.entries, .entries(_, false)), (.medications, .medications(_, false)): true
        default: false
        }
    }
}

extension ReportBlock {

    /// The blocks the document holds, in order, for one report.
    ///
    /// Sections with nothing in them are left out rather than drawn empty — a labelled blank
    /// in a document someone else reads looks like data that failed to load. The disclaimer is
    /// the exception and is always last: it is the one block whose absence would be a problem.
    static func all(for report: WellbeingReport) -> [ReportBlock] {
        var blocks: [ReportBlock] = [.header]

        if !report.profile.isEmpty { blocks.append(.about) }
        blocks.append(.summary)
        blocks.append(.trace)
        if !report.tags.isEmpty { blocks.append(.tags) }
        blocks.append(contentsOf: slices(of: report.medications.count,
                                         by: medicationsPerBlock,
                                         make: ReportBlock.medications))
        blocks.append(.sources)
        blocks.append(contentsOf: slices(of: report.entries.count,
                                         by: entriesPerBlock,
                                         make: ReportBlock.entries))
        blocks.append(.disclaimer)

        return blocks
    }

    /// The blocks the on-screen preview draws: everything except the log, which can run to
    /// pages and which the screen says in words is also in the file.
    static func preview(for report: WellbeingReport) -> [ReportBlock] {
        all(for: report).filter {
            if case .entries = $0 { return false }
            return true
        }
    }

    /// Rows per slice of the entry log.
    ///
    /// A slice has to fit one page's budget whatever it holds, so this number is only sound
    /// alongside a bounded row: `ReportEntriesBlock.Metrics` caps the three cells that grow
    /// with what the user recorded, which puts the worst row at roughly 145 pt against a
    /// content budget of about 750.
    ///
    /// Both numbers are measured, not estimated — `ReportPDFTests` lays the worst slice the
    /// domain can produce out through the renderer's own measuring call and holds it under 80%
    /// of the page. The first version of this constant was an estimate, it was low by a factor
    /// of three, and the pages that resulted lost their last rows and their footer without
    /// anything on them saying so. Changing this number without re-running that test is how
    /// that comes back.
    static let entriesPerBlock = 4

    /// Rows per slice of the medications table. Higher than `entriesPerBlock` because these
    /// rows carry no note — two capped cells and a count, so about 42 pt each.
    static let medicationsPerBlock = 12

    /// Cuts a list of `count` rows into slices, tagging the first so it carries the heading.
    private static func slices(of count: Int,
                               by size: Int,
                               make: (Range<Int>, Bool) -> ReportBlock) -> [ReportBlock] {
        stride(from: 0, to: count, by: size).map { start in
            make(start..<min(start + size, count), start == 0)
        }
    }
}

// MARK: - Page

/// One rendered page: its blocks, then the running footer.
///
/// Sized to the whole page rather than to its content, so a page that holds two blocks still
/// draws them at the top with white beneath instead of centring them. Rendering a page as one
/// view is also what keeps the PDF writer free of layout arithmetic — there are no offsets to
/// compute because nothing is placed at an offset.
struct ReportPageView: View {

    let blocks: [ReportBlock]
    let report: WellbeingReport
    let pageNumber: Int
    let pageCount: Int

    var body: some View {
        // Spacing is applied per block rather than by the stack, because a slice continuing the
        // table above it has to sit flush against it — a gap there would read as the end of one
        // table and the start of another.
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
                ReportBlockView(block: block,
                                report: report,
                                drawsHeading: drawsHeading(at: index))
                    .padding(.top, topPadding(at: index))
            }

            Spacer(minLength: 0)

            footer
        }
        .padding(.horizontal, ReportDocumentMetrics.horizontalMargin)
        .padding(.top, ReportDocumentMetrics.topMargin)
        .padding(.bottom, ReportDocumentMetrics.bottomMargin)
        .frame(width: ReportDocumentMetrics.pageSize.width,
               height: ReportDocumentMetrics.pageSize.height,
               alignment: .topLeading)
        .background(Palette.cardSurface)
    }

    /// A continuation slice keeps its heading only when it opens a page — where it is genuinely
    /// a new table for the reader, who cannot see the rows it continues from.
    private func drawsHeading(at index: Int) -> Bool {
        guard index > 0 else { return true }
        return !blocks[index].continues(blocks[index - 1])
    }

    private func topPadding(at index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        return drawsHeading(at: index) ? ReportDocumentMetrics.blockSpacing : 0
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 5) {
            Rectangle()
                .fill(Palette.separator)
                .frame(height: 0.5)

            Text(ReportDocumentCopy.footer(page: pageNumber, of: pageCount))
                .font(Typography.chartAnnotation)
                .foregroundStyle(Palette.inkSubtle)
        }
        .frame(height: ReportDocumentMetrics.footerHeight, alignment: .bottom)
    }
}

// MARK: - Header

private struct ReportHeaderBlock: View {

    let report: WellbeingReport

    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // The wordmark is rendered verbatim: it is a product name, not copy, and running
            // it through a localisation lookup is how a brand ends up transliterated.
            Text(verbatim: "BAROSENSE")
                .font(Typography.sectionHeader)
                .tracking(1.6)
                .foregroundStyle(Palette.inkSubtle)

            Text(ReportDocumentCopy.title)
                .font(Typography.onboardingTitle)
                .foregroundStyle(Palette.heading)
                .padding(.top, 6)

            Text(ReportDocumentCopy.subtitle)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.bodyText)
                .padding(.top, 3)

            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(Palette.link)
                .frame(width: 62, height: 3)
                .padding(.top, 12)

            VStack(alignment: .leading, spacing: 3) {
                ReportKeyValueRow(key: ReportDocumentCopy.period, value: periodValue)
                ReportKeyValueRow(key: ReportDocumentCopy.generated, value: generatedValue)
            }
            .padding(.top, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "1 May – 14 Aug 2026". Built from the window's own bounds rather than from the period
    /// name, so the document states the days it covers and not the button that was tapped.
    private var periodValue: Text {
        let start = ReportDateFormat.day(report.window.lowerBound, in: calendar, locale: locale)
        let end = ReportDateFormat.day(report.lastCoveredDay, in: calendar, locale: locale)
        return Text(verbatim: "\(start) – \(end)")
    }

    private var generatedValue: Text {
        Text(verbatim: ReportDateFormat.dayAndTime(report.generatedAt, in: calendar,
                                                   locale: locale))
    }
}

// MARK: - About

private struct ReportAboutBlock: View {

    let profile: ReportProfile

    var body: some View {
        ReportSection(title: ReportDocumentCopy.aboutSection) {
            VStack(alignment: .leading, spacing: 3) {
                if let name = profile.displayName {
                    // The user's own words, so verbatim — the rule `SettingsScreen.profileName`
                    // follows, for the same reason.
                    Text(verbatim: name)
                        .font(Typography.cardTitle)
                        .foregroundStyle(Palette.heading)
                }

                details
            }
        }
    }

    /// Age and gender on one line, whichever of them the user gave.
    ///
    /// Separate views with a drawn separator rather than one concatenated `Text`: `Text.+` is
    /// deprecated from iOS 26, and two labels beside a middot need no concatenation to begin
    /// with.
    private var details: some View {
        HStack(spacing: 5) {
            if let age = profile.ageYears {
                Text(ReportDocumentCopy.ageValue(age))
            }

            if profile.ageYears != nil && profile.gender != nil {
                Text(verbatim: "·")
                    .foregroundStyle(Palette.inkSubtle)
            }

            if let gender = profile.gender {
                Text(gender.label)
            }
        }
        .font(Typography.settingsCaption)
        .foregroundStyle(Palette.bodyText)
    }
}

// MARK: - Summary

private struct ReportSummaryBlock: View {

    let report: WellbeingReport

    @Environment(\.locale) private var locale

    var body: some View {
        ReportSection(title: ReportDocumentCopy.summarySection) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 12) {
                    figure(report.totals.checkInCount, ReportDocumentCopy.checkInsFigure)
                    figure(report.totals.daysWithEntries, ReportDocumentCopy.daysFigure)
                    figure(report.totals.medicationEntryCount, ReportDocumentCopy.dosesFigure)
                }

                if let intensity = report.intensity {
                    intensityLine(intensity)
                }
            }
        }
    }

    private func figure(_ value: Int, _ label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(value)")
                .font(Typography.intensityValue)
                .foregroundStyle(Palette.inkStrong)
                .monospacedDigit()

            Text(label)
                .font(Typography.metricLabel)
                .foregroundStyle(Palette.inkSubtle)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The scale restated beside its own numbers — never a bare figure. See
    /// `ReportDocumentCopy.intensityLabel`.
    private func intensityLine(_ intensity: ReportIntensityDigest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(ReportDocumentCopy.intensityLabel)
                .font(Typography.metricLabel)
                .foregroundStyle(Palette.inkSubtle)

            Text(ReportDocumentCopy.intensityValues(
                mean: intensity.mean.formatted(.number.precision(.fractionLength(1))
                    .locale(locale)),
                lowest: intensity.lowest.rawValue,
                highest: intensity.peak.rawValue
            ))
            .font(Typography.choiceLabelCompact)
            .foregroundStyle(Palette.heading)
        }
        .padding(.top, 2)
    }
}

// MARK: - Sources

private struct ReportSourcesBlock: View {

    let sources: [ReportSource]

    var body: some View {
        ReportSection(title: ReportDocumentCopy.sourcesSection) {
            VStack(spacing: 0) {
                ForEach(Array(sources.enumerated()), id: \.element.id) { index, source in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.rowSeparator)
                            .frame(height: 0.5)
                    }
                    row(source)
                }
            }
        }
    }

    private func row(_ source: ReportSource) -> some View {
        HStack(spacing: 10) {
            Text(source.kind.label)
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.heading)

            Spacer(minLength: 8)

            Text("\(source.count)")
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.bodyText)
                .monospacedDigit()

            // Colour is not the only channel: the count beside it says the same thing, which
            // is what makes the block readable to someone who cannot tell the two dots apart.
            Circle()
                .fill(source.isPresent ? Palette.positive : Palette.controlBorder)
                .frame(width: 8, height: 8)
        }
        .padding(.vertical, 6)
    }
}

// MARK: - Disclaimer

private struct ReportDisclaimerBlock: View {

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(ReportDisclaimerCopy.heading)
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(Palette.heading)

            ForEach(Array(ReportDisclaimerCopy.all.enumerated()), id: \.offset) { _, paragraph in
                Text(paragraph)
                    .font(Typography.cardNote)
                    .foregroundStyle(Palette.bodyText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Palette.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 0.5)
        }
    }
}

// MARK: - Primitives

/// A titled block: the all-caps heading, a hairline, and whatever the section draws.
struct ReportSection<Content: View>: View {

    let title: LocalizedStringKey
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title)
                    .font(Typography.sectionHeader)
                    .tracking(0.48)
                    .textCase(.uppercase)
                    .foregroundStyle(Palette.inkSubtle)

                Rectangle()
                    .fill(Palette.separator)
                    .frame(height: 0.5)
            }

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A label and its value on one line — the header's "Period" and "Generated".
struct ReportKeyValueRow: View {

    let key: LocalizedStringKey
    let value: Text

    /// Wide enough for the longest of the two labels in every shipped language, so the values
    /// line up in a column instead of each starting wherever its own label ended.
    private static let keyWidth: CGFloat = 78

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(key)
                .font(Typography.settingsCaption)
                .foregroundStyle(Palette.inkSubtle)
                .frame(width: Self.keyWidth, alignment: .leading)

            value
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.heading)
        }
    }
}

/// Date text for the document.
///
/// Two things are pinned here, and leaving either to the default produces a document that is
/// quietly wrong:
///
/// - **Locale.** `.formatted()` resolves against `Locale.current`, which is still the language
///   the app *launched* in after a switch in Settings — the trap `HistoryModel` documents. It
///   matters more here, because a file is generated once and keeps whatever language it was
///   built with forever.
/// - **Time zone.** A format style defaults to `TimeZone.autoupdatingCurrent`, while every
///   boundary in the report — the window, the day a check-in falls on, the buckets of the
///   chart — was computed in the report's own `Calendar`. Let the two differ and the header
///   prints a period a day off from the one the document actually covers.
enum ReportDateFormat {

    static func day(_ date: Date, in calendar: Calendar, locale: Locale) -> String {
        date.formatted(base(calendar, locale).day().month(.abbreviated).year())
    }

    static func dayAndTime(_ date: Date, in calendar: Calendar, locale: Locale) -> String {
        date.formatted(base(calendar, locale)
            .day().month(.abbreviated).year().hour().minute())
    }

    static func shortDay(_ date: Date, in calendar: Calendar, locale: Locale) -> String {
        date.formatted(base(calendar, locale).day().month(.abbreviated))
    }

    static func time(_ date: Date, in calendar: Calendar, locale: Locale) -> String {
        date.formatted(base(calendar, locale).hour().minute())
    }

    /// Built through the initialiser rather than by chaining: `calendar` and `timeZone` are
    /// stored properties on `Date.FormatStyle`, not modifiers, and only `locale` has a builder
    /// method. Setting all three at once is also what keeps them from disagreeing.
    private static func base(_ calendar: Calendar, _ locale: Locale) -> Date.FormatStyle {
        Date.FormatStyle(locale: locale, calendar: calendar, timeZone: calendar.timeZone)
    }
}
