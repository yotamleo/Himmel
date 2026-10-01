#!/usr/bin/env bash
# scripts/ci/test-classify-ci-red.sh -- suite for scripts/ci/classify-ci-red.sh
# (HIMMEL-4071): the cheap cascade a leg runs on a failed CI job's log to decide
# whether the red is the PR's (leg fixes it) or MAIN-RED (leg escalates).
# Hermetic: the marker dir, the diff and the signature list are all seams; no
# gh, no git, no network.
#
# Usage: bash scripts/ci/test-classify-ci-red.sh
# Exit codes: 0 -- all cases passed; 1 -- at least one failed.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SCRIPT="$ROOT/scripts/ci/classify-ci-red.sh"
fails=0
ok()  { echo "ok - $1"; }
bad() { echo "FAIL - $1" >&2; fails=$((fails + 1)); }
eq()  { if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -e "$1" <<< "$2"; then ok "$3"; else bad "$3 (out: $2)"; fi; }

T=$(mktemp -d "${TMPDIR:-/tmp}/classify-ci-red.XXXXXX") || exit 1
trap 'rm -rf "$T"' EXIT

# run <log-text> <diff-text> <case> [extra args...] -> sets OUT, RC
run() {
    local log="$1" diff="$2" cs="$3"; shift 3
    printf '%s\n' "$log" > "$T/job.log"
    printf '%s\n' "$diff" > "$T/diff.txt"
    mkdir -p "$T/markers"
    RC=0
    OUT=$(MAIN_RED_MARKER_DIR="$T/markers" CLASSIFY_DIFF_FILE="$T/diff.txt" \
        bash "$SCRIPT" --log "$T/job.log" --job "unit tests" --case "$cs" --pr 7 --head abc123 "$@" 2>&1) || RC=$?
}
clear_markers() { rm -rf "$T/markers"; }

# 1. SIGNATURE: an npm audit advisory in the job log is MAIN-RED, and the diff
#    is not even consulted (it references the case, which would read PR-RED).
clear_markers
run "found 2 high severity vulnerabilities
npm audit failed" "diff --git a/foo.sh b/foo.sh
+audit" "npm audit"
eq "1: signature match exits 0" 0 "$RC"
has "MAIN-RED" "$OUT" "1: names MAIN-RED"
has "via signature" "$OUT" "1: names the deciding step"
if [ -n "$(ls "$T/markers" 2>/dev/null)" ]; then ok "1: a marker was written"; else bad "1: a marker was written"; fi
if grep -qF 'pr=7' "$T/markers"/* 2>/dev/null && grep -qF 'head=abc123' "$T/markers"/* 2>/dev/null; then ok "1: marker carries pr and head"; else bad "1: marker carries pr and head"; fi

# 1b. each signature class matches (control that the list is not one pattern).
for line in "getaddrinfo EAI_AGAIN registry.npmjs.org" "HTTP 503 Service Unavailable" "API rate limit exceeded" "The runner has received a shutdown signal" "lost communication with the server"; do
    clear_markers
    run "$line" "diff --git a/x b/x" "zzz-case"
    eq "1b: '$line' is MAIN-RED" 0 "$RC"
done

# 2. DIFF: no signature; the failing case is untouched by and unreferenced from
#    the PR diff -> MAIN-RED.
clear_markers
run "FAIL: widget parser case 7" "diff --git a/scripts/other.sh b/scripts/other.sh
+echo hi" "widget parser"
eq "2: unrelated diff exits 0" 0 "$RC"
has "via diff" "$OUT" "2: deciding step is the diff"

# 2b. control: the diff references the case -> the PR's own red (rc 1).
clear_markers
run "FAIL: widget parser case 7" "diff --git a/scripts/widget.sh b/scripts/widget.sh
+# widget parser change" "widget parser"
eq "2b: a diff that touches the case exits 1" 1 "$RC"
has "PR-RED" "$OUT" "2b: names PR-RED"
if [ -z "$(ls "$T/markers" 2>/dev/null)" ]; then ok "2b: no marker for a PR-RED"; else bad "2b: no marker for a PR-RED"; fi

# 3. MARKER read first: a prior leg's marker for the same job+case wins even
#    though the log has no signature and the diff references the case (which
#    alone would read PR-RED), and no diff file is needed at all.
clear_markers
mkdir -p "$T/markers"
printf 'evidence=npm audit\npr=3\nhead=deadbeef\n' > "$T/markers/unit_tests__widget_parser"
printf 'FAIL: widget parser\n' > "$T/job.log"
RC=0
OUT=$(MAIN_RED_MARKER_DIR="$T/markers" CLASSIFY_DIFF_FILE="$T/does-not-exist" \
    bash "$SCRIPT" --log "$T/job.log" --job "unit tests" --case "widget parser" 2>&1) || RC=$?
eq "3: an existing marker exits 0 before any diagnosis" 0 "$RC"
has "via marker" "$OUT" "3: deciding step is the marker"
has "pr=3" "$OUT" "3: prints the first leg's evidence"

# 4. usage: no --log is a usage error (64), never a verdict.
RC=0; OUT=$(bash "$SCRIPT" --job x 2>&1) || RC=$?
eq "4: missing --log exits 64" 64 "$RC"

echo
if [ "$fails" -eq 0 ]; then echo "classify-ci-red: all passed"; else echo "classify-ci-red: $fails failed"; fi
[ "$fails" -eq 0 ]
