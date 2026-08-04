# ML spec

Ground truth for the forecast model: label definition, feature registry, validation
protocol, metrics. Procedure ("how to work on it") lives in
`../skills/ml_pipeline/SKILL.md`; this file holds the facts that procedure operates on.

**If this file contradicts the code, this file is the bug.** Update it in the same PR as
the code change.

## Status

| | |
| ------------------------- | -------------------------------------------------------- |
| Domain types | `Shared/Models/` — `Pressure` (hPa), `PressureSample`, `CheckIn`, `WellbeingScore`, `WellbeingTag` (user-owned, open set) |
| Label | defined — `Shared/Models/WellbeingLabel.swift` (§1) |
| Persistence | `CheckInStore` / `PressureSampleStore` / `WellbeingTagStore` / `UserProfileStore` protocols + in-memory doubles in `Shared/Persistence/`. SwiftData stores exist for `UserProfileStore` and `WellbeingTagStore` only (`Shared/Persistence/SwiftData/`, CloudKit off). **Check-ins and pressure samples still do not survive a launch** |
| Feature pipeline | not written |
| Model | not trained; no data collected |
| HealthKit read set | **empty** — `com.apple.developer.healthkit.access: []` in `project.yml` |

Every row below marked `planned` is a design decision, not shipped behaviour. Every
HealthKit row is additionally gated by `../skills/healthkit_permissions/SKILL.md`: no type
is requested until a consumer exists.

Numbers marked *provisional* were chosen from reasoning, not from data. Re-derive them
from the first real dataset and update this file.

---

## 1. Target label

```
poorWellbeing(checkIn) = checkIn.score <= 2        // 1–5 scale, 1 = worst
```

- Defined **once**, as `WellbeingLabel.poorWellbeingThreshold` in
  `Shared/Models/WellbeingLabel.swift`, with the rationale in a `///` comment. Never
  inlined at a call site.
- Tags are recorded but do **not** enter the v1 label. Extending the label to
  `score <= 3 && !tagIDs.isEmpty` is an open question (§9).
- The tag vocabulary is **open and per user**: `WellbeingTag.seeds` is only where a fresh
  install starts, and the user adds, renames and retires tags from there. A check-in
  stores `Set<WellbeingTag.ID>`, not tag text, so a rename does not rewrite history.
  Consequences for anything that consumes tags:
  - Per-tag features are **personal-model only**. A user-created id means nothing on
    another device, so tag features can never enter the population prior (§6). Only
    `.seeded` ids are comparable across users, and even those may have been renamed to
    mean something else.
  - Tag *text* is user input and is treated like `CheckIn.note`: never a feature, never in
    an outbound payload.
  - The vocabulary is unbounded, so one-hot encoding over all tags is not an option.
    Anything tag-derived has to be a fixed-width summary (count, "any", per-seeded-id).
- Changing the threshold invalidates every stored metric. Re-run the baselines in the
  same PR and put both sets of numbers in the body.

Prediction unit: one row per check-in, features computed at the check-in timestamp `t`.
The advance-warning variant predicts "will any check-in in `[t + 6 h, t + 30 h]` be poor";
both share this label, differing only in the feature cut-off. Only the same-check-in
variant is in v1 scope.

**Base rate: unknown.** It is per-user and cannot be assumed. Report it per fold, never
substitute a literature value.

---

## 2. Feature registry

No row here, no feature in the model. Columns: source, unit, expected sampling frequency
and minimum coverage, behaviour on a gap.

### 2.1 Barometer — highest weight, changes get extra review

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `pressureHPa` | `CMAltimeter` | hPa | opportunistic, target ≥1/h; needs a sample within 90 min of `t` | feature nil → row dropped | planned |
| `pressureDeltaHPaPer3h` | derived | hPa | ≥50% of the 3 h grid observed | nil | planned |
| `pressureDeltaHPaPer6h` | derived | hPa | ≥50% of the 6 h grid | nil | planned |
| `pressureDeltaHPaPer24h` | derived | hPa | ≥40% of the 24 h grid | nil | planned |
| `pressureVolatilityHPa24h` | derived (SD of hourly grid) | hPa | ≥40% of the 24 h grid | nil | planned |
| `pressureCoverage6h` | derived | fraction 0–1 | always computable | 0 | planned |
| `pressureCoverage24h` | derived | fraction 0–1 | always computable | 0 | planned |

Coverage is a first-class feature, not a debug field: it lets the model discount a delta
computed from two lonely samples. Below the stated minimum the feature is `nil` and the
model must handle absence explicitly — never emit a confidently-wrong value.

Grid: hourly, aligned to the hour, trailing from `t`. Gap policy: linear interpolation
across gaps ≤ 2 h; longer gaps stay holes and reduce coverage. Interpolated cells never
count toward coverage.

### 2.2 WeatherKit — forward-looking, the reason an *advance* warning is possible

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `forecastPressureDeltaHPaPer6h` | `HourWeather.pressure` | hPa | hourly forecast, ≤3 h stale | nil | planned |
| `forecastPressureDeltaHPaPer12h` | `HourWeather.pressure` | hPa | as above | nil | planned |
| `forecastPressureDeltaHPaPer24h` | `HourWeather.pressure` | hPa | as above | nil | planned |
| `forecastMinPressureHPaNext24h` | `HourWeather.pressure` | hPa | as above | nil | planned |

`Measurement<UnitPressure>` → hPa at the WeatherKit boundary, once. WeatherKit also
exposes a pressure-trend value; verify its exact type and semantics against current
documentation before using it — do not assume from this file.

Sensor and forecast are **separate feature families**. A WeatherKit value never
substitutes for a missing sensor sample: the watch is ground truth for "now", WeatherKit
for "next". Silently swapping them makes the two families indistinguishable in
attribution.

Outbound WeatherKit requests carry location and time only. Never a health-derived value.

### 2.3 HealthKit — all planned, none authorised

| name | source type | unit | sampling / min coverage | on missing | status |
| ---- | ----------- | ---- | ----------------------- | ---------- | ------ |
| `sleepDurationHours` | `.sleepAnalysis` | h | one session/night; needs a session ending ≤24 h before `t` | nil | planned |
| `sleepAwakeningCount` | `.sleepAnalysis` | count | as above; requires `awake` segments to be recorded | nil | planned |
| `hoursSinceWake` | derived from `.sleepAnalysis` | h | as above | nil | planned |
| `restingHeartRateBPM` | `.restingHeartRate` | bpm | ~1/day, published late | previous completed day, else nil | planned |
| `hrvSDNNMs` | `.heartRateVariabilitySDNN` | ms | sparse and irregular, a few/day at best | nil | planned |
| `oxygenSaturationFraction` | `.oxygenSaturation` | fraction 0–1 | model- and region-dependent; frequently absent | nil | planned |

Two rules that apply to this whole family:

1. **No look-ahead.** Only samples with `endDate <= t` may enter a feature computed at
   `t`. Daily aggregates (`restingHeartRate`) summarise a window that may extend past the
   prediction time — using today's value for a morning prediction leaks the future. Use
   the previous completed day.
2. **Absence is normal, not an error.** Read authorisation denial is indistinguishable
   from "no data" (`../skills/healthkit_permissions/SKILL.md`), and Blood Oxygen
   availability varies by watch model and region. Every one of these features must be
   droppable with a stated confidence reduction, never a hard requirement.

### 2.4 Check-in context

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `priorCheckInScore` | check-in store | 1–5 | previous check-in ≤48 h before `t` | nil | planned |
| `hoursSincePriorCheckIn` | derived | h | as above | nil | planned |
| `hourOfDay` | `t` | 0–23, cyclic-encoded | always | — | planned |

`priorCheckInScore` is strongly autocorrelated with the label and will dominate a small
model. Keep it, but it is also baseline #3 (§7) — if it alone matches the model, the
weather signal is not doing any work and that must be reported.

---

## 3. Altitude contamination

Raw barometer output is *station* pressure. Near sea level ≈ **8.3 m/hPa** (0.12 hPa/m),
so a 10 m elevator ride ≈ 1.2 hPa — the same size as a meteorologically meaningful 6 h
change. Left uncorrected, the model learns "the user took the stairs".

**The obvious fix is circular:** `CMAltimeter.startRelativeAltitudeUpdates` derives
relative altitude *from pressure*, so it cannot separate weather from altitude on its own.
Do not use it as the de-trending reference.

v1 approach — reject rather than correct:

- **Rate gate.** Synoptic pressure change is roughly ≤2 hPa/h even in a rapidly deepening
  system. A change >3 hPa within 10 min is altitude or a bad sample, not weather: drop
  both samples and reduce coverage. *Provisional* thresholds; validate on real traces.
- **Plausibility gate.** `Pressure.isPlausible` (800–1100 hPa) already rejects unit
  mix-ups and bad reads at the boundary.
- **Anchor on rest.** Prefer deltas between samples taken while the user is stationary
  (long-lived low-motion periods, e.g. overnight), which removes most short excursions.

Candidates deferred to §9: `CMAltimeter` absolute-altitude updates (fused with GNSS, so
not circular — verify hardware and platform availability before designing around it), and
CoreLocation altitude as an independent but noisy reference. Both cost battery
(`../skills/watchos_budget/SKILL.md`).

---

## 4. Cold start and the population prior

Requirement: useful output with **3–7 days** of history.

Arithmetic that constrains everything else. At 2–3 check-ins/day, 7 days ≈ 14–21 labelled
rows. At a plausible 15–25% positive rate that is **2–5 positive events**. With a rule of
thumb of ~10 positive events per free parameter, a personal model at day 7 supports well
under one parameter.

Consequences, not opinions:

- Day 7 output is essentially the **population prior**, nudged. A genuinely personal model
  is not statistically meaningful before roughly 3–4 weeks of positives.
- Blend: `w(n) = n / (n + k)`, `n` = labelled rows with usable coverage (not calendar
  days), `k = 30` *provisional*. `k` lives in **one** named constant in `Shared/`.
- **Feature budget: ≤6 features in the personal component.** More parameters than events
  is memorisation. The prior may be richer; the personal part may not.
- The UI states reduced confidence during cold start. Wording per
  `../skills/appstore_compliance/SKILL.md`.

The population prior ships in the bundle. Sourcing it is an open question (§9) — there is
no dataset yet, and shipping a prior fitted on nothing is worse than shipping the "pressure
dropped >X hPa" rule as the day-1 model.

---

## 5. Validation protocol

- **Forward-chaining only, per user.** Random k-fold leaks future into past and is
  rejected in review, no exceptions.
- **Train/test gap ≥ 24 h** — the longest feature window. Without it the 24 h features
  straddle the boundary and leak anyway.
- Two evaluation modes, reported separately:
  1. *Personal* — forward-chaining within one user, ≥3 folds, test fold ≥3 days.
  2. *Cold start* — leave-one-user-out on the prior, scored on that user's first 7 days
     only. This is the number that answers "does the app work on day 3".
- Any user with zero positive events in a fold is excluded from that fold's precision, and
  the exclusion is reported. Do not silently average it away.

---

## 6. Decision threshold

The model outputs a probability; the product sends notifications. Separate concerns:

- Threshold is chosen on the validation folds, never on test.
- *Provisional* ship gate: **precision ≥ 0.5** on the positive class, at whatever recall
  results. A false advance warning costs trust faster than a miss costs value.
- *Provisional* cap: **≤1 advance notification per day.** Bounds the damage of a bad
  threshold and is independent of model quality.
- Output surfaced as a graded risk state, never a yes/no or a percentage presented as
  fact.

Both provisional numbers are product decisions — confirm with a human before they ship.

---

## 7. Metrics and baselines

Report, on the positive class, for every model change:

`precision`, `recall`, `PR-AUC`, `base rate`, `n`, `positive count`.

Accuracy alone is not acceptable — the positive class is rare and a majority-class
predictor scores well on it while being useless.

Beat **all three** baselines or say so plainly in the PR body:

1. **Majority class** — always predict "not poor".
2. **Pressure rule** — `pressureDeltaHPaPer6h < -X`, X tuned on train only.
3. **Persistence** — predict the previous check-in's label.

Baseline 3 is the honest one: self-reported wellbeing is autocorrelated, and a weather
model that cannot beat "yesterday repeated" has not demonstrated a weather signal. A model
that loses to a threshold rule costs battery and adds risk for nothing.

---

## 8. Test fixtures

The pipeline runs from plain XCTest with synthetic input — no `HKHealthStore`, no
`CMAltimeter`, no network. Required fixtures:

- clean hourly pressure series, 14 days;
- series with a 12 h gap (coverage must drop, features must go nil, nothing may crash);
- ~10 hPa step over 5 min (altitude — must be rejected by §3, not learned);
- user with 3 days of history (cold start must still produce output);
- user with zero positive labels (metrics must degrade gracefully, not divide by zero);
- kPa-valued input reaching the boundary (must be rejected or converted, never silently
  10× off).

---

## 9. Open questions

Each needs a decision before v1 ships; anything architectural gets an ADR in
`context/decisions/`.

1. **Population prior source.** No dataset exists. Options: ship the pressure rule as the
   day-1 model and start personal fitting immediately; or a small hand-specified prior from
   literature effect sizes, clearly labelled as a guess.
2. **Label extension** to `score <= 3 && !tagIDs.isEmpty`. Needs real check-in
   distribution. Note the vocabulary is user-owned, so "has any tag" is the only form of
   this that means the same thing for every user.
3. **Altitude reference** — absolute-altitude updates vs. CoreLocation vs. rejection only.
   Battery cost decides it.
4. **Advance-warning horizon** — the 6–30 h window in §1 is assumed, not validated.
5. **Cold-start notifications** — whether to notify at all while output is prior-dominated.
6. **CloudKit sync of derived features.** Apple's HealthKit terms restrict off-device
   storage of health data; this is a gated ADR, not a default
   (`../skills/healthkit_permissions/SKILL.md`).
