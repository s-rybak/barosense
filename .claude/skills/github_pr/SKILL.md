---
name: github_pr
description: Branch naming, commit format, pre-PR gate, and the PR body template for this repo. Load before committing or preparing a pull request. Every outbound action here is gated by human_approval.
---

# GitHub PR

Remote: `https://github.com/s-rybak/barosense`. Use the `gh` CLI for anything touching
GitHub.

**Everything in this skill that leaves the local machine is gated** — push, PR creation,
comments, reviews. Draft, show, wait for an explicit yes. See
`../human_approval/SKILL.md`.

## Branches

```
type/BARO-123-short-slug
```

`type` ∈ `feat` | `fix` | `chore` | `refactor` | `spike`. Omit the ticket segment when
there is no ticket: `feat/pressure-delta-window`.

Never commit to `main` directly. If you are on `main` when work starts, branch first.

## Commits

Conventional Commits, imperative mood, one logical change per commit:

```
feat(forecasting): add pressure delta over 6h window
fix(watch): stop barometer updates when the app resigns active
chore(project): add widget extension target to project.yml
```

Scopes in use: `forecasting`, `watch`, `ios`, `shared`, `health`, `weather`, `project`,
`agents`, `docs`.

Rules:

- Subject ≤ 72 chars, no trailing period.
- Body explains *why*, wrapped at 90 columns. The diff already shows *what*.
- No mixed-concern commits. Formatting-only changes get their own commit, and only when
  formatting was the task (`../scope_control/SKILL.md`).
- Never `--amend`, rebase, or force-push without approval.

## Pre-PR gate

Run all of these and paste real output into the PR body. Do not open a PR on unverified
work.

```bash
xcodegen generate
```

```bash
xcodebuild -project Barosense.xcodeproj -scheme Barosense -destination 'platform=iOS Simulator,name=iPhone 16' test
```

```bash
git diff --stat main...HEAD | tail -1
```

Plus the vocabulary sweep from `../appstore_compliance/SKILL.md` if any user-facing string
changed, and the metric-regression result from `../ml_pipeline/SKILL.md` if the pipeline
changed.

Stop and fix instead of opening a PR when: the build fails, a test fails, a test was
newly skipped, or the diff exceeds the hard scope limit.

## PR body template

```markdown
## What

<one paragraph — the change, not the journey>

## Why

<the problem; link the issue if there is one>

## Scope

- Files touched: N (+A / −B)
- Out of scope, deliberately: <or "none">
- Follow-ups: <issue-ready one-liners, or "none">

## Verification

- Build: <pass/fail, command used>
- Tests: <N passed, N failed, N skipped>
- Device check: <what was exercised on real hardware, or "simulator only">

## Constraint checks

- [ ] No medical claims in any user-facing or code-facing string
- [ ] No new HealthKit type (or: type + consumer + label update listed below)
- [ ] No health data egress added
- [ ] Battery cost stated for any new recurring work (watchOS)
- [ ] Cold start (3–7 days of history) still produces useful output

## ML metrics — delete if the pipeline is untouched

| metric | before | after | baseline (majority) | baseline (>X hPa / 6 h) | baseline (persistence) |
| ------ | ------ | ----- | ------------------- | ----------------------- | ---------------------- |
| precision @ positive |  |  |  |  |  |
| recall @ positive |  |  |  |  |  |
| PR-AUC |  |  |  |  |  |
| base rate |  |  |  |  |  |

Validation: forward-chaining, <k> folds, <gap> gap between train and test.
```

Unchecked boxes are allowed only with a one-line reason next to them. An unexplained
unchecked box means the PR is not ready.

## Commands

```bash
gh pr create --draft --title "feat(forecasting): add 6h pressure delta" --body-file .claude/.pr-body.md
```

Draft first, always. Marking ready for review is a separate approval.

```bash
gh pr view --json title,body,files,additions,deletions
```

Reading is free. Writing — `gh pr comment`, `gh pr review`, `gh pr merge`, `gh issue …` —
is gated, every time.
