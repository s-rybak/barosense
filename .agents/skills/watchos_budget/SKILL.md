---
name: watchos_budget
description: Battery-cost accounting for watchOS — how to justify a sampling interval, background refresh, or complication reload before adding it. Load before adding any timer, observer, background task, or session.
---

# watchOS budget

Core convention #6. Battery is the binding constraint on the watch, not CPU and not
memory. Every recurring wake-up is a debit that must be argued for.

**Budget: ≤ 2% additional daily drain on Apple Watch.** A change with no stated cost is
not reviewable and should be rejected in review.

## Before adding anything recurring

Answer all six, in the PR body:

1. What wakes the app up, and how often per hour?
2. How long does the work take, in ms, measured — not guessed?
3. What does it keep powered while awake (barometer, HealthKit query, network, display)?
4. What breaks if the interval is doubled? If nothing breaks, double it.
5. What happens when the wake-up does not fire at all? (It will not fire. Design for it.)
6. Estimated daily drain, in %, with the arithmetic shown.

If you cannot answer 2 or 6 with a measurement, say so explicitly rather than inventing a
number. An admitted gap is acceptable; a fabricated mAh figure is not.

## Background execution reality

- Continuous barometer sampling in the background is **not** freely available. Assume
  opportunistic sampling: app foreground, complication/widget refresh, and
  `WKApplication` background refresh.
- The system budgets background refresh; the exact allowance depends on watchOS version,
  whether the complication is on the active face, and system conditions. **Do not
  hard-code an assumed number of refreshes per hour.** Schedule the next refresh, handle
  being dropped, and verify the real cadence by logging on device.
- `WKExtendedRuntimeSession` is for specific declared session types and is expensive.
  Do not reach for it to work around gaps in sampling — that is a design smell, and the
  session type must be justifiable to App Review.
- HealthKit background delivery (`HKObserverQuery` + `enableBackgroundDelivery`) has its
  own frequency ceiling per type. Requesting `.immediate` where `.hourly` suffices is a
  battery bug. See `../healthkit_permissions/SKILL.md`.

Consequence for the pipeline: it must tolerate gaps and irregular timestamps. Any code
that assumes a fixed sample interval is wrong. See `../ml_pipeline/SKILL.md`.

## Complications and widgets

- Target refresh cadence ~1 h. Pressure does not move fast enough to justify more, and
  the daily reload allowance is finite and shared.
- A complication must be parseable in ~0.5 s: one number **or** one state. No dense text,
  no two-line sentences, no trend arrow plus number plus label.
- Never reload the timeline from a sensor callback. Batch: sample → persist → reload at
  the scheduled boundary.

## Measurement procedure

Simulator numbers are meaningless for energy. Measure on device:

1. Xcode → Debug Navigator → Energy Impact, during a foreground session.
2. Instruments → Energy Log / Points of Interest for background wake-ups; mark regions
   with `os_signpost` around each sampling batch.
3. For a day-scale number: charge to 100%, run a build with the feature flag on for a
   fixed window (≥ 4 h) with the watch worn normally, record the delta, then repeat with
   the flag off. Report both, not just the difference.

Record the result in the PR body. Feature-flag anything whose measured cost you have not
yet confirmed, so it can be disabled without a release.

## Review triggers

Reject or escalate a change that:

- Adds a `Timer`, `AsyncStream` loop, or observer with no stated frequency.
- Samples faster than the feature's actual resolution needs (a 6-hour pressure delta does
  not need 1-minute samples — hourly is already 6× oversampled for that window).
- Keeps the barometer running while the app is not in the foreground.
- Reloads a complication more than a handful of times per hour.
