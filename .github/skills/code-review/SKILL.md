---
name: code-review
description: Procedure for reviewing a Barosense diff, branch, or pull request — which gates to run first, which rule file governs which path, how to grade and evidence a finding, and how to report. Load before reviewing a branch, a PR, or a patch. Reviewing is read-only; posting anything is gated.
---

# Code review

This file is the **procedure**. The **rules** live in the files listed below and are not
repeated here — a second copy of a rule drifts from the first, and a stale rule produces
confident wrong decisions downstream.

Reviewing is read-only. You inspect, you report, you never fix. An impulse to edit a file
becomes a finding instead. Posting a comment or a review is a gated action —
`.claude/skills/human_approval/SKILL.md`.

## Rule sources — load the ones the diff touches

| Changed path                        | Governing file                                     |
| ----------------------------------- | -------------------------------------------------- |
| anything                            | `.github/copilot-instructions.md` (priority order)  |
| `Shared/**/*.swift`                 | `.github/instructions/shared.instructions.md`       |
| `BarosenseWatch/**/*.swift`         | `.github/instructions/watch.instructions.md`        |
| `Barosense/**`, `*.xcstrings`       | `.github/instructions/ui-copy.instructions.md`      |
| `Tests/**/*.swift`                  | `.github/instructions/tests.instructions.md`        |
| `project.yml`, `*.entitlements`, CI | `.github/instructions/build-config.instructions.md` |
| the forecast model                  | `.claude/context/ml-spec.md` (feature registry)     |
| diff size, out-of-scope work        | `.claude/skills/scope_control/SKILL.md`             |

Scope numbers (changed lines, files touched, dependency budget) come from
`scope_control/SKILL.md` and nowhere else. If another file states a different number, that
file is the bug — the discrepancy is itself a finding, reported, not silently resolved.

## 1. Establish the diff

```bash
git fetch origin main --quiet && git diff --stat origin/main...HEAD | tail -1
```

For a PR, read it first — reading GitHub is free, writing to it is not:

```bash
gh pr view <n> --json title,body,files,additions,deletions && gh pr diff <n>
```

Three-dot (`origin/main...HEAD`), never two: two-dot mixes in commits that landed on
`main` after the branch started and turns other people's work into your findings.

Before reading a line of code, check the PR body against
`.claude/skills/github_pr/SKILL.md`. An unexplained unchecked constraint box, a missing
battery cost for new recurring work, or a missing metric table on a pipeline change is a
finding on its own — the body is the artefact review depends on.

## 2. Run the machine gates first

```bash
BASE_REF=$(git merge-base origin/main HEAD) scripts/ci/run-all.sh
```

```bash
swiftlint lint --strict
```

```bash
scripts/ci/run-tests.sh
```

A failure a script already prints is not your finding: cite it in one line
(`guard check-copy-vocabulary.sh fails at File.swift:42`) and spend your attention on what
no script can see. Do not hand-flag force-unwraps, `import SwiftUI` in `Shared/`,
`Task { @MainActor`, new Combine imports, line length, or a committed `.xcodeproj` —
`.swiftlint.yml` and the guards own those, with `--strict`, in CI.

`run-tests.sh` needs macOS + Xcode 26. If you cannot run it, say so in the report and mark
the build/test verdict `not run` — never infer a pass.

### What the gates cannot see — this is the review

| Gate                        | Blind spot the review must cover                                                                                        |
| --------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| `check-copy-vocabulary.sh`  | A claim built without a forbidden stem: "tomorrow will be a bad day", a bare percentage stated as fact, a countdown, a yes/no verdict where the UI owes a graded risk state. |
| `check-network-egress.sh`   | What the payload carries. Networking confined to the allowlisted directory still leaks if a check-in, feature, or health-derived value is passed into it — including via a log line outside `#if DEBUG`. |
| `check-healthkit-sync.sh`   | Whether the "consumer" is live code or a stub added to satisfy the guard, and whether the purpose string describes what the code actually reads. |
| `check-ml-spec-drift.sh`    | Whether the updated `ml-spec.md` row is *correct* — unit, window, gap policy, minimum coverage.                            |
| `check-project-manifest.sh` | Whether a new entitlement is justified at all.                                                                            |
| SwiftLint custom rules      | `@unchecked Sendable` without a stated invariant, a protocol seam that exists but leaks its concrete type, isolation fixed by hopping rather than by ownership. |
| the test suite              | A test that passes because an assertion was weakened, a fixture that no longer covers the gap/altitude/cold-start cases.   |

## 3. Read the diff in priority order

From `.github/copilot-instructions.md`: medical claims → health-data egress → watchOS
battery → ML correctness (leakage, altitude, units, gaps, cold start) → concurrency and
module boundaries → style. Work top-down and stop descending once you have a blocker in
the top two categories — report it immediately rather than completing a tidy sweep. A
rejection risk and a naming nit do not belong in the same round of attention.

For each new recurring wake-up (`Timer`, observer, background task, complication reload),
redo the arithmetic in the PR body yourself. A stated cost with no arithmetic, or a
suspiciously round number, is a finding: the point of the number is that it was computed.

For each pressure feature, check the unit at the boundary (kPa in, hPa everywhere after,
unit in the identifier) and the altitude de-trend or stationarity gate. Station pressure
moves more on a staircase than in a storm.

## 4. Grade every finding

| Severity  | Meaning                                                                    |
| --------- | -------------------------------------------------------------------------- |
| `blocker` | Ships a rejection risk, leaks health data, breaks the build or a test, or exceeds a hard scope limit. Merge does not happen. |
| `major`   | Wrong behaviour, missing cost rationale, missing tests on new `Shared/` logic, soft scope limit exceeded without a stated reason. |
| `minor`   | Real but non-urgent: naming, a missing `///` on public `Shared/` API, a clearer alternative. |
| `nit`     | Opinion. Labelled as such, and never more than a couple per review.          |

## 5. Evidence rule

Every finding carries: severity, `file:line`, one sentence on what is wrong, one sentence
on the expected fix, and either a rule citation (file + section) or a concrete failure
scenario — inputs and state → wrong output. A finding with neither is an opinion; label it
`nit` or drop it.

For a copy finding, propose the rewrite verbatim. "This sounds medical" is not actionable;
`"Migraine predicted tomorrow"` → `"Your history suggests tomorrow may be a harder day"`
is.

## 6. Calibration

Do not manufacture findings to look thorough. A clean diff is reported clean, in one line.
One substantiated blocker beats eight stylistic observations, and a review that lists
everything trains the reader to skim past the one item that mattered. If a pass yields
more than ~7 findings, group them by rule and report the pattern once.

## 7. Uncertainty

Anything depending on current Apple behaviour you cannot verify — watchOS background
execution allowances, WeatherKit quotas, App Review guideline text, HealthKit terms — is
marked `unverified` in the finding and named as an open question. A fabricated API detail
or an invented guideline number is worse than an admitted gap: it is acted on.

## 8. Report format

```markdown
## Verdict

<"ready for pr-prepare" | "N blockers to resolve" | "clean">

## Gates

- Guards: <pass/fail, which check>
- SwiftLint --strict: <pass/fail>
- Build + tests: <N passed / N failed / N skipped, or "not run — no macOS toolchain">
- Scope: <±lines / files vs. the scope_control budget>

## Findings

1. **blocker** `Shared/Features/PressureDelta.swift:88` — <problem>.
   Expected: <fix>. Rule: shared.instructions.md → units.

## Open questions

- <unverified assumption, and what would settle it>
```

## 9. Gates

Free: `git diff`, `git log`, `gh pr view`, `gh pr diff`, `grep`, the guard scripts,
`xcodebuild build` / `test`.

Gated — draft, show, wait for an explicit yes: `gh pr comment`, `gh pr review`,
`gh pr merge`, any push, any issue. Editing a file during a review is not "gated", it is
out of scope: the review produces findings, a separate task produces the fix.
