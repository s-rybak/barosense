#!/usr/bin/env bash
# Tier 1 of the pipeline: the checks that need Xcode. Builds the Barosense scheme
# (iOS app + embedded watchOS app) and runs the XCTest suite on an iOS simulator.
#
# Local use:   scripts/ci/run-tests.sh
# CI use:      same — .github/workflows/tests.yml calls exactly this.
#
# macOS-only, unlike run-all.sh. Everything environment-specific (which Xcode, which
# simulator) is resolved here at runtime rather than hardcoded in the workflow file,
# so a runner-image update changes nothing in the repo and a mismatch fails with the
# list of what is actually installed instead of a cryptic xcodebuild error.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

scheme=Barosense
project=Barosense.xcodeproj
derived_data=${DERIVED_DATA:-.build/ci-dd}
result_bundle=${RESULT_BUNDLE:-.build/TestResults.xcresult}

# --- required toolchain version -------------------------------------------------------
# project.yml stays the single source of truth. Xcode's major version tracks the OS
# major version (Xcode 26 ships the iOS 26 SDK), so the deployment target tells us the
# minimum Xcode. Reading it from the manifest means bumping the target cannot silently
# leave CI building against an older SDK than the code declares.
required_major=$(sed -n 's/^[[:space:]]*iOS:[[:space:]]*"\([0-9]*\)\..*/\1/p' project.yml | head -1)
if [ -z "$required_major" ]; then
    echo "FAIL: could not read options.deploymentTarget.iOS from project.yml" >&2
    exit 1
fi

xcode_major() {
    xcodebuild -version 2>/dev/null | sed -n 's/^Xcode \([0-9]*\).*/\1/p' | head -1
}

# Empty when xcodebuild is missing entirely, which the ${:-0} below turns into "too old"
# so that case falls into the same branch and gets the same actionable error.
selected_major=$(xcode_major) || selected_major=""

# An explicit DEVELOPER_DIR is a deliberate choice by whoever set it — respect it.
if [ -z "${DEVELOPER_DIR:-}" ] && [ "${selected_major:-0}" -lt "$required_major" ]; then
    # Selecting via DEVELOPER_DIR, not `sudo xcode-select -s`: process-scoped, needs no
    # password, and leaves the developer's own machine setting untouched.
    best_major=0
    best_path=""
    for app in /Applications/Xcode*.app; do
        [ -d "$app" ] || continue
        version=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" \
            "$app/Contents/Info.plist" 2>/dev/null) || continue
        major=${version%%.*}
        if [ "$major" -ge "$required_major" ] && [ "$major" -gt "$best_major" ]; then
            best_major=$major
            best_path=$app
        fi
    done

    if [ -z "$best_path" ]; then
        echo "FAIL: project.yml targets iOS ${required_major}.x, which needs Xcode ${required_major} or newer." >&2
        echo "Selected: $(xcodebuild -version 2>/dev/null | head -1 || echo 'no xcodebuild')" >&2
        echo "Installed:" >&2
        ls -d /Applications/Xcode*.app >&2 2>/dev/null || echo "  (none)" >&2
        exit 1
    fi

    export DEVELOPER_DIR="$best_path/Contents/Developer"
fi

echo "==> $(xcodebuild -version | head -1) ($(xcode-select -p))"

# --- generate the project -------------------------------------------------------------
# The .xcodeproj is generated, not committed (CLAUDE.md → Build), so CI always starts
# without one. Locally, regenerate only when project.yml is newer, to stay incremental.
if [ ! -f "$project/project.pbxproj" ] || [ project.yml -nt "$project/project.pbxproj" ]; then
    if ! command -v xcodegen >/dev/null 2>&1; then
        echo "FAIL: xcodegen not found — brew install xcodegen" >&2
        exit 1
    fi
    echo "==> xcodegen generate"
    xcodegen generate --quiet
fi

# --- pick a simulator -----------------------------------------------------------------
# `xcodebuild test` needs a concrete device, not `generic/platform=iOS Simulator`. Names
# ("iPhone 16") churn with every runner-image update, so resolve a UDID from what is
# actually installed: newest iOS runtime at or above the deployment target, first iPhone.
destination_id=$(xcrun simctl list devices available --json | python3 -c '
import json, re, sys

required = int(sys.argv[1])
best = None
runtimes = []
for runtime, devices in json.load(sys.stdin)["devices"].items():
    match = re.search(r"iOS-(\d+)-(\d+)", runtime)
    if not match:
        continue
    version = (int(match.group(1)), int(match.group(2)))
    runtimes.append("iOS %d.%d" % version)
    if version[0] < required:
        continue
    for device in devices:
        if device.get("isAvailable") and "iPhone" in device["name"]:
            if best is None or version > best[0]:
                best = (version, device["udid"], device["name"])
            break

if best is None:
    sys.stderr.write(
        "FAIL: no available iPhone simulator running iOS %d or newer.\n"
        "Available iOS runtimes: %s\n" % (required, ", ".join(sorted(set(runtimes))) or "none")
    )
    raise SystemExit(1)

sys.stderr.write("==> simulator: %s (iOS %d.%d)\n" % (best[2], best[0][0], best[0][1]))
print(best[1])
' "$required_major")

# --- build + test ---------------------------------------------------------------------
# CODE_SIGNING_ALLOWED=NO: DEVELOPMENT_TEAM is intentionally empty in project.yml and CI
# has no keychain. Simulator unit tests exercise pure Shared/ logic and need no
# entitlements, so signing is dead weight here — it is not a workaround for a real
# signing problem, and device/TestFlight builds are unaffected.
#
# The scheme builds BarosenseWatch as an embedded dependency, so this compiles the
# watchOS target too — a watch-side break fails this job, not a later release build.
rm -rf "$result_bundle"
echo "==> xcodebuild test"
NSUnbufferedIO=YES xcodebuild test \
    -project "$project" \
    -scheme "$scheme" \
    -destination "platform=iOS Simulator,id=$destination_id" \
    -derivedDataPath "$derived_data" \
    -resultBundlePath "$result_bundle" \
    CODE_SIGNING_ALLOWED=NO
