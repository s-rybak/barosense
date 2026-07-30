---
name: scope_control
description: Diff-size limits, what counts as out of scope, and how to escalate instead of silently widening a task. Load at the start of any implementation task and again before opening a PR.
---

# Scope control

Core conventions #1 and #3. The system is stable. A task changes what the task requires
and nothing else.

## Budget

Default per task:

| Metric               | Soft limit | Hard limit             |
| -------------------- | ---------- | ---------------------- |
| Changed lines (±)    | 500        | 1000 → split the task   |
| Files touched        | 10         | 15 → split the task    |
| New third-party deps | 0          | 0 (gated, always)      |
| Public API removed   | 0          | 0 without an ADR       |

Check before drafting a PR:

```bash
git diff --stat main...HEAD | tail -1
```

Exceeding a soft limit is not forbidden — it requires one line in the PR body saying why
(e.g. "generated fixture data, 400 lines, no logic"). Exceeding a hard limit means the
task is really two tasks: land the first, open an issue for the second.

## Out of scope by default

Do not do these while doing something else, even when they are obviously right:

- Reformatting, re-wrapping, or re-styling files you did not otherwise change — including
  Markdown. A whitespace-only diff hides the real change from review.
- Renaming symbols, files, or directories.
- Upgrading dependencies, the Swift version, or deployment targets.
- "Fixing" adjacent code that is not on the path of the current change.
- Adding abstraction for a second use case that does not exist yet.
- Deleting code that looks dead without proving it is unreferenced.

If you find one of these worth doing, record it — file an issue or list it under
`Follow-ups` in the report. Do not leave `// TODO` in source as the record.

## Escalate instead of widening

Stop and ask a human when:

- Fixing the task properly requires refactoring outside the task scope.
- The task needs a new HealthKit type, a new dependency, or a backend.
- The task touches user-facing wording about health outcomes.
- Two files disagree about a rule and the task depends on which is right.
- An API's current behaviour is uncertain. Say so plainly; do not invent the API.

Escalation format:

```
BLOCKED / SCOPE: <one line>
NEEDED: <the smallest change that would unblock>
COST IF DEFERRED: <what stays broken or hacky>
OPTIONS: A) <in-scope workaround>  B) <do it properly, +N files>
```

Give a recommendation with the options. Do not present a menu and wait.

## Reporting

Every task report ends with:

- **Changed:** files and why, one line each.
- **Not changed on purpose:** anything you deliberately left broken or dirty.
- **Follow-ups:** out-of-scope findings, as issue-ready one-liners.

Silently doing extra work is a scope violation even when the extra work is good.
