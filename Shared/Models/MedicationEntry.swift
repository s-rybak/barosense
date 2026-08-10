import Foundation

/// One thing the user recorded taking around a check-in: a name, and optionally a dose,
/// both in their own words (Figma `7:330`).
///
/// **Recorded, never interpreted.** The app stores what the user typed and does nothing
/// else with it — no dose checking, no interaction lookup, no suggestion of what to take or
/// when. Anything that reads as guidance here is a claim this app may not make
/// (`.claude/skills/appstore_compliance/SKILL.md`), and the shortest way to keep that true
/// is for the type to have no vocabulary of its own: two strings the user owns.
///
/// `name` and `dose` are unbounded user input and carry the same rule as `CheckIn.note`:
/// never a model feature, never in an outbound payload. That is why this is free text and
/// not a lookup against a shipped list — a list would be a vocabulary the app asserts, and
/// matching against it would be interpretation.
struct MedicationEntry: Identifiable, Hashable, Codable, Sendable {

    /// Stable across a redraw of the form, so a row the user is about to remove is the row
    /// that gets removed. Two entries with the same name are two entries.
    let id: UUID

    /// What the user called it. Never empty — see the initialiser.
    let name: String

    /// What they took, as they wrote it: "400 mg", "two", "half a sachet". A string rather
    /// than a quantity and a unit, because parsing it into a number would be the first step
    /// toward interpreting it, and because the useful answer to "how much" is often not one.
    let dose: String?

    /// `nil` when the name is blank once trimmed — an entry with no name is not an entry,
    /// and rejecting it here means no screen has to remember to check.
    ///
    /// A dose that trims to nothing becomes `nil` rather than `""`, so "the user gave a
    /// dose" stays a meaningful distinction — the same rule `CheckIn.note` follows.
    init?(id: UUID = UUID(), name: String, dose: String? = nil) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty else { return nil }

        let trimmedDose = dose?.trimmingCharacters(in: .whitespacesAndNewlines)

        self.id = id
        self.name = trimmedName
        self.dose = (trimmedDose?.isEmpty ?? true) ? nil : trimmedDose
    }
}
