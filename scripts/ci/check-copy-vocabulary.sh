#!/usr/bin/env bash
# Guard: no medical-claim vocabulary on any product surface.
#
# Rule source: .claude/skills/appstore_compliance/SKILL.md. App Review Guidelines
# 1.4.1 / 5.1.1 — a hit here is a rejection risk, not a style nit. The rule covers
# UI strings, notification bodies, purpose strings, type/function names AND comments:
# comments become names, names become UI strings.
#
# Scope is the shipping surface only. Repo documentation (CLAUDE.md, AGENTS.md,
# .claude/, .github/) is excluded on purpose — those files *define* the forbidden
# vocabulary and would always match.
#
# Escape hatch: put `barosense:copy-allow <reason>` on the same line. Every use has
# to be justified in the PR body.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

product_paths=(Barosense BarosenseWatch Shared Tests project.yml)

# -w is applied per match, so `medical` also catches `medical-grade`, and the
# `[a-z]*` suffixes catch inflections (diagnose/diagnosis/diagnostic, treats/treatment).
forbidden='(diagnos[a-z]*|predict[a-z]*|prevent[a-z]*|treat[a-z]*|therap[a-z]*|medical[a-z]*|clinical[a-z]*|cure[a-z]*|symptom[a-z]*|patient[a-z]*|disease[a-z]*|migraine[a-z]*|headache[a-z]*|remed[a-z]*)'

# Two things must not trip the guard:
#  - the mandatory "not medical advice" disclaimer — the compliance checklist *requires*
#    it next to the forecast, so the negated form is the one wording that is always safe;
#  - Core ML's generated `prediction(...)` API, which is Apple's name, not our copy.
#    A user-facing string containing "predict" still fails: this only exempts call sites.
exempt='(not medical|non-medical|isn.t medical|no medical|\.prediction\(|Prediction(Input|Output)\b)'

files=$(git ls-files -- "${product_paths[@]}" \
    | grep -E '\.(swift|yml|yaml|strings|stringsdict|entitlements|plist|json)$' || true)

if [ -z "$files" ]; then
    echo "no product files to scan"
    exit 0
fi

hits=$(printf '%s\n' "$files" \
    | tr '\n' '\0' \
    | xargs -0 grep -EinwH "$forbidden" 2>/dev/null \
    | grep -Evi "$exempt" \
    | grep -v 'barosense:copy-allow' || true)

if [ -z "$hits" ]; then
    echo "clean: no medical-claim vocabulary in product files"
    exit 0
fi

echo "FAIL: medical-claim vocabulary on a product surface" >&2
printf '%s\n' "$hits" >&2
cat >&2 <<'EOF'

Allowed vocabulary: tracking, personal patterns, wellbeing companion,
your history suggests, check-in, trend, likely, risk state.

Rewrite the line, or — if the word genuinely cannot be a user-facing claim —
append `barosense:copy-allow <reason>` and justify it in the PR body.
See .claude/skills/appstore_compliance/SKILL.md.
EOF
exit 1
