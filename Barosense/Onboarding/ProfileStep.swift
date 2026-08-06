import SwiftUI

/// O1 · Profile — name, age and gender (Figma `7:346`).
///
/// Every field is optional. They personalise the population prior the forecast leans on
/// before there is personal history; none of them gates anything, so none of them is
/// required.
struct ProfileStep: View {

    @Bindable var model: OnboardingModel

    /// Width of the age entry, sized for three digits at the default content size and
    /// scaled with the type ramp so the unit beside it never lands on top of the number.
    @ScaledMetric(relativeTo: .subheadline) private var ageFieldWidth: CGFloat = 44

    @FocusState private var focusedField: Field?

    private enum Field {
        case name
        case age
    }

    /// Pulled out of the string interpolation below so the validation line stays inside
    /// the line-length limit without breaking the literal — a concatenated literal would
    /// stop being a `LocalizedStringKey` and silently drop out of the string catalogue.
    private var minimumAge: Int { UserProfile.supportedAgeYears.lowerBound }
    private var maximumAge: Int { UserProfile.supportedAgeYears.upperBound }

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: model.step.completedSteps,
            actionTitle: "Continue",
            isActionEnabled: model.canLeaveCurrentStep,
            action: model.advance
        ) {
            VStack(alignment: .leading, spacing: 28) {
                OnboardingHeader(
                    title: "Let's get to know each other",
                    subtitle: "This helps personalise your pressure and wellbeing forecasts",
                    titleFont: Typography.onboardingTitleLarge,
                    subtitleFont: Typography.onboardingBody
                )

                VStack(alignment: .leading, spacing: 14) {
                    nameField
                    ageField
                    genderChoices
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            // The number pad has no return key, so without this the age field can only
            // be dismissed by scrolling.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

    // MARK: - Fields

    private var nameField: some View {
        FieldSurface {
            ZStack(alignment: .leading) {
                if model.displayName.isEmpty {
                    Text("Name")
                        .font(Typography.fieldText)
                        .foregroundStyle(Palette.placeholder)
                }

                TextField("", text: $model.displayName)
                    .font(Typography.fieldText)
                    .foregroundStyle(Palette.heading)
                    .textContentType(.givenName)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .name)
                    .onSubmit { focusedField = .age }
                    .accessibilityLabel(Text("Name"))
            }
        }
    }

    private var ageField: some View {
        VStack(alignment: .leading, spacing: 6) {
            FieldSurface {
                HStack(spacing: 8) {
                    ZStack(alignment: .leading) {
                        if model.ageText.isEmpty {
                            Text("Age")
                                .font(Typography.fieldText)
                                .foregroundStyle(Palette.placeholder)
                        }

                        TextField("", text: $model.ageText)
                            .font(Typography.fieldText)
                            .foregroundStyle(Palette.heading)
                            .keyboardType(.numberPad)
                            .focused($focusedField, equals: .age)
                            .accessibilityLabel(Text("Age"))
                    }
                    .frame(width: ageFieldWidth, alignment: .leading)

                    if !model.ageText.isEmpty {
                        Text("years")
                            .font(Typography.fieldUnit)
                            .foregroundStyle(Palette.placeholder)
                    }

                    Spacer(minLength: 0)
                }
                // The entry itself is only as wide as three digits, so most of this
                // 56 pt row is the spacer beside it. Without this the control looks
                // full-width and only a sliver of it takes focus.
                .contentShape(.rect)
                .onTapGesture { focusedField = .age }
            }

            // Not in the design, which draws only a filled, valid field. Without it the
            // primary action goes dim with nothing on screen explaining why.
            if !model.isAgeValid {
                Text("Enter an age between \(minimumAge) and \(maximumAge)")
                    .font(Typography.fieldUnit)
                    .foregroundStyle(Palette.health)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var genderChoices: some View {
        FlowLayout(alignment: .center) {
            ForEach(Gender.allCases, id: \.self) { option in
                ChoiceChip(title: option.label,
                           isSelected: model.gender == option,
                           font: Typography.choiceLabelCompact) {
                    // Tapping the chosen one again clears it: the question is optional,
                    // and without this there is no way back to "not answered".
                    model.gender = model.gender == option ? nil : option
                }
            }
        }
        .frame(maxWidth: .infinity)
    }
}

#Preview {
    ProfileStep(model: OnboardingModel(profileStore: InMemoryUserProfileStore(),
                                       tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                                       onFinished: {}))
}
