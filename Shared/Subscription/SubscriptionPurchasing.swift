import Foundation

/// One purchasable plan as the paywall is allowed to see it.
///
/// `displayPrice` is the App Store's own string — currency, formatting and tax as the user
/// will actually be billed — and never a figure this app formatted. See `SubscriptionPlan`.
struct SubscriptionOffer: Equatable, Sendable, Identifiable {

    let plan: SubscriptionPlan

    /// Already localised and already formatted, by StoreKit. Drawn verbatim.
    let displayPrice: String

    /// Whether this Apple Account may still take an introductory offer on this product.
    ///
    /// Read from StoreKit rather than assumed: the free stretch is granted per *account*, so a
    /// user who has subscribed before is not eligible and must not be shown a screen promising
    /// them a free week they will be charged for.
    let isEligibleForIntroOffer: Bool

    var id: String { plan.rawValue }
}

/// How a purchase actually happens. Everything StoreKit, behind one narrow protocol.
///
/// Declared next to its consumer, like every other boundary in this project, and for the
/// sharpest version of the usual reason: StoreKit cannot be driven from a unit test without a
/// signed build, a configured App Store Connect product and a sandbox account. Behind this
/// protocol the paywall, the gate and the controller are all testable with a double; in front
/// of it there is one adapter that does nothing but translate.
protocol SubscriptionPurchasing: Sendable {

    /// The plans this build can actually sell, in the order given.
    ///
    /// Empty when StoreKit has nothing to offer — no network, products not yet configured in
    /// App Store Connect, or a build with no signing. The paywall has to render that state
    /// rather than assume it cannot happen, because on a development build it is the *usual*
    /// state.
    func offers() async -> [SubscriptionOffer]

    /// Runs the App Store purchase sheet for `plan`.
    ///
    /// Returns the resulting entitlement, or `nil` when the user cancelled or the purchase is
    /// pending parental approval — both are ordinary outcomes, not errors.
    func purchase(_ plan: SubscriptionPlan) async throws -> PurchasedEntitlement?

    /// What the App Store currently says this account is entitled to, or `nil` for nothing.
    ///
    /// This is the authority on a purchase, and it is called at launch, on every foreground
    /// activation, and whenever `transactionUpdates()` reports a change.
    ///
    /// **`nil` is not proof of nothing.** StoreKit has no way to say "I could not ask": an
    /// account that holds no subscription and an account that could not be read — signed out,
    /// a device restored before its transactions have synced, an outage — both come back
    /// empty. So a `nil` here is folded in by `SubscriptionStatus.reconciled(with:asOf:)`
    /// rather than written straight over the stored row, and a still-live cached purchase
    /// survives it for `SubscriptionGrace.duration`.
    func currentEntitlement() async -> PurchasedEntitlement?

    /// Transactions the App Store delivers outside a `purchase(_:)` this app ran, one element
    /// per change, for as long as the stream is held.
    ///
    /// Two jobs, and the app is broken without either. It is where a renewal, a purchase made
    /// on another device, an Ask to Buy approved by a parent hours later, and a refund actually
    /// arrive — foreground activation would otherwise be the only thing that noticed. And it is
    /// where those transactions get **finished**: an unfinished transaction is redelivered by
    /// the App Store on every launch, for ever, and only the code that receives it can close it
    /// out.
    ///
    /// Carries no payload on purpose. Every element means the same thing — ask
    /// `currentEntitlement()` again — and handing the caller one transaction would invite it to
    /// decide entitlement from a single row when the account's entitlement is the whole set.
    func transactionUpdates() -> AsyncStream<Void>

    /// Asks the App Store to restore purchases onto this device.
    ///
    /// Required on any screen that sells a subscription — a user who reinstalls or switches
    /// device must be able to get back what they bought without paying again.
    func restore() async throws -> PurchasedEntitlement?
}

/// A live paid subscription, as the App Store reports it.
struct PurchasedEntitlement: Equatable, Sendable {

    let plan: SubscriptionPlan

    /// When the current period ends. The App Store gives this for auto-renewables; a `nil`
    /// from it is dated by `SubscriptionPlan.periodDays` at the boundary rather than being let
    /// into the domain, so nothing downstream has to handle an entitlement with no end.
    let expiresAt: Date
}

/// Sells nothing. Previews, unit tests, and any build where reaching StoreKit would put a real
/// App Store sheet on screen.
struct NoOpSubscriptionPurchaser: SubscriptionPurchasing {

    /// Optional canned offers, so a preview can draw the populated paywall without StoreKit.
    var stubOffers: [SubscriptionOffer] = []

    func offers() async -> [SubscriptionOffer] { stubOffers }

    func purchase(_ plan: SubscriptionPlan) async throws -> PurchasedEntitlement? { nil }

    func currentEntitlement() async -> PurchasedEntitlement? { nil }

    /// Never yields. Nothing here can produce a transaction, so a stream that finished
    /// immediately would be the same thing with an extra wake-up.
    func transactionUpdates() -> AsyncStream<Void> { AsyncStream { _ in } }

    func restore() async throws -> PurchasedEntitlement? { nil }
}
