import Foundation

/// The population prior: the two stages as they were fitted in the research notebook, shipped
/// as constants so a device with no history of its own still has something to say.
///
/// ## What these numbers are
///
/// The output of `barosense-final-model.ipynb` on a 120-day, 15-minute synthetic trace — one
/// simulated person, 89 self-reports, forward-chaining validation throughout. They are the day
/// model's four coefficients with its Platt pair, the window model's nine, and the operating
/// point the notebook settled on.
///
/// ## What they are not
///
/// They are not a population. They are one synthetic person, and the generator that produced
/// them was written with an explicit barometric effect in it — a 10 hPa fall over six hours
/// makes a slot roughly three thousand times likelier to hold an entry. Numbers measured
/// against that are a **ceiling**, not an estimate of what this app will do for a real user.
///
/// This is `ml-spec.md` §9 question 1 answered in its second form — "a small hand-specified
/// prior, clearly labelled as a guess" — and the label is this paragraph. Two consequences that
/// are not negotiable:
///
/// 1. The prior's own base rate is **0.75 of days holding an entry**, which is a property of
///    how the synthetic person was written, not of anybody real. `intercept` carries it. A user
///    who logs twice a week will be over-estimated until their own fit takes over, which is
///    what the blend weight in `WellbeingRiskModel` is for and why it moves as fast as it does.
/// 2. Nothing here may be quoted on screen as a measured accuracy. The figures in this file's
///    comments exist to be checked against the notebook, not to be rendered.
enum WellbeingRiskPrior {

    /// Whether the shipped prior is used at all.
    ///
    /// The feature flag `swift_conventions` asks for on anything that changes forecast output.
    /// Off, the app has a personal model or it has nothing, and cold-start devices show no
    /// forecast rather than a synthetic one.
    static let isEnabled = true

    /// Chance that a day holds an entry. Four day-level columns, one row per day.
    static let day = LogisticRegressionModel(
        medians: [0.33854166666666546, 0.9778125000000024, 1.3703125000000078, 0.0],
        mean: [3.8597102591036423, 1.418986344537815, 3.1618741246498603, 3.1951689104206267],
        scale: [6.848890066534658, 1.1783542830259288, 4.059478705103588, 5.862532507220165],
        coefficients: [0.24032384015083422, 0.956096662324671,
                       0.19475741339466277, 0.8295918074728577],
        intercept: 0.4555626836293463
    )

    /// The correction that makes the day model's output a frequency rather than a ranking.
    ///
    /// Fitted on forward-chained out-of-fold decisions. Brier 0.174 → 0.117 on the notebook's
    /// own folds; ROC-AUC essentially unchanged at 0.771 → 0.779.
    static let dayCalibration = PlattCalibration(slope: 1.0443190412515233,
                                                 intercept: 1.0018538233052257)

    /// Which window, given that a day holds an entry. All nine columns.
    ///
    /// Read the two largest coefficients together, because their signs are the finding:
    /// `drop6hHPa` **+1.346** against `dayDrop6hHPa` **−1.244**. The model is not looking for a
    /// large six-hour fall. It is looking for a fall that exceeds *today's own average* — which
    /// is exactly the shape of a question about **when inside a day**, and exactly what the
    /// day-level columns cannot answer, being constant across it.
    static let window = LogisticRegressionModel(
        medians: [1013.13, 0.2149999999999892, 0.43250000000001876, 0.7787499999999881, 0.0,
                  1.0064583333333321, 1.385833333333333, 2.087291666666657,
                  0.03611033606150945],
        mean: [1011.8708551810244, 4.700171660424472, 1.5117524968789005, 3.8844444444444464,
               3.9857154581367666, 4.614999999999998, 1.62578183520599, 3.737680243445702,
               4.008357356934128],
        scale: [10.899647905493737, 7.760627540796076, 2.127472005540163, 5.368235128252171,
                6.35879873720183, 7.498300270552676, 1.253770830080001, 4.413105878913286,
                6.382527831604332],
        coefficients: [-0.23566782267817968, -0.06004461500147542, 1.3464376536613558,
                       0.15704248160992207, 0.04245317017870892, 0.08291652665122788,
                       -1.2443461569447387, 0.08281263526456355, -0.040423171652734624],
        intercept: -0.49701337709587023
    )

    /// The gate: how sure the **window** model has to be before the app is allowed to speak.
    ///
    /// **0.848**, which on the notebook's folds is the 65th percentile of the per-day best
    /// window score — the app stays quiet on roughly two days in three.
    ///
    /// Why the window model and not the day model holds the gate is the least obvious result in
    /// the notebook and the simplest to state. Being right decomposes into
    /// `P(entry today) × P(named the right window)`. The first factor is already 0.75, so
    /// filtering days by it removes nearly as many good days as bad ones — measured precision
    /// 0.60 against 0.52 with no gate at all. The second factor is the bottleneck, and only the
    /// window model's own confidence says anything about it. Gated there: **2.4 messages a week
    /// at precision 0.857**, 95% CI [0.65, 0.95] on 21 messages.
    ///
    /// The price is recall **0.34** — two entries in three arrive with no warning. That is the
    /// right trade for an interruption and the wrong one for a chart, which is why the chart
    /// does not use this number.
    ///
    /// What a personal fit reproduces is the **rate**, not this number: a fitted model has its
    /// own scale, so carrying 0.848 across would gate at whatever share of days that value
    /// happened to land on for that user. The rate has one source,
    /// `WellbeingRiskTrainer.messagesPerWeekTarget` — 2.5 a week is the 64% of days this
    /// threshold stayed quiet on, and it is written once rather than twice.
    static let gateThreshold: Double = 0.8479147778557771

    /// Days in the notebook that held at least one entry.
    ///
    /// Not used in any arithmetic. It is here because the prior's intercept is unreadable
    /// without it, and because it is the single number that most limits how far these
    /// coefficients travel.
    static let dayBaseRate: Double = 0.7478991596638656

    /// Forward-chaining results these constants were selected on. Reference values for the
    /// regression test, never copy for the screen.
    enum ReferenceMetrics {
        static let dayROCAUC: Double = 0.7789757412398922
        static let dayBrierCalibrated: Double = 0.11655166613938743
        static let dayBrierRaw: Double = 0.1737857744947495
        static let windowROCAUC: Double = 0.7620006973770873
        static let windowPRAUC: Double = 0.36889648306359807
        static let windowBaseRate: Double = 0.09814814814814815
        static let gatePrecision: Double = 0.8571428571428571
        static let gateRecall: Double = 0.33962264150943394
        static let gateMessagesPerWeek: Double = 2.45
    }
}
