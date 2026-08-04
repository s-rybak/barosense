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

    init(id: UUID = UUID(), timestamp: Date, pressure: Pressure) {
        self.id = id
        self.timestamp = timestamp
        self.pressure = pressure
    }
}
