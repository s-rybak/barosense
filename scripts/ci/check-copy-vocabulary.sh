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

# Stems, not whole words: matching is substring-based, so `diagnos` covers
# diagnose / diagnosis / diagnostic and `treat` covers treats / treatment.
stems=(diagnos predict prevent treat therap medical clinical cure symptom patient
       disease migraine remed)

# Same stems with a capital initial, for the camelCase pass below. Built here rather
# than written out twice — one list to edit, no chance of the two drifting.
lower=$(IFS='|'; printf '%s' "${stems[*]}")
caps=''
for stem in "${stems[@]}"; do
    initial=$(printf '%s' "${stem:0:1}" | tr '[:lower:]' '[:upper:]')
    caps="${caps:+$caps|}${initial}${stem:1}"
done

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

grep_files() { printf '%s\n' "$files" | tr '\n' '\0' | xargs -0 grep "$@" 2>/dev/null || true; }

# Two passes, because Swift identifiers put words in two different places.
#
# 1. Word start — "Migraine risk", `migraineRiskState`, `SHOW_MIGRAINE`. Underscore
#    counts as a boundary, so SCREAMING_SNAKE and _leadingUnderscore are covered.
# 2. camelCase / PascalCase hump — `showMigraineWarning`, `isPatientFacing`, which a
#    word-boundary match misses entirely: the term is glued to the previous word.
#    Case-SENSITIVE on purpose. It must be the capitalised form, otherwise the `cure`
#    stem would fire on `secure` / `SecureField` and the guard would be ignorable noise.
word_start=$(grep_files -EinH "(^|[^A-Za-z0-9])($lower)")
camel_hump=$(grep_files -EnH "[a-z0-9_]($caps)")

hits=$(printf '%s\n%s\n' "$word_start" "$camel_hump" \
    | grep -v '^$' \
    | sort -t: -k1,1 -k2,2n -u \
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
