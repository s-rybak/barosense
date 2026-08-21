import Foundation
import SwiftUI

/// Owns Health ingest: foreground pulls, and (when flagged on) observer-driven background
/// pulls into the durable training log.
///
/// Observers are registered from `start()`, which the composition root calls at launch —
/// not from a view. HealthKit background delivery relaunches the app and expects those
/// queries to already exist.
@MainActor
@Observable
final class HealthIngestController {

    let recorder: HealthSampleRecorder

    private let changeObserver: any HealthChangeObserving
    /// Not private so a test can await the batch it schedules
    /// (`HealthIngestSignalCoalescer.waitForPendingWork`) instead of guessing at a delay.
    let backgroundCoalescer: HealthIngestSignalCoalescer

    /// The recorder's own gate, not a second one. The refusal happens inside
    /// `HealthSampleRecorder`; this reference is what opens and closes it — see
    /// `HealthIngestGate` for why an erase needs one.
    private let gate: HealthIngestGate

    private var didStart = false
    private var foregroundRefreshTask: Task<Void, Never>?

    init(recorder: HealthSampleRecorder,
         changeObserver: any HealthChangeObserving = NoOpHealthChangeObserver()) {
        self.recorder = recorder
        self.changeObserver = changeObserver

        // Read into a local and captured by value, alongside the recorder (a Sendable
        // struct), rather than reached through `self`: `self` is not fully initialised
        // while stored properties are still being set.
        let gate = recorder.gate
        self.gate = gate

        self.backgroundCoalescer = HealthIngestSignalCoalescer {
            // Not the enforcement — `refresh` refuses the write on its own. This is the
            // battery half: a closed gate skips four HealthKit round trips per background
            // wake, which is the only part of an hourly firing that costs anything.
            guard await gate.isOpen else { return }
            _ = try? await recorder.refresh(lookback: .backgroundLookback)
        }
    }

    /// Registers HealthKit observers (if enabled) and runs an initial foreground pull.
    ///
    /// Call once from the composition root. Idempotent. The pull is subject to the gate,
    /// so on a launch that lands in onboarding it writes nothing until `setEnabled(true)`.
    func start() {
        guard !didStart else { return }
        didStart = true

        Task {
            await refreshLog(lookback: .refreshLookback)
            await changeObserver.start { [backgroundCoalescer] in
                await backgroundCoalescer.signal()
            }
        }
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    func sceneDidBecomeActive() {
        foregroundRefreshTask?.cancel()
        foregroundRefreshTask = Task {
            await refreshLog(lookback: .refreshLookback)
        }
    }

    /// Opens or closes ingest.
    ///
    /// Driven by whether the user is past onboarding (`AppRootView`), which covers both
    /// the fresh install and the install that has just been erased — after "delete my
    /// data" the profile is gone, so the app is back in onboarding and stays closed until
    /// the flow is finished again. Getting it from the phase rather than from a flag of
    /// its own is what makes it hold across a relaunch: the profile is on disk, this
    /// object is not.
    ///
    /// The HealthKit observers are deliberately left registered while closed. They are
    /// meant to be registered once at launch
    /// (`.claude/skills/healthkit_permissions/SKILL.md`), and tearing them down and
    /// rebuilding them would churn the app's background-delivery registration for a state
    /// that lasts one pass through onboarding. What changes is that a firing writes
    /// nothing.
    ///
    /// Opening runs a foreground pull, because closing is what suppressed the one
    /// `start()` would otherwise have done.
    func setEnabled(_ isEnabled: Bool) async {
        await gate.setOpen(isEnabled)

        guard isEnabled else {
            foregroundRefreshTask?.cancel()
            foregroundRefreshTask = nil
            return
        }
        sceneDidBecomeActive()
    }

    /// Pulls Health into the durable log. Failures stay silent: denied access and an empty
    /// Health store are indistinguishable, and neither is actionable from a background
    /// refresh of this kind.
    ///
    /// Reads nothing while the gate is closed. The write would be refused by the recorder
    /// either way — this is what keeps a suspended pipeline from querying HealthKit for a
    /// result it is going to drop.
    ///
    /// Asks for nothing. `start()` runs from `App.init`, which is before onboarding has
    /// drawn a frame, so an authorisation request on this path is a Health sheet raised
    /// with nothing on screen to explain what is read or why. The sheet belongs to the step
    /// that describes it (`HealthStep`), to the Settings switch, and to the Now screen's
    /// first load. A read taken before any of those simply comes back empty — the same
    /// shape as a refusal and as an empty Health store, which is what every consumer here
    /// already handles.
    func refreshLog(lookback: HealthMetricsWindow) async {
        guard await gate.isOpen else { return }
        _ = try? await recorder.refresh(lookback: lookback)
    }
}
