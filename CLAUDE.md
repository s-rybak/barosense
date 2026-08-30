# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Barosense — an iOS + watchOS app for weather-sensitive people. It samples barometric
pressure from the iPhone built-in barometer, collects short self-reported wellbeing
check-ins, and produces a **personal** forecast of likely wellbeing decline with an
advance notification. Target outcome: shipped MVP on the App Store.

Everything runs **on-device**. There is no backend and adding one requires explicit
discussion.

## Non-negotiable constraints

Read these before writing any code. They override convenience.

1. **No medical claims.** Never write copy, comments, or API names that assert diagnosis,
   treatment, or disease prevention. Allowed vocabulary: _tracking_, _personal patterns_,
   _wellbeing companion_, _your history suggests_. Forbidden: _diagnose_, _predicts your
   migraine_, _prevents_, _treats_, _medical_. This is an App Review rejection risk
   (Guideline 1.4.1 / 5.1.1), not a style preference.
2. **Health data never leaves the device** without explicit, separate user consent.
   Default: no network egress of health or check-in data at all. WeatherKit requests are
   the only outbound traffic and must not carry health payloads.
3. **Request HealthKit permissions surgically.** Only the exact types read by a shipped
   feature. Adding a type to the read set requires a corresponding consumer in the model.
4. **Battery budget on watchOS is the binding constraint.** Every sampling interval,
   background refresh, and complication reload must come with a stated cost rationale.
   Do not add a timer or observer without justifying its frequency.
5. **Cold start must work.** The model must produce useful output with 3–7 days of
   history. Any design that needs months of data before it is useful is wrong. Prefer a
   population prior blended toward the personal model as `n` grows.
6. **Complication readability.** A watch face complication must be parseable in ~0.5 s.
   One number or one state, no dense text.

## Stack (defaults — flag before deviating)

| Concern        | Choice                                                                     |
| -------------- | -------------------------------------------------------------------------- |
| Language / UI  | Swift, SwiftUI                                                             |
| Minimum OS     | iOS 26.0 / watchOS 26.0                                                    |
| Barometer      | `CoreMotion.CMAltimeter`                                                   |
| Health signals | HealthKit (`HKHealthStore`, observer queries)                              |
| Weather        | WeatherKit                                                                 |
| ML             | Core ML on-device; local training via `MLUpdateTask`                       |
| Persistence    | SwiftData (CoreData only if fine-grained control is needed), CloudKit sync |
| Widgets        | WidgetKit + `TimelineProvider`, ~1 h refresh cadence                       |
| Tests          | XCTest; separate unit tests for the ML pipeline                            |
| Project file   | XcodeGen (`project.yml`)                                                   |

## Build

The `.xcodeproj` is **generated, not committed**. Regenerate after any change to
`project.yml` or after adding/removing source directories:

```sh
brew install xcodegen        # once
xcodegen generate            # writes Barosense.xcodeproj
```

Build and test:

```sh
xcodebuild -project Barosense.xcodeproj -scheme Barosense \
  -destination 'platform=iOS Simulator,name=iPhone 17' build

xcodebuild -project Barosense.xcodeproj -scheme Barosense \
  -destination 'platform=iOS Simulator,name=iPhone 17' test
```

`name=` has to match a simulator that is actually installed, otherwise `xcodebuild`
fails before it compiles anything. Check with `xcrun simctl list devices available`
and substitute — the device model only matters when a change is layout-sensitive.

Adding a file inside an existing `sources` path needs no `project.yml` edit — XcodeGen
globs directories. Adding a new **target** or top-level directory does.

## Layout

```
Barosense/        iOS app target — onboarding, check-in UI, history, settings
BarosenseWatch/   watchOS app target — quick check-in, current pressure, risk state
Shared/           cross-platform: domain models, barometer service, feature
                  engineering, Core ML wrapper. Keep UI-free and testable.
Tests/            XCTest targets
project.yml       XcodeGen manifest
```

Rule: anything that can live in `Shared/` should. Platform targets hold views and
platform-specific plumbing only. The ML pipeline in particular must be runnable from a
plain unit test with synthetic input — no `HKHealthStore` or `CMAltimeter` at test time.

## Documentation

The `docs/` site is Material for MkDocs. Two halves, and the split is the rule:

- **Hand-written and committed** — `docs/index.md`, `overview/`, `subsystems/`,
  `database/`, `ml/`, `privacy/`, `dev/`, `adr/`.
- **Generated and gitignored** — `docs/reference/` (a page per `.swift` file, with every
  call site of every symbol) and `docs/generated/` (SwiftData schema + ER diagram, repo
  tree, module graph, stats).

```sh
python3 -m venv .venv-docs
.venv-docs/bin/pip install -r docs/requirements.txt
.venv-docs/bin/mkdocs serve                                  # regenerates on startup
.venv-docs/bin/python scripts/docs/generate_reference.py     # generator alone
```

If a fact can be read out of the source, **do not write it into a hand-written page** —
teach `scripts/docs/swiftdoc/` to extract it. The reference pages are built from the
`///` comments, so the way to improve them is to document the Swift, not the Markdown.

CI builds the site with `--strict` on a Linux runner; the generator therefore must never
grow a dependency on Xcode or on any third-party Python package.

## Agent assets

`AGENTS.md` at the repo root is the tool-agnostic entry point; the operational assets
live in `.claude/` and are auto-discovered by Claude Code:

- `.claude/skills/` — procedure skills (scope control, human-approval gates, Swift
  conventions, watchOS battery budget, ML pipeline, HealthKit permissions, App Store
  compliance, GitHub PR flow). Load the ones the task actually touches.
- `.claude/agents/` — subagents: `ios-engineer`, `ml-engineer` (writes only `Shared/`
  and `Tests/`), `reviewer` (read-only), `researcher` (read-only + web).
- `.claude/commands/` — slash commands: `/pr-prepare`, `/release-check`, `/ml-eval`.
- `.claude/context/ml-spec.md` — feature registry and ML ground truth; update it in
  the same change as any feature edit.

## Domain notes worth remembering

- `CMAltimeter.startRelativeAltitudeUpdates` delivers `CMAltitudeData.pressure` in
  **kPa** (`NSNumber`). Multiply by 10 for hPa/mbar, the unit meteorology uses. Check
  `CMAltimeter.isRelativeAltitudeAvailable()` and `authorizationStatus()` first.
- Raw barometer output is _station_ pressure — it moves when the user changes altitude
  (stairs, elevator, driving). Altitude-driven change is not weather. Any pressure feature
  fed to the model must be de-trended for altitude or gated on a stationarity check;
  otherwise the model learns "user took the elevator" as a signal.
- Continuous barometer sampling on watchOS is **not** freely available in the background.
  Assume opportunistic sampling (app foreground, complication refresh, `WKApplication`
  background refresh) and design the pipeline to tolerate gaps and irregular timestamps.
  If you are unsure whether a specific background mode is permitted, say so rather than
  guessing.
- The physiologically discussed signal in the literature is usually **rate of change**
  (hPa per 3/6/24 h) rather than absolute pressure. Feature design should reflect that.
- WeatherKit provides forward-looking pressure, which is what makes an _advance_ warning
  possible at all. On-watch sensor data is the ground truth for "now"; WeatherKit is the
  ground truth for "next 24–48 h".

## ML pipeline expectations

- Target label: binary "poor wellbeing" event derived from the 1–10 check-in intensity
  scale (higher is worse) plus tags. Define the threshold in one place in `Shared/`, not inline.
- Validation must be **time-series aware** — forward-chaining splits, never a random
  shuffle. A random split leaks future into past and will report fake accuracy.
- Report precision/recall (and PR-AUC) on the positive class. Accuracy is meaningless
  here; the positive class is rare.
- Always compare against a trivial baseline (majority class, and "pressure dropped >X hPa
  in 6 h"). If the learned model does not beat both, say so plainly.
- Never present a model output as certainty. UI surfaces a graded risk state, not a
  yes/no prediction.

## Working style expected here

- Be quantitative: payload sizes, sampling frequency, battery cost in %, latency in ms.
- Critique over validation. If a proposed approach is bad, say why and give the
  alternative. Do not agree by default.
- When several approaches are valid, compare trade-offs: battery, complexity, accuracy,
  time to market.
- If you do not know a current API detail (watchOS background execution rules, WeatherKit
  quotas, App Review specifics), say so explicitly instead of inventing it. Fabricated API
  surface is worse than an admitted gap.
- Answers in Ukrainian; code, identifiers, comments, and commit messages in English.
- **Never run `git commit`, `git add`, or `git push` yourself** — not even when asked.
  Leave the change in the working copy, say what is in it, and hand over the command.
  Committing is the human's signature that the diff has been read.
  See `.claude/skills/human_approval/SKILL.md`.
