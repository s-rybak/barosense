# Security Policy

Barosense is a wellbeing-tracking app for iPhone and Apple Watch. It runs entirely
on-device: there is no backend, no account, and no server-side component. That shapes what
a vulnerability looks like here. The assets worth protecting are the data sitting on the
user's own device — check-ins, the free-text notes attached to them, the tag vocabulary,
barometer samples, and the values read from HealthKit — plus the integrity of the pipeline
that builds the app.

## Reporting a vulnerability

**Please do not open a public issue for a security report.** A public issue is visible to
everyone the moment it is filed, including before there is a fix.

Two private channels, in order of preference:

1. **GitHub Private Vulnerability Reporting** — the *Report a vulnerability* button on the
   repository's **Security** tab. Preferred: the report, the discussion and the fix stay in
   one place, and nothing is public until it is resolved.
2. **Email** — <barosense.app@gmail.com>. Use this if you cannot reach GitHub, or if the
   report is about the repository account itself.

Useful to include, as far as you have it:

- what an attacker gets, stated concretely — which data, from where, under what access;
- the steps to reproduce, and the device / OS version you saw it on;
- the commit or release you tested;
- whether you have shared this with anyone else.

Reports in Ukrainian or English are equally welcome.

## What to expect

This is a small project with a single maintainer, so the timings below are commitments
about *communication*, not about a fix landing:

| Stage | Target |
| ----- | ------ |
| First reply acknowledging the report | 7 days |
| Triage decision — accepted, needs more information, or out of scope | 14 days |
| Fix or a written plan for one, for an accepted report | 90 days |

There is no bug bounty. Credit in the release notes and in the advisory, if you want it.

## Scope

Findings that are in scope:

- anything that moves health data, check-ins, notes or barometer history off the device
  outside of the one sanctioned request path (WeatherKit, which carries location and time
  only);
- anything that lets another app, another user, or a process outside the app read that
  data on the device;
- weakening of at-rest protection: backup exclusion, file protection class, or the
  location the durable stores are opened at;
- a way to bypass or silently no-op the erase-all-data path
  (`Shared/Persistence/BarosenseDataEraser.swift`);
- supply chain: the GitHub Actions workflows, the pinned action and tool digests, the
  repository guards under `scripts/ci/`, or anything that could get unreviewed code into a
  build;
- health-derived values reaching a log, a crash report, a diagnostic payload or the
  pasteboard.

Out of scope:

- vulnerabilities in iOS, watchOS, HealthKit, WeatherKit, SwiftData or StoreKit
  themselves — please report those to Apple, not here;
- anything that requires a jailbroken device, or a debugger already attached to the
  process;
- automated scanner output with no demonstrated impact on this codebase;
- social engineering, and physical attacks on Apple hardware;
- the absence of a feature (for example "the app has no passcode lock") — that is a
  feature request, and welcome as a normal issue.

Attacks that assume physical possession of a **locked** device are in scope. A wellbeing
journal is exactly the kind of data that matters in that scenario.

## Disclosure

Coordinated disclosure. Once a fix is available, or 90 days after the report is accepted —
whichever comes first — the finding is published as a GitHub Security Advisory. If you
plan to write the finding up yourself, tell us and we will agree a date rather than race
you to it.

## How the app handles data

Context that usually answers the first question a reporter has:

- there is no backend and no telemetry SDK; nothing is uploaded, so nothing is stored
  server-side to be breached;
- the on-device model is trained locally, and its weights are derived from the user's own
  check-ins — they are treated as health data, not as a build artefact;
- outbound WeatherKit requests carry a coordinate rounded to 0.1° (~11 km) and a time, and
  never a health-derived value;
- CloudKit sync is switched off in code
  (`Shared/Persistence/SwiftData/BarosenseModelContainer.swift`), not merely unconfigured.

The full write-up lives in `docs/privacy/`.
