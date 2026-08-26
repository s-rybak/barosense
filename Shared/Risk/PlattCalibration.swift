import Foundation

/// Platt scaling: the one-parameter-pair correction that turns a ranking into a probability.
///
/// ## What it fixes, and what it deliberately does not
///
/// `class_weight='balanced'` is what makes the day model see the rare class at all, and it is
/// also what breaks the numbers it returns: reweighting the loss moves the fitted base rate
/// away from the real one, so the model comes back systematically high. For **ranking** that is
/// harmless — the order is untouched. For a threshold it is fatal, because "notify above 0.7"
/// only means something if 0.7 is a frequency.
///
/// Measured on the notebook's own forward-chaining folds: the day model's Brier score falls
/// from **0.174 raw to 0.117 calibrated**, with the ordering essentially unchanged. That is the
/// whole trade — this buys reliability, not discrimination, and it is the reason a percentage
/// may be shown on screen at all.
///
/// ## Why the fit is forward-chained too
///
/// The correction is a model, and a model fitted on the same rows it corrects sees its own
/// in-sample decisions, which are optimistic. Calibrating on those teaches the sigmoid to
/// undo an overconfidence that only exists in-sample, and it comes back worse on new days. So
/// the decisions handed to `fit` are always out-of-fold decisions from forward-chained splits —
/// past scoring future — never in-sample ones.
///
/// The shape here is one base model plus one sigmoid, rather than the library's default
/// ensemble of one pair per fold. Three sets of coefficients on the device to average at every
/// score, for a difference measured at 0.024 ROC-AUC in the ensemble's favour and 0.013 Brier
/// in this one's, is not a trade worth making on a phone.
struct PlattCalibration: Hashable, Sendable, Codable {

    /// `p = sigmoid(slope · decision + intercept)`.
    ///
    /// Deliberately **not** scikit-learn's stored convention, which is `1 / (1 + exp(a·d + b))`
    /// and therefore holds the negatives of these two. Both are correct and one of them is
    /// readable: here a model whose decisions rank correctly has a *positive* slope, and
    /// `intercept` is the base rate in log-odds. `SklearnFixture` is compared against the
    /// negated pair, which is the only place the difference has to be remembered.
    let slope: Double
    let intercept: Double

    /// The transform that changes nothing, for the paths where a raw score is already a
    /// probability. `p = sigmoid(d)`.
    static let identity = PlattCalibration(slope: 1, intercept: 0)

    func probability(ofDecision decision: Double) -> Double {
        LogisticMath.sigmoid(slope * decision + intercept)
    }

    static let maximumIterations = 200
    static let convergenceTolerance: Double = 1e-10

    /// Fits `(a, b)` on out-of-fold decisions by Newton iteration.
    ///
    /// Targets are the prior-corrected ones from Lin, Weng and Lin (2007): `(N₊+1)/(N₊+2)`
    /// instead of 1 and `1/(N₋+2)` instead of 0. Fitting to the hard labels instead lets the
    /// sigmoid run away whenever the classes happen to be separable in a fold — which on
    /// sixty days and a rare class is not a corner case — and the result is a "probability"
    /// pinned at 0 and 1.
    ///
    /// `nil` when there is nothing to fit: no rows, or one class absent, in which case the
    /// caller keeps the uncalibrated score rather than inventing a correction.
    static func fit(decisions: [Double], labels: [Bool]) -> PlattCalibration? {
        guard decisions.count == labels.count, !decisions.isEmpty else { return nil }

        let positives = Double(labels.count(where: { $0 }))
        let negatives = Double(labels.count) - positives
        guard positives > 0, negatives > 0 else { return nil }

        let high = (positives + 1) / (positives + 2)
        let low = 1 / (negatives + 2)
        let targets = labels.map { $0 ? high : low }

        var slope = 0.0
        // The base rate in log-odds, which is what a flat sigmoid should return before it has
        // seen a decision. The sign is the easiest thing here to get wrong and the most
        // punishing: started on the far side of the base rate with a rare positive class,
        // Newton's first step is enormous and the fit leaves for infinity.
        var offset = log((positives + 1) / (negatives + 1))
        var loss = objective(decisions, targets, slope, offset)

        for _ in 0..<maximumIterations {
            var gradientSlope = 0.0
            var gradientOffset = 0.0
            var curvatureSS = 0.0
            var curvatureSO = 0.0
            var curvatureOO = 0.0

            for (index, decision) in decisions.enumerated() {
                let probability = LogisticMath.sigmoid(slope * decision + offset)
                let weight = max(probability * (1 - probability), 1e-12)
                let residual = probability - targets[index]

                gradientSlope += residual * decision
                gradientOffset += residual
                curvatureSS += weight * decision * decision
                curvatureSO += weight * decision
                curvatureOO += weight
            }

            curvatureSS += 1e-12
            curvatureOO += 1e-12

            let determinant = curvatureSS * curvatureOO - curvatureSO * curvatureSO
            guard abs(determinant) > 1e-300 else { break }

            let stepSlope = (curvatureOO * gradientSlope - curvatureSO * gradientOffset) / determinant
            let stepOffset = (curvatureSS * gradientOffset - curvatureSO * gradientSlope) / determinant

            // Step halving. The curvature of a sigmoid collapses toward zero once the fitted
            // probabilities saturate, and an undamped Newton step then divides by it — which is
            // not a rare path here, because a fold whose decisions separate the classes cleanly
            // is exactly the case this correction is asked about.
            var scaleFactor = 1.0
            var accepted = false
            for _ in 0..<40 {
                let candidateSlope = slope - scaleFactor * stepSlope
                let candidateOffset = offset - scaleFactor * stepOffset
                let candidateLoss = objective(decisions, targets, candidateSlope, candidateOffset)

                if candidateLoss.isFinite, candidateLoss <= loss {
                    let movement = max(abs(slope - candidateSlope), abs(offset - candidateOffset))
                    slope = candidateSlope
                    offset = candidateOffset
                    loss = candidateLoss
                    accepted = movement >= convergenceTolerance
                    break
                }
                scaleFactor /= 2
            }
            if !accepted { break }
        }

        guard slope.isFinite, offset.isFinite else { return nil }

        return PlattCalibration(slope: slope, intercept: offset)
    }

    /// Weighted cross-entropy against the prior-corrected targets, on the stable side of the
    /// softplus so a decision of ±800 does not become an infinity here.
    private static func objective(_ decisions: [Double],
                                  _ targets: [Double],
                                  _ slope: Double,
                                  _ offset: Double) -> Double {
        var total = 0.0
        for (index, decision) in decisions.enumerated() {
            let score = slope * decision + offset
            let softplus = score > 0 ? score + log1p(exp(-score)) : log1p(exp(score))
            total += softplus - targets[index] * score
        }
        return total
    }
}
