import Foundation
import HealthKit

/// `HealthAccessReporting` on top of `HKHealthStore`.
///
/// One of three places `HKHealthStore` is touched — the other two are
/// `HealthKitDataReader` (samples) and `HealthKitChangeObserver` (background delivery).
///
/// A `struct` for the same reason as the reader: no mutable state, and `HKHealthStore` is
/// itself `Sendable` in the iOS 26 SDK, so there is nothing to serialise access to.
struct HealthKitAccessReporter: HealthAccessReporting {

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Asks iOS whether requesting authorisation for the read set would still put a sheet
    /// on screen.
    ///
    /// `statusForAuthorizationRequest(toShare:read:)` reports on the set **as a whole**:
    /// `.shouldRequest` comes back if even one type has never been presented, which is
    /// what makes it the right question for a single toggle labelled "Apple Health". It
    /// also means the row correctly goes back to "not connected" if a future release adds
    /// a fourth type — the user has genuinely not been asked about all of it.
    ///
    /// It reveals nothing about the answer, which is the whole reason it is safe to branch
    /// on: `.unnecessary` is returned for a user who allowed everything and for one who
    /// refused everything alike.
    ///
    /// A thrown error maps to `.notRequested` rather than to a fourth "unknown" case.
    /// `.unknown` from HealthKit means the query itself failed, and the only useful thing
    /// to offer then is the sheet — which is exactly what `.notRequested` renders.
    func accessState() async -> HealthAccessState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

        do {
            let status = try await healthStore.statusForAuthorizationRequest(
                toShare: [],
                read: HealthKitReadSet.objectTypes
            )
            return status == .unnecessary ? .requested : .notRequested
        } catch {
            return .notRequested
        }
    }

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthDataError.healthDataUnavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: HealthKitReadSet.objectTypes)
    }
}
