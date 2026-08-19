import Foundation

/// The forecast the app can make from the user's own barometer alone.
///
/// ## Why this is small on purpose
///
/// One sensor at one point cannot see advection. It has no way to know about a front 200 km
/// away, and no amount of history changes that — a five-year log and a five-day log are equally
/// blind to weather that has not arrived yet. On 1–3 h horizons linear extrapolation is close to
/// unbeatable; past that, skill decays toward climatology.
///
/// So the range is **3–6 h** with a band that opens fast, and that is a decision confirmed by a
/// human rather than a default to be improved on. An agent minded to "finish it off to 24 hours"
/// has to re-read `.claude/context/pressure-forecast-spec.md` §4.7 and produce a measurement
/// first.
///
/// ## Why AR(3) + two harmonics and not Core ML
///
/// The model has one thing to know that persistence does not: the **solar semidiurnal tide**,
/// `S2`. It is deterministic, it follows from the time of day, and at Kyiv's latitude it is
/// order 0.3–0.5 hPa (*provisional* — a literature order of magnitude, to be checked against
/// real traces). Below the 1.0 hPa threshold this app treats as meaningful, but it is free skill
/// that persistence cannot have. Three autoregressive lags carry the local trend and its
/// curvature.
///
/// Eight parameters, closed-form least squares, a 30-day window of 720 hourly points: about
/// **46 000 multiply-adds**, which is microseconds. A daily refit therefore needs **no new wake
/// source** and fits inside a foreground activation — `CLAUDE.md` constraint 4 satisfied by
/// there being nothing to schedule.
///
/// `MLUpdateTask` and Core ML stay in reserve for the day a measurement shows linearity is the
/// binding constraint. Starting with them would be paying for machinery that holds nothing yet.
struct LocalPressureModel: Sendable {

    /// Autoregressive order: the value depends on the three preceding hours.
    ///
    /// Three carries level, slope and curvature — enough for the shape of a passing ridge or
    /// trough. A fourth lag buys little at these horizons and costs a parameter out of a budget
    /// that is already tight on one day of data.
    static let autoregressiveOrder = 3

    /// How much history the fit sees.
    ///
    /// **30 days**, 720 hourly cells. Long enough for the diurnal harmonics to be identifiable
    /// against weather noise, short enough that a seasonal change in their amplitude is not
    /// averaged into a year-round compromise — and short enough that the fit stays microseconds.
    static let trainingWindowDays = 30

    /// Rows below which no fit is attempted.
    ///
    /// **12.** Eight parameters against fewer rows than that is memorisation with a ridge term
    /// holding it up. Twelve is reachable on a **single day** of data — 24 hourly cells minus
    /// three lost to the lags — which is the cold-start requirement this model exists to meet.
    static let minimumTrainingRows = 12

    /// How often the fit is renewed. Daily: the coefficients move on the timescale of the
    /// weather regime, not of an activation.
    static let refitIntervalSeconds: TimeInterval = 24 * 3600

    /// Ridge term, relative to the mean diagonal of the normal matrix.
    ///
    /// Tiny, and not there for regularisation in the statistical sense. It is there so that a
    /// perfectly flat log — a phone on a desk in stable air — produces a solvable system
    /// instead of a singular one. Without it the §8 zero-variance fixture crashes rather than
    /// degrading.
    static let ridge: Double = 1e-6

    /// The residual spread a band of nominal width is quoted against. Above this, the band is
    /// inflated in proportion.
    static let referenceResidualHPa: Double = 0.8

    /// Coverage below which the band stops widening further, so a nearly empty log produces a
    /// very wide band rather than an infinite one.
    static let minimumCoverageForBand: Double = 0.2

    /// `[intercept, lag1, lag2, lag3, sinS1, cosS1, sinS2, cosS2]`, fitted on centred values.
    let coefficients: [Double]

    /// Mean of the training targets, added back on prediction.
    ///
    /// Centring is not cosmetic: pressure sits near 1000 and the harmonics near 1, so an
    /// uncentred normal matrix spans six orders of magnitude and the solve loses most of its
    /// precision to it.
    let mean: Double

    /// Root-mean-square one-step residual, hPa. What the band is scaled from.
    let residualStandardDeviationHPa: Double

    /// Fraction of the training window actually observed. Feeds the band, so a log full of
    /// holes produces a visibly less certain forecast rather than a confident one.
    let coverage: Double

    let rowCount: Int

    /// The hour the fit ends at — the last cell it saw. Predictions step forward from here.
    let lastHour: Date

    /// The three most recent values, newest last. The seed for the forward iteration.
    let recentValues: [Double]

    let fittedAt: Date
}

extension LocalPressureModel {

    /// Fits the model, or `nil` when there is not enough to fit.
    ///
    /// `nil` is an ordinary outcome — a fresh install, a phone that was off — and the caller's
    /// answer to it is to draw no forward half at all. A model fitted on four points would
    /// produce a line, and a line is a claim.
    ///
    /// Pure and synchronous: §8 requires the pipeline to run from XCTest with synthetic input
    /// and no `CMAltimeter` anywhere.
    static func fit(to samples: [PressureSample],
                    asOf now: Date,
                    windowDays: Int = trainingWindowDays) -> LocalPressureModel? {
        let window = now.addingTimeInterval(-TimeInterval(windowDays) * 24 * 3600)..<now
            .addingTimeInterval(3600)
        let cells = HourlyPressureGrid.cells(from: samples, in: window)
        guard cells.count > autoregressiveOrder else { return nil }

        let values = cells.map(\.hectopascals)
        let mean = values.reduce(0, +) / Double(values.count)

        var design: [[Double]] = []
        var targets: [Double] = []

        for index in autoregressiveOrder..<cells.count {
            // Lags have to be *consecutive hours*. A row whose lags straddle a hole would be
            // telling the fit that a twelve-hour jump was a one-hour step, which is how a gap
            // becomes a learned trend.
            let span = cells[index].hour.timeIntervalSince(cells[index - autoregressiveOrder].hour)
            guard abs(span - Double(autoregressiveOrder) * 3600) < 1 else { continue }

            design.append(row(lags: (1...autoregressiveOrder).map { values[index - $0] - mean },
                              hour: cells[index].hour))
            targets.append(values[index] - mean)
        }

        guard design.count >= minimumTrainingRows,
              let coefficients = solveNormalEquations(design: design, targets: targets)
        else {
            return nil
        }

        let residuals = zip(design, targets).map { row, target in
            target - dot(coefficients, row)
        }
        let residualSD = (residuals.reduce(0) { $0 + $1 * $1 } / Double(residuals.count)).squareRoot()

        let recent = cells.suffix(autoregressiveOrder).map(\.hectopascals)
        guard let lastHour = cells.last?.hour, recent.count == autoregressiveOrder else {
            return nil
        }

        return LocalPressureModel(
            coefficients: coefficients,
            mean: mean,
            residualStandardDeviationHPa: residualSD,
            coverage: HourlyPressureGrid.coverage(of: cells, in: window),
            rowCount: design.count,
            lastHour: lastHour,
            recentValues: recent,
            fittedAt: now
        )
    }

    /// The forward curve, hourly, from the first whole hour after `now`.
    ///
    /// Clipped to `ForecastSource.localModel.rangeSeconds` whatever is asked for. A caller that
    /// wants 24 hours gets 6, silently and on purpose: the range is a property of what a single
    /// barometer can know, not a parameter.
    ///
    /// Predictions are fed back in as lags, which is what makes the band's growth the honest
    /// shape — each step inherits the previous step's error as well as its own.
    func forecast(asOf now: Date, horizonSeconds: TimeInterval) -> [ForecastPressurePoint] {
        let horizon = min(horizonSeconds, ForecastSource.localModel.rangeSeconds)
        guard horizon >= 3600 else { return [] }

        var lags = recentValues.reversed().map { $0 - mean }
        var hour = lastHour
        var points: [ForecastPressurePoint] = []

        while true {
            hour = hour.addingTimeInterval(3600)
            let lead = hour.timeIntervalSince(now)
            if lead > horizon { break }

            let predicted = dot(coefficients,
                                Self.row(lags: lags, hour: hour))
            lags = [predicted] + lags.dropLast()

            // Hours already past — the log's last cell can be a couple of hours old — are
            // stepped through to carry the lags forward, but never drawn: they are not a
            // forecast, they are a gap the sensor left.
            guard lead > 0 else { continue }

            points.append(ForecastPressurePoint(
                timestamp: hour,
                pressure: Pressure(hectopascals: predicted + mean),
                uncertaintyHPa: uncertaintyHPa(atLeadSeconds: lead),
                source: .localModel,
                // A local forecast is knowable the moment it is computed, which is `now`. Any
                // earlier stamp would let a feature at `t` read a curve the device had not
                // fitted yet — the same leak the archive's `issuedAt` guards against.
                issuedAt: now
            ))
        }

        return points
    }

    /// Band half-width at a lead time, hPa.
    ///
    /// The source's nominal band, inflated by two things the fit actually measured: how badly
    /// it fits its own history, and how much of that history was there. A log with a
    /// twelve-hour hole in it produces a visibly wider band, which is the point — the model
    /// knows less, and the chart says so.
    func uncertaintyHPa(atLeadSeconds lead: TimeInterval) -> Double {
        let nominal = ForecastSource.localModel.uncertaintyHPa(atLeadSeconds: lead)
        let residualInflation = max(1, residualStandardDeviationHPa
                                    / LocalPressureModel.referenceResidualHPa)
        let coverageInflation = 1 / max(coverage, LocalPressureModel.minimumCoverageForBand)

        return nominal * residualInflation * coverageInflation
    }

    /// Whether this fit is old enough to be worth renewing.
    func isStale(asOf now: Date) -> Bool {
        now.timeIntervalSince(fittedAt) >= LocalPressureModel.refitIntervalSeconds
    }

    // MARK: - The fit itself

    /// One design row: intercept, lags, and the two diurnal harmonics.
    ///
    /// `lags` is newest-first. The harmonics are functions of the hour being predicted, not of
    /// the lags, which is what lets the model carry a time-of-day shape through a forward
    /// iteration where the lags are its own output.
    private static func row(lags: [Double], hour: Date) -> [Double] {
        // Hour of day as a fraction, from the epoch. UTC rather than the user's calendar: S1
        // and S2 are solar tides and their phase is a property of the sun's position, and a
        // model refitted after a time-zone change must not have its harmonics jump by an hour.
        let secondsIntoDay = hour.timeIntervalSince1970.truncatingRemainder(dividingBy: 86_400)
        let angle = 2 * Double.pi * secondsIntoDay / 86_400

        return [1] + lags + [sin(angle), cos(angle), sin(2 * angle), cos(2 * angle)]
    }

    private static func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        zip(lhs, rhs).reduce(0) { $0 + $1.0 * $1.1 }
    }

    private func dot(_ lhs: [Double], _ rhs: [Double]) -> Double {
        LocalPressureModel.dot(lhs, rhs)
    }

    /// `(XᵀX + λI) β = Xᵀy`, solved by Gaussian elimination with partial pivoting.
    ///
    /// Eight by eight. Building `XᵀX` costs `rows × 64` multiply-adds — about 46 000 over a
    /// 30-day window — and the solve is a fixed ~340. There is no library call here worth the
    /// dependency, and Accelerate would not measurably beat it at this size.
    private static func solveNormalEquations(design: [[Double]], targets: [Double]) -> [Double]? {
        guard let width = design.first?.count, width > 0 else { return nil }

        var normal = [[Double]](repeating: [Double](repeating: 0, count: width), count: width)
        var moment = [Double](repeating: 0, count: width)

        for (row, target) in zip(design, targets) {
            for i in 0..<width {
                moment[i] += row[i] * target
                for j in i..<width {
                    normal[i][j] += row[i] * row[j]
                }
            }
        }
        // Symmetric, so only the upper triangle was accumulated.
        for i in 0..<width where i > 0 {
            for j in 0..<i {
                normal[i][j] = normal[j][i]
            }
        }

        let meanDiagonal = (0..<width).reduce(0) { $0 + normal[$1][$1] } / Double(width)
        for i in 0..<width {
            normal[i][i] += ridge * max(meanDiagonal, 1)
        }

        return gaussianSolve(matrix: &normal, vector: &moment, width: width)
    }

    private static func gaussianSolve(matrix: inout [[Double]],
                                      vector: inout [Double],
                                      width: Int) -> [Double]? {
        for column in 0..<width {
            // Partial pivoting. Without it a near-zero leading coefficient — an entirely
            // plausible outcome on a flat log — turns the elimination into noise.
            guard let pivot = (column..<width).max(by: { abs(matrix[$0][column]) < abs(matrix[$1][column]) }),
                  abs(matrix[pivot][column]) > 1e-12
            else {
                return nil
            }

            if pivot != column {
                matrix.swapAt(pivot, column)
                vector.swapAt(pivot, column)
            }

            for row in (column + 1)..<width {
                let factor = matrix[row][column] / matrix[column][column]
                guard factor != 0 else { continue }
                for inner in column..<width {
                    matrix[row][inner] -= factor * matrix[column][inner]
                }
                vector[row] -= factor * vector[column]
            }
        }

        var solution = [Double](repeating: 0, count: width)
        for row in stride(from: width - 1, through: 0, by: -1) {
            var accumulated = vector[row]
            for column in (row + 1)..<width {
                accumulated -= matrix[row][column] * solution[column]
            }
            solution[row] = accumulated / matrix[row][row]
            guard solution[row].isFinite else { return nil }
        }

        return solution
    }
}
