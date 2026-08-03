---
applyTo: "Tests/**/*.swift"
---

# Tests/

Force-unwrap, `try!`, and `as!` are allowed here — do not flag them.

Do flag:

- A test that needs a device or a live dependency: `HKHealthStore`, `CMAltimeter`,
  WeatherKit, or any network access. If a test cannot run with synthetic input, the seam
  is in the wrong place — the fix is in the production code, not the test.
- A newly `XCTSkip`-ped or commented-out test, or an assertion weakened to make a failing
  test pass.
- Time-dependent tests using `Date()` or `sleep` instead of an injected clock — the
  pipeline is time-series code and must be deterministic.
- Floating-point equality on pressure values without an accuracy tolerance.
- A pipeline change without the corresponding fixture coverage. Expected fixtures: a clean
  series; a series with a 12 h gap; an altitude step of ~10 hPa over 5 minutes; a user with
  3 days of history; a user with zero positive labels.
- A validation helper that shuffles or randomly splits time-ordered rows. Splits are
  forward-chaining, by time, with a gap at least as long as the longest feature window.
- A metric assertion on accuracy alone. The positive class is rare — assert on precision,
  recall, and PR-AUC, and compare against the majority-class, threshold-rule, and
  persistence baselines.
