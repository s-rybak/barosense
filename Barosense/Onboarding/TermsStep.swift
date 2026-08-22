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

    /// The chosen app language, read back out of the locale the composition root put in the
    /// environment. Onboarding is not handed the `LanguageController`, and threading it
    /// through four initialisers to reach one sheet is a worse trade than this.
    @Environment(\.locale) private var locale

    /// Which document the sheet is showing, or `nil` for none. One piece of state rather than
    /// two Booleans: two could both be true, and there is only one sheet.
    @State private var reading: ShippedDocument?

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

                documentLinks
            }
        }
        .sheet(item: $reading) { document in
            LegalDocumentScreen(document: document,
                                language: AppLanguage(locale),
                                back: { reading = nil },
                                title: document.screenTitle)
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

    /// The way to actually read what the checkbox above accepts.
    ///
    /// **Not optional polish.** The consent sentence names two documents; without a way to
    /// open them, the step asks the user to accept text they cannot see — which is both a bad
    /// deal and the kind of thing App Review looks for on a screen that gates the app.
    ///
    /// Below the card rather than as links inside its sentence: the card is one large toggle,
    /// and a tappable link inside a tappable row means every attempt to read the terms is a
    /// coin flip that may instead tick the box.
    private var documentLinks: some View {
        HStack(spacing: 18) {
            documentLink(.termsOfUse)
            documentLink(.privacyPolicy)
            Spacer(minLength: 0)
        }
    }

    private func documentLink(_ document: ShippedDocument) -> some View {
        Button {
            reading = document
        } label: {
            Text(document.screenTitle)
                .font(Typography.linkAction)
                .foregroundStyle(Palette.link)
                .underline()
                .frame(minHeight: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
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
