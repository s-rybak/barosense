import Foundation
import Observation

/// The watch's side of the pressure link: holds whatever the phone last published.
///
/// The watch is a companion display. It does not read its barometer, does not keep a log,
/// and does not schedule a wake — the phone samples, and this shows the newest of what it
/// took (`PressureCollectionController` in the iOS target has the reasoning).
///
/// ## Battery
///
/// Nothing to budget (`.claude/skills/watchos_budget/SKILL.md`). This type starts no sensor,
/// arms no timer, requests no background refresh and opens no store. It reacts to
/// `WCSession` deliveries the system was going to make anyway, at most one per phone
/// reading, and the transport keeps a single slot rather than a queue — so a watch that was
/// off the wrist for six hours receives one context on its next wake, not twenty-four.
@MainActor
@Observable
final class PressureDisplayController {

    /// What the phone last told us, or `nil` before anything has ever arrived.
    private(set) var snapshot: PressureDisplaySnapshot?

    /// True once the link has been set up, whatever it has or has not delivered. Lets the
    /// view distinguish "still connecting" from "connected and the phone has nothing".
    private(set) var hasStarted = false

    private var link: WatchConnectivityPressureLink?

    /// Activates the WatchConnectivity session. Call once from the composition root.
    ///
    /// Not from a view: a context delivered while the watch app was not running is handed
    /// over shortly after activation, and a session that only activates when a particular
    /// screen appears would sit on it until the user happened to open that screen.
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        // Built here rather than in `init` so the handler can reference a fully initialised
        // `self`. `weak` because the link retains this closure and this object retains the
        // link; both live for the process lifetime, but a cycle that is only harmless by
        // accident is still a cycle.
        link = WatchConnectivityPressureLink { [weak self] snapshot in
            Task { await self?.receive(snapshot) }
        }
        guard let link else {
            BarosenseLog.pressure.error("WatchConnectivity unsupported here, the screen cannot update")
            return
        }
        link.activate()
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    ///
    /// Re-reads the system's stored context rather than waiting for a delivery. Free — no
    /// sensor, no radio, one property read — and it covers the case where the phone
    /// published while this app was suspended.
    func sceneDidBecomeActive() {
        guard let restored = link?.lastReceivedSnapshot() else { return }
        receive(restored)
    }

    /// Keeps the newer reading.
    ///
    /// Deliveries are not ordered against the stored context: `sceneDidBecomeActive` reads
    /// whatever the system kept, which on a slow hand-off can be older than something
    /// already delivered live. Comparing timestamps means the number on screen only ever
    /// moves forward.
    private func receive(_ incoming: PressureDisplaySnapshot) {
        guard let current = snapshot else {
            snapshot = incoming
            return
        }
        guard incoming.sample.timestamp > current.sample.timestamp else { return }
        snapshot = incoming
    }
}
