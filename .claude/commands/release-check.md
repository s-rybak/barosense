---
description: Pre-TestFlight compliance sweep — copy vocabulary, HealthKit permission sync, battery budget total, network egress. Read-only; produces a go/no-go report.
---

Run the pre-release compliance sweep for Barosense. This command changes nothing — it
reads, checks, and reports. Load `.claude/skills/appstore_compliance/SKILL.md`,
`.claude/skills/healthkit_permissions/SKILL.md`, and
`.claude/skills/watchos_budget/SKILL.md` before starting.

## Checks

1. **Vocabulary audit.** Collect every user-facing string: SwiftUI views in
   `Barosense/` and `BarosenseWatch/`, notification copy, `INFOPLIST_KEY_*` usage
   descriptions in `project.yml`, and any store-listing text present in the repo.
   Scan against the forbidden list (diagnose, predict + symptom, prevent, treat,
   medical, clinical, cure, patient, disease, symptom relief). Report each hit with
   `file:line` and the suggested rewrite from the skill's table.
2. **HealthKit sync.** For every `HKObjectType` requested anywhere in the codebase,
   verify the full chain: (a) a real consumer in `Shared/` that reads it for a shipped
   feature, (b) a row in `.claude/context/ml-spec.md`, (c) the entitlement in
   `project.yml` for each target that reads it, (d) a purpose string whose wording
   passes check 1. A type failing any link → no-go item.
3. **Battery budget total.** Inventory every recurring wake-up on the watch target:
   timers, observer queries, `WKApplication` background refreshes, complication
   reloads, extended runtime sessions. Sum the stated daily-drain estimates and
   compare against the budget in `.claude/skills/watchos_budget/SKILL.md`. Any
   recurring mechanism with no stated cost → no-go item (unreviewable ≠ free).
4. **Network egress.** Find every outbound network call. The only allowed destination
   is WeatherKit, and its requests must carry no health or check-in data (location
   only). Anything else — analytics SDK, crash reporter with custom payloads,
   third-party endpoint → no-go item.
5. **Complication readability.** Each complication renders one number or one state.
   Dense text or multi-value layouts → flag.
6. **Cold start.** Confirm the risk output is defined for 3–7 days of history (the
   population-prior blend exists and is reachable). If the model silently requires
   more, that is a no-go item.

## Report format

Two sections, nothing else:

- **NO-GO** — items that block submission, each with `file:line`, the rule violated,
  and the minimal fix.
- **WARN** — items worth fixing but not blocking.

Finish with one line: `GO` or `NO-GO (N items)`. Do not soften a NO-GO into prose; an
App Review rejection costs a full review cycle.
