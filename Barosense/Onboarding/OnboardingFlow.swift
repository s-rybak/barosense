import SwiftUI

/// The onboarding flow: one step on screen at a time, in the order `OnboardingStep`
/// declares (Figma `7:338`).
///
/// Every step after the first offers a way back, which the six frames do not draw. The design's
/// reasoning was that nothing here can be got wrong — every answer except the terms checkbox is
/// optional, and a mistyped name is fixed in settings later. That holds for the *name*, and not
/// for the rest: a tag turned off, a frequency tapped by mistake or the wrong episode duration
/// are all one tap and none of them can be seen again from a later step. Settings can repair
/// them afterwards, but only for someone who knows what they picked.
struct OnboardingFlow: View {

    @State private var model: OnboardingModel

    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         sensorAccess: any SensorAccessRequesting,
         onFinished: @escaping () -> Void) {
        _model = State(initialValue: OnboardingModel(profileStore: profileStore,
                                                     tagStore: tagStore,
                                                     sensorAccess: sensorAccess,
                                                     onFinished: onFinished))
    }

    var body: some View {
        step
            .id(model.step)
            .transition(slide)
            // The steps carry their own background edge to edge, and the keyboard on the
            // opening step must not push the pinned action off screen.
            .background(model.step == .ready ? Palette.ink : Palette.surface)
            .ignoresSafeArea(.keyboard, edges: .bottom)
            // Read by `OnboardingStepScaffold`, which draws the control.
            .environment(\.onboardingBack, back)
    }

    /// `nil` on the opening step, where the chevron is hidden rather than dimmed: there is
    /// nothing to explain about a step that is the first one.
    private var back: OnboardingBack? {
        guard model.canGoBack else { return nil }

        return { model.goBack() }
    }

    /// Steps enter from the side they are travelling from, so going back undoes the movement
    /// that brought the user here rather than looking like another step forward.
    private var slide: AnyTransition {
        guard model.isMovingBack else {
            return .asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                               removal: .move(edge: .leading).combined(with: .opacity))
        }
        return .asymmetric(insertion: .move(edge: .leading).combined(with: .opacity),
                           removal: .move(edge: .trailing).combined(with: .opacity))
    }

    @ViewBuilder
    private var step: some View {
        switch model.step {
        case .profile: ProfileStep(model: model)
        case .tags: TagsStep(model: model)
        case .pattern: PatternStep(model: model)
        case .terms: TermsStep(model: model)
        case .health: HealthStep(model: model)
        case .ready: ReadyStep(model: model)
        }
    }
}

#Preview {
    OnboardingFlow(profileStore: InMemoryUserProfileStore(),
                   tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                   sensorAccess: NoOpSensorAccess(),
                   onFinished: {})
}
