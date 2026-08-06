import Foundation
import HealthKit

/// `HKObserverQuery` + hourly background delivery for the three authorised types.
///
/// This is the second HealthKit boundary next to `HealthKitDataReader`. Sample reads stay
/// on the reader; this type only watches for "something changed" and never looks at
/// values — the recorder re-queries through the reader on each signal.
///
/// ## Battery justification (provisional — unmeasured on device)
///
/// Answers for `.claude/skills/watchos_budget/SKILL.md`. Applies to the **iPhone**
/// target; watchOS does not register this observer (training log lives on phone).
///
/// 1. **What wakes the app, how often?** HealthKit, via background delivery. Frequency
///    request is `.hourly` — at most one wake per type per hour. Three types ⇒ theoretical
///    ceiling 3 wakes/h; coalescing collapses near-simultaneous fires to one ingest.
/// 2. **Work duration?** Unmeasured. Bound: one sample query over
///    `HealthMetricsWindow.backgroundLookback` (48 h) per coalesced wake + SwiftData
///    upsert. No barometer, no network, no display.
/// 3. **What stays powered?** HealthKit query only, for the length of that pull.
/// 4. **If doubled to 2 h?** Sleep and resting heart rate are ~daily; SpO₂ feature
///    lookback is 24 h, so a 2 h delivery still covers it. Hourly keeps a margin for
///    coalesced/missed wakes. Do not go `.immediate`.
/// 5. **If the wake never fires?** Foreground `scenePhase == .active` pull (7 d lookback)
///    remains the backstop. The pipeline already tolerates gaps.
/// 6. **Estimated daily drain?** Unknown until Instruments on device. Kill-switch:
///    `HealthBackgroundDelivery.isEnabled`.
actor HealthKitChangeObserver: HealthChangeObserving {

    private let healthStore: HKHealthStore
    private var queries: [HKObserverQuery] = []
    private var didStart = false

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Same three types as `HealthKitDataReader.readSet` — nothing held "for later".
    private static var observedTypes: [HKSampleType] {
        [
            HKQuantityType(HKQuantityTypeIdentifier.restingHeartRate),
            HKQuantityType(HKQuantityTypeIdentifier.oxygenSaturation),
            HKCategoryType(HKCategoryTypeIdentifier.sleepAnalysis)
        ]
    }

    func start(onChange: @escaping @Sendable () async -> Void) async {
        guard !didStart else { return }
        didStart = true

        guard HKHealthStore.isHealthDataAvailable() else { return }

        for type in Self.observedTypes {
            // `.hourly` is the coarsest cadence that still keeps a 24 h SpO₂ feature
            // window warm. `.immediate` is a battery bug for these types.
            do {
                try await healthStore.enableBackgroundDelivery(for: type, frequency: .hourly)
            } catch {
                // Missing `com.apple.developer.healthkit.background-delivery` entitlement,
                // or the system refused. Observers below still fire while the app is
                // foregrounded; background wakes simply will not happen.
                #if DEBUG
                print("HealthKit background delivery not enabled for \(type): \(error)")
                #endif
            }

            let query = HKObserverQuery(sampleType: type, predicate: nil) { _, completion, error in
                // Always call completion — three missed acknowledgements and HealthKit
                // stops delivering to this app entirely.
                Task {
                    defer { completion() }
                    guard error == nil else { return }
                    await onChange()
                }
            }

            healthStore.execute(query)
            queries.append(query)
        }
    }
}
