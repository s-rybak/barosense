# AGENTS.md

Entry point for any AI agent working in this repository. Read this file first, then load
only the skills the task actually requires.

**Project:** Barosense — iOS + watchOS app for weather-sensitive people. Collects barometric
pressure from the Apple Watch barometer, surveys wellbeing, and produces a personal forecast
of condition deterioration with an early warning. Target: shipped MVP in the App Store.

**Runtime:** 100% on-device. No backend. Health data never leaves the device.

---

## 1. Core Conventions

These three are non-negotiable and apply to every task, every agent, every commit.

1. **Do No Harm** — The system is stable. Don't refactor beyond task scope.
2. **Human-in-the-Loop** — All external mutations (push, GitHub PR, comments) require
   human approval. See `.claude/skills/human_approval/SKILL.md`.
3. **Scope Control** — Only change what the task requires. See `.claude/skills/scope_control/SKILL.md`.

### Project-specific hard rules

4. **Privacy-first** — Health data does not leave the device without explicit consent.
   ML training and inference are on-device (Core ML + `MLUpdateTask`). No analytics SDK
   that touches HealthKit-derived values.
5. **No medical claims** — Never write copy, code comments, or PR descriptions that state or
   imply diagnosis, treatment, or disease prevention. Approved vocabulary: _tracking_,
   _personal patterns_, _wellbeing companion_. Violations are App Review blockers
   (Guideline 1.4.1 / 5.1.1).
6. **Battery budget is a constraint, not a preference** — Every new sampling loop,
   background task, or complication refresh on watchOS must state its expected cost.
   Default budget: ≤2% additional daily drain on Apple Watch. Justify any sampling rate.
7. **Laser-scoped permissions** — Request only the HealthKit types actually consumed by a
   shipped feature. Adding a `HKObjectType` requires a matching entry in the privacy
   nutrition label and a one-line justification in the PR.

---

## 2. Folder Structure

### `.claude/` — agent operating system

This file lives at the repo root (`AGENTS.md`) as the tool-agnostic entry point.
Everything operational lives in `.claude/`, where Claude Code auto-discovers skills,
subagents, and slash commands; other tools read this file first, then load from
`.claude/` by path.

What exists today:

```
AGENTS.md                         # this file — always read first
.claude/
├── settings.json                 # tool permissions — empty, not configured yet
├── skills/                       # loadable procedures, one folder per skill
│   ├── human_approval/           # when + how to request human sign-off
│   ├── scope_control/            # diff-size limits, out-of-scope escalation
│   ├── swift_conventions/        # Swift/SwiftUI style, module boundaries
│   ├── watchos_budget/           # background refresh quotas, battery math
│   ├── ml_pipeline/              # feature engineering, time-series validation
│   ├── healthkit_permissions/    # permission flow + nutrition-label sync
│   ├── appstore_compliance/      # health-claim wording, review checklist
│   └── github_pr/                # branch, commit, PR template (gated by #2)
├── context/                      # durable project knowledge
│   └── ml-spec.md                # label, feature registry, validation, metrics
├── agents/                       # subagent role definitions
│   ├── ios-engineer.md           # Swift/SwiftUI implementation
│   ├── ml-engineer.md            # ML pipeline; writes only Shared/ + Tests/
│   ├── reviewer.md               # read-only scope/convention/compliance audit
│   └── researcher.md             # external facts with sources; read-only
└── commands/                     # repeatable workflows (slash commands)
    ├── pr-prepare.md             # gates → PR body draft → approval stop
    ├── release-check.md          # pre-TestFlight compliance sweep, go/no-go
    └── ml-eval.md                # metric regression vs. baselines, PR table
```

Planned, not written yet. Do not cite these as if they existed; if a task needs one,
write it as part of that task:

| path | contents |
| ---------------------------------------- | ------------------------------------------ |
| `.claude/context/architecture.md` | data flow, persistence, sync, background |
| `.claude/context/data-model.md` | SwiftData schema + migration history |
| `.claude/context/glossary.md` | domain terms (kPa, HRV, risk score…) |
| `.claude/context/decisions/ADR-0001-on-device-ml.md` | ADRs, immutable once merged |

**Rules for `.claude/`**

- `.claude/skills/` — one directory per skill, always `SKILL.md` inside. A skill describes _how_ to
  do something; it never contains project facts. Facts live in `context/`.
- `context/` — the only place agents may treat as ground truth without re-reading source.
  Anything here that contradicts the code is a bug: fix `context/`, don't fix the code to
  match it.
- `decisions/` — append-only. Superseding an ADR means writing a new one that references it.

---

## 3. Development Conventions

### Stack defaults

Deviating from these requires an ADR in `.claude/context/decisions/`.

| Concern       | Default                                                                |
| ------------- | ---------------------------------------------------------------------- |
| Language / UI | Swift, SwiftUI                                                         |
| Minimum OS    | iOS 17 / watchOS 10                                                    |
| Barometer     | `CoreMotion.CMAltimeter` (`relativeAltitudeUpdates`, pressure in kPa)  |
| Health        | HealthKit — `HKHealthStore`, observer queries for background updates   |
| Weather       | WeatherKit                                                             |
| ML            | Core ML on-device, local training via `MLUpdateTask`                   |
| Persistence   | SwiftData + CloudKit sync (CoreData only if fine control is required)  |
| Widgets       | WidgetKit + ClockKit, `TimelineProvider`, ~1 h refresh                 |
| Backend       | None. Avoid for as long as possible.                                   |
| Tests         | XCTest; snapshot tests for UI; separate unit tests for the ML pipeline |

### Code

- Concurrency: `async/await` and actors. No new Combine pipelines; no completion-handler
  APIs in new code.
- Sensor and network access sits behind a protocol in `Shared/` so tests inject fakes.
- No force-unwrap and no `try!` outside test targets.
- Public API of every type in `Shared/` documented with `///`. Internal code is documented
  only where the _why_ is non-obvious.
- Feature flags for anything that changes the forecast output, so it can be disabled without
  a release.

### Data & ML

- The model must produce useful output with **3–7 days** of history. Any change that raises
  the cold-start requirement needs explicit approval.
- Validation is time-series aware: forward-chaining splits only. Random k-fold on this data
  is leakage and will be rejected in review.
- Primary metric: precision/recall on the "poor wellbeing" event. Report both, plus the
  base rate. Accuracy alone is not an acceptable metric.
- Every feature added to the model gets a row in `context/ml-spec.md`: source, unit,
  sampling frequency, missing-value strategy.
- Pressure from the Apple Watch barometer carries the highest weight — changes to its
  handling get extra review.

### Testing

- New logic in `Shared/` ships with unit tests. No exceptions for "small" changes.
- New or changed SwiftUI view → snapshot test, both size classes and both platforms
  where applicable.
- ML pipeline changes → the metric-regression test must run and the result goes in the PR
  description.
- Nothing merges with a failing or newly skipped test.

### Git & workflow

- Branches: `type/BARO-123-short-slug` (`feat`, `fix`, `chore`, `refactor`, `spike`).
- Commits: Conventional Commits, imperative mood, one logical change per commit.
  `feat(forecasting): add pressure delta over 6h window`
- **Any push, PR creation, or comment posting is a gated action** — draft it, show it,
  wait for human approval. See rule #2 and `.claude/skills/github_pr/SKILL.md`.

### Escalate instead of guessing

Stop and ask a human when:

- The task requires a new HealthKit permission, a new third-party dependency, or a backend.
- The change touches user-facing wording about health outcomes.
- Fixing the task properly requires refactoring code outside the task scope (rules #1, #3).
- An API's current behaviour is uncertain — say so plainly rather than inventing it.
