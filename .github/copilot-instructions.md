# Copilot review instructions — Barosense

Barosense is an iOS + watchOS app for weather-sensitive people. It samples barometric
pressure from the iPhone barometer, collects 1–10 wellbeing check-ins, and produces a
**personal** forecast of likely wellbeing decline. Everything runs **on-device**: there is
no backend, and adding one requires an explicit design decision in the PR.

Review Swift/SwiftUI code against the rules below. They are project constraints, not
preferences — a violation is a blocking finding, not a nitpick.

## Priority order

1. Medical-claim wording (App Review blocker)
2. Health-data egress
3. Battery cost on watchOS
4. Correctness of the ML pipeline (leakage, altitude, gaps)
5. Concurrency and module boundaries
6. Style

## 1. No medical claims — highest priority

Flag any **new or changed** string, identifier, comment, commit message, or PR text that
asserts diagnosis, treatment, prediction of a bodily event, or prevention.

Forbidden vocabulary: `diagnose`, `diagnosis`, `predicts your migraine`, `prevents`,
`treats`, `treatment`, `therapy`, `medical`, `clinical`, `symptom relief`, `cure`,
`patient`, `disease`.

Allowed vocabulary: _tracking_, _personal patterns_, _wellbeing companion_, _your history
suggests_, _check-in_, _trend_, _likely_, _risk state_.

This applies to every surface: UI strings, notification bodies, complication text,
`INFOPLIST_KEY_NS*UsageDescription` in `project.yml`, type and function names, and code
comments. Comments become names; names become UI strings.

Also flag: presenting model output as certainty — a bare percentage stated as fact, a
countdown to an event, "confirmed", or a yes/no prediction. The UI surfaces a **graded
risk state** only.

When flagging, propose the concrete rewrite, e.g. "Migraine predicted tomorrow" →
"Your history suggests tomorrow may be a harder day".

## 2. Health data never leaves the device

Flag as blocking:

- any network call carrying a health-derived value, a check-in, or a model feature;
- a WeatherKit request with anything but location and time attached;
- an analytics or crash-reporting SDK that can observe health-derived values;
- logging of sample values outside `#if DEBUG`;
- CloudKit / iCloud sync of HealthKit-derived data without an explicit design rationale
  in the PR body — Apple's HealthKit terms restrict this; it is a gated decision.

## 3. HealthKit permissions are laser-scoped

Any newly requested `HKObjectType` must arrive with **all** of: a live consumer in
`Shared/`, an entitlement change in `project.yml` (never a hand-edited `.xcodeproj`), a
purpose string, a row in `.claude/context/ml-spec.md`, and one line of justification in
the PR. Missing any of those → flag it. A type added "for later" is a rejection risk today.

Read vs write are separate authorisations. Do not request `NSHealthUpdateUsageDescription`
unless shipped code writes.

Flag branching on `authorizationStatus(for:)` for a **read** type — iOS does not reveal
read denial; an unauthorised read returns an empty result. "No samples" must be a normal,
gracefully handled state, never a blocking wall.

`HKObserverQuery` + `enableBackgroundDelivery`: flag `.immediate` without a battery
justification (`.hourly` is the default expectation), an observer registered inside a
view rather than once at launch, and any path that fails to call the completion handler.

## 4. watchOS battery budget — ≤ 8 % additional daily drain

Battery is the binding constraint on the watch. Flag any new `Timer`, polling loop,
observer, background task, or complication reload that arrives **without a stated
frequency and cost rationale** in the PR body.

Specific rejections:

- barometer left running while the app is not in the foreground;
- sampling faster than the feature needs (a 6 h pressure delta does not need 1-minute
  samples — hourly is already 6× oversampled);
- complication/widget refresh materially more often than ~1 h;
- a timeline reload triggered directly from a sensor callback (batch instead:
  sample → persist → reload at the scheduled boundary);
- `WKExtendedRuntimeSession` used to paper over sampling gaps;
- a hard-coded assumption about how many background refreshes per hour the system grants.

Background execution on watchOS is **opportunistic**. Any code assuming a fixed sample
interval or a guaranteed wake-up is wrong — flag it and ask what happens when the
wake-up never fires.

## 5. ML pipeline correctness

- **Leakage.** Random / shuffled k-fold splits are wrong on this data. Validation must be
  forward-chaining, split by time, with a gap between train and test at least as long as
  the longest feature window (24 h). Flag any `shuffle`, `randomSplit`, or index-based
  split over time-ordered rows.
- **Metrics.** Accuracy alone is not acceptable — the positive class is rare. Require
  precision, recall, PR-AUC on the positive class, plus the per-fold base rate, and a
  comparison against three baselines: majority class, "pressure dropped > X hPa in 6 h",
  and persistence (repeat the previous label).
- **Altitude.** Raw barometer output is _station_ pressure — stairs and elevators move it
  far more than weather does. Every pressure feature must be de-trended for altitude or
  gated on a stationarity check. Flag a raw-pressure feature without either.
- **Gaps.** Samples are irregular. Features must resample to an explicit grid with a
  documented gap policy and must emit `nil` below their stated minimum coverage rather
  than a confidently-wrong value.
- **Units.** `CMAltitudeData.pressure` is **kPa**; the domain unit is **hPa** (×10).
  Convert once at the sensor boundary. Flag any kPa value past that boundary, and any
  pressure identifier without the unit in its name (`pressureHPa`, `deltaHPaPer6h`).
- **Label threshold** is defined once in `Shared/` as a named constant. Flag an inlined
  `intensity >= 7` at a call site.
- **Cold start.** The model must be useful with 3–7 days of history via a population prior
  blended toward the personal model as `n` grows. Flag any design that needs months of
  data, or a raised cold-start requirement.
- Any feature change must come with the matching row update in
  `.claude/context/ml-spec.md` in the same PR. No row, no feature.

## 6. Architecture and concurrency

- `Shared/` is UI-free: no `import SwiftUI`, `import UIKit`, or `import WatchKit`. It must
  compile and be testable without a device. Anything that _can_ live in `Shared/` should;
  platform targets hold views and platform glue only.
- Sensors, stores, and network clients sit behind a protocol declared next to the
  consumer, injected at the app layer. The ML pipeline must run from a plain XCTest with
  synthetic input — no `HKHealthStore`, no `CMAltimeter`, no network at test time.
- The project builds with `SWIFT_STRICT_CONCURRENCY: complete`. Flag suppressed isolation
  warnings, `@unchecked Sendable` without a stated invariant, and
  `Task { @MainActor in … }` used to silence an isolation warning instead of fixing
  ownership. `@MainActor` belongs on view models, never on `Shared/` domain logic.
- `async`/`await` and actors only. Flag new Combine pipelines and new completion-handler
  APIs; legacy callbacks (`CMAltimeter`, `HKObserverQuery`) are wrapped once at the
  boundary in `AsyncStream` / `withCheckedContinuation`.
- No force-unwrap, `try!`, or `as!` outside `Tests/`.
- Errors are typed enums per subsystem — not `NSError`, not `String`.
- Views are pure functions of state: no network, sensor, or store access inside `body`,
  and no business logic that could be unit-tested in `Shared/`.
- Dynamic Type and VoiceOver labels on anything conveying a value or state. A watch
  complication must be parseable in ~0.5 s: one number **or** one state.
- `Barosense.xcodeproj` is generated by XcodeGen and not committed. Flag any PR that
  commits it or hand-edits `project.pbxproj`; target and top-level-directory changes go in
  `project.yml`.

## 7. Scope

The system is stable; a PR changes what its task requires and nothing else. Flag, as
separate-PR material: reformatting of untouched files, unrelated renames, dependency or
deployment-target bumps, "fixes" to adjacent code off the change path, abstraction for a
second use case that does not exist yet, and deletion of code not proven unreferenced.

Soft limits: 900 changed lines, 30 files. Beyond that the PR body must say why. New
third-party dependencies are 0 by default and always require explicit sign-off.

Flag a new `// TODO` left in source as the only record of known follow-up work — it
belongs in the PR body or an issue.

## What not to comment on

- Formatting already enforced by `.swiftlint.yml` (line length, file length, function
  length) — the pre-commit hook runs SwiftLint `--strict`.
- Missing `///` docs on internal code. Only `Shared/` public API needs them.
- Test files using force-unwrap or `try!` — allowed there by design.
- Generated files: `Barosense.xcodeproj/**`, `.build/**`.
- Restating what the diff does. Comment only where something is wrong, risky, or violates
  a rule above; prefer one substantiated finding over five stylistic ones.

## Uncertainty

If a comment depends on current Apple behaviour you cannot verify — watchOS background
execution allowances, WeatherKit quotas, App Review guideline text, HealthKit terms — say
so explicitly and mark it unverified. A fabricated API detail or guideline citation is
worse than an admitted gap, because it produces confident wrong decisions downstream.
