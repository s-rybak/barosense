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

    private var didAuthorize = false
    private var didStart = false
    private var foregroundRefreshTask: Task<Void, Never>?

    init(recorder: HealthSampleRecorder,
         changeObserver: any HealthChangeObserving = NoOpHealthChangeObserver()) {
        self.recorder = recorder
        self.changeObserver = changeObserver

        // Capture the recorder (a Sendable struct) rather than `self`: `self` is not
        // fully initialised while stored properties are still being set. Authorisation
        // on this path is a cheap no-op after the first launch pull in `start()`.
        self.backgroundCoalescer = HealthIngestSignalCoalescer {
            try? await recorder.authorize()
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
    func refreshLog(lookback: HealthMetricsWindow) async {
        if !didAuthorize {
            try? await recorder.authorize()
            didAuthorize = true
        }
        _ = try? await recorder.refresh(lookback: lookback)
    }
}
