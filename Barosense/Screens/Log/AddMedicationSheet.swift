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
// ## Four deliberate divergences, and why
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
// 4. **The frame's middle time chip is a clock reading** — the last ten-minute mark before now,
//    `09:40` at 09:41. It has been replaced by "Other day". The mark bought the user nothing:
//    it named a moment at most ten minutes before "Now", and nothing this app measures resolves
//    that finely. What was missing instead was the day. A time wheel has no date, so until this
//    chip existed a dose taken yesterday could only be entered as one taken today — the sheet
//    would file it against the wrong day and the History grid would colour the wrong cell.

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

    /// Chips the user has dismissed, and where a dismissal is recorded.
    ///
    /// The sheet writes through it and re-reads into `hiddenNames` / `hiddenDoses` below,
    /// rather than reading the store inside `body`: a `body` that calls into a store is a
    /// `body` whose output SwiftUI has no reason to recompute when the store changes.
    let chips: any MedicationChipStore

    /// Mirrors of the store, refreshed on appearance and after every removal.
    @State private var hiddenNames: Set<String> = []

    /// Keyed the way `MedicationChipStore` keys it: folded medication name, or `nil` for the
    /// unfiltered row. Held as the one bucket currently on screen, because that is the only
    /// one the dose row can draw.
    @State private var hiddenDoses: Set<String> = []

    /// Which chip in a section is active: one the user has used before, or the one that opens
    /// a field for something new. Used by both the name and the dose row — they are the same
    /// control twice, and giving them one type keeps them behaving the same way.
    private enum Choice: Hashable {
        case remembered(String)
        case new
    }

    /// Which part of the timestamp the user wants to say something about: nothing (it is now),
    /// the clock time, or the day. Each one reveals the control that edits it.
    private enum TimeChoice: Hashable {
        case now
        case custom
        case customDay
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

    /// The counterpart for `.customDay`. Carries a whole instant, not just a day: the calendar
    /// edits the date components and leaves the time of day exactly as it was seeded, so a dose
    /// the user placed at 09:00 stays at 09:00 when they move it to yesterday.
    @State private var customDay = Date()

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
            // Before the focus decision below, not after: that decision reads `rememberedNames`,
            // which is the history minus what has been dismissed. Reading it against an empty
            // hidden set would leave the field unfocused on a sheet whose every chip is hidden.
            refreshHidden()

            // Straight into the field when there is nothing to pick from — on a first run the
            // chips are absent and typing is the only thing to do.
            if isTypingName { focused = .name }
        }
        // The dose row is filtered by the chosen medication, so the bucket of hidden doses moves
        // with it. Without this, doses dismissed under one medication would stay dismissed under
        // the next one the user picked.
        .onChange(of: doseBucket) { hiddenDoses = chips.hiddenDoses(for: doseBucket) }
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
                        DismissableChoiceChip(text: Text(verbatim: name),
                                              isSelected: nameChoice == .remembered(name),
                                              select: { select(name: name) },
                                              dismiss: { forget(name: name) })
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
                        DismissableChoiceChip(text: Text(verbatim: dose),
                                              isSelected: doseChoice == .remembered(dose),
                                              select: {
                                                  doseChoice = .remembered(dose)
                                                  focused = nil
                                              },
                                              dismiss: { forget(dose: dose) })
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

                ChoiceChip(title: "Other time",
                           isSelected: timeChoice == .custom,
                           font: Typography.choiceLabelCompact) {
                    chooseCustomTime()
                }

                ChoiceChip(title: "Other day",
                           isSelected: timeChoice == .customDay,
                           font: Typography.choiceLabelCompact) {
                    chooseCustomDay()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if timeChoice == .custom {
                // The wheel itself, not a `.compact` field that opens one in a popover: this
                // chip is the same promise "+ Other dose" makes one section up — tap it and
                // the control you need is there, ready to use. A pill that has to be tapped
                // again to reveal the clock is one extra tap on the only section of this form
                // that is about a number the user has to think about.
                TimeWheel(date: $customTime)
            }

            if timeChoice == .customDay {
                // Same promise, kept the same way: the calendar is on screen the moment the
                // chip is tapped rather than behind a `.compact` field that opens one.
                DayCalendar(date: $customDay, latest: latestDay)
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

    /// Opens the calendar on the day currently selected, for the same reason `chooseCustomTime`
    /// opens the wheel on the current time: switching chips must not change the answer.
    ///
    /// Seeding from `takenAt` is also what keeps the picker's range honest — `takenAt` is never
    /// in the future, so the time of day the calendar carries forward cannot push the newly
    /// picked day past `latestDay`.
    private func chooseCustomDay() {
        customDay = takenAt
        timeChoice = .customDay
        focused = nil
    }

    /// The last day the calendar offers: the end of today. A dose cannot have been taken after
    /// the moment the user is writing it down.
    private var latestDay: Date {
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now))

        return tomorrow?.addingTimeInterval(-1) ?? now
    }

    /// The picked wall-clock time, today — or yesterday when today would put it in the future.
    ///
    /// A time picker has no day. "23:00" chosen at 09:41 means last night, and recording it as
    /// tonight would file a dose fourteen hours *after* the check-in that carries it. This
    /// guess only applies to `.custom`; `.customDay` is the user saying which day outright, and
    /// nothing there needs inferring.
    private var resolvedCustomTime: Date {
        guard customTime > now else { return customTime }

        return Calendar.current.date(byAdding: .day, value: -1, to: customTime) ?? now
    }

    // MARK: - Forgetting a chip

    /// Stops offering `name`, and clears the selection if that is what was selected.
    ///
    /// **Removes no history.** The entries keep counting on the "My medications" screen and in
    /// the report; what goes away is the offer. See `MedicationChipStore`.
    private func forget(name: String) {
        chips.hideName(name)
        if nameChoice == .remembered(name) {
            nameChoice = .new
            // The dose row is filtered by the name, so leaving a dose selected under a name
            // that is no longer chosen would record an amount with nothing on screen showing it
            // — the same reasoning as `select(name:)`.
            doseChoice = nil
        }
        refreshHidden()
    }

    private func forget(dose: String) {
        chips.hideDose(dose, for: doseBucket)
        if doseChoice == .remembered(dose) { doseChoice = nil }
        refreshHidden()
    }

    private func refreshHidden() {
        hiddenNames = chips.hiddenNames()
        hiddenDoses = chips.hiddenDoses(for: doseBucket)
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
            // Prompt drawn rather than handed to `TextField` — see `fieldPlaceholder`. It
            // wraps the field, so it goes on last, after `.focused` and `.onSubmit` have
            // reached the field itself. The prompt is hidden from VoiceOver there, hence the
            // label here.
            TextField("", text: text)
                .font(Typography.fieldText)
                .foregroundStyle(Palette.heading)
                .accessibilityLabel(Text(placeholder))
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
                .fieldPlaceholder(placeholder, isVisible: text.wrappedValue.isEmpty)
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

// MARK: - Derived values

/// What the form adds up to.
///
/// No SwiftUI below this line: every value here is a function of the `@State` above it,
/// which is what lets the view read as a layout and this read as the rules behind it.
extension AddMedicationSheet {

    /// `nil` until there is a name, which is also what disables the action — one definition of
    /// "ready" rather than two that can disagree.
    private var entry: MedicationEntry? {
        guard let resolvedName else { return nil }

        return MedicationEntry(name: resolvedName, dose: resolvedDose, takenAt: takenAt)
    }

    private var takenAt: Date {
        switch timeChoice {
        case .now: now
        case .custom: resolvedCustomTime
        case .customDay: customDay
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
        MedicationHistory.names(in: history, hiding: hiddenNames)
    }

    /// Narrowed to the chosen name only when it is one from the list — while a new name is
    /// being typed there is nothing to narrow by, and every dose the user has used is a better
    /// offer than none.
    private var rememberedDoses: [String] {
        guard case .remembered(let name) = nameChoice else {
            return MedicationHistory.doses(in: history, hiding: hiddenDoses)
        }

        return MedicationHistory.doses(in: history, for: name, hiding: hiddenDoses)
    }

    /// The dose bucket the row currently draws from — the chosen name, or `nil` for the
    /// unfiltered row. One place, because the read and the write have to agree on it.
    private var doseBucket: String? {
        guard case .remembered(let name) = nameChoice else { return nil }
        return name
    }
}

// MARK: - Dismissable chip

/// A remembered chip with a ✕ that stops it being offered (Figma `Додати ліки`, matching the
/// removable tag chips in Edit Profile).
///
/// ## Why two buttons and not one
///
/// `RemovableTagChip` makes the whole chip the remove button, because there the chip has no
/// other job — the tags in Edit Profile are a list you add to and take from. Here the chip has
/// a primary action already: it is what selects the medication. So the mark has to be its own
/// target, and the rest of the chip keeps selecting.
///
/// That makes the mark the small target the tag chip deliberately avoided, so it is given its
/// own padding rather than a bare glyph: `dismissHitWidth` across and the full chip height,
/// which clears 44 pt vertically and gets close to it horizontally. Wider than that starts
/// eating the label on a chip like "400 mg".
///
/// The two are separated by more than proximity, which matters because the outcomes are not
/// symmetrical: selecting is free, dismissing takes a chip away. Hence a `plain` button style
/// on the mark — no highlight bleeding across the whole chip — and a distinct accessibility
/// action rather than one element with two meanings.
private struct DismissableChoiceChip: View {

    let text: Text
    let isSelected: Bool
    let select: () -> Void
    let dismiss: () -> Void

    private enum Metrics {
        static let horizontalPadding: CGFloat = 18
        static let verticalPadding: CGFloat = 13
        static let spacing: CGFloat = 8
        static let cornerRadius: CGFloat = 20
        static let markSize: CGFloat = 10
        /// The mark's own hit area. See the type's documentation for why it is not the glyph.
        static let dismissHitWidth: CGFloat = 34
    }

    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                text
                    .font(Typography.choiceLabelCompact)
                    .foregroundStyle(isSelected ? Palette.onInk : Palette.bodyText)
                    .padding(.leading, Metrics.horizontalPadding)
                    .padding(.trailing, Metrics.spacing)
                    .padding(.vertical, Metrics.verticalPadding)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)

            Button(action: dismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: Metrics.markSize, weight: .bold))
                    .foregroundStyle(
                        isSelected ? Palette.onInk.opacity(0.7) : Palette.bodyText.opacity(0.55)
                    )
                    .frame(width: Metrics.dismissHitWidth)
                    .frame(maxHeight: .infinity)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text("Stop offering this"))
        }
        .fixedSize(horizontal: true, vertical: false)
        .background(ChoiceBackground(isSelected: isSelected,
                                     cornerRadius: Metrics.cornerRadius))
    }
}

// MARK: - Time wheel

/// The hour and minute wheel, built from `WheelColumn` rather than `DatePicker(.wheel)` — see
/// that type for why the system picker could not be styled onto `Palette`.
///
/// The cost is the 12/24-hour question `DatePicker` answered for free. It is asked of the
/// locale's own format template, the same source a formatted time would resolve through, so a
/// reader on a 12-hour locale gets a period column and one on a 24-hour locale does not.
private struct TimeWheel: View {

    @Binding var date: Date

    /// The app's language and calendar rather than `.current`, which is still whatever the
    /// app launched in — see `LanguageController`. It is the period column that shows this:
    /// after a switch to Ukrainian, `.current` would still spell the two rows "AM" / "PM".
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// Whether the reader writes "9:41 PM" rather than "21:41". Asked of the format the locale
    /// resolves for a bare time rather than inferred from the region.
    private var usesPeriod: Bool {
        DateFormatter.dateFormat(fromTemplate: "j", options: 0, locale: locale)?
            .contains("a") ?? false
    }

    /// The locale's own symbols, not "AM"/"PM" literals: those strings belong to the reader's
    /// locale rather than to this app's copy.
    private var amSymbol: String { periodSymbols.amSymbol }

    private var pmSymbol: String { periodSymbols.pmSymbol }

    private var periodSymbols: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        return formatter
    }

    var body: some View {
        HStack(spacing: 0) {
            WheelColumn(selection: hourSelection, values: hourValues) {
                Text(verbatim: String(format: "%02d", $0))
            }

            WheelColumn(selection: minuteSelection, values: Array(0...59)) {
                Text(verbatim: String(format: "%02d", $0))
            }

            if usesPeriod {
                WheelColumn(selection: periodSelection, values: [false, true]) {
                    Text(verbatim: $0 ? pmSymbol : amSymbol)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: WheelColumn<Int>.standardHeight)
    }

    // MARK: Selections

    /// Read straight off the binding rather than mirrored into `@State`: a local copy of the
    /// time is a second answer that can disagree with the one the sheet will record.
    private var parts: DateComponents {
        calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
    }

    /// Always 0–23, whatever the columns display, so the hour and the period cannot disagree
    /// about which half of the day was picked.
    private var hour24: Int { parts.hour ?? 0 }

    private var hourValues: [Int] { usesPeriod ? Array(1...12) : Array(0...23) }

    private var hourSelection: Binding<Int> {
        Binding(get: { usesPeriod ? (hour24 % 12 == 0 ? 12 : hour24 % 12) : hour24 },
                set: { update(hour: usesPeriod ? ($0 % 12) + (hour24 >= 12 ? 12 : 0) : $0) })
    }

    private var minuteSelection: Binding<Int> {
        Binding(get: { parts.minute ?? 0 }, set: { update(minute: $0) })
    }

    /// `true` is the afternoon half. A `Bool` rather than an enum because the column has
    /// exactly two rows and the locale supplies both of their names.
    private var periodSelection: Binding<Bool> {
        Binding(get: { hour24 >= 12 },
                set: { update(hour: (hour24 % 12) + ($0 ? 12 : 0)) })
    }

    /// Rebuilt from the date's own components, so the day survives a change of hour — this
    /// wheel names a wall-clock time, and `resolvedCustomTime` decides which day it lands on.
    private func update(hour: Int? = nil, minute: Int? = nil) {
        var updated = parts
        if let hour { updated.hour = hour }
        if let minute { updated.minute = minute }

        date = calendar.date(from: updated) ?? date
    }
}

// MARK: - Day calendar

/// The month calendar behind the "Other day" chip.
///
/// `MonthCalendar`, the same component the History grid is built from, rather than the
/// `DatePicker(.graphical)` this shipped with. The system picker was chosen on the grounds that
/// rebuilding a month grid by hand would gain nothing — that was wrong, and three things it gave
/// up are visible on screen. It draws its own header, so the month title, the ‹ › arrows and the
/// wheels behind them look and behave differently here than four taps away on History. It has no
/// way back to the current month once the user has paged away from it. And it resolves its own
/// locale rather than reading the environment, so after a language switch it kept naming its
/// month and its weekday column in whatever language the app launched in — the bug
/// `LanguageController.calendar` exists to fix, reintroduced by a control that does not read it.
///
/// Days only. The hour and minute are the other chip's job, and offering them twice is two
/// controls that can disagree about the same entry — which is also why picking a day keeps the
/// time of day the binding already carried instead of resetting it to midnight.
private struct DayCalendar: View {

    @Binding var date: Date

    /// End of today. Passed in rather than read from the clock here, so the calendar and the
    /// sheet agree on "now" even if the sheet has been open for a while.
    let latest: Date

    /// The app's calendar, which is where the month names, the weekday letters and the first day
    /// of the week come from — see `LanguageController.calendar`.
    @Environment(\.calendar) private var calendar

    /// The month on screen, once the user has moved it. `nil` until then, so the grid opens on
    /// whatever day is selected rather than on a month captured when the sheet was built.
    @State private var browsedMonth: Date?

    private var shownMonth: Date {
        browsedMonth ?? CheckInHistory.startOfMonth(containing: date, calendar: calendar)
    }

    /// The last reachable month: the one holding `latest`. A dose cannot have been taken after
    /// the moment the user is writing it down, so later months are not offered at all.
    private var currentMonth: Date {
        CheckInHistory.startOfMonth(containing: latest, calendar: calendar)
    }

    var body: some View {
        MonthCalendar(grid: CheckInHistory.grid(forMonthContaining: shownMonth,
                                                calendar: calendar),
                      calendar: calendar,
                      currentMonth: currentMonth,
                      move: step,
                      select: jump) { day in
            DayPickerCell(date: day,
                          isSelected: calendar.isDate(day, inSameDayAs: date),
                          isToday: calendar.isDateInToday(day),
                          isReachable: day <= latest,
                          calendar: calendar) {
                pick(day)
            }
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Navigation

    /// The ‹ › arrows. Clamped on the way forward as well as being disabled there, so the two
    /// cannot disagree about which month is last.
    private func step(_ offset: Int) {
        let moved = CheckInHistory.month(offsetBy: offset, from: shownMonth, calendar: calendar)
        browsedMonth = min(moved, currentMonth)
    }

    /// The wheels and "Now". `CheckInHistory.month(_:of:notAfter:)` does the clamping.
    private func jump(month: Int, year: Int) {
        browsedMonth = CheckInHistory.month(month, of: year, notAfter: latest, calendar: calendar)
    }

    // MARK: - Selection

    /// Moves the day and keeps the clock reading.
    ///
    /// The binding carries a whole instant, and only its date components belong to this control:
    /// a dose the user placed at 09:00 stays at 09:00 when they move it to yesterday. Clamped to
    /// `latest` for the one case that can still overshoot — a time of day carried in from
    /// yesterday evening, dropped onto today.
    private func pick(_ day: Date) {
        let clock = calendar.dateComponents([.hour, .minute, .second], from: date)
        var parts = calendar.dateComponents([.year, .month, .day], from: day)
        parts.hour = clock.hour
        parts.minute = clock.minute
        parts.second = clock.second

        guard let picked = calendar.date(from: parts) else { return }

        date = min(picked, latest)
    }
}

/// One day of `DayCalendar`: a button that says whether it is the chosen day, whether it is
/// today, and whether it can be chosen at all.
///
/// Deliberately not `HistoryCalendarCard`'s `DayCell`. That one reports what was recorded on a
/// day and is not tappable; this one is a control. They share the grid, not the cell — see
/// `MonthCalendar`.
private struct DayPickerCell: View {

    let date: Date
    let isSelected: Bool
    let isToday: Bool

    /// `false` for a day after the moment the entry is being written. Drawn dim and refuses the
    /// tap, rather than being blanked: a gap in the grid reads as a calendar fault.
    let isReachable: Bool

    let calendar: Calendar
    let select: () -> Void

    private enum Metrics {
        static let radius: CGFloat = 9
        static let todayRing: CGFloat = 1.5
    }

    /// As `MonthCalendar`: the app's language, carried on the calendar.
    private var locale: Locale { calendar.locale ?? .current }

    var body: some View {
        Button(action: select) {
            Text(verbatim: date.formatted(.dateTime.day().locale(locale)))
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(numeralColour)
                .monospacedDigit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background {
                    RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                        // The same ink a selected chip is filled with, so the chosen day and
                        // the chip that revealed it read as one selection.
                        .fill(isSelected ? Palette.ink : .clear)
                }
                .overlay {
                    // Today's ring, dropped once today *is* the selection — a ring in
                    // `Palette.ink` around a fill in `Palette.ink` is invisible anyway, and
                    // drawing it costs the numeral nothing to leave out.
                    if isToday, !isSelected {
                        RoundedRectangle(cornerRadius: Metrics.radius, style: .continuous)
                            .strokeBorder(Palette.ink, lineWidth: Metrics.todayRing)
                    }
                }
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isReachable)
        .accessibilityLabel(Text(verbatim: date.formatted(
            .dateTime.weekday(.wide).day().month(.wide).locale(locale)
        )))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var numeralColour: Color {
        if isSelected { return Palette.onInk }
        return isReachable ? Palette.heading : Palette.placeholder
    }
}

// MARK: - Previews

#Preview("First run") {
    Color.black.sheet(isPresented: .constant(true)) {
        AddMedicationSheet(history: [], add: { _ in }, chips: InMemoryMedicationChipStore())
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
        AddMedicationSheet(history: history, add: { _ in }, chips: InMemoryMedicationChipStore())
    }
}
