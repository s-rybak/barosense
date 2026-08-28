import AppIntents
import Foundation

/// "Hey Siri, log a check-in in Barosense" — one number, one row.
///
/// The spoken counterpart of the check-in sheet's intensity track, and deliberately only
/// that: no tags, no note. Those are choices from a list, and reading a vocabulary out loud
/// for the user to pick from turns a five-second command into a conversation. They stay on
/// the form, where the whole vocabulary is visible at once.
///
/// Runs without opening the app (`openAppWhenRun` is false by default), because the value
/// here is not having to.
struct LogCheckInIntent: AppIntent {

    static let title: LocalizedStringResource = "Log a check-in"

    static let description = IntentDescription(
        """
        Records how you feel right now on the same 1–10 scale as the check-in form, \
        where 1 is barely there and 10 is as bad as it gets.
        """,
        categoryName: "Check in"
    )

    /// Plain `Int` rather than the domain type: App Intents resolves the spoken number
    /// against a standard type, and `CheckInIntensity` is what decides whether the number
    /// is on the scale — see `perform()`. One validator, and it is the one the form uses.
    @Parameter(title: "Intensity",
               description: "1 is barely there, 10 is as bad as it gets.",
               requestValueDialog: "How would you rate it, from 1 to 10?")
    var intensity: Int

    static var parameterSummary: some ParameterSummary {
        Summary("Log a check-in at \(\.$intensity)")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        // Rejected rather than clamped. "Log a check-in at 50" is a misheard number, and a
        // 10 written for it would be a training label the user never gave.
        guard let value = CheckInIntensity(rawValue: intensity) else {
            throw $intensity.needsValueError("The scale runs from 1 to 10. Which is it?")
        }

        let recorder = try await BarosenseIntentServices.recorder()
        try await recorder.record(intensity: value)

        return .result(dialog: "Logged \(intensity) out of 10.")
    }
}
