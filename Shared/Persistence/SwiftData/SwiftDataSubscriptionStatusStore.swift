import Foundation
import SwiftData

/// Durable row for `SubscriptionStatus`.
///
/// Flat primitives rather than a `Codable` blob, for the reason `StoredUserProfile` gives: a
/// `Codable` property is opaque bytes to SwiftData and cannot be queried or migrated
/// field-by-field. The plan is held by its frozen raw value — which is the App Store product
/// identifier — and an unrecognised one reads back as `nil` rather than trapping, so a row
/// written by a newer build downgrades instead of taking the app with it.
///
/// Not `Sendable`, and it must not become one: `@Model` instances stay inside the store actor
/// and callers get the value type.
@Model
final class StoredSubscription {

    var trialStartedAt: Date?
    /// `SubscriptionPlan.rawValue`.
    var planRawValue: String?
    var purchaseExpiresAt: Date?
    /// Optional like the rest, so a row written before this property existed reads back with
    /// `nil` and `SubscriptionStatus.reconciled(with:asOf:)` starts its grace window then.
    var purchaseConfirmedAt: Date?
    var lastOfferedAt: Date?

    init(status: SubscriptionStatus) {
        apply(status)
    }

    /// Overwrites every field. Unconditional, like the profile's: a subscription that lapsed
    /// has to clear its plan in storage too, or the Settings card keeps printing a plan name
    /// under an expired date.
    func apply(_ status: SubscriptionStatus) {
        trialStartedAt = status.trialStartedAt
        planRawValue = status.plan?.rawValue
        purchaseExpiresAt = status.purchaseExpiresAt
        purchaseConfirmedAt = status.purchaseConfirmedAt
        lastOfferedAt = status.lastOfferedAt
    }

    var status: SubscriptionStatus {
        SubscriptionStatus(trialStartedAt: trialStartedAt,
                           plan: planRawValue.flatMap(SubscriptionPlan.init(rawValue:)),
                           purchaseExpiresAt: purchaseExpiresAt,
                           purchaseConfirmedAt: purchaseConfirmedAt,
                           lastOfferedAt: lastOfferedAt)
    }
}

/// On-disk `SubscriptionStatusStore`.
///
/// A `@ModelActor` for the reason every store here is one: `ModelContext` is not `Sendable`
/// and the project builds with complete strict concurrency, so the actor owns its context and
/// only value types leave.
///
/// It shares the main container with the profile and the check-ins rather than opening one of
/// its own. Nothing here references those tables, so that is not a relationship requirement —
/// it is that a fourth SQLite file for four dates is a fourth thing that can fail to open at
/// launch, and this one failing would lock a paying user out of what they bought.
@ModelActor
actor SwiftDataSubscriptionStatusStore: SubscriptionStatusStore {

    /// The stored status, or an empty one on an install that has never written a row.
    ///
    /// An empty status rather than `nil`: "no row yet" and "trial not started" are the same
    /// fact here, and every caller would otherwise have to collapse them itself.
    func status() throws -> SubscriptionStatus {
        try storedRows().first?.status ?? SubscriptionStatus()
    }

    func save(_ status: SubscriptionStatus) throws {
        let rows = try storedRows()

        if let existing = rows.first {
            existing.apply(status)
            // A duplicate would be a bug rather than a normal state, but crashing on one turns
            // a recoverable bug into a launch failure. Collapse it, as the profile store does.
            for duplicate in rows.dropFirst() {
                modelContext.delete(duplicate)
            }
        } else {
            modelContext.insert(StoredSubscription(status: status))
        }
        try modelContext.save()
    }

    /// Every stored row — normally zero or one. Fetched unfiltered rather than through a
    /// `#Predicate`, for the reason `SwiftDataUserProfileStore` gives: the macro captures a
    /// `KeyPath` into a non-`Sendable` `@Model` type, and there is at most one row to narrow.
    private func storedRows() throws -> [StoredSubscription] {
        try modelContext.fetch(FetchDescriptor<StoredSubscription>())
    }
}
