import SwiftUI

// The check-in sheet (Figma `7:330`) — one check-in: a point on the 1–10 intensity scale,
// whatever tags apply, whatever the user took, and an optional note.
//
// ## Where the design came from
//
// The Figma file itself sits behind a login this session cannot pass; the layout below is
// measured off a PNG of frame `7:330` supplied in the session. Positions are derived from
// the image at ~1.05 pt per pixel, so every metric here is within a point or two of the
// frame rather than read from it. What that leaves genuinely unverified: the exact hex of
// the gradient's middle stops (see `Palette.intensityGradient`) and the corner radii, which
// are taken from the existing components rather than re-measured.
//
// One deliberate divergence, and it is the only one: the frame labels the tag block
// "Симптоми". That word is on the forbidden list in
// `.claude/skills/appstore_compliance/SKILL.md` — it names a condition rather than a
// self-report, and it is the wording an App Review reader sees. The block is labelled
// "What you noticed" instead. Everything else follows the frame.

// MARK: - Screen

/// The check-in form, presented as a sheet from the tab bar's raised centre action.
///
/// Reuses `OnboardingStepScaffold` for its chrome — scrolling content plus a primary action
/// pinned to the bottom, with the progress bar suppressed. Not because a check-in is
/// onboarding, but because that scaffold *is* the app's "content plus one committing action"
/// layout, and a second copy of the 56 pt / 18 pt action button is the exact drift the
/// scaffold's own comment exists to guard against. The type's name is now too narrow; renaming it
/// is a follow-up rather than part of this change.
struct LogScreen: View {

    @State private var model: LogModel
    @State private var isAddingMedication = false
    @FocusState private var isNoteFocused: Bool

    /// Gap between the blocks of the form — 26 pt in the frame, between every pair.
    private static let sectionSpacing: CGFloat = 26

    /// Gap between a section's quiet label and the control under it.
    private static let labelSpacing: CGFloat = 12

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
                Text("Log how you feel")
                    .font(Typography.onboardingTitle)
                    .foregroundStyle(Palette.heading)

                intensitySection

                tagsSection

                medicationSection

                noteField

                // Same handling as the onboarding commit failure, deliberately: it is the
                // same kind of event — the one write the screen exists for did not happen.
                if model.failure != nil {
                    Text("Your check-in could not be saved. Check that the device has free space and try again.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.markerWarm)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { await model.load() }
        .sheet(isPresented: $isAddingMedication) {
            AddMedicationSheet(add: model.add(medication:))
        }
    }

    // MARK: - Intensity

    private var intensitySection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(title: "Intensity")

            IntensityField(value: $model.intensity)
        }
    }

    // MARK: - Tags

    /// Only rendered once the vocabulary is in. An empty `FlowLayout` under a heading reads
    /// as "you have no tags", which is never true — onboarding insists on at least one.
    @ViewBuilder
    private var tagsSection: some View {
        if !model.offeredTags.isEmpty {
            VStack(alignment: .leading, spacing: Self.labelSpacing) {
                SectionLabel(title: "What you noticed")

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

    // MARK: - Medication

    private var medicationSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel(title: "Medication taken")

                Spacer(minLength: 12)

                Button {
                    isAddingMedication = true
                } label: {
                    Text("+ Add")
                        .font(Typography.tertiaryAction)
                        .foregroundStyle(Palette.markerCool)
                        // Padding rather than a frame: the text is short and the tap target
                        // has to reach 44 pt without pushing the label off its baseline.
                        .padding(.vertical, 12)
                        .padding(.leading, 12)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                // Pulled back out of the layout so the enlarged target does not push the
                // label off the row's baseline.
                .padding(.vertical, -12)
            }

            MedicationList(entries: model.medications,
                           remove: model.remove(medication:))
        }
    }

    // MARK: - Note

    /// No section label, matching the frame: the placeholder says what the box is, and a
    /// label above an optional free-text field is the one place in this form where a second
    /// line of chrome buys nothing.
    private var noteField: some View {
        FieldSurface {
            // Four lines reserved rather than one that grows, so the box has the presence
            // the frame gives it and the form does not jump as the user types. It grows to
            // six and scrolls past that — a long note cannot push the action off screen.
            TextField("Note (optional)", text: $model.note, axis: .vertical)
                .lineLimit(4...6)
                .font(Typography.fieldText)
                .foregroundStyle(Palette.heading)
                .textInputAutocapitalization(.sentences)
                .focused($isNoteFocused)
                // Padding, not a frame: `FieldSurface` sets the 56 pt minimum and the field
                // has to be free to grow past it.
                .padding(.vertical, 14)
        }
        // An empty field claims only the width its absent text needs, so a tap on the rest
        // of the box would otherwise do nothing — see `AddMedicationSheet.field`.
        .contentShape(.rect)
        .onTapGesture { isNoteFocused = true }
    }
}

// MARK: - Section label

/// The quiet noun that names a block of the form.
private struct SectionLabel: View {

    let title: LocalizedStringKey

    var body: some View {
        Text(title)
            .font(Typography.sectionLabel)
            .foregroundStyle(Palette.placeholder)
    }
}

// MARK: - Intensity control

/// The chosen intensity as a numeral, over the scale it was chosen on.
private struct IntensityField: View {

    @Binding var value: CheckInIntensity

    var body: some View {
        VStack(spacing: 10) {
            HStack(alignment: .center, spacing: 4) {
                Text(value.rawValue, format: .number)
                    .font(Typography.intensityValue)
                    .foregroundStyle(Palette.intensity(value))
                    .contentTransition(.numericText())

                // The scale's top, not a unit — spelled from `CheckInIntensity` so the two
                // cannot disagree, and verbatim because a numeral is not app copy.
                Text(verbatim: "/\(CheckInIntensity.scale.upperBound)")
                    .font(Typography.fieldUnit)
                    .foregroundStyle(Palette.placeholder)
            }
            .frame(maxWidth: .infinity)
            // The slider below is the accessibility element for this value; a VoiceOver user
            // reading "6" and then "Intensity, 6 of 10" is hearing it twice.
            .accessibilityHidden(true)

            IntensitySlider(value: $value)
        }
        .animation(.snappy(duration: 0.2), value: value)
    }
}

/// The 1–10 scale as a track the user drags along, low on the left (Figma `7:330`).
///
/// Hand-built rather than a `Slider`, for one reason that matters: the track carries the
/// colour ramp end to end, and a system slider fills its leading portion with a tint instead.
/// The gradient is what makes the sheet and the pressure chart legible as one thing — the
/// colour under the thumb is the colour the dot takes on the chart.
///
/// Three channels carry the value, not one: the numeral above, the position along the track,
/// and the hue. A ten-step ramp alone is not readable to a dichromat, and this control is
/// where the entire training label comes from.
private struct IntensitySlider: View {

    @Binding var value: CheckInIntensity

    /// The track and thumb keep their geometry at every content size.
    ///
    /// Same trade `BarosenseTabBar` makes for its raised action: this is a target the user
    /// aims at rather than text they read, the row already clears the 44 pt minimum, and a
    /// thumb scaled to an accessibility size would leave less than a step of travel between
    /// its own edges. The numeral above it scales, which is the part that is read.
    private enum Metrics {
        static let trackHeight: CGFloat = 10
        static let thumbDiameter: CGFloat = 26
        static let thumbBorder: CGFloat = 2.5
        /// Row height, so the whole control clears the 44 pt minimum target.
        static let rowHeight: CGFloat = 44
    }

    var body: some View {
        GeometryReader { proxy in
            // The thumb travels between its own edges rather than its centre, so it never
            // hangs past either end of the track.
            let travel = max(proxy.size.width - Metrics.thumbDiameter, 1)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(LinearGradient(gradient: Palette.intensityGradient,
                                         startPoint: .leading,
                                         endPoint: .trailing))
                    .frame(height: Metrics.trackHeight)

                thumb.offset(x: travel * value.normalized)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            // `minimumDistance: 0` so a tap anywhere on the row sets the value, rather than
            // only a drag that starts on the thumb.
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = (gesture.location.x - Metrics.thumbDiameter / 2) / travel
                        value = CheckInIntensity(position: position)
                    }
            )
        }
        .frame(height: Metrics.rowHeight)
        .sensoryFeedback(.selection, trigger: value)
        .accessibilityElement()
        .accessibilityLabel(Text("Intensity"))
        .accessibilityValue(Text("\(value.rawValue) of \(CheckInIntensity.scale.upperBound)"))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = CheckInIntensity(clamping: value.rawValue + 1)
            case .decrement: value = CheckInIntensity(clamping: value.rawValue - 1)
            @unknown default: break
            }
        }
    }

    /// White, ringed in the colour of the value under it — so the thumb states the value a
    /// third time instead of only marking a position.
    private var thumb: some View {
        Circle()
            .fill(Palette.controlFill)
            .overlay {
                Circle().strokeBorder(Palette.intensity(value), lineWidth: Metrics.thumbBorder)
            }
            .frame(width: Metrics.thumbDiameter, height: Metrics.thumbDiameter)
            .shadow(color: Palette.accentShadow.opacity(0.5), radius: 3, y: 2)
    }
}

// MARK: - Medication

/// What has been recorded for this check-in so far, in one box under the section label.
///
/// The box is drawn whether or not there is anything in it, which is how the frame draws it:
/// the section is a slot with a known shape, so adding the first entry fills the box instead
/// of making the form jump. One container around the rows rather than a card each — the frame
/// shows a single entry, and a stack of separate cards would read as separate sections once
/// there were three.
private struct MedicationList: View {

    let entries: [MedicationEntry]
    let remove: (MedicationEntry.ID) -> Void

    private enum Metrics {
        static let cornerRadius: CGFloat = 14
        /// Where a separator starts: past the marker and its gap, so it lines up with the
        /// text rather than cutting the whole box in half.
        static let separatorInset: CGFloat = MedicationRow.Metrics.horizontalPadding
            + MedicationRow.Metrics.markerSize
            + MedicationRow.Metrics.markerSpacing
    }

    var body: some View {
        VStack(spacing: 0) {
            if entries.isEmpty {
                emptyRow
            } else {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    if index > 0 {
                        Rectangle()
                            .fill(Palette.separator)
                            .frame(height: 1)
                            .padding(.leading, Metrics.separatorInset)
                    }

                    MedicationRow(entry: entry) { remove(entry.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                .fill(Palette.controlFill)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
                        .strokeBorder(Palette.controlBorder, lineWidth: 1)
                }
        }
    }

    /// States that the box is empty rather than that something is wrong. Not a button: the
    /// action is "+ Add", one line above and labelled, and a second invisible way in would
    /// only be found by the users who least need it.
    private var emptyRow: some View {
        Text("Nothing added yet")
            .font(Typography.choiceLabelCompact)
            .foregroundStyle(Palette.placeholder)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, MedicationRow.Metrics.horizontalPadding)
            .padding(.vertical, MedicationRow.Metrics.verticalPadding)
    }
}

/// One recorded entry: a marker, what the user wrote, and a way to take it back off.
///
/// Carries no surface of its own — `MedicationList` draws the box around every row, so a
/// second entry cannot end up with its own card.
private struct MedicationRow: View {

    let entry: MedicationEntry
    let remove: () -> Void

    /// Read by `MedicationList` for its separator inset and its empty row, so the three stay
    /// aligned from one set of numbers.
    enum Metrics {
        static let horizontalPadding: CGFloat = 17
        static let verticalPadding: CGFloat = 13
        static let markerSize: CGFloat = 8
        static let markerSpacing: CGFloat = 12
    }

    var body: some View {
        HStack(spacing: Metrics.markerSpacing) {
            Circle()
                .fill(Palette.markerCool)
                .frame(width: Metrics.markerSize, height: Metrics.markerSize)

            label
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button(action: remove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(Palette.placeholder)
                    // A 44 pt target pulled back out of the layout, so the row keeps the
                    // height the frame draws while the tap area is the one HIG asks for.
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .padding(.vertical, -11)
            .padding(.trailing, -12)
            .accessibilityLabel(Text("Remove"))
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
    }

    /// `verbatim` on both sides: the name and the dose are the user's own words, and the
    /// separator is punctuation rather than copy.
    private var label: Text {
        guard let dose = entry.dose else { return Text(verbatim: entry.name) }
        return Text(verbatim: "\(entry.name) · \(dose)")
    }
}

/// Two fields and a commit — everything `MedicationEntry` holds, and nothing else.
///
/// Free text on both, with no list to match against. A shipped list of names would be a
/// vocabulary the app asserts, and matching what the user typed against it would be
/// interpretation of what they took — see `MedicationEntry`.
private struct AddMedicationSheet: View {

    let add: (MedicationEntry) -> Void

    private enum Field { case name, dose }

    @State private var name = ""
    @State private var dose = ""
    @FocusState private var focused: Field?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: nil,
            actionTitle: "Add",
            isActionEnabled: entry != nil,
            action: commit
        ) {
            VStack(alignment: .leading, spacing: 18) {
                OnboardingHeader(title: "What did you take?")

                // Its own key rather than the profile step's "Name": Ukrainian splits the
                // two, and a person's name and a thing's name are not the same word.
                field(placeholder: "Medication name", text: $name, field: .name)
                    .textInputAutocapitalization(.words)

                field(placeholder: "Dose (optional)", text: $dose, field: .dose)
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear { focused = .name }
    }

    /// `nil` until there is a name — which is also what disables the action, so the sheet has
    /// one definition of "ready" rather than two that can disagree.
    private var entry: MedicationEntry? {
        MedicationEntry(name: name, dose: dose)
    }

    private func commit() {
        guard let entry else { return }
        add(entry)
        dismiss()
    }

    private func field(placeholder: LocalizedStringKey,
                       text: Binding<String>,
                       field: Field) -> some View {
        FieldSurface {
            TextField(placeholder, text: text)
                .font(Typography.fieldText)
                .foregroundStyle(Palette.heading)
                // Both fields take letters *and* digits, stated rather than left to the
                // system: a medication is "Ібупрофен", a dose is "400 мг" or "two", and
                // neither is a number. Spelled out so no inherited or heuristic keyboard
                // type can narrow it — this field reported as digits-only in the field.
                .keyboardType(.default)
                // Off, and this is the important one. A medication name is a brand name, not
                // a dictionary word: Ukrainian autocorrect rewrites it while it is still
                // being typed, and the inline completion it puts on screen is marked text
                // that a redraw of this sheet can drop — which reads as the field refusing
                // letters while accepting digits, since digits are never autocorrected.
                .autocorrectionDisabled()
                // No AutoFill. iOS otherwise offers to fill a contact's name here, which is
                // both the wrong value and an invitation to put a third party's name into a
                // health record on this device.
                .textContentType(nil)
                .focused($focused, equals: field)
                .submitLabel(field == .name ? .next : .done)
                .onSubmit {
                    if field == .name {
                        focused = .dose
                    } else {
                        commit()
                    }
                }
        }
        // An empty `TextField` only claims the width its (absent) text needs, so without
        // this a tap on the right two-thirds of the box lands on the surface and focus stays
        // wherever it was. Found on device: typing after tapping "Dose" went on filling in
        // the name. The `TextField` is hit-tested first, so a tap on real text still places
        // the caret rather than jumping to the end.
        .contentShape(.rect)
        .onTapGesture { focused = field }
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

/// State behind the check-in sheet.
///
/// Holds no domain logic. What a check-in *means* — the 1–10 scale, the label threshold, what
/// a tag identifier is — lives in `Shared/Models/`, where a test reaches it without a screen.
@MainActor
@Observable
final class LogModel {

    /// Opens at the middle of the scale, which is what the frame draws: a slider has no
    /// unset state to show, so there is nothing to draw for "not answered yet".
    ///
    /// **This biases the label** and the bias is worth stating: a user who saves without
    /// touching the track records a 5 they did not choose, and 5 is one point below the
    /// event threshold. The honest fix is to require a deliberate touch before the action
    /// enables, which the frame's always-dark button rules out. Revisit once there is enough
    /// history to see how often 5 is recorded — an implausible spike at exactly 5 is the
    /// signal, and it is measurable from the same data.
    var intensity = CheckInIntensity(clamping: 5)

    var note: String = ""

    private(set) var selectedTagIDs: Set<WellbeingTag.ID> = []

    private(set) var medications: [MedicationEntry] = []

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

    /// The intensity always has a value, so the only thing that closes the action is a write
    /// already in flight — which matches the frame, where the button is never dimmed.
    var canSave: Bool { !isSaving }

    func load() async {
        guard offeredTags.isEmpty else { return }

        // A vocabulary that will not load costs the tag section and nothing else — the
        // intensity is what makes the check-in, so the form stays usable.
        offeredTags = Self.inSeedOrder((try? await tagStore.activeTags()) ?? [])
    }

    func toggleTag(_ id: WellbeingTag.ID) {
        if selectedTagIDs.contains(id) {
            selectedTagIDs.remove(id)
        } else {
            selectedTagIDs.insert(id)
        }
    }

    /// Appended rather than merged. Two entries with the same name are two entries: the user
    /// may well have taken the same thing twice, and this screen is not in a position to
    /// decide they did not.
    func add(medication: MedicationEntry) {
        medications.append(medication)
    }

    func remove(medication id: MedicationEntry.ID) {
        medications.removeAll { $0.id == id }
    }

    func save() {
        Task { await commit() }
    }

    private func commit() async {
        guard !isSaving else { return }

        isSaving = true
        failure = nil
        defer { isSaving = false }

        let checkIn = CheckIn(timestamp: now(),
                              intensity: intensity,
                              tagIDs: selectedTagIDs,
                              medications: medications,
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

#Preview("Sheet") {
    Color.black.sheet(isPresented: .constant(true)) {
        LogScreen(checkInStore: InMemoryCheckInStore(),
                  tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                  onSaved: {})
    }
}

#Preview("Scale") {
    @Previewable @State var low = CheckInIntensity(clamping: 1)
    @Previewable @State var middle = CheckInIntensity(clamping: 6)
    @Previewable @State var high = CheckInIntensity(clamping: 10)

    VStack(spacing: 28) {
        IntensityField(value: $low)
        IntensityField(value: $middle)
        IntensityField(value: $high)
    }
    .padding(24)
    .background(Palette.surface)
}

#Preview("Medication") {
    VStack(alignment: .leading, spacing: 20) {
        MedicationList(entries: [], remove: { _ in })

        // `MedicationEntry.init?` only rejects a blank name, so `compactMap` drops nothing
        // from these literals — it is how the preview builds its rows without a force
        // unwrap, which the lint config bans outside test targets.
        MedicationList(entries: [MedicationEntry(name: "Ibuprofen", dose: "400 mg")].compactMap { $0 },
                       remove: { _ in })

        MedicationList(entries: [MedicationEntry(name: "Ibuprofen", dose: "400 mg"),
                                 MedicationEntry(name: "Magnesium")].compactMap { $0 },
                       remove: { _ in })
    }
    .padding(24)
    .background(Palette.surface)
}
