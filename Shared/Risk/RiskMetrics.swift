import Foundation

/// The metrics the risk model is judged on, and nothing that would flatter it.
///
/// **Accuracy is absent on purpose.** One window in nine holds an entry at best, so a model
/// that answers "no" to everything scores 0.89 and is worth nothing. What is reported instead
/// is the positive class: PR-AUC against the base rate it has to be read against, and the
/// product metric — how often the window the app actually named contained the entry.
enum RiskMetrics {

    /// Area under the precision–recall curve, by the step rule `Σ (Rₙ − Rₙ₋₁)·Pₙ`.
    ///
    /// Not the trapezoid: interpolating between operating points on a PR curve is optimistic,
    /// because precision does not move linearly between them. Ties share one threshold, so a
    /// model that returns the same score for every row scores its base rate rather than 1.
    ///
    /// `nil` when there is no positive class — a real state on a fresh install, and one that
    /// must read as "not measurable" rather than as zero.
    static func averagePrecision(scores: [Double], labels: [Bool]) -> Double? {
        guard scores.count == labels.count, !scores.isEmpty else { return nil }
        let positives = labels.count(where: { $0 })
        guard positives > 0 else { return nil }

        let order = scores.indices.sorted { scores[$0] > scores[$1] }

        var truePositives = 0
        var falsePositives = 0
        var previousRecall = 0.0
        var sum = 0.0
        var index = 0

        while index < order.count {
            let threshold = scores[order[index]]
            while index < order.count, scores[order[index]] == threshold {
                if labels[order[index]] { truePositives += 1 } else { falsePositives += 1 }
                index += 1
            }
            let precision = Double(truePositives) / Double(truePositives + falsePositives)
            let recall = Double(truePositives) / Double(positives)
            sum += (recall - previousRecall) * precision
            previousRecall = recall
        }

        return sum
    }

    /// Area under the ROC curve, by the rank identity rather than by trapezoids over a curve.
    ///
    /// Mid-ranks for ties, which is what makes a constant score come out at exactly 0.5 instead
    /// of 1 — the failure a naive sort-and-count has, and one that shows up here because a
    /// baseline built on a threshold rule produces exactly two distinct scores.
    static func rocAUC(scores: [Double], labels: [Bool]) -> Double? {
        guard scores.count == labels.count, !scores.isEmpty else { return nil }
        let positives = labels.count(where: { $0 })
        let negatives = labels.count - positives
        guard positives > 0, negatives > 0 else { return nil }

        let order = scores.indices.sorted { scores[$0] < scores[$1] }
        var ranks = [Double](repeating: 0, count: scores.count)
        var index = 0

        while index < order.count {
            var last = index
            while last + 1 < order.count, scores[order[last + 1]] == scores[order[index]] { last += 1 }
            let midRank = Double(index + last + 2) / 2
            for position in index...last { ranks[order[position]] = midRank }
            index = last + 1
        }

        let positiveRankSum = scores.indices.reduce(0.0) { $0 + (labels[$1] ? ranks[$1] : 0) }
        let positiveCount = Double(positives)

        return (positiveRankSum - positiveCount * (positiveCount + 1) / 2)
            / (positiveCount * Double(negatives))
    }

    /// Mean squared error of a probability against the outcome. Lower is better; a model that
    /// always answers the base rate scores `p(1−p)`.
    ///
    /// The one metric here that reads **calibration** rather than ranking, which is why it is
    /// the number quoted for the day stage: a model can rank days perfectly and still be
    /// useless behind a fixed threshold.
    static func brier(probabilities: [Double], labels: [Bool]) -> Double? {
        guard probabilities.count == labels.count, !probabilities.isEmpty else { return nil }

        let sum = probabilities.indices.reduce(0.0) { partial, index in
            let error = probabilities[index] - (labels[index] ? 1 : 0)
            return partial + error * error
        }
        return sum / Double(probabilities.count)
    }

    /// Of the rows a rule flagged, the share that held an entry. `nil` when it flagged none.
    static func precision(flagged: [Bool], labels: [Bool]) -> Double? {
        let named = flagged.indices.count(where: { flagged[$0] })
        guard named > 0 else { return nil }

        let hits = flagged.indices.count(where: { flagged[$0] && labels[$0] })
        return Double(hits) / Double(named)
    }

    /// Of the rows that held an entry, the share a rule flagged. `nil` when there are none.
    static func recall(flagged: [Bool], labels: [Bool]) -> Double? {
        let positives = labels.count(where: { $0 })
        guard positives > 0 else { return nil }

        let hits = flagged.indices.count(where: { flagged[$0] && labels[$0] })
        return Double(hits) / Double(positives)
    }

    /// The product metric: of the days that held an entry, the share where it fell inside the
    /// `k` windows the model ranked highest **for that day**.
    ///
    /// Per day and not globally, because the app names windows a day at a time. Days with no
    /// entry are excluded from the denominator rather than counted as misses — they are days
    /// the question was never asked, and folding them in would let a model look better by
    /// being lucky about which days were quiet. The exclusion is reported, per §5.
    ///
    /// Compare against `k / windowsPerDay`, which is what picking at random scores.
    static func hitRate(scores: [Double], labels: [Bool], days: [Date], topK: Int) -> Double? {
        guard scores.count == labels.count, scores.count == days.count, topK > 0 else { return nil }

        var byDay: [Date: [(score: Double, label: Bool)]] = [:]
        for index in scores.indices {
            byDay[days[index], default: []].append((scores[index], labels[index]))
        }

        let withEntry = byDay.values.filter { $0.contains(where: \.label) }
        guard !withEntry.isEmpty else { return nil }

        let hits = withEntry.count { rows in
            rows.sorted { $0.score > $1.score }.prefix(topK).contains(where: \.label)
        }
        return Double(hits) / Double(withEntry.count)
    }

    /// Wilson score interval for a proportion.
    ///
    /// The normal approximation is not usable at the sizes that matter here: the gate fires on
    /// twenty-odd days in a validation run, and at `p = 0.86` on `n = 21` it puts the upper
    /// bound past 1. The interval is reported beside every gate precision for that reason —
    /// the point estimate on its own reads as a much stronger claim than the data supports.
    static func wilsonInterval(hits: Int,
                               of total: Int,
                               zScore: Double = 1.96) -> ClosedRange<Double>? {
        guard total > 0 else { return nil }

        let count = Double(total)
        let rate = Double(hits) / count
        let denominator = 1 + zScore * zScore / count
        let centre = (rate + zScore * zScore / (2 * count)) / denominator
        let half = zScore / denominator
            * (rate * (1 - rate) / count + zScore * zScore / (4 * count * count)).squareRoot()

        return max(0, centre - half)...min(1, centre + half)
    }
}
