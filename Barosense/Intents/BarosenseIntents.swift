import AppIntents
import Foundation

/// What the voice shortcuts are allowed to reach.
///
/// An App Intent runs inside the app's own process — the system launches the app in the
/// background when it is not already up — so this opens the same store the screens read
/// rather than a private one. See `BarosenseModelContainer.sharedDurable`.
///
/// Deliberately small. The intents get a `SpokenCheckInRecorder` and nothing else: no
/// HealthKit, no barometer, no WeatherKit. A voice command should cost one row on disk, not
/// a cold start of every subsystem the app owns.
@MainActor
enum BarosenseIntentServices {

    static func recorder() throws -> SpokenCheckInRecorder {
        let container = try BarosenseModelContainer.sharedDurable()
        return SpokenCheckInRecorder(store: SwiftDataCheckInStore(modelContainer: container))
    }
}

/// The shortcuts Siri and the Shortcuts app offer without the user building anything.
///
/// Two, and deliberately no more: log a check-in, and write down something taken. Both are
/// things the app already does through a form, reached here in one sentence — which is the
/// whole point, because the moment a check-in is worth recording is rarely a moment anyone
/// wants to open an app.
///
/// Every phrase has to carry `\(.applicationName)`; the system requires it, and it is also
/// what keeps a bare "log a check-in" from being claimed against every app on the device.
///
/// **Phrases are matched in Siri's language, not the app's.** The strings below are English;
/// a device whose Siri speaks Ukrainian needs the same phrases translated in
/// `AppShortcuts.xcstrings` beside them. The app's own Language setting has no bearing on
/// this — it moves `AppleLanguages`, and Siri is not listening to that.
struct BarosenseShortcuts: AppShortcutsProvider {

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LogCheckInIntent(),
            phrases: [
                "Log a check-in in \(.applicationName)",
                "Add a check-in to \(.applicationName)",
                "Check in with \(.applicationName)"
            ],
            shortTitle: "Log a check-in",
            systemImageName: "square.and.pencil"
        )

        AppShortcut(
            intent: LogMedicationIntent(),
            phrases: [
                "Record a medication in \(.applicationName)",
                "Add a medication to \(.applicationName)",
                "Write down what I took in \(.applicationName)"
            ],
            shortTitle: "Record a medication",
            systemImageName: "pills"
        )
    }
}
