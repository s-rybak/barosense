---
name: ml_pipeline
description: Feature engineering, label definition, time-series validation, and reporting rules for the on-device forecast model. Load before touching features, training, evaluation, or anything that produces a risk state.
---

# ML pipeline

Everything here runs on-device: Core ML for inference, `MLUpdateTask` for local personal
training. No training data leaves the watch or phone.

## Cold start is a requirement, not a goal

The model must produce useful output with **3–7 days** of history. A design that needs
months before it is useful is wrong and will be rejected.

Mechanism: a population prior, blended toward the personal model as `n` grows. State the
blend weight as an explicit function of `n` (days of history, or number of labelled
check-ins) in one place — not scattered across call sites. Any change that raises the
cold-start requirement is a gated escalation, not a judgement call.

## Label

- Binary "poor wellbeing" event, derived from the 1–5 check-in scale plus tags.
- The threshold is defined **once**, in `Shared/`, as a named constant with a comment
  explaining the choice. Never inline `score <= 2` at a call site.
- Changing the threshold invalidates every stored metric. Re-run the baseline comparison
  in the same PR and put both numbers in the body.

## Features

Design around **rate of change** (hPa per 3 / 6 / 24 h), not absolute pressure — that is
what the literature actually discusses.

Two traps that will silently poison the model:

1. **Altitude.** Raw barometer output is *station* pressure. Stairs, an elevator, or a
   drive up a hill move it far more than weather does. Every pressure feature is either
   de-trended for altitude or gated on a stationarity check. Untreated, the model learns
   "the user took the elevator".
2. **Irregular sampling.** Samples arrive opportunistically with gaps (see
   `../watchos_budget/SKILL.md`). Any feature that assumes a fixed interval is wrong.
   Resample to a fixed grid with an explicit, documented gap policy, and record the
   fraction of the window that was actually observed as a feature-quality field. Refuse
   to emit a feature when coverage is below its stated minimum — do not emit a
   confidently-wrong value.

Every feature gets a row in `.claude/context/ml-spec.md`:

| field | meaning |
| ----- | ------------------------------------------------------------ |
| name | identifier as used in code |
| source | barometer / HealthKit type / WeatherKit / check-in |
| unit | hPa, hPa·h⁻¹, ms, count… |
| sampling frequency | expected, and minimum acceptable coverage |
| missing-value strategy | what happens on a gap, explicitly |

No row, no feature. Pressure from the watch barometer carries the highest weight —
changes to its handling get extra review.

Sensor "now" vs forecast "next": on-watch sensor data is ground truth for the present;
WeatherKit forward pressure is what makes an *advance* warning possible. Keep them as
separate feature families and never let a WeatherKit value silently substitute for a
missing sensor sample.

## Validation

- **Forward-chaining splits only.** Random k-fold on this data leaks future into past and
  will be rejected in review. Split by time, per user, with a gap between train and test
  at least as long as the longest feature window — otherwise the 24 h window straddles
  the boundary and leaks anyway.
- Report on the positive class: **precision, recall, PR-AUC, and the base rate.**
  Accuracy alone is not an acceptable metric here; the positive class is rare and a
  majority-class predictor scores well on accuracy while being useless.
- Always compare against three trivial baselines:
  1. majority class;
  2. the rule "pressure dropped > X hPa in 6 h" (tune X on train only);
  3. persistence — repeat the previous check-in's label.
  If the learned model does not beat all three, **say so plainly** in the PR body. Shipping
  a model that loses to a threshold rule costs battery and adds risk for nothing, and one
  that loses to persistence has not demonstrated a weather signal at all.

## Tests

- The pipeline runs from a plain XCTest with synthetic input: no `HKHealthStore`, no
  `CMAltimeter`, no network. If a test needs a device, the seam is in the wrong place.
- Fixtures cover: a clean series; a series with a 12 h gap; an altitude step of ~10 hPa
  over 5 minutes; a user with 3 days of history; a user with zero positive labels.
- A metric-regression test runs on every pipeline change and its output goes in the PR
  description. See `../github_pr/SKILL.md`.

## Output

Never present a model output as certainty. The UI surfaces a **graded risk state**, not a
yes/no prediction, and the wording is bound by `../appstore_compliance/SKILL.md`:
"your history suggests", never "you will get a migraine".
