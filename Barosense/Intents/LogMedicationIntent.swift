import AppIntents
import Foundation

/// "Hey Siri, record a medication in Barosense" — a name, optionally a dose.
///
/// **Recorded, never interpreted**, exactly as `MedicationEntry` requires: the words the user
/// said are stored and nothing is done with them. Nothing checks a dose, nothing looks up an
/// interaction, and Siri is never told what to take or when.
///
/// A medication has no row of its own — it is carried by a check-in — so this either joins
/// the check-in the user has already logged today or asks for the one number it needs to make
/// one. See `SpokenCheckInRecorder.record(_:)` for why it does not invent that number.
struct LogMedicationIntent: AppIntent {

    static let title: LocalizedStringResource = "Record a medication"

    static let description = IntentDescription(
        """
        Writes down something you took, in your own words, alongside your check-ins. \
        Barosense records it and nothing more.
        """,
        categoryName: "Check in"
    )

    @Parameter(title: "Name",
               description: "What you call it.",
               requestValueDialog: "What did you take?")
    var name: String

    @Parameter(title: "Dose", description: "In your own words — \"400 mg\", \"two\".")
    var dose: String?

    /// Only used when there is no recent check-in to attach the entry to, which is why it is
    /// optional and asked for from `perform()` rather than up front: on the common path the
    /// user has already logged how they feel and is not asked again.
    ///
    /// The description says so, because this parameter is visible in the Shortcuts editor and
    /// a value set there is silently unused whenever a recent check-in exists — which looks
    /// like a dropped input rather than the design.
    @Parameter(title: "Intensity",
               description: "Only used when there is no recent check-in to add this to. 1 is barely there, 10 is as bad as it gets.")
    var intensity: Int?

    static var parameterSummary: some ParameterSummary {
        Summary("Record \(\.$name)") {
            \.$dose
            \.$intensity
        }
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // `MedicationEntry` rejects a blank name, which is the same guard the sheet relies
        // on. A misheard empty string becomes a re-ask rather than a nameless row.
        guard let entry = MedicationEntry(name: name, dose: dose, takenAt: Date()) else {
            throw $name.needsValueError("What did you take?")
        }

        let recorder = try await BarosenseIntentServices.recorder()

        switch try await recorder.record(entry) {
        case .appended:
            return .result(dialog: "Added \(entry.name) to your last check-in.")

        case .needsCheckIn:
            guard let intensity, let value = CheckInIntensity(rawValue: intensity) else {
                throw $intensity.needsValueError(
                    "There's no recent check-in to add that to. How would you rate it, from 1 to 10?"
                )
            }

            try await recorder.record(intensity: value, medications: [entry])
            return .result(dialog: "Logged \(intensity) out of 10, with \(entry.name).")
        }
    }
}
