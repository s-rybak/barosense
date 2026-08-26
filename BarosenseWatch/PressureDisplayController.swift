import Foundation
import Observation

/// The watch's side of the link: holds whatever the phone last published, and hands the
/// check-in form somewhere to send.
///
/// The watch is a companion. It does not read its barometer, does not keep a log, and does
/// not schedule a wake — the phone samples, and this shows the newest of what it took
/// (`PressureCollectionController` in the iOS target has the reasoning). The one thing the
/// watch originates is a check-in, and that is queued straight to the phone's store rather
/// than kept here (`CheckInTransferLink`).
///
/// ## Battery
///
/// Nothing to budget (`.claude/skills/watchos_budget/SKILL.md`). This type starts no sensor,
/// arms no timer, requests no background refresh and opens no store. It reacts to `WCSession`
/// deliveries the system was going to make anyway, at most one per phone reading, and the
/// transport keeps a single slot rather than a queue — so a watch that was off the wrist for
/// six hours receives one context on its next wake, not twenty-four.
///
/// The context grew a short pressure series and the tag vocabulary in the change that added
/// the chart and the check-in form. Neither adds a wake: they ride the same delivery, and the
/// series is bucketed on the phone precisely so the watch spends no cycles reducing it
/// (`PressureWatchSeries`).
@MainActor
@Observable
final class PressureDisplayController {

    /// What the phone last told us, or `nil` before anything has ever arrived.
    private(set) var context: WatchContext?

    /// True once `start()` has run. Guards against a second activation, nothing more.
    ///
    /// Deliberately **not** what the loading screen keys on: `start()` is called from
    /// `App.init`, so this is already true before the first frame is drawn and a screen
    /// gated on it would never appear. See `hasSettled`.
    private(set) var hasStarted = false

    /// True once the session has finished activating, whether or not it had anything to hand
    /// over — the event `WatchLoadingView` waits for.
    ///
    /// Set from the link's activation callback, and also set when the link could not be built
    /// at all: a watch that cannot pair has settled into "there is nothing coming", which is a
    /// state to show rather than a spinner to leave running.
    private(set) var hasSettled = false

    private var link: WatchConnectivityPressureLink?

    /// The pressure half, which is what most of the UI reads.
    var snapshot: PressureDisplaySnapshot? { context?.pressure }

    /// The chips the check-in form offers. Empty until the phone has published its
    /// vocabulary, which it does once per phone launch.
    var tags: [WatchTag] { context?.tags ?? [] }

    /// Where a saved check-in goes.
    ///
    /// The no-op double rather than an optional, so the form has one code path: the double
    /// throws `linkUnavailable` from `transfer`, and a watch with no usable session reports
    /// that through the form's own failure line instead of through a special case.
    var checkInLink: any CheckInTransferLink { link ?? NoOpCheckInTransferLink() }

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
        link = WatchConnectivityPressureLink(
            onReceive: { [weak self] context in
                Task { await self?.receive(context) }
            },
            onActivated: { [weak self] in
                Task { await self?.settle() }
            }
        )
        guard let link else {
            BarosenseLog.pressure.error("WatchConnectivity unsupported here, the screen cannot update")
            hasSettled = true
            return
        }
        link.activate()
    }

    /// Activation finished. Ends the loading screen whether or not anything arrived with it.
    private func settle() {
        hasSettled = true
    }

    /// Call from the scene-phase observer when the scene becomes `.active`.
    ///
    /// Re-reads the system's stored context rather than waiting for a delivery. Free — no
    /// sensor, no radio, one property read — and it covers the case where the phone
    /// published while this app was suspended.
    func sceneDidBecomeActive() {
        guard let restored = link?.lastReceivedContext() else { return }
        receive(restored)
    }

    /// Merges a delivery into what is on screen, half by half.
    ///
    /// The two halves have different rules because they change for different reasons.
    ///
    /// **Pressure keeps the newer reading.** Deliveries are not ordered against the stored
    /// context: `sceneDidBecomeActive` reads whatever the system kept, which on a slow
    /// hand-off can be older than something already delivered live. Comparing timestamps
    /// means the number on screen only ever moves forward.
    ///
    /// **The vocabulary takes the latest non-empty one.** It carries no timestamp and needs
    /// none — a rename has no ordering to respect beyond "what the phone thinks now". Empty
    /// reads as "not sent" rather than as "the user has no tags", because the phone publishes
    /// its first context before it has opened its tag store and an empty list arriving second
    /// would blank a form that was working.
    private func receive(_ incoming: WatchContext) {
        let pressure = newerPressure(incoming.pressure)
        let tags = incoming.tags.isEmpty ? (context?.tags ?? []) : incoming.tags

        context = WatchContext(pressure: pressure, tags: tags)
    }

    private func newerPressure(_ incoming: PressureDisplaySnapshot?) -> PressureDisplaySnapshot? {
        guard let incoming else { return context?.pressure }
        guard let current = context?.pressure else { return incoming }

        return incoming.sample.timestamp > current.sample.timestamp ? incoming : current
    }
}

#if DEBUG
extension PressureDisplayController {

    /// A controller already holding a context, for previews.
    ///
    /// Here rather than in a preview body because `context` is `private(set)` and the setter
    /// is reachable only from this file. `#if DEBUG` so no preview fixture is compiled into a
    /// shipping build — a screen that can be handed fabricated readings in Release is a
    /// screen that can show one.
    ///
    /// Not a substitute for looking at the app: it feeds the layout, not the link.
    static func previewing(_ context: WatchContext) -> PressureDisplayController {
        let controller = PressureDisplayController()
        controller.context = context
        return controller
    }
}

extension WatchContext {

    /// Six hours of a steady fall, the state the design was drawn against.
    ///
    /// Values are plausible rather than real: a ~5 hPa fall across six hours is an ordinary
    /// front, and it exercises the padded domain with a span wide enough to have a shape and
    /// narrow enough that the padding floor still matters.
    static func previewFalling(asOf now: Date = .now) -> WatchContext {
        let points = (0..<12).map { index in
            PressureTrendPoint(
                timestamp: now.addingTimeInterval(-Double(11 - index) * PressureWatchSeries.bucketSeconds),
                hectopascals: 1016.0 - Double(index) * 0.45 + (index.isMultiple(of: 3) ? 0.6 : -0.3)
            )
        }

        return WatchContext(
            pressure: PressureDisplaySnapshot(
                sample: PressureSample(timestamp: now, pressure: Pressure(hectopascals: 1011.4)),
                trend: .falling,
                recent: points,
                deltaHPaPer3h: -3.2
            ),
            tags: WatchTag.offered(from: WellbeingTag.seeds)
        )
    }
}
#endif
