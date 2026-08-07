import Foundation
import Observation
import WatchKit

/// Owns barometer collection on the watch: when to sample, and what to ship to the phone.
///
/// The watch is the only device that samples. Its readings go into a durable local log
/// *and* onto the uplink; the phone's log is the union of what arrives. Keeping a local copy
/// is what lets a dropped transfer heal — the next hand-off resends an overlapping window
/// rather than leaving a permanent hole in the training history.
///
/// ## Battery justification (provisional — unmeasured on device)
///
/// Answers for `.claude/skills/watchos_budget/SKILL.md`, against the ≤8% daily budget.
///
/// 1. **What wakes the app, how often?** Two things. A `WKApplication` background refresh
///    requested every 60 min — the system decides the real cadence and grants fewer wakes
///    than requested. Plus foreground activation, rate-limited to one reading per 10 min by
///    `PressureSamplingPolicy`. Upper bound on a heavy day: ~24 background + ~30 foreground
///    readings.
/// 2. **Work duration?** Unmeasured. Bound per wake: one `CMAltimeter` start/first-sample/
///    stop (the sensor reports at roughly 1 Hz, so ≈1 s, hard-capped at 5 s by
///    `CoreMotionPressureSource`), one SwiftData upsert, one `transferUserInfo` enqueue.
/// 3. **What stays powered?** The barometer, for that ≈1 s and no longer — `stopRelative
///    AltitudeUpdates` runs on every exit path. No display, no network, no HealthKit, no
///    extended runtime session.
/// 4. **If the interval is doubled?** It breaks a stated requirement rather than costing
///    resolution: `pressureHPa` needs a sample within 90 min of the moment a feature is
///    computed (`.claude/context/ml-spec.md` §2.1), and a 2 h target misses that in the
///    ordinary case. 60 min is already the loosest setting the feature registry allows.
/// 5. **If the wake never fires?** It often will not — background refresh is budgeted and
///    favours apps with a complication on the active face, which this app does not have yet.
///    Foreground activation is the backstop, gaps are expected, and the coverage features
///    exist precisely to tell the model how much of a window was really observed.
/// 6. **Estimated daily drain?** Unknown until Instruments on device. Kill-switch:
///    `PressureSamplingPolicy.isBackgroundRefreshEnabled`.
@MainActor
@Observable
final class PressureCollectionController {

    /// Most recent reading this device took. Drives the watch face of the app itself; the
    /// history lives in the log.
    private(set) var latest: PressureSample?

    /// True once a sampling attempt has finished, whatever the outcome. Lets the view
    /// distinguish "still reading the sensor" from "this device has no barometer".
    private(set) var hasAttemptedSample = false

    private let recorder: PressureSampleRecorder
    private let uplink: any PressureSampleUplink

    private var didStart = false
    private var sampleTask: Task<Void, Never>?

    init(recorder: PressureSampleRecorder, uplink: any PressureSampleUplink) {
        self.recorder = recorder
        self.uplink = uplink
    }

    /// Takes the launch reading and asks for the first background wake.
    ///
    /// Call once from the composition root. Idempotent.
    func start() {
        guard !didStart else { return }
        didStart = true

        sample()
        scheduleNextRefresh()
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    ///
    /// Cheap to call often: the recorder's rate limit decides whether the sensor actually
    /// runs, so a user flipping in and out of the app does not turn into sensor time.
    func sceneDidBecomeActive() {
        sample()
    }

    /// Handles a `WKApplicationRefreshBackgroundTask`.
    ///
    /// Awaits the reading rather than firing and forgetting: the system is holding the app
    /// awake for the duration of this call and suspends it as soon as the task completes, so
    /// a detached task would be killed mid-write. Reschedules before returning — a chain
    /// that forgets to re-arm itself stops after one wake.
    func handleBackgroundRefresh() async {
        await sampleAndShip()
        scheduleNextRefresh()
    }

    // MARK: - Sampling

    private func sample() {
        // One attempt in flight at a time. Two overlapping calls would serialise inside the
        // recorder anyway; cancelling is how the older one stops holding the sensor open.
        sampleTask?.cancel()
        sampleTask = Task { await sampleAndShip() }
    }

    /// Reads the barometer, then hands the recent window to the phone.
    ///
    /// Failures are swallowed. Every reason this can fail — no barometer, Motion & Fitness
    /// denied, the sensor not answering inside the timeout — produces the same outcome from
    /// here: no new row, and a gap the coverage features already account for. There is
    /// nothing the watch UI could usefully say about any of them.
    private func sampleAndShip() async {
        defer { hasAttemptedSample = true }

        guard let sample = try? await recorder.record() else { return }
        latest = sample

        // The whole recent window, not just the new row. `PressureSampleStore` upserts on
        // the identifier the watch generated, so redelivery costs the phone nothing and a
        // transfer the system dropped is picked up by the next hand-off.
        guard let window = try? await recorder.samples(
            trailing: PressureUplinkPolicy.resendWindowSeconds
        ) else { return }

        await uplink.send(window)
    }

    // MARK: - Background refresh

    /// Asks for the next wake, roughly one hour out.
    ///
    /// The date is a preference, not a promise — watchOS budgets these and grants fewer than
    /// requested. Only one request can be outstanding at a time; scheduling replaces the
    /// previous one, which is what makes it safe to call from both `start()` and every wake.
    private func scheduleNextRefresh() {
        guard PressureSamplingPolicy.isBackgroundRefreshEnabled else { return }

        let fireDate = Date.now.addingTimeInterval(PressureSamplingPolicy.backgroundRefreshIntervalSeconds)
        WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: fireDate,
                                                        userInfo: nil) { _ in
            // A scheduling failure leaves the chain broken until the next foreground
            // activation, which re-arms it. Nothing here is worth waking the user for, and
            // the error carries no value the app can act on.
        }
    }
}
