import SwiftUI

/// O3 · How often and how long (Figma `7:448`).
///
/// Two coarse questions on one screen. Both are optional: they give the population prior
/// something to lean on before there is personal history, and someone who does not know
/// the answer must not be stuck here.
struct PatternStep: View {

    @Bindable var model: OnboardingModel

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Next",
            isActionEnabled: model.canLeaveCurrentStep,
            action: model.advance
        ) {
            VStack(alignment: .leading, spacing: 30) {
                VStack(alignment: .leading, spacing: 22) {
                    OnboardingHeader(title: "How often does this happen?")

                    VStack(spacing: 10) {
                        ForEach(EpisodeFrequency.allCases, id: \.self) { option in
                            ChoiceRow(title: option.label,
                                      isSelected: model.episodeFrequency == option) {
                                model.episodeFrequency =
                                    model.episodeFrequency == option ? nil : option
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 22) {
                    OnboardingHeader(title: "How long does it usually last?")

                    FlowLayout {
                        ForEach(EpisodeDuration.allCases, id: \.self) { option in
                            ChoiceChip(title: option.label,
                                       isSelected: model.typicalEpisodeDuration == option) {
                                model.typicalEpisodeDuration =
                                    model.typicalEpisodeDuration == option ? nil : option
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }
}

#Preview {
    PatternStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                       tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                       sensorAccess: NoOpSensorAccess(),
                                       onFinished: {}))
}
