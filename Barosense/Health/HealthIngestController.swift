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
    private let backgroundCoalescer: HealthIngestSignalCoalescer

    private var didStart = false
    private var foregroundRefreshTask: Task<Void, Never>?

    init(recorder: HealthSampleRecorder,
         changeObserver: any HealthChangeObserving = NoOpHealthChangeObserver()) {
        self.recorder = recorder
        self.changeObserver = changeObserver

        // Capture the recorder (a Sendable struct) rather than `self`: `self` is not
        // fully initialised while stored properties are still being set.
        self.backgroundCoalescer = HealthIngestSignalCoalescer {
            _ = try? await recorder.refresh(lookback: .backgroundLookback)
        }
    }

    /// Registers HealthKit observers (if enabled) and runs an initial foreground pull.
    ///
    /// Call once from the composition root. Idempotent.
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

    /// Pulls Health into the durable log. Failures stay silent: denied access and an empty
    /// Health store are indistinguishable, and neither is actionable from a background
    /// refresh of this kind.
    ///
    /// Asks for nothing. `start()` runs from `App.init`, which is before onboarding has
    /// drawn a frame, so an authorisation request on this path is a Health sheet raised
    /// with nothing on screen to explain what is read or why. The sheet belongs to the step
    /// that describes it (`HealthStep`), to the Settings switch, and to the Now screen's
    /// first load. A read taken before any of those simply comes back empty — the same
    /// shape as a refusal and as an empty Health store, which is what every consumer here
    /// already handles.
    func refreshLog(lookback: HealthMetricsWindow) async {
        _ = try? await recorder.refresh(lookback: lookback)
    }
}
