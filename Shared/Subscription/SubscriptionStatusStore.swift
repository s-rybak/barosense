import Foundation

/// Storage for the one `SubscriptionStatus`.
///
/// A protocol for the same reason every other store here is one: the gate, the controller and
/// every test depend on this rather than on SwiftData, so the paywall's behaviour is reachable
/// from a plain unit test with a synthetic clock.
///
/// **This is a cache of an App Store fact, not the fact itself.** The authority on whether a
/// subscription is live is `Transaction.currentEntitlements`, which needs the network and the
/// user's Apple Account. The row exists so that an install that is offline, in flight, or
/// launched before StoreKit has answered still knows what it is entitled to instead of
/// locking the user out of something they paid for. The reconcile direction is one-way: the
/// App Store overwrites the row, never the reverse.
protocol SubscriptionStatusStore: Sendable {

    /// The stored status, or `nil` on an install that has never written one.
    func status() async throws -> SubscriptionStatus

    /// Writes the status, replacing whatever was stored.
    func save(_ status: SubscriptionStatus) async throws
}

/// Non-persistent `SubscriptionStatusStore` for previews and unit tests.
final class InMemorySubscriptionStatusStore: SubscriptionStatusStore, @unchecked Sendable {

    private let lock = NSLock()
    private var stored: SubscriptionStatus

    init(_ status: SubscriptionStatus = SubscriptionStatus()) {
        stored = status
    }

    func status() throws -> SubscriptionStatus { lock.withLock { stored } }

    func save(_ status: SubscriptionStatus) throws {
        lock.withLock { stored = status }
    }
}
