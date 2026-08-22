import Foundation

/// Where the health stamp on a check-in comes from.
///
/// A protocol declared next to its consumer, like every other service boundary here: the
/// check-in form has to be exercisable from a plain unit test, and `HealthSampleRecorder`
/// cannot exist without a `HealthDataReader` and a log behind it.
protocol CheckInHealthContextProviding: Sendable {

    /// The stamp for a check-in reported at `now`, or `.empty` when there is nothing to
    /// stamp it with.
    ///
    /// Does not throw, and that is the contract rather than an omission. Every reason this
    /// comes back empty — no Health store on the device, access refused, nothing recorded —
    /// is indistinguishable from the others by design, and none of them is a reason to
    /// refuse to save a check-in the user has already written.
    ///
    /// Implementations must return promptly after task cancellation. The save path has a
    /// deadline and cancels a read that loses it so an abandoned or stalled query does not
    /// continue spending HealthKit work in the background.
    func healthContext(asOf now: Date) async -> CheckInHealthContext
}

extension HealthSampleRecorder: CheckInHealthContextProviding {

    /// Reads the Health store and takes the stamp off what came back.
    ///
    /// The same read the Now screen makes, narrowed to `HealthMetricsWindow.checkInContext`.
    /// What it read is still filed into the training log by `refresh` — a read taken and
    /// thrown away would be the same battery for less history — and that write stays subject
    /// to `HealthIngestGate` like every other.
    ///
    /// Asks for nothing. `authorize()` is deliberately not called here: the Health sheet
    /// belongs to the screens that explain what is read and why — onboarding's `HealthStep`,
    /// the Settings switch, the Now screen's first load — and raising it over a half-written
    /// check-in would be a prompt with no explanation attached
    /// (`.claude/skills/healthkit_permissions/SKILL.md`). A read taken before any of those
    /// simply comes back empty, which is a stamp with nothing in it.
    ///
    /// Cost: 4 HealthKit queries per saved check-in, three of them over 24 h and heart rate
    /// over its own 2 h cap (`HealthMetricKind.readLookbackCap`). At the 2–3 check-ins a day
    /// §4 of `.claude/context/ml-spec.md` plans for, that is ~10 queries a day on top of the
    /// foreground refresh, every one of them inside a screen the user opened themselves.
    /// **No new wake source**: nothing here schedules, observes, or polls.
    func healthContext(asOf now: Date) async -> CheckInHealthContext {
        guard let snapshot = try? await refresh(asOf: now, lookback: .checkInContext) else {
            return .empty
        }

        return CheckInHealthContext(snapshot: snapshot)
    }
}

extension CheckInHealthContext {

    /// The three fields a check-in keeps out of a Now-screen snapshot.
    ///
    /// `restingHeartRateBPM` is deliberately dropped. It is a daily aggregate HealthKit
    /// publishes hours after the day it covers, it is already in the durable log, and the
    /// no-look-ahead rule means a feature has to re-window it from there — a copy stamped at
    /// whatever hour the user happened to check in would summarise a window running past the
    /// check-in's own timestamp.
    init(snapshot: HealthMetricsSnapshot) {
        self.init(heartRateBPM: snapshot.heartRateBPM,
                  oxygenSaturationFraction: snapshot.oxygenSaturationFraction,
                  asleepHours: snapshot.asleepHours)
    }
}

/// A provider that stamps nothing.
///
/// For previews and for any caller with no Health store behind it. Returns the same shape a
/// phone with no watch produces, so a screen built on it exercises the ordinary path rather
/// than a special case.
struct NoOpCheckInHealthContextProvider: CheckInHealthContextProviding {

    func healthContext(asOf now: Date) async -> CheckInHealthContext { .empty }
}
