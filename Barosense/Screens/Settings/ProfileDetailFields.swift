import SwiftUI

/// The "Personal details" block of the profile editor: name, age and gender
/// (Figma `7:1338`).
///
/// Its own view rather than three computed properties on `EditProfileScreen`, because it is
/// the only part of that screen that owns keyboard focus — keeping the `@FocusState` and the
/// keyboard toolbar that clears it in one type means neither can be moved without the other.
struct ProfileDetailFields: View {

    @Bindable var model: EditProfileModel

    @FocusState private var focusedField: Field?

    /// Sized for three digits at the default content size, scaled with the type ramp so the
    /// unit beside it never lands on top of the number.
    @ScaledMetric(relativeTo: .subheadline) private var ageFieldWidth: CGFloat = 44

    private enum Field {
        case name
        case age
    }

    /// Pulled out of the interpolation below so the validation line stays inside the
    /// line-length limit without splitting the literal — a concatenated literal stops being
    /// a `LocalizedStringKey` and drops out of the string catalogue.
    private var minimumAge: Int { UserProfile.supportedAgeYears.lowerBound }
    private var maximumAge: Int { UserProfile.supportedAgeYears.upperBound }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionHeader(title: "Personal details")
            nameField
            ageField
            genderChoices
        }
        .toolbar {
            // The number pad has no return key, so without this the age field can only be
            // dismissed by scrolling.
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
    }

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
                // The entry itself is only as wide as three digits, so most of this 56 pt
                // row is the spacer beside it. Without this the control looks full-width and
                // only a sliver of it takes focus.
                .contentShape(.rect)
                .onTapGesture { focusedField = .age }
            }

            // Not in the design, which draws only a filled, valid field. Without it Save
            // goes dim with nothing on screen explaining why.
            if !model.isAgeValid {
                Text("Enter an age between \(minimumAge) and \(maximumAge)")
                    .font(Typography.fieldUnit)
                    .foregroundStyle(Palette.destructive)
                    .padding(.horizontal, 4)
            }
        }
    }

    /// Three across, equal width (Figma `7:1349`) rather than the wrapping row onboarding
    /// draws — the design lays this block out as a fixed set of three.
    private var genderChoices: some View {
        HStack(spacing: 10) {
            ForEach(Gender.allCases, id: \.self) { option in
                ChoiceChip(title: option.label,
                           isSelected: model.gender == option,
                           font: Typography.choiceLabelCompact,
                           cornerRadius: 14,
                           expands: true) {
                    // Tapping the chosen one again clears it: the question is optional and
                    // there would otherwise be no way back to "not answered".
                    model.gender = model.gender == option ? nil : option
                }
            }
        }
    }
}
