import Foundation

/// One point of the short history the watch draws: an instant and a pressure, nothing else.
///
/// Not a `PressureSample`, and the difference is the point. A sample carries an identifier
/// and is a row of the training log; these are already-bucketed display points that exist
/// for the length of one screen. Reusing `PressureSample` would put 36 bytes of UUID per
/// point on the air for something no store will ever hold, and would make a drawn average
/// indistinguishable from a measurement to anything reading the type.
struct PressureTrendPoint: Hashable, Codable, Sendable {

    let timestamp: Date

    /// Hectopascals, the one unit the domain layer uses. Named for it because a bare
    /// `value` here is exactly where a kPa gets in.
    let hectopascals: Double
}

/// What the watch shows: the phone's latest reading, how pressure has been moving, and the
/// short stretch of history behind it.
///
/// The history is deliberately **short and pre-bucketed** — see `PressureWatchSeries`. The
/// watch is a glance device and the full log lives on the phone, where there is room to
/// scroll it; what travels here is only enough to draw the shape the number came out of.
///
/// Environmental measurements only. No check-in values, no Health values, no note text: this
/// crosses a device boundary, and widening it is a gated decision under `CLAUDE.md`
/// constraint 2 rather than an edit to this struct. Check-ins travel the *other* way, on
/// their own transport and under their own reasoning — see `CheckInTransfer`.
struct PressureDisplaySnapshot: Hashable, Codable, Sendable {

    /// The last reading the phone's barometer actually took. Never a forecast value — the
    /// watch's number is ground truth for "now" or it is nothing.
    let sample: PressureSample

    /// The trailing three-hour tendency, computed on the phone from the full log. Computed
    /// there and shipped rather than derived here, because the watch holds no history to
    /// derive it from.
    let trend: PressureTrend

    /// The bucketed trailing window the watch plots, ascending by time. Empty until the
    /// phone has recorded more than one reading, which is the ordinary state of a fresh
    /// install for the first quarter of an hour.
    ///
    /// Defaulted, so a payload written by a build that predates the chart still decodes:
    /// `Codable` fills a missing key with nothing to fill it with unless the property has a
    /// default, and a watch one release behind must degrade to the bare number rather than
    /// to a decode failure.
    let recent: [PressureTrendPoint]

    /// The signed three-hour change in hPa, `nil` when there is not enough history to say.
    ///
    /// The number `trend` was cut from — see `PressureTrend.delta`. Shipped rather than
    /// derived on the watch for the reason the trend is: `recent` is bucketed for drawing,
    /// and a difference taken across averaged points is a smoothed difference. The watch
    /// would print a smaller fall than the phone reports and neither screen would be wrong
    /// on its own terms, which is the worst kind of disagreement to debug.
    let deltaHPaPer3h: Double?

    init(sample: PressureSample,
         trend: PressureTrend,
         recent: [PressureTrendPoint] = [],
         deltaHPaPer3h: Double? = nil) {
        self.sample = sample
        self.trend = trend
        self.recent = recent
        self.deltaHPaPer3h = deltaHPaPer3h
    }
}

extension PressureDisplaySnapshot {

    /// Tolerates the key being absent, which is what a payload from a build older than the
    /// chart looks like. Hand-written rather than synthesised for that one reason.
    private enum CodingKeys: String, CodingKey {
        case sample, trend, recent, deltaHPaPer3h
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sample = try container.decode(PressureSample.self, forKey: .sample)
        trend = try container.decode(PressureTrend.self, forKey: .trend)
        recent = try container.decodeIfPresent([PressureTrendPoint].self, forKey: .recent) ?? []
        deltaHPaPer3h = try container.decodeIfPresent(Double.self, forKey: .deltaHPaPer3h)
    }
}

/// How much history the watch is sent, and how coarsely.
///
/// ## Why this is not simply the phone's chart range
///
/// The phone draws four selectable ranges and scrolls twelve screenfuls behind each
/// (`PressureChartRange`). None of that fits a 40 mm screen or is worth putting on the air.
/// This is one fixed window, bucketed once on the phone, sized so the whole series is a
/// couple of hundred bytes riding along with a delivery the system was going to make anyway.
///
/// ## Cost
///
/// A full window holds `windowSeconds / bucketSeconds` = 12 points, and `maxPoints` caps a
/// clock-skewed one at 16. So 12–16 × (an ISO-8601 date + a double) ≈ 12–16 × ~55 B ≈
/// 0.7 kB typical and 0.9 kB worst case of JSON, against `updateApplicationContext`'s limit,
/// which is orders of magnitude above that. No extra wake, no extra store read — the phone
/// already loads this window to compute the tendency, and this reuses that same array
/// (`PressureCollectionController.publish`).
enum PressureWatchSeries {

    /// Six hours. Wide enough that the shape of a front is visible on the plot, and it is
    /// the shortest window that comfortably contains `PressureTrend.windowSeconds`, so the
    /// caption's three hours are always somewhere inside the line the user is looking at.
    static let windowSeconds: TimeInterval = 6 * 3600

    /// One point per half hour across the window.
    ///
    /// The same bucket the phone's six-hour range uses, which is deliberate: the two devices
    /// must not draw visibly different lines for the same stretch of time. Twelve points is
    /// also about the density limit of a plot 40 pt tall.
    static let bucketSeconds: TimeInterval = 30 * 60

    /// Hard ceiling on what goes on the air, independent of the arithmetic above.
    ///
    /// A guard rather than a target: a phone whose clock jumped, or a log holding a run of
    /// future-dated rows, can produce more occupied buckets than the window has slots, and
    /// an unbounded array on a wire format is how a payload-size limit gets hit in the field
    /// rather than in review. The newest points are the ones kept.
    static let maxPoints = 16

    /// Collapses the raw log into what the watch plots.
    ///
    /// Takes the same array the tendency was computed from, so the line and the arrow can
    /// never describe different data. Anything outside the window, and anything dated after
    /// `now`, is dropped — a forward-dated row is a clock artefact and drawing it would put
    /// the line's end somewhere the user has not lived yet.
    static func make(from samples: [PressureSample], asOf now: Date) -> [PressureTrendPoint] {
        let window = now.addingTimeInterval(-windowSeconds)...now
        let inWindow = samples.filter { window.contains($0.timestamp) }

        let bucketed = PressureBuckets.collapse(inWindow, intoBucketsOf: bucketSeconds)

        return bucketed
            .suffix(maxPoints)
            .map { PressureTrendPoint(timestamp: $0.timestamp,
                                      hectopascals: $0.pressure.hectopascals) }
    }
}

/// Hands the phone's latest reading to the watch for display.
///
/// Declared next to its consumer for the same reason `PressureSource` is: the phone's
/// controller and its tests depend on this and not on `WCSession`.
///
/// Deliberately fire-and-forget, and deliberately *lossy*. The watch needs the newest value
/// and has no use for the one before it, so a publish the system supersedes before delivery
/// has lost nothing. That is the opposite of the training log's requirement, and it is why
/// this is a separate protocol rather than a direction flag on one shared type.
protocol PressureDisplayLink: Sendable {

    /// Offers `snapshot` to the paired watch, replacing any undelivered one.
    func publish(_ snapshot: PressureDisplaySnapshot) async
}

/// Used on a device with no counterpart to talk to, and in previews.
struct NoOpPressureDisplayLink: PressureDisplayLink {
    func publish(_ snapshot: PressureDisplaySnapshot) async {}
}

/// When a snapshot is worth putting on the air.
enum PressureDisplayPolicy {

    /// Whether `snapshot` says anything the watch is not already showing.
    ///
    /// Pure, and here rather than in the phone's controller, because that type lives in
    /// `Barosense/` where no test target can reach it.
    ///
    /// The only gate is *did the content change*. There is no time-based throttle and there
    /// must not be one: `updateApplicationContext` already keeps a single slot that the next
    /// call overwrites, so a burst costs one delivery, and a rate limit on top of that would
    /// only be able to make the watch's number staler than the phone's.
    static func shouldPublish(_ snapshot: PressureDisplaySnapshot,
                              lastPublished: PressureDisplaySnapshot?) -> Bool {
        snapshot != lastPublished
    }
}

/// Wire format for the display snapshot.
///
/// A `Codable` round trip through JSON rather than a hand-rolled dictionary of primitives:
/// `PressureDisplaySnapshot` already is `Codable`, and hand-mapping fields is exactly where a
/// hectopascal quietly becomes a kilopascal.
enum PressureDisplayPayload {

    /// Versioned because the receiver may be an older build than the sender — the watch and
    /// the phone update independently. An unknown key is ignored rather than mis-parsed.
    ///
    /// `v2` and not `v1`: `v1` carried a batch of samples travelling the other way, from the
    /// watch's barometer to the phone's log. A watch still running that build would read a
    /// `v1` key as history to ingest, so the new payload must not reuse the name.
    static let key = "barosense.pressureDisplay.v2"

    static func encode(_ snapshot: PressureDisplaySnapshot) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return [key: try encoder.encode(snapshot)]
    }

    /// Returns `nil` when the payload is not ours — a transfer for some other feature is not
    /// an error here.
    static func decode(_ context: [String: Any]) throws -> PressureDisplaySnapshot? {
        guard let data = context[key] as? Data else { return nil }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do {
            return try decoder.decode(PressureDisplaySnapshot.self, from: data)
        } catch {
            throw PressureDisplayError.malformedPayload
        }
    }
}

enum PressureDisplayError: Error, Sendable, Equatable {

    /// The key was present but the bytes behind it did not decode. A version skew the
    /// version tag failed to catch, or a corrupt transfer. Dropped, never guessed at.
    case malformedPayload
}
