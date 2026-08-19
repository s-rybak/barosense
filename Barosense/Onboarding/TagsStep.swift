import SwiftUI

/// O2 · What the user wants to track (Figma `7:399`).
///
/// The chips are the tag vocabulary from `WellbeingTagStore`, not a list private to this
/// screen. Whatever the user leaves unselected is archived when the flow commits, so this
/// step decides what a check-in will offer from then on — which is why it is the one
/// answer the flow insists on.
struct TagsStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Next",
            isActionEnabled: model.canLeaveCurrentStep,
            action: model.advance
        ) {
            VStack(alignment: .leading, spacing: 24) {
                OnboardingHeader(
                    title: "What best describes how you feel?",
                    subtitle: "Choose everything that applies"
                )

                FlowLayout {
                    ForEach(model.offeredTags) { tag in
                        ChoiceChip(text: tag.label,
                                   isSelected: model.selectedTagIDs.contains(tag.id)) {
                            model.toggleTag(tag.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if model.selectedTagIDs.isEmpty {
                    Text("Choose at least one — you can add and rename these later.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.placeholder)
                }
            }
        }
        .task { await model.load() }
    }
}

#Preview {
    @Previewable @State var model = OnboardingModel(
        profileStore: InMemoryUserProfileStore(),
        tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
        sensorAccess: NoOpSensorAccess(),
        onFinished: {}
    )

    TagsStep(model: model)
}
