---
description: Audit the current branch, run all pre-PR gates, draft the PR body, then stop for human approval. Nothing leaves the machine without an explicit yes.
argument-hint: [base-branch, default main]
---

Prepare the current branch for a pull request against `${ARGUMENTS:-main}`. Work
through the gates in order and stop at the first hard failure. Rules live in
`.claude/skills/github_pr/SKILL.md`, `.claude/skills/scope_control/SKILL.md`, and
`.claude/skills/human_approval/SKILL.md` — read them first.

## Gates

1. **Branch sanity.** Not on `main`; branch name matches `type/BARO-123-short-slug`
   (ticket segment optional). Working tree committed — no stray unstaged changes.
2. **Scope budget.** `git diff --stat main...HEAD`. Soft 500 lines / 10 files: over
   soft needs one stated line of justification for the PR body; over hard
   (1000 / 15) → stop, the task must be split.
3. **Convention greps.**
   - `grep -rnE '^import (SwiftUI|UIKit|WatchKit)' Shared/` → must be empty.
   - Force-unwrap / `try!` outside `Tests/` in the diff → fix before proceeding.
4. **Compliance scan.** Search the full diff (code, comments, strings, commit
   messages) for forbidden vocabulary from
   `.claude/skills/appstore_compliance/SKILL.md`. Any hit → fix before proceeding.
5. **Battery accounting.** If the diff adds any recurring wake-up on watchOS, the
   six-question costing from `.claude/skills/watchos_budget/SKILL.md` must be ready
   for the PR body. Missing → stop and produce it.
6. **Tests.** Run the test suite for affected schemes. If the diff touches the ML
   pipeline, run `/ml-eval` and capture its table. Failing or newly skipped tests →
   stop.

## Draft

Compose the PR body using the template in `.claude/skills/github_pr/SKILL.md`,
including: summary, scope-budget note if over soft limit, battery arithmetic if
applicable, test output, ML metrics table if applicable. Write it to
`.claude/.pr-body.md`.

## Approval gate — hard stop

Show the user: the branch name, `git diff --stat`, and the full drafted PR body.
Then **stop and wait**. Only after an explicit yes: `git push`, then
`gh pr create --draft --body-file .claude/.pr-body.md`. No push, no PR, no comment
before that yes — approval for a previous PR does not carry over.
