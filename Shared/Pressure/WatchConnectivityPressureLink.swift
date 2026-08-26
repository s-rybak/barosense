import Foundation
import os
import WatchConnectivity

/// The only place `WCSession` is touched.
///
/// One type serves both ends and both directions of the link, because there is only one
/// session to serve them with: `WCSession.default.delegate` is a single slot, so a second
/// class wanting its own callbacks would silently displace this one. Everything that crosses
/// between the phone and the watch is therefore routed here.
///
/// The unused half is inert on each side — the phone calls `publish` and receives check-ins,
/// the watch calls `transfer` and receives contexts — which is cheaper to keep honest than
/// two classes that must agree on a wire format.
///
/// The name is now narrower than the job: it also carries check-ins, in the other direction.
/// Renaming it is a follow-up rather than part of the change that widened it, so that the
/// diff which added the second direction is readable as the second direction.
///
/// ## Two transports, because there are two requirements
///
/// **Phone → watch, `updateApplicationContext`.** What travels is the current state, for
/// display: only the newest value matters and one superseded before delivery has lost
/// nothing. `sendMessage` needs the counterpart awake and reachable, so a watch raised twenty
/// minutes after the phone sampled would get nothing. `transferUserInfo` would hand the watch
/// a backlog of stale numbers to walk through before reaching the current one.
/// `updateApplicationContext` keeps exactly one slot that the next call overwrites, and it
/// **persists that slot**: a watch app launched cold reads `receivedApplicationContext` and
/// has a number on screen before any delivery happens at all.
///
/// **Watch → phone, `transferUserInfo`.** What travels is a check-in — user-entered data that
/// exists nowhere else, where dropping one drops a training row the user cannot be asked to
/// re-enter. That is the exact opposite requirement, and it is why the two directions use
/// different transports rather than one transport with a flag. See `CheckInTransferLink`.
///
/// Nothing measured on the watch is sent anywhere, because nothing is measured on the watch.
/// The barometer is the phone's (`PressureCollectionController`).
///
/// ## Concurrency
///
/// `@unchecked Sendable` and not an actor, because `WCSessionDelegate` requires an
/// `NSObject` subclass. The checker is switched off over a type whose every stored property
/// is a `let` — an immutable reference to a system singleton, two `@Sendable` closures, and a
/// lock that owns the one piece of mutable state — and `WCSession` is itself safe to use
/// from any thread.
final class WatchConnectivityPressureLink: NSObject, @unchecked Sendable {

    private let session: WCSession

    /// Invoked on WatchConnectivity's own queue, from any thread. The callee decides
    /// isolation — the context handed over is a `Sendable` value type, so nothing
    /// framework-shaped escapes this file.
    private let onReceive: @Sendable (WatchContext) -> Void

    /// The other direction: a check-in the watch queued, arriving on the phone. Same
    /// isolation rule.
    private let onReceiveCheckIn: @Sendable (WatchCheckIn) -> Void

    /// Activation finished — with or without anything to hand over.
    ///
    /// Distinct from `onReceive`, and the distinction is what the watch's loading state is
    /// built on: "a context arrived" and "there was never going to be one" look identical
    /// from `onReceive`, which only fires in the first case. Without this the loading screen
    /// has no event that ends it on a watch whose phone has never published.
    private let onActivated: @Sendable () -> Void

    /// A context `publish` was handed before the session finished activating, flushed by the
    /// activation callback.
    ///
    /// One slot, overwritten, matching the semantics of the transport it is waiting for.
    /// Behind a lock rather than an `actor` because the delegate callbacks run on
    /// WatchConnectivity's queue and this has to be readable from both.
    ///
    /// There is deliberately no equivalent for check-ins. A check-in must not sit in a
    /// single-slot buffer where the next one overwrites it, so `transfer` throws while the
    /// session is still activating and the form tells the user, rather than parking it.
    private let pending = OSAllocatedUnfairLock<WatchContext?>(initialState: nil)

    /// Fails when the device cannot pair at all — an iPad, or a Mac running the app. Not an
    /// error worth surfacing: the phone keeps sampling into its own log, and the only thing
    /// lost is a second screen to read it on.
    init?(onReceive: @escaping @Sendable (WatchContext) -> Void = { _ in },
          onReceiveCheckIn: @escaping @Sendable (WatchCheckIn) -> Void = { _ in },
          onActivated: @escaping @Sendable () -> Void = {}) {
        guard WCSession.isSupported() else { return nil }

        self.session = .default
        self.onReceive = onReceive
        self.onReceiveCheckIn = onReceiveCheckIn
        self.onActivated = onActivated
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
    func lastReceivedContext() -> WatchContext? {
        try? WatchContextPayload.decode(session.receivedApplicationContext)
    }
}

// MARK: - Publishing (phone → watch)

extension WatchConnectivityPressureLink: WatchContextLink {

    func publish(_ context: WatchContext) async {
        // Activation is asynchronous, and the first publish of a launch routinely beats it:
        // the composition root calls `activate()` and starts sampling in the same `init`, and
        // a barometer read finishes in about a second. `updateApplicationContext` on a
        // session that is not activated raises, so the context waits for the callback rather
        // than being dropped.
        guard session.activationState == .activated else {
            pending.withLock { $0 = context }
            return
        }

        write(context)
    }

    /// Every failure here is the same failure from the app's point of view: the watch keeps
    /// showing the previous number until the next reading. Nothing is lost — the reading is
    /// already in the phone's durable log, which is the copy that matters — so this logs and
    /// returns rather than retrying.
    private func write(_ context: WatchContext) {
        do {
            try session.updateApplicationContext(WatchContextPayload.encode(context))
        } catch {
            // Ordinary on an unpaired phone or one whose watch app is not installed, which
            // is why this is `info` and not `error`.
            BarosenseLog.pressure.info(
                "could not publish to the watch: \(String(describing: error), privacy: .public)"
            )
        }
    }
}

// MARK: - Transferring (watch → phone)

extension WatchConnectivityPressureLink: CheckInTransferLink {

    /// Activation is the only precondition, deliberately.
    ///
    /// Not reachability: the queue's whole purpose is to hold items while the phone is out of
    /// range or asleep, and refusing then would fail exactly when the form is most useful — a
    /// walk with the phone left at home.
    func transfer(_ checkIn: WatchCheckIn) throws {
        guard session.activationState == .activated else {
            throw CheckInTransferError.linkUnavailable
        }

        // No completion to await. `transferUserInfo` enqueues synchronously and the system
        // delivers when it can, including after both apps have been terminated; the return
        // value is a handle for cancelling a pending transfer, which nothing here wants.
        session.transferUserInfo(try CheckInTransferPayload.encode(checkIn))
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
        let parked = pending.withLock { slot -> WatchContext? in
            defer { slot = nil }
            return slot
        }
        if let parked {
            write(parked)
        }

        if let restored = lastReceivedContext() {
            onReceive(restored)
        }

        // Last, so an owner that shows a loading state until this fires has already been
        // handed the restored context and swaps straight to the populated screen rather than
        // flashing the empty one in between.
        onActivated()
    }

    func session(_ session: WCSession, didReceiveApplicationContext context: [String: Any]) {
        // Decoded synchronously, on WatchConnectivity's queue, on purpose: `[String: Any]`
        // is not `Sendable`, so handing the dictionary to a `Task` would be the isolation
        // hole. Only the decoded value type leaves this scope.
        let decoded: WatchContext?
        do {
            decoded = try WatchContextPayload.decode(context)
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
        guard let decoded else { return }

        onReceive(decoded)
    }

    /// A check-in the watch queued, arriving on the phone. Decoded on this queue for the same
    /// isolation reason as the context above.
    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        let checkIn: WatchCheckIn?
        do {
            checkIn = try CheckInTransferPayload.decode(userInfo)
        } catch {
            // Worse than a dropped context and logged as such: nothing supersedes a check-in,
            // so this is a report the user made that the phone will never store.
            BarosenseLog.pressure.error(
                "a check-in from the watch failed to decode: \(String(describing: error), privacy: .public)"
            )
            return
        }

        guard let checkIn else { return }

        onReceiveCheckIn(checkIn)
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
