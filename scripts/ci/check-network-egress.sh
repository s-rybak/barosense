#!/usr/bin/env bash
# Guard: health data never leaves the device.
#
# Rule source: CLAUDE.md constraint #2 and .claude/skills/healthkit_permissions/SKILL.md.
# WeatherKit is the only sanctioned outbound traffic and it carries location + time only.
#
# The guard keeps the egress surface auditable by confining every networking API to an
# allowlisted directory. It cannot prove a payload is health-free — that still needs a
# proxy capture before submission. What it does prove: no new networking appeared
# somewhere nobody is reviewing.
#
# Escape hatch: `barosense:egress-allow <reason>` on the same line, justified in the PR.
set -uo pipefail

cd "$(git rev-parse --show-toplevel)" || exit 1

# Only files under these prefixes may reference networking / WeatherKit.
allowed_prefixes='^Shared/Weather/'

networking='(URLSession|URLRequest|NSURLConnection|NWConnection|NWPathMonitor|CFSocket|WKWebView|WebView|\.dataTask\(|\.downloadTask\(|\.uploadTask\(|import Network|import WeatherKit|WeatherService)'

# Always gated regardless of location: off-device storage and third-party telemetry.
# CloudKit sync of health-derived data needs an ADR (Apple's HealthKit terms restrict it).
gated='(import CloudKit|CKContainer|CKDatabase|NSUbiquitous|import Firebase[A-Za-z]*|import Sentry|import Amplitude|import Mixpanel|Analytics\.log)'

# Directory pathspecs recurse into every subdirectory at any depth. Written this way
# rather than as 'Shared/*.swift': that glob also recurses (a git pathspec '*' matches
# '/', unlike a .gitignore glob), but it reads as if it did not.
source_dirs=(Barosense BarosenseWatch Shared)

swift_files=$(git ls-files -- "${source_dirs[@]}" | grep -E '\.swift$' || true)
[ -z "$swift_files" ] && { echo "no Swift files to scan"; exit 0; }

scan() { # $1 = regex
    printf '%s\n' "$swift_files" \
        | tr '\n' '\0' \
        | xargs -0 grep -EnH "$1" 2>/dev/null \
        | grep -v 'barosense:egress-allow' || true
}

status=0

net_hits=$(scan "$networking" | grep -Ev "$allowed_prefixes" || true)
if [ -n "$net_hits" ]; then
    echo "FAIL: networking API outside the allowlisted egress path (Shared/Weather/)" >&2
    printf '%s\n' "$net_hits" >&2
    status=1
fi

gated_hits=$(scan "$gated")
if [ -n "$gated_hits" ]; then
    echo "FAIL: off-device storage or third-party telemetry — gated, needs an ADR" >&2
    printf '%s\n' "$gated_hits" >&2
    status=1
fi

# Health values must not reach the log even in Debug builds that ship symbols.
log_hits=$(printf '%s\n' "$swift_files" | tr '\n' '\0' \
    | xargs -0 grep -EnH '(print\(|NSLog\(|os_log\()' 2>/dev/null \
    | grep -Ei '(hk[a-z]*sample|heartrate|sleep|checkin|check_in|wellbeing)' \
    | grep -v 'barosense:egress-allow' || true)
if [ -n "$log_hits" ]; then
    echo "FAIL: health-derived value in a log statement" >&2
    printf '%s\n' "$log_hits" >&2
    status=1
fi

[ "$status" -eq 0 ] && echo "clean: no unreviewed egress surface"
exit "$status"
