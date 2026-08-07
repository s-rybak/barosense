import Foundation
import os
import WatchConnectivity

/// The only place `WCSession` is touched.
///
/// One type serves both ends of the link: the phone calls `publish`, the watch gets
/// `onReceive`. The unused half is inert on each side, which is cheaper to keep honest than
/// two classes that must agree on a wire format.
///
/// ## Why `updateApplicationContext`
///
/// The three options are not interchangeable, and which one is right follows from what is
/// travelling. This link carries **the current reading, for display**. Only the newest value
/// matters; one superseded before delivery has lost nothing.
///
/// `sendMessage` needs the counterpart awake and reachable, so a watch raised twenty minutes
/// after the phone sampled would get nothing. `transferUserInfo` is a FIFO queue that
/// delivers every item — correct for a history, wasteful here, and it would hand the watch a
/// backlog of stale numbers to walk through before reaching the current one.
/// `updateApplicationContext` keeps exactly one slot that the next call overwrites, and the
/// system hands the latest value over when it can. It also **persists that slot**: a watch
/// app launched cold reads `receivedApplicationContext` and has a number on screen before any
/// delivery happens at all.
///
/// This is the direction the link runs. The phone samples; the watch displays. Nothing
/// measured on the watch is sent anywhere, because nothing is measured on the watch.
///
/// ## Concurrency
///
/// `@unchecked Sendable` and not an actor, because `WCSessionDelegate` requires an
/// `NSObject` subclass. The checker is switched off over a type whose every stored property
/// is a `let` — an immutable reference to a system singleton, a `@Sendable` closure, and a
/// lock that owns the one piece of mutable state — and `WCSession` is itself safe to use
/// from any thread.
final class WatchConnectivityPressureLink: NSObject, @unchecked Sendable {

    private let session: WCSession

    /// Invoked on WatchConnectivity's own queue, from any thread. The callee decides
    /// isolation — the snapshot handed over is a `Sendable` value type, so nothing
    /// framework-shaped escapes this file.
    private let onReceive: @Sendable (PressureDisplaySnapshot) -> Void

    /// A snapshot `publish` was handed before the session finished activating, flushed by the
    /// activation callback.
    ///
    /// One slot, overwritten, matching the semantics of the transport it is waiting for.
    /// Behind a lock rather than an `actor` because the delegate callbacks run on
    /// WatchConnectivity's queue and this has to be readable from both.
    private let pending = OSAllocatedUnfairLock<PressureDisplaySnapshot?>(initialState: nil)

    /// Fails when the device cannot pair at all — an iPad, or a Mac running the app. Not an
    /// error worth surfacing: the phone keeps sampling into its own log, and the only thing
    /// lost is a second screen to read it on.
    init?(onReceive: @escaping @Sendable (PressureDisplaySnapshot) -> Void = { _ in }) {
        guard WCSession.isSupported() else { return nil }

        self.session = .default
        self.onReceive = onReceive
        super.init()

        // Delegate before activation: an activation callback with no delegate set is a
        // dropped first delivery.
        session.delegate = self
    }

    /// Activates the session. Call once at launch from the composition root.
    ///
    /// Activation must happen before anything is published *and* before the system can
    /// deliver a context that arrived while the app was not running.
    func activate() {
        guard session.activationState != .activated else { return }
        session.activate()
    }

    /// The last context the system delivered, including one delivered before this launch.
    ///
    /// The watch's cold-start path. `receivedApplicationContext` is kept by the system across
    /// launches, so a watch app opened hours later has the phone's last reading immediately
    /// instead of a dash until the next publish.
    ///
    /// Returns `nil` before activation completes and when nothing has ever been delivered.
    func lastReceivedSnapshot() -> PressureDisplaySnapshot? {
        try? PressureDisplayPayload.decode(session.receivedApplicationContext)
    }
}

// MARK: - Publishing

extension WatchConnectivityPressureLink: PressureDisplayLink {

    func publish(_ snapshot: PressureDisplaySnapshot) async {
        // Activation is asynchronous, and the first publish of a launch routinely beats it:
        // the composition root calls `activate()` and starts sampling in the same `init`, and
        // a barometer read finishes in about a second. `updateApplicationContext` on a
        // session that is not activated raises, so the snapshot waits for the callback rather
        // than being dropped.
        guard session.activationState == .activated else {
            pending.withLock { $0 = snapshot }
            return
        }

        write(snapshot)
    }

    /// Every failure here is the same failure from the app's point of view: the watch keeps
    /// showing the previous number until the next reading. Nothing is lost — the reading is
    /// already in the phone's durable log, which is the copy that matters — so this logs and
    /// returns rather than retrying.
    private func write(_ snapshot: PressureDisplaySnapshot) {
        do {
            try session.updateApplicationContext(PressureDisplayPayload.encode(snapshot))
        } catch {
            // Ordinary on an unpaired phone or one whose watch app is not installed, which
            // is why this is `info` and not `error`.
            BarosenseLog.pressure.info(
                "could not publish to the watch: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

// MARK: - Receiving

extension WatchConnectivityPressureLink: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {
        if let error {
            BarosenseLog.pressure.error(
                "WCSession activation failed: \(String(describing: error), privacy: .public)"
            )
        }
        guard activationState == .activated else { return }

        // Two things become possible at once. Whatever `publish` parked can go out, and on
        // the watch a context delivered before this launch is now readable — that is the
        // cold-start number, and without this the screen holds a dash until the phone
        // happens to sample again.
        let parked = pending.withLock { slot -> PressureDisplaySnapshot? in
            defer { slot = nil }
            return slot
        }
        if let parked {
            write(parked)
        }

        if let restored = lastReceivedSnapshot() {
            onReceive(restored)
        }
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        // Decoded synchronously, on WatchConnectivity's queue, on purpose: `[String: Any]`
        // is not `Sendable`, so handing the dictionary to a `Task` would be the isolation
        // hole. Only the decoded value type leaves this scope.
        let snapshot: PressureDisplaySnapshot?
        do {
            snapshot = try PressureDisplayPayload.decode(context)
        } catch {
            // Version skew or a corrupt transfer, and the one case here worth an error: it
            // means the watch is going to keep showing a number that has stopped updating.
            BarosenseLog.pressure.error(
                "a delivered context failed to decode: \(String(describing: error), privacy: .public)"
            )
            return
        }

        // Not ours — the session is shared, and a context belonging to some other feature
        // lands here too.
        guard let snapshot else { return }

        onReceive(snapshot)
    }

    #if os(iOS)
    /// Required on iOS only, and both are about the *watch* changing underneath us.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to a different paired watch. Reactivating is what re-points the
    /// session at the new device; without it the new watch never receives anything.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
