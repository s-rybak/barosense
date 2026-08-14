import SwiftUI
import UIKit

/// Turns a `WellbeingReport` into PDF bytes.
///
/// ## How it paginates
///
/// Three passes, and the middle one is the reason for the other two:
///
/// 1. **Measure.** Every block is laid out once at the page's content width and its height
///    recorded. Heights are measured rather than estimated because the blocks hold translated
///    copy and the user's own text, and a guessed height is wrong in exactly the cases that
///    matter — a long medication name, a two-line note, Ukrainian running longer than English.
/// 2. **Pack.** Blocks are placed onto pages greedily against a fixed budget. A block is never
///    split, so a page break can never land inside a heading or a table row; the two unbounded
///    sections are already cut into page-sized slices by `ReportBlock.all(for:)`.
/// 3. **Draw.** Each page is built as one `ReportPageView` sized to the whole sheet and handed
///    to `ImageRenderer`. There is deliberately no offset arithmetic here — a page is one view,
///    so SwiftUI does the placing and this file only decides which blocks go on which sheet.
///
/// `@MainActor` because `ImageRenderer` is. That means generation runs on the main thread; the
/// work is a layout pass per block, and the caller shows a progress state over it. The `await`
/// between pages is what lets that state actually paint.
@MainActor
enum ReportPDFRenderer {

    enum Failure: Error, Equatable {
        /// Core Graphics would not give us a PDF context to write into. Nothing recoverable and
        /// nothing the user did.
        case contextUnavailable
        /// A page produced no bytes. Cannot happen with a fixed media box, but a silently empty
        /// file is worse than a reported failure.
        case emptyDocument
    }

    /// Renders the whole document.
    ///
    /// `locale` and `calendar` are handed in rather than read from `Locale.current`: the app's
    /// language is `LanguageController`'s, not the device's, and a file is generated once and
    /// keeps whatever language it was built with. See `ReportDateFormat`.
    static func render(_ report: WellbeingReport,
                       locale: Locale,
                       calendar: Calendar) async throws -> Data {
        let blocks = ReportBlock.all(for: report)

        var heights: [CGFloat] = []
        heights.reserveCapacity(blocks.count)
        for block in blocks {
            let measured = height(of: block, in: report, locale: locale, calendar: calendar)

            // A block taller than a page cannot be rescued further down. The page is a fixed
            // frame over a fixed media box, so what does not fit is cropped out of the finished
            // document — rows and the running footer simply absent, with nothing on the page to
            // say so. Every block is bounded by construction (`ReportEntriesBlock.Metrics`,
            // `ReportBlock.entriesPerBlock`), so reaching this is a mistake in those bounds and
            // belongs in a failing test rather than in somebody's PDF. Compiled out in Release:
            // a document with a cropped page is still worth more to the user than no document.
            assert(measured <= ReportDocumentMetrics.contentHeight,
                   "\(block) measured \(measured) pt against a \(ReportDocumentMetrics.contentHeight) pt page")

            heights.append(measured)
            // Measuring a year of entries is dozens of layout passes on the main thread. The
            // yield hands the run loop back between them so the progress state stays live.
            await Task.yield()
        }

        let pages = pack(blocks, heights: heights)

        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data) else { throw Failure.contextUnavailable }

        var mediaBox = CGRect(origin: .zero, size: ReportDocumentMetrics.pageSize)
        guard let context = CGContext(consumer: consumer, mediaBox: &mediaBox, documentInfo)
        else {
            throw Failure.contextUnavailable
        }

        for (index, page) in pages.enumerated() {
            let view = ReportPageView(blocks: page,
                                      report: report,
                                      pageNumber: index + 1,
                                      pageCount: pages.count)

            ImageRenderer(content: document(view, locale: locale, calendar: calendar))
                .render { _, draw in
                    context.beginPDFPage(nil)
                    draw(context)
                    context.endPDFPage()
                }

            await Task.yield()
        }

        context.closePDF()

        guard data.length > 0 else { throw Failure.emptyDocument }
        return data as Data
    }

    // MARK: - Measuring

    /// What one block measures at the page's content width.
    ///
    /// Internal rather than private so the regression test that keeps a table slice inside a
    /// page measures through this exact path. A test that laid the block out its own way would
    /// guarantee nothing about the file this renderer actually writes.
    static func height(of block: ReportBlock,
                       in report: WellbeingReport,
                       locale: Locale,
                       calendar: Calendar) -> CGFloat {
        let content = ReportBlockView(block: block, report: report)
            .frame(width: ReportDocumentMetrics.contentWidth, alignment: .topLeading)

        var measured: CGFloat = 0
        ImageRenderer(content: document(content, locale: locale, calendar: calendar))
            .render { size, _ in measured = size.height }

        return measured
    }

    // MARK: - Packing

    /// Greedy first fit, in order. Blocks keep their order, so a page is a contiguous run.
    ///
    /// A block taller than a whole page gets a page to itself and is allowed to overflow it.
    /// Nothing produces one today — every unbounded section is pre-sliced — but the alternative
    /// to placing it is dropping it, and a document silently missing a section is the worse
    /// failure of the two.
    static func pack(_ blocks: [ReportBlock], heights: [CGFloat]) -> [[ReportBlock]] {
        let budget = ReportDocumentMetrics.contentHeight
        let spacing = ReportDocumentMetrics.blockSpacing

        var pages: [[ReportBlock]] = []
        var current: [ReportBlock] = []
        var used: CGFloat = 0

        for (block, height) in zip(blocks, heights) {
            let needed = current.isEmpty ? height : height + spacing

            if !current.isEmpty && used + needed > budget {
                pages.append(current)
                current = [block]
                used = height
            } else {
                current.append(block)
                used += needed
            }
        }

        if !current.isEmpty { pages.append(current) }
        return pages
    }

    // MARK: - Environment

    /// The environment every rendered view is resolved against.
    ///
    /// `dynamicTypeSize` is pinned. A PDF cannot re-lay itself out for the person who opens it,
    /// so it is generated at the standard size whatever the author has set on their own phone —
    /// otherwise a reader at an accessibility size would hand over a document with four words
    /// per line. The app's own screens still scale; this is the one surface that cannot.
    private static func document<Content: View>(_ content: Content,
                                                locale: Locale,
                                                calendar: Calendar) -> some View {
        content
            .environment(\.locale, locale)
            .environment(\.calendar, calendar)
            .environment(\.dynamicTypeSize, .large)
            .environment(\.colorScheme, .light)
    }

    /// PDF metadata.
    ///
    /// Deliberately carries no personal data — not the name, not the period. Metadata is copied
    /// by every tool that touches the file and is read by indexers the user never sees, and
    /// there is nothing here that the first page does not already say to someone who opens it.
    private static var documentInfo: CFDictionary {
        [kCGPDFContextCreator as String: "Barosense",
         kCGPDFContextTitle as String: "Barosense"] as CFDictionary
    }
}

// MARK: - File

/// Where the generated file lives between "Create PDF" and the share sheet.
///
/// Its own directory under `tmp`, emptied before each write and again when the screen goes
/// away. This is health data at rest outside the app's stores, so its lifetime is bounded
/// explicitly rather than left to whenever iOS decides to reclaim `tmp`.
enum ReportFile {

    private static var directory: URL {
        FileManager.default.temporaryDirectory.appending(path: "Reports", directoryHint: .isDirectory)
    }

    /// Writes `data` and returns where it went, replacing anything written before.
    ///
    /// `.completeFileProtectionUnlessOpen` rather than `.completeFileProtection`: a share
    /// extension may still be reading the file when the screen locks, and complete protection
    /// would fail that read halfway through. "Unless open" keeps an already-open handle valid
    /// and still leaves the file unreadable at rest on a locked device.
    static func write(_ data: Data, generatedAt: Date, calendar: Calendar) throws -> URL {
        try discardAll()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let url = directory.appending(path: fileName(for: generatedAt, calendar: calendar))
        try data.write(to: url, options: [.atomic, .completeFileProtectionUnlessOpen])
        return url
    }

    /// Removes every generated file. Not an error when there is nothing there.
    static func discardAll() throws {
        guard FileManager.default.fileExists(atPath: directory.path(percentEncoded: false)) else {
            return
        }
        try FileManager.default.removeItem(at: directory)
    }

    /// `Barosense-report-2026-08-14.pdf`.
    ///
    /// ASCII and ISO-ordered, deliberately not localised. This string becomes an attachment
    /// name in somebody else's mail client and a row in their file system, where a Cyrillic
    /// name and a locale-ordered date are two more things that can go wrong on the way. It
    /// carries the date and nothing about the person.
    static func fileName(for date: Date, calendar: Calendar) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        let year = parts.year ?? 0
        let month = parts.month ?? 0
        let day = parts.day ?? 0
        return String(format: "Barosense-report-%04d-%02d-%02d.pdf", year, month, day)
    }
}

// MARK: - Share

/// The system share sheet, with the generated file as its only item.
///
/// `UIActivityViewController` rather than `ShareLink`: the file does not exist until the user
/// asks for it, and `ShareLink` needs its item up front. Handing over a file URL is also what
/// gives the full set of destinations — AirDrop, Mail, Messages, Files, Print, Copy — rather
/// than the reduced set a plain `Data` item offers.
///
/// No `excludedActivityTypes`. iOS already hides what cannot take a PDF, and removing anything
/// further would be this app deciding who the user may send their own document to.
struct ReportShareSheet: UIViewControllerRepresentable {

    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
