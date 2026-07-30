---
name: healthkit_permissions
description: Procedure for requesting, adding, or changing HealthKit types — consumer-first rule, entitlement/purpose-string/nutrition-label sync, and denial handling. Load before touching any HKObjectType, entitlement, or usage-description string.
---

# HealthKit permissions

Core convention #7: laser-scoped. Request only the types a shipped feature actually
consumes. Every unnecessary type is a permission dialog the user declines, and a question
in App Review.

**Adding a type is a gated action** (`../human_approval/SKILL.md`). Never widen the read
set as a side effect of another task.

## Checklist for adding one type

Do them in this order. Stop at the first one you cannot satisfy.

1. **Consumer first.** Point to the code in `Shared/` that reads this type and the
   feature it feeds. No consumer → no request. A type added "for later" is a rejection
   risk today.
2. **Feature row.** Add the type to `.claude/context/ml-spec.md` with unit, sampling
   frequency, and missing-value strategy (`../ml_pipeline/SKILL.md`).
3. **Entitlement.** `com.apple.developer.healthkit.access` in the target's
   `.entitlements`, via `project.yml` — never by hand-editing the generated project.
   Both `Barosense` and `BarosenseWatch` targets, if both read it.
4. **Purpose string.** `INFOPLIST_KEY_NSHealthShareUsageDescription` (read) and
   `…NSHealthUpdateUsageDescription` (write). Wording is bound by
   `../appstore_compliance/SKILL.md`: describe tracking and personal patterns, never
   diagnosis or prevention. One sentence, specific about what is read and why.
5. **Privacy nutrition label.** Update the App Store Connect entry in the same change.
   A drifted label is a compliance defect, not paperwork.
6. **PR justification.** One line: type, consumer, why nothing narrower works.

Removing a type follows the same list in reverse; do not leave orphan entitlements.

## Read vs write

Read and write are separate authorisations and separate justifications. Request write
(`NSHealthUpdate…`) only if a shipped feature actually writes — e.g. saving check-ins
back to Health. If nothing writes, do not ask.

## Denial handling

- `authorizationStatus(for:)` is only meaningful for **share/write** types. For read
  types iOS deliberately does not reveal denial — an unauthorised read returns an empty
  result, indistinguishable from "no data". Never branch on read authorization status;
  design for "no samples" as a normal state.
- Every feature that depends on a HealthKit type degrades gracefully when the type is
  empty: the forecast still works, with a stated reduction in confidence. A blocking
  "grant access to continue" screen is not acceptable for anything except the check-in
  flow itself.
- Never re-prompt in a loop. iOS shows the sheet once; after that, link to Settings and
  explain what the feature loses.

## Background delivery

`HKObserverQuery` + `enableBackgroundDelivery(for:frequency:)` is the only sanctioned
path for background health updates. Rules:

- Ask for the **coarsest** frequency that works. `.hourly` unless you can argue otherwise;
  `.immediate` needs an explicit battery justification (`../watchos_budget/SKILL.md`).
- One observer per type, registered once at launch, never inside a view.
- Always call the completion handler, including on the error path — failing to do so gets
  the app's background delivery throttled by the system.
- Requires the HealthKit background-delivery capability; verify the current requirement in
  Apple's docs rather than assuming, and say so if unsure.

## Egress rule

HealthKit-derived values never leave the device without separate, explicit consent.
Concretely: no analytics SDK that can see them, no crash-report payload containing them,
no logging of sample values outside `#if DEBUG`, and nothing health-derived attached to a
WeatherKit request. WeatherKit traffic carries location and time only.

CloudKit sync of HealthKit-derived data is **not** a settled question here — Apple's
HealthKit terms restrict where this data may be stored. Treat it as a gated design
decision requiring an ADR, not a default. See `../appstore_compliance/SKILL.md`.
