import XCTest
@testable import Barosense

/// Moving through the onboarding flow. What each step *collects* is covered by the model
/// tests for the types it writes; this is about getting between the steps and, above all,
/// about getting back to one — an answer picked by mistake is invisible from the step after it.
@MainActor
final class OnboardingModelTests: XCTestCase {

    // MARK: - Order

    func testEveryStepKnowsTheOneBeforeIt() {
        XCTAssertNil(OnboardingStep.profile.previous)
        XCTAssertEqual(OnboardingStep.tags.previous, .profile)
        XCTAssertEqual(OnboardingStep.pattern.previous, .tags)
        XCTAssertEqual(OnboardingStep.terms.previous, .pattern)
        XCTAssertEqual(OnboardingStep.health.previous, .terms)
        XCTAssertEqual(OnboardingStep.ready.previous, .health)
    }

    func testPreviousAndNextAreInverses() {
        for step in OnboardingStep.allCases {
            XCTAssertEqual(step.next?.previous, step.next == nil ? nil : step)
        }
    }

    // MARK: - Going back

    func testTheOpeningStepHasNowhereToGoBackTo() {
        let model = makeModel()

        XCTAssertFalse(model.canGoBack)

        model.goBack()

        XCTAssertEqual(model.step, .profile)
    }

    func testBackReturnsToTheStepBefore() {
        let model = makeModel()
        model.advance()

        XCTAssertEqual(model.step, .tags)
        XCTAssertTrue(model.canGoBack)

        model.goBack()

        XCTAssertEqual(model.step, .profile)
    }

    func testBackIsOfferedOnEveryStepAfterTheFirst() async {
        // Including the closing one: the pattern answers are three steps behind it by then and
        // this is the last point at which they can be corrected before they are written.
        let model = await makeAnsweredModel()

        for expected in OnboardingStep.allCases.dropFirst() {
            model.advance()

            XCTAssertEqual(model.step, expected)
            XCTAssertTrue(model.canGoBack, "no way back from \(expected)")
        }
    }

    func testAnswersSurviveARoundTrip() {
        let model = makeModel()
        model.displayName = "Olena"
        model.ageText = "34"
        model.gender = .female

        model.advance()
        model.goBack()

        XCTAssertEqual(model.displayName, "Olena")
        XCTAssertEqual(model.ageText, "34")
        XCTAssertEqual(model.gender, .female)
    }

    func testGoingBackLetsAnAnswerBeChanged() async {
        // The whole point of the control: a frequency tapped by mistake is one tap to fix,
        // and the corrected answer is the one that goes forward.
        let model = await makeAnsweredModel()
        model.advance()
        model.advance()
        model.episodeFrequency = .daily

        model.advance()
        model.goBack()
        model.episodeFrequency = .weekly
        model.advance()

        XCTAssertEqual(model.step, .terms)
        XCTAssertEqual(model.episodeFrequency, .weekly)
    }

    func testBackIsAllowedOffAStepThatCannotBeLeftForwards() async {
        // The tag step insists on at least one tag and opens with none, so the state it
        // cannot be left in is the state it arrives in. That guards the commit, not the
        // retreat — a user who has chosen nothing must not be stuck on it.
        let model = makeModel()
        await model.load()
        model.advance()

        XCTAssertEqual(model.step, .tags)
        XCTAssertFalse(model.canLeaveCurrentStep)
        XCTAssertTrue(model.canGoBack)

        model.goBack()

        XCTAssertEqual(model.step, .profile)
    }

    // MARK: - Tags

    func testTheTagStepOpensWithNothingChosen() async {
        // A selected chip is filled with `ink`, so a vocabulary that arrives pre-selected
        // opens the step as a wall of dark pills — and answers "what best describes how you
        // feel" before the user has said anything.
        let model = makeModel()
        await model.load()

        XCTAssertFalse(model.offeredTags.isEmpty)
        XCTAssertTrue(model.selectedTagIDs.isEmpty)
    }

    func testTheTagStepOpensBlockedAndUnblocksOnTheFirstChoice() async throws {
        let model = makeModel()
        await model.load()
        model.step = .tags

        XCTAssertFalse(model.canLeaveCurrentStep)

        let first = try XCTUnwrap(model.offeredTags.first)
        model.toggleTag(first.id)

        XCTAssertEqual(model.selectedTagIDs, [first.id])
        XCTAssertTrue(model.canLeaveCurrentStep)
    }

    // MARK: - Permissions

    func testTheHealthStepAsksForBothSensorsInOrder() async {
        // The only place in the app that raises either sheet. Apple Health first: its request
        // returns once the sheet has been answered, so the Motion prompt cannot land on top
        // of a sheet the user is still reading.
        let access = RecordingSensorAccess()
        let model = makeModel(sensorAccess: access)
        model.step = .health

        await model.requestHealthAccess()

        XCTAssertEqual(access.requests, [.health, .barometer])
        XCTAssertTrue(model.wantsHealthAccess)
        XCTAssertEqual(model.step, .ready)
        XCTAssertFalse(model.isRequestingAccess)
    }

    func testSkippingTheHealthStepAsksForNothing() {
        let access = RecordingSensorAccess()
        let model = makeModel(sensorAccess: access)
        model.step = .health

        model.skipHealthAccess()

        XCTAssertTrue(access.requests.isEmpty)
        XCTAssertFalse(model.wantsHealthAccess)
        XCTAssertEqual(model.step, .ready)
    }

    func testASecondTapDoesNotAskTwice() async {
        // Two prompt pairs for one step would also mean two `advance()` calls, and the second
        // would run the closing commit from a step the user never saw.
        let access = RecordingSensorAccess()
        let model = makeModel(sensorAccess: access)
        model.step = .health

        let firstTap = Task { await model.requestHealthAccess() }
        let secondTap = Task { await model.requestHealthAccess() }
        await firstTap.value
        await secondTap.value

        XCTAssertEqual(access.requests, [.health, .barometer])
        XCTAssertEqual(model.step, .ready)
    }

    // MARK: - Direction

    func testTheFlowKnowsWhichWayTheLastMoveWent() {
        // Read by `OnboardingFlow` to slide the arriving step in from the side it comes from.
        let model = makeModel()

        model.advance()
        XCTAssertFalse(model.isMovingBack)

        model.goBack()
        XCTAssertTrue(model.isMovingBack)

        model.advance()
        XCTAssertFalse(model.isMovingBack)
    }

    // MARK: - Helpers

    private func makeModel(
        sensorAccess: any SensorAccessRequesting = NoOpSensorAccess()
    ) -> OnboardingModel {
        OnboardingModel(profileStore: InMemoryUserProfileStore(),
                        tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                        sensorAccess: sensorAccess,
                        onFinished: {})
    }

    /// A model that can actually be walked to the end: one tag chosen, because the step
    /// opens with none and insists on one, and the terms box, which is the one other answer
    /// `canLeaveCurrentStep` requires. Without both, `advance` is a no-op partway through
    /// and the walk tests nothing.
    private func makeAnsweredModel() async -> OnboardingModel {
        let model = makeModel()
        await model.load()
        if let first = model.offeredTags.first {
            model.toggleTag(first.id)
        }
        model.hasAcceptedTerms = true
        return model
    }
}

// MARK: - Doubles

/// Records what the Apple Health step asked the device for, and in what order — which is the
/// whole of what that step does.
@MainActor
private final class RecordingSensorAccess: SensorAccessRequesting {

    enum Request: Equatable {
        case health
        case barometer
    }

    private(set) var requests: [Request] = []

    func requestHealthAccess() async { requests.append(.health) }

    func requestBarometerAccess() async { requests.append(.barometer) }
}
