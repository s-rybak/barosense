---
applyTo: "BarosenseWatch/**/*.swift"
---

# BarosenseWatch/ — watchOS target

Battery is the binding constraint here, not CPU and not memory. Budget: **≤ 8 % additional
daily drain**. Every recurring wake-up is a debit that must be argued for in the PR body.

Flag any new `Timer`, `AsyncStream` polling loop, observer, background task, or
complication reload that does not state: what wakes it, how often per hour, how long the
work takes, what it keeps powered, and the estimated daily drain with the arithmetic
shown. A change with no stated cost is not reviewable.

Specific blocking findings:

- Barometer updates started without a matching stop on `resignActive` / scene background,
  or left running while the app is not in the foreground.
- `CMAltimeter` used without checking `isRelativeAltitudeAvailable()` and the authorization
  status first.
- Sampling faster than the feature's resolution needs. A 6 h pressure delta is already 6×
  oversampled at hourly.
- Complication or widget refresh materially more often than ~1 h. Pressure does not move
  fast enough to justify more, and the daily reload allowance is finite and shared.
- A timeline reload fired from a sensor callback. Batch: sample → persist → reload at the
  scheduled boundary.
- `WKExtendedRuntimeSession` reached for to work around gaps in background sampling. That
  is a design smell, and the session type has to be justifiable to App Review.
- A hard-coded assumption about the number of background refreshes the system grants per
  hour, or code that breaks when a scheduled refresh simply does not fire. It will not
  fire — design for it.
- A background refresh handler that does not schedule the next one, or does not complete
  its task.

Complication and glance content: parseable in ~0.5 s — one number **or** one state. No
dense text, no two-line sentences, no trend arrow plus number plus label together. The
wording rules in `.github/copilot-instructions.md` §1 apply in full to complication text.

If a battery figure is asserted without a device measurement, say so rather than accepting
it. Simulator energy numbers are meaningless.
