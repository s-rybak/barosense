import Foundation

/// One barometer reading with the instant it was taken.
///
/// Sensor readings only. WeatherKit forecast pressure is a separate feature family and
/// must never be stored here: once a forecast value can stand in for a missing sensor
/// sample the two are indistinguishable downstream, and "now" stops being ground truth
/// (`.claude/context/ml-spec.md` §2.2).
struct PressureSample: Identifiable, Hashable, Codable, Sendable {

    let id: UUID

    /// When the reading was taken. Sampling is opportunistic and irregular by design, so
    /// nothing downstream may assume a fixed interval between consecutive samples.
    let timestamp: Date

    let pressure: Pressure

    /// The `PressureLocationEpoch` the reading was taken in, when one was known.
    ///
    /// A reference, not a place: the row carries a UUID, and the city / region / country sit
    /// once on the epoch. At ~2 900 rows a month, a place name per row would be a text
    /// movement trail kept for five years to express a fact that changes a few times a year.
    ///
    /// `nil` is ordinary and always readable. Rows written before the epoch table existed
    /// have it, so do rows taken before an install's first fix, and so does every row on a
    /// device where location was refused — the barometer does not depend on it, and nothing
    /// downstream may drop a sample for wanting one.
    let locationEpochID: UUID?

    init(id: UUID = UUID(),
         timestamp: Date,
         pressure: Pressure,
         locationEpochID: UUID? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.pressure = pressure
        self.locationEpochID = locationEpochID
    }

    /// The same reading stamped with the epoch it was taken in.
    ///
    /// The recorder resolves the epoch and writes the row in one step, so this exists for the
    /// path that cannot: a reading taken while the fix was still in flight, which is stamped
    /// when the epoch resolves rather than being written twice or dropped.
    func inLocationEpoch(_ epochID: UUID?) -> PressureSample {
        PressureSample(id: id,
                       timestamp: timestamp,
                       pressure: pressure,
                       locationEpochID: epochID)
    }
}
