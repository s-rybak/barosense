import XCTest
@testable import Barosense

/// Pagination, and that the renderer produces a real document.
///
/// The packing half runs on values and is exact. The rendering half cannot be — what a page
/// looks like is SwiftUI's business — so it asserts the things that would be silently wrong in
/// a file nobody opened before sharing it: the page count, the sheet size, and that the page
/// carries ink at all.
final class ReportPDFTests: XCTestCase {

    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Kyiv") ?? .gmt
        calendar.locale = Locale(identifier: "uk_UA")
        calendar.firstWeekday = 2
        return calendar
    }()

    // MARK: - Packing

    @MainActor
    func testBlocksAreNeverSplitAcrossAPageBreak() {
        // Every block is a heading with its own content under it. A break inside one would put
        // a section title at the foot of one page and its table at the top of the next.
        let budget = ReportDocumentMetrics.contentHeight
        let blocks: [ReportBlock] = [.header, .summary, .trace, .sources, .disclaimer]
        let heights: [CGFloat] = [budget * 0.6, budget * 0.5, budget * 0.3, 60, 120]

        let pages = ReportPDFRenderer.pack(blocks, heights: heights)

        // Nothing lost, nothing duplicated, nothing reordered.
        XCTAssertEqual(pages.flatMap { $0 }, blocks)
        XCTAssertEqual(pages, [[.header], [.summary, .trace, .sources], [.disclaimer]])
    }

    @MainActor
    func testEverythingThatFitsOnOnePageStaysOnOnePage() {
        let blocks: [ReportBlock] = [.header, .summary, .sources]
        let pages = ReportPDFRenderer.pack(blocks, heights: [80, 90, 70])

        XCTAssertEqual(pages, [blocks])
    }

    @MainActor
    func testABlockTallerThanAPageGetsItsOwnPageRatherThanBeingDropped() {
        // Nothing produces one today — the unbounded sections are pre-sliced — but a document
        // silently missing a section is a worse failure than one page that overflows.
        let tall = ReportDocumentMetrics.contentHeight + 200
        let pages = ReportPDFRenderer.pack([.header, .summary, .sources],
                                           heights: [80, tall, 70])

        XCTAssertEqual(pages, [[.header], [.summary], [.sources]])
    }

    // MARK: - Block list

    @MainActor
    func testASectionWithNothingInItIsLeftOutAndTheDisclaimerNeverIs() {
        let empty = report(checkIns: [])
        let blocks = ReportBlock.all(for: empty)

        XCTAssertFalse(blocks.contains(.tags))
        XCTAssertEqual(blocks.last, .disclaimer)
        XCTAssertTrue(blocks.contains(.header))
        XCTAssertTrue(blocks.contains(.sources))
    }

    @MainActor
    func testTheLogIsCutIntoSlicesSmallEnoughToFitAPage() {
        let count = ReportBlock.entriesPerBlock * 2 + 1
        let blocks = ReportBlock.all(for: report(checkIns: (0..<count).map(checkIn(offset:))))

        let entryBlocks = blocks.compactMap { block -> (Range<Int>, Bool)? in
            guard case .entries(let range, let isFirst) = block else { return nil }
            return (range, isFirst)
        }

        XCTAssertEqual(entryBlocks.count, 3)
        // Written against the constant rather than its value: what this test is about is that
        // the log is cut into whole slices with the remainder last, and re-tuning the slice
        // size — which `testTheWorstSliceEitherTableCanProduceStillFitsOnAPage` governs — is
        // not supposed to drag an unrelated test along with it.
        let size = ReportBlock.entriesPerBlock
        XCTAssertEqual(entryBlocks.map(\.0.count), [size, size, 1])
        // Only the first slice carries the heading, so it cannot be orphaned at a page foot.
        XCTAssertEqual(entryBlocks.map(\.1), [true, false, false])
    }

    @MainActor
    func testThePreviewDrawsEverythingExceptTheLog() {
        let blocks = ReportBlock.preview(for: report(checkIns: (0..<20).map(checkIn(offset:))))

        XCTAssertFalse(blocks.contains { if case .entries = $0 { return true } else { return false } })
        XCTAssertTrue(blocks.contains(.disclaimer))
        XCTAssertTrue(blocks.contains(.summary))
    }

    // MARK: - Fitting

    /// The worst slice the domain can produce still fits on a page.
    ///
    /// This is the assertion the whole fixed-slice design rests on, and the one whose absence
    /// let a real defect ship: `entriesPerBlock` was set from an estimate of what a row costs,
    /// the estimate was low by a factor of three, and a slice that measured taller than the page
    /// was drawn onto it anyway — the page is a fixed frame over a fixed media box, so the rows
    /// that did not fit were cropped out of the document along with the running footer, silently.
    ///
    /// Measured through `ReportPDFRenderer.height(of:in:locale:calendar:)`, the same call the
    /// renderer paginates with. Ukrainian on purpose: it sets the longer of the two shipped
    /// languages against the bound.
    @MainActor
    func testTheWorstSliceEitherTableCanProduceStillFitsOnAPage() {
        let report = worstCaseReport()

        let entries = ReportPDFRenderer.height(of: .entries(range: 0..<ReportBlock.entriesPerBlock,
                                                            isFirst: true),
                                               in: report,
                                               locale: Locale(identifier: "uk_UA"),
                                               calendar: calendar)
        let medications = ReportPDFRenderer.height(
            of: .medications(range: 0..<ReportBlock.medicationsPerBlock, isFirst: true),
            in: report,
            locale: Locale(identifier: "uk_UA"),
            calendar: calendar
        )

        // Headroom rather than a bare fit. A slice landing within a few points of the budget
        // would pass here and break on the next font metric or the next translation.
        let ceiling = ReportDocumentMetrics.contentHeight * 0.8
        XCTAssertLessThan(entries, ceiling)
        XCTAssertLessThan(medications, ceiling)
    }

    /// Every free-text field of a check-in at the largest the app permits.
    ///
    /// A note at `ReportEntry.noteCharacterLimit`, more tags than the row can show and each at
    /// `WellbeingTag.maximumNameLength`, and more medications than it can show — with names of
    /// no particular length, because `MedicationEntry` imposes none.
    private func worstCaseReport() -> WellbeingReport {
        let generatedAt = date(2026, 8, 14, hour: 15)
        let note = String(repeating: "тиск падав з самого ранку і голова важка, ", count: 20)

        let tags = (0..<12).map {
            WellbeingTag(id: .user(UUID()),
                         name: String(repeating: "довга назва позначки \($0) ", count: 4))
        }

        let checkIns = (0..<ReportBlock.entriesPerBlock).map { offset -> CheckIn in
            let timestamp = generatedAt.addingTimeInterval(Double(-offset) * 86_400)
            let medications = (0..<ReportBlock.medicationsPerBlock).compactMap { index in
                MedicationEntry(name: "Препарат із дуже довгою назвою номер \(index)",
                                dose: "400 мг двічі на добу",
                                takenAt: timestamp)
            }
            return CheckIn(timestamp: timestamp,
                           intensity: CheckInIntensity(clamping: 7),
                           tagIDs: Set(tags.map(\.id)),
                           medications: medications,
                           note: note)
        }

        return ReportBuilder.make(period: .twelveMonths,
                                  window: ReportPeriod.twelveMonths.window(endingOn: generatedAt,
                                                                           calendar: calendar),
                                  generatedAt: generatedAt,
                                  profile: nil,
                                  checkIns: checkIns,
                                  pressureSamples: [],
                                  healthReadingCount: 0,
                                  tagsByID: Dictionary(uniqueKeysWithValues: tags.map { ($0.id, $0) }),
                                  calendar: calendar)
    }

    // MARK: - Rendering

    @MainActor
    func testTheRendererProducesAnA4DocumentWithInkOnItsFirstPage() async throws {
        let data = try await ReportPDFRenderer.render(report(checkIns: (0..<9).map(checkIn(offset:))),
                                                      locale: Locale(identifier: "uk_UA"),
                                                      calendar: calendar)

        let document = try XCTUnwrap(CGPDFDocument(try XCTUnwrap(CGDataProvider(data: data as CFData))))
        XCTAssertGreaterThan(document.numberOfPages, 1)

        let page = try XCTUnwrap(document.page(at: 1))
        let box = page.getBoxRect(.mediaBox)
        XCTAssertEqual(box.width, ReportDocumentMetrics.pageSize.width, accuracy: 0.5)
        XCTAssertEqual(box.height, ReportDocumentMetrics.pageSize.height, accuracy: 0.5)

        // A renderer that silently produced blank sheets would pass every assertion above.
        XCTAssertGreaterThan(inkFraction(of: page, box: box), 0.005)
    }

    /// Fraction of the page that is not the paper colour.
    private func inkFraction(of page: CGPDFPage, box: CGRect) -> Double {
        let width = Int(box.width / 2)
        let height = Int(box.height / 2)
        var pixels = [UInt8](repeating: 0, count: width * height)

        guard let context = CGContext(data: &pixels,
                                      width: width,
                                      height: height,
                                      bitsPerComponent: 8,
                                      bytesPerRow: width,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
        else {
            return 0
        }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: 0.5, y: 0.5)
        context.drawPDFPage(page)

        return Double(pixels.count { $0 < 240 }) / Double(pixels.count)
    }

    // MARK: - Helpers

    private func report(checkIns: [CheckIn]) -> WellbeingReport {
        let generatedAt = date(2026, 8, 14, hour: 15)
        let tag = WellbeingTag(id: .seeded("fatigue"), name: "Fatigue")

        return ReportBuilder.make(period: .oneMonth,
                                  window: ReportPeriod.oneMonth.window(endingOn: generatedAt,
                                                                       calendar: calendar),
                                  generatedAt: generatedAt,
                                  profile: UserProfile(displayName: "Олена",
                                                       ageYears: 34,
                                                       gender: .female),
                                  checkIns: checkIns,
                                  pressureSamples: pressure(),
                                  healthReadingCount: 128,
                                  tagsByID: [tag.id: tag],
                                  calendar: calendar)
    }

    /// One check-in per day, walking backwards from the 14th so they all land in the window.
    private func checkIn(offset: Int) -> CheckIn {
        let timestamp = date(2026, 8, 14, hour: 9).addingTimeInterval(Double(-offset) * 86_400)
        let medication = MedicationEntry(name: "Ібупрофен", dose: "400 мг", takenAt: timestamp)

        return CheckIn(timestamp: timestamp,
                       intensity: CheckInIntensity(clamping: offset % 10 + 1),
                       tagIDs: [.seeded("fatigue")],
                       medications: offset.isMultiple(of: 2) ? [medication].compactMap { $0 } : [],
                       note: offset == 0 ? "тиск падав з ранку" : nil)
    }

    private func pressure() -> [PressureSample] {
        (0..<30).map { day in
            PressureSample(timestamp: date(2026, 8, 14, hour: 12)
                .addingTimeInterval(Double(-day) * 86_400),
                           pressure: Pressure(hectopascals: 1008 + Double(day % 7)))
        }
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
}
