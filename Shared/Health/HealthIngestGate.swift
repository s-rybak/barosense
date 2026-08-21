import Foundation

/// Whether Health ingest may write to the durable training log right now.
///
/// Exists because "delete my data" and the ingest pipeline are otherwise unaware of each
/// other. `BarosenseDataEraser` empties the log; nothing told the HealthKit observers, so
/// the next firing — or the next foreground activation, which pulls
/// `HealthMetricsWindow.refreshLookback` — put the same week of readings straight back.
/// The erase alert promised they were gone, and minutes later they were not.
///
/// Lives on `HealthSampleRecorder` — the type that performs the write — and is opened and
/// closed through `HealthIngestController`. Not a flag on the controller: the Now screen
/// refreshes through the same recorder without going through the controller at all, so a
/// check that only the controller performed would leave a write path uncovered.
///
/// An `actor` rather than a `Bool` because of where it is read from: the recorder is a
/// `Sendable` struct with nowhere to keep mutable state, and the background coalescer's
/// work closure runs on an arbitrary executor.
///
/// Closed on creation. The app opens it once it knows onboarding is behind the user —
/// which is also what makes the suspension survive a relaunch, since that fact lives in
/// the profile on disk rather than in this object.
actor HealthIngestGate {

    private(set) var isOpen: Bool

    init(isOpen: Bool = false) {
        self.isOpen = isOpen
    }

    func setOpen(_ isOpen: Bool) {
        self.isOpen = isOpen
    }
}
