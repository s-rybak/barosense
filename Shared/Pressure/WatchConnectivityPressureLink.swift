import Foundation
import WatchConnectivity

/// The only place `WCSession` is touched.
///
/// One type serves both ends of the link: the watch calls `send`, the phone gets
/// `onReceive`. The unused half is inert on each side, which is cheaper to keep honest than
/// two classes that must agree on a wire format.
///
/// ## Why `transferUserInfo`
///
/// The three options are not interchangeable. `sendMessage` needs the counterpart awake and
/// reachable — useless for a background wake on a watch whose phone is in a pocket.
/// `updateApplicationContext` keeps only the *latest* payload, so a queued update is
/// silently overwritten by the next one; for a training log, that is data loss by design.
/// `transferUserInfo` is a FIFO queue the system persists across launches and delivers when
/// it can. That is what a history needs.
///
/// ## Concurrency
///
/// `@unchecked Sendable` and not an actor, because `WCSessionDelegate` requires an
/// `NSObject` subclass. The checker is switched off over a type whose every stored property
/// is a `let` — an immutable reference to a system singleton and a `@Sendable` closure —
/// and `WCSession` is itself safe to use from any thread. There is no mutable state here to
/// race over.
final class WatchConnectivityPressureLink: NSObject, @unchecked Sendable {

    private let session: WCSession

    /// Invoked on WatchConnectivity's own queue, from any thread. The callee decides
    /// isolation — the samples handed over are a `Sendable` value type, so nothing
    /// framework-shaped escapes this file.
    private let onReceive: @Sendable ([PressureSample]) -> Void

    /// Fails when the device cannot pair at all — an iPad, or a Mac running the app. Not an
    /// error worth surfacing: on such a device the phone-side log simply never grows.
    init?(onReceive: @escaping @Sendable ([PressureSample]) -> Void = { _ in }) {
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
    /// Activation must happen before anything is queued *and* before the system can deliver
    /// a transfer that arrived while the app was not running — on the phone that delivery is
    /// the entire point of the link.
    func activate() {
        guard session.activationState != .activated else { return }
        session.activate()
    }
}

// MARK: - Sending

extension WatchConnectivityPressureLink: PressureSampleUplink {

    func send(_ samples: [PressureSample]) {
        guard !samples.isEmpty else { return }
        guard session.activationState == .activated else { return }

        // A payload that will not encode is a bug in the codec, not a transient failure, and
        // retrying it would queue the same broken bytes forever. The rows stay in the
        // sender's own durable log either way, and the next window resends them.
        guard let payload = try? PressureSyncPayload.encode(samples) else { return }

        session.transferUserInfo(payload)
    }
}

// MARK: - Receiving

extension WatchConnectivityPressureLink: WCSessionDelegate {

    func session(_ session: WCSession,
                 activationDidCompleteWith activationState: WCSessionActivationState,
                 error: (any Error)?) {
        // Nothing to do. Queued transfers drain on their own once the state is `.activated`,
        // and a failure here is not actionable from the app: the log keeps accumulating
        // locally and the next launch retries activation.
    }

    func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        // Decoded synchronously, on WatchConnectivity's queue, on purpose: `[String: Any]`
        // is not `Sendable`, so handing the dictionary to a `Task` would be the isolation
        // hole. Only the decoded value type leaves this scope.
        guard let samples = try? PressureSyncPayload.decode(userInfo), !samples.isEmpty else {
            return
        }
        onReceive(samples)
    }

    #if os(iOS)
    /// Required on iOS only, and both are about the *watch* changing underneath us.
    func sessionDidBecomeInactive(_ session: WCSession) {}

    /// The user switched to a different paired watch. Reactivating is what re-points the
    /// session at the new device; without it the phone stops receiving entirely.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }
    #endif
}
