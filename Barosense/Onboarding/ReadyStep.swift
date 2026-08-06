import SwiftUI

/// O6 · The closing step (Figma `7:589`).
///
/// The only step on the dark side of the palette, and the only one with no progress bar —
/// it is the arrival, not another thing to get through. Its action is what actually
/// commits the profile and prunes the tag vocabulary, so a failure has to be visible here
/// rather than dropping the user into an app with none of their answers.
struct ReadyStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            palette: .dark,
            actionTitle: model.failure == nil ? "Start" : "Try again",
            isActionEnabled: !model.isSaving,
            action: model.advance
        ) {
            VStack(spacing: 24) {
                ConfirmationRing()
                    .padding(.top, 20)

                OnboardingHeader(
                    title: "Your plan is ready",
                    subtitle: "Your personal model has started learning from your data",
                    palette: .dark,
                    alignment: .center
                )

                VStack(spacing: 12) {
                    MarkerRow(text: "Pressure forecast with push notifications",
                              marker: Palette.markerWarm,
                              markerSize: 10,
                              palette: .dark)

                    MarkerRow(text: """
                        The model learns from your data alone. For a sharper forecast it \
                        needs 90 days of tracking at 3 check-ins a day.
                        """,
                              marker: Palette.markerCool,
                              markerSize: 10,
                              palette: .dark)
                }
                .padding(.top, 8)

                if model.failure != nil {
                    Text("Your answers could not be saved. Check that the device has free space and try again.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.markerWarm)
                        .multilineTextAlignment(.center)
                }
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The 86 pt confirmation mark: a ring with a check drawn inside it (Figma `7:603`).
///
/// Two primitives in the design, so it is rebuilt here rather than exported — the same
/// call `TabBarIcons` makes.
private struct ConfirmationRing: View {

    private enum Metrics {
        static let diameter: CGFloat = 86
        static let ringWidth: CGFloat = 3
        static let strokeWidth: CGFloat = 4
        /// The check before rotation: an L, drawn as its short arm then its long one.
        static let armShort: CGFloat = 18
        static let armLong: CGFloat = 30
    }

    var body: some View {
        Circle()
            .strokeBorder(Palette.positive, lineWidth: Metrics.ringWidth)
            .frame(width: Metrics.diameter, height: Metrics.diameter)
            .overlay {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0))
                    path.addLine(to: CGPoint(x: 0, y: Metrics.armShort))
                    path.addLine(to: CGPoint(x: Metrics.armLong, y: Metrics.armShort))
                }
                .stroke(Palette.positive,
                        style: StrokeStyle(lineWidth: Metrics.strokeWidth,
                                           lineCap: .square,
                                           lineJoin: .miter))
                .frame(width: Metrics.armLong, height: Metrics.armShort)
                // Turning the corner of the L up to the left is what makes it a check.
                .rotationEffect(.degrees(-45))
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    ReadyStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                     tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                     onFinished: {}))
}
