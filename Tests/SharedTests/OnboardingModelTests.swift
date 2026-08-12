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
        // The tag step insists on at least one tag. That guards the commit, not the retreat —
        // a user who turned everything off must not be stuck on it.
        let model = makeModel()
        await model.load()
        model.advance()
        for tag in model.offeredTags { model.toggleTag(tag.id) }

        XCTAssertFalse(model.canLeaveCurrentStep)
        XCTAssertTrue(model.canGoBack)

        model.goBack()

        XCTAssertEqual(model.step, .profile)
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

    private func makeModel() -> OnboardingModel {
        OnboardingModel(profileStore: InMemoryUserProfileStore(),
                        tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                        onFinished: {})
    }

    /// A model that can actually be walked to the end: `load` supplies the tags the tag step
    /// insists on, and the terms box is the one other answer `canLeaveCurrentStep` requires.
    /// Without both, `advance` is a no-op partway through and the walk tests nothing.
    private func makeAnsweredModel() async -> OnboardingModel {
        let model = makeModel()
        await model.load()
        model.hasAcceptedTerms = true
        return model
    }
}
