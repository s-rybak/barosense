import Foundation

/// The trivial predictors the learned model has to beat before it is worth its battery.
///
/// §7 of `ml-spec.md` names three; the fourth is the notebook's own and is the sharpest of
/// them. A model that cannot beat a lookup table of "which window does this person usually log
/// in" has not demonstrated a *weather* signal, whatever its PR-AUC says.
enum RiskBaseline: String, Hashable, Sendable, Codable, CaseIterable {

    /// Predict the base rate everywhere. The floor: PR-AUC equal to the base rate by
    /// construction, ROC-AUC exactly 0.5.
    case majorityClass

    /// "Pressure fell more than X hPa in six hours", X tuned on the training half of each fold
    /// alone. The rule a person could apply with a barometer and no model at all.
    case pressureRule

    /// Frequency of entries per window index, learned on the training half. The control that
    /// asks whether the model is reading the weather or reading the clock.
    case timeOfDay

    /// Repeat the last day that held an entry: score 1 for the window index that entry fell in.
    /// "Yesterday again", the honest baseline for anything autocorrelated.
    case persistence
}

/// Everything the forward-chaining run measured. Written to the log, never to the screen.
///
/// It is `Codable` so a run survives a relaunch and a later run can be compared with it, and
/// deliberately not `LocalizedStringKey`-anything: no field here has a rendering, because
/// showing the user an accuracy figure is a claim about how well the app knows them and needs
/// a human decision before it appears anywhere (`.claude/skills/appstore_compliance/SKILL.md`).
struct RiskModelReport: Hashable, Sendable, Codable {

    /// One stage's out-of-fold scores.
    struct Stage: Hashable, Sendable, Codable {
        let rocAUC: Double?
        /// Read against `baseRate` and never on its own — PR-AUC is not comparable across
        /// datasets with different positive shares.
        let prAUC: Double?
        let baseRate: Double
        /// `nil` for a stage used only for ranking, where a calibration number would be
        /// measuring something nothing consumes.
        let brier: Double?

        /// The same stage's Brier score **before** the Platt correction.
        ///
        /// Carried so the correction can be shown to have earned its place rather than assumed
        /// to. `nil` wherever `brier` is.
        let uncalibratedBrier: Double?

        let rowCount: Int
        let positiveCount: Int

        /// PR-AUC as a multiple of the base rate. 1.0 is the majority-class floor.
        var lift: Double? {
            guard let prAUC, baseRate > 0 else { return nil }
            return prAUC / baseRate
        }

        /// What always answering the base rate scores on Brier: `p(1 − p)`.
        ///
        /// The floor the day stage has to clear before its percentage is worth more than a
        /// constant, and it is a **hard** floor to clear when the base rate is lopsided — at
        /// 0.88 it is 0.103, and a model has to be genuinely discriminating to beat that.
        var constantBrier: Double { baseRate * (1 - baseRate) }

        /// Whether the calibrated probability beats simply answering the base rate.
        ///
        /// `false` is a result to report, not to hide: it means the percentage is worth less
        /// than a constant on this history, even where the stage still ranks days correctly.
        var beatsConstantBrier: Bool? {
            guard let brier else { return nil }
            return brier < constantBrier
        }
    }

    struct BaselineScore: Hashable, Sendable, Codable {
        let baseline: RiskBaseline
        let prAUC: Double?
        let rocAUC: Double?
        let hitAtOne: Double?
    }

    /// How the gate performed at the threshold the run chose.
    struct GateScore: Hashable, Sendable, Codable {
        let threshold: Double
        let messagesPerWeek: Double
        /// Share of days the app spoke on where an entry did land in a marked window.
        let precision: Double?
        /// Wilson 95%. Quoted with the point estimate always — on twenty-odd fired days the
        /// point estimate alone reads as a far stronger claim than the run supports.
        let precisionInterval: ClosedRange<Double>?
        /// Share of all entries that arrived with a message. Low by design.
        let recall: Double?
        let firedDayCount: Int
        let evaluatedDayCount: Int
    }

    let evaluatedAt: Date

    let dayCount: Int
    let loggedDayCount: Int
    let foldCount: Int

    let day: Stage
    let window: Stage

    /// Share of days holding an entry where it fell in the single highest-ranked window.
    let hitAtOne: Double?
    /// The same for the two windows the chart actually marks.
    let hitAtTwo: Double?

    /// What picking windows at random scores — `k / windowsPerDay`. The only honest thing to
    /// read `hitAtOne` against.
    let randomHitAtOne: Double
    let randomHitAtTwo: Double

    /// Days with no entry, excluded from every hit rate. Reported rather than averaged away,
    /// per §5.
    let daysWithoutEntry: Int

    let baselines: [BaselineScore]
    let gate: GateScore

    /// Whether the window stage's PR-AUC beat every baseline that could be scored.
    ///
    /// False is a publishable result, not a failure to hide: a model that loses to a threshold
    /// rule costs battery and adds risk for nothing, and the PR body has to say so.
    var beatsEveryBaseline: Bool {
        guard let learned = window.prAUC else { return false }
        return baselines.allSatisfy { ($0.prAUC ?? 0) < learned }
    }

    /// One line per fact, for `BarosenseLog`. No health values, no check-in contents — counts,
    /// rates and metrics only.
    var logLines: [String] {
        var lines = [
            "days=\(dayCount) logged=\(loggedDayCount) folds=\(foldCount)",
            format("day", day) + " brier=" + number(day.brier)
                + " (uncalibrated " + number(day.uncalibratedBrier)
                + ", constant " + number(day.constantBrier)
                + ", beats-constant=" + (day.beatsConstantBrier.map(String.init) ?? "—") + ")",
            format("window", window) + " lift=" + number(window.lift),
            "hit@1=\(number(hitAtOne))/\(number(randomHitAtOne)) "
                + "hit@2=\(number(hitAtTwo))/\(number(randomHitAtTwo)) "
                + "quiet-days-excluded=\(daysWithoutEntry)"
        ]
        for score in baselines {
            lines.append("baseline \(score.baseline.rawValue): pr=\(number(score.prAUC)) "
                + "roc=\(number(score.rocAUC)) hit@1=\(number(score.hitAtOne))")
        }
        lines.append("gate threshold=\(number(gate.threshold)) "
            + "msgs/wk=\(number(gate.messagesPerWeek)) "
            + "precision=\(number(gate.precision)) "
            + "[\(number(gate.precisionInterval?.lowerBound)), "
            + "\(number(gate.precisionInterval?.upperBound))] "
            + "recall=\(number(gate.recall)) fired=\(gate.firedDayCount)/\(gate.evaluatedDayCount)")
        lines.append("beats-every-baseline=\(beatsEveryBaseline)")
        return lines
    }

    private func format(_ label: String, _ stage: Stage) -> String {
        "\(label): n=\(stage.rowCount) pos=\(stage.positiveCount) "
            + "base=\(number(stage.baseRate)) roc=\(number(stage.rocAUC)) pr=\(number(stage.prAUC))"
    }

    private func number(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "—" }
        return String(format: "%.3f", value)
    }
}
