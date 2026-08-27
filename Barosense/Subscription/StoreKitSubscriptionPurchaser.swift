import Foundation
import StoreKit

/// `SubscriptionPurchasing` against the real App Store.
///
/// The whole of this app's StoreKit surface, and deliberately thin: it translates between
/// StoreKit's types and the four value types in `Shared/Subscription/`, and decides nothing.
/// Every rule about what an entitlement *opens* is in `SubscriptionGate`, where a test reaches
/// it without a signed build, a configured App Store Connect product or a sandbox account.
///
/// ## What has to exist outside this file before it can sell anything
///
/// Both identifiers in `SubscriptionPlan` must be created as auto-renewable subscriptions in
/// App Store Connect, in one subscription group, with the seven-day free trial configured as
/// an **introductory offer** on the group. Until then `Product.products(for:)` returns an
/// empty array on every device including the simulator, and the paywall renders its
/// no-offers state. That state is not a bug and must keep working: it is also what a device
/// with no network shows.
///
/// The trial is Apple's to grant, not this app's to assume — `SubscriptionOffer` carries
/// StoreKit's own eligibility answer, because an Apple Account that has subscribed before is
/// not eligible and must not be shown a screen promising a free week it will be charged for.
/// The local `SubscriptionStatus.trialStartedAt` is a *different* thing with the same name: it
/// is the app's own free stretch for a fresh install, granted before any purchase exists and
/// costing nothing.
///
/// **No receipt validation.** `Transaction.currentEntitlements` is already verified by
/// StoreKit — signature checked against Apple's certificate chain, on device — and this app
/// has no server to validate against. `.unverified` is treated as no entitlement rather than
/// trusted, which is the conservative direction: the worst case is a user briefly locked out
/// of a feature they can restore, not a feature given away on a forged transaction.
struct StoreKitSubscriptionPurchaser: SubscriptionPurchasing {

    func offers() async -> [SubscriptionOffer] {
        let identifiers = Set(SubscriptionPlan.allCases.map(\.rawValue))

        let products: [Product]
        do {
            products = try await Product.products(for: identifiers)
        } catch {
            // Ordinary on a build with no signing team and on any device without a network,
            // so this is not an error state — the paywall has a first-class rendering for it.
            BarosenseLog.subscription.info(
                "no products from the App Store: \(String(describing: error), privacy: .public)"
            )
            return []
        }

        var offers: [SubscriptionOffer] = []
        for plan in SubscriptionPlan.inDisplayOrder {
            guard let product = products.first(where: { $0.id == plan.rawValue }) else { continue }

            offers.append(SubscriptionOffer(
                plan: plan,
                // StoreKit's own string: the user's currency, the user's tax, the user's
                // formatting. Never a number this app assembled — see `SubscriptionPlan`.
                displayPrice: product.displayPrice,
                isEligibleForIntroOffer: await product.subscription?.isEligibleForIntroOffer ?? false
            ))
        }
        return offers
    }

    func purchase(_ plan: SubscriptionPlan) async throws -> PurchasedEntitlement? {
        let products = try await Product.products(for: [plan.rawValue])
        guard let product = products.first else { throw SubscriptionError.productUnavailable }

        switch try await product.purchase() {
        case .success(let verification):
            guard let transaction = Self.verified(verification) else {
                throw SubscriptionError.unverifiedTransaction
            }
            // Finishing is what tells the App Store to stop re-delivering this transaction.
            // It has to happen after the entitlement has been read out of it, and it happens
            // whether or not the caller manages to persist that — an unfinished transaction
            // is redelivered on the next launch and reconciled there anyway.
            await transaction.finish()
            return Self.entitlement(from: transaction)

        case .userCancelled, .pending:
            // Both are ordinary. `.pending` is Ask to Buy waiting on a parent, and it resolves
            // through `Transaction.updates` whenever it resolves — there is nothing to report
            // and nothing to wait for.
            return nil

        @unknown default:
            return nil
        }
    }

    func currentEntitlement() async -> PurchasedEntitlement? {
        var newest: PurchasedEntitlement?

        for await result in Transaction.currentEntitlements {
            guard let transaction = Self.verified(result),
                  let entitlement = Self.entitlement(from: transaction)
            else {
                continue
            }
            // Newest expiry wins. An account that has been on both plans has an entitlement
            // for each, and the one that decides whether the app is open is whichever runs
            // longest — not whichever the sequence happened to yield first.
            if entitlement.expiresAt > (newest?.expiresAt ?? .distantPast) {
                newest = entitlement
            }
        }
        return newest
    }

    /// Every transaction the App Store hands over outside a purchase this app ran: renewals,
    /// purchases made on another device, an Ask to Buy a parent approves hours later, refunds.
    ///
    /// Each one is **finished** here. That is not bookkeeping — an unfinished transaction is
    /// redelivered on every launch until somebody closes it out, and `purchase(_:)` only ever
    /// sees the transactions it started itself. Finishing before yielding, because the yield is
    /// what makes the caller re-read entitlements and the entitlement is already in
    /// `Transaction.currentEntitlements` by then; finishing is only the acknowledgement.
    ///
    /// `.unverified` is dropped without being finished, so a transaction that failed
    /// verification is offered again rather than silently discarded for good.
    func transactionUpdates() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await result in Transaction.updates {
                    guard let transaction = Self.verified(result) else { continue }

                    await transaction.finish()
                    continuation.yield(())
                }
                continuation.finish()
            }
            // The stream is held for the lifetime of the app, so this fires only if the holder
            // goes away first — a preview being torn down, or a test.
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func restore() async throws -> PurchasedEntitlement? {
        // Puts an Apple Account sign-in in front of the user, which is why it is only ever
        // called from an explicit "Restore purchases" tap and never on launch.
        try await AppStore.sync()
        return await currentEntitlement()
    }

    /// A live entitlement out of one transaction, or `nil` when it is not one.
    ///
    /// Two rejections, both necessary. A **revoked** transaction is a refund or a family-sharing
    /// withdrawal and entitles nothing regardless of its expiry date. A transaction whose
    /// product is not one of ours — impossible today, possible the day a second product
    /// exists — must not be read as a subscription to this one.
    ///
    /// A missing `expirationDate` is dated from the plan's own period rather than dropped.
    /// StoreKit gives one for every auto-renewable, so this is a sandbox and defensive path:
    /// treating it as no entitlement would lock out a user who has just paid.
    private static func entitlement(from transaction: Transaction) -> PurchasedEntitlement? {
        guard transaction.revocationDate == nil,
              let plan = SubscriptionPlan(rawValue: transaction.productID)
        else {
            return nil
        }

        let expiry = transaction.expirationDate
            ?? transaction.purchaseDate.addingTimeInterval(TimeInterval(plan.periodDays) * 24 * 3600)

        return PurchasedEntitlement(plan: plan, expiresAt: expiry)
    }

    /// Unwraps StoreKit's verification, and drops what fails it.
    ///
    /// `.unverified` is discarded rather than trusted — see the note on the type. It is logged
    /// because it should never happen on a working device and, if it does, the only visible
    /// sign would be a paying user whose app stays locked.
    private static func verified(_ result: VerificationResult<Transaction>) -> Transaction? {
        switch result {
        case .verified(let transaction):
            return transaction
        case .unverified(_, let error):
            BarosenseLog.subscription.error(
                "unverified transaction discarded: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }
}

/// What can go wrong on the way to a purchase, as the paywall is allowed to see it.
///
/// A typed enum per subsystem, like every other error in this project. Neither case is shown
/// to the user in its own words — both resolve to `SubscriptionCopy.purchaseFailed`, because
/// neither has a next step the user could take that "try again" does not already cover.
enum SubscriptionError: Error, Equatable {

    /// The App Store has no product under that identifier: not yet created in App Store
    /// Connect, not available in this storefront, or no network.
    case productUnavailable

    /// A transaction came back that StoreKit could not verify against Apple's signature.
    case unverifiedTransaction
}
