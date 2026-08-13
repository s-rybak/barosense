import Foundation

/// How much the weather is moving right now, on a 0–1 scale, read off the barometer log alone.
///
/// **A statement about the weather, not about the user.** It reports how far pressure has
/// travelled across the trailing six hours. It does not say the user will feel it, and nothing
/// self-reported enters it — no check-in, no tag, no intensity. The card that draws it is
/// labelled "Weather Trigger Index" in the design, and the copy on that card has to stay on the
/// weather's side of that line (`.claude/skills/appstore_compliance/SKILL.md`).
///
/// **Display only.** Like `PressureTrend`, it has no row in the feature registry and nothing in
/// `Shared/Features/` may read it. The model consumes `pressureDeltaHPaPer6h` as a continuous
/// *signed* value; folding that into one unsigned 0–1 figure throws away the sign and most of
/// the resolution it is fitted on.
///
/// ## Why a rule and not a model
///
/// There is no trained model — every feature row in `.claude/context/ml-spec.md` §2 is still
/// `planned` — so this card cannot show one. What it shows instead is the pipeline's own trivial
/// baseline made visible: pressure movement over six hours, the thing a learned model has to
/// beat before it is worth shipping (§7). That is a reading off rows that exist, which is what
/// separates it from the "Точність 87%" caption `PressureChartCard` deliberately refuses to
/// draw. The day the model lands, this stays as the baseline and the forecast becomes a
/// different card.
///
/// ## Known limitation: altitude
///
/// The log holds raw station pressure, so ten floors in a lift moves this figure the way a front
/// does — §3. A round trip nets out over a six-hour window and a one-way climb does not. The
/// shipped `PressureTrend` caption already carries the same exposure; this is a second surface
/// onto it, not a new class of error. Fixing it needs an altitude reference the app does not
/// collect.
struct WeatherTriggerIndex: Hashable, Sendable {

    /// 0–1. Zero is "nothing above the noise floor", one is a full-scale movement.
    let value: Double

    /// The change the value was read off, in hPa across `windowSeconds`. **Signed** — negative
    /// is a fall — because the index itself is not, and a caller that wants to say which way
    /// pressure went has nowhere else to get it.
    let deltaHPa: Double

    /// Fraction of the window that was actually observed, 0–1. Carried rather than dropped
    /// after the gate, so a caller can tell a reading built on a full window from one built on
    /// the bare minimum.
    let coverage: Double
}

extension WeatherTriggerIndex {

    /// Six hours — the window `pressureDeltaHPaPer6h` is defined over in §2.1, so the card and
    /// the eventual feature describe the same stretch of time instead of two different ones.
    static let windowSeconds: TimeInterval = 6 * 3600

    /// Below this the index is zero rather than a small number.
    ///
    /// Twice `PressureTrend.significantChangeHPa`, which is that same rate held for twice as
    /// long: the two surfaces then agree about where weather stops and sensor noise starts,
    /// instead of the chart calling a day "steady" while the card reports 12%.
    static let noiseFloorHPa = PressureTrend.significantChangeHPa * 2

    /// The change that reads as 100%.
    ///
    /// *Provisional.* 6 hPa in six hours is the order of magnitude of a deep low passing over,
    /// but it comes from that reasoning and not from a measured distribution of this app's own
    /// traces. Re-derive it once there is real history — it is the one constant here that
    /// decides what "high" means on screen.
    static let fullScaleHPa: Double = 6

    /// How much of the window has to be observed before a figure is offered at all.
    ///
    /// The 50% `pressureCoverage6h` requires in §2.1. Below it the index is `nil`, never zero:
    /// "the weather is quiet" and "the phone was asleep" are different facts and the card has
    /// to be able to say which.
    static let minimumCoverage: Double = 0.5

    /// The index at `now`, or `nil` when the log is too thin to support one.
    ///
    /// `samples` may be unsorted and may reach further back than the window; anything outside
    /// it is ignored, so one store read serves this and the chart both.
    ///
    /// The delta is taken raw between the window's first and last reading, and deliberately
    /// **not** scaled up to a full six hours — the same rule `PressureTrend.make` follows.
    /// Extrapolating a three-hour span by 2× turns sensor noise into a confident bar.
    static func make(from samples: [PressureSample], asOf now: Date) -> WeatherTriggerIndex? {
        let window = now.addingTimeInterval(-windowSeconds)...now
        let inWindow = samples
            .filter { window.contains($0.timestamp) }
            .sorted { $0.timestamp < $1.timestamp }

        let coverage = observedCoverage(of: inWindow, asOf: now)
        guard coverage >= minimumCoverage,
              let first = inWindow.first,
              let last = inWindow.last
        else { return nil }

        let deltaHPa = last.pressure.delta(from: first.pressure)

        return WeatherTriggerIndex(value: scaled(magnitudeHPa: abs(deltaHPa)),
                                   deltaHPa: deltaHPa,
                                   coverage: coverage)
    }

    /// Fraction of the trailing hourly cells holding at least one reading.
    ///
    /// Hourly and aligned to the hour, which is the grid §2.1 defines — not aligned to `now`,
    /// so the figure does not shift under a reload one second later. Counting cells rather
    /// than readings is also what stops six samples taken in one busy minute from reporting
    /// a covered window.
    private static func observedCoverage(of samples: [PressureSample], asOf now: Date) -> Double {
        let cellCount = Int((windowSeconds / 3600).rounded())
        guard cellCount > 0 else { return 0 }

        let occupied = Set(samples.map(Self.hourCell))
        let newest = hourCell(at: now)
        let cells = (newest - cellCount + 1)...newest

        return Double(cells.filter(occupied.contains).count) / Double(cellCount)
    }

    private static func hourCell(_ sample: PressureSample) -> Int {
        hourCell(at: sample.timestamp)
    }

    private static func hourCell(at date: Date) -> Int {
        Int((date.timeIntervalSince1970 / 3600).rounded(.down))
    }

    /// Linear from the noise floor to full scale, clamped at both ends.
    ///
    /// Linear rather than curved on purpose: a curve would need a shape, and there is no
    /// evidence here to pick one with. A straight line between two stated constants is a
    /// claim a reader can check.
    private static func scaled(magnitudeHPa: Double) -> Double {
        let span = fullScaleHPa - noiseFloorHPa
        guard span > 0 else { return magnitudeHPa >= fullScaleHPa ? 1 : 0 }

        return min(max((magnitudeHPa - noiseFloorHPa) / span, 0), 1)
    }
}
