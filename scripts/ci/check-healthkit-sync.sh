#!/usr/bin/env bash
# Guard: the HealthKit read/write set, the purpose strings and the ML spec agree.
#
# Rule source: CLAUDE.md constraint #3 and .claude/skills/healthkit_permissions/SKILL.md.
# Consumer-first: a type is requested only when shipped code reads it, and every
# requested type has a feature row in .claude/context/ml-spec.md.
#
# Hard failures are the compliance-risk direction (code reads a type nobody declared or
# documented). A purpose string with no consumer is reported as a warning: it is a normal
# transient state while a feature is being built, but must be gone before submission.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

manifest=project.yml
ml_spec=.claude/context/ml-spec.md
status=0

swift_files=$(git ls-files -- 'Barosense/*.swift' 'BarosenseWatch/*.swift' 'Shared/*.swift' || true)
[ -z "$swift_files" ] && { echo "no Swift files to scan"; exit 0; }

grep_swift() { printf '%s\n' "$swift_files" | tr '\n' '\0' | xargs -0 grep -EnH "$1" 2>/dev/null || true; }

# --- types actually consumed by code -------------------------------------------------
types=$(grep_swift 'HK(Quantity|Category|Characteristic|CorrelationType|Workout)TypeIdentifier' \
    | grep -oE 'HK(Quantity|Category|Characteristic|CorrelationType|Workout)TypeIdentifier\.[A-Za-z]+' \
    | sed -E 's/.*\.//' | sort -u)

uses_healthkit=$(grep_swift 'import HealthKit|HKHealthStore')

# --- every consumed type needs a row in the ML spec ----------------------------------
if [ -n "$types" ]; then
    echo "HealthKit types consumed by code:"
    printf '  %s\n' $types
    for type in $types; do
        # -w so that reading `.heartRate` is not satisfied by a `.restingHeartRate` row.
        if ! grep -qwi "$type" "$ml_spec"; then
            echo "FAIL: $type is read in code but has no feature row in $ml_spec" >&2
            echo "      Add unit, sampling frequency and missing-value strategy." >&2
            status=1
        fi
    done
else
    echo "no HealthKit type identifiers in code"
fi

# --- purpose strings -----------------------------------------------------------------
share_string=$(grep -c 'INFOPLIST_KEY_NSHealthShareUsageDescription' "$manifest" || true)
update_string=$(grep -c 'INFOPLIST_KEY_NSHealthUpdateUsageDescription' "$manifest" || true)

if [ -n "$types" ] && [ "$share_string" -eq 0 ]; then
    echo "FAIL: code reads HealthKit types but no NSHealthShareUsageDescription in $manifest" >&2
    status=1
fi

# Heuristic: a write consumer is a save() on a health store, or a non-empty toShare set.
writes=$(grep_swift '(healthStore|store)\.save\(|requestAuthorization\(toShare: *\[[^]]' || true)
if [ -n "$writes" ] && [ "$update_string" -eq 0 ]; then
    echo "FAIL: code writes to HealthKit but no NSHealthUpdateUsageDescription in $manifest" >&2
    printf '%s\n' "$writes" >&2
    status=1
fi
if [ -z "$writes" ] && [ "$update_string" -gt 0 ]; then
    echo "WARN: NSHealthUpdateUsageDescription is declared but nothing writes to HealthKit."
    echo "      Remove it before submission — do not ask for an authorisation you never use."
fi
if [ -z "$uses_healthkit" ] && [ "$share_string" -gt 0 ]; then
    echo "WARN: NSHealthShareUsageDescription is declared but no code imports HealthKit yet."
fi

# --- background delivery cost --------------------------------------------------------
# .immediate frequency needs an explicit battery justification (watchos_budget skill).
immediate=$(grep_swift 'enableBackgroundDelivery' | grep -E '\.immediate' \
    | grep -v 'barosense:battery-allow' || true)
if [ -n "$immediate" ]; then
    echo "FAIL: enableBackgroundDelivery(.immediate) without a battery justification" >&2
    printf '%s\n' "$immediate" >&2
    echo "      Use .hourly, or append 'barosense:battery-allow <cost rationale>'." >&2
    status=1
fi

[ "$status" -eq 0 ] && echo "clean: HealthKit declarations are in sync"
exit "$status"
