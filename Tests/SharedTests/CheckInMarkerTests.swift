import XCTest
@testable import Barosense

/// Placement of check-ins onto the drawn pressure line.
///
/// The property under test throughout is that a dot is either **on the line** or **absent** —
/// never somewhere plausible-looking that no measurement supports.
final class CheckInMarkerTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func sample(_ offsetMinutes: Double, _ hectopascals: Double) -> PressureSample {
        PressureSample(timestamp: referenceDate.addingTimeInterval(offsetMinutes * 60),
                       pressure: Pressure(hectopascals: hectopascals))
    }

    private func checkIn(_ offsetMinutes: Double,
                         _ score: WellbeingScore = .fair) -> CheckIn {
        CheckIn(timestamp: referenceDate.addingTimeInterval(offsetMinutes * 60), score: score)
    }

    // MARK: - Placement

    func testMarkerSitsOnTheLineBetweenTwoReadings() {
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(20)], on: line)

        XCTAssertEqual(placed.count, 1)
        // A third of the way along a 6 hPa rise.
        XCTAssertEqual(placed.first?.hectopascals ?? 0, 1002, accuracy: 0.0001)
    }

    func testMarkerOnAReadingTakesThatReadingsValue() {
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(60)], on: line)

        XCTAssertEqual(placed.first?.hectopascals ?? 0, 1006, accuracy: 0.0001)
    }

    func testMarkerKeepsItsOwnTimestampRatherThanTheReadings() {
        // The dot marks when the user logged it. Snapping it to the nearest reading would
        // move a check-in by up to half a bucket.
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(20)], on: line)

        XCTAssertEqual(placed.first?.timestamp, referenceDate.addingTimeInterval(20 * 60))
    }

    func testMarkerCarriesTheCheckInsIdentityAndScore() {
        // Identity is what keeps `ForEach` stable across a redraw, and the score is what the
        // chart colours the dot by.
        let source = CheckIn(timestamp: referenceDate.addingTimeInterval(600), score: .veryPoor)

        let placed = CheckInMarker.place([source], on: [sample(0, 1000), sample(60, 1006)])

        XCTAssertEqual(placed.first?.id, source.id)
        XCTAssertEqual(placed.first?.score, .veryPoor)
    }

    // MARK: - Ends of the line

    func testCheckInAfterTheNewestReadingClampsToIt() {
        // The ordinary case: a check-in logged now, against a barometer log whose newest
        // reading is by definition already in the past.
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(90)], on: line)

        XCTAssertEqual(placed.first?.hectopascals ?? 0, 1006, accuracy: 0.0001)
    }

    func testCheckInBeyondToleranceAfterTheNewestReadingIsDropped() {
        let line = [sample(0, 1000), sample(60, 1006)]

        // 3 h past the last reading, tolerance is 2 h.
        let placed = CheckInMarker.place([checkIn(60 + 180)], on: line)

        XCTAssertTrue(placed.isEmpty)
    }

    func testCheckInBeforeTheOldestReadingClampsToIt() {
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(-30)], on: line)

        XCTAssertEqual(placed.first?.hectopascals ?? 0, 1000, accuracy: 0.0001)
    }

    func testCheckInBeyondToleranceBeforeTheOldestReadingIsDropped() {
        let line = [sample(0, 1000), sample(60, 1006)]

        let placed = CheckInMarker.place([checkIn(-180)], on: line)

        XCTAssertTrue(placed.isEmpty)
    }

    func testToleranceBoundaryIsInclusive() {
        let line = [sample(0, 1000)]
        let tolerance = CheckInMarker.placementToleranceSeconds / 60

        XCTAssertEqual(CheckInMarker.place([checkIn(tolerance)], on: line).count, 1)
        XCTAssertTrue(CheckInMarker.place([checkIn(tolerance + 1)], on: line).isEmpty)
    }

    // MARK: - Degenerate input

    func testNothingIsPlacedWhenThereIsNoLine() {
        XCTAssertTrue(CheckInMarker.place([checkIn(0)], on: []).isEmpty)
    }

    func testNoCheckInsPlaceNothing() {
        XCTAssertTrue(CheckInMarker.place([], on: [sample(0, 1000)]).isEmpty)
    }

    func testTwoReadingsSharingATimestampDoNotDivideByZero() {
        let line = [sample(0, 1000), sample(0, 1004)]

        let placed = CheckInMarker.place([checkIn(0)], on: line)

        XCTAssertEqual(placed.count, 1)
        XCTAssertTrue(placed[0].hectopascals.isFinite)
    }

    func testMarkersComeBackAscendingWhateverOrderTheyArriveIn() {
        let line = [sample(0, 1000), sample(120, 1012)]
        let unordered = [checkIn(90), checkIn(10), checkIn(50)]

        let placed = CheckInMarker.place(unordered, on: line)

        XCTAssertEqual(placed.map(\.timestamp), placed.map(\.timestamp).sorted())
        XCTAssertEqual(placed.count, 3)
    }

    // MARK: - Through PressureSeries

    func testSeriesPlacesMarkersOnTheDrawnLineNotTheRawLog() {
        // `.day` buckets hourly. The first four raw readings average to 1003 at 00:22:30,
        // while the raw log around that instant reads 1000 — so the two placements are
        // distinguishable, and only one of them puts the dot on the line the user can see.
        let now = referenceDate.addingTimeInterval(120 * 60)
        let samples = [sample(0, 1000), sample(15, 1000), sample(30, 1000), sample(45, 1012),
                       sample(90, 1020)]

        let series = PressureSeries.make(from: samples,
                                         checkIns: [checkIn(22.5)],
                                         range: .day,
                                         asOf: now)

        XCTAssertEqual(series.checkIns.count, 1)
        XCTAssertEqual(series.checkIns.first?.hectopascals ?? 0, 1003, accuracy: 0.0001)
    }

    func testSeriesDropsCheckInsOutsideTheScrollableExtent() {
        let now = referenceDate
        let samples = [sample(-60, 1000), sample(0, 1004)]

        // `.oneHour` scrolls back twelve screenfuls — twelve hours. A check-in from
        // yesterday is outside it and belongs to a History screen, not this card.
        let series = PressureSeries.make(from: samples,
                                         checkIns: [checkIn(-24 * 60), checkIn(-30)],
                                         range: .oneHour,
                                         asOf: now)

        XCTAssertEqual(series.checkIns.count, 1)
        XCTAssertEqual(series.checkIns.first?.timestamp,
                       referenceDate.addingTimeInterval(-30 * 60))
    }

    func testSeriesWithNoCheckInsHasNoMarkers() {
        let series = PressureSeries.make(from: [sample(-30, 1000), sample(0, 1004)],
                                         range: .oneHour,
                                         asOf: referenceDate)

        XCTAssertTrue(series.checkIns.isEmpty)
        XCTAssertTrue(PressureSeries.empty().checkIns.isEmpty)
    }

    func testCheckInsAreNotPlacedWhenThePlotIsEmpty() {
        // No readings, so no line — the card takes its empty state and the check-in has
        // nothing to be drawn against.
        let series = PressureSeries.make(from: [],
                                         checkIns: [checkIn(-10)],
                                         range: .oneHour,
                                         asOf: referenceDate)

        XCTAssertTrue(series.isEmpty)
        XCTAssertTrue(series.checkIns.isEmpty)
    }
}
