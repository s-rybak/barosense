import SwiftUI

/// M6b · Language.
///
/// Not in the Figma file — the design draws the row that leads here, not the destination —
/// so it is built from the same parts as the rest of the flow: the settings navigation
/// bar, one card, and the check mark the platform uses for a single choice.
///
/// Three options rather than two. "System" has to be a distinct entry, otherwise there is
/// no way back to following the device once the user has pinned a language, and someone
/// who travels or switches their phone's language would be stuck with whatever they picked
/// once.
struct LanguageScreen: View {

    let languages: LanguageController
    let back: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: "Language", back: back)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    SettingsCard {
                        row(for: .system, title: Text("System"))

                        ForEach(AppLanguage.allCases, id: \.self) { language in
                            SettingsRowDivider()
                            row(for: .fixed(language), title: Text(verbatim: language.endonym))
                        }
                    }

                    Text("""
                        System follows your device's language. Barosense uses English for \
                        anything it hasn't been translated into.
                        """)
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.placeholder)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                }
                .padding(.horizontal, SettingsMetrics.screenInset)
                .padding(.top, 18)
                .padding(.bottom, 24)
            }
            .scrollBounceBehavior(.basedOnSize)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.surface.ignoresSafeArea())
    }

    /// One choice. The trailing check mark rather than a chevron: this row *is* the
    /// setting, it does not lead anywhere.
    private func row(for selection: LanguageSelection, title: Text) -> some View {
        let isSelected = languages.selection == selection

        return Button {
            languages.select(selection)
        } label: {
            HStack(spacing: 12) {
                title
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Palette.link)
                }
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, SettingsMetrics.rowVerticalInset)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

#Preview {
    LanguageScreen(languages: LanguageController(), back: {})
}
