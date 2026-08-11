import XCTest
@testable import Barosense

final class CheckInTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_770_000_000)

    private func intensity(_ value: Int) -> CheckInIntensity {
        CheckInIntensity(clamping: value)
    }

    // MARK: - Storage format

    func testIntensityRawValuesAreTheOneToTenScale() {
        // Raw values are the persisted format and are also what the 1–10 UI and every
        // reported metric assume. Renumbering them silently rewrites stored history.
        XCTAssertEqual(CheckInIntensity.allCases.map(\.rawValue), Array(1...10))
        XCTAssertEqual(CheckInIntensity.scale, 1...10)
    }

    func testIntensityRejectsValuesOffTheScale() {
        // The failable init is the read path from storage. A row written by a build that
        // knew a different scale has to be rejectable rather than clamped, or the label it
        // carries is fabricated.
        XCTAssertNil(CheckInIntensity(rawValue: 0))
        XCTAssertNil(CheckInIntensity(rawValue: 11))
        XCTAssertNil(CheckInIntensity(rawValue: -3))
        XCTAssertEqual(CheckInIntensity(rawValue: 1)?.rawValue, 1)
        XCTAssertEqual(CheckInIntensity(rawValue: 10)?.rawValue, 10)
    }

    func testClampingPinsOntoTheScale() {
        XCTAssertEqual(intensity(-4).rawValue, 1)
        XCTAssertEqual(intensity(99).rawValue, 10)
        XCTAssertEqual(intensity(6).rawValue, 6)
    }

    func testIntensityEncodesAsABareNumber() throws {
        // `RawRepresentable` gives single-value coding, so the JSON is `7` rather than
        // `{"rawValue":7}`. That is the storage format the watch→phone payload will carry.
        let encoded = try JSONEncoder().encode(intensity(7))

        XCTAssertEqual(String(decoding: encoded, as: UTF8.self), "7")
    }

    func testDecodingAnOffScaleIntensityFails() {
        // Same guarantee as the failable init, across the decoder: a payload carrying 0
        // must not produce a check-in at all.
        XCTAssertThrowsError(try JSONDecoder().decode(CheckInIntensity.self,
                                                      from: Data("0".utf8)))
    }

    func testCheckInSurvivesACodableRoundTrip() throws {
        let original = CheckIn(timestamp: referenceDate,
                               intensity: intensity(3),
                               tagIDs: [.seeded("fatigue"), .user(UUID())],
                               medications: [MedicationEntry(name: "Ibuprofen",
                                                             dose: "400 mg",
                                                             takenAt: referenceDate)!],
                               note: "Woke up early")

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
    }

    func testCheckInWithoutTagsMedicationOrNoteRoundTrips() throws {
        let original = CheckIn(timestamp: referenceDate, intensity: intensity(9))

        let decoded = try JSONDecoder().decode(CheckIn.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertTrue(decoded.tagIDs.isEmpty)
        XCTAssertTrue(decoded.medications.isEmpty)
        XCTAssertNil(decoded.note)
    }

    // MARK: - Ordering and position

    func testIntensitiesCompareAlongTheScale() {
        XCTAssertLessThan(intensity(1), intensity(2))
        XCTAssertLessThan(intensity(9), intensity(10))
        XCTAssertEqual(CheckInIntensity.allCases.sorted(), CheckInIntensity.allCases)
    }

    func testNormalizedSpansTheWholeTrack() {
        // The slider's thumb position and the colour ramp are both read from this, so the
        // ends have to be exactly 0 and 1 or the thumb never reaches either edge.
        XCTAssertEqual(intensity(1).normalized, 0, accuracy: 0.000_1)
        XCTAssertEqual(intensity(10).normalized, 1, accuracy: 0.000_1)
        XCTAssertEqual(intensity(6).normalized, 5.0 / 9.0, accuracy: 0.000_1)
    }

    func testPositionSnapsToTheNearestPoint() {
        XCTAssertEqual(CheckInIntensity(position: 0).rawValue, 1)
        XCTAssertEqual(CheckInIntensity(position: 1).rawValue, 10)
        // Just past halfway between 5 and 6 rounds up rather than truncating down.
        XCTAssertEqual(CheckInIntensity(position: 4.6 / 9.0).rawValue, 6)
        XCTAssertEqual(CheckInIntensity(position: 4.4 / 9.0).rawValue, 5)
    }

    func testPositionOutsideTheTrackClampsRatherThanWrapping() {
        // The drag gesture can report a point past either end of the track when the finger
        // leaves it, and that has to read as "the end", not as a value off the scale.
        XCTAssertEqual(CheckInIntensity(position: -2).rawValue, 1)
        XCTAssertEqual(CheckInIntensity(position: 8).rawValue, 10)
    }

    func testPositionAndNormalizedAreInverses() {
        for value in CheckInIntensity.allCases {
            XCTAssertEqual(CheckInIntensity(position: value.normalized), value)
        }
    }

    // MARK: - Label

    func testTopFourIntensitiesArePoorWellbeingEvents() {
        for value in [7, 8, 9, 10] {
            let checkIn = CheckIn(timestamp: referenceDate, intensity: intensity(value))
            XCTAssertTrue(checkIn.isPoorWellbeing, "intensity \(value)")
        }
    }

    func testTheMiddleAndBelowAreNotEvents() {
        for value in [1, 2, 3, 4, 5, 6] {
            let checkIn = CheckIn(timestamp: referenceDate, intensity: intensity(value))
            XCTAssertFalse(checkIn.isPoorWellbeing, "intensity \(value)")
        }
    }

    func testThresholdSitsAboveTheMiddleOfTheScale() {
        // Pins the boundary itself, not just the outcomes: moving it to 6 would fold the
        // middle into the positive class and change every stored metric. That has to fail
        // here first.
        XCTAssertEqual(WellbeingLabel.poorWellbeingThreshold.rawValue, 7)
        XCTAssertGreaterThan(WellbeingLabel.poorWellbeingThreshold, CheckInIntensity(clamping: 6))
    }

    func testTheEventBandIsTheSameFractionOfTheScaleAsTheFivePointOneWas() {
        // The form moved from a 1–5 scale whose bottom two points were events — 40% of the
        // range — to a 1–10 scale. The threshold was carried across to preserve that
        // fraction rather than re-chosen, so the event definition did not quietly move
        // with the resolution. Documented in `WellbeingLabel`; asserted here.
        let events = CheckInIntensity.allCases.filter {
            $0 >= WellbeingLabel.poorWellbeingThreshold
        }

        XCTAssertEqual(Double(events.count) / Double(CheckInIntensity.allCases.count), 0.4)
    }

    func testTagsAndMedicationDoNotAffectTheLabel() {
        let annotated = CheckIn(timestamp: referenceDate,
                                intensity: intensity(5),
                                tagIDs: [.seeded("fatigue")],
                                medications: [MedicationEntry(name: "Ibuprofen",
                                                              takenAt: referenceDate)!])
        let bare = CheckIn(timestamp: referenceDate, intensity: intensity(5))

        XCTAssertFalse(annotated.isPoorWellbeing)
        XCTAssertEqual(annotated.isPoorWellbeing, bare.isPoorWellbeing)
    }
}

/// `MedicationEntry` lives only inside a check-in, so its tests sit beside the check-in's.
final class MedicationEntryTests: XCTestCase {

    private let referenceDate = Date(timeIntervalSince1970: 1_700_000_000)

    func testABlankNameIsNotAnEntry() {
        // Rejected in the initialiser so no screen has to remember to check.
        XCTAssertNil(MedicationEntry(name: "", takenAt: referenceDate))
        XCTAssertNil(MedicationEntry(name: "   \n ", takenAt: referenceDate))
        XCTAssertNil(MedicationEntry(name: " ", dose: "400 mg", takenAt: referenceDate))
    }

    func testNameAndDoseAreTrimmed() {
        let entry = MedicationEntry(name: "  Ibuprofen ", dose: "  400 mg  ", takenAt: referenceDate)

        XCTAssertEqual(entry?.name, "Ibuprofen")
        XCTAssertEqual(entry?.dose, "400 mg")
    }

    func testABlankDoseBecomesNoDose() {
        // So "the user gave a dose" stays a meaningful distinction — the rule `CheckIn.note`
        // follows, applied to the same kind of optional free text.
        XCTAssertNil(MedicationEntry(name: "Ibuprofen", dose: "", takenAt: referenceDate)?.dose)
        XCTAssertNil(MedicationEntry(name: "Ibuprofen", dose: "   ", takenAt: referenceDate)?.dose)
        XCTAssertNil(MedicationEntry(name: "Ibuprofen", dose: nil, takenAt: referenceDate)?.dose)
    }

    func testTwoEntriesWithTheSameNameStayDistinct() {
        // The user may have taken the same thing twice, and nothing in this app is in a
        // position to decide they did not.
        let first = MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: referenceDate)
        let second = MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: referenceDate)

        XCTAssertNotEqual(first, second)
        XCTAssertNotEqual(first?.id, second?.id)
    }

    func testTheTakenTimeIsKeptExactlyAsGivenAndNotSnappedToTheCheckIn() throws {
        // The whole reason the sheet has a time control: something taken at 09:40 and
        // reported at 14:00 has to stay at 09:40 all the way through the check-in that
        // carries it.
        let taken = referenceDate.addingTimeInterval(-4 * 3600 - 20 * 60)
        let entry = try XCTUnwrap(MedicationEntry(name: "Ibuprofen", takenAt: taken))

        let checkIn = CheckIn(timestamp: referenceDate,
                              intensity: CheckInIntensity(clamping: 6),
                              medications: [entry])

        XCTAssertEqual(checkIn.medications.first?.takenAt, taken)
        XCTAssertNotEqual(checkIn.medications.first?.takenAt, checkIn.timestamp)
    }

    func testAnEntrySurvivesACodableRoundTrip() throws {
        let original = try XCTUnwrap(MedicationEntry(name: "Magnesium", takenAt: referenceDate))

        let decoded = try JSONDecoder().decode(MedicationEntry.self,
                                               from: JSONEncoder().encode(original))

        XCTAssertEqual(decoded, original)
        XCTAssertNil(decoded.dose)
        XCTAssertEqual(decoded.takenAt, referenceDate)
    }
}
