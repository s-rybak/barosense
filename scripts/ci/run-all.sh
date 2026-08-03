#!/usr/bin/env bash
# Entry point for the Linux-cheap repo guards. Runs every check, reports all
# failures instead of stopping at the first one, exits non-zero if any failed.
#
# Local use:   scripts/ci/run-all.sh
# CI use:      same, with BASE_REF set to the PR base sha (enables the drift check).
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

checks=(
    check-copy-vocabulary.sh
    check-network-egress.sh
    check-healthkit-sync.sh
    check-project-manifest.sh
    check-ml-spec-drift.sh
)

failed=()
for check in "${checks[@]}"; do
    printf '\n=== %s ===\n' "$check"
    if ! "scripts/ci/$check"; then
        failed+=("$check")
    fi
done

printf '\n=== summary ===\n'
if [ ${#failed[@]} -eq 0 ]; then
    echo "all ${#checks[@]} guards passed"
    exit 0
fi

printf 'FAILED (%d/%d):\n' "${#failed[@]}" "${#checks[@]}"
printf '  %s\n' "${failed[@]}"
exit 1
