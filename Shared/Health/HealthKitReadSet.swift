import Foundation
import HealthKit

/// The HealthKit types Barosense reads — the single list.
///
/// Extracted out of `HealthKitDataReader` when a second caller appeared: the Settings
/// toggle has to ask iOS whether the user has been prompted for **all** of them, and a
/// second copy of the list is a copy that drifts. Two lists would make the toggle report
/// on a set the reader no longer queries, which is exactly the failure the
/// consumer-first rule exists to guard against.
///
/// Exactly the three types a shipped feature consumes, and nothing held "for later".
/// Each has a feature row in `.claude/context/ml-spec.md` §2.3. Adding a fourth is a gated
/// change — see `.claude/skills/healthkit_permissions/SKILL.md` — not an edit to this
/// file.
enum HealthKitReadSet {

    /// The HealthKit type behind one metric.
    ///
    /// A `switch` over `HealthMetricKind` rather than a dictionary: a new metric cannot be
    /// added to the app's own vocabulary without the compiler stopping here and asking
    /// which HealthKit type backs it. That is what keeps the authorisation set and the
    /// metrics the app actually consumes from drifting apart.
    static func sampleType(for kind: HealthMetricKind) -> HKSampleType {
        switch kind {
        case .restingHeartRate:
            HKQuantityType(HKQuantityTypeIdentifier.restingHeartRate)
        case .oxygenSaturation:
            HKQuantityType(HKQuantityTypeIdentifier.oxygenSaturation)
        case .asleep:
            HKCategoryType(HKCategoryTypeIdentifier.sleepAnalysis)
        }
    }

    /// Read-only. Nothing in the app writes to HealthKit, so there is no matching share
    /// set and the user is never shown a write toggle they would have to reason about.
    static var objectTypes: Set<HKObjectType> {
        Set(HealthMetricKind.allCases.map { sampleType(for: $0) as HKObjectType })
    }
}
