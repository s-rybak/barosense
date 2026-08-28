# ML spec

Ground truth for the forecast model: label definition, feature registry, validation
protocol, metrics. Procedure ("how to work on it") lives in
`../skills/ml_pipeline/SKILL.md`; this file holds the facts that procedure operates on.

**If this file contradicts the code, this file is the bug.** Update it in the same PR as
the code change.

## Status

| | |
| ------------------------- | -------------------------------------------------------- |
| Domain types | `Shared/Models/` — `Pressure` (hPa), `PressureSample`, `CheckIn`, `CheckInIntensity` (1–10, **higher is worse**), `MedicationEntry` (name, dose, `takenAt`), `MedicationHistory` (recall of the user's own earlier entries — proposes nothing; also groups them into `MedicationSummary` for the medications screen, arranged by `MedicationOrder` — recency or the reader's own alphabet, and nothing that ranks), `CheckInHistory` (+ `HistoryPeriod`, `HistorySummary`, `HistoryDay`, `MonthGrid` — calendar arithmetic and counting for the History screen; **display only, feeds no feature**), `WellbeingTag` (user-owned, open set), `UserProfile` (+ `avatarImageData` — a UI-only thumbnail the profile screen draws instead of an initial: never a feature, never in an outbound payload), `HealthSample` (+ `HealthMetricValue`, unit fixed by case), `CheckInHealthContext` (the pulse / SpO2 / sleep-hours stamp on a check-in — every field optional, each gated by `HealthMetricValue`'s own plausibility ranges, and `nil` on `CheckIn.health` means *nothing looked* where an empty stamp means *looked, found nothing*) |
| Label | defined — `Shared/Models/WellbeingLabel.swift` (§1) |
| Persistence | `CheckInStore` / `PressureSampleStore` / `WellbeingTagStore` / `UserProfileStore` / `HealthSampleStore` protocols + in-memory doubles in `Shared/Persistence/`. SwiftData: `UserProfileStore` + `WellbeingTagStore` + **`CheckInStore` via `SwiftDataCheckInStore`** all on `BarosenseModelContainer` (CloudKit off; check-ins share that container because they reference the tag vocabulary, and are indexed on `timestamp`; medication entries are stored inline on the check-in row, not as a model of their own, via `StoredMedication` whose `takenAt` is optional in storage and falls back to the check-in's timestamp on read; the health stamp is three plain columns plus a `hasHealthStamp` flag, because a SwiftData composite attribute whose every field is `nil` reads back as `nil` and would lose the *looked-and-found-nothing* / *nothing-looked* distinction); `HealthSampleStore` via `SwiftDataHealthSampleStore`; **`PressureSampleStore` via `SwiftDataPressureSampleStore`** (own container, indexed on `timestamp`, runs on both targets). Every store is durable — nothing resets on launch |
| Check-in capture | **shipped, iPhone only** — a sheet from the tab bar's raised centre action (`Barosense/Screens/Log/`). One row per check-in: a point on the 1–10 intensity scale, any number of tags, any number of medication entries (free text, never interpreted; each carries its own `takenAt`, which may be hours before the check-in). **No free-text note is captured any more** — the field was removed from the form; `CheckIn.note` still exists, is still stored, and is now always `nil` on anything the app writes. The intensity **opens at 5** and needs no interaction, so a saved check-in that was never adjusted records a 5 — watch the recorded distribution for a spike at exactly 5 before trusting the base rate. Written straight to `SwiftDataCheckInStore`; no edit or delete UI yet, and the watch still cannot log one. The medication sheet (`AddMedicationSheet`) offers back names and doses from the last 90 days of the user's own entries — recall only, nothing shipped or inferred. Every saved check-in is also **stamped with the pulse, SpO2 and hours of sleep** standing at the moment the sheet was opened (`CheckIn.health`, §2.4) — one Health read per check-in, started when the sheet opens and collected at save |
| Check-in review | **shipped, iPhone only** — the History destination (`Barosense/Screens/History/`): a period picker (month / 3M / year / all), a card counting check-ins, the two most-used tags and medication entries in that window, and a month grid whose cells carry the day's **peak** intensity. Under it a row to "My medications", which groups the same entries by name (`MedicationSummary`). Read-only: nothing on either screen edits or deletes a check-in, and neither surface relates a medication to how the user felt |
| Notifications | **shipped, iPhone only** — `Shared/Notifications/` + `Barosense/Notifications/`. One kind: a "How are you feeling?" check-in reminder, placed at the time of day this user's own check-ins cluster around (`CheckInRhythm` — circular mean over the last 30 d, needs 3 check-ins and a resultant ≥ 0.35, otherwise 20:00). Planned 7 days deep (`CheckInReminderPlanner`), suppressed on a day already logged. **Every notification the app decides to send is a row first** — kind, language, slot, state (`scheduled` / `delivered` / `suppressed` / `cancelled`) — on `BarosenseModelContainer` via `SwiftDataNotificationStore`, pruned at 30 d. `NotificationDispatcher` is the only path to `UNUserNotificationCenter` and enforces `NotificationBudget`: **at most 3 per local day across every kind**, counted off the stored rows so it survives a relaunch. **Display-only in the ML sense — no row here feeds a feature, and no notification body carries a health value.** Permission is never requested by a reconcile pass: `CheckInReminderPrimer` explains the reminder once per install and only its own button reaches iOS, after which the Settings switch is the second route — iOS grants one prompt ever, and an unexplained one loses the feature for that install. A tap routes to the check-in sheet (`NotificationRouter` + `NotificationResponder`, registered in `BarosenseApp.init` because a tap that launched the app is delivered as soon as launching finishes); the kind travels in `userInfo` so a cold launch need not open the store to know where to go. Kill switch: `CheckInReminderPlanner.isEnabled`. Cost: no new wake source — see battery note below |
| Location epochs | **shipped, iPhone only** — `Shared/Location/` + `Shared/Pressure/LocationEpochResolver.swift` + `Barosense/Location/`. One `PressureLocationEpoch` per place the user has been: coordinate rounded to **0.1°** (~11 km), city / region / country, `startedAt`. A new epoch is opened past a **25 km** threshold and only then is the geocoder called — `MKReverseGeocodingRequest` (`CLGeocoder` is deprecated as of iOS 26.0, this project's own deployment target) — at most **once per epoch**, its limits being unpublished. `PressureSample.locationEpochID` references it and is optional at every layer: rows written before the epoch table read back `nil` and are not dropped. It is **read**, not only written: `PressureOffsetCalibrator` and the local fit both take only the readings from epochs within 25 km of the current one (`LocationEpochResolver.samePlaceEpochIDs(as:among:)`), because the station-to-MSLP offset is dominated by elevation and a window straddling a move medians two places together — tens of hPa at Kyiv's 180 m against sea level. A log with no stamps at all, and a device with no current epoch, are filtered by nothing. Location is **when-in-use and foreground-only** (`CoreLocationService`, one-shot `requestLocation`), and only on an activation the barometer's 15-minute floor actually admits — at most four fixes an hour however often the app is opened; a background wake reads the stored epoch and powers no radio. `NSLocationDefaultAccuracyReduced` ships `true`, so precise location is never asked for and `.reducedAccuracy` is rendered as a working grant. Durable via `SwiftDataPressureLocationEpochStore` on the barometer container |
| Forecast archive | **shipped, iPhone only** — `Shared/Weather/` + `Shared/Persistence/SwiftDataWeatherForecastStore.swift`. Rows `(issuedAt, validAt, meanSeaLevelPressureHPa, temperatureC)`, **append-only per issue**, own container, 90 d retention on the write path. Filled by `WeatherKitForecastProvider` — `.current` + `.hourly` in **one** `weather(for:including:)`, which is one unit of quota — under `WeatherRequestBudget`: **≤4 requests/local day** at 08/12/16/20 with the first slot moved to the user's wake hour, counted off stored rows so it survives a relaunch. One historical request per install (7 d, ending at the start of today) bootstraps offset calibration against barometer history already on disk; success is **recorded** rather than inferred from the archive, so a failed attempt is retried on the next launch instead of being mistaken for a completed one, and a wiped archive bootstraps again. Two switches, both of which must say yes: `WeatherForecastPolicy.isEnabled` (shipped) and `WeatherKitPreferenceStore` (the user's, default on after `WeatherKitPrimer`). A revoked location grant stops requests **without spending slots**. Cost: no new wake source — it rides the barometer's `BGAppRefreshTask` and foreground activations |
| Local pressure model | **shipped** — `Shared/Pressure/LocalPressureModel.swift` + `HourlyPressureGrid.swift`. **Regression target is the hourly change, not the level**: `Δyₜ = Σψⱼ Δyₜ₋ⱼ` plus solar S1/S2 harmonics at the top size, **no intercept**, closed-form least squares over a 30-day hourly grid, ridge `1e-6` so a flat log degrades instead of going singular. Differencing is not a refinement — it is what keeps the forward iteration bounded. Station pressure has lag-1 hourly autocorrelation ~0.99, so an unconstrained fit on levels estimates a root sitting on the unit circle from a handful of rows and nothing stops it landing outside; measured on the real device log 2026-08-22 (30 observed cells / 3 days) the level polynomial had a root at **|λ| = 1.207** and the drawn curve read 1001 hPa at 1 h, 1011 at 6 h and **1139 at 18 h**. Differencing imposes the unit root instead of estimating it; dropping the intercept refuses to extrapolate a drift, which on that same log implied a long-run level 21 hPa from the window mean. **Tendency persistence is capped at 0.9** (`maximumTendencyPersistence`): the e-folding life of a tendency is `−1/ln r` hours, so 0.9 is 9.5 h — the order of a mid-latitude trough — where 0.98 would grant it 49 h; it also bounds the whole curve at `d × r/(1−r)` = nine times the last hourly change (≈5 hPa on a 0.6 hPa/h trace, ≈18 on a violent 2 hPa/h one). Enforced by scaling lag *j* by `γʲ`, which multiplies every root by `γ` exactly and leaves the fit's shape, rather than by rejection — a root at 0.999 is stable and still draws an 18-hour ramp. Radius found by bisection on the Schur–Cohn step-down test, no root finder. **The size is chosen from the log, not fixed**: `specificationLadder` tries 3 lags+S1+S2 (7 params) → 3 lags (3) → 2 lags (2) → 1 lag (1) and takes the first the data supports, gated on `max(6 rows, 1.5 x parameters)`. A design row for *k* lagged changes needs *k+2* consecutive hours — one more than the level fit, which is what differencing costs. **A rung with no harmonics may not keep an oscillating lag block**: there is one cycle this app knows about and it has four terms of its own, so when those are unaffordable the tide leaks into the lags and is extrapolated as their own dynamics. Measured on the waking-day fixture the 2-lag rung read the tide as a 20 h oscillation from a 9 h window and turned a fall into a rise by step 2 — RMSE 0.60 hPa over 1–6 h against persistence's 0.35, where the 1-lag rung below scores 0.22. Checked on the impulse response `hₜ = Σψⱼhₜ₋ⱼ` across the drawn range; not applied where harmonics are fitted, since rejecting them there costs real skill (0.03 vs 0.35 on a flat log). Behind `LocalPressureModel.isOrderLadderEnabled`. Skill range **3–6 h** (`ForecastSource.localModel.skillRangeSeconds`) — a human decision, not a default: one sensor at one point cannot see advection, so extending it needs a measurement first. **Drawn** range **18 h** (`ForecastSource.localModel.rangeSeconds`, human decision 2026-08-22, narrowed from 36 h the same day) so the chart's day button has a forward half; the two are separate constants and `PressureForecastReader.features` clips the curve back to the skill range before the feature vector sees it, so no §2.2 delta is ever filled by an 18-step extrapolation. Fits from **one waking day** of history; the absolute floor of 6 rows is the **skill** range in hours (not the drawn one — reading 18 there would triple the cold-start gate, and the drawn range has already moved twice). The forward iteration carries a level and a tendency, seeded from the latest run of **`k+1` consecutive** hourly cells and anchored at the last level the sensor recorded, so the curve joins the user's own line instead of being pulled toward a 30-day mean a three-day log does not have; its range is measured from that anchor, not from the clock. Altitude excursions are rejected before the fit by the §3 rate gate; gaps ≤2 h are bridged and never counted as coverage. Coverage is measured over the **span the log reaches across**, not over the nominal 30-day window. The band is scaled from the **residual degrees of freedom** (`rows - parameters`), not the row count, and the residual is measured **after** stabilising — so pulling an explosive fit down widens the band it is drawn with. Against persistence, scored on each fixture's own continuation (trend **plus** tide, not the trend alone): a full log wins at every hour 1–6; the thin waking-day log loses the first four hours and wins the last two, RMSE 0.22 against 0.35 — which is what the literature says, not a defect. Refit at most daily, on a foreground activation — **no new wake source** |
| Forecast skill | **shipped** — `Shared/Features/ForecastSkillReport.swift`, run by `WeatherForecastController` after every request that lands and logged through `BarosenseLog.pressure` (never shown: nothing on screen may present model output as a claim). Scores past forecasts against what the barometer went on to record, per horizon (1/3/6 h), against **persistence**. This is the first §7 baseline comparison the app can actually run: the ground truth arrives by itself a few hours later, so no dataset is needed. Derived from the 90-day raw archive — there is deliberately no second table of realised forecasts |
| Feature pipeline | Health features at `t` computed by `HealthFeatureExtractor` (`Shared/Features/`). **Forecast features computed on device, not yet consumed** — `ForecastFeatureExtractor` (§2.2) via `PressureForecastReader.features(asOf:)`, run by `WeatherForecastController` after every request that lands, under `issuedAt <= t`, past the ≤12 h staleness gate, calibrated into barometer coordinates. No model reads them: there is none. Pressure (§2.1) / check-in (§2.4) features still planned |
| Model | **The two-stage risk model is shipped and on screen** — see the row below. The wellbeing model of §1 (`intensity >= 7`) is still not trained: the two labels are different questions and only the second has been answered. The Now screen's two meter cards remain `WeatherTriggerIndex` (§7 baseline #2, made visible) and `TrainingDataProgress` (rows on disk against §4's blend point) — both display-only, both explained under §2.1. The ⓘ on the second opens `TrainingProgressSheet`, which states in words that the bar counts check-ins and not accuracy |
| Risk model | **shipped, iPhone only** — `Shared/Risk/`, drawn by `RiskOutlookCard` (Now screen, above the chart; Figma `7:654`) and marked on `PressureChartCard`'s forward line. Two stages over the §1.1 label (§2.5 features): a **day** stage (4 day-level columns, one row per day, Platt-calibrated — the only number on screen expressed as a percentage) and a **window** stage (9 columns, trained only on days that held an entry, ranking only). Both are logistic regressions fitted on device by penalised Newton, `C = 0.3`, `class_weight='balanced'`, verified against scikit-learn to 1e-3 on the coefficients and 1e-6 on the calibration (`RiskNumericsTests`). A **shipped prior** (`WellbeingRiskPrior`, the research notebook's own coefficients) is blended with the personal fit by §4's `w(n)`. The **gate** — the app's right to stay silent — sits on the window stage, not the day stage, and is a quantile tuned to `messagesPerWeekTarget = 2.5`. Scored over **every waking day the forward curve reaches** (96 h, the widest the chart draws), each day gated and ranked on its own — see §2.6. Refit at most daily on a foreground activation — **no new wake source**. The card's chip row carries **two figures the model did not produce**: the last three logged intensities, and `RiskOutlook.expectedIntensity` — the trailing 14-day mean, carried forward unchanged and drawn in the forecast's place. The model was never trained on intensity (§1.1), so the count of rings is the model's and their colour is the user's own recent average — which a legend line under the row states in words, because a figure of the user's own drawn inside a forecast ring reads as the model's. Both sides of the row are capped at three (`RiskOutlook.recentCheckInCount`, `expectedChipCount`); the chart below draws every marked stretch. Also drawn as the Insights screen's 1–3 day outlook (`WellbeingRiskForecast.outlook`, `RiskOutlookDay`, `RiskLevel`, `InsightsOutlookCard`): one tile per scored day with a window still ahead, banded on the two stages' own thresholds and printing a state rather than a percentage — see §2.6. Kill switches: `WellbeingRiskEngine.isEnabled`, `WellbeingRiskPrior.isEnabled` |
| Insights | **shipped, iPhone only** — `Shared/Insights/` + `Barosense/Screens/Insights/`. Four cards over 120 d (`WellbeingInsights.analysisWindowDays`, deliberately `WellbeingRiskTrainer.trainingWindowDays`): the `PressureWellbeingLink` correlation with a seven-day sparkline, the risk outlook above, most-used tags, and `WellbeingPatternNote`. The trace and the tag counts are `ReportBuilder.trace` / `.tagCounts` reused rather than respelled. **Display only in the ML sense — nothing here feeds a feature**, and the two new types are explained under §2.1. Every card is independently absent when its gate fails; the heading pushes to the existing `ReportScreen`. Cost: one foreground read per appearance of the tab, no new wake source, and the forecast rides the engine's existing 15-minute cache |
| Barometer ingest | **shipped** — `Shared/Pressure/`. **Phone-only sensor** via `CoreMotionPressureSource` (`CMAltimeter`, single-shot, kPa→hPa at the boundary) → `PressureSampleRecorder` → durable local log on the phone. **The watch never samples**: it receives one `PressureDisplaySnapshot` over `WatchConnectivityPressureLink.updateApplicationContext` and displays it (see below). Cadence: `BGAppRefreshTask` requested every 15 min + foreground activation, floored at one reading / 15 min by `PressureSamplingPolicy`. Kill-switch: `PressureSamplingPolicy.isBackgroundRefreshEnabled`. Cost: provisional, unmeasured — see battery note below |
| HealthKit read set | **4 types read, 0 written** — `.restingHeartRate`, `.oxygenSaturation`, `.sleepAnalysis` and `.heartRate`, via `Shared/Health/HealthKitDataReader.swift`. `.heartRate` is display-only: read on every refresh for the Now card, dropped before the log, no feature consumes it. `com.apple.developer.healthkit.access` stays `[]` in `project.yml`: that key lists health-record types, which this app does not read |
| Health ingest | `HealthSampleRecorder` via `HealthIngestController`. **Foreground:** 7 d lookback on scene activation + Now pull-to-refresh. **Background:** `HealthKitChangeObserver` — one `HKObserverQuery` per **logged** type (3 of the 4 read; `.heartRate` is display-only and deliberately gets none, or a worn watch would wake the app for readings nothing keeps) + `enableBackgroundDelivery(..., frequency: .hourly)`; signals coalesce (750 ms) into one 48 h lookback pull. **Every write is subject to `HealthIngestGate`**, held by `HealthSampleRecorder` and opened only once onboarding is behind the user — so after "delete my data" the log stays empty instead of refilling from the next observer firing. Kill-switch: `HealthBackgroundDelivery.isEnabled`. Requires entitlement `com.apple.developer.healthkit.background-delivery` (iOS). watchOS does not register observers. Cost: provisional, unmeasured — see battery note below |

### Health background delivery — battery note (provisional)

iPhone only. Unmeasured on device; flip `HealthBackgroundDelivery.isEnabled` if drain is bad.

1. Wake: HealthKit, ≤1/h per observed type (`.hourly`); 3 of the 4 read types, coalesced when near-simultaneous.
2. Work duration: unmeasured; bound = one 48 h sample query + SwiftData upsert.
3. Powered while awake: HealthKit query only (no barometer, network, display).
4. Doubling to 2 h: still covers SpO₂'s 24 h feature window; hourly kept for missed-wake margin. Not `.immediate`.
5. If wake never fires: foreground 7 d pull is the backstop; pipeline tolerates gaps.
6. Daily drain %: unknown until Instruments on device.

### Local pressure model — battery note

iPhone only, and there is nothing scheduled to budget.

1. Wake: **none**. The refit runs inside a foreground activation the user initiated, at most
   once a day (`LocalPressureModel.refitIntervalSeconds`). No timer, no observer, no second
   `BGAppRefreshTask` identifier.
2. Work duration: **measured at 16.6 ms** for a full 30-day refit — 720 hourly cells, ~716
   design rows, 7 parameters — in a Debug simulator build on the machine this was written on.
   Re-measured after the move to a differenced target, which took the richest fit from 8
   parameters to 7 and moved the number by 0.4 ms. The arithmetic is ~35 000 multiply-adds to
   build `XᵀX` plus a fixed ~230 for the 7×7 solve, and the stability bisection adds 48
   iterations of an O(k²) step-down on a vector of at most three, which does not register; a
   Release build on device will be materially faster, but 16.6 ms is the number actually observed
   and is the one recorded. Well inside the 100 ms at which `pressure-forecast-spec.md` §5 asks
   for the window to be reconsidered.
3. Powered while awake: nothing. No sensor, no network, no location, no HealthKit — it reads
   rows already on disk.
4. If the refit never runs: the previous day's coefficients keep being used, and the band it
   quotes is unchanged. Staleness costs accuracy, not correctness.
5. Daily drain %: not separately measurable. 17 ms once a day is below the noise floor of any
   instrument that would measure it.

### Risk model — battery note

iPhone only, and there is nothing scheduled to budget.

1. Wake: **none**. Both paths ride work the app was already doing — a foreground activation, or
   the barometer's existing `BGAppRefreshTask` landing a reading and the chart reloading. No
   timer, no observer, no second background task identifier.
2. Work duration: the refit is at most **once a day** (`WellbeingRiskEngine.refitIntervalSeconds`,
   the same cadence and the same reasoning as `LocalPressureModel`). It is a penalised Newton
   solve on a 10×10 system over at most ~1 000 window rows — on the order of 10⁵ multiply–adds,
   an order of magnitude above `LocalPressureModel`'s measured 16.6 ms. **Not yet measured on
   device**; measure with Instruments before this number is quoted as fact.
3. Between refits a forecast is memoised for 15 min (`forecastCacheSeconds`), which is
   `PressureSamplingPolicy`'s own floor — below it there cannot be a new reading to change the
   answer. A chart reload inside that window costs nothing. The daily throttle is keyed on
   `lastFitAt` **alone**: keyed on "there is a model" as well, a device under
   `minimumTrainingDays` — the state every new install starts in and stays in longest — failed
   the condition every time and re-read 120 days of samples and check-ins every 15 minutes. A
   fit that declined to happen is still an answer for today, and `invalidate()` is what makes a
   new check-in visible before tomorrow.
4. Powered while awake: nothing. No sensor, no network, no location, no HealthKit — it reads rows
   already on disk and the forward curve the chart asked for anyway.
5. If the refit never runs: the previous day's coefficients keep being used, and below the
   validation floor the shipped prior is used unchanged. Staleness costs accuracy, not
   correctness.
6. Daily drain %: unknown until Instruments on device.

### WeatherKit requests — battery and quota note

iPhone only. **No new wake source**: requests ride the barometer's existing `BGAppRefreshTask`
and foreground activations.

1. Wake: none of its own. `WeatherRequestBudget` allows a request at four moments a day
   (08/12/16/20, first slot moved to the user's wake hour from `.sleepAnalysis`); whichever
   execution the app is next granted spends the slot that is due.
2. Work duration: with nothing due — the common case — one indexed store read of the day's
   issue times, one `UserDefaults` array of the day's failed attempts, and no network at all.
   With a slot due, one `weather(for:including:)` and one batched write of ~240 rows.
2a. The wake hour reaches the refresher as a **closure**, not a value, so the health read behind
   it (three indexed reads over 48 h) happens only on a pass that gets as far as the budget —
   never on a device with the switch off or the grant refused — and is memoised for the local
   day by `WeatherForecastController`, so it costs one read a day rather than one an activation.
2b. A request that **fails** spends its slot too. The budget counts stored issues, so a failure
   used to leave the archive reading as empty and the slot as unspent, and a service refusing
   the build — an empty `DEVELOPMENT_TEAM`, an expired token, a day offline — turned every scene
   activation into another call. Failures are recorded in the same day-scoped ledger the budget
   counts from (`WeatherKitPreferenceStore.recordFailedRequest(at:)`); only failures, because a
   request that lands writes rows and those rows are the record.
3. Powered while awake: the network, for the length of one request. Never the barometer, never
   CoreLocation — the coordinate comes from the epoch table.
3a. After a request that lands — at most 4–5 times a day — the §2.2 feature row and the realised
   skill comparison are read off the same curve: two indexed store reads and a pass over the
   archive. No sensor, no radio, no HealthKit, and nothing at all on a pass with no slot due.
4. Quota: 4/day = 120/month per device, against 500 000/month per Apple Developer Program
   membership ≈ **4 160 devices**, and lower in practice because unspent slots are never spent.
   The quota belongs to the whole membership, not to this app; re-check before the install base
   approaches it.
5. Once per install, one extra historical request bootstraps offset calibration, so the day
   WeatherKit is first enabled can make five calls rather than four.
6. If the wake never fires: foreground activation is the backstop, exactly as it is for the
   barometer. A curve up to 12 h old is still valid (`WeatherForecastPolicy.maximumIssueAgeSeconds`)
   because it reaches 240 h ahead.

### Notifications — battery note

iPhone only. **Nothing here schedules work of Barosense's own.**

1. Wake: none. A `UNCalendarNotificationTrigger` is held and fired by the system's own
   scheduler; the app is not woken when it fires and is not woken to keep the queue warm.
2. Work duration: one reconcile pass on a scene activation the user initiated — one store
   read, at most `CheckInReminderPlanner.horizonDays` (7) cross-process `add` calls, and
   normally zero, because a plan that has not changed schedules nothing.
3. Powered while awake: nothing. No sensor, no network, no location, no HealthKit.
4. Daily drain %: not separately measurable — there is no background execution to measure.
5. The user-visible cost is interruptions, not battery, which is what `NotificationBudget`
   bounds at 3/day.

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

Numbers marked _provisional_ were chosen from reasoning, not from data. Re-derive them
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
  in an outbound payload. `MedicationEntry.takenAt` is _not_ text and could become a feature
  ("hours since last dose"); it is not one today, and making it one is an §9 question, not a
  quiet addition — it is also the field most likely to be wrong, since the user types it from
  memory.
  "Did they take something" is a fixed-width summary that _could_
  become one, and is not one today.
- The tag vocabulary is **open and per user**: `WellbeingTag.seeds` is only where a fresh
  install starts, and the user adds, renames and retires tags from there. A check-in
  stores `Set<WellbeingTag.ID>`, not tag text, so a rename does not rewrite history.
  Consequences for anything that consumes tags:
  - Per-tag features are **personal-model only**. A user-created id means nothing on
    another device, so tag features can never enter the population prior (§6). Only
    `.seeded` ids are comparable across users, and even those may have been renamed to
    mean something else.
  - Tag _text_ is user input and is treated like `CheckIn.note`: never a feature, never in
    an outbound payload.
  - The vocabulary is unbounded, so one-hot encoding over all tags is not an option.
    Anything tag-derived has to be a fixed-width summary (count, "any", per-seeded-id).
- Changing the threshold invalidates every stored metric. Re-run the baselines in the
  same PR and put both sets of numbers in the body.

### 1.1 The second label: check-in occurrence

There are **two** labels in this app and they answer different questions. Confusing them is the
single easiest way to make a false claim on screen.

```
checkInOccurred(window) = any CheckIn with timestamp in [window.start, window.end)
```

- Defined by `RiskWindowGeometry.windowStart(containing:)` and consumed as
  `RiskWindowRow.isLogged`. No threshold, no intensity: the event is that the user **made an
  entry**, whatever they recorded in it.
- It is a label about **behaviour**, not about the body. Every surface built on it says so — the
  chart's row reads "Check-in likely today", never "a harder day ahead"
  (`../skills/appstore_compliance/SKILL.md`).
- Why it exists at all: the §1 label needs the user to have logged *and* to have logged a 7+. On
  a 120-day trace that is a rare event inside a rare event. Occurrence is the outer one, it is
  what the research notebook found a barometric signal for, and it is the honest thing to
  forecast with the data that exists. Extending the risk model to condition on intensity is an
  open question, not a small change — see §9.
- **Prediction unit: one row per two-hour window of the waking day**, not one per check-in. That
  is a different unit from §1's and the two are not interchangeable: the base rate here is
  ~1 window in 9 on a day that holds an entry, and it is defined on days with no entry at all.
- The waking day is a restriction of the **domain**, not a feature. See `RiskWindowGeometry`: the
  boundary comes from the *early tail* of this user's entry hours, never from their most frequent
  hour, because the latter is a time-of-day feature and time of day is measured separately and
  deliberately excluded (`RiskBaseline.timeOfDay`). Early tail and not the outright minimum: the
  minimum is a one-sample estimator setting a domain that then stands for 120 days, so a single
  00:30 entry would turn a nine-window day into a twelve-window one and move the base rate and
  `randomHitAtOne` with it. `dayStartQuantile = 0.05`, degrading to the minimum below ~20 entries.
  The boundary itself is built from date components, so it holds its wall-clock hour across a DST
  transition; the windows inside the day are laid out in absolute hours from it, which makes the
  two transition days 23 and 25 hours long.

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

| name                       | source                      | unit         | sampling / min coverage                                              | on missing                | status  |
| -------------------------- | --------------------------- | ------------ | -------------------------------------------------------------------- | ------------------------- | ------- |
| `pressureHPa`              | `CMAltimeter` (iPhone)      | hPa          | opportunistic, target ≥1/15 min; needs a sample within 90 min of `t` | feature nil → row dropped | planned |
| `pressureDeltaHPaPer3h`    | derived                     | hPa          | ≥50% of the 3 h grid observed                                        | nil                       | planned |
| `pressureDeltaHPaPer6h`    | derived                     | hPa          | ≥50% of the 6 h grid                                                 | nil                       | planned |
| `pressureDeltaHPaPer24h`   | derived                     | hPa          | ≥40% of the 24 h grid                                                | nil                       | planned |
| `pressureVolatilityHPa24h` | derived (SD of hourly grid) | hPa          | ≥40% of the 24 h grid                                                | nil                       | planned |
| `pressureCoverage6h`       | derived                     | fraction 0–1 | always computable                                                    | 0                         | planned |
| `pressureCoverage24h`      | derived                     | fraction 0–1 | always computable                                                    | 0                         | planned |

Coverage is a first-class feature, not a debug field: it lets the model discount a delta
computed from two lonely samples. Below the stated minimum the feature is `nil` and the
model must handle absence explicitly — never emit a confidently-wrong value.

Grid: hourly, aligned to the hour, trailing from `t`. Gap policy: linear interpolation
across gaps ≤ 2 h; longer gaps stay holes and reduce coverage. Interpolated cells never
count toward coverage.

Every row here is still `planned` as a _feature_: raw `PressureSample` rows now accumulate
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
reason. It places a check-in onto the _drawn_ line — bucket means included — so the chart can
mark when the user logged it, interpolating linearly and clamping to the ends inside a 2 h
tolerance. That is a chart join, not an alignment: a feature computed at `t` reads raw rows
under §2.1's own gap and coverage rules, which are stricter. Nothing in `Shared/Features/` may
read this type.

`PressureTrend` (`Shared/Pressure/PressureSeries.swift`) is **display only** and has no row
here on purpose. It buckets the trailing-3 h delta into rising / falling / steady for the
chart caption; the model consumes `pressureDeltaHPaPer3h` as a continuous value, and
collapsing it to three states throws away the resolution the model needs. Nothing in
`Shared/Features/` may read that type. Its ±1.0 hPa threshold and 1 h minimum span are
_provisional_ and chosen from reasoning, not data.

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

`PressureWellbeingLink` (`Shared/Insights/PressureWellbeingLink.swift`) is **display only**,
for the fourth time and the same reason: the Insights screen's link card, and nothing in
`Shared/Features/` or `Shared/Risk/` may read it. Pearson *r* between a six-hour **fall**
(`p(t−6h) − p(t)`, the §2.1 quantity, sign kept) and the intensity reported `lagHours` later,
over `lagHoursSearched = [0, 3, 6, 9, 12, 18, 24]`; the largest |*r*| wins and the coefficient
is reported signed, so a user whose log lines up with *rising* pressure is told that rather
than shown a flipped number. Gates: `minimumPairs = 10`, and `nil` — never `0.00` — when
either column is flat, because "measured, no relationship" and "there was nothing to measure"
are different facts.

**The lag is chosen by search, so the surviving magnitude is inflated.** Seven candidates and
a single reported *r* with no correction is a screening number, not a tested hypothesis. The
three conservatisms that follow from that are deliberate and stated on the type: the pair
count is printed beside the coefficient, the bands are Cohen's 0.3 / 0.5 rather than something
flattering, and the lag is only ever drawn with a `~`. It carries §3's altitude exposure like
every other pressure surface — `HourlyPressureGrid` removes lift rides, a one-way climb
survives — which is also why it is built on a *change* and never on a level.

`WellbeingPatternNote` (`Shared/Insights/WellbeingInsights.swift`) is the same finding as a
hit rate, and is **gated on that link existing** so the two cards on the screen cannot disagree
about direction or lag. An episode is the first hour of a maximal run whose trailing six-hour
change clears `PressureTrend.significantChangeHPa` in the link's own direction — one onset per
weather system, not one per hour. A match is a §1.1-labelled entry within
`matchToleranceHours = 3` of `onset + lagHours`, counted once however many onsets it sits near.
`minimumEpisodes = 5`, `maximumEpisodes = 10`.

**Zero is reported.** A note with `matchedEpisodes == 0` is built like any other and the card
words it as a miss. The earlier behaviour — no note at all — was a second selection on top of
the lag search above: the rate is already counted at the best of seven lags fitted on this same
log, and suppressing the low end as well left a card that could only ever agree with itself.
The hit rate is a screening figure, in-sample, and the type says so. **Never an absolute
hectopascal threshold**: the log holds station pressure, so "below 1005 hPa" would be a claim
about the user's altitude as much as about the weather (§3).

Neither type feeds anything. The screen's forecast comes from `WellbeingRiskEngine` and is
passed in beside them — one risk model, one place it is fitted.

### 2.2 Forecast — forward-looking, and the reason an *advance* warning reaches days rather than hours

| name                             | source                       | unit | sampling / min coverage           | on missing | status  |
| -------------------------------- | ---------------------------- | ---- | --------------------------------- | ---------- | ------- |
| `forecastPressureDeltaHPaPer6h`  | forecast archive             | hPa  | hourly, issue age ≤12 h           | nil        | computed |
| `forecastPressureDeltaHPaPer12h` | forecast archive             | hPa  | as above                          | nil        | computed |
| `forecastPressureDeltaHPaPer24h` | forecast archive             | hPa  | as above                          | nil        | computed |
| `forecastMinPressureHPaNext24h`  | forecast archive             | hPa  | as above; curve must **reach** t+24 h | nil        | computed |
| `forecastSource`                 | `ForecastPressurePoint`      | enum | always, when any forecast exists  | —          | computed |
| `forecastUncertaintyHPa`         | `ForecastPressurePoint`      | hPa  | at a fixed 6 h horizon            | nil        | computed |
| `forecastIssueAgeSeconds`        | `ForecastPressurePoint`      | s    | as above                          | nil        | computed |

**`computed`, not `shipped`.** The row is built on the device — `PressureForecastReader.features(asOf:)`,
called by `WeatherForecastController` after every request that lands, which is where §4.5 of
`../context/pressure-forecast-spec.md` puts it: four numbers per request, off the curve the app
was just handed, under the same `issuedAt <= t` guard as everything else. What does not exist
yet is a consumer — there is no wellbeing model to train — so the values are observable and
logged rather than fitted on. Do not read `computed` as "in use".

The source is **the archive, not WeatherKit** — and, when the switch is off, the local model's
in-memory curve read through the same type. `WeatherForecastStore` is filled by WeatherKit
alone; `LocalPressureModel` is refitted from the barometer log and its points are **never
archived**, which is also why `ForecastSkillReport` can only score WeatherKit. What both
producers share is `PressureForecastReader.forecast(asOf:horizonSeconds:)` and
`[ForecastPressurePoint]`, so the feature pipeline has one branch, not two: it reads a curve and
does not know who wrote it. What differs between
the two producers is **range** and **band width**, not the shape of the data —
`../context/pressure-forecast-spec.md` §2.3.

That is why the last two rows exist and why they are not optional decoration. Coefficients
fitted on WeatherKit-quality inputs and then applied to a ten-times noisier local curve would
be applied with the same confidence, and nothing would report that the input had got worse.
The source and the band travel to the vector so the model can be told.

Hours past a source's range yield `nil`, which the "on missing" column already required. In the
WeatherKit-off case that means `Per12h` and `Per24h` are `nil` nearly always and `Per6h` is at
the edge of the local model's 3–6 h horizon — an expected reading of this table, not a defect.

**Staleness: issue age ≤12 h**, replacing the ≤3 h this table used to state. That norm was
wrong, not merely tight: requests are allowed at four slots a day (08/12/16/20, first slot moved
to the user's wake time), so at 07:00 the newest issue is eleven hours old and a 3 h rule was
violated about nineteen hours a day — for a curve that still holds 229 valid future hours.
`WeatherForecastPolicy.maximumIssueAgeSeconds` is the one place it is written.

It is a **gate**, in `ForecastPressurePoint.curve` and `ForecastFeatureExtractor`, not a note
next to a number. The archive outlives the requests by design — rows are kept 90 days and one
issue reaches 240 h ahead — so an ungated device that stopped asking (switch off, location
revoked, no network) goes on redrawing the same run for ten days and calling it the current
forecast. Past the norm there is no curve and no feature row from WeatherKit at all, and the app
falls through to the local model, which is the OFF-mode behaviour §2.1 of the feature spec
describes.

The age is **also** a carried field, and the two are not the same thing: the gate decides
whether a row may be read, `forecastIssueAgeSeconds` lets a model learn that an eleven-hour-old
curve is a worse input than a one-hour-old one. Band width follows the same logic — a point's
uncertainty is measured from its **`issuedAt`**, not from `now`, because how wrong a value is
was settled by the model run that produced it and the clock advancing does not improve it.

**`issuedAt <= t` is the whole leak guard.** A forecast row is identified by the pair
`(issuedAt, validAt)` and is never overwritten by a newer issue for the same hour. Overwriting
turns "the forecast for 14:00 last Tuesday" into hindsight, and a model fitted on hindsight
validates beautifully and fails in production — the §5 random-split failure in different
clothes. The filter is applied inside `WeatherForecastStore`, not left to callers.

**MSLP is not station pressure, and the difference is a datum, not a unit.**
`HourWeather.pressure` and `CurrentWeather.pressure` are **mean sea level** pressure — Apple:
*"This is a reduced pressure calculated by using observed conditions to remove the effects of
elevation from pressure readings."* `CMAltimeter` reports **station** pressure. Near Kyiv
(≈180 m) the two differ by about **22 hPa**, five to seven times a whole day's weather (3–5 hPa).
Comparing them without removing the offset is a larger error than every signal in §2.1 put
together. The field is therefore named `meanSeaLevelPressureHPa` rather than `pressureHPa`:
the unit is not the ambiguity that bites here, the datum is. `PressureOffsetCalibrator` measures
the offset from the data — rolling median of `station − MSLP` plus an analytic temperature
correction — rather than computing it from an altitude the app only half knows.

`Measurement<UnitPressure>` → hPa at the WeatherKit boundary, once, through
`WeatherMeasurement.hectopascals`. The runtime unit is **not documented**, so reading `.value`
directly is a silent 10× error the day a response arrives in kilopascals; §8's unit fixture
covers exactly that. Temperature goes through `WeatherMeasurement.celsius` for the same reason —
Fahrenheit read as Celsius puts the offset's temperature correction out by nearly 2×.
WeatherKit also exposes a pressure-trend value; its window and `steady` threshold are **not
documented**, so it is not used.

Sensor and forecast are **separate feature families**. A forecast value never substitutes for a
missing sensor sample: the phone's barometer is ground truth for "now", the archive for "next".
Silently swapping them makes the two families indistinguishable in attribution.

Outbound WeatherKit requests carry a 0.1°-rounded coordinate and a time. Never a health-derived
value. Health data does reach one decision — `.sleepAnalysis` moves the **first request slot of
the day** to the user's own waking hour (already-authorised type, already-read feature
`hoursSinceWake`) — and it reaches nothing else. The moment of a request, never its content.

Retention: raw rows 90 days (`WeatherForecastPolicy.rawRetentionDays`), pruned on the write
path like the barometer's; derived features indefinitely, being four floats a request.

### 2.3 HealthKit

| name                       | source type                   | unit         | sampling / min coverage                                               | on missing                       | status                                                        |
| -------------------------- | ----------------------------- | ------------ | --------------------------------------------------------------------- | -------------------------------- | ------------------------------------------------------------- |
| `sleepDurationHours`       | `.sleepAnalysis`              | h            | one session/night; needs a session ending ≤24 h before `t`            | nil                              | **shipped** — `HealthFeatureExtractor`                        |
| `sleepAwakeningCount`      | `.sleepAnalysis`              | count        | as above; requires `awake` segments to be recorded                    | nil                              | planned — blocked, see below                                  |
| `hoursSinceWake`           | derived from `.sleepAnalysis` | h            | as above                                                              | nil                              | **shipped** — end of the same session as `sleepDurationHours` |
| `restingHeartRateBPM`      | `.restingHeartRate`           | bpm          | ~1/day, published late                                                | previous completed day, else nil | **shipped** — previous calendar day by sample `start`         |
| `heartRateBPM` (display)   | `.heartRate`                  | bpm          | ~1/5 min while the watch is worn; read over a 2 h cap                 | nil                              | **shipped** — newest reading; no sample row, stamped onto each check-in (§2.4) |
| `hrvSDNNMs`                | `.heartRateVariabilitySDNN`   | ms           | sparse and irregular, a few/day at best                               | nil                              | planned — **not authorised**, no consumer                     |
| `oxygenSaturationFraction` | `.oxygenSaturation`           | fraction 0–1 | model- and region-dependent; frequently absent; feature lookback 24 h | nil                              | **shipped** — latest with `end <= t` inside 24 h              |

`.heartRate` is the one type read without being kept **as a sample row**. Its consumers
are the Now screen's pulse card, which needs the reading the watch just took, and the
health stamp on a check-in (§2.4), which keeps a copy of that same figure on the check-in's
own row; `restingHeartRateBPM` is a daily aggregate published hours after the day it covers
and read as stale under a "now" heading.
Nothing in this table consumes beat-to-beat readings, and a worn watch writes one every
few minutes — logging a foreground refresh of them would add roughly 2 000 rows a week
that no feature reads. `HealthMetricKind.isLoggedForTraining` is where that is decided,
and `readLookbackCap` is what keeps the read itself down to the card's 2 h staleness
window. If a feature ever wants them, both flip in one place — and the row mapping in
`SwiftDataHealthSampleStore` is already complete for it.

Raw samples are written by `HealthSampleRecorder` into `HealthSampleStore` as `HealthSample`
rows, one per HealthKit object, keyed by HealthKit's own identifier so a repeated read
replaces rather than duplicates. The durable implementation is
`SwiftDataHealthSampleStore` — history accumulates across launches. Features at `t` are a
separate pure step (`HealthFeatureExtractor`); the Now-screen snapshot does not feed the
model.

What is logged from `.sleepAnalysis` is the _asleep_ stages only — `asleepUnspecified`,
`asleepCore`, `asleepDeep`, `asleepREM`. `inBed` is excluded because it is not sleep, and
`awake` is excluded because nothing consumes it; that is what blocks `sleepAwakeningCount`.
A sleep _session_ for features is a maximal run of overlapping or abutting asleep
intervals; the most recent session ending ≤24 h before `t` supplies both
`sleepDurationHours` and `hoursSinceWake`.

The display window definitions live in `HealthMetricsWindow` (`Shared/Health/`) and are
_provisional_: 2 h staleness for heart rate, 48 h for resting heart rate, 24 h for blood
oxygen, trailing 24 h for sleep, 7 d of lookback per refresh. They govern the Now screen only — a feature
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

| name                     | source         | unit                 | sampling / min coverage            | on missing | status  |
| ------------------------ | -------------- | -------------------- | ---------------------------------- | ---------- | ------- |
| `priorCheckInScore`      | check-in store | 1–10                 | previous check-in ≤48 h before `t` | nil        | planned |
| `hoursSincePriorCheckIn` | derived        | h                    | as above                           | nil        | planned |
| `hourOfDay`              | `t`            | 0–23, cyclic-encoded | always                             | —          | planned |

**The health stamp.** What a saved check-in records beside the intensity, written by the
check-in form (`Barosense/Screens/Log/`) into `CheckIn.health`. Recorded, consumed by
nothing:

| name (on `CheckIn.health`) | source              | unit         | window at capture        | on missing | status                     |
| -------------------------- | ------------------- | ------------ | ------------------------ | ---------- | -------------------------- |
| `heartRateBPM`             | `.heartRate`        | bpm          | newest ≤2 h              | nil        | **shipped, recorded only** |
| `oxygenSaturationFraction` | `.oxygenSaturation` | fraction 0–1 | newest ≤24 h             | nil        | **shipped, recorded only** |
| `asleepHours`              | `.sleepAnalysis`    | h            | union over trailing 24 h | nil        | **shipped, recorded only** |

Only one of the three is otherwise unrecoverable, and it is why the stamp exists at all:
`.heartRate` is never written to the sample log (§2.3), so the pulse at a check-in's moment
is on this row or is gone. SpO2 and sleep are duplicated here deliberately — the stamp is a
record of the state the user was in when they reported, not a feature source. **A feature at
`t` re-windows the raw log and must not read the stamp**: the windows above are the Now
screen's display windows (`HealthMetricsWindow`), which are provisional and are not the
windows §2.3 states. `restingHeartRateBPM` is deliberately not stamped — it summarises a day
that may extend past the check-in's own timestamp, which is the look-ahead §2.3 rule 1
forbids.

`nil` on `CheckIn.health` means nothing looked (a row written before the stamp existed, or
by a client that does not read Health); a stamp whose three fields are empty means the app
looked and the Health store had nothing. The two must stay distinguishable or a coverage
count over the history cannot tell them apart. Everything else about absence follows §2.3
rule 2 unchanged.

Cost: one `HealthSampleRecorder.refresh` per saved check-in over `HealthMetricsWindow.checkInContext`
(24 h — the widest window the stamp quotes; heart rate narrows itself to 2 h), started when
the sheet opens so it overlaps the seconds the user spends on the form. 4 HealthKit queries
per check-in, ~10/day at the 2–3 check-ins §4 assumes, inside a screen the user opened.
**No new wake source.** What that read returns is still filed into the sample log, subject to
`HealthIngestGate` like every other write, so the read is not spent twice. The stamp itself
is written only from a screen that exists past onboarding — the same condition that opens the
gate — and `BarosenseDataEraser` removes check-ins, so stamps go with them.

`priorCheckInScore` is strongly autocorrelated with the label and will dominate a small
model. Keep it, but it is also baseline #3 (§7) — if it alone matches the model, the
weather signal is not doing any work and that must be reported.

---

### 2.5 Risk windows — the only family with a trained consumer

`RiskFeature`, in registry order. One row per two-hour window of the waking day; the five
window-level quantities are computed **per hour** and only then averaged over the window, because
averaging pressure first and differencing afterwards is a low-pass filter in front of the one
feature that carries the signal.

| name                  | source                     | unit | sampling / min coverage                       | on missing         | status  |
| --------------------- | -------------------------- | ---- | --------------------------------------------- | ------------------ | ------- |
| `pressureHPa`         | barometer + forecast curve | hPa  | hourly grid; ≥1 cell in the window            | median-imputed     | **shipped** |
| `levelDeficitHPa`     | derived                    | hPa  | as above                                      | median-imputed     | **shipped** |
| `drop6hHPa`           | derived                    | hPa  | needs a cell at exactly `t − 6 h`             | nil → imputed      | **shipped** |
| `drop24hHPa`          | derived                    | hPa  | needs a cell at exactly `t − 24 h`            | nil → imputed      | **shipped** |
| `low7dHPa`            | derived                    | hPa  | expanding from the first cell                 | 0                  | **shipped** |
| `dayLevelDeficitHPa`  | derived                    | hPa  | mean over the day's windows; ≥50% of them     | nil → imputed      | **shipped** |
| `dayDrop6hHPa`        | derived                    | hPa  | as above                                      | nil → imputed      | **shipped** |
| `dayDrop24hHPa`       | derived                    | hPa  | as above                                      | nil → imputed      | **shipped** |
| `dayLow7dHPa`         | derived                    | hPa  | as above                                      | nil → imputed      | **shipped** |

Four things about this table that are not obvious from it:

1. **Every quantity appears twice, per window and per day, and they answer different questions.**
   The day copies are constant inside a day by construction, so they cannot rank one window above
   another — measured, window columns alone reach hit@1 = 0.43 and day columns alone 0.11 at
   ROC-AUC 0.535, which is a coin. That is why there are two models and not one.
2. **The series is re-centred before any of this is computed.** `RiskPressureBaseline` shifts
   every reading by `1013 − median(trailing 30 days)`. The notebook's `1013` is the mean of the
   synthetic series it was fitted on, not a constant of nature; `CMAltimeter` reports *station*
   pressure, which near Kyiv is ~991 hPa, and an unshifted `1013 − p` would read a permanent
   22 hPa "deficit" on an ordinary day. The two change features are untouched by the shift, which
   is a useful check that it does what it claims.

   **The 30 days are measured once per refit and carried to the forecast path**
   (`WellbeingRiskEngine.baseline`). This is load-bearing and was got wrong once: the fit reads
   120 days and can measure the real median, the forecast reads eight and cannot, and left to
   measure its own it centred level features on an eight-day median under coefficients fitted
   against a thirty-day one. On a settled week that is a couple of hPa, and `dayLow7dHPa` carries
   it at 0.83 over a scale of 5.86 — about 0.42 in log-odds, ten points of the percentage on
   screen, with both halves staying perfectly well-formed. `RiskPressureBaseline.minimumCells`
   (24 observed hours) is the check that a caller measured over the span it meant to; below it
   there is no baseline and therefore no rows, rather than a confidently-wrong shift.
3. **The grid is hourly, not quarter-hourly as in the notebook.** Forced by the forward half:
   WeatherKit publishes hourly and `LocalPressureModel` iterates hourly, so a finer grid behind
   `now` would still be hourly ahead of it, and a window's features have to mean the same thing
   on both sides of the join. The notebook's own width sweep says this is not where the signal
   lives — ROC-AUC holds 0.764–0.799 from 30 min to 4 h.
4. **Sensor and forecast stay distinguishable.** `RiskGridCell.isMeasured` / `.isForecast` travel
   to `RiskWindowRow.coverage` / `.forecastShare` and out to `WellbeingRiskForecast.forecastShare`,
   so a caller can tell a morning that rests on WeatherKit from an evening that rests on
   measurements. **Training rejects any row with `forecastShare > 0`** — fitting on a forecast
   teaches the model the forecaster's biases and then applies them again at inference, twice.

**The known train/serve difference.** At training time the day-level columns are averages over a
day that has fully happened; at inference the later windows come from the forward curve. That is
what makes an *advance* forecast possible at all, and it is a real difference in input quality
between fit and use, not a leak — a feature at `t` still reads only what was knowable at `t`.
`forecastShare` is what makes it visible rather than assumed.

### 2.6 What reaches the screen

The model scores windows; three rules decide which of them a surface may draw. They are one
place — `WellbeingRiskModel.forecast(for:asOf:)` and `WellbeingRiskForecast` — because a chart
and a caption disagreeing about the same day is worse than neither being there.

1. **Every covered day ahead is scored, each on its own.** The horizon is
   `WellbeingRiskEngine.forecastHorizonSeconds` = **96 h**, deliberately the same number as
   `PressureChartRange.day.forecastSeconds(for: .weatherKit)`: every hour of forward line the
   chart can put on screen is an hour the model is asked about. The day stage runs per day and
   the top `markedWindowCount` windows are picked **within** a day, never globally — the window
   stage is a *conditional* answer to "if an entry happens that day, when", and letting a strong
   Tuesday take Wednesday's marks would compose two different conditionals. Costs no new wake
   source and no second read: the chart already asks the same reader for the same 96 h.
2. **A day is scored whole or not at all.** `RiskWindowBuilder.minimumDayCoverage` (50%) is
   applied per day; a day under it contributes no windows, rather than windows carrying a day
   average that is really the mean of a morning. Today failing that gate is not the forecast
   failing — `checkInProbability` is `nil` and the days behind it are still scored.
3. **Nothing is drawn that has no percentage.** `WellbeingRiskModel.isPrintable` — the joint
   figure rounds to at least one whole point — gates both the number the row prints and whether a
   window may be marked at all. Ranking always produces a best window; marking one the model puts
   under half a point would be the chart claiming a stretch the row cannot put a number on.

**The figure on screen is the strongest window of today, not the day stage's own output.**
`checkInProbability = max(combined)` over today's windows, where
`combined = P(entry today) × P(this window | entry)` — the same quantity per window as
`ScoredRiskWindow.combined`. The two answer different questions and only one of them has
something drawn under it: the day stage's number is a frequency the user cannot locate anywhere
on the plot, while this is the strongest thing the model will point at on it. Being a joint
probability it is always at or below the day stage's figure, and it is the only number in this
subsystem a surface may render as a percentage — the window stage's `confidence` is a rank and
stays one (§2.5).

**The 1–3 day outlook is a fourth rule, and it introduces no fourth constant.**
`WellbeingRiskForecast.outlook` carries one `RiskOutlookDay` per scored day that still has a
window **ahead of `now`** — an outlook about a stretch that ended at breakfast is not an
outlook — built from that day's highest-`confidence` remaining window. The band is
`WellbeingRiskModel.level`: `.low` when the day stage called the day quiet
(`dayDisplayThreshold`), otherwise `.high` when the window stage clears `gateThreshold` on that
window and `.moderate` when it does not. Both cut points already exist and are already tuned —
the first is the filter that decides whether the day stage hands the question on at all, the
second is the bar `mayNotify` reads. The consequence is worth stating: `.high` means "if this
were today the app would be entitled to send a message", which by design happens on roughly one
day in three, so a card whose tiles were mostly red would be reporting a threshold set too low
rather than a worse life.

The tile prints a **state and never a number**. `RiskOutlookDay.percent` exists, follows
`isPrintable` exactly as `ScoredRiskWindow.percent` does, and is deliberately not drawn: the
one percentage this subsystem shows sits on the chart, where the windows under it are visible.
`confidence` is on the tile so a reader of the type can check the band, and stays a rank.

## 3. Altitude contamination

Raw barometer output is _station_ pressure. Near sea level ≈ **8.3 m/hPa** (0.12 hPa/m),
so a 10 m elevator ride ≈ 1.2 hPa — the same size as a meteorologically meaningful 6 h
change. Left uncorrected, the model learns "the user took the stairs".

**The obvious fix is circular:** `CMAltimeter.startRelativeAltitudeUpdates` derives
relative altitude _from pressure_, so it cannot separate weather from altitude on its own.
Do not use it as the de-trending reference.

v1 approach — reject rather than correct:

- **Rate gate.** Synoptic pressure change is roughly ≤2 hPa/h even in a rapidly deepening
  system. A change >3 hPa within 10 min is altitude or a bad sample, not weather: drop
  both samples and reduce coverage. _Provisional_ thresholds; validate on real traces.
- **Plausibility gate.** `Pressure.isPlausible` (800–1100 hPa) already rejects unit
  mix-ups and bad reads at the boundary.
- **Anchor on rest.** Prefer deltas between samples taken while the user is stationary
  (long-lived low-motion periods, e.g. overnight), which removes most short excursions.

Candidates deferred to §9: `CMAltimeter` absolute-altitude updates (fused with GNSS, so
not circular — verify hardware and platform availability before designing around it), and
CoreLocation altitude as an independent but noisy reference. Both cost battery
(`../skills/watchos_budget/SKILL.md`).

**WeatherKit MSLP is a third candidate, and the only non-circular one already on disk.** It is
derived from a network of stations rather than from this device's barometer, so it cannot
absorb the user's own altitude excursion the way `CMAltimeter`'s relative altitude does. The
residual `station − MSLP`, once the rolling median has taken out the slow part, moves with
**elevation** and not with weather: a ten-floor lift ride shows up in it and a passing front
does not. That makes it an altitude reference the app now collects for free, and it costs no
battery at all — the rows are fetched for the forecast regardless.

Two reasons it is a §9 candidate and not shipped de-trending. It exists only while WeatherKit
is on, so anything built on it would be a feature that silently changes meaning when a switch is
flipped — exactly what §2.2's `forecastSource` exists to prevent elsewhere. And the residual
also carries the temperature dependence of Apple's own reduction, which
`PressureOffsetCalibrator` corrects only partially: at elevations above ~500 m the diurnal
remainder is ~2 hPa, comparable with `PressureTrend.significantChangeHPa` itself. Quantifying
that against real traces comes before using it. See §9, question 3.

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
  days), `k = 30` _provisional_. `k` lives in **one** named constant in `Shared/`:
  `WellbeingRiskModel.priorBlendConstant`. `n` is `labelledEntryCount` — entries that landed in a
  window a fit could use: inside the 120-day window, past `minimumDayCoverage`, behind `now`.
  That is **not** what `TrainingDataProgress` counts on the Now screen, and the two cannot be
  made equal: the bar has to draw before any fit has run, so it counts stored check-ins, all
  time, which is always the larger. What ties them is the line rather than the count — the card's
  target of 40 is derived from `k` (`40/(40+30) = 0.57`), so the bar fills no sooner than the
  forecast stops leaning on the prior. The blend is taken in **log-odds**, not in probability:
  averaging 0.02 and 0.30 directly gives 0.16, a stronger claim than either model made.
- **Cold start is not `w(n) < 0.5` alone.** A stage that could not be fitted at all falls through
  to the prior whatever `n` says — a user who logs every day gives the day stage no negative
  class and `LogisticRegressionFitter` refuses — so `WellbeingRiskModel.isColdStart` also
  requires both personal stages to exist. Without that clause the "still learning your pattern"
  disclosure came off a figure that was 100% prior, which is a compliance problem as well as a bug.
- **`WellbeingRiskPrior.isEnabled` off means no prior anywhere.** `WellbeingRiskModel.blending`
  is the single place that reads it: on, the shipped stages carry the blend; off, the personal
  fits *become* the stages, the weight is zero, and a device without both of them gets no model
  and no forecast rather than a synthetic one. Gate threshold in that mode is
  `unreachableGateThreshold` until a validation run measures one on the device's own scale.
- **Feature budget: ≤6 features in the personal component.** More parameters than events
  is memorisation. The prior may be richer; the personal part may not.
- The UI states reduced confidence during cold start. Wording per
  `../skills/appstore_compliance/SKILL.md`.

---

## 5. Validation protocol

- **Forward-chaining only, per user.** Random k-fold leaks future into past and is
  rejected in review, no exceptions.
- **Train/test gap ≥ 24 h.** Without it the 24 h features straddle the boundary and leak
  anyway. This used to be "the longest feature window" and no longer is: §2.5 added
  `low7dHPa`, a seven-day trailing mean, and `WellbeingRiskTrainer.foldGapDays` is still **1**.
  A deliberate deviation, stated rather than silently accepted — seven days between every fold
  costs a quarter of a month's history for the feature carrying the smallest coefficient in the
  model (0.042 against `drop6hHPa`'s 1.35). Revisit it if that coefficient ever grows.
- Two evaluation modes, reported separately:
  1. _Personal_ — forward-chaining within one user, ≥3 folds, test fold ≥3 days.
  2. _Cold start_ — leave-one-user-out on the prior, scored on that user's first 7 days
     only. This is the number that answers "does the app work on day 3".
- Any user with zero positive events in a fold is excluded from that fold's precision, and
  the exclusion is reported. Do not silently average it away.

---

## 6. Decision threshold

The model outputs a probability; the product sends notifications. Separate concerns:

- Threshold is chosen on the validation folds, never on test.
- _Provisional_ ship gate: **precision ≥ 0.5** on the positive class, at whatever recall
  results. A false advance warning costs trust faster than a miss costs value.
- _Provisional_ cap: **≤1 advance notification per day.** Bounds the damage of a bad
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

### 7.1 What the risk model measured

`WellbeingRiskTrainer` runs all four baselines on every validation pass and writes the result to
`BarosenseLog.pressure`; `RiskModelReport.beatsEveryBaseline` is the summary. The numbers below
are from `WellbeingRiskPipelineTests` on the research notebook's own 120-day synthetic trace,
rebuilt on this app's hourly grid, four forward-chaining folds, 60 evaluated days:

| | value | read against |
| --- | --- | --- |
| window PR-AUC | **0.407** | base rate 0.098 (lift 4.15) |
| window ROC-AUC | 0.784 | 0.5 |
| hit@1 / day | **0.358** | 0.111 picking at random |
| hit@2 / day (what the chart marks) | **0.604** | 0.222 picking at random |
| day ROC-AUC | 0.747 | 0.5 |
| day Brier | 0.124 | 0.197 uncalibrated, **0.103 always answering the base rate** |
| gate | **2.45 messages/week at precision 0.810**, 95% CI [0.60, 0.92] | recall 0.321, fired 21/60 days |

Baselines, PR-AUC: pressure rule 0.175, time of day 0.134, persistence 0.107, majority 0.102.
The learned window stage beats all four.

**Two results that are not flattering and are recorded here rather than left to be discovered.**

1. **The day stage does not beat a constant.** Its calibrated Brier is 0.124 against 0.103 for
   simply answering the base rate. That is a property of the trace — 53 of the 60 evaluated days
   hold an entry, so there is almost nothing to discriminate — and the stage still *ranks* days
   at ROC-AUC 0.747, which is what the "quiet day" filter uses it for. But the percentage on
   screen is, on this data, worth less than a constant would be.
   `RiskModelReport.Stage.beatsConstantBrier` carries it every run.
2. **Every number here is a ceiling.** The trace is synthetic and its generator has an explicit
   barometric effect written into it: a 10 hPa fall over six hours makes a slot roughly three
   thousand times likelier to hold an entry. One simulated person, 90 entries. Nothing here is an
   estimate of what this app will do for a real user, and the shipped prior inherits the same
   limitation (`WellbeingRiskPrior`).

Calibration is measured, not assumed: the Platt correction halves the day stage's Brier
(0.197 → 0.124) while leaving its ordering untouched, which is the only thing that licenses a
percentage on screen at all.

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
2. **Label extension** to `intensity >= 6 && !tagIDs.isEmpty`. Needs real check-in
   distribution. Note the vocabulary is user-owned, so "has any tag" is the only form of
   this that means the same thing for every user.
3. **Altitude reference** — absolute-altitude updates vs. CoreLocation vs. rejection only.
   Battery cost decides it.
4. **Advance-warning horizon** — the 6–30 h window in §1 is assumed, not validated.
5. **Cold-start notifications** — whether to notify at all while output is prior-dominated.
6. **CloudKit sync of derived features.** Apple's HealthKit terms restrict off-device
   storage of health data; this is a gated ADR, not a default
   (`../skills/healthkit_permissions/SKILL.md`).
7. **Conditioning the risk model on intensity.** §1.1 forecasts *whether an entry happens*, not
   how bad it was. Joining the two labels — "will an entry be made, and will it be a 7+" — is the
   question the product actually wants and the one the data cannot yet answer. Needs a real
   check-in distribution first, and watch for the spike at exactly 5 that the form's default
   produces.
8. **Whether the day percentage should be shown at all.** On the synthetic trace it does not beat
   a constant (§7.1). A rule that hides the figure when
   `RiskModelReport.Stage.beatsConstantBrier` is false would be honest and is not implemented —
   it is a product decision about what an unhelpful-but-not-wrong number costs.
9. **Notifications from the gate.** `WellbeingRiskForecast.mayNotify` is computed, logged and
   **consumed by nothing**. Wiring it to `NotificationDispatcher` needs §6's provisional ship
   gate confirmed by a human, and needs the cold-start question (§9.5) answered first — the gate
   would otherwise fire on prior-dominated output.
