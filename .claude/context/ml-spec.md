# ML spec

Ground truth for the forecast model: label definition, feature registry, validation
protocol, metrics. Procedure ("how to work on it") lives in
`../skills/ml_pipeline/SKILL.md`; this file holds the facts that procedure operates on.

**If this file contradicts the code, this file is the bug.** Update it in the same PR as
the code change.

## Status

| | |
| ------------------------- | -------------------------------------------------------- |
| Domain types | `Shared/Models/` — `Pressure` (hPa), `PressureSample`, `CheckIn`, `CheckInIntensity` (1–10, **higher is worse**), `MedicationEntry` (name, dose, `takenAt`), `MedicationHistory` (recall of the user's own earlier entries — proposes nothing; also groups them into `MedicationSummary` for the medications screen, arranged by `MedicationOrder` — recency or the reader's own alphabet, and nothing that ranks), `CheckInHistory` (+ `HistoryPeriod`, `HistorySummary`, `HistoryDay`, `MonthGrid` — calendar arithmetic and counting for the History screen; **display only, feeds no feature**), `WellbeingTag` (user-owned, open set), `UserProfile` (+ `avatarImageData` — a UI-only thumbnail the profile screen draws instead of an initial: never a feature, never in an outbound payload), `HealthSample` (+ `HealthMetricValue`, unit fixed by case) |
| Label | defined — `Shared/Models/WellbeingLabel.swift` (§1) |
| Persistence | `CheckInStore` / `PressureSampleStore` / `WellbeingTagStore` / `UserProfileStore` / `HealthSampleStore` protocols + in-memory doubles in `Shared/Persistence/`. SwiftData: `UserProfileStore` + `WellbeingTagStore` + **`CheckInStore` via `SwiftDataCheckInStore`** all on `BarosenseModelContainer` (CloudKit off; check-ins share that container because they reference the tag vocabulary, and are indexed on `timestamp`; medication entries are stored inline on the check-in row, not as a model of their own, via `StoredMedication` whose `takenAt` is optional in storage and falls back to the check-in's timestamp on read); `HealthSampleStore` via `SwiftDataHealthSampleStore`; **`PressureSampleStore` via `SwiftDataPressureSampleStore`** (own container, indexed on `timestamp`, runs on both targets). Every store is durable — nothing resets on launch |
| Check-in capture | **shipped, iPhone only** — a sheet from the tab bar's raised centre action (`Barosense/Screens/Log/`). One row per check-in: a point on the 1–10 intensity scale, any number of tags, any number of medication entries (free text, never interpreted; each carries its own `takenAt`, which may be hours before the check-in). **No free-text note is captured any more** — the field was removed from the form; `CheckIn.note` still exists, is still stored, and is now always `nil` on anything the app writes. The intensity **opens at 5** and needs no interaction, so a saved check-in that was never adjusted records a 5 — watch the recorded distribution for a spike at exactly 5 before trusting the base rate. Written straight to `SwiftDataCheckInStore`; no edit or delete UI yet, and the watch still cannot log one. The medication sheet (`AddMedicationSheet`) offers back names and doses from the last 90 days of the user's own entries — recall only, nothing shipped or inferred |
| Check-in review | **shipped, iPhone only** — the History destination (`Barosense/Screens/History/`): a period picker (month / 3M / year / all), a card counting check-ins, the two most-used tags and medication entries in that window, and a month grid whose cells carry the day's **peak** intensity. Under it a row to "My medications", which groups the same entries by name (`MedicationSummary`). Read-only: nothing on either screen edits or deletes a check-in, and neither surface relates a medication to how the user felt |
| Feature pipeline | Health features at `t` computed by `HealthFeatureExtractor` (`Shared/Features/`). Pressure / WeatherKit / check-in features still planned |
| Model | not trained; health and barometer raw samples are now accumulateable on disk. **Nothing on screen is model output.** The Now screen's two meter cards are `WeatherTriggerIndex` (§7 baseline #2, made visible) and `TrainingDataProgress` (rows on disk against §4's blend point) — both display-only, both explained under §2.1. The ⓘ on the second opens `TrainingProgressSheet`, which states in words that the bar counts check-ins and not accuracy |
| Barometer ingest | **shipped** — `Shared/Pressure/`. **Phone-only sensor** via `CoreMotionPressureSource` (`CMAltimeter`, single-shot, kPa→hPa at the boundary) → `PressureSampleRecorder` → durable local log on the phone. **The watch never samples**: it receives one `PressureDisplaySnapshot` over `WatchConnectivityPressureLink.updateApplicationContext` and displays it (see below). Cadence: `BGAppRefreshTask` requested every 15 min + foreground activation, floored at one reading / 15 min by `PressureSamplingPolicy`. Kill-switch: `PressureSamplingPolicy.isBackgroundRefreshEnabled`. Cost: provisional, unmeasured — see battery note below |
| HealthKit read set | **3 types read, 0 written** — `.restingHeartRate`, `.oxygenSaturation`, `.sleepAnalysis`, via `Shared/Health/HealthKitDataReader.swift`. `com.apple.developer.healthkit.access` stays `[]` in `project.yml`: that key lists health-record types, which this app does not read |
| Health ingest | `HealthSampleRecorder` via `HealthIngestController`. **Foreground:** 7 d lookback on scene activation + Now pull-to-refresh. **Background:** `HealthKitChangeObserver` — one `HKObserverQuery` per authorised type + `enableBackgroundDelivery(..., frequency: .hourly)`; signals coalesce (750 ms) into one 48 h lookback pull. Kill-switch: `HealthBackgroundDelivery.isEnabled`. Requires entitlement `com.apple.developer.healthkit.background-delivery` (iOS). watchOS does not register observers. Cost: provisional, unmeasured — see battery note below |

### Health background delivery — battery note (provisional)

iPhone only. Unmeasured on device; flip `HealthBackgroundDelivery.isEnabled` if drain is bad.

1. Wake: HealthKit, ≤1/h per type (`.hourly`); 3 types, coalesced when near-simultaneous.
2. Work duration: unmeasured; bound = one 48 h sample query + SwiftData upsert.
3. Powered while awake: HealthKit query only (no barometer, network, display).
4. Doubling to 2 h: still covers SpO₂'s 24 h feature window; hourly kept for missed-wake margin. Not `.immediate`.
5. If wake never fires: foreground 7 d pull is the backstop; pipeline tolerates gaps.
6. Daily drain %: unknown until Instruments on device.

### Barometer sampling — battery note (provisional)

iPhone. Unmeasured on device; flip `PressureSamplingPolicy.isBackgroundRefreshEnabled`
if drain is bad.

1. Wake: `BGAppRefreshTask` with `earliestBeginDate` 15 min out (iOS grants far fewer —
   `earliestBeginDate` is a floor, never a cadence), plus foreground activation. Upper
   bound 96 readings/day; the 15 min floor in `PressureSamplingPolicy` caps both paths.
2. Work duration: unmeasured. Bound per reading = one `CMAltimeter` start / first-sample /
   stop (≈1 s, hard-capped at 5 s), one SwiftData upsert, at most one
   `updateApplicationContext` write. A declined activation costs nothing at all.
3. Powered while awake: the barometer only, for that ≈1 s. No display, no network, no
   location, no HealthKit.
4. Loosening to 60 min would still satisfy `pressureHPa`'s 90 min tolerance (§2.1) but
   costs delta resolution: `pressureDeltaHPaPer3h` on an hourly grid is 3 points, on a
   15 min grid 12. 15 min is chosen for the delta features, not for `pressureHPa`.
5. If the wake never fires — and often it will not, since iOS grants `BGAppRefreshTask`
   from usage history and throttles it hard in Low Power Mode — foreground activation is
   the backstop, and on a phone that is the main source rather than a fallback. The
   overnight gap is real; `pressureCoverage6h` / `pressureCoverage24h` exist to report it.
6. Daily drain %: unknown until Instruments on device.
7. **Unverified:** that `CMAltimeter` delivers inside a `BGAppRefreshTask`. Expected — the
   app is executing for the length of the task — but not confirmed on device.

**Why the watch does not sample, and the phone does.** Both devices have a barometer, and
using both would look like free coverage. It is not: two devices at two altitudes writing
into one series manufactures exactly the contamination §3 is about, and nothing in a
`PressureSample` row says which device produced it. One sensor, one series.

Which one is a real trade. The watch is on the wrist, so it measures where the user
actually is; the phone can be on a desk while the user is outside. The phone wins anyway on
everything else: it is picked up dozens of times a day, it is charged nightly rather than
budgeted hourly, and its readings reach the training log with no radio hop that can stall.
The watch keeps a role — it displays the phone's newest reading and is where check-ins are
meant to be logged — but it contributes no rows.

Adding device provenance and a per-device altitude reference is the change that would make
sampling on both safe. It is not made.

### watchOS battery — barometer feature

Nothing to budget. The watch target starts no sensor, schedules no background refresh and
opens no pressure store. It holds one `WCSession` and reacts to at most one context
delivery per phone reading; the transport keeps a single slot rather than a queue, so a
watch off the wrist for six hours receives one context on its next wake, not twenty-four.

Every row below marked `planned` is a design decision, not shipped behaviour. Every
HealthKit row is additionally gated by `../skills/healthkit_permissions/SKILL.md`: no type
is requested until a consumer exists.

Numbers marked *provisional* were chosen from reasoning, not from data. Re-derive them
from the first real dataset and update this file.

---

## 1. Target label

```
poorWellbeing(checkIn) = checkIn.intensity >= 7    // 1–10 scale, 10 = worst
```

- Defined **once**, as `WellbeingLabel.poorWellbeingThreshold` in
  `Shared/Models/WellbeingLabel.swift`, with the rationale in a `///` comment. Never
  inlined at a call site.
- **The scale runs the opposite way to a wellbeing score**, and the comparison is `>=`.
  The form asks for intensity — how strong it was — so 10 is the worst end. This replaced a
  1–5 score where 1 was the worst; the storage attribute was renamed with it
  (`scoreRawValue` → `intensityRawValue`) precisely so rows written under the old meaning
  fail the range check and drop, rather than being read as their own opposite.
- The threshold is the **top four of ten**, which is the same 40% of the range the old
  scale's bottom two of five covered. Carried across rather than re-chosen, so moving to a
  finer scale did not quietly move the event definition with it.
- Tags and medication entries are recorded but do **not** enter the v1 label. Extending the
  label to `intensity >= 6 && !tagIDs.isEmpty` is an open question (§9).
- Medication text is user input and carries the `CheckIn.note` rule: never a feature, never
  in an outbound payload. `MedicationEntry.takenAt` is *not* text and could become a feature
  ("hours since last dose"); it is not one today, and making it one is an §9 question, not a
  quiet addition — it is also the field most likely to be wrong, since the user types it from
  memory.
 "Did they take something" is a fixed-width summary that *could*
  become one, and is not one today.
- The tag vocabulary is **open and per user**: `WellbeingTag.seeds` is only where a fresh
  install starts, and the user adds, renames and retires tags from there. A check-in
  stores `Set<WellbeingTag.ID>`, not tag text, so a rename does not rewrite history.
  Consequences for anything that consumes tags:
  - Per-tag features are **personal-model only**. A user-created id means nothing on
    another device, so tag features can never enter the population prior (§6). Only
    `.seeded` ids are comparable across users, and even those may have been renamed to
    mean something else.
  - Tag *text* is user input and is treated like `CheckIn.note`: never a feature, never in
    an outbound payload.
  - The vocabulary is unbounded, so one-hot encoding over all tags is not an option.
    Anything tag-derived has to be a fixed-width summary (count, "any", per-seeded-id).
- Changing the threshold invalidates every stored metric. Re-run the baselines in the
  same PR and put both sets of numbers in the body.

Prediction unit: one row per check-in, features computed at the check-in timestamp `t`.
The advance-warning variant predicts "will any check-in in `[t + 6 h, t + 30 h]` be poor";
both share this label, differing only in the feature cut-off. Only the same-check-in
variant is in v1 scope.

**Base rate: unknown.** It is per-user and cannot be assumed. Report it per fold, never
substitute a literature value.

---

## 2. Feature registry

No row here, no feature in the model. Columns: source, unit, expected sampling frequency
and minimum coverage, behaviour on a gap.

### 2.1 Barometer — highest weight, changes get extra review

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `pressureHPa` | `CMAltimeter` (iPhone) | hPa | opportunistic, target ≥1/15 min; needs a sample within 90 min of `t` | feature nil → row dropped | planned |
| `pressureDeltaHPaPer3h` | derived | hPa | ≥50% of the 3 h grid observed | nil | planned |
| `pressureDeltaHPaPer6h` | derived | hPa | ≥50% of the 6 h grid | nil | planned |
| `pressureDeltaHPaPer24h` | derived | hPa | ≥40% of the 24 h grid | nil | planned |
| `pressureVolatilityHPa24h` | derived (SD of hourly grid) | hPa | ≥40% of the 24 h grid | nil | planned |
| `pressureCoverage6h` | derived | fraction 0–1 | always computable | 0 | planned |
| `pressureCoverage24h` | derived | fraction 0–1 | always computable | 0 | planned |

Coverage is a first-class feature, not a debug field: it lets the model discount a delta
computed from two lonely samples. Below the stated minimum the feature is `nil` and the
model must handle absence explicitly — never emit a confidently-wrong value.

Grid: hourly, aligned to the hour, trailing from `t`. Gap policy: linear interpolation
across gaps ≤ 2 h; longer gaps stay holes and reduce coverage. Interpolated cells never
count toward coverage.

Every row here is still `planned` as a *feature*: raw `PressureSample` rows now accumulate
on disk (see Barometer ingest above), but nothing derives a feature from them yet. Readings
are stored **raw and unsmoothed**, so §3 can identify an altitude excursion from its
neighbours — impossible once the evidence is averaged away.

**Retention: five years.** `PressureRetentionPolicy` sets the horizon and
`PressureSampleRecorder` drops what is past it, at most once a day, on the write path. Five
calendar years is five passes over the annual cycle, which is the longest period any
seasonal effect in §2.1 could need; nothing in §5's forward-chaining splits assumes more. It
is a ceiling on file growth (~2 900 rows a month, ~175 000 at the horizon), not a target —
the bias is toward keeping. Two consequences for anyone fitting on this table: the training
window is bounded, and it is bounded on **one device**, because the store runs with
`cloudKitDatabase: .none` and nothing backs it up. A reinstall costs the whole history and
returns the model to the §4 cold-start path.

The chart's bucket means (`PressureBuckets`, `PressureChartRange.bucketSeconds`) are
**display only** and must never reach a feature. Averaging before differencing is a
low-pass filter, and a low-pass filter applied ahead of `pressureDeltaHPaPer3h` rounds a
real fall down toward "steady". The features build their own hourly grid from raw rows,
with the interpolation and coverage policy stated above.

`CheckInMarker` (`Shared/Pressure/CheckInMarker.swift`) is **display only** for the same
reason. It places a check-in onto the *drawn* line — bucket means included — so the chart can
mark when the user logged it, interpolating linearly and clamping to the ends inside a 2 h
tolerance. That is a chart join, not an alignment: a feature computed at `t` reads raw rows
under §2.1's own gap and coverage rules, which are stricter. Nothing in `Shared/Features/` may
read this type.

`PressureTrend` (`Shared/Pressure/PressureSeries.swift`) is **display only** and has no row
here on purpose. It buckets the trailing-3 h delta into rising / falling / steady for the
chart caption; the model consumes `pressureDeltaHPaPer3h` as a continuous value, and
collapsing it to three states throws away the resolution the model needs. Nothing in
`Shared/Features/` may read that type. Its ±1.0 hPa threshold and 1 h minimum span are
*provisional* and chosen from reasoning, not data.

`WeatherTriggerIndex` (`Shared/Pressure/WeatherTriggerIndex.swift`) is **display only**, for
the third time and the same reason. It is the Now screen's "Weather Trigger Index" card:
`|Δ hPa|` across the trailing 6 h, mapped linearly onto 0–1 between a noise floor of 2.0 hPa
(twice `PressureTrend.significantChangeHPa`, so the card and the chart caption agree about
where weather starts) and a *provisional* full scale of 6.0 hPa. Gated on
`pressureCoverage6h`'s own 50% minimum, counted in hourly cells; below it the value is `nil`
and the card says why rather than drawing a zero. The delta is raw first-to-last and is never
extrapolated to a full window. It is **unsigned**, which is precisely why the model must not
read it — `pressureDeltaHPaPer6h` is signed and continuous, and this throws both away.

It is baseline #2 of §7 rendered for the user. That is deliberate: with no trained model, the
only figure the app can honestly put on that card is the rule the model will have to beat. It
carries §3's altitude exposure in full — a one-way climb reads as weather — and there is no
de-trending, because there is no altitude reference. Same exposure `PressureTrend` already
ships with, now on a second surface.

`TrainingDataProgress` (`Shared/Models/TrainingDataProgress.swift`) is **display only** and
holds no feature either: check-ins on the device counted against
`targetCheckInCount = 40`, which is where §4's `w(n) = n / (n + k)` at `k = 30` first passes a
half. Both constants are *provisional* and move together — a change to `k` that leaves the
target at 40 makes the card's explainer wrong.

### 2.2 WeatherKit — forward-looking, the reason an *advance* warning is possible

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `forecastPressureDeltaHPaPer6h` | `HourWeather.pressure` | hPa | hourly forecast, ≤3 h stale | nil | planned |
| `forecastPressureDeltaHPaPer12h` | `HourWeather.pressure` | hPa | as above | nil | planned |
| `forecastPressureDeltaHPaPer24h` | `HourWeather.pressure` | hPa | as above | nil | planned |
| `forecastMinPressureHPaNext24h` | `HourWeather.pressure` | hPa | as above | nil | planned |

`Measurement<UnitPressure>` → hPa at the WeatherKit boundary, once. WeatherKit also
exposes a pressure-trend value; verify its exact type and semantics against current
documentation before using it — do not assume from this file.

Sensor and forecast are **separate feature families**. A WeatherKit value never
substitutes for a missing sensor sample: the phone's barometer is ground truth for "now",
WeatherKit for "next". Silently swapping them makes the two families indistinguishable in
attribution.

Outbound WeatherKit requests carry location and time only. Never a health-derived value.

### 2.3 HealthKit — all planned, none authorised

| name | source type | unit | sampling / min coverage | on missing | status |
| ---- | ----------- | ---- | ----------------------- | ---------- | ------ |
| `sleepDurationHours` | `.sleepAnalysis` | h | one session/night; needs a session ending ≤24 h before `t` | nil | **shipped** — `HealthFeatureExtractor` |
| `sleepAwakeningCount` | `.sleepAnalysis` | count | as above; requires `awake` segments to be recorded | nil | planned — blocked, see below |
| `hoursSinceWake` | derived from `.sleepAnalysis` | h | as above | nil | **shipped** — end of the same session as `sleepDurationHours` |
| `restingHeartRateBPM` | `.restingHeartRate` | bpm | ~1/day, published late | previous completed day, else nil | **shipped** — previous calendar day by sample `start` |
| `hrvSDNNMs` | `.heartRateVariabilitySDNN` | ms | sparse and irregular, a few/day at best | nil | planned — **not authorised**, no consumer |
| `oxygenSaturationFraction` | `.oxygenSaturation` | fraction 0–1 | model- and region-dependent; frequently absent; feature lookback 24 h | nil | **shipped** — latest with `end <= t` inside 24 h |

Raw samples are written by `HealthSampleRecorder` into `HealthSampleStore` as `HealthSample`
rows, one per HealthKit object, keyed by HealthKit's own identifier so a repeated read
replaces rather than duplicates. The durable implementation is
`SwiftDataHealthSampleStore` — history accumulates across launches. Features at `t` are a
separate pure step (`HealthFeatureExtractor`); the Now-screen snapshot does not feed the
model.

What is logged from `.sleepAnalysis` is the *asleep* stages only — `asleepUnspecified`,
`asleepCore`, `asleepDeep`, `asleepREM`. `inBed` is excluded because it is not sleep, and
`awake` is excluded because nothing consumes it; that is what blocks `sleepAwakeningCount`.
A sleep *session* for features is a maximal run of overlapping or abutting asleep
intervals; the most recent session ending ≤24 h before `t` supplies both
`sleepDurationHours` and `hoursSinceWake`.

The display window definitions live in `HealthMetricsWindow` (`Shared/Health/`) and are
*provisional*: 48 h staleness for resting heart rate, 24 h for blood oxygen, trailing 24 h
for sleep, 7 d of lookback per refresh. They govern the Now screen only — a feature
computed at `t` re-windows from the store and must not inherit them.

Two rules that apply to this whole family:

1. **No look-ahead.** Only samples with `endDate <= t` may enter a feature computed at
   `t`. Daily aggregates (`restingHeartRate`) summarise a window that may extend past the
   prediction time — using today's value for a morning prediction leaks the future. Use
   the previous completed day.
2. **Absence is normal, not an error.** Read authorisation denial is indistinguishable
   from "no data" (`../skills/healthkit_permissions/SKILL.md`), and Blood Oxygen
   availability varies by watch model and region. Every one of these features must be
   droppable with a stated confidence reduction, never a hard requirement.

### 2.4 Check-in context

| name | source | unit | sampling / min coverage | on missing | status |
| ---- | ------ | ---- | ----------------------- | ---------- | ------ |
| `priorCheckInScore` | check-in store | 1–5 | previous check-in ≤48 h before `t` | nil | planned |
| `hoursSincePriorCheckIn` | derived | h | as above | nil | planned |
| `hourOfDay` | `t` | 0–23, cyclic-encoded | always | — | planned |

`priorCheckInScore` is strongly autocorrelated with the label and will dominate a small
model. Keep it, but it is also baseline #3 (§7) — if it alone matches the model, the
weather signal is not doing any work and that must be reported.

---

## 3. Altitude contamination

Raw barometer output is *station* pressure. Near sea level ≈ **8.3 m/hPa** (0.12 hPa/m),
so a 10 m elevator ride ≈ 1.2 hPa — the same size as a meteorologically meaningful 6 h
change. Left uncorrected, the model learns "the user took the stairs".

**The obvious fix is circular:** `CMAltimeter.startRelativeAltitudeUpdates` derives
relative altitude *from pressure*, so it cannot separate weather from altitude on its own.
Do not use it as the de-trending reference.

v1 approach — reject rather than correct:

- **Rate gate.** Synoptic pressure change is roughly ≤2 hPa/h even in a rapidly deepening
  system. A change >3 hPa within 10 min is altitude or a bad sample, not weather: drop
  both samples and reduce coverage. *Provisional* thresholds; validate on real traces.
- **Plausibility gate.** `Pressure.isPlausible` (800–1100 hPa) already rejects unit
  mix-ups and bad reads at the boundary.
- **Anchor on rest.** Prefer deltas between samples taken while the user is stationary
  (long-lived low-motion periods, e.g. overnight), which removes most short excursions.

Candidates deferred to §9: `CMAltimeter` absolute-altitude updates (fused with GNSS, so
not circular — verify hardware and platform availability before designing around it), and
CoreLocation altitude as an independent but noisy reference. Both cost battery
(`../skills/watchos_budget/SKILL.md`).

---

## 4. Cold start and the population prior

Requirement: useful output with **3–7 days** of history.

Arithmetic that constrains everything else. At 2–3 check-ins/day, 7 days ≈ 14–21 labelled
rows. At a plausible 15–25% positive rate that is **2–5 positive events**. With a rule of
thumb of ~10 positive events per free parameter, a personal model at day 7 supports well
under one parameter.

Consequences, not opinions:

- Day 7 output is essentially the **population prior**, nudged. A genuinely personal model
  is not statistically meaningful before roughly 3–4 weeks of positives.
- Blend: `w(n) = n / (n + k)`, `n` = labelled rows with usable coverage (not calendar
  days), `k = 30` *provisional*. `k` lives in **one** named constant in `Shared/`.
- **Feature budget: ≤6 features in the personal component.** More parameters than events
  is memorisation. The prior may be richer; the personal part may not.
- The UI states reduced confidence during cold start. Wording per
  `../skills/appstore_compliance/SKILL.md`.

The population prior ships in the bundle. Sourcing it is an open question (§9) — there is
no dataset yet, and shipping a prior fitted on nothing is worse than shipping the "pressure
dropped >X hPa" rule as the day-1 model.

---

## 5. Validation protocol

- **Forward-chaining only, per user.** Random k-fold leaks future into past and is
  rejected in review, no exceptions.
- **Train/test gap ≥ 24 h** — the longest feature window. Without it the 24 h features
  straddle the boundary and leak anyway.
- Two evaluation modes, reported separately:
  1. *Personal* — forward-chaining within one user, ≥3 folds, test fold ≥3 days.
  2. *Cold start* — leave-one-user-out on the prior, scored on that user's first 7 days
     only. This is the number that answers "does the app work on day 3".
- Any user with zero positive events in a fold is excluded from that fold's precision, and
  the exclusion is reported. Do not silently average it away.

---

## 6. Decision threshold

The model outputs a probability; the product sends notifications. Separate concerns:

- Threshold is chosen on the validation folds, never on test.
- *Provisional* ship gate: **precision ≥ 0.5** on the positive class, at whatever recall
  results. A false advance warning costs trust faster than a miss costs value.
- *Provisional* cap: **≤1 advance notification per day.** Bounds the damage of a bad
  threshold and is independent of model quality.
- Output surfaced as a graded risk state, never a yes/no or a percentage presented as
  fact.

Both provisional numbers are product decisions — confirm with a human before they ship.

---

## 7. Metrics and baselines

Report, on the positive class, for every model change:

`precision`, `recall`, `PR-AUC`, `base rate`, `n`, `positive count`.

Accuracy alone is not acceptable — the positive class is rare and a majority-class
predictor scores well on it while being useless.

Beat **all three** baselines or say so plainly in the PR body:

1. **Majority class** — always predict "not poor".
2. **Pressure rule** — `pressureDeltaHPaPer6h < -X`, X tuned on train only.
3. **Persistence** — predict the previous check-in's label.

Baseline 3 is the honest one: self-reported wellbeing is autocorrelated, and a weather
model that cannot beat "yesterday repeated" has not demonstrated a weather signal. A model
that loses to a threshold rule costs battery and adds risk for nothing.

---

## 8. Test fixtures

The pipeline runs from plain XCTest with synthetic input — no `HKHealthStore`, no
`CMAltimeter`, no network. Required fixtures:

- clean hourly pressure series, 14 days;
- series with a 12 h gap (coverage must drop, features must go nil, nothing may crash);
- ~10 hPa step over 5 min (altitude — must be rejected by §3, not learned);
- user with 3 days of history (cold start must still produce output);
- user with zero positive labels (metrics must degrade gracefully, not divide by zero);
- kPa-valued input reaching the boundary (must be rejected or converted, never silently
  10× off).

---

## 9. Open questions

Each needs a decision before v1 ships; anything architectural gets an ADR in
`context/decisions/`.

1. **Population prior source.** No dataset exists. Options: ship the pressure rule as the
   day-1 model and start personal fitting immediately; or a small hand-specified prior from
   literature effect sizes, clearly labelled as a guess.
2. **Label extension** to `score <= 3 && !tagIDs.isEmpty`. Needs real check-in
   distribution. Note the vocabulary is user-owned, so "has any tag" is the only form of
   this that means the same thing for every user.
3. **Altitude reference** — absolute-altitude updates vs. CoreLocation vs. rejection only.
   Battery cost decides it.
4. **Advance-warning horizon** — the 6–30 h window in §1 is assumed, not validated.
5. **Cold-start notifications** — whether to notify at all while output is prior-dominated.
6. **CloudKit sync of derived features.** Apple's HealthKit terms restrict off-device
   storage of health data; this is a gated ADR, not a default
   (`../skills/healthkit_permissions/SKILL.md`).
