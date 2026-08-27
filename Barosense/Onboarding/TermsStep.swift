import SwiftUI

/// O4 · Terms and what the app is (Figma `7:503`).
///
/// The paragraph here is the plain-language "this is not medical advice" statement the
/// pre-submission checklist requires. It is deliberately the first thing the user reads
/// on this step, above the control that gates the flow — not a line buried in settings.
///
/// This is the only step whose answer is mandatory: the flow cannot continue until the
/// checkbox is on.
struct TermsStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Agree and continue",
            isActionEnabled: model.canLeaveCurrentStep,
            action: model.advance
        ) {
            VStack(alignment: .leading, spacing: 24) {
                logoTile

                OnboardingHeader(
                    title: "Before you start",
                    subtitle: """
                        Barosense looks at how barometric pressure lines up with how you \
                        feel, using your own data. It is not medical advice and does not \
                        replace talking to a doctor — these are personal observations only.
                        """
                )

                consentCard
            }
        }
    }

    /// The 56 pt mark that opens the step: the app's own logo, at the size and corner radius
    /// the design gives this tile.
    ///
    /// The one place in the flow that draws a bitmap. It replaced a ring built from two
    /// primitives — the ring said nothing, and this is the step where the user is told what
    /// Barosense is, so the mark above that sentence may as well be the app's. The artwork is
    /// the same file as the icon (`Logo` in `Assets.xcassets`, cut down from the 1024 pt
    /// original to the three scales this 56 pt tile actually renders at).
    ///
    /// Carries no meaning the text below does not, so it stays hidden from VoiceOver.
    private var logoTile: some View {
        Image(.logo)
            .resizable()
            .scaledToFit()
            .frame(width: 56, height: 56)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .accessibilityHidden(true)
    }

    private var consentCard: some View {
        Button {
            model.hasAcceptedTerms.toggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(model.hasAcceptedTerms ? Palette.ink : Palette.controlFill)
                    .overlay {
                        if !model.hasAcceptedTerms {
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .strokeBorder(Palette.controlBorder, lineWidth: 1)
                        }
                    }
                    .frame(width: 20, height: 20)
                    // Nudged onto the first line's optical centre; the row is top-aligned
                    // so the box stays put as the sentence wraps.
                    .padding(.top, 1)

                Text("I understand and accept the Terms of Use and Privacy Policy")
                    .font(Typography.consentText)
                    .foregroundStyle(Palette.heading)
                    .lineSpacing(5)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(17)
            .background {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Palette.controlFill)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(Palette.controlBorder, lineWidth: 1)
                    }
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(model.hasAcceptedTerms ? Text("On") : Text("Off"))
    }
}

#Preview {
    TermsStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                     tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                     sensorAccess: NoOpSensorAccess(),
                                     onFinished: {}))
}
