import XCTest
@testable import Barosense

/// The rules behind the watch's quick check-in form.
///
/// The reason this model was moved into `Shared/` — a class carrying the whole of the watch's
/// check-in behaviour with no test target able to reach it was the one gap in an otherwise
/// well-covered change.
@MainActor
final class WatchLogModelTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_770_000_000)

    private func model(tags: [WatchTag] = [],
                       link: any CheckInTransferLink = RecordingTransferLink()) -> WatchLogModel {
        WatchLogModel(tags: tags, link: link, now: { [now] in now })
    }

    private var seedTags: [WatchTag] { WatchTag.offered(from: WellbeingTag.seeds) }

    // MARK: - Intensity

    /// Documented as a known bias rather than a neutral default: a user who saves without
    /// touching the control records a 5 they did not choose. Pinned so the bias cannot drift
    /// silently, and so the phone's form and this one keep opening on the same value.
    func testTheFormOpensAtTheMiddleOfTheScale() {
        XCTAssertEqual(model().intensity.rawValue, 5)
    }

    func testTheWholeScaleIsReachable() {
        let subject = model()

        for _ in CheckInIntensity.scale { subject.decrease() }
        XCTAssertEqual(subject.intensity.rawValue, CheckInIntensity.scale.lowerBound)

        for _ in CheckInIntensity.scale { subject.increase() }
        XCTAssertEqual(subject.intensity.rawValue, CheckInIntensity.scale.upperBound)
    }

    /// The buttons and the crown both run through this, so a step past the end must clamp
    /// rather than wrap — a 10 that became a 1 would invert the label.
    func testSteppingPastEitherEndClamps() {
        let subject = model()

        for _ in 0...20 { subject.increase() }
        XCTAssertEqual(subject.intensity.rawValue, CheckInIntensity.scale.upperBound)
        XCTAssertFalse(subject.canIncrease)

        for _ in 0...20 { subject.decrease() }
        XCTAssertEqual(subject.intensity.rawValue, CheckInIntensity.scale.lowerBound)
        XCTAssertFalse(subject.canDecrease)
    }

    // MARK: - Tags

    func testATagTogglesOnAndOffAgain() {
        let subject = model(tags: seedTags)
        let headache = WellbeingTag.ID.seeded("headache")

        subject.toggle(headache)
        XCTAssertEqual(subject.selectedTagIDs, [headache])

        subject.toggle(headache)
        XCTAssertTrue(subject.selectedTagIDs.isEmpty)
    }

    /// The chips are whatever the phone published, in the order it published them — the watch
    /// does not hold its own vocabulary and must not reorder the one it is given.
    func testTheOfferedChipsAreTheOnesThePhonePublished() {
        XCTAssertEqual(model(tags: seedTags).tags, seedTags)
    }

    // MARK: - Saving

    func testSavingQueuesWhatTheUserChose() throws {
        let link = RecordingTransferLink()
        let subject = model(tags: seedTags, link: link)
        subject.increase()
        subject.toggle(.seeded("headache"))

        subject.save()

        let queued = try XCTUnwrap(link.transferred.first)
        XCTAssertEqual(queued.intensity.rawValue, 6)
        XCTAssertEqual(queued.tagIDs, [.seeded("headache")])
        XCTAssertTrue(subject.hasSaved)
        XCTAssertNil(subject.failure)
    }

    /// Stamped with the watch's clock at the moment the user commits, not with the instant the
    /// phone receives it — which can be hours later. A check-in filed against the wrong weather
    /// is worse than no check-in.
    func testTheReportIsStampedWhenTheUserCommits() throws {
        let link = RecordingTransferLink()
        let subject = model(link: link)

        subject.save()

        XCTAssertEqual(try XCTUnwrap(link.transferred.first).timestamp, now)
    }

    /// Terminal by design: the form closes on a save, and a second one would file a duplicate
    /// report the user did not make.
    func testTheFormDoesNotAcceptASecondReport() {
        let link = RecordingTransferLink()
        let subject = model(link: link)

        subject.save()
        XCTAssertFalse(subject.canSave)

        subject.save()
        XCTAssertEqual(link.transferred.count, 1)
    }

    /// A refused hand-off is reported rather than confirmed. The action stays live and the
    /// user's input stays on screen, which is the whole reason `canSave` is not also gated on
    /// whether the link is usable.
    func testARefusedHandOffIsReportedAndLeavesTheFormUsable() {
        let subject = model(link: NoOpCheckInTransferLink())

        subject.save()

        XCTAssertEqual(subject.failure, .couldNotQueue)
        XCTAssertFalse(subject.hasSaved)
        XCTAssertTrue(subject.canSave)
    }

    func testARetryAfterAFailureClearsTheFailure() {
        let link = RecordingTransferLink(refusals: 1)
        let subject = model(link: link)

        subject.save()
        XCTAssertEqual(subject.failure, .couldNotQueue)

        subject.save()

        XCTAssertNil(subject.failure)
        XCTAssertTrue(subject.hasSaved)
        XCTAssertEqual(link.transferred.count, 1)
    }

    /// Nothing is confirmed that did not happen: a failed hand-off must not raise the tick.
    func testAFailedHandOffNeverShowsAConfirmation() {
        let subject = model(link: NoOpCheckInTransferLink())

        subject.save()

        XCTAssertFalse(subject.hasSaved)
    }
}

// MARK: - Doubles

/// Records what was queued, and can refuse the first `refusals` attempts.
private final class RecordingTransferLink: CheckInTransferLink, @unchecked Sendable {

    private let lock = NSLock()
    private var _transferred: [WatchCheckIn] = []
    private var remainingRefusals: Int

    init(refusals: Int = 0) {
        remainingRefusals = refusals
    }

    var transferred: [WatchCheckIn] { lock.withLock { _transferred } }

    func transfer(_ checkIn: WatchCheckIn) throws {
        try lock.withLock {
            if remainingRefusals > 0 {
                remainingRefusals -= 1
                throw CheckInTransferError.linkUnavailable
            }
            _transferred.append(checkIn)
        }
    }
}
