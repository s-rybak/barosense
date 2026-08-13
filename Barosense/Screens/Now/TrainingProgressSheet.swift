import SwiftUI

// The explainer behind the ⓘ on the training-progress card.
//
// It exists because the card cannot be honest in the space it has. "Прогрес навчання моделі —
// 48%" reads as "the model is 48% accurate", and it is not: there is no trained model at all
// (`.claude/context/ml-spec.md`), and the bar counts check-ins. This screen is where that gets
// said, alongside the two things the user can actually do about it.
//
// ## Where the copy departs from the design
//
// The frame lists three sources the model learns from and three ways to speed it up. Three of
// those six name things this app does not have, and shipping them would be a promise the code
// does not keep:
//
// 1. "вологість" — humidity comes from WeatherKit, which is not wired. The row now names the
//    barometer, which is the one signal the device is actually recording.
// 2. "симптомів" — the form captures an intensity, tags and medication entries, and nothing
//    the design's word there names. It is also on the forbidden vocabulary list in
//    `.claude/skills/appstore_compliance/SKILL.md`. // barosense:copy-allow naming the rejected word
// 3. "активності" from Apple Health — the read set is resting heart rate, blood oxygen and
//    sleep, and nothing else (`HealthKitReadSet`). Naming a fourth type on screen is exactly
//    the drift `.claude/skills/healthkit_permissions/SKILL.md` exists to stop.
// 4. "тривалість епізоду" — asked once during onboarding, never per check-in. Advice to record
//    it on a check-in points at a control that is not there.
// 5. "впевненого прогнозу" — a confident forecast is a certainty claim. The footer now says
//    what 40 entries actually buy: the point where the user's own history outweighs the prior.
//
// The verbs are also future tense throughout. The model *will* look for links; today it does
// not exist.

/// What the training-progress bar is counting, and how to move it.
struct TrainingProgressSheet: View {

    let progress: TrainingDataProgress

    @Environment(\.dismiss) private var dismiss

    /// The same pair the check-in sheets use, so the three read as one app.
    private static let sectionSpacing: CGFloat = 24
    private static let horizontalInset: CGFloat = 24

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header

                Text("""
                    The model will look for links between pressure, weather and how you feel. \
                    The more entries you add, the more it leans on your own history instead of \
                    general patterns.
                    """)
                    .font(Typography.onboardingBodySmall)
                    .foregroundStyle(Palette.bodyText)
                    .fixedSize(horizontal: false, vertical: true)

                learnsFrom

                howToHelp

                footer
            }
            .padding(.horizontal, Self.horizontalInset)
            .padding(.top, 26)
            .padding(.bottom, 32)
        }
        .background(Palette.surface)
        // `.large` for the reason the check-in sheets document: the content is long enough that
        // `.medium` would put the footer under the fold on every device.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Model training progress")
                .font(Typography.onboardingTitleCompact)
                .foregroundStyle(Palette.heading)
                .accessibilityAddTraits(.isHeader)

            Spacer(minLength: 12)

            closeButton
        }
    }

    /// The same grey disc the check-in sheets draw, and kept for the same reason: a sheet with
    /// a visible close control is dismissable without knowing that it can be dragged.
    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.placeholder)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.segmentedTrack))
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, -7)
        .padding(.trailing, -7)
        .accessibilityLabel(Text("Close"))
    }

    // MARK: - What it learns from

    /// The three sources, each named as what the device records rather than as what the
    /// pipeline plans to derive. Marker colours carry no meaning here beyond telling three
    /// rows apart, which is why every row also reads as a full sentence.
    private var learnsFrom: some View {
        ExplainerCard(title: "What it learns from", palette: .light) {
            VStack(alignment: .leading, spacing: 14) {
                BulletRow(text: "Atmospheric pressure and how fast it is changing",
                          marker: Palette.markerCool, palette: .light)

                BulletRow(text: "Your check-ins, the tags on them and what you took",
                          marker: Palette.markerCool, palette: .light)

                BulletRow(text: "Sleep, resting heart rate and blood oxygen from Apple Health",
                          marker: Palette.markerCool, palette: .light)
            }
        }
    }

    // MARK: - How to help

    private var howToHelp: some View {
        ExplainerCard(title: "To learn faster", palette: .dark) {
            VStack(alignment: .leading, spacing: 14) {
                // First because it is the one people get wrong. A log of bad days only teaches
                // the model that every day is bad — with no ordinary days in it there is
                // nothing for a positive event to stand out against.
                NumberedRow(number: 1,
                            text: "Log a check-in on ordinary days too, not only on bad ones")

                NumberedRow(number: 2,
                            text: "Add the tags and what you took, not just the intensity")

                NumberedRow(number: 3,
                            text: "Keep Apple Health connected, for sleep and heart rate")
            }
        }
    }

    // MARK: - Footer

    /// Two numbers in one string rather than two `Text`s joined with `+`: the separator is
    /// copy, and `Text` concatenation is deprecated on this deployment target.
    private var footer: some View {
        Text("About \(TrainingDataProgress.targetCheckInCount) entries before your own history leads · \(progress.checkInCount) so far")
            .font(Typography.cardNote)
            .foregroundStyle(Palette.inkSubtle)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }
}

// MARK: - Components

/// A titled block: an all-caps heading over its rows, on light or dark.
///
/// A local type rather than `SettingsSectionHeader`, which is light-only and belongs to the
/// settings screens. Two of these three blocks are dark, and giving the settings component an
/// ink parameter would couple a Now sheet to a Settings component for one colour.
private struct ExplainerCard<Content: View>: View {

    let title: LocalizedStringKey
    let palette: OnboardingPalette

    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(Typography.sectionHeader)
                .tracking(0.48)
                .textCase(.uppercase)
                .foregroundStyle(palette == .light ? Palette.placeholder : Palette.bodyTextOnInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(palette == .light ? Palette.cardSurface : Palette.ink)
                .overlay {
                    if palette == .light {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(Palette.cardBorder, lineWidth: 1)
                    }
                }
        }
    }
}

/// A dot and a sentence.
///
/// Not `MarkerRow`: that one draws each row as its own bordered card, which is right on the
/// onboarding steps and wrong inside a card that already has an outline.
private struct BulletRow: View {

    let text: LocalizedStringKey
    let marker: Color
    let palette: OnboardingPalette

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Circle()
                .fill(marker)
                .frame(width: 7, height: 7)
                // Nudged down onto the first line's optical centre; a dot aligned to the top of
                // a text box sits above the line it belongs to.
                .padding(.top, 6)

            Text(text)
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(palette == .light ? Palette.heading : Palette.onInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

/// A numeral and a sentence, for the block where the order is the advice.
private struct NumberedRow: View {

    let number: Int
    let text: LocalizedStringKey

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(verbatim: "\(number)")
                .font(Typography.captionEmphasis)
                .foregroundStyle(Palette.bodyTextOnInk)
                .monospacedDigit()
                // A fixed column so three numerals line their sentences up, and so the second
                // line of a wrapped row hangs under the text rather than under the number.
                .frame(width: 14, alignment: .leading)
                .padding(.top, 2)

            Text(text)
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(Palette.onInk)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
        // Combined so VoiceOver reads "1, log a check-in…" as one item rather than stopping on
        // a bare numeral.
        .accessibilityElement(children: .combine)
    }
}

#Preview("Partway") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            TrainingProgressSheet(progress: TrainingDataProgress(checkInCount: 19))
        }
}

#Preview("Target reached") {
    Color.clear
        .sheet(isPresented: .constant(true)) {
            TrainingProgressSheet(progress: TrainingDataProgress(checkInCount: 52))
        }
}
