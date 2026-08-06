import SwiftUI

/// O5 · Apple Health (Figma `7:543`).
///
/// **This step requests nothing yet.** Both actions record what the user chose and move
/// on — see `OnboardingModel.requestHealthAccess()`. The app reads no HealthKit type and
/// `com.apple.developer.healthkit.access` is empty, so putting a real
/// `requestAuthorization` call here would ask for types nothing consumes, which the
/// consumer-first rule in `.claude/skills/healthkit_permissions/SKILL.md` forbids and
/// App Review asks about.
///
/// Consequence to resolve before submission: the rows below describe reads that do not
/// happen yet. Either the first HealthKit consumer lands and this step starts making the
/// real request, or the step comes out of the flow.
struct HealthStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Connect",
            action: model.requestHealthAccess,
            skipTitle: "Skip",
            skip: model.skipHealthAccess
        ) {
            VStack(spacing: 24) {
                HealthTile()
                    .padding(.top, 10)

                OnboardingHeader(
                    title: "Connect Apple Health",
                    subtitle: "Automatic tracking of sleep, heart rate and activity — no typing",
                    titleFont: Typography.onboardingTitleCompact,
                    alignment: .center
                )

                VStack(spacing: 10) {
                    MarkerRow(text: "Sleep and heart rate", marker: Palette.positive)
                    MarkerRow(text: "Activity and blood oxygen", marker: Palette.positive)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

/// The 88 pt Apple Health mark: a rounded tile with a heart cut from a square whose
/// corners are round except one (Figma `7:564`).
///
/// Rebuilt as a shape rather than shipped as an asset, the same choice `TabBarIcons`
/// makes — it is three primitives in the design, not an exported image.
private struct HealthTile: View {

    private enum Metrics {
        static let tile: CGFloat = 88
        static let tileRadius: CGFloat = 26
        /// The heart before rotation. Its bounding box once turned 45° is `side * √2`.
        static let side: CGFloat = 34
        static let roundCorner: CGFloat = 17
        static let pointCorner: CGFloat = 4
    }

    var body: some View {
        RoundedRectangle(cornerRadius: Metrics.tileRadius, style: .continuous)
            .fill(Palette.health)
            .frame(width: Metrics.tile, height: Metrics.tile)
            .overlay {
                UnevenRoundedRectangle(
                    cornerRadii: RectangleCornerRadii(
                        topLeading: Metrics.roundCorner,
                        bottomLeading: Metrics.pointCorner,
                        bottomTrailing: Metrics.roundCorner,
                        topTrailing: Metrics.roundCorner
                    )
                )
                .fill(Palette.controlFill)
                .frame(width: Metrics.side, height: Metrics.side)
                // The square corner swings to the bottom and becomes the point of the
                // heart; the three round ones become its lobes.
                .rotationEffect(.degrees(45))
            }
            .accessibilityHidden(true)
    }
}

#Preview {
    HealthStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                      tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                      onFinished: {}))
}
