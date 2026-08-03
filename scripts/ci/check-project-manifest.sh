#!/usr/bin/env bash
# Guard: project.yml stays the single source of truth for the Xcode project.
#
# The .xcodeproj is generated, not committed (CLAUDE.md → Build). XcodeGen itself is
# macOS-only, so this runs the checks that do not need it: manifest/disk agreement,
# no generated project in the index, and the build-setting invariants that silently
# weaken the codebase when someone flips them.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

manifest=project.yml
status=0

# --- every path referenced by the manifest exists on disk -----------------------------
while IFS= read -r path; do
    [ -z "$path" ] && continue
    if [ ! -e "$path" ]; then
        echo "FAIL: $manifest references '$path', which does not exist" >&2
        status=1
    fi
done < <(grep -E '^[[:space:]]*-?[[:space:]]*path:[[:space:]]' "$manifest" \
    | sed -E 's/^[[:space:]]*-?[[:space:]]*path:[[:space:]]*//' | tr -d '"')

# --- the generated project must not be tracked ----------------------------------------
tracked_project=$(git ls-files -- '*.xcodeproj' '*.xcodeproj/*' '*.xcworkspace/*' || true)
if [ -n "$tracked_project" ]; then
    echo "FAIL: generated Xcode project is tracked in git — it is produced by 'xcodegen generate'" >&2
    printf '%s\n' "$tracked_project" >&2
    status=1
fi

# --- build-setting invariants ----------------------------------------------------------
# Each of these silently degrades the codebase if flipped, and nothing else catches it.
declare -a invariants=(
    'SWIFT_STRICT_CONCURRENCY: complete|strict concurrency must stay complete'
    'ENABLE_USER_SCRIPT_SANDBOXING: YES|user script sandboxing must stay on'
)
for entry in "${invariants[@]}"; do
    setting=${entry%%|*}
    reason=${entry##*|}
    if ! grep -qF "$setting" "$manifest"; then
        echo "FAIL: '$setting' missing from $manifest — $reason" >&2
        status=1
    fi
done

# --- a source directory that no target builds is dead weight ---------------------------
for dir in Barosense BarosenseWatch Shared Tests; do
    [ -d "$dir" ] || continue
    if ! grep -qE "path: $dir(/|$)" "$manifest"; then
        echo "FAIL: '$dir/' exists but no target in $manifest builds it" >&2
        status=1
    fi
done

[ "$status" -eq 0 ] && echo "clean: manifest and working tree agree"
exit "$status"
