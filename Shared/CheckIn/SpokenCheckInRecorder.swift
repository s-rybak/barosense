import Foundation

/// Writes a check-in that arrived from outside the check-in form — today, the voice
/// shortcuts in `Barosense/Intents/`.
///
/// Lives in `Shared/` and takes a `CheckInStore` and a clock, nothing else. That is what
/// makes the rules below testable from a plain unit test with `InMemoryCheckInStore`: the
/// App Intents types are thin adapters that parse what was said and print what happened,
/// and every decision about *what gets written* is here.
///
/// **Nothing here is inferred.** A spoken check-in carries the number the user said and no
/// more; a spoken medication carries the words they used. Neither path invents an intensity,
/// and that is the single rule this type exists to hold — see `record(_:)`.
struct SpokenCheckInRecorder: Sendable {

    /// What happened to a medication the user spoke.
    enum MedicationOutcome: Hashable, Sendable {

        /// Appended to a check-in the user had already logged. Carries that check-in's
        /// timestamp so the caller can say which one it went on.
        case appended(to: Date)

        /// Nothing recent enough to carry it. The caller has to ask for an intensity — a
        /// `CheckIn` cannot exist without one, and the one number this app must never
        /// make up is the label its model is trained on.
        case needsCheckIn
    }

    let store: any CheckInStore

    /// How far back the check-in a spoken medication is attached to may be.
    ///
    /// Six hours: long enough that "I took an ibuprofen" after a check-in logged over
    /// breakfast lands on that check-in, short enough that it cannot land on yesterday's.
    /// Past it the user is asked for a fresh intensity instead, which costs one spoken
    /// number and keeps the entry attached to how they actually felt when they took it.
    var recentCheckInWindow: TimeInterval = 6 * 60 * 60

    /// Injectable so a test can pin the window's boundaries. The intents pass nothing.
    var now: @Sendable () -> Date = { Date() }

    /// Writes a check-in at the given intensity, optionally carrying medications.
    ///
    /// **No Health stamp.** `CheckIn.health` is left `nil`, which that property documents as
    /// "no stamp was taken" and keeps distinguishable from "looked, found nothing". The form
    /// stamps because it is already running inside an app that holds an open HealthKit stack;
    /// this path runs in a background launch triggered by a voice command, and standing that
    /// stack up there would spend a HealthKit query on every spoken check-in for a field
    /// nothing reads yet. Revisit if and when a feature consumes it.
    @discardableResult
    func record(intensity: CheckInIntensity,
                medications: [MedicationEntry] = []) async throws -> CheckIn {
        let checkIn = CheckIn(timestamp: now(),
                              intensity: intensity,
                              medications: medications)

        try await store.save(checkIn)
        return checkIn
    }

    /// Attaches a medication to the check-in it belongs to, or reports that there is none.
    ///
    /// A `MedicationEntry` has no store of its own — it is carried by a check-in, which is
    /// what the "My medications" screen reads them back out of. So a spoken medication either
    /// joins the check-in the user has just logged or waits for one; it never creates a row
    /// with a made-up intensity, because that row is a training label and a fabricated label
    /// is worse than a missing entry.
    func record(_ medication: MedicationEntry) async throws -> MedicationOutcome {
        let instant = now()

        guard let previous = try await store.mostRecentCheckIn(before: instant),
              instant.timeIntervalSince(previous.timestamp) <= recentCheckInWindow else {
            return .needsCheckIn
        }

        // Rebuilt whole rather than mutated: `CheckIn` is a value with `let` fields, and
        // saving under the same `id` is what makes this an edit instead of a second row —
        // see `CheckInStore.save`. Appended, not merged, for the reason `LogModel` appends:
        // two entries under one name are two entries.
        let updated = CheckIn(id: previous.id,
                              timestamp: previous.timestamp,
                              intensity: previous.intensity,
                              tagIDs: previous.tagIDs,
                              medications: previous.medications + [medication],
                              health: previous.health,
                              note: previous.note)

        try await store.save(updated)
        return .appended(to: previous.timestamp)
    }
}
