import Foundation

/// How strongly the user feels what they are logging, on the 1–10 scale the check-in form
/// draws (Figma `7:330`).
///
/// **Higher is worse.** 1 is barely there, 10 is as bad as it gets — the direction the
/// form's green→red track reads left to right, and the *inverse* of a wellbeing score.
/// The type is named for intensity rather than for a score precisely so the direction
/// cannot be assumed from the identifier: a comparison written the wrong way round yields a
/// label that is exactly backwards and still compiles.
///
/// A validating struct rather than a bare `Int`, for the reason a bare `Int` fails: 0 and 11
/// must not be representable. The label threshold and every reported metric assume the
/// closed 1–10 range, and a value outside it would be silently absorbed instead of rejected.
///
/// Raw values are persisted. They are part of the storage format and must not be
/// renumbered.
struct CheckInIntensity: RawRepresentable, Hashable, Codable, Sendable {

    /// The closed range the form draws and the store accepts.
    static let scale = 1...10

    let rawValue: Int

    /// `nil` for anything off the scale.
    ///
    /// This is the read path from storage, where a row written by a build that knew a
    /// different scale has to be rejectable rather than clamped into a neighbouring value:
    /// a fabricated label is worse than a missing one.
    init?(rawValue: Int) {
        guard Self.scale.contains(rawValue) else { return nil }
        self.rawValue = rawValue
    }

    /// Pins a value onto the scale.
    ///
    /// For the two places where an off-scale value is a rounding artefact rather than bad
    /// data: the slider, whose geometry can put a drag a fraction past either end, and
    /// constants written in code.
    init(clamping value: Int) {
        rawValue = min(max(value, Self.scale.lowerBound), Self.scale.upperBound)
    }
}

extension CheckInIntensity: Comparable {
    static func < (lhs: CheckInIntensity, rhs: CheckInIntensity) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

extension CheckInIntensity: CaseIterable {
    static let allCases: [CheckInIntensity] = scale.map(CheckInIntensity.init(clamping:))
}

extension CheckInIntensity {

    /// Where this sits on the scale: 0 at the low end, 1 at the high end.
    ///
    /// The slider's thumb position and the colour ramp are both read from this one value, so
    /// the colour under the thumb and the colour of the resulting dot on the chart cannot
    /// drift apart.
    var normalized: Double {
        let span = Double(Self.scale.upperBound - Self.scale.lowerBound)
        return Double(rawValue - Self.scale.lowerBound) / span
    }

    /// The value at `position` along the scale, 0 to 1. The inverse of `normalized`, rounded
    /// to the nearest point — the slider snaps rather than storing a fraction, because the
    /// label is an ordinal report and a stored 6.37 would imply a precision the user never
    /// expressed.
    init(position: Double) {
        let span = Double(Self.scale.upperBound - Self.scale.lowerBound)
        let clamped = min(max(position, 0), 1)
        self.init(clamping: Self.scale.lowerBound + Int((clamped * span).rounded()))
    }
}

/// One self-reported wellbeing check-in — the unit of user input, and the row the model
/// is trained on.
///
/// A value type on purpose. This is what the feature pipeline consumes, so it has to be
/// constructible in a plain unit test with no store, no container and no device.
/// Persistence maps to and from it (`CheckInStore`) and never hands a storage type back.
struct CheckIn: Identifiable, Hashable, Codable, Sendable {

    /// Stable identity across edits and across the watch→phone transfer, so a check-in
    /// entered on the watch and delivered twice does not become two training rows.
    let id: UUID

    /// When the user reported this, not when it reached storage. Features are computed at
    /// this instant, so the two must not be conflated.
    let timestamp: Date

    /// How intense it was. See `CheckInIntensity` — higher is worse.
    let intensity: CheckInIntensity

    /// Tags the user attached, held by identity rather than by value: the vocabulary is
    /// user-owned and mutable, so renaming a tag must not rewrite the check-ins carrying
    /// it, and its text must not be copied into every row.
    ///
    /// Recorded from v1 but deliberately outside the v1 label — see `WellbeingLabel`.
    /// They exist so "does the pressure signal differ by tag" becomes answerable once
    /// there is enough history, not because anything reads them today.
    let tagIDs: Set<WellbeingTag.ID>

    /// What the user recorded taking around this check-in, in the order they entered it.
    ///
    /// Recorded, never interpreted — see `MedicationEntry`. Outside the v1 label and
    /// outside the feature registry for the same reason `note` is: unbounded user text.
    let medications: [MedicationEntry]

    /// Pulse, blood oxygen and hours of sleep as they stood when this was saved.
    ///
    /// `nil` means no stamp was taken — a row written before check-ins carried one, or by a
    /// client that does not read Health at all. That is a different state from a stamp whose
    /// three fields are empty, which means the app did look and the Health store had nothing.
    /// The two stay distinguishable on purpose: a coverage count over the history that
    /// merged them could not tell "never asked" from "asked, nothing there".
    ///
    /// Recorded, and outside the v1 label for the reason the tags are — it exists so "does
    /// this signal differ when the user slept badly" becomes answerable once there is enough
    /// history, not because anything reads it today. See `CheckInHealthContext` for which of
    /// the three can be recovered from the durable log later and which cannot.
    let health: CheckInHealthContext?

    /// Free-text reflection. Never becomes a feature and never joins an outbound payload:
    /// it is unbounded user text and the only part of a check-in that can contain
    /// anything at all.
    let note: String?

    init(id: UUID = UUID(),
         timestamp: Date,
         intensity: CheckInIntensity,
         tagIDs: Set<WellbeingTag.ID> = [],
         medications: [MedicationEntry] = [],
         health: CheckInHealthContext? = nil,
         note: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.intensity = intensity
        self.tagIDs = tagIDs
        self.medications = medications
        self.health = health
        self.note = note
    }
}
