---
name: swift_conventions
description: Swift/SwiftUI style, module boundaries, concurrency rules, and XcodeGen mechanics for this repo. Load before writing or reviewing any Swift file.
---

# Swift conventions

## Module boundaries

```
Shared/           domain models, sensor services, feature engineering, Core ML wrapper.
                  UI-free. Must compile and be testable without a device.
Barosense/        iOS views + iOS-only plumbing.
BarosenseWatch/   watchOS views + watchOS-only plumbing.
Tests/            XCTest.
```

Rule: anything that can live in `Shared/` does. A platform target holds views and
platform glue only.

Hard consequence: `Shared/` must contain no `import SwiftUI`, no `import UIKit`, no
`import WatchKit`. Check before committing:

```bash
grep -rnE '^import (SwiftUI|UIKit|WatchKit)' Shared/
```

The ML pipeline in particular must run from a plain unit test with synthetic input — no
`HKHealthStore`, no `CMAltimeter` at test time. That is enforced by protocols, not by
discipline: every sensor, store, and network client sits behind a protocol declared next
to its consumer, with the real implementation injected at the app layer.

## Concurrency

The project builds with `SWIFT_STRICT_CONCURRENCY: complete`. Warnings here are future
errors — do not suppress them.

- `async`/`await` and actors. No new Combine pipelines. No completion-handler APIs in new
  code; wrap a legacy callback API (`CMAltimeter`, `HKObserverQuery`) once, at the
  boundary, in an `AsyncStream` or a `withCheckedContinuation`, and keep the callback out
  of the rest of the codebase.
- Types crossing an isolation boundary are `Sendable`. Prefer value types; if a reference
  type must cross, make it an `actor`.
- `@MainActor` on view models, never on `Shared/` domain logic.
- Never `Task { @MainActor in ... }` to paper over an isolation warning — fix the
  ownership instead.

## Style

- No force-unwrap, no `try!`, no `as!` outside test targets. `guard let … else { return }`
  or a typed `throws`.
- Errors are typed enums per subsystem, not `NSError` and not `String`.
- Public API of every type in `Shared/` is documented with `///`. Internal code is
  documented only where the *why* is non-obvious. Do not narrate what the code says.
- Names say the unit when the unit is ambiguous: `pressureHPa`, `deltaHPaPer6h`,
  `windowSeconds`. Not `pressure`, not `delta`.
- One unit in the domain layer: **hPa**. `CMAltitudeData.pressure` arrives in kPa —
  convert at the sensor boundary, once, and never let kPa past it.
- Feature-flag anything that changes forecast output, so it can be turned off without a
  release.
- File length: split above ~300 lines. View bodies: extract a subview above ~60 lines.

## SwiftUI

- Views are pure functions of state. No network, sensor, or store access inside `body`.
- No business logic in a view — if it can be unit-tested, it belongs in `Shared/`.
- watchOS views are designed for a glance: one number or one state per screen.
  See `../watchos_budget/SKILL.md` for the complication rule.
- Dynamic Type and VoiceOver labels on anything conveying a value or state.

## XcodeGen

`Barosense.xcodeproj` is **generated, not committed**.

- Adding a file inside an existing `sources` path → nothing to do, the glob picks it up.
- Adding a new target or a new top-level directory → edit `project.yml`.
- After any `project.yml` change:

```bash
xcodegen generate
```

Build and test:

```bash
xcodebuild -project Barosense.xcodeproj -scheme Barosense -destination 'platform=iOS Simulator,name=iPhone 16' test
```

Never hand-edit the `.xcodeproj`, and never commit it.
