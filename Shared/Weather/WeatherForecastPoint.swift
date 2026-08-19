import Foundation

/// One hour of a weather forecast, as Barosense stores it.
///
/// ## The two dates are the whole design
///
/// `issuedAt` is **when Barosense learned this**, and `validAt` is the hour it describes. Both
/// are stored because a feature computed at `t` may read only what was knowable at `t`
/// (`.claude/context/pressure-forecast-spec.md` §4.5). Overwrite a row with a newer issue and
/// "the forecast for 14:00 last Tuesday" quietly becomes hindsight; a model fitted on that
/// validates beautifully and falls apart in production, which is the random-split failure
/// wearing a different coat.
///
/// So rows are **append-only per issue**. Two issues covering the same hour are two rows, and
/// the reader picks by `issuedAt`.
///
/// ## The pressure here is not the pressure the barometer reads
///
/// `meanSeaLevelPressureHPa` is exactly what the name says. Apple: *"This is a reduced
/// pressure calculated by using observed conditions to remove the effects of elevation from
/// pressure readings."* The phone's barometer reports **station** pressure — what the air
/// actually weighs where the user is — and near Kyiv (≈180 m) the two differ by about
/// **22 hPa**, five to seven times a whole day's weather.
///
/// The field is named for its datum rather than called `pressureHPa` for that reason. A unit
/// is not the ambiguity that bites here; the datum is, and the two are only comparable after
/// `PressureOffsetCalibrator` has measured the difference.
struct WeatherForecastPoint: Hashable, Codable, Sendable {

    /// When this row entered Barosense's knowledge — the instant the request was made, not the
    /// timestamp of the numerical model run behind it.
    ///
    /// Deliberately the later of the two. A model run happens before the app asks for it, and
    /// stamping a row with the run time would let a feature at `t` read a forecast the device
    /// did not yet have. The request instant is exactly when the app knew.
    ///
    /// Historical rows carry `issuedAt == validAt`: an observation was knowable at the moment
    /// it described and at no earlier one. That is what makes bootstrap history safe for
    /// offset calibration and structurally useless as a forward-looking feature — its points
    /// are never in the future of any `t` that can see them.
    let issuedAt: Date

    /// The hour this row describes.
    let validAt: Date

    /// Mean sea level pressure, hectopascals. See the type's note — this is not station
    /// pressure and must never be compared with a `PressureSample` uncalibrated.
    let meanSeaLevelPressureHPa: Double

    /// Air temperature at `validAt`, °C.
    ///
    /// Carried because the offset between station and MSLP depends on it: Apple reduces "by
    /// using observed conditions", which makes ∂ΔP/∂T ≈ −ΔP/T ≈ 0.08 hPa/°C at 180 m. It
    /// arrives in the same response as the pressure and costs no extra request, so storing it
    /// is cheaper than learning to live without it.
    let temperatureC: Double

    init(issuedAt: Date, validAt: Date, meanSeaLevelPressureHPa: Double, temperatureC: Double) {
        self.issuedAt = issuedAt
        self.validAt = validAt
        self.meanSeaLevelPressureHPa = meanSeaLevelPressureHPa
        self.temperatureC = temperatureC
    }

    /// How far ahead this row looked when it was issued. Negative for an observation.
    var leadTimeSeconds: TimeInterval { validAt.timeIntervalSince(issuedAt) }
}

/// One response, as a unit.
///
/// The points of a single request share an `issuedAt` by construction, and carrying them
/// together is what lets a caller say "this whole curve is N hours old" without re-deriving it
/// per row.
struct WeatherForecastIssue: Hashable, Sendable {

    let issuedAt: Date

    /// Ascending by `validAt`. May reach 240 h ahead — WeatherKit's documented horizon.
    let points: [WeatherForecastPoint]

    init(issuedAt: Date, points: [WeatherForecastPoint]) {
        self.issuedAt = issuedAt
        self.points = points.sorted { $0.validAt < $1.validAt }
    }

    /// Age of the issue at `instant`. What the staleness rule is stated against.
    func ageSeconds(at instant: Date) -> TimeInterval { instant.timeIntervalSince(issuedAt) }
}

/// The two unit conversions on the WeatherKit boundary.
///
/// Lifted out of `WeatherKitForecastProvider` so they can be exercised by a test. That client
/// cannot run on this machine at all — WeatherKit does not serve the Simulator — and these two
/// lines are the ones most worth checking: `Measurement<UnitPressure>`'s runtime unit is **not
/// documented**, so reading `.value` directly is a silent 10× error the day WeatherKit hands
/// back kilopascals, and a 10× error in pressure is the exact failure `Pressure` exists to
/// rule out on the sensor side.
enum WeatherMeasurement {

    /// Hectopascals, whatever unit the measurement arrived in.
    static func hectopascals(_ measurement: Measurement<UnitPressure>) -> Double {
        measurement.converted(to: .hectopascals).value
    }

    /// Celsius, whatever unit the measurement arrived in. A Fahrenheit value read as Celsius
    /// would put `PressureOffsetCalibrator`'s temperature correction out by nearly 2×.
    static func celsius(_ measurement: Measurement<UnitTemperature>) -> Double {
        measurement.converted(to: .celsius).value
    }
}

/// Retention and freshness rules for the forecast archive.
///
/// Together in one type because they are read against each other: the staleness norm decides
/// whether an issue may still be used, and the retention horizon decides how long it is kept
/// after that.
enum WeatherForecastPolicy {

    /// Kill switch. `false` stops every request and every write; the archive already on disk
    /// is left alone and the app falls back to its own local model.
    ///
    /// Separate from the user's own switch (`WeatherKitPreferenceStore`) — this one is the
    /// shipped decision, that one is theirs, and both have to say yes.
    static let isEnabled = true

    /// How old an issue may be and still be read.
    ///
    /// **12 hours**, which replaces the ≤3 h the feature registry used to state. That norm was
    /// wrong rather than merely tight: with requests allowed at 08/12/16/20, the newest issue
    /// at 07:00 is eleven hours old, so a 3 h rule was violated about nineteen hours a day —
    /// and violated for no reason, because a curve that reaches 240 h ahead still holds plenty
    /// of valid future hours after eleven of them have passed.
    ///
    /// The age is a stored, observable field rather than an assumption, which is the other
    /// half of the fix: the feature vector carries it, so a model can learn that an older
    /// issue is a worse input instead of being told they are all the same.
    static let maximumIssueAgeSeconds: TimeInterval = 12 * 3600

    /// The oldest issue that may still be read at `now`.
    ///
    /// Enforced in `ForecastPressurePoint.curve` and `ForecastFeatureExtractor`, which is to
    /// say in the two places a curve is built — not left to each caller. Without a gate the
    /// norm is a comment: the archive keeps rows for 90 days and a single issue reaches 240 h
    /// ahead, so a device that stopped asking (switch off, location revoked, no network) would
    /// go on drawing the same issue for ten days and calling it the current forecast, instead
    /// of falling back to the local model the way §2.1 of the feature spec describes.
    static func oldestUsableIssue(asOf now: Date) -> Date {
        now.addingTimeInterval(-maximumIssueAgeSeconds)
    }

    /// How long raw forecast rows are kept.
    ///
    /// **90 days.** Long enough to measure realised skill against what the barometer actually
    /// recorded, and to re-derive the offset calibration over a season; short enough that the
    /// table stays small next to the barometer log. Derived features computed from these rows
    /// are kept indefinitely — they are four floats a day, and they are the part a model is
    /// fitted on.
    static let rawRetentionDays = 90

    /// Oldest `validAt` still worth keeping raw.
    ///
    /// Calendar arithmetic, and `distantPast` on failure for the reason
    /// `PressureRetentionPolicy` uses it: a pass that deletes nothing is a bug somebody fixes
    /// later, and a pass that deletes the archive is not.
    static func rawCutoff(asOf now: Date, calendar: Calendar = .current) -> Date {
        calendar.date(byAdding: .day, value: -rawRetentionDays, to: now) ?? .distantPast
    }
}
