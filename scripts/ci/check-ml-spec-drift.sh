#!/usr/bin/env bash
# Guard: .claude/context/ml-spec.md is updated in the same change as the model code.
#
# Rule source: ml-spec.md itself — "If this file contradicts the code, this file is the
# bug. Update it in the same PR as the code change." A spec that drifts is worse than no
# spec: it produces confident wrong decisions downstream.
#
# Needs a base ref to diff against. Set BASE_REF (CI passes the PR base sha); falls back
# to origin/main, and skips with a note when neither is available.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

ml_spec=.claude/context/ml-spec.md
# Directories whose contents the spec describes: features, label, model, validation.
watched='^Shared/(Features|ML|Model|Models|Forecast|Risk)/'

base=${BASE_REF:-}
if [ -z "$base" ]; then
    if git rev-parse --verify --quiet origin/main >/dev/null; then
        base=origin/main
    else
        echo "SKIP: no BASE_REF and no origin/main — nothing to diff against"
        exit 0
    fi
fi

if ! git rev-parse --verify --quiet "$base" >/dev/null; then
    echo "SKIP: base ref '$base' not present in this clone (shallow fetch?)"
    exit 0
fi

changed=$(git diff --name-only "$base"...HEAD || true)
[ -z "$changed" ] && { echo "no changes against $base"; exit 0; }

model_changes=$(printf '%s\n' "$changed" | grep -E "$watched" || true)
if [ -z "$model_changes" ]; then
    echo "clean: no model-facing changes in this diff"
    exit 0
fi

if printf '%s\n' "$changed" | grep -qF "$ml_spec"; then
    echo "clean: model code and $ml_spec changed together"
    exit 0
fi

echo "FAIL: model-facing code changed without updating $ml_spec" >&2
printf '%s\n' "$model_changes" >&2
echo "      Update the feature registry / label / validation rows in the same change." >&2
exit 1
