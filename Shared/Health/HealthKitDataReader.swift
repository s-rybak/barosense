import Foundation
import HealthKit

/// One of two places `HKHealthStore` is touched (the other is `HealthKitChangeObserver`).
///
/// Everything below the `HealthDataReader` protocol is HealthKit-shaped; everything above
/// it is `HealthSample`. Units are converted here and only here, the way kPa is converted
/// at the barometer boundary, so no HealthKit unit can reach the model.
///
/// A `struct` rather than an actor: it holds no mutable state, and `HKHealthStore` is
/// itself `Sendable` (`NS_SWIFT_SENDABLE` in the iOS 26 SDK), so there is nothing here to
/// serialise access to.
struct HealthKitDataReader: HealthDataReader {

    private let healthStore: HKHealthStore

    init(healthStore: HKHealthStore = HKHealthStore()) {
        self.healthStore = healthStore
    }

    /// Exactly the three types a shipped feature reads, and nothing held "for later".
    ///
    /// Each one has a consumer on screen today and a feature row in
    /// `.claude/context/ml-spec.md` §2.3. Adding a fourth is a gated change, not an edit
    /// to this array — see `.claude/skills/healthkit_permissions/SKILL.md`.
    private static var readSet: Set<HKObjectType> {
        [
            HKQuantityType(HKQuantityTypeIdentifier.restingHeartRate),
            HKQuantityType(HKQuantityTypeIdentifier.oxygenSaturation),
            HKCategoryType(HKCategoryTypeIdentifier.sleepAnalysis)
        ]
    }

    /// Read-only. The app asks for nothing it can write, so `toShare` stays empty and the
    /// user is never shown a write toggle they would have to reason about.
    func requestAuthorization() async throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthDataError.healthDataUnavailable
        }
        try await healthStore.requestAuthorization(toShare: [], read: Self.readSet)
    }

    func samples(of kind: HealthMetricKind, in range: Range<Date>) async throws -> [HealthSample] {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthDataError.healthDataUnavailable
        }

        // `.strictEndDate` keeps HealthKit from handing back a long interval that merely
        // overlaps the window. The exact half-open bound is still applied in Swift below:
        // how the framework predicate handles its own endpoints is not something to
        // depend on for a contract that says "lowerBound in, upperBound out".
        let predicate = HKQuery.predicateForSamples(withStart: range.lowerBound,
                                                    end: range.upperBound,
                                                    options: [.strictEndDate])

        switch kind {
        case .restingHeartRate:
            let unit = HKUnit.count().unitDivided(by: .minute())
            return try await quantitySamples(HKQuantityType(HKQuantityTypeIdentifier.restingHeartRate),
                                             predicate: predicate,
                                             in: range) { quantity in
                .restingHeartRateBPM(quantity.doubleValue(for: unit))
            }

        case .oxygenSaturation:
            // `HKUnit.percent()` yields the 0...1 fraction, which is what the feature
            // registry stores. The screen is the only place it becomes "97%".
            return try await quantitySamples(HKQuantityType(HKQuantityTypeIdentifier.oxygenSaturation),
                                             predicate: predicate,
                                             in: range) { quantity in
                .oxygenSaturationFraction(quantity.doubleValue(for: HKUnit.percent()))
            }

        case .asleep:
            return try await asleepSamples(predicate: predicate, in: range)
        }
    }

    // MARK: - Queries

    /// Unsorted and uncapped, with the ordering applied in Swift on the way out.
    ///
    /// A `limit` would need HealthKit to sort first, and the sorted overload wants a
    /// `Sendable` key path that is awkward to express for these descriptors. Taking the
    /// whole window instead is the cheaper trade: a cap applied to an unspecified order
    /// could drop the newest reading, which is the one the screen is about to show. The
    /// window bounds the cost on its own — a week holds roughly 7 resting heart rates, a
    /// few hundred blood-oxygen readings and a few hundred staged sleep intervals, so
    /// well under a thousand objects per refresh.
    private func quantitySamples(_ type: HKQuantityType,
                                 predicate: NSPredicate,
                                 in range: Range<Date>,
                                 value: (HKQuantity) -> HealthMetricValue) async throws -> [HealthSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.quantitySample(type: type, predicate: predicate)],
            sortDescriptors: []
        )

        let samples = try await descriptor.result(for: healthStore).map {
            HealthSample(id: $0.uuid, start: $0.startDate, end: $0.endDate, value: value($0.quantity))
        }
        return usable(samples, in: range)
    }

    /// Only the stages that mean the user was actually asleep.
    ///
    /// `.inBed` is not sleep — it is the window the watch was watching — and folding it in
    /// would inflate every night by the time spent reading. `.awake` segments are dropped
    /// here too: nothing consumes them yet, and the feature registry marks the two
    /// features that would (`sleepAwakeningCount`, and the awake side of `hoursSinceWake`)
    /// as not computed.
    private func asleepSamples(predicate: NSPredicate,
                               in range: Range<Date>) async throws -> [HealthSample] {
        let asleepValues: Set<Int> = [
            HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue,
            HKCategoryValueSleepAnalysis.asleepCore.rawValue,
            HKCategoryValueSleepAnalysis.asleepDeep.rawValue,
            HKCategoryValueSleepAnalysis.asleepREM.rawValue
        ]

        let descriptor = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: HKCategoryType(HKCategoryTypeIdentifier.sleepAnalysis),
                                         predicate: predicate)],
            sortDescriptors: []
        )

        let samples = try await descriptor.result(for: healthStore)
            .filter { asleepValues.contains($0.value) }
            .map { HealthSample(id: $0.uuid, start: $0.startDate, end: $0.endDate, value: .asleep) }

        return usable(samples, in: range)
    }

    /// The half-open window and the plausibility gate, applied once for every kind.
    ///
    /// A reading that fails the gate is dropped rather than clamped: a value outside the
    /// range means the unit or the row is wrong, and a clamped wrong value is a wrong
    /// value the model cannot tell apart from a real one.
    private func usable(_ samples: [HealthSample], in range: Range<Date>) -> [HealthSample] {
        samples
            .filter { range.contains($0.end) && $0.isPlausible }
            .sorted { $0.end < $1.end }
    }
}
