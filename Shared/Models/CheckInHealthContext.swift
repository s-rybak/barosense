import Foundation

/// The three body readings as they stood when a check-in was saved.
///
/// A stamp taken off the Health store at the moment the user reported, not something this
/// app measured itself: exactly the three figures the Now screen shows — pulse, blood
/// oxygen, sleep — kept beside what the user said about the same instant.
///
/// Every field is optional and absence is the ordinary case, not a failure. A user with no
/// watch has none of it, blood oxygen depends on the watch model and the region, and a
/// refused read is indistinguishable from an empty Health store
/// (`.claude/skills/healthkit_permissions/SKILL.md`). Nothing here may become a blocking
/// state, an error, or a reason to refuse a check-in the user has written.
///
/// One of the three exists nowhere else. `.heartRate` is read for display and deliberately
/// never logged (`HealthMetricKind.isLoggedForTraining`), so the pulse at a check-in's
/// moment is on this row or is gone. Blood oxygen and sleep *are* in the durable log as
/// well, and a feature computed at `t` re-windows from there rather than reading these: the
/// numbers below were cut to the Now screen's display windows (`HealthMetricsWindow`),
/// which are provisional and are not the windows `.claude/context/ml-spec.md` §2.3 states.
struct CheckInHealthContext: Hashable, Codable, Sendable {

    /// Beats per minute, the newest reading inside `HealthMetricsWindow.heartRate`.
    let heartRateBPM: Double?

    /// Fraction of 0...1 — 0.97, not 97 — newest inside
    /// `HealthMetricsWindow.oxygenSaturation`.
    let oxygenSaturationFraction: Double?

    /// Hours asleep across the trailing day, overlapping intervals counted once.
    let asleepHours: Double?

    /// The app looked and the Health store had nothing to give. Distinct from `nil` on
    /// `CheckIn.health`, which means nothing looked at all.
    static let empty = CheckInHealthContext()

    var isEmpty: Bool {
        heartRateBPM == nil && oxygenSaturationFraction == nil && asleepHours == nil
    }

    /// Drops a value that cannot be a real reading instead of storing it, one field at a
    /// time — the other two are still worth keeping, and nothing on this type is required.
    ///
    /// The bounds are `HealthMetricValue`'s own, reached through it rather than restated:
    /// two copies of a plausibility range is how the read path and the storage path end up
    /// disagreeing about what counts as a reading.
    init(heartRateBPM: Double? = nil,
         oxygenSaturationFraction: Double? = nil,
         asleepHours: Double? = nil) {
        self.heartRateBPM = Self.plausible(heartRateBPM, as: HealthMetricValue.heartRateBPM)
        self.oxygenSaturationFraction = Self.plausible(
            oxygenSaturationFraction,
            as: HealthMetricValue.oxygenSaturationFraction
        )
        // No case to borrow for this one: sleep is stored as intervals and its duration is
        // `end - start`, so a total in hours exists only once they have been unioned. A
        // single interval is already capped at 24 h by `HealthSample.isPlausible`, but the
        // union selects on `end` and an interval may begin before the window opened — two
        // staged nights can therefore add past a day, which is a merge artefact and not a
        // night anybody slept.
        self.asleepHours = asleepHours.flatMap { (0...24).contains($0) ? $0 : nil }
    }

    /// Routed through the initialiser above rather than synthesised, so a value arriving
    /// from storage or from a future watch payload passes the same gate as one read here.
    ///
    /// Absent keys decode as `nil`, which is what lets a payload written before a field
    /// existed still produce a stamp instead of failing the whole check-in.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let heartRate = try container.decodeIfPresent(Double.self, forKey: .heartRateBPM)
        let saturation = try container.decodeIfPresent(Double.self,
                                                       forKey: .oxygenSaturationFraction)
        let asleep = try container.decodeIfPresent(Double.self, forKey: .asleepHours)

        self.init(heartRateBPM: heartRate,
                  oxygenSaturationFraction: saturation,
                  asleepHours: asleep)
    }

    private static func plausible(_ value: Double?,
                                  as metric: (Double) -> HealthMetricValue) -> Double? {
        guard let value, metric(value).isPlausible else { return nil }
        return value
    }
}
