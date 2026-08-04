import XCTest
@testable import Barosense

final class CheckInTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    // MARK: - Storage format

    func testScoreRawValuesAreTheOneToFiveScale() {
        // Raw values are the persisted format and are also what the 1–5 UI and every
        // reported metric assume. Renumbering them silently rewrites stored history.
        XCTAssertEqual(WellbeingScore.allCases.map(\.rawValue), [1, 2, 3, 4, 5])
        XCTAssertEqual(WellbeingScore.veryPoor.rawValue, 1)
        XCTAssertEqual(WellbeingScore.veryGood.rawValue, 5)
    }

    func testTagRawValuesAreStable() {
        XCTAssertEqual(Set(WellbeingTag.allCases.map(\.rawValue)),
                       ["headache", "fatigue", "joints"])
    }

    func testCheckInSurvivesACodableRoundTrip() throws {
        let original = CheckIn(timestamp: referenceDate,
                               score: .poor,
                               tags: [.headache, .fatigue],
                               note: "Woke up early")

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
    }

    func testCheckInWithoutTagsOrNoteRoundTrips() throws {
        let original = CheckIn(timestamp: referenceDate, score: .veryGood)

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.tags.isEmpty)
        XCTAssertNil(decoded.note)
    }

    // MARK: - Ordering

    func testScoresCompareAlongTheScale() {
        XCTAssertLessThan(WellbeingScore.veryPoor, WellbeingScore.poor)
        XCTAssertLessThan(WellbeingScore.poor, WellbeingScore.fair)
        XCTAssertEqual(WellbeingScore.allCases.sorted(), WellbeingScore.allCases)
    }

    // MARK: - Label

    func testBottomTwoScoresArePoorWellbeingEvents() {
        for score in [WellbeingScore.veryPoor, .poor] {
            let checkIn = CheckIn(timestamp: referenceDate, score: score)
            XCTAssertTrue(checkIn.isPoorWellbeing, "score \(score.rawValue)")
        }
    }

    func testNeutralAndBetterScoresAreNotEvents() {
        for score in [WellbeingScore.fair, .good, .veryGood] {
            let checkIn = CheckIn(timestamp: referenceDate, score: score)
            XCTAssertFalse(checkIn.isPoorWellbeing, "score \(score.rawValue)")
        }
    }

    func testThresholdSitsBelowTheNeutralMidpoint() {
        // Pins the boundary itself, not just the outcomes: moving the threshold to
        // `.fair` would fold the neutral middle into the positive class and change every
        // stored metric. That has to fail here first.
        XCTAssertEqual(WellbeingLabel.poorWellbeingThreshold, .poor)
        XCTAssertLessThan(WellbeingLabel.poorWellbeingThreshold, .fair)
    }

    func testTagsDoNotAffectTheLabel() {
        let tagged = CheckIn(timestamp: referenceDate, score: .fair, tags: [.headache])
        let untagged = CheckIn(timestamp: referenceDate, score: .fair)

        XCTAssertFalse(tagged.isPoorWellbeing)
        XCTAssertEqual(tagged.isPoorWellbeing, untagged.isPoorWellbeing)
    }
}
