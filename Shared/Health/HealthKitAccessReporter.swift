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

    /// Two questions, because iOS answers only the first one.
    ///
    /// 1. Would asking still put a sheet on screen?
    ///    `statusForAuthorizationRequest(toShare:read:)` reports on the set **as a whole**:
    ///    `.shouldRequest` comes back if even one type has never been presented. It reveals
    ///    nothing about the answer — `.unnecessary` is returned for a user who allowed
    ///    everything and for one who refused everything alike — which is exactly why it is
    ///    safe to branch on, and exactly why it is not enough for a switch that claims to
    ///    show granted access.
    ///
    /// 2. What can Barosense actually read? Answered by probing, below.
    ///
    /// A thrown error on the first question maps to `.notRequested`. `.unknown` from
    /// HealthKit means the query itself failed, and the only useful thing to offer then is
    /// the sheet — which is what `.notRequested` renders.
    func accessState() async -> HealthAccessState {
        guard HKHealthStore.isHealthDataAvailable() else { return .unavailable }

        do {
            let status = try await healthStore.statusForAuthorizationRequest(
                toShare: [],
                read: HealthKitReadSet.objectTypes
            )
            guard status == .unnecessary else { return .notRequested }
        } catch {
            return .notRequested
        }

        return .requested(readable: await readableTypes())
    }

    func requestAccess() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthDataError.healthDataUnavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: HealthKitReadSet.objectTypes)
    }

    // MARK: - Probing

    /// The types a read actually returns something for.
    ///
    /// Run in parallel: three independent round trips to the Health daemon, and the screen
    /// waits on all of them. Iterating `allCases` rather than naming the three types keeps
    /// a fourth metric from being silently omitted from the check that drives the switch.
    private func readableTypes() async -> Set<HealthMetricKind> {
        await withTaskGroup(of: (HealthMetricKind, Bool).self) { group in
            for kind in HealthMetricKind.allCases {
                group.addTask { (kind, await self.isReadable(kind)) }
            }

            var readable: Set<HealthMetricKind> = []
            for await (kind, canRead) in group where canRead {
                readable.insert(kind)
            }
            return readable
        }
    }

    /// Whether one sample of this type can be read — the only positive evidence of a read
    /// grant that HealthKit offers.
    ///
    /// Deliberately unbounded in time and capped at one object. Unbounded because a window
    /// would turn "hasn't worn the watch this week" into "no access", and the switch is
    /// about permission, not recency; capped at one because existence is the entire
    /// question, so HealthKit applies the limit in its own query rather than handing over
    /// a history.
    ///
    /// A refusal and an empty Health store both land on `false`. That is a false negative
    /// this API cannot avoid — see `HealthAccessState` — and the caption it drives says
    /// what was observed rather than asserting a denial.
    private func isReadable(_ kind: HealthMetricKind) async -> Bool {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(type: HealthKitReadSet.sampleType(for: kind))],
            sortDescriptors: [],
            limit: 1
        )

        // A throw here is the not-determined path and every transient daemon failure.
        // Both mean "cannot demonstrate access", which is what `false` says.
        let samples = try? await descriptor.result(for: healthStore)
        return samples?.isEmpty == false
    }
}
