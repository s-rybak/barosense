import SwiftUI

// The check-in sheet (Figma `7:330`) — one check-in: a point on the 1–10 intensity scale,
// whatever tags apply, and whatever the user took.
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
    @State private var isAddingTag = false

    /// Gap between the blocks of the form — 26 pt in the frame, between every pair.
    private static let sectionSpacing: CGFloat = 26

    /// Gap between a section's quiet label and the control under it.
    private static let labelSpacing: CGFloat = 12

    init(checkInStore: any CheckInStore,
         tagStore: any WellbeingTagStore,
         health: any CheckInHealthContextProviding,
         onSaved: @escaping () -> Void) {
        _model = State(initialValue: LogModel(checkInStore: checkInStore,
                                              tagStore: tagStore,
                                              health: health,
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

                // Same handling as the onboarding commit failure, deliberately: it is the
                // same kind of event — a write the screen was asked for did not happen.
                if let failure = model.failure {
                    Text(failure.message)
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.markerWarm)
                }
            }
        }
        .presentationDragIndicator(.visible)
        .task { await model.load() }
        .sheet(isPresented: $isAddingMedication) {
            AddMedicationSheet(history: model.medicationHistory,
                               add: model.add(medication:),
                               chips: model.medicationChips)
        }
        .sheet(isPresented: $isAddingTag) {
            AddTagSheet { name in model.addTag(named: name) }
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

    /// The vocabulary, plus the way to grow it.
    ///
    /// The heading and its "+ Add" are drawn even before the vocabulary is in, and even if it
    /// comes back empty. An empty `FlowLayout` under a bare heading used to read as "you have
    /// no tags" with nothing to do about it; a user who archived everything during onboarding
    /// now has the way back on the same row.
    private var tagsSection: some View {
        VStack(alignment: .leading, spacing: Self.labelSpacing) {
            SectionHeader(title: "What you noticed") { isAddingTag = true }

            if !model.offeredTags.isEmpty {
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
            SectionHeader(title: "Medication taken") { isAddingMedication = true }

            MedicationList(entries: model.medications,
                           remove: model.remove(medication:))
        }
    }
}

// MARK: - Section header

/// A section's label with the "+ Add" that opens its sheet.
///
/// One type for both blocks of the form: the tag row and the medication row make the user the
/// same offer, and two copies of a 44 pt target pulled back out of a baseline-aligned row is
/// exactly the kind of thing that drifts a point at a time.
private struct SectionHeader: View {

    let title: LocalizedStringKey
    let add: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            SectionLabel(title: title)

            Spacer(minLength: 12)

            Button(action: add) {
                Text("+ Add")
                    .font(Typography.tertiaryAction)
                    .foregroundStyle(Palette.markerCool)
                    // Padding rather than a frame: the text is short and the tap target has
                    // to reach 44 pt without pushing the label off its baseline.
                    .padding(.vertical, 12)
                    .padding(.leading, 12)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            // Pulled back out of the layout so the enlarged target does not push the label
            // off the row's baseline.
            .padding(.vertical, -12)
            // "+ Add" beside two different section labels is two identical buttons to
            // VoiceOver; the label says which one this is.
            .accessibilityLabel(Text("Add"))
            .accessibilityHint(Text(title))
        }
    }
}

// MARK: - Section label

/// The quiet noun that names a block of the form. Shared with `AddMedicationSheet`, which is
/// the same form one level down.
struct SectionLabel: View {

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

    /// Which row is swiped open, at most one. Owned here rather than by the row: two rows sitting
    /// open at once reads as the list having lost track of what the user is doing.
    @State private var openRow: MedicationEntry.ID?

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

                    MedicationRow(entry: entry,
                                  isOpen: binding(for: entry.id)) { remove(entry.id) }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(Palette.controlFill))
        // Clipped to the card, not to each row: a swiped row slides its own fill out past the
        // left edge, and a rectangular clip per row would square off the card's corners.
        .clipShape(shape)
        // Drawn after the clip so the outline stays a full 1 pt instead of being halved by it.
        .overlay { shape.strokeBorder(Palette.controlBorder, lineWidth: 1) }
        // A row left open while another entry is added would sit there with its action showing
        // and nothing pointing at it.
        .onChange(of: entries.count) { openRow = nil }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.cornerRadius, style: .continuous)
    }

    private func binding(for id: MedicationEntry.ID) -> Binding<Bool> {
        Binding(get: { openRow == id }, set: { openRow = $0 ? id : nil })
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

/// One recorded entry: a marker, what the user wrote, and a delete revealed by swiping left.
///
/// Carries no surface of its own — `MedicationList` draws the box around every row, so a
/// second entry cannot end up with its own card.
///
/// ## Why the gesture is hand-built
///
/// `.swipeActions` exists and would be the obvious answer, but it is a `List` modifier and this
/// box is a `VStack` inside the scaffold's `ScrollView`. Putting a `List` in there means a
/// scroll view inside a scroll view and a height this box has to be told rather than take from
/// its rows. The gesture below is about thirty lines and does not fight the container.
private struct MedicationRow: View {

    let entry: MedicationEntry

    /// Whether this row is the one showing its action. `MedicationList` owns it, so opening one
    /// row closes any other.
    @Binding var isOpen: Bool

    let remove: () -> Void

    /// Travel of the gesture in progress, on top of wherever the row was resting. Zero between
    /// gestures — the resting position is `isOpen`, not this.
    @State private var drag: CGFloat = 0

    /// The app's language and calendar, which are not `.current` — those are still whatever
    /// the app launched in. See `LanguageController`.
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar

    /// Read by `MedicationList` for its separator inset and its empty row, so the three stay
    /// aligned from one set of numbers.
    enum Metrics {
        static let horizontalPadding: CGFloat = 17
        static let verticalPadding: CGFloat = 13
        static let markerSize: CGFloat = 8
        static let markerSpacing: CGFloat = 12
        /// Width of the revealed action, sized for "Видалити" at 14 pt bold — the longer of the
        /// two shipped languages.
        static let actionWidth: CGFloat = 96
        /// Travel past which letting go leaves the action open instead of snapping shut.
        static let openThreshold: CGFloat = 40
        static let settle = Animation.snappy(duration: 0.22)
    }

    var body: some View {
        ZStack(alignment: .trailing) {
            deleteAction
                // The gesture that reveals this is invisible to VoiceOver, and so is a button
                // sitting under an opaque row. The action below is the route in, not this.
                .accessibilityHidden(true)

            content
                // Opaque, so the red does not read through the row while it is closed.
                .background(Palette.controlFill)
                // `.offset` last, and this is load-bearing rather than tidiness. `.offset`
                // moves what is below it in the chain — rendering and touch together — but it
                // does not change the layout frame, so a `.contentShape(.rect)` applied after
                // it re-draws the hit area over the row's *original* width. That leaves the
                // swiped-open row still catching taps across the button underneath it, and
                // "Delete" silently does nothing. Found on device.
                .contentShape(.rect)
                .gesture(swipe)
                .onTapGesture { close() }
                .offset(x: offset)
        }
        // One element, with the delete in its rotor. Replacing the old "×" with a gesture took
        // away the only control VoiceOver could reach, so this is not a convenience on top of a
        // visible button any more — it is the whole of the affordance.
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: Text("Delete"), remove)
    }

    private var content: some View {
        HStack(spacing: Metrics.markerSpacing) {
            Circle()
                .fill(Palette.markerCool)
                .frame(width: Metrics.markerSize, height: Metrics.markerSize)

            label
                .font(Typography.choiceLabelCompact)
                .foregroundStyle(Palette.heading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, Metrics.horizontalPadding)
        .padding(.vertical, Metrics.verticalPadding)
    }

    /// The panel the row slides off.
    ///
    /// White rather than `Palette.onInk`, measured on `Palette.destructive`: white gives 3.85:1
    /// and `onInk` 3.44:1. At 14 pt bold the label is "large text", where WCAG AA asks 3:1 and
    /// both clear it — white keeps the margin. Neither would reach the 4.5:1 a caption-sized
    /// label needs, which is why the label is 14 pt bold rather than a caption.
    private var deleteAction: some View {
        Button(action: remove) {
            VStack(spacing: 4) {
                Image(systemName: "trash")
                    .font(.system(size: 15, weight: .semibold))

                Text("Delete")
                    .font(.system(size: 14, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(width: Metrics.actionWidth)
            .frame(maxHeight: .infinity)
            .background(Palette.destructive)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    /// Resting position plus the live drag, clamped: the row cannot be pulled further than the
    /// action is wide, and cannot be dragged to the right of where it started.
    private var offset: CGFloat {
        min(0, max(-Metrics.actionWidth, resting + drag))
    }

    private var resting: CGFloat { isOpen ? -Metrics.actionWidth : 0 }

    private var swipe: some Gesture {
        DragGesture(minimumDistance: 14)
            .onChanged { value in
                // Horizontal only. A vertical drag belongs to the scroll view this form sits
                // in, and claiming it would make the sheet unscrollable from a row.
                guard abs(value.translation.width) > abs(value.translation.height) else { return }

                drag = value.translation.width
            }
            .onEnded { value in
                let settled = resting + value.translation.width
                drag = 0

                withAnimation(Metrics.settle) { isOpen = settled < -Metrics.openThreshold }
            }
    }

    /// A tap anywhere on an open row puts it back, which is what the same gesture does in every
    /// system list. On a closed row it does nothing — there is nothing else on the row to hit.
    private func close() {
        guard isOpen else { return }

        withAnimation(Metrics.settle) { isOpen = false }
    }

    /// `verbatim` throughout: the name and the dose are the user's own words, the time is a
    /// clock reading formatted for their locale, and the separator is punctuation rather than
    /// copy.
    ///
    /// The time is always shown, including when it is "now". It is the one field on this row
    /// the user cannot otherwise check after the sheet closes, and an entry filed at the wrong
    /// hour is worth catching before the check-in is saved.
    private var label: Text {
        guard let dose = entry.dose else { return Text(verbatim: "\(entry.name) · \(taken)") }
        return Text(verbatim: "\(entry.name) · \(dose) · \(taken)")
    }

    /// A clock reading on its own for today, and the day in front of it for anything earlier.
    ///
    /// The sheet's "Other day" chip can file a dose on a previous day, and from that point a
    /// bare "09:00" stops identifying a moment — a dose taken this morning and one taken last
    /// Tuesday would draw the identical row. The day is added only when it is not today, so the
    /// ordinary case keeps the short row the frame draws.
    private var taken: String {
        let time = entry.takenAt.formatted(
            Date.FormatStyle(date: .omitted, time: .shortened, locale: locale)
        )
        guard !calendar.isDateInToday(entry.takenAt) else { return time }

        let day = entry.takenAt.formatted(.dateTime.day().month(.abbreviated).locale(locale))
        return "\(day), \(time)"
    }
}

// MARK: - Previews

#Preview("Sheet") {
    Color.black.sheet(isPresented: .constant(true)) {
        LogScreen(checkInStore: InMemoryCheckInStore(),
                  tagStore: InMemoryWellbeingTagStore(WellbeingTag.seeds),
                  health: NoOpCheckInHealthContextProvider(),
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
    // `compactMap` rather than a `!`: `MedicationEntry` is failable by design, and the ban on
    // force unwrapping holds in a preview too — this target is not a test target.
    let now = Date()
    let one = [MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: now)].compactMap { $0 }
    let two = [MedicationEntry(name: "Ibuprofen", dose: "400 mg", takenAt: now),
               MedicationEntry(name: "Magnesium",
                               takenAt: now.addingTimeInterval(-7200))].compactMap { $0 }

    VStack(alignment: .leading, spacing: 20) {
        MedicationList(entries: [], remove: { _ in })

        MedicationList(entries: one, remove: { _ in })

        MedicationList(entries: two, remove: { _ in })
    }
    .padding(24)
    .background(Palette.surface)
}
