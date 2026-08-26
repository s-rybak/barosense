import Foundation

/// One stage of the risk model: a linear fit and, where the number has to mean something, the
/// correction that makes it a frequency.
struct RiskStage: Hashable, Sendable, Codable {

    let model: LogisticRegressionModel

    /// `nil` where the stage is used for **ranking only**, in which case the raw logistic is
    /// enough and a correction would be two more parameters fitted for no consumer. The window
    /// stage is that case: nothing compares its output to a fixed number, only to itself.
    let calibration: PlattCalibration?

    /// Which columns the model reads, in its own order. Carried so a stage cannot be handed a
    /// vector assembled for a different one — the failure that produces a plausible number
    /// from the wrong features and no error anywhere.
    let columns: [RiskFeature]

    func decision(of row: RiskWindowRow) -> Double {
        model.decision(row.vector(columns))
    }

    func probability(of row: RiskWindowRow) -> Double {
        let raw = decision(of: row)
        guard let calibration else { return LogisticMath.sigmoid(raw) }
        return calibration.probability(ofDecision: raw)
    }
}

/// The two-stage forecast: whether today holds an entry, and — if it does — when.
///
/// ## Why two models and not one
///
/// One model over windows answers both questions at once and answers neither well. The
/// evidence is in the features: the day-level columns are constant inside a day, so they cannot
/// rank one window above another (window features alone reach hit@1 = 0.43; day features alone
/// 0.11, at ROC-AUC 0.535, which is a coin). Fitting them together lets a strong day signal
/// raise every window of that day equally and read as confidence about *when*.
///
/// Split apart, each has its own question, its own rows and its own metric:
///
/// - **day** — one row per day, day-level columns only, calibrated, and the only number on
///   screen expressed as a percentage;
/// - **window** — one row per window, all columns, trained **only on days that held an entry**,
///   which turns it into pure ranking with a fixed 1-in-9 base rate instead of one that moves
///   with how often the user logs at all.
///
/// They combine by multiplication where a joint figure is wanted, because that is what the two
/// questions compose to: `P(entry in this window) = P(entry today) × P(this window | entry)`.
///
/// ## The gate — the app's right to say nothing
///
/// The third piece, and the one that is easiest to leave out. A model that has an opinion every
/// day produces a message every day, and at precision 0.52 those messages get switched off.
/// `gateThreshold` is the confidence the **window** stage must reach before the app speaks at
/// all; below it there is no message, and the chart carries on regardless.
///
/// Which stage holds the gate is measured, not assumed, and the answer is counter-intuitive.
/// See `WellbeingRiskPrior.gateThreshold`.
struct WellbeingRiskModel: Hashable, Sendable, Codable {

    /// `k` in `w(n) = n / (n + k)` — how fast this user's own history takes over from the
    /// shipped prior.
    ///
    /// **30** labelled entries, *provisional*, and the one place it is written.
    ///
    /// `n` is `labelledEntryCount`: entries that landed in a window of a day the fit could
    /// use — inside the 120-day training window, covered well enough to clear
    /// `RiskWindowBuilder.minimumDayCoverage`, and behind `now`. That is **not** what
    /// `TrainingDataProgress` counts on the Now screen, and the two cannot be made equal: the
    /// card has to draw a number before any fit has run, so it counts stored check-ins, all
    /// time, which is always the larger of the two. The card's own target (40) is set from
    /// this constant — `40 / (40 + 30) = 0.57`, the first point past the halfway mark — so the
    /// bar and the blend agree about *where the line is* while counting toward it differently.
    /// Changing `k` moves that target with it.
    static let priorBlendConstant: Double = 30

    /// Calibrated day probability at or above which the chart is allowed to name windows.
    ///
    /// **0.5**, and the reason it can be a round number is the calibration: after Platt, a half
    /// is a statement about frequency — days scoring above it hold an entry more often than not.
    /// Against the raw balanced-weight output the same 0.5 would be an arbitrary point on an
    /// arbitrary scale.
    ///
    /// This is the "quiet day" filter, and it is deliberately far below `gateThreshold`. Being
    /// wrong on the chart costs a stripe the user glances past; being wrong in a notification
    /// costs the notification.
    static let dayDisplayThreshold: Double = 0.5

    /// How many windows the chart marks.
    ///
    /// **Two**, which at two hours each is a four-hour stretch when they are adjacent. One
    /// window contains the entry on 38% of days that hold one, two on 57%, against 11% and 22%
    /// for picking at random. The second window buys 19 points of coverage for two more hours
    /// of stripe, and below roughly half the marked stretch stops being worth looking at.
    static let markedWindowCount = 2

    /// The gate threshold used when no run has measured one on this device's own scale.
    ///
    /// **2** — above any probability, so the gate never opens and the app stays quiet. Not `1`:
    /// a saturated sigmoid returns exactly 1 in `Double`, and `>=` would then fire on it.
    static let unreachableGateThreshold: Double = 2

    /// The stage the forecast starts from, before this user's own fit is blended in.
    ///
    /// Normally the shipped prior. With `WellbeingRiskPrior.isEnabled` off there is no prior to
    /// start from, so this holds the user's own fit standing alone and `personalDay` is `nil` —
    /// the blend is a no-op and no shipped coefficient reaches a screen. `blending` is the only
    /// thing that decides which of the two it is.
    let day: RiskStage
    let window: RiskStage

    /// This user's own fit, `nil` until there is enough history for one. Same columns as the
    /// stage it blends with, except the window stage — see `RiskFeature.personalWindowColumns`.
    let personalDay: RiskStage?
    let personalWindow: RiskStage?

    /// `w(n)`. Zero on a device that has never fitted; one is unreachable by construction.
    let personalWeight: Double

    /// Confidence the window stage must reach before a notification is allowed.
    let gateThreshold: Double

    let dayStartHour: Int

    /// Entries that landed in a usable window — the `n` behind `personalWeight`, and not the
    /// count the Now screen's bar draws. See `priorBlendConstant`.
    let labelledEntryCount: Int

    let trainedAt: Date

    /// True while the forecast is mostly the shipped prior speaking.
    ///
    /// Drawn in the UI as reduced confidence, per §4. Two ways to be in that state, and `n`
    /// alone only catches the first:
    ///
    /// 1. `w(n) < 0.5` — the ordinary one, and the boundary is `n = k` by construction;
    /// 2. **a stage that could not be fitted at all**, whatever `n` is. A user who logs every
    ///    day gives the day stage no negative class, `LogisticRegressionFitter` refuses, and
    ///    `blend` falls through to the prior — a 100%-prior figure carrying a personal weight
    ///    of 0.8. Without this clause the "still learning your pattern" disclosure disappears
    ///    exactly where it is most needed, which is a compliance problem and not only a bug.
    ///
    /// Reads the prior switch because with the prior off there is no prior to lean on: the
    /// stages are this user's own and a cold-start disclosure would be false.
    var isColdStart: Bool {
        guard WellbeingRiskPrior.isEnabled else { return false }
        guard personalDay != nil, personalWindow != nil else { return true }

        return personalWeight < 0.5
    }

    /// The shipped prior alone, for a device with no history at all.
    ///
    /// `nil` when the prior is switched off — that device shows no forecast until it has a fit
    /// of its own, which is what the switch is for.
    static func prior(dayStartHour: Int = RiskWindowGeometry.defaultDayStartHour,
                      trainedAt: Date) -> WellbeingRiskModel? {
        blending(personalDay: nil,
                 personalWindow: nil,
                 labelledEntryCount: 0,
                 dayStartHour: dayStartHour,
                 trainedAt: trainedAt)
    }

    /// A model composed out of whatever this device has, or `nil` when that is nothing.
    ///
    /// **The only place that knows what `WellbeingRiskPrior.isEnabled` means.** It used to be
    /// read at one call site out of four, which left the switch unable to do the thing its own
    /// comment promised: `prior(...)` and both stage constructions ignored it, so a cold-start
    /// device kept getting the full shipped prior with the switch off.
    ///
    /// - prior **on**: the shipped stages, with the personal fits blended into them by `w(n)`;
    /// - prior **off**: the personal fits *become* the stages, the blend weight is zero, and a
    ///   device missing either of them gets no model at all rather than a synthetic one.
    static func blending(personalDay: RiskStage?,
                         personalWindow: RiskStage?,
                         labelledEntryCount: Int,
                         dayStartHour: Int,
                         trainedAt: Date) -> WellbeingRiskModel? {
        guard WellbeingRiskPrior.isEnabled else {
            guard let personalDay, let personalWindow else { return nil }

            return WellbeingRiskModel(
                day: personalDay,
                window: personalWindow,
                personalDay: nil,
                personalWindow: nil,
                personalWeight: 0,
                // The shipped threshold is a point on the prior's scale and this model is not
                // on it. Quiet until a validation run measures one here.
                gateThreshold: unreachableGateThreshold,
                dayStartHour: dayStartHour,
                labelledEntryCount: labelledEntryCount,
                trainedAt: trainedAt
            )
        }

        return WellbeingRiskModel(
            day: RiskStage(model: WellbeingRiskPrior.day,
                           calibration: WellbeingRiskPrior.dayCalibration,
                           columns: RiskFeature.dayColumns),
            window: RiskStage(model: WellbeingRiskPrior.window,
                              calibration: nil,
                              columns: RiskFeature.windowColumns),
            personalDay: personalDay,
            personalWindow: personalWindow,
            personalWeight: priorBlendWeight(labelledEntryCount: labelledEntryCount),
            gateThreshold: WellbeingRiskPrior.gateThreshold,
            dayStartHour: dayStartHour,
            labelledEntryCount: labelledEntryCount,
            trainedAt: trainedAt
        )
    }

    /// The same model gated at a threshold measured on this device's own scale.
    func withGateThreshold(_ threshold: Double) -> WellbeingRiskModel {
        WellbeingRiskModel(day: day,
                           window: window,
                           personalDay: personalDay,
                           personalWindow: personalWindow,
                           personalWeight: personalWeight,
                           gateThreshold: threshold,
                           dayStartHour: dayStartHour,
                           labelledEntryCount: labelledEntryCount,
                           trainedAt: trainedAt)
    }

    /// `w(n) = n / (n + k)`.
    static func priorBlendWeight(labelledEntryCount count: Int) -> Double {
        let n = Double(max(count, 0))
        return n / (n + priorBlendConstant)
    }

    // MARK: - Scoring

    /// Calibrated probability that this day holds an entry.
    ///
    /// The day stage reads day-level columns, which are identical across every row of a day, so
    /// any row of the day answers for all of them.
    func dayProbability(for row: RiskWindowRow) -> Double {
        blend(prior: day.probability(of: row), personal: personalDay?.probability(of: row))
    }

    /// How strongly this window is preferred over the others of its day.
    ///
    /// A ranking, not a frequency, and deliberately not presented as one. It is compared with
    /// `gateThreshold` and with the other windows of the same day, and with nothing else.
    func windowConfidence(for row: RiskWindowRow) -> Double {
        blend(prior: window.probability(of: row), personal: personalWindow?.probability(of: row))
    }

    /// Blends in log-odds rather than in probability.
    ///
    /// Averaging two probabilities directly pulls every result toward the middle: 0.02 and 0.30
    /// average to 0.16, which is a stronger claim than either model made. Log-odds is the space
    /// both models are linear in, so the blend is a weighted vote between two linear opinions
    /// and a confident, agreeing pair stays confident.
    private func blend(prior: Double, personal: Double?) -> Double {
        guard let personal, personalWeight > 0 else { return prior }

        let mixed = (1 - personalWeight) * logit(prior) + personalWeight * logit(personal)
        return LogisticMath.sigmoid(mixed)
    }

    /// The same model with the day stage's Platt correction removed.
    ///
    /// For measurement only, so a run can report what the correction was worth rather than
    /// assert it. Nothing on a user-facing path calls this.
    func withoutDayCalibration() -> WellbeingRiskModel {
        WellbeingRiskModel(
            day: RiskStage(model: day.model, calibration: nil, columns: day.columns),
            window: window,
            personalDay: personalDay.map {
                RiskStage(model: $0.model, calibration: nil, columns: $0.columns)
            },
            personalWindow: personalWindow,
            personalWeight: personalWeight,
            gateThreshold: gateThreshold,
            dayStartHour: dayStartHour,
            labelledEntryCount: labelledEntryCount,
            trainedAt: trainedAt
        )
    }

    private func logit(_ probability: Double) -> Double {
        let clamped = min(max(probability, 1e-9), 1 - 1e-9)
        return log(clamped / (1 - clamped))
    }
}
