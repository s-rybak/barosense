import Foundation

/// The binary target the forecast model is trained against.
///
/// Ground truth for the definition is `.claude/context/ml-spec.md` §1. This type is the
/// single place the threshold exists — the comparison is never inlined at a call site,
/// because a second copy would drift and silently invalidate every reported metric.
enum WellbeingLabel {

    /// A check-in at or **above** this intensity counts as a "poor wellbeing" event.
    ///
    /// At or above, not at or below: `CheckInIntensity` runs the other way from a wellbeing
    /// score, 10 being the worst. The direction is the whole reason the comparison lives
    /// here and nowhere else.
    ///
    /// The top four points of the 1–10 scale — the same 40% of the range the previous 1–5
    /// scale's bottom two points covered, so moving the form to a finer scale did not
    /// quietly move the event definition with it. `5` and `6` are the middle: folding them
    /// in would push the base rate toward half of all check-ins and label ordinary days as
    /// events.
    ///
    /// *Provisional* — chosen from reasoning, not from data. Changing it invalidates
    /// every stored metric, so the baselines get re-run in the same change.
    static let poorWellbeingThreshold = CheckInIntensity(clamping: 7)
}

extension CheckIn {

    /// Whether this check-in is a positive event for the model.
    ///
    /// Tags and medication entries are recorded but do not enter the v1 label.
    var isPoorWellbeing: Bool {
        intensity >= WellbeingLabel.poorWellbeingThreshold
    }
}
