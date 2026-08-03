---
applyTo: "Shared/**/*.swift"
---

# Shared/ — domain layer

This is the cross-platform, UI-free, device-free core: domain models, sensor services
behind protocols, feature engineering, the Core ML wrapper.

Blocking findings:

- `import SwiftUI`, `import UIKit`, or `import WatchKit` anywhere in this directory.
- `@MainActor` on domain logic. Main-actor isolation belongs to view models in the
  platform targets.
- A direct dependency on `HKHealthStore`, `CMAltimeter`, `WKApplication`, or a live
  network client. These are reached through a protocol declared next to the consumer and
  injected at the app layer — otherwise the ML pipeline stops being testable from a plain
  XCTest with synthetic input.
- A type crossing an isolation boundary that is not `Sendable`. Prefer value types; a
  reference type that must cross is an `actor`. `@unchecked Sendable` needs a comment
  stating the invariant that makes it safe.
- Force-unwrap, `try!`, or `as!`.
- `NSError` or `String` as an error type. Use a typed enum per subsystem.
- Pressure in kPa. `CMAltitudeData.pressure` arrives in kPa and is converted to hPa once,
  at the sensor boundary; hPa is the only unit in this layer. Identifiers carry the unit:
  `pressureHPa`, `deltaHPaPer6h`, `windowSeconds`.
- A magic threshold inlined at a call site — most importantly the "poor wellbeing" label
  (`score <= 2`), which is defined exactly once as a named constant with a `///` rationale.
- Missing `///` documentation on a **public** type or member.
- New Combine pipelines, or a new completion-handler API. Wrap a legacy callback once,
  here at the boundary, in `AsyncStream` / `withCheckedContinuation`.

Feature-engineering code additionally: no assumption of a fixed sample interval, an
explicit gap policy, a coverage value emitted alongside every windowed feature, and `nil`
rather than a value when coverage is below the documented minimum. Any change to a feature
requires the matching row in `.claude/context/ml-spec.md` in the same PR.

Anything that changes forecast output should be behind a feature flag so it can be turned
off without a release.
