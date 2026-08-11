import SwiftUI

// The medication sheet (Figma `Додати ліки`) — one entry for the check-in being written:
// what the user took, how much, and when.
//
// ## Where the design came from
//
// A screenshot of the frame supplied in the session, measured at ~1.72 pt per pixel (the
// device body in the shot is 234 px wide for a 402 pt screen). Metrics are therefore within a
// point or two rather than read off the frame, and corner radii come from the existing
// components rather than being re-measured — the same basis as `LogScreen`.
//
// ## Three deliberate divergences, and why
//
// 1. **The frame's chips carry a name *and* a dose** ("Ібупрофен 400мг") while it also has a
//    separate "Дозування" block. Shipped with the name alone on the chip and the dose owned by
//    its own block: two places showing the same dose can disagree, and the recorded entry has
//    to come from exactly one of them. Picking a remembered name preselects the dose last used
//    with it, so the frame's two-tap outcome survives.
// 2. **A "+ Інша доза" chip** was added beside the remembered doses, matching the frame's own
//    "+ Новий засіб". The frame offers no way to enter a dose it has not seen before, which
//    cannot ship — the first dose of anything would be unenterable.
// 3. **The "Нагадувати про повторний прийом" row is not here.** Two reasons, both blocking.
//    The frame gives the toggle no interval control, so the app would be choosing when the
//    next dose is due — that is dosing guidance, not tracking, and it is the kind of claim
//    `.claude/skills/appstore_compliance/SKILL.md` exists to keep out. And there is no
//    notification code anywhere in this repo yet: authorisation, scheduling and cancellation
//    should be built once, for the forecast warning `CLAUDE.md` describes, not bolted onto a
//    medication form. A reminder at a time the *user* names is fine and is the shape to build.

// MARK: - Sheet

/// Picks one `MedicationEntry` and hands it to the check-in being written.
///
/// Everything the two chip rows offer comes from `history` — the user's own earlier entries.
/// The sheet proposes nothing of its own; see `MedicationHistory`.
struct AddMedicationSheet: View {

    /// What the user has recorded taking recently. Empty on a first run, which is the case the
    /// layout below is built around rather than the case it degrades into.
    let history: [MedicationEntry]

    let add: (MedicationEntry) -> Void

    /// Which chip in a section is active: one the user has used before, or the one that opens
    /// a field for something new. Used by both the name and the dose row — they are the same
    /// control twice, and giving them one type keeps them behaving the same way.
    private enum Choice: Hashable {
        case remembered(String)
        case new
    }

    private enum TimeChoice: Hashable {
        case now
        case recent
        case custom
    }

    private enum Field: Hashable {
        case name
        case dose
    }

    @State private var nameChoice: Choice?
    @State private var typedName = ""

    @State private var doseChoice: Choice?
    @State private var typedDose = ""

    @State private var timeChoice: TimeChoice = .now

    /// Only meaningful once `timeChoice` is `.custom`, and set from the current selection at
    /// the moment the user asks for it — so the picker opens where they already were.
    @State private var customTime = Date()

    /// Fixed for the life of the sheet rather than read per redraw: "Now" and the mark beside
    /// it must not drift under the user while they are looking at them, and the difference
    /// between presenting the sheet and tapping Add is not information this screen records.
    @State private var now = Date()

    @FocusState private var focused: Field?
    @Environment(\.dismiss) private var dismiss

    /// Gap between the blocks of the form, and between a block's label and its content —
    /// the same pair `LogScreen` uses, so the two sheets read as one screen.
    private static let sectionSpacing: CGFloat = 24
    private static let labelSpacing: CGFloat = 10

    /// The minute grid the second time chip snaps to: `09:40` at 09:41, as the frame draws it.
    private static let markMinutes = 10

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: nil,
            actionTitle: "Add to check-in",
            isActionEnabled: entry != nil,
            action: commit
        ) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header

                nameSection

                doseSection

                timeSection
            }
        }
        // Full height only, though the frame draws a shorter card. At `.medium` the scaffold's
        // pinned action draws *over* the last section — its action bar is a sibling of the
        // scroll view rather than a safe-area inset, so it does not push the content up when
        // the container is too short for it. Fixing that properly means changing all six
        // onboarding steps and is its own change; until then this sheet asks for the height it
        // needs. It also lands at the same height as the check-in sheet behind it, so moving
        // between the two does not resize the card under the user's thumb.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        .onAppear {
            // Straight into the field when there is nothing to pick from — on a first run the
            // chips are absent and typing is the only thing to do.
            if isTypingName { focused = .name }
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Add medication")
                .font(Typography.onboardingTitleCompact)
                .foregroundStyle(Palette.heading)

            Spacer(minLength: 12)

            closeButton
        }
    }

    /// The frame's grey disc. Duplicates the drag indicator's job, and keeps it: a sheet with
    /// a visible close control is dismissable without knowing that it can be dragged.
    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.placeholder)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.segmentedTrack))
                // A 44 pt target around a 30 pt disc, pulled back out of the layout so the
                // row keeps the height the frame draws.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, -7)
        .padding(.trailing, -7)
        .accessibilityLabel(Text("Close"))
    }

    // MARK: - Name

    private var nameSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(title: "Your medications")

            if !rememberedNames.isEmpty {
                FlowLayout {
                    ForEach(rememberedNames, id: \.self) { name in
                        // `Text(verbatim:)` — the user's own word, never a key to translate.
                        ChoiceChip(text: Text(verbatim: name),
                                   isSelected: nameChoice == .remembered(name),
                                   font: Typography.choiceLabelCompact) {
                            select(name: name)
                        }
                    }

                    ChoiceChip(title: "+ New medication",
                               isSelected: nameChoice == .new,
                               font: Typography.choiceLabelCompact) {
                        nameChoice = .new
                        focused = .name
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isTypingName {
                field(placeholder: "Medication name", text: $typedName, field: .name)
                    .textInputAutocapitalization(.words)
            }
        }
    }

    /// Also resets the dose, deliberately. The dose row below is filtered by the chosen name,
    /// so a dose carried over from the previous choice would stay in effect with no chip left
    /// on screen to show it — the entry would then record an amount the user cannot see.
    private func select(name: String) {
        guard nameChoice != .remembered(name) else { return }

        nameChoice = .remembered(name)
        focused = nil
        doseChoice = MedicationHistory.doses(in: history, for: name).first.map(Choice.remembered)
    }

    // MARK: - Dose

    private var doseSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(title: "Dose")

            if !rememberedDoses.isEmpty {
                FlowLayout {
                    ForEach(rememberedDoses, id: \.self) { dose in
                        ChoiceChip(text: Text(verbatim: dose),
                                   isSelected: doseChoice == .remembered(dose),
                                   font: Typography.choiceLabelCompact) {
                            doseChoice = .remembered(dose)
                            focused = nil
                        }
                    }

                    ChoiceChip(title: "+ Other dose",
                               isSelected: doseChoice == .new,
                               font: Typography.choiceLabelCompact) {
                        doseChoice = .new
                        focused = .dose
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if isTypingDose {
                field(placeholder: "Dose (optional)", text: $typedDose, field: .dose)
            }
        }
    }

    // MARK: - Time

    private var timeSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionLabel(title: "Time taken")

            FlowLayout {
                ChoiceChip(title: "Now",
                           isSelected: timeChoice == .now,
                           font: Typography.choiceLabelCompact) {
                    timeChoice = .now
                    focused = nil
                }

                // A clock reading, formatted for the reader's locale and 12/24-hour setting —
                // not app copy, so it carries no key.
                ChoiceChip(text: Text(verbatim: recentMark.formatted(date: .omitted, time: .shortened)),
                           isSelected: timeChoice == .recent,
                           font: Typography.choiceLabelCompact) {
                    timeChoice = .recent
                    focused = nil
                }

                ChoiceChip(title: "Other time",
                           isSelected: timeChoice == .custom,
                           font: Typography.choiceLabelCompact) {
                    chooseCustomTime()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if timeChoice == .custom {
                // The wheel itself, not a `.compact` field that opens one in a popover: this
                // chip is the same promise "+ Other dose" makes one section up — tap it and
                // the control you need is there, ready to use. A pill that has to be tapped
                // again to reveal the clock is one extra tap on the only section of this form
                // that is about a number the user has to think about.
                DatePicker(selection: $customTime, displayedComponents: .hourAndMinute) {
                    Text("Time taken")
                }
                .datePickerStyle(.wheel)
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }
        }
    }

    /// Opens the picker on whatever is currently selected, so switching to "Other time" never
    /// silently changes the answer before the user has touched anything.
    private func chooseCustomTime() {
        customTime = takenAt
        timeChoice = .custom
        focused = nil
    }

    /// The last ten-minute mark before `now` — the frame's middle chip, `09:40` at 09:41.
    ///
    /// Built from components rather than by subtracting seconds, so the result lands exactly on
    /// the minute the chip is showing instead of carrying the fractional seconds of `now`.
    private var recentMark: Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: now)
        components.minute = ((components.minute ?? 0) / Self.markMinutes) * Self.markMinutes

        return calendar.date(from: components) ?? now
    }

    /// The picked wall-clock time, today — or yesterday when today would put it in the future.
    ///
    /// A time picker has no day. "23:00" chosen at 09:41 means last night, and recording it as
    /// tonight would file a dose fourteen hours *after* the check-in that carries it.
    private var resolvedCustomTime: Date {
        guard customTime > now else { return customTime }

        return Calendar.current.date(byAdding: .day, value: -1, to: customTime) ?? now
    }

    // MARK: - Result

    /// `nil` until there is a name, which is also what disables the action — one definition of
    /// "ready" rather than two that can disagree.
    private var entry: MedicationEntry? {
        guard let resolvedName else { return nil }

        return MedicationEntry(name: resolvedName, dose: resolvedDose, takenAt: takenAt)
    }

    private var takenAt: Date {
        switch timeChoice {
        case .now: now
        case .recent: recentMark
        case .custom: resolvedCustomTime
        }
    }

    /// Typing wins whenever the field is on screen — either the user asked for a new name, or
    /// there is nothing remembered to pick and the field is the only control there is.
    private var isTypingName: Bool { nameChoice == .new || rememberedNames.isEmpty }

    private var isTypingDose: Bool { doseChoice == .new || rememberedDoses.isEmpty }

    private var resolvedName: String? {
        if isTypingName { return typedName }
        if case .remembered(let name) = nameChoice { return name }

        return nil
    }

    private var resolvedDose: String? {
        if isTypingDose { return typedDose }
        if case .remembered(let dose) = doseChoice { return dose }

        return nil
    }

    private var rememberedNames: [String] {
        MedicationHistory.names(in: history)
    }

    /// Narrowed to the chosen name only when it is one from the list — while a new name is
    /// being typed there is nothing to narrow by, and every dose the user has used is a better
    /// offer than none.
    private var rememberedDoses: [String] {
        guard case .remembered(let name) = nameChoice else {
            return MedicationHistory.doses(in: history)
        }

        return MedicationHistory.doses(in: history, for: name)
    }

    private func commit() {
        guard let entry else { return }

        add(entry)
        dismiss()
    }

    // MARK: - Field

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
                    if field == .name, isTypingDose {
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

// MARK: - Previews

#Preview("First run") {
    Color.black.sheet(isPresented: .constant(true)) {
        AddMedicationSheet(history: [], add: { _ in })
    }
}

#Preview("With history") {
    // `compactMap` rather than a `!`: `MedicationEntry` is failable by design, and the ban on
    // force unwrapping holds in a preview too — this target is not a test target.
    let now = Date()
    let hour: TimeInterval = 3600
    let history = [
        MedicationEntry(name: "Ібупрофен", dose: "400 мг", takenAt: now - hour),
        MedicationEntry(name: "Суматриптан", dose: "50 мг", takenAt: now - 24 * hour),
        MedicationEntry(name: "Ібупрофен", dose: "1 таблетка", takenAt: now - 48 * hour)
    ].compactMap { $0 }

    Color.black.sheet(isPresented: .constant(true)) {
        AddMedicationSheet(history: history, add: { _ in })
    }
}
