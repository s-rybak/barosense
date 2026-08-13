import XCTest
@testable import Barosense

/// The bar over how much history the device holds. Small arithmetic, but it is the number the
/// user reads as "how far along am I", so the ends of the scale are what matter.
final class TrainingDataProgressTests: XCTestCase {

    func testAnEmptyDeviceIsAtZero() {
        XCTAssertEqual(TrainingDataProgress(checkInCount: 0).fraction, 0)
    }

    func testTheTargetIsAFullBar() {
        let progress = TrainingDataProgress(checkInCount: TrainingDataProgress.targetCheckInCount)

        XCTAssertEqual(progress.fraction, 1)
        XCTAssertTrue(progress.hasReachedTarget)
        XCTAssertEqual(progress.remainingCheckIns, 0)
    }

    func testPastTheTargetTheBarStaysFull() {
        // There is no "more than full". A user with a year of history must not see a bar
        // running off the end of its own track.
        let progress = TrainingDataProgress(checkInCount: 400)

        XCTAssertEqual(progress.fraction, 1)
        XCTAssertEqual(progress.remainingCheckIns, 0)
    }

    func testHalfTheTargetIsHalfTheBar() {
        let half = TrainingDataProgress.targetCheckInCount / 2

        XCTAssertEqual(TrainingDataProgress(checkInCount: half).fraction, 0.5, accuracy: 0.0001)
    }

    func testWhatIsLeftCountsDownToTheTarget() {
        let progress = TrainingDataProgress(checkInCount: 19)

        XCTAssertEqual(progress.remainingCheckIns, TrainingDataProgress.targetCheckInCount - 19)
        XCTAssertFalse(progress.hasReachedTarget)
    }

    func testANegativeCountCannotDrawABarToTheLeftOfItsTrack() {
        let progress = TrainingDataProgress(checkInCount: -5)

        XCTAssertEqual(progress.checkInCount, 0)
        XCTAssertEqual(progress.fraction, 0)
    }

    func testTheTargetIsWhereThePersonalModelWouldOutweighThePrior() {
        // ml-spec §4 blends personal and prior with `w(n) = n / (n + k)`, k = 30. The target is
        // the count at which `w` first passes a half — the point the explainer sheet describes.
        // If the target moves without that reasoning moving with it, this fails.
        let blendK = 30.0
        let n = Double(TrainingDataProgress.targetCheckInCount)

        XCTAssertGreaterThan(n / (n + blendK), 0.5)
        XCTAssertLessThan((n - 15) / (n - 15 + blendK), 0.5)
    }
}
