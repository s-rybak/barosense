import SwiftUI
import UIKit
import XCTest
@testable import Barosense

/// That the two new surfaces actually draw.
///
/// What a chart *looks* like is SwiftUI's business and is not assertable here. What is
/// assertable is the thing that would otherwise ship silently broken: that the marked stretch
/// reaches the plot as marks at all, and that the row renders ink rather than an empty frame.
/// A `RectangleMark` given an inverted range, or a stretch that no forward point falls inside,
/// both produce a plot that builds, runs, and shows nothing.
///
/// `BAROSENSE_RENDER_DIR` writes the bitmaps out, which is how the appearance was checked by
/// eye during development. Unset — the normal case, including CI — nothing is written.
@MainActor
final class RiskChartRenderTests: XCTestCase {

    private static let scale: CGFloat = 3

    func testMarkedStretchReachesThePlotAsDrawnMarks() throws {
        let series = try XCTUnwrap(Self.markedSeries)

        XCTAssertEqual(series.markedRanges.count, 1, "two adjacent windows are one stretch")
        let stretch = try XCTUnwrap(series.markedRanges.first)

        // The stroke needs at least two points or there is no segment to draw, and it has to
        // span the stretch its own band covers.
        let marked = series.forecastSegments.filter(\.isMarked)
        XCTAssertEqual(marked.count, 1, "one stretch is one run")
        let run = try XCTUnwrap(marked.first)
        XCTAssertGreaterThanOrEqual(run.points.count, 2)
        XCTAssertEqual(run.points.first?.timestamp, stretch.lowerBound)
        XCTAssertEqual(run.points.last?.timestamp, stretch.upperBound)

        // And the stretch sits inside the drawn domain, or Swift Charts clips it away.
        XCTAssertTrue(series.timeDomain.contains(stretch.lowerBound))
        XCTAssertTrue(series.timeDomain.contains(stretch.upperBound))
    }

    /// The forward half is **one** line, cut into coloured runs — not a line with a second one
    /// laid over part of it.
    ///
    /// The regression this guards is what the overlay looked like on device: two 3 pt dashed
    /// strokes on the same path, dash phases disagreeing, rendering as a doubled two-toned line.
    /// Three properties say the runs are a partition rather than an overlay — they cover every
    /// vertex, they meet exactly at their boundaries, and no hour is stroked twice in the same
    /// colour.
    func testForwardLineIsOneStrokeCutIntoColouredRuns() throws {
        let series = try XCTUnwrap(Self.markedSeries)
        let segments = series.forecastSegments

        XCTAssertGreaterThan(segments.count, 1, "a marked stretch means at least two runs")
        XCTAssertTrue(segments.allSatisfy { $0.points.count >= 2 },
                      "a run of one point draws nothing at all")

        // Consecutive runs share their boundary vertex and overlap in nothing else.
        for (earlier, later) in zip(segments, segments.dropFirst()) {
            XCTAssertEqual(earlier.points.last, later.points.first,
                           "runs join at a shared vertex")
            XCTAssertNotEqual(earlier.isMarked, later.isMarked,
                              "two runs of the same colour would be one run")
        }

        // Every drawn vertex appears, and every interior hour exactly once.
        let joined = segments.flatMap(\.points)
        let distinct = Set(joined.map(\.timestamp))
        XCTAssertEqual(joined.count, distinct.count + segments.count - 1,
                       "only the boundaries are shared")
        XCTAssertEqual(distinct.count, series.forecast.count + 1,
                       "the curve plus the measurement it departs from")
        XCTAssertEqual(segments.first?.points.first?.timestamp,
                       series.forecastJoin?.timestamp)
        XCTAssertEqual(segments.last?.points.last?.timestamp,
                       series.forecast.last?.timestamp)
    }

    /// A stretch beyond what this range draws is clipped, not handed to the chart as a mark
    /// outside its own scale.
    func testStretchBeyondTheDrawnHorizonIsClipped() throws {
        let now = Date.now
        let far = now.addingTimeInterval(20 * 3600)

        let series = PressureSeries.make(
            from: Self.samples(asOf: now),
            forecast: Self.forecast(asOf: now, hours: 4),
            risk: WellbeingRiskForecast(
                dayStart: now,
                checkInProbability: 0.8,
                windows: [],
                marked: [ScoredRiskWindow(start: far,
                                          end: far.addingTimeInterval(2 * 3600),
                                          dayStart: now,
                                          confidence: 0.9, combined: 0.7,
                                          forecastShare: 1, isMarked: true)],
                isDayQuiet: false, mayNotify: true, isColdStart: false,
                dayCoverage: 1, forecastShare: 1
            ),
            range: .oneHour,
            asOf: now
        )

        XCTAssertTrue(series.markedRanges.isEmpty)
    }

    /// A stretch on a later day is drawn, because the widest button draws four days of curve.
    ///
    /// The counterpart to the clipping test above: what is cut is what runs past the drawn
    /// horizon, not what runs past midnight. While the model scored one day this was
    /// unreachable — there was nothing after today to mark.
    func testAStretchTomorrowIsDrawnOnTheDayRange() throws {
        let now = Self.referenceNow
        let tomorrow = now.addingTimeInterval(30 * 3600)

        let series = PressureSeries.make(
            from: Self.samples(asOf: now),
            forecast: Self.forecast(asOf: now, hours: 90),
            risk: WellbeingRiskForecast(
                dayStart: now,
                checkInProbability: 0.2,
                windows: [],
                marked: [ScoredRiskWindow(start: tomorrow,
                                          end: tomorrow.addingTimeInterval(2 * 3600),
                                          dayStart: now.addingTimeInterval(24 * 3600),
                                          confidence: 0.9, combined: 0.4,
                                          forecastShare: 1, isMarked: true)],
                isDayQuiet: false, mayNotify: false, isColdStart: false,
                dayCoverage: 1, forecastShare: 1
            ),
            range: .day,
            asOf: now
        )

        XCTAssertEqual(series.markedRanges.count, 1)
        XCTAssertEqual(series.forecastSegments.filter(\.isMarked).count, 1)
        XCTAssertTrue(series.timeDomain.contains(tomorrow))
    }

    /// No forward curve, nothing to mark: a stretch has no line to be drawn on.
    func testNoForecastMeansNoMarkedStretch() {
        let now = Date.now
        let series = PressureSeries.make(from: Self.samples(asOf: now),
                                         risk: .preview(marked: [0, 1], chance: 0.8,
                                                        cold: false, asOf: now),
                                         range: .sixHours,
                                         asOf: now)

        XCTAssertTrue(series.markedRanges.isEmpty)
    }

    /// The stretch reaches the screen, not just the data.
    ///
    /// 317 × 110 is the card's own plot box: 351 pt of card less 2 × 17 pt of padding, at
    /// `PressureChartCard.Metrics.plotHeight`.
    func testPlotDrawsTheMarkedStretch() throws {
        let box = CGSize(width: 317, height: 110)

        let plain = try snapshot(PressureChartPlot(series: Self.plainSeries),
                                 size: box, name: "plot-plain")
        let marked = try snapshot(PressureChartPlot(series: try XCTUnwrap(Self.markedSeries)),
                                  size: box, name: "plot-marked")

        // A blank plot is one colour. The line alone is several hundred; the stretch adds the
        // band and the warm stroke on top of it.
        XCTAssertGreaterThan(Self.distinctColourCount(plain), 100)
        XCTAssertGreaterThan(Self.distinctColourCount(marked),
                             Self.distinctColourCount(plain),
                             "the marked stretch has to add ink, not merely data")
        XCTAssertNotEqual(marked, plain)
    }

    func testRiskRowDrawsBothStates() throws {
        let box = CGSize(width: 317, height: 60)

        let marked = try snapshot(RiskSummaryRow(risk: .previewMarked), size: box, name: "row-marked")
        let quiet = try snapshot(RiskSummaryRow(risk: .previewQuiet), size: box, name: "row-quiet")

        XCTAssertGreaterThan(Self.distinctColourCount(marked), 1)
        XCTAssertGreaterThan(Self.distinctColourCount(quiet), 1)
        // The quiet state says something different: no stretch, and the cold-start note instead.
        XCTAssertNotEqual(marked, quiet)
    }

    // MARK: - Rendering

    /// Snapshots through a real key window rather than `ImageRenderer`.
    ///
    /// Not a preference. `ImageRenderer` does not run the layout pass that
    /// `chartScrollPosition(initialX:)` depends on, so a scrollable chart rendered through it
    /// stays parked at the start of its domain — which for this plot is twelve screenfuls of
    /// empty history — and comes back as a blank rectangle whatever the marks say. Measured:
    /// one distinct colour through `ImageRenderer`, 1 171 through a window.
    private func snapshot(_ view: some View, size: CGSize, name: String) throws -> Data {
        let host = UIHostingController(rootView: view.frame(width: size.width, height: size.height))
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.frame = CGRect(origin: .zero, size: size)
        host.view.layoutIfNeeded()
        // Swift Charts applies the initial scroll offset on a later turn of the run loop.
        RunLoop.current.run(until: Date().addingTimeInterval(0.4))

        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { _ in
            host.view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
        }
        let data = try XCTUnwrap(image.pngData(), "\(name) produced no PNG")

        // `TEST_RUNNER_BAROSENSE_RENDER_DIR=<path>` on the xcodebuild invocation writes the
        // bitmaps out, which is how the appearance was checked by eye. Unset — the normal case,
        // including CI — nothing is written.
        if let directory = ProcessInfo.processInfo.environment["BAROSENSE_RENDER_DIR"] {
            try? data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
        return data
    }

    /// Whether the bitmap holds anything but its own background.
    ///
    /// A view that lays out but draws nothing still produces a valid PNG of the right size, so
    /// "the renderer returned an image" is not the assertion worth making.
    private static func distinctColourCount(_ png: Data) -> Int {
        guard let image = UIImage(data: png), let cgImage = image.cgImage else { return 0 }

        let width = cgImage.width
        let height = cgImage.height
        var pixels = [UInt8](repeating: 0, count: width * height * 4)

        guard let context = CGContext(data: &pixels,
                                      width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return 0 }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        return Set(stride(from: 0, to: pixels.count, by: 4).map {
            Array(pixels[$0..<($0 + 4)])
        }).count
    }

    // MARK: - Fixtures

    private static let referenceNow = Date(timeIntervalSince1970: 1_787_000_000)

    private static var plainSeries: PressureSeries {
        .make(from: samples(asOf: referenceNow),
              forecast: forecast(asOf: referenceNow, hours: 12),
              range: .sixHours,
              asOf: referenceNow)
    }

    /// A falling six hours with a forward half, and two adjacent windows marked on it.
    private static var markedSeries: PressureSeries {
        let now = referenceNow
        let width = TimeInterval(RiskWindowGeometry.windowMinutes) * 60
        let dayStart = RiskPressureGrid.alignedHour(of: now)

        let windows = (0..<9).map { index in
            ScoredRiskWindow(start: dayStart.addingTimeInterval(Double(index) * width),
                             end: dayStart.addingTimeInterval(Double(index + 1) * width),
                             dayStart: dayStart,
                             confidence: (1...2).contains(index) ? 0.9 : 0.2,
                             combined: 0.7,
                             forecastShare: 1,
                             isMarked: (1...2).contains(index))
        }

        return .make(from: samples(asOf: now),
                     forecast: forecast(asOf: now, hours: 12),
                     risk: WellbeingRiskForecast(dayStart: dayStart,
                                                 checkInProbability: 0.78,
                                                 windows: windows,
                                                 marked: windows.filter(\.isMarked),
                                                 isDayQuiet: false,
                                                 mayNotify: true,
                                                 isColdStart: false,
                                                 dayCoverage: 1,
                                                 forecastShare: 1),
                     range: .sixHours,
                     asOf: now)
    }

    private static func samples(asOf now: Date) -> [PressureSample] {
        let values: [Double] = [1016.2, 1015.8, 1015.1, 1014.2, 1013.4, 1012.6, 1012.1]
        return values.enumerated().map { index, hectopascals in
            PressureSample(timestamp: now.addingTimeInterval(TimeInterval(index - 6) * 3600),
                           pressure: Pressure(hectopascals: hectopascals))
        }
    }

    private static func forecast(asOf now: Date, hours: Int) -> [ForecastPressurePoint] {
        let anchor = RiskPressureGrid.alignedHour(of: now)
        return (1...hours).map { step in
            ForecastPressurePoint(timestamp: anchor.addingTimeInterval(Double(step) * 3600),
                                  pressure: Pressure(hectopascals: 1012.1 - Double(step) * 0.45),
                                  uncertaintyHPa: 0.5 + Double(step) * 0.08,
                                  source: .weatherKit,
                                  issuedAt: now)
        }
    }
}
