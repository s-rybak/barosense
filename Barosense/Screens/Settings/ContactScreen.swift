import SwiftUI

/// M6c · Contact us.
///
/// **Placeholder, on purpose.** There is no support address, no site and no company entry
/// yet, so every value here reads `XXXX` and nothing is tappable — a `mailto:` to a
/// made-up address would look like it worked and quietly lose the message.
///
/// Filling these in is a release blocker: App Review expects working support contact
/// details, and this screen is what the store listing points at. The build number below is
/// real, so a support reply can at least be matched to a build once the rest lands.
struct ContactScreen: View {

    let back: () -> Void

    /// Rows whose value is still to be decided. One list so filling them in is one edit.
    private static let placeholder = "XXXX"

    var body: some View {
        VStack(spacing: 0) {
            SettingsNavigationBar(title: "Contact us", back: back)

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    Text("""
                        Questions, a problem, or something that looks wrong — we read \
                        everything that comes in.
                        """)
                        .font(Typography.settingsRowLabel)
                        .foregroundStyle(Palette.bodyText)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 4)
                        .padding(.bottom, 8)

                    SettingsCard {
                        detailRow(title: "Email", value: Self.placeholder)
                        SettingsRowDivider()
                        detailRow(title: "Website", value: Self.placeholder)
                        SettingsRowDivider()
                        detailRow(title: "Response time", value: Self.placeholder)
                    }

                    SettingsCard {
                        detailRow(title: "App version", value: Self.appVersion)
                    }

                    Text("Contact details are not final yet.")
                        .font(Typography.settingsCaption)
                        .foregroundStyle(Palette.placeholder)
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

    /// A label and a value, with nothing to tap. Same metrics as `SettingsNavigationRow`
    /// so the two kinds of row line up inside one card.
    private func detailRow(title: LocalizedStringKey, value: String) -> some View {
        HStack(spacing: 12) {
            Text(title)
                .font(Typography.settingsRowLabel)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(verbatim: value)
                .font(Typography.settingsRowValue)
                .foregroundStyle(Palette.placeholder)
                .textSelection(.enabled)
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.rowVerticalInset)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
        .accessibilityElement(children: .combine)
    }

    /// `MARKETING_VERSION (CURRENT_PROJECT_VERSION)`, both set in `project.yml`.
    private static var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String ?? "—"
        return "\(short) (\(build))"
    }
}

#Preview {
    ContactScreen(back: {})
}
