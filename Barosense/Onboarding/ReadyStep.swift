import SwiftUI

/// O6 · The arrival step (Figma `7:589`).
///
/// No progress bar — it is the arrival, not another thing to get through — but on the same
/// light surface as every step before it. The design had it inverted, back when it was the
/// last screen and the inversion marked the end of the flow. `PremiumStep` is the end now and
/// carries that inversion, so a second dark screen in front of it read as the finish arriving
/// twice.
///
/// It used to be the last step, and its action used to be the commit: "Start" wrote the
/// profile, pruned the tag vocabulary and dropped the user into the app. `PremiumStep` now
/// sits behind it and carries all three, so this reads "Next" and does nothing but move on.
/// The retry-on-failure copy moved with the commit rather than being left here over a write
/// that no longer happens on this screen.
struct ReadyStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Next",
            action: model.advance
        ) {
            VStack(spacing: 24) {
                ConfirmationRing()
                    .padding(.top, 20)

                OnboardingHeader(
                    title: "Your plan is ready",
                    subtitle: "Your personal model has started learning from your data",
                    alignment: .center
                )

                VStack(spacing: 12) {
                    MarkerRow(text: "Pressure forecast with push notifications",
                              marker: Palette.markerWarm,
                              markerSize: 10)

                    MarkerRow(text: """
                        The model learns from your data alone. For a sharper forecast it \
                        needs 90 days of tracking at 3 check-ins a day.
                        """,
                              marker: Palette.markerCool,
                              markerSize: 10)
                }
                .padding(.top, 8)
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
                                     sensorAccess: NoOpSensorAccess(),
                                     onFinished: {}))
}
