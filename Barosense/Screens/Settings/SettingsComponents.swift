import SwiftUI

/// Fixed metrics shared by the settings screens (Figma `7:1246`, `7:1308`).
///
/// A file-level type rather than one nested per view: the card radius and the screen
/// inset are the two numbers every one of these views has to agree on, and three private
/// copies of `18` is how they stop agreeing.
enum SettingsMetrics {
    /// Horizontal inset of the whole screen.
    static let screenInset: CGFloat = 22
    /// Vertical gap between two cards.
    static let blockSpacing: CGFloat = 18
    static let cardRadius: CGFloat = 18
    static let rowHorizontalInset: CGFloat = 16
    /// 14 pt above and 15 pt below in the design; averaged so a row is symmetric and the
    /// divider between two of them sits centred.
    static let rowVerticalInset: CGFloat = 14
    /// Below the 44 pt minimum a row would be hard to hit, and the design's own rows are
    /// 47–48 pt tall anyway.
    static let rowMinHeight: CGFloat = 48
}

// MARK: - Card

/// The white, hairline-outlined container a group of settings rows sits in.
///
/// Clips its content so the first and last row's own backgrounds follow the corner radius
/// — without that a highlighted row paints square corners over the card's rounded ones.
struct SettingsCard<Content: View>: View {

    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            content()
        }
        .background(Palette.cardSurface)
        .clipShape(RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: SettingsMetrics.cardRadius, style: .continuous)
                .strokeBorder(Palette.cardBorder, lineWidth: 1)
        }
    }
}

/// The hairline between two rows of one card.
///
/// Inset to the row's text rather than run edge to edge: that is what the design draws,
/// and it is what keeps the divider from touching the card's rounded outline.
struct SettingsRowDivider: View {
    var body: some View {
        Rectangle()
            .fill(Palette.rowSeparator)
            .frame(height: 1)
            .padding(.leading, SettingsMetrics.rowHorizontalInset)
    }
}

// MARK: - Rows

/// The disclosure marker at the trailing edge of a row that leads somewhere.
///
/// An SF Symbol rather than the design's literal "›" character: the glyph is the same
/// shape, it scales with Dynamic Type on its own, and it stays optically centred at every
/// size, which a text chevron in a `Text` view does not.
struct SettingsChevron: View {

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Palette.placeholder)
            .accessibilityHidden(true)
    }
}

/// A row that leads somewhere: a label, an optional current value, and a chevron.
struct SettingsNavigationRow: View {

    let title: LocalizedStringKey
    /// What the setting currently reads, printed before the chevron. Already-resolved
    /// `Text` because a language name comes from a table and a profile name is the user's
    /// own words — only the caller knows which.
    var value: Text?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Text(title)
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let value {
                    value
                        .font(Typography.settingsRowValue)
                        .foregroundStyle(Palette.placeholder)
                }

                SettingsChevron()
            }
            .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
            .padding(.vertical, SettingsMetrics.rowVerticalInset)
            .frame(minHeight: SettingsMetrics.rowMinHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// A row carrying a switch, with an optional caption underneath.
///
/// The caption is not in the design. It is there because the switch reports an
/// authorisation state that has more than two meanings — see `SettingsModel` — and a
/// switch alone cannot say "you were asked, but nothing has arrived".
struct SettingsToggleRow: View {

    let title: LocalizedStringKey
    var caption: LocalizedStringKey?
    @Binding var isOn: Bool
    var isEnabled: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: $isOn) {
                Text(title)
                    .font(Typography.settingsRowLabel)
                    .foregroundStyle(Palette.heading)
            }
            .toggleStyle(BarosenseToggleStyle())
            .disabled(!isEnabled)
            .opacity(isEnabled ? 1 : 0.5)

            if let caption {
                Text(caption)
                    .font(Typography.settingsCaption)
                    .foregroundStyle(Palette.placeholder)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, SettingsMetrics.rowHorizontalInset)
        .padding(.vertical, SettingsMetrics.rowVerticalInset)
        .frame(minHeight: SettingsMetrics.rowMinHeight)
    }
}

/// The 38 × 22 switch the design draws (Figma `7:1274`), which is smaller than the system
/// one and green rather than the system tint.
///
/// A `ToggleStyle` rather than a hand-rolled button, so VoiceOver still announces a switch
/// with an on/off value and the rest of the app can keep using `Toggle`.
struct BarosenseToggleStyle: ToggleStyle {

    private enum Metrics {
        static let width: CGFloat = 38
        static let height: CGFloat = 22
        static let knob: CGFloat = 18
        static let inset: CGFloat = 2
    }

    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)

            Capsule()
                .fill(configuration.isOn ? Palette.positive : Palette.controlBorder)
                .frame(width: Metrics.width, height: Metrics.height)
                .overlay(alignment: configuration.isOn ? .trailing : .leading) {
                    Circle()
                        .fill(Palette.cardSurface)
                        .frame(width: Metrics.knob, height: Metrics.knob)
                        .padding(.horizontal, Metrics.inset)
                }
                .animation(.easeInOut(duration: 0.18), value: configuration.isOn)
                // The switch itself is 22 pt tall; the row around it supplies the rest of
                // the 44 pt target, and this makes the whole trailing area hit it.
                .contentShape(.rect)
                .onTapGesture { configuration.isOn.toggle() }
        }
    }
}

/// A row of bare destructive text, outside any card (Figma `7:1305`).
struct DestructiveActionRow: View {

    let title: LocalizedStringKey
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(Typography.destructiveAction)
                .foregroundStyle(Palette.destructive)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Headings

/// An all-caps heading above a block of fields (Figma `7:1340`).
struct SettingsSectionHeader: View {

    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.sectionHeader)
            .tracking(0.48)
            .textCase(.uppercase)
            .foregroundStyle(Palette.placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The bar at the top of a pushed settings screen: back, title, and one optional
/// confirming action (Figma `7:1324`).
///
/// Hand-drawn rather than `NavigationStack`'s own bar. The system bar brings a translucent
/// material, its own type ramp and its own insets, none of which are in this design, and
/// overriding all three costs more than laying out three items.
struct SettingsNavigationBar: View {

    let title: LocalizedStringKey
    let back: () -> Void
    var actionTitle: LocalizedStringKey?
    var isActionEnabled: Bool = true
    var action: (() -> Void)?

    var body: some View {
        ZStack {
            Text(title)
                .font(Typography.navigationTitle)
                .foregroundStyle(Palette.heading)

            HStack(spacing: 0) {
                Button(action: back) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Palette.placeholder)
                        .frame(width: 44, height: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Back"))

                Spacer(minLength: 0)

                if let actionTitle, let action {
                    Button(action: action) {
                        Text(actionTitle)
                            .font(Typography.navigationAction)
                            .foregroundStyle(Palette.link)
                            .frame(height: 44)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isActionEnabled)
                    .opacity(isActionEnabled ? 1 : 0.4)
                }
            }
        }
        .padding(.horizontal, SettingsMetrics.screenInset - 8)
        .padding(.top, 8)
    }
}

// MARK: - Avatar

/// The circular avatar: the chosen photo, or the first letter of the name on a dark disc
/// (Figma `7:1262`, `7:1333`).
struct ProfileAvatar: View {

    /// JPEG bytes from `ProfileAvatarEncoder`, or `nil` to fall back to the initial.
    let imageData: Data?
    /// One character, already extracted by the caller. Empty renders an unadorned disc,
    /// which is what someone who skipped the name field should see.
    let initial: String
    let diameter: CGFloat
    var font: Font = Typography.avatarInitial

    var body: some View {
        Circle()
            .fill(Palette.ink)
            .frame(width: diameter, height: diameter)
            .overlay {
                if let imageData, let image = UIImage(data: imageData) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: diameter, height: diameter)
                        .clipShape(.circle)
                } else if !initial.isEmpty {
                    Text(verbatim: initial)
                        .font(font)
                        .foregroundStyle(Palette.onInk)
                }
            }
            .accessibilityHidden(true)
    }
}

#Preview("Settings controls") {
    @Previewable @State var isOn = true

    ScrollView {
        VStack(spacing: SettingsMetrics.blockSpacing) {
            SettingsCard {
                SettingsToggleRow(title: "Apple Health", isOn: $isOn)
                SettingsRowDivider()
                SettingsNavigationRow(title: "Language", value: Text(verbatim: "Українська")) {}
            }

            SettingsCard {
                SettingsNavigationRow(title: "Contact us") {}
            }

            VStack(alignment: .leading, spacing: 8) {
                DestructiveActionRow(title: "Reset what Barosense has learned") {}
                DestructiveActionRow(title: "Delete my data") {}
            }
            .padding(.horizontal, 4)

            HStack(spacing: 14) {
                ProfileAvatar(imageData: nil, initial: "O", diameter: 48,
                              font: Typography.avatarInitialCompact)
                ProfileAvatar(imageData: nil, initial: "O", diameter: 76)
            }
        }
        .padding(SettingsMetrics.screenInset)
    }
    .background(Palette.surface)
}
