---
description: Run the ML metric-regression evaluation — forward-chaining validation, precision/recall/PR-AUC vs. both trivial baselines — and produce the markdown table for a PR body.
---

Evaluate the forecast pipeline and produce the metrics table that
`.claude/skills/ml_pipeline/SKILL.md` requires in every ML-touching PR. Read that
skill and `.claude/context/ml-spec.md` first.

## Procedure

1. **Locate the eval harness.** Look in `Tests/` for the ML pipeline test target
   (synthetic-input tests that run without HealthKit or CoreMotion). If no evaluation
   harness exists yet, stop and report exactly that — "no eval harness; metrics
   unavailable" — instead of improvising numbers. Building the harness is its own
   task.
2. **Run it** via `xcodebuild test` scoped to the ML test target
   (`-only-testing:` the pipeline suite). The evaluation must use the fixed synthetic
   dataset checked into `Tests/`, so numbers are comparable across PRs. If the dataset
   changed in this diff, say so — the comparison to previous numbers is void.
3. **Verify the split.** Confirm the evaluation uses forward-chaining time-series
   splits. If you find a random shuffle anywhere in the eval path, stop: the numbers
   are leakage and must not be reported. That finding outranks any metric.
4. **Collect, on the positive ("poor wellbeing") class:** precision, recall, PR-AUC,
   and the base rate. For both baselines too: majority class, and the rule "pressure
   dropped >X hPa in 6 h" (X from its named constant in `Shared/`, never re-hardcoded
   here).

## Output

A markdown table ready to paste into a PR body:

| Model | Precision | Recall | PR-AUC |
| --- | --- | --- | --- |
| Learned model | … | … | … |
| Baseline: majority class | … | … | … |
| Baseline: pressure drop rule | … | … | … |

Plus two lines below the table: the positive-class base rate, and a one-sentence
verdict. If the learned model does not beat both baselines, the verdict says exactly
that — first, plainly, before any mitigation. Never report accuracy; never present the
output as a certainty claim.
