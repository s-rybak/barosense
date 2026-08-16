import SwiftUI

/// State behind the report screen.
///
/// Two jobs, kept apart because they cost very different amounts and fail for different
/// reasons: reading the window out of the stores and turning it into a `WellbeingReport`, which
/// happens on every change of period and feeds the preview; and rendering that report to PDF
/// bytes, which happens only when the user asks and is the only part that writes a file.
///
/// Nothing here decides what the document *says*. That is `ReportBuilder` in `Shared/`, where a
/// test reaches it without a screen and without a store.
@MainActor
@Observable
final class ReportModel {

    /// Where the screen is between the store and the share sheet.
    enum Phase: Equatable {
        case loading
        /// A report is in hand and the preview is drawing it.
        case ready
        /// Rendering the PDF. The button is a progress state for as long as this lasts.
        case building
        /// The store would not answer, or Core Graphics would not give us a document. Either
        /// way there is nothing the user can do beyond trying again.
        case failed
    }

    var period: ReportPeriod = .default

    private(set) var phase: Phase = .loading
    private(set) var report: WellbeingReport?

    /// Set when a file is ready to hand over; clearing it dismisses the share sheet.
    var share: ReportShareItem?

    private let dependencies: SettingsDependencies
    private let languages: LanguageController
    private let now: () -> Date

    init(dependencies: SettingsDependencies,
         languages: LanguageController,
         now: @escaping () -> Date = Date.init) {
        self.dependencies = dependencies
        self.languages = languages
        self.now = now
    }

    /// The blocks the preview draws — everything the file holds except the log.
    var previewBlocks: [ReportBlock] {
        report.map(ReportBlock.preview(for:)) ?? []
    }

    var isBuildable: Bool {
        switch phase {
        case .ready: true
        case .loading, .building, .failed: false
        }
    }

    // MARK: - Loading

    /// Reads the window and builds the report for the current period.
    ///
    /// Runs on every change of period, so it must be safe to repeat and must not leave a stale
    /// document behind: the preview and the file both come from `report`, and a period switch
    /// that failed halfway would otherwise offer a PDF of the wrong months.
    func load() async {
        phase = .loading
        report = nil

        let calendar = languages.calendar
        let generatedAt = now()
        let window = period.window(endingOn: generatedAt, calendar: calendar)

        do {
            // Concurrent because they are four independent reads against four stores, and the
            // pressure read alone can be tens of thousands of rows on the widest period.
            async let profile = dependencies.profileStore.profile()
            async let checkIns = dependencies.checkInStore.checkIns(in: window)
            async let pressure = dependencies.pressureLog.samples(in: window)
            async let tags = dependencies.tagStore.allTags()
            async let healthCount = healthReadingCount(in: window)

            let vocabulary = try await Dictionary(tags.map { ($0.id, $0) },
                                                  uniquingKeysWith: { first, _ in first })

            let input = try await ReportInput(profile: profile,
                                              checkIns: checkIns,
                                              pressureSamples: pressure,
                                              healthReadingCount: healthCount,
                                              tagsByID: vocabulary)

            report = ReportBuilder.make(period: period,
                                        window: window,
                                        generatedAt: generatedAt,
                                        from: input,
                                        calendar: calendar)
            phase = .ready
        } catch {
            phase = .failed
        }
    }

    /// How many Health rows backed the window, across every kind Barosense reads.
    ///
    /// A count and nothing more — the document says how much Health data there was and never
    /// what was in it. A kind that will not read contributes zero rather than failing the whole
    /// report: a missing source is exactly what the "Data sources" block is for.
    private func healthReadingCount(in window: Range<Date>) async -> Int {
        var total = 0
        for kind in HealthMetricKind.allCases {
            let samples = (try? await dependencies.healthLog.samples(of: kind, in: window)) ?? []
            total += samples.count
        }
        return total
    }

    // MARK: - Building

    /// Renders the PDF, writes it, and raises the share sheet over it.
    ///
    /// The file is written before the sheet appears rather than handed over as bytes: a URL is
    /// what gives the share sheet its full set of destinations, and it is what lets a
    /// destination that copies lazily — Files, Mail — read the document after this call has
    /// returned.
    func build() async {
        guard let report, isBuildable else { return }

        phase = .building
        do {
            let data = try await ReportPDFRenderer.render(report,
                                                          locale: languages.locale,
                                                          calendar: languages.calendar)
            let url = try ReportFile.write(data,
                                           generatedAt: report.generatedAt,
                                           calendar: languages.calendar)
            phase = .ready
            share = ReportShareItem(url: url)
        } catch {
            phase = .failed
        }
    }

    /// Removes the generated file.
    ///
    /// Called when the screen goes away. Health data outside the app's own stores gets an
    /// explicit lifetime rather than being left for iOS to reclaim from `tmp` whenever it
    /// chooses — the same posture `BarosenseDataEraser` takes toward everything else.
    func discardFile() {
        try? ReportFile.discardAll()
    }
}

/// The generated file, wrapped so `.sheet(item:)` can key on it.
///
/// A fresh identity per build, not the URL: two builds in a row can land on the same path — the
/// name carries only the date — and a sheet keyed on the URL would not re-present for the
/// second one.
struct ReportShareItem: Identifiable {
    let id = UUID()
    let url: URL
}
