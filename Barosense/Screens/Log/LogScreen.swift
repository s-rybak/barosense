import SwiftUI

// The Log destination (Figma `7:330`) — one check-in: a point on the 1–5 scale, whatever
// tags apply, and an optional note.
//
// ## The Figma frame could not be read
//
// The design at `node-id=7-330` sits behind a Figma login this session has no way to pass,
// so the layout below is built from the design system already extracted into
// `DesignSystem/` and `Onboarding/OnboardingComponents.swift` rather than measured off the
// frame. Every control here is an existing component at existing metrics; nothing new was
// invented visually except the scale row and two colours (`Palette.wellbeingFair`,
// `Palette.wellbeingGood`), which are marked at their declarations.
//
// Concretely, what is *not* verified against the design: the order of the three sections,
// the scale's presentation (a row of five dots was chosen; the frame may draw faces, a
// slider or numbered cards), and the exact copy. Export the frame as PNG or paste its
// spec and this file can be reconciled — the domain, storage and chart work below it do
// not change either way.

// MARK: - Copy

extension WellbeingScore {

    /// What the user reads for one point of the scale.
    ///
    /// App copy, and bound by `.claude/skills/appstore_compliance/SKILL.md`: these name how
    /// the *user says they feel*, never a condition. "Very poor" is a self-report; anything
    /// naming a symptom or a severity would be a claim the app is not allowed to make.
    var label: LocalizedStringKey {
        switch self {
        case .veryPoor: "Very poor"
        case .poor: "Poor"
        case .fair: "Okay"
        case .good: "Good"
        case .veryGood: "Very good"
        }
    }
}

// MARK: - Screen

/// The check-in form.
///
/// Reuses `OnboardingStepScaffold` for its chrome — scrolling content plus a primary action
/// pinned to the bottom, with the progress bar suppressed. Not because a check-in is
/// onboarding, but because that scaffold *is* the app's "content plus one committing action"
/// layout, and a second copy of the 56 pt / 18 pt action button is the exact drift the
/// scaffold's own comment exists to prevent. The type's name is now too narrow; renaming it
/// is a follow-up rather than part of this change.
struct LogScreen: View {

    @State private var model: LogModel

    /// Gap between the three blocks of the form.
    private static let sectionSpacing: CGFloat = 26

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         onSaved: @escaping () -> Void) {
        _model = State(initialValue: LogModel(checkInStore: checkInStore,
                                              tagStore: tagStore,
                                              onSaved: onSaved))
    }

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: nil,
            actionTitle: "Save check-in",
            isActionEnabled: model.canSave,
            action: model.save
        ) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                OnboardingHeader(
                    title: "How do you feel right now?",
                    subtitle: "Your check-ins are what your personal patterns are built from. They stay on this device."
                )

                WellbeingScaleField(selection: $model.score)

                tagsSection

                noteSection

                // Same treatment as the onboarding commit failure, deliberately: it is the
                // same kind of event — the one write the screen exists for did not happen.
                if model.failure != nil {
                    Text("Your check-in could not be saved. Check that the device has free space and try again.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.markerWarm)
                }
            }
        }
        .task { await model.load() }
    }

    // MARK: - Tags

    /// Only rendered once the vocabulary is in. An empty `FlowLayout` under a heading reads
    /// as "you have no tags", which is never true — onboarding insists on at least one.
    @ViewBuilder
    private var tagsSection: some View {
        if !model.offeredTags.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                Text("What stands out?")
                    .font(Typography.cardTitle)
                    .foregroundStyle(Palette.heading)

                FlowLayout {
                    ForEach(model.offeredTags) { tag in
                        ChoiceChip(text: tag.label,
                                   isSelected: model.selectedTagIDs.contains(tag.id)) {
                            model.toggleTag(tag.id)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    // MARK: - Note

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Note")
                .font(Typography.cardTitle)
                .foregroundStyle(Palette.heading)

            FieldSurface {
                // Grows with what is typed instead of scrolling inside one line. Capped at
                // four lines so a long note cannot push the primary action off the screen —
                // the field scrolls past that, the layout does not.
                TextField("Anything worth remembering (optional)",
                          text: $model.note,
                          axis: .vertical)
                    .lineLimit(1...4)
                    .font(Typography.fieldText)
                    .foregroundStyle(Palette.heading)
                    .textInputAutocapitalization(.sentences)
                    // Padding, not a frame: `FieldSurface` sets the 56 pt minimum and the
                    // field has to be free to grow past it.
                    .padding(.vertical, 14)
            }
        }
    }
}

// MARK: - Scale

/// The 1–5 scale as a row of coloured points, worst on the left.
///
/// The colour is the whole point of this control: whichever point the user taps is the
/// colour their check-in takes on the pressure chart, so the two screens say the same thing
/// without a legend.
///
/// Three channels carry the value, not one. Position is fixed worst→best and labelled at
/// both ends; the chosen point's name is printed under the row; and every point has a
/// VoiceOver label. A five-hue ramp on its own is unreadable to a dichromat, and this is
/// the control the entire training label comes from.
private struct WellbeingScaleField: View {

    @Binding var selection: WellbeingScore?

    /// The dots do not grow with Dynamic Type, and the labels around them do.
    ///
    /// Same trade `BarosenseTabBar` makes for its raised action, for the same reason: five of
    /// these have to fit across a 375 pt screen, so the slot is ~75 pt and a dot scaled by the
    /// accessibility sizes would collide with its neighbours rather than help anyone. The tap
    /// target already clears the 44 pt minimum at every size. Checked at
    /// `accessibility-XXXL`: the block wraps, the row stays intact, and the whole form
    /// scrolls.
    private enum Metrics {
        static let dotDiameter: CGFloat = 34
        /// Grown when chosen, so the selection survives with colour vision taken away.
        static let selectedDotDiameter: CGFloat = 42
        static let selectionRingWidth: CGFloat = 2
        /// Well clear of the 44 pt minimum target even at the smaller diameter.
        static let minimumTapTarget: CGFloat = 48
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 0) {
                ForEach(WellbeingScore.allCases, id: \.self) { score in
                    dot(for: score)
                        .frame(maxWidth: .infinity)
                }
            }

            HStack {
                endLabel("Worse")
                Spacer(minLength: 12)
                endLabel("Better")
            }

            // One line that either names the choice or asks for one, so the block does not
            // change height when the user taps.
            Group {
                if let selection {
                    Text(selection.label)
                        .font(Typography.choiceLabel)
                        .foregroundStyle(Palette.heading)
                } else {
                    Text("Tap a point to choose")
                        .font(Typography.choiceLabel)
                        .foregroundStyle(Palette.placeholder)
                }
            }
            .frame(maxWidth: .infinity, alignment: .center)
            .accessibilityHidden(true)
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity)
        .background {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .fill(Palette.cardSurface)
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .strokeBorder(Palette.cardBorder, lineWidth: 1)
                }
        }
        .animation(.easeInOut(duration: 0.15), value: selection)
    }

    private func dot(for score: WellbeingScore) -> some View {
        let isSelected = selection == score
        let diameter = isSelected ? Metrics.selectedDotDiameter : Metrics.dotDiameter

        return Button {
            selection = score
        } label: {
            Circle()
                .fill(Palette.wellbeing(score))
                .frame(width: diameter, height: diameter)
                // An ink ring rather than a brighter fill: the fill is the value, so it may
                // not also carry the selection.
                .overlay {
                    if isSelected {
                        Circle()
                            .strokeBorder(Palette.ink, lineWidth: Metrics.selectionRingWidth)
                            .padding(-4)
                    }
                }
                .frame(width: Metrics.minimumTapTarget, height: Metrics.minimumTapTarget)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(Text(score.label))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func endLabel(_ text: LocalizedStringKey) -> some View {
        Text(text)
            .font(Typography.fieldUnit)
            .foregroundStyle(Palette.placeholder)
            .accessibilityHidden(true)
    }
}

// MARK: - Model

/// What went wrong writing a check-in.
enum CheckInFailure: Error {
    /// The row could not be written. The form keeps everything the user entered so they can
    /// retry — a check-in is a minute of someone's attention and must not be thrown away
    /// because the disk was full.
    case couldNotSave
}

/// State behind the Log screen.
///
/// Holds no domain logic. What a check-in *means* — the 1–5 scale, the label threshold, what
/// a tag identifier is — lives in `Shared/Models/`, where a test reaches it without a screen.
@MainActor
@Observable
final class LogModel {

    var score: WellbeingScore?

    var note: String = ""

    private(set) var selectedTagIDs: Set<WellbeingTag.ID> = []

    /// The vocabulary this check-in may use, read from the store rather than from
    /// `WellbeingTag.seeds` — the user has been adding to and retiring from it since
    /// onboarding, and the seeds are only where it started.
    private(set) var offeredTags: [WellbeingTag] = []

    private(set) var isSaving = false

    private(set) var failure: CheckInFailure?

    private let checkInStore: any CheckInStore
    private let tagStore: any WellbeingTagStore
    private let now: @Sendable () -> Date
    private let onSaved: () -> Void

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         now: @escaping @Sendable () -> Date = { Date() },
         onSaved: @escaping () -> Void) {
        self.checkInStore = checkInStore
        self.tagStore = tagStore
        self.now = now
        self.onSaved = onSaved
    }

    /// The score is the only required answer: it is the label the model is trained on
    /// (`.claude/context/ml-spec.md` §1), and a check-in without one is not a row.
    var canSave: Bool { score != nil && !isSaving }

    func load() async {
        guard offeredTags.isEmpty else { return }

        // A vocabulary that will not load costs the tag section and nothing else — the
        // score is what makes the check-in, so the form stays usable.
        offeredTags = Self.inSeedOrder((try? await tagStore.activeTags()) ?? [])
    }

    func toggleTag(_ id: WellbeingTag.ID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    func save() {
        Task { await commit() }
    }

    private func commit() async {
        guard let score, !isSaving else { return }

        isSaving = true
        failure = nil
        defer { isSaving = false }

        let checkIn = CheckIn(timestamp: now(),
                              score: score,
                              tagIDs: selectedTagIDs,
                              note: trimmedNote)

        do {
            try await checkInStore.save(checkIn)
        } catch {
            failure = .couldNotSave
            return
        }

        onSaved()
    }

    /// Whitespace-only notes are stored as no note at all, so "the user wrote something"
    /// stays a meaningful distinction.
    private var trimmedNote: String? {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Shipped tags in the order `WellbeingTag.seeds` declares them, with anything the user
    /// added after.
    ///
    /// The store sorts by the stored base-language `name`, which in a translated build is
    /// the alphabetical order of a language the user is not reading. Seed order is the only
    /// one stable across languages — and it is the order onboarding offered these same chips
    /// in, so the two screens do not shuffle the vocabulary between them.
    ///
    /// A near-copy of `OnboardingModel.inSeedOrder`; folding the two into one helper means
    /// touching the onboarding flow, which is outside this change.
    private static func inSeedOrder(_ tags: [WellbeingTag]) -> [WellbeingTag] {
        let position = Dictionary(
            uniqueKeysWithValues: WellbeingTag.seeds.enumerated().map { ($1.id, $0) }
        )

        return tags.sorted { lhs, rhs in
            switch (position[lhs.id], position[rhs.id]) {
            case let (left?, right?): left < right
            case (_?, nil): true
            case (nil, _?): false
            case (nil, nil): lhs.name < rhs.name
            }
        }
    }
}

// MARK: - Previews

#Preview("Empty") {
    LogScreen(checkInStore: InMemoryCheckInStore(),
              tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
              onSaved: {})
}

#Preview("Scale") {
    @Previewable @State var selection: WellbeingScore? = .poor

    VStack(spacing: 20) {
        WellbeingScaleField(selection: $selection)
        WellbeingScaleField(selection: .constant(nil))
    }
    .padding(24)
    .background(Palette.surface)
}
