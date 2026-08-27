import Foundation
import Observation
import SwiftUI

/// Owns what this install is entitled to: reads it, reconciles it with the App Store, and
/// answers the one question every gated screen asks.
///
/// `@MainActor @Observable` in the app target rather than an actor in `Shared/`, the same
/// shape as `SettingsModel` and for the same reason — it is a view model, every reader of it
/// is a view, and the project's test target reaches the app target so it is still unit
/// testable. The rules it applies are not here: they are `SubscriptionGate` and
/// `SubscriptionStatus`, in `Shared/`, where they are reachable with a synthetic clock and no
/// StoreKit at all.
///
/// ## Two sources, one direction
///
/// The App Store is the authority on a *purchase*; the local row is a cache of its last
/// answer plus the two things the App Store knows nothing about — when this install's free
/// trial began, and when the paywall was last shown. Reconciling is therefore one-way:
/// `purchasing` overwrites the purchase half of the row and never reads it back.
///
/// The cache is what makes the app usable offline. `Transaction.currentEntitlements` needs the
/// network and the user's Apple Account; without a row, an aeroplane would lock a paying user
/// out of the report they are on the plane to write.
@MainActor
@Observable
final class SubscriptionController {

    /// What the app currently believes. Written only by `load`, `reconcile` and the two
    /// purchase paths, and persisted on every write.
    private(set) var status = SubscriptionStatus()

    /// The plans the App Store will actually sell, loaded when a paywall first appears.
    ///
    /// Empty until then, and empty afterwards on any build where StoreKit has nothing —
    /// a state the paywall renders rather than assumes away. See `StoreKitSubscriptionPurchaser`.
    private(set) var offers: [SubscriptionOffer] = []

    private(set) var isLoadingOffers = false

    /// True while an App Store sheet is up or a restore is in flight. The paywall's actions
    /// are disabled behind it, so a second tap cannot start a second purchase.
    private(set) var isPurchasing = false

    /// What to tell the user about the last purchase or restore, if anything.
    var failure: SubscriptionFailure?

    private let store: any SubscriptionStatusStore
    private let purchasing: any SubscriptionPurchasing
    private let now: @Sendable () -> Date

    /// The `transactionUpdates()` loop. Held so a second `observeTransactions()` cannot start
    /// a second one; never cancelled, because it is meant to outlive every screen.
    private var updates: Task<Void, Never>?

    init(store: any SubscriptionStatusStore,
         purchasing: any SubscriptionPurchasing = NoOpSubscriptionPurchaser(),
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.store = store
        self.purchasing = purchasing
        self.now = now
    }

    // MARK: - Reading

    /// Whether `feature` may be drawn.
    ///
    /// Evaluated against the clock at the moment of the call, so a screen built after the
    /// boundary is already locked. A trial that runs out while the app sits open on screen
    /// does **not** re-lock under the user mid-session — the next foreground activation
    /// re-reads and the gate closes then. That is deliberate: pulling a card out from under
    /// someone reading it buys nothing, and the activation is at most minutes away.
    func isUnlocked(_ feature: PremiumFeature) -> Bool {
        SubscriptionGate.isUnlocked(feature, status: status, asOf: now())
    }

    /// Whether the app should raise the paywall by itself right now. See
    /// `SubscriptionGate.shouldOfferPaywall` for the three conditions.
    var shouldOfferPaywall: Bool {
        SubscriptionGate.shouldOfferPaywall(status: status, asOf: now())
    }

    /// Whether the free week has been used up and nothing paid has replaced it.
    ///
    /// Read by the paywall for the line above its title. Asked of the controller rather than
    /// passed in by whoever raised the sheet: it is a fact about the install, true or false
    /// whichever route opened the screen, and threading it through as a second piece of view
    /// state is how the sheet ends up disagreeing with the entitlement it is selling against.
    var hasTrialExpired: Bool { status.hasTrialExpired(asOf: now()) }

    /// When the current entitlement runs out, for the Settings card.
    var activeUntil: Date? { status.activeUntil(asOf: now()) }

    /// Where the current entitlement comes from, or `nil` when there is none.
    var source: SubscriptionStatus.Source? { status.source(asOf: now()) }

    // MARK: - Loading

    /// Reads the stored row, starts the trial if this install has never had one, and asks the
    /// App Store what it says. Safe to call on every launch.
    ///
    /// The trial is started **here** rather than when onboarding finishes, and the difference
    /// matters for one user: the one who quits halfway through onboarding and comes back a
    /// fortnight later. Starting it at first launch means their week ran while they were away;
    /// starting it here, on the first read after the store is open, is the same instant for
    /// everyone who finishes onboarding in one sitting and fairer to everyone who does not.
    func load() async {
        var loaded = (try? await store.status()) ?? SubscriptionStatus()

        if loaded.trialStartedAt == nil {
            loaded.trialStartedAt = now()
            await persist(loaded)
        } else {
            status = loaded
        }

        await reconcile()
    }

    /// Re-reads the App Store's answer and folds it into the stored row.
    ///
    /// Called on every foreground activation and on every `transactionUpdates()` element.
    /// Cheap and silent when nothing has changed: `currentEntitlements` is answered from
    /// StoreKit's on-device cache, and a status equal to the one already held writes nothing.
    ///
    /// **Folded, not overwritten.** An empty answer from StoreKit does not distinguish "this
    /// account holds nothing" from "this account could not be read", and writing it straight
    /// over the row would lock a paying subscriber out the first time their Apple Account was
    /// unreachable — the exact failure the cached row exists to stop. The rule that decides
    /// what an empty answer does to a live purchase is
    /// `SubscriptionStatus.reconciled(with:asOf:)`, in `Shared/`, where a test walks it with a
    /// synthetic clock.
    func reconcile() async {
        let entitlement = await purchasing.currentEntitlement()
        let updated = status.reconciled(with: entitlement, asOf: now())

        guard updated != status else { return }
        await persist(updated)
    }

    /// Watches for transactions the App Store delivers on its own and re-reads after each.
    ///
    /// Started once, at composition, and held for the lifetime of the app. Without it a
    /// renewal, a purchase made on another device, an Ask to Buy approved later and a refund
    /// would all wait for the next foreground activation to be noticed — and, worse, would
    /// never be finished, so the App Store would redeliver them on every launch for ever. See
    /// `SubscriptionPurchasing.transactionUpdates()`.
    ///
    /// Costs nothing while nothing happens: it is suspended on an `AsyncStream` rather than
    /// polling, and a transaction is a rare event.
    func observeTransactions() {
        guard updates == nil else { return }

        updates = Task { [weak self] in
            guard let stream = self?.purchasing.transactionUpdates() else { return }

            for await _ in stream {
                await self?.reconcile()
            }
        }
    }

    /// Loads what can be sold. Called when a paywall appears; re-entrant calls are dropped.
    func loadOffers() async {
        guard !isLoadingOffers else { return }

        isLoadingOffers = true
        offers = await purchasing.offers()
        isLoadingOffers = false
    }

    // MARK: - Buying

    /// Runs the App Store purchase sheet and stores what came back.
    ///
    /// A cancelled purchase is not a failure and says nothing: the user answered the sheet,
    /// and an error message over a decision they made deliberately reads as the app arguing
    /// with them.
    func purchase(_ plan: SubscriptionPlan) async {
        guard !isPurchasing else { return }

        isPurchasing = true
        failure = nil
        defer { isPurchasing = false }

        do {
            guard let entitlement = try await purchasing.purchase(plan) else { return }
            await apply(entitlement)
        } catch {
            failure = .purchaseFailed
        }
    }

    /// Asks the App Store to put a previous purchase back on this device.
    ///
    /// Finding nothing is reported, unlike a cancelled purchase: the user asked a question and
    /// silence is not an answer to it.
    func restore() async {
        guard !isPurchasing else { return }

        isPurchasing = true
        failure = nil
        defer { isPurchasing = false }

        do {
            guard let entitlement = try await purchasing.restore() else {
                failure = .nothingToRestore
                return
            }
            await apply(entitlement)
        } catch {
            failure = .purchaseFailed
        }
    }

    // MARK: - Offer bookkeeping

    /// Stamps that the paywall has now been put in front of the user.
    ///
    /// Called when the app raises it by itself, and **not** when the user opens it from
    /// Settings — the stamp is what spends the one end-of-trial offer, and a user who went
    /// looking for the paywall has not been offered anything.
    func recordPaywallOffered() async {
        var updated = status
        updated.lastOfferedAt = now()
        await persist(updated)
    }

    // MARK: - Writing

    /// Through the same fold as `reconcile`, so the confirmation stamp is written here too —
    /// a purchase is the strongest confirmation there is, and leaving it unstamped would start
    /// the new subscriber's grace window at whatever the previous state held.
    private func apply(_ entitlement: PurchasedEntitlement) async {
        await persist(status.reconciled(with: entitlement, asOf: now()))
    }

    /// Publishes then persists.
    ///
    /// In that order on purpose. The screen the user is looking at is the one that has to
    /// change the instant a purchase lands; a store write that fails must not also mean the
    /// feature they just paid for stays locked for the rest of the session. The row is then
    /// out of step with the app until the next launch, where `reconcile` rebuilds it from the
    /// App Store — which is the authority anyway.
    private func persist(_ updated: SubscriptionStatus) async {
        status = updated
        try? await store.save(updated)
    }
}

/// What to tell the user after a purchase or a restore, when there is anything to tell.
enum SubscriptionFailure: Equatable, Identifiable {

    /// Something between the tap and the App Store went wrong. Nothing was charged.
    case purchaseFailed

    /// The restore ran and this Apple Account has no subscription to put back.
    case nothingToRestore

    var id: Self { self }

    var message: LocalizedStringKey {
        switch self {
        case .purchaseFailed: SubscriptionCopy.purchaseFailed
        case .nothingToRestore: SubscriptionCopy.restoreFoundNothing
        }
    }
}
