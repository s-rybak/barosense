import Foundation

/// A fitted logistic regression, plus the two preprocessing steps it cannot be read without.
///
/// Median imputation, standardisation and the linear part travel together in one value because
/// separating them is how a model silently starts scoring on the wrong axis: coefficients
/// fitted on standardised columns applied to raw hPa are not slightly wrong, they are
/// meaningless. The three are a single serialisable unit for the same reason.
///
/// `Codable` so a fitted model survives a relaunch without being refitted, and so the shipped
/// prior can be written as data rather than as code that happens to produce numbers.
struct LogisticRegressionModel: Hashable, Sendable, Codable {

    /// Per-column median from the training rows, used wherever a value is missing.
    ///
    /// Imputation, not deletion, because absence here is ordinary rather than exceptional: a
    /// window with no cell six hours back still has four other columns worth reading, and
    /// dropping it would throw away the row the sensor did cover.
    let medians: [Double]

    /// Column means and standard deviations of the imputed training rows.
    ///
    /// Population standard deviation, and 1 where a column did not vary — the same convention
    /// `StandardScaler` uses, so a model fitted here and one fitted in the notebook can be
    /// compared coefficient by coefficient.
    let mean: [Double]
    let scale: [Double]

    /// On standardised columns. Directly comparable to each other, which is the whole reason
    /// the standardisation is not optional.
    let coefficients: [Double]

    let intercept: Double

    var featureCount: Int { coefficients.count }

    /// The linear score before the logistic — what a Platt correction is fitted on.
    ///
    /// Calibration is fitted on this and not on the probability because the sigmoid has already
    /// squashed the tails by then, and a correction learned on squashed values cannot move
    /// them back.
    func decision(_ raw: [Double?]) -> Double {
        var sum = intercept
        for index in coefficients.indices {
            let value = index < raw.count ? raw[index] : nil
            let filled = value ?? (index < medians.count ? medians[index] : 0)
            let centred = filled - (index < mean.count ? mean[index] : 0)
            let divisor = index < scale.count ? scale[index] : 1
            sum += coefficients[index] * (centred / (divisor == 0 ? 1 : divisor))
        }
        return sum
    }

    func probability(_ raw: [Double?]) -> Double {
        LogisticMath.sigmoid(decision(raw))
    }
}

/// Numerics shared by the fitter and the calibrator.
enum LogisticMath {

    /// Overflow-safe logistic. The naive form returns NaN for a decision below about −710.
    static func sigmoid(_ value: Double) -> Double {
        if value >= 0 {
            return 1 / (1 + exp(-value))
        }
        let exponent = exp(value)
        return exponent / (1 + exponent)
    }

    /// Solves `A x = b` by Gaussian elimination with partial pivoting.
    ///
    /// Dense and unblocked, which is right at this size: the largest system here is 10×10, and
    /// a decomposition worth optimising would be more code than the solve. `nil` on a singular
    /// matrix rather than a fabricated answer — a fit that cannot be solved has to degrade to
    /// the prior, not to arbitrary coefficients.
    static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        let size = vector.count
        guard matrix.count == size, matrix.allSatisfy({ $0.count == size }) else { return nil }

        var upper = matrix
        var rhs = vector

        for column in 0..<size {
            var pivot = column
            for row in (column + 1)..<size where abs(upper[row][column]) > abs(upper[pivot][column]) {
                pivot = row
            }
            guard abs(upper[pivot][column]) > 1e-12 else { return nil }

            if pivot != column {
                upper.swapAt(pivot, column)
                rhs.swapAt(pivot, column)
            }

            for row in (column + 1)..<size {
                let factor = upper[row][column] / upper[column][column]
                guard factor != 0 else { continue }
                for inner in column..<size {
                    upper[row][inner] -= factor * upper[column][inner]
                }
                rhs[row] -= factor * rhs[column]
            }
        }

        var solution = [Double](repeating: 0, count: size)
        for row in stride(from: size - 1, through: 0, by: -1) {
            var sum = rhs[row]
            for column in (row + 1)..<size {
                sum -= upper[row][column] * solution[column]
            }
            solution[row] = sum / upper[row][row]
        }

        return solution.allSatisfy(\.isFinite) ? solution : nil
    }
}

/// Fits `LogisticRegressionModel` by penalised Newton iteration.
///
/// ## Why this and not Core ML
///
/// `MLUpdateTask` retrains a shipped `.mlmodel` and is the right tool for a network with
/// thousands of weights. This model has at most ten, the fit is a closed-form Newton solve on a
/// 10×10 system, and the whole thing runs in under a millisecond on a few hundred rows — see
/// the battery note in `ml-spec.md`. Wrapping that in a model file would add a build artefact,
/// a versioning problem and an opaque box around ten numbers a reviewer can otherwise read.
///
/// The choice is revisited the day the model stops being linear, not before.
enum LogisticRegressionFitter {

    /// Inverse regularisation strength, matching `LogisticRegression(C=…)`.
    ///
    /// **0.3**, carried from the notebook. Stronger than the library default of 1.0, which is
    /// the right direction here: nine columns against a few hundred rows and a rare positive
    /// class is exactly where an unregularised fit starts reading noise as structure.
    static let defaultInverseRegularisation: Double = 0.3

    static let maximumIterations = 100

    /// Newton stops when no parameter moves by more than this.
    static let convergenceTolerance: Double = 1e-9

    /// Fewest rows a fit is attempted on at all.
    ///
    /// Not a statistical claim — the blend weight in `WellbeingRiskModel` is what decides how
    /// much a thin fit is trusted. This is only the point below which the arithmetic itself
    /// stops being defined: fewer rows than parameters, or one class missing entirely.
    static let minimumRowsPerParameter: Double = 2

    /// Fits, or returns `nil` when the rows cannot support a fit.
    ///
    /// `nil` is a real and expected outcome — a user with no positive rows yet, a fold with one
    /// class, a singular design. Every caller falls back to the shipped prior, which is what
    /// the cold-start path is.
    ///
    /// - Parameters:
    ///   - rows: raw feature vectors; `nil` entries are median-imputed from these same rows.
    ///   - labels: the positive class.
    ///   - balanced: weight each class by the inverse of its frequency, as
    ///     `class_weight='balanced'` does. On by default because the positive class here is
    ///     one window in nine at best.
    static func fit(rows: [[Double?]],
                    labels: [Bool],
                    inverseRegularisation: Double = defaultInverseRegularisation,
                    balanced: Bool = true) -> LogisticRegressionModel? {
        guard rows.count == labels.count, let width = rows.first?.count, width > 0 else { return nil }
        guard Double(rows.count) >= minimumRowsPerParameter * Double(width + 1) else { return nil }

        let positives = labels.count(where: { $0 })
        guard positives > 0, positives < labels.count else { return nil }

        let medians = (0..<width).map { column in
            median(of: rows.compactMap { $0.indices.contains(column) ? $0[column] : nil })
        }
        let imputed = rows.map { row in
            (0..<width).map { column -> Double in
                (row.indices.contains(column) ? row[column] : nil) ?? medians[column]
            }
        }

        let mean = (0..<width).map { column in
            imputed.reduce(0) { $0 + $1[column] } / Double(imputed.count)
        }
        let scale = (0..<width).map { column -> Double in
            let variance = imputed.reduce(0) { partial, row in
                let delta = row[column] - mean[column]
                return partial + delta * delta
            } / Double(imputed.count)
            let deviation = variance.squareRoot()
            return deviation > 1e-12 ? deviation : 1
        }

        let design = imputed.map { row in
            (0..<width).map { (row[$0] - mean[$0]) / scale[$0] }
        }

        // `class_weight='balanced'`: n / (2 · n_class). The positive class is one window in
        // nine at best, and an unweighted fit on that answers "never" and scores well doing it.
        let weights: [Double] = labels.map { label in
            guard balanced else { return 1 }
            let count = label ? positives : labels.count - positives
            return Double(labels.count) / (2 * Double(count))
        }

        guard let solution = newton(design: design,
                                    labels: labels,
                                    weights: weights,
                                    lambda: 1 / max(inverseRegularisation, 1e-6))
        else { return nil }

        return LogisticRegressionModel(medians: medians,
                                       mean: mean,
                                       scale: scale,
                                       coefficients: Array(solution.prefix(width)),
                                       intercept: solution[width])
    }

    // MARK: - Newton

    /// Penalised Newton with backtracking. Returns `[coefficients…, intercept]`.
    ///
    /// The intercept is the last parameter and is **not** penalised, matching the library
    /// convention. Penalising it would pull the fitted base rate toward one half, which on a
    /// class that is one in nine is a large and entirely artificial shift.
    private static func newton(design: [[Double]],
                               labels: [Bool],
                               weights: [Double],
                               lambda: Double) -> [Double]? {
        let width = design[0].count
        let size = width + 1
        var beta = [Double](repeating: 0, count: size)
        var previousLoss = objective(design, labels, weights, beta, lambda)

        for _ in 0..<maximumIterations {
            let system = normalEquations(design: design,
                                         labels: labels,
                                         weights: weights,
                                         beta: beta,
                                         lambda: lambda)

            guard let step = LogisticMath.solve(system.hessian, system.gradient) else { return nil }

            // Backtracking. Newton on a penalised logistic is well behaved with standardised
            // columns, but a fold with near-separable classes drives the curvature toward zero
            // and a full step then overshoots into a worse objective. Halving is two lines and
            // removes the failure mode.
            var scaleFactor = 1.0
            var accepted = beta
            var acceptedLoss = previousLoss
            for _ in 0..<20 {
                let candidate = (0..<size).map { beta[$0] - scaleFactor * step[$0] }
                let loss = objective(design, labels, weights, candidate, lambda)
                if loss.isFinite, loss <= previousLoss {
                    accepted = candidate
                    acceptedLoss = loss
                    break
                }
                scaleFactor /= 2
            }

            let movement = (0..<size).map { abs(accepted[$0] - beta[$0]) }.max() ?? 0
            beta = accepted
            previousLoss = acceptedLoss
            if movement < convergenceTolerance { break }
        }

        return beta.allSatisfy(\.isFinite) ? beta : nil
    }

    /// Gradient and Hessian of the penalised objective at `beta`, intercept last.
    private static func normalEquations(design: [[Double]],
                                        labels: [Bool],
                                        weights: [Double],
                                        beta: [Double],
                                        lambda: Double)
    -> (gradient: [Double], hessian: [[Double]]) {
        let width = design[0].count
        let size = width + 1
        var gradient = [Double](repeating: 0, count: size)
        var hessian = [[Double]](repeating: [Double](repeating: 0, count: size), count: size)

        for (index, row) in design.enumerated() {
            var score = beta[width]
            for column in 0..<width { score += beta[column] * row[column] }

            let probability = LogisticMath.sigmoid(score)
            let weight = weights[index]
            let residual = weight * (probability - (labels[index] ? 1 : 0))
            let curvature = weight * probability * (1 - probability)

            for column in 0..<width { gradient[column] += residual * row[column] }
            gradient[width] += residual

            // Upper triangle only; mirrored below rather than accumulated twice.
            for outer in 0..<width {
                let scaled = curvature * row[outer]
                for inner in outer..<width { hessian[outer][inner] += scaled * row[inner] }
                hessian[outer][width] += scaled
            }
            hessian[width][width] += curvature
        }

        // The ridge, on the coefficients and never on the intercept.
        for column in 0..<width {
            gradient[column] += lambda * beta[column]
            hessian[column][column] += lambda
        }
        for outer in 0..<size {
            for inner in 0..<outer { hessian[outer][inner] = hessian[inner][outer] }
        }
        // A jitter invisible next to `lambda`, which keeps a column that happened to be
        // constant in this fold from making the whole system unsolvable.
        for index in 0..<size { hessian[index][index] += 1e-10 }

        return (gradient, hessian)
    }

    private static func objective(_ design: [[Double]],
                                  _ labels: [Bool],
                                  _ weights: [Double],
                                  _ beta: [Double],
                                  _ lambda: Double) -> Double {
        let width = design[0].count
        var loss = 0.0

        for (index, row) in design.enumerated() {
            var score = beta[width]
            for column in 0..<width { score += beta[column] * row[column] }
            // log(1 + e^score) evaluated on the stable side, then the label term.
            let softplus = score > 0 ? score + log1p(exp(-score)) : log1p(exp(score))
            loss += weights[index] * (softplus - (labels[index] ? score : 0))
        }

        let penalty = (0..<width).reduce(0.0) { $0 + beta[$1] * beta[$1] }
        return loss + 0.5 * lambda * penalty
    }

    static func median(of values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }

        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
    }
}
