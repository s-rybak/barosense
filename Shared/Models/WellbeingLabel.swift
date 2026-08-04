import Foundation

/// The binary target the forecast model is trained against.
///
/// Ground truth for the definition is `.claude/context/ml-spec.md` §1. This type is the
/// single place the threshold exists — the comparison is never inlined at a call site,
/// because a second copy would drift and silently invalidate every reported metric.
enum WellbeingLabel {

    /// A check-in at or below this score counts as a "poor wellbeing" event.
    ///
    /// The bottom two points of the 1–5 scale. `.fair` is the neutral middle: folding it
    /// into the positive class would push the base rate toward half of all check-ins and
    /// label ordinary days as events.
    ///
    /// *Provisional* — chosen from reasoning, not from data. Changing it invalidates
    /// every stored metric, so the baselines get re-run in the same change.
    static let poorWellbeingThreshold: WellbeingScore = .poor
}

extension CheckIn {

    /// Whether this check-in is a positive event for the model.
    ///
    /// Tags are recorded but do not enter the v1 label.
    var isPoorWellbeing: Bool {
        score <= WellbeingLabel.poorWellbeingThreshold
    }
}
