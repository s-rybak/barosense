import SwiftUI

/// The onboarding flow: one step on screen at a time, in the order `OnboardingStep`
/// declares (Figma `7:338`).
///
/// There is no way back, matching the design — none of the six frames draws a back
/// control. Every answer except the terms checkbox is optional, so nothing here can be
/// got wrong in a way that has to be undone; a mistyped name is fixed in settings later.
struct OnboardingFlow: View {

    @State private var model: OnboardingModel

    init(profileStore: any UserProfileStore,
         tagStore: any WellbeingTagStore,
         onFinished: @escaping () -> Void) {
        _model = State(initialValue: OnboardingModel(profileStore: profileStore,
                                                     tagStore: tagStore,
                                                     onFinished: onFinished))
    }

    var body: some View {
        step
            .id(model.step)
            .transition(.asymmetric(
                insertion: .move(edge: .trailing).combined(with: .opacity),
                removal: .move(edge: .leading).combined(with: .opacity)
            ))
            // The steps carry their own background edge to edge, and the keyboard on the
            // opening step must not push the pinned action off screen.
            .background(model.step == .ready ? Palette.ink : Palette.surface)
            .ignoresSafeArea(.keyboard, edges: .bottom)
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
                   onFinished: {})
}
