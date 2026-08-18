import SwiftUI

/// O5 · Apple Health and the barometer (Figma `7:543`).
///
/// The step where the app asks for what it reads, and the only screen in the flow that
/// raises a system prompt. "Connect" runs both requests in order — the Health sheet for
/// `HealthKitReadSet`, then the Motion & Fitness alert `CMAltimeter` raises when the
/// barometer is first started — and "Skip" runs neither. See
/// `OnboardingModel.requestHealthAccess()`.
///
/// The rows name exactly what the Health sheet will list, and nothing beyond it. They used
/// to promise activity, which is not in the read set and so never appears on the sheet:
/// a step describing reads the app does not make is the consumer-first rule of
/// `.claude/skills/healthkit_permissions/SKILL.md` read backwards, and the kind of
/// mismatch App Review asks about.
struct HealthStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Connect",
            // Dimmed while the two sheets are up. They are modal, so this is not what stops
            // a second tap — `requestHealthAccess` guards that itself — it is what says the
            // step is mid-request when the first sheet is dismissed and the second has not
            // yet drawn.
            isActionEnabled: !model.isRequestingAccess,
            action: { Task { await model.requestHealthAccess() } },
            skipTitle: "Skip",
            skip: model.skipHealthAccess
        ) {
            VStack(spacing: 24) {
                HealthTile()
                    .padding(.top, 10)

                OnboardingHeader(
                    title: "Connect your data",
                    subtitle: "Sleep, heart rate and pressure are read for you — no typing",
                    titleFont: Typography.onboardingTitleCompact,
                    alignment: .center
                )

                VStack(spacing: 10) {
                    MarkerRow(text: "Sleep and heart rate", marker: Palette.positive)
                    MarkerRow(text: "Blood oxygen", marker: Palette.positive)
                    MarkerRow(text: "Pressure from this device's barometer",
                              marker: Palette.positive)
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
                                      sensorAccess: NoOpSensorAccess(),
                                      onFinished: {}))
}
