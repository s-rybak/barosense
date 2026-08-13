import Foundation

/// How much of the history a personal model needs is on the device.
///
/// A count against a target, and nothing else. It makes no claim about the quality of any
/// forecast: there is no trained model yet (`.claude/context/ml-spec.md` — the model row reads
/// *not trained*), so the only progress bar this app can honestly draw is one over the data a
/// model would be fitted on. The card's own label calls it training progress because that is
/// what the design calls it; the explainer behind the card is where the distinction gets made.
///
/// **Display only.** No row in the feature registry, no consumer in `Shared/Features/`.
struct TrainingDataProgress: Hashable, Sendable {

    /// Check-ins recorded on this device, all time.
    ///
    /// All time and not a window: the bar reports the size of the history a model would train
    /// on, and every stored row counts toward that whatever month it landed in.
    let checkInCount: Int

    /// Negative counts are clamped rather than trusted. Nothing produces one today; the
    /// alternative is a bar that renders to the left of its own track if something ever does.
    init(checkInCount: Int) {
        self.checkInCount = max(checkInCount, 0)
    }
}

extension TrainingDataProgress {

    /// The count at which the personal component starts to carry more weight than the
    /// population prior.
    ///
    /// Not a finish line, and not an accuracy claim. §4 blends the two with
    /// `w(n) = n / (n + k)` at a *provisional* `k = 30`; 40 rows put `w` at 0.57, which is the
    /// first point where a forecast leans mostly on this user's own history rather than on the
    /// prior. The design draws "~40" on the same card, so what the user reads and what the
    /// arithmetic means are the same number.
    ///
    /// *Provisional*, like `k`. Re-derive both from a measured learning curve; changing this
    /// moves every bar on the screen and nothing else.
    static let targetCheckInCount = 40

    /// 0–1, clamped.
    ///
    /// Past the target it stays at 1. The bar measures the distance to the point where the
    /// user's own data leads, and there is no "further than there" to draw — more history keeps
    /// helping, but not on this scale.
    var fraction: Double {
        guard Self.targetCheckInCount > 0 else { return 1 }

        return min(Double(checkInCount) / Double(Self.targetCheckInCount), 1)
    }

    /// How many more check-ins before the target. Zero once it is reached.
    var remainingCheckIns: Int { max(Self.targetCheckInCount - checkInCount, 0) }

    var hasReachedTarget: Bool { checkInCount >= Self.targetCheckInCount }
}
