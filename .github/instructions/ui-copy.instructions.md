---
applyTo: "Barosense/**/*.swift,BarosenseWatch/**/*.swift,**/*.strings,**/*.stringsdict,project.yml"
---

# User-facing surfaces

Every string here can end up in front of App Review. The medical-claim rule
(`.github/copilot-instructions.md` §1) is a rejection risk under Guidelines 1.4.1 / 5.1.1,
so treat a violation as blocking and always propose the concrete rewrite.

Check every new or changed literal, `LocalizedStringKey`, notification body,
accessibility label, and `INFOPLIST_KEY_NS*UsageDescription` for:

- diagnosis, treatment, prevention, or cure wording;
- a claim that the app knows what will happen to the user's body;
- model output presented as certainty — a percentage stated as fact, a countdown to an
  event, "confirmed", or a yes/no prediction instead of a graded risk state.

Purpose strings must be specific about what is read and why, non-medical, and must match
what the code actually does. A purpose string describing a type the code does not read —
or a type read without a purpose string — is a blocking finding.

SwiftUI review points:

- No network, sensor, or store access inside `body`. Views are pure functions of state.
- No business logic that could be unit-tested — that belongs in `Shared/`.
- `@State` on a view model reference type, or `@StateObject`/`@State` misuse that
  recreates state on every render.
- Anything conveying a value or state needs a VoiceOver label and must survive Dynamic
  Type at accessibility sizes.
- A permission denial or an empty data set must degrade gracefully. A blocking "grant
  access to continue" wall is acceptable only for the check-in flow itself, and the app
  must still be useful with 3–7 days of history — no empty-state dead end.
- Somewhere the user sees the forecast there must be a plain-language statement that this
  is not medical advice. Flag a new forecast surface that lacks one.
