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
                ringTile

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

    /// The 56 pt mark that opens the step. A ring rather than a glyph — it carries no
    /// meaning the text below does not, so it is hidden from VoiceOver.
    private var ringTile: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(Palette.ink)
            .frame(width: 56, height: 56)
            .overlay {
                Circle()
                    .strokeBorder(Palette.onInk, lineWidth: 3)
                    .frame(width: 28, height: 28)
            }
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
