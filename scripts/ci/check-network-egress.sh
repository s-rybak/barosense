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

# Watch <-> phone transfer. Not networking — it never touches IP — but it is the other way a
# check-in leaves this process, and it is the path a free-text `note` would ride out on if
# somebody widened the payload. Confined to the files that own the link, the same way the
# WeatherKit client is confined to Shared/Weather/.
#
# Named files rather than one directory prefix for the last three: the link is composed in
# the app entry point and its logging category is declared beside the other subsystems', so
# a prefix wide enough to cover them would cover half of Shared/ with it.
transfer_allowed='^(Shared/Watch/|Barosense/Watch/|BarosenseWatch/|Shared/Pressure/WatchConnectivityPressureLink\.swift|Shared/Pressure/PressureDisplayLink\.swift|Shared/Diagnostics/BarosenseLog\.swift|Barosense/BarosenseApp\.swift)'
transfer='(WCSession|import WatchConnectivity|transferUserInfo\(|updateApplicationContext\(|transferFile\(|transferCurrentComplicationUserInfo\()'

# Always gated regardless of location: off-device storage and third-party telemetry.
# CloudKit sync of health-derived data needs an ADR (Apple's HealthKit terms restrict it).
#
# The pasteboard sits here rather than in the transfer list because it has no legitimate
# location in this app at all: a copied note reaches the system pasteboard, and with
# Universal Clipboard on that is another device. MetricKit likewise — its payloads go to
# Apple, and nothing here consumes diagnostics.
gated='(import CloudKit|CKContainer|CKDatabase|NSUbiquitous|import Firebase[A-Za-z]*|import Sentry|import Amplitude|import Mixpanel|Analytics\.log|UIPasteboard|NSPasteboard|import MetricKit|MXMetricManager)'

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

transfer_hits=$(scan "$transfer" | grep -Ev "$transfer_allowed" || true)
if [ -n "$transfer_hits" ]; then
    echo "FAIL: watch transfer API outside the files that own the watch link" >&2
    printf '%s\n' "$transfer_hits" >&2
    echo "      A check-in crossing to the phone goes through Shared/Watch/CheckInTransfer.swift," >&2
    echo "      which carries neither the note nor the medications. Widening that payload is a" >&2
    echo "      privacy decision, not plumbing." >&2
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
