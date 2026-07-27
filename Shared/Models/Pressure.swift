import Foundation

/// Barometric pressure in hectopascals (hPa), the unit used in meteorology.
///
/// `CMAltitudeData.pressure` is reported in **kilopascals**, while WeatherKit and every
/// weather source report hPa/mbar. Mixing the two silently produces a 10x error that no
/// compiler catches, so all pressure crossing a module boundary is carried in this type
/// rather than as a bare `Double`.
struct Pressure: Hashable, Codable, Sendable {

    /// Value in hectopascals. Typical sea-level range: ~950–1050 hPa.
    let hectopascals: Double

    init(hectopascals: Double) {
        self.hectopascals = hectopascals
    }

    /// Builds a `Pressure` from a CoreMotion reading, which is expressed in kPa.
    init(kilopascals: Double) {
        self.hectopascals = kilopascals * 10
    }

    var kilopascals: Double { hectopascals / 10 }

    /// Plausibility gate for a raw sensor reading.
    ///
    /// Values outside this range mean a unit mix-up or a bad sample, not weather —
    /// they must never reach the model.
    var isPlausible: Bool { (800...1100).contains(hectopascals) }
}

extension Pressure {
    /// Change from an earlier reading, in hPa. Negative means falling pressure.
    func delta(from earlier: Pressure) -> Double {
        hectopascals - earlier.hectopascals
    }
}
