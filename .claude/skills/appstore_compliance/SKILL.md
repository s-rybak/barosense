---
name: appstore_compliance
description: Health-claim wording rules and the pre-submission review checklist. Load before writing any user-facing string, notification copy, store listing, screenshot, or PR description.
---

# App Store compliance

Core convention #5. The medical-claim rule is an App Review blocker (Guidelines 1.4.1 /
5.1.1), not a style preference. A rejection costs a review cycle; rewording costs a
minute.

## Vocabulary

**Allowed:** tracking, personal patterns, wellbeing companion, your history suggests,
check-in, trend, likely, risk state.

**Forbidden:** diagnose, diagnosis, predicts your migraine, prevents, treats, treatment,
therapy, medical, clinical, symptom relief, cure, patient, disease — and any phrasing that
implies the app knows what will happen to the user's body.

Rewrites:

| Instead of                            | Write                                              |
| ------------------------------------- | -------------------------------------------------- |
| "Migraine predicted tomorrow"         | "Your history suggests tomorrow may be a harder day" |
| "Prevent your next headache"          | "Notice patterns before they repeat"                |
| "Medical-grade pressure tracking"     | "Barometric pressure from your Watch"              |
| "You will feel worse at 14:00"        | "Elevated risk state from ~14:00"                  |
| "Diagnose your weather sensitivity"   | "Track how weather lines up with how you feel"     |

The rule applies to **every** surface, not just marketing: UI strings, notification
bodies, complication text, `INFOPLIST_KEY_NS*UsageDescription`, onboarding, settings
footers, the App Store description, screenshot captions, code comments, type and function
names, commit messages, and PR bodies.

Also forbidden regardless of wording: presenting model output as certainty. The UI shows
a graded risk state (`../ml_pipeline/SKILL.md`). No percentages presented as fact, no
"confirmed".

## Sweep

Run before any PR that touches copy, and before every submission:

```bash
grep -rniE 'diagnos|prevent|treat|medical|clinical|cure|symptom|patient|disease|migraine' --include='*.swift' --include='*.yml' --include='*.strings' --include='*.md' .
```

Every hit is either fixed or explicitly justified in the PR body. "It's only a comment"
is not a justification — comments become names, names become UI strings.

## Pre-submission checklist

Privacy and data:

- [ ] Privacy nutrition label matches the actual HealthKit read/write set, exactly.
- [ ] Every requested HealthKit type has a live consumer in shipped code.
- [ ] Purpose strings are specific, non-medical, and match what the code does.
- [ ] No health-derived value in any outbound request; WeatherKit carries location/time
      only. Verify with a proxy capture, not by reading the code.
- [ ] No analytics or crash SDK with access to health-derived values.
- [ ] Storage location of health-derived data is documented, and any iCloud/CloudKit sync
      of it has an ADR. Apple's HealthKit terms restrict this — verify the current
      guideline text before submitting rather than assuming; if unverified, say so and do
      not ship the sync.

Behaviour:

- [ ] App is useful with 3–7 days of data; no empty-state dead end (Guideline 4.2 —
      minimum functionality).
- [ ] Sensor/permission denial degrades gracefully, no blocking wall.
- [ ] Complication readable in ~0.5 s: one number or one state.
- [ ] Notification copy passes the vocabulary rule.
- [ ] A visible, plain-language statement that this is not medical advice, placed where
      the user sees the forecast — not buried in settings.

Build:

- [ ] `xcodegen generate` run; `xcodebuild … test` green, no newly skipped tests.
- [ ] No `#if DEBUG` logging of health values reachable in Release.
- [ ] Version and build number bumped.

## Uncertainty

App Review specifics change. If you do not know the current text of a guideline or
whether a capability is permitted, **say so explicitly** and mark the item unverified.
A fabricated guideline citation is worse than an admitted gap — it produces confident
wrong decisions downstream.
