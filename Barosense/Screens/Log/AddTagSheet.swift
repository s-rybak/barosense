import SwiftUI

// The tag sheet — one word the user adds to their own vocabulary from the check-in form.
//
// Built as a sheet off a "+ Add" on the section header rather than as a chip inline with the
// others, to match `AddMedicationSheet`: the two blocks of the check-in form now offer the same
// affordance in the same place, and "+ Add" already means "a sheet opens" on this screen.
//
// It asks for a name and nothing else. A tag has no second field — a colour or an icon would be
// decoration the model never reads, and the archive control belongs on a screen that lists the
// whole vocabulary rather than on the way into a check-in.

/// Names one new `WellbeingTag` and hands the text to the check-in form.
///
/// What happens to that text — a brand-new tag, or the one the user already has under this name
/// brought back — is `LogModel`'s decision, not this sheet's. The sheet cannot see the archived
/// half of the vocabulary and must not guess at it.
struct AddTagSheet: View {

    let add: (String) -> Void

    @State private var typedName = ""

    @FocusState private var isFocused: Bool
    @Environment(\.dismiss) private var dismiss

    /// The same pair `LogScreen` and `AddMedicationSheet` use, so the three read as one screen.
    private static let sectionSpacing: CGFloat = 24
    private static let labelSpacing: CGFloat = 10

    /// Whitespace-only input is not a name. Also what closes the action, so the button and the
    /// commit cannot disagree about what counts as ready.
    private var trimmedName: String {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        OnboardingStepScaffold(
            completedSteps: nil,
            actionTitle: "Add to check-in",
            isActionEnabled: !trimmedName.isEmpty,
            action: commit
        ) {
            VStack(alignment: .leading, spacing: Self.sectionSpacing) {
                header

                VStack(alignment: .leading, spacing: Self.labelSpacing) {
                    SectionLabel(title: "Tag name")

                    field

                    // States the side effect before it happens: this is not a note on one
                    // check-in, it joins the list every later check-in offers.
                    Text("Kept in your list for next time.")
                        .font(Typography.fieldUnit)
                        .foregroundStyle(Palette.placeholder)
                }
            }
        }
        // `.large` for the reason `AddMedicationSheet` documents: at `.medium` the scaffold's
        // pinned action draws over the content instead of being inset by it. It also lands at
        // the height of the check-in sheet behind it, so moving between the two does not resize
        // the card under the user's thumb.
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
        // The field is the only thing on this sheet, so there is nothing to choose first.
        .onAppear { isFocused = true }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Add tag")
                .font(Typography.onboardingTitleCompact)
                .foregroundStyle(Palette.heading)

            Spacer(minLength: 12)

            closeButton
        }
    }

    /// The same grey disc `AddMedicationSheet` draws, and kept for the same reason: a sheet with
    /// a visible close control is dismissable without knowing that it can be dragged.
    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(Palette.placeholder)
                .frame(width: 30, height: 30)
                .background(Circle().fill(Palette.segmentedTrack))
                // A 44 pt target around a 30 pt disc, pulled back out of the layout so the row
                // keeps the height the medication sheet's header has.
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.vertical, -7)
        .padding(.trailing, -7)
        .accessibilityLabel(Text("Close"))
    }

    private var field: some View {
        FieldSurface {
            TextField("What you noticed", text: $typedName)
                .font(Typography.fieldText)
                .foregroundStyle(Palette.heading)
                .textInputAutocapitalization(.sentences)
                // Off, as on the medication fields: this is one word in the user's own
                // vocabulary, and Ukrainian autocorrect rewrites it while it is still being
                // typed. The inline completion it leaves on screen is marked text that a redraw
                // can drop, which reads as the field losing letters.
                .autocorrectionDisabled()
                // No AutoFill. iOS otherwise offers a contact's name here, which is both the
                // wrong value and an invitation to put a third party's name into a health
                // record on this device.
                .textContentType(nil)
                .focused($isFocused)
                .submitLabel(.done)
                .onSubmit(commit)
        }
        // An empty `TextField` claims only the width its (absent) text needs, so without this a
        // tap on the rest of the box lands on the surface and does not focus the field. Same
        // fix as `AddMedicationSheet.field`, found on device there.
        .contentShape(.rect)
        .onTapGesture { isFocused = true }
    }

    private func commit() {
        guard !trimmedName.isEmpty else { return }

        add(trimmedName)
        dismiss()
    }
}

#Preview {
    Color.black.sheet(isPresented: .constant(true)) {
        AddTagSheet(add: { _ in })
    }
}
