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

# Directory pathspecs recurse into every subdirectory at any depth. Written this way
# rather than as 'Shared/*.swift': that glob also recurses (a git pathspec '*' matches
# '/', unlike a .gitignore glob), but it reads as if it did not.
source_dirs=(Barosense BarosenseWatch Shared)

swift_files=$(git ls-files -- "${source_dirs[@]}" | grep -E '\.swift$' || true)
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
#
# Scoped to the files that touch HealthKit at all, because `store.save(...)` is the shape of
# every persistence store in this repo: matched across the whole tree it reported the SwiftData
# notification log — which never sees a health sample — as a HealthKit write. Nothing real is
# lost by the narrowing. Saving to HealthKit means building an HKObject and handing it to an
# HKHealthStore, and neither is expressible in a file that imports neither.
healthkit_files=$(printf '%s\n' "$uses_healthkit" | grep -v '^$' | cut -d: -f1 | sort -u)
writes=''
if [ -n "$healthkit_files" ]; then
    writes=$(printf '%s\n' "$healthkit_files" | tr '\n' '\0' \
        | xargs -0 grep -EnH '(healthStore|store)\.save\(|requestAuthorization\(toShare: *\[[^]]' \
        2>/dev/null || true)
fi
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
#
# The frequency argument is regularly on a different line from the call, so the unit of
# inspection is the call site plus the next 3 lines, not a single line. A same-line grep
# lets a wrapped call through the guard silently — the expensive direction to be wrong in.
# The allow-comment counts anywhere in that window, since it usually sits on the argument.
#
# A fixed window rather than paren balancing: it covers every realistic formatting of this
# call, and the failure mode is a false positive, which the escape hatch already answers.
immediate=$(printf '%s\n' "$swift_files" | tr '\n' '\0' | xargs -0 awk '
    function flush() {
        if (window ~ /\.immediate/ && window !~ /barosense:battery-allow/) print site
        window = ""; site = ""; n = 0
    }
    FNR == 1 && n > 0 { flush() }          # a window never spans two files
    n > 0 {
        window = window "\n" $0
        if (--n == 0) flush()
    }
    /enableBackgroundDelivery/ && n == 0 {
        site = FILENAME ":" FNR ": " $0
        window = $0
        n = 3
    }
    END { if (n > 0) flush() }
' 2>/dev/null || true)
if [ -n "$immediate" ]; then
    echo "FAIL: enableBackgroundDelivery(.immediate) without a battery justification" >&2
    printf '%s\n' "$immediate" >&2
    echo "      Use .hourly, or append 'barosense:battery-allow <cost rationale>'." >&2
    status=1
fi

[ "$status" -eq 0 ] && echo "clean: HealthKit declarations are in sync"
exit "$status"
