#!/usr/bin/env bash
# Smoke test for scripts/lib/wire-caveman-node.sh.
# Usage: bash scripts/lib/test-wire-caveman-node.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
WIRE="$REPO_ROOT/scripts/lib/wire-caveman-node.sh"
[ -f "$WIRE" ] || { echo "FAIL: $WIRE not found"; exit 1; }

failures=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

# Opaque non-slash tokens for the himmel/claude args: the rewrite interpolates
# them verbatim, and avoiding leading slashes sidesteps Git Bash POSIX->Windows
# arg conversion (which would mangle /fake/... but must stay ON for the real
# settings-file path that native jq opens).
HP="HIMMELROOT"; CD="CLAUDEDIR"
WANT_SS='bash "HIMMELROOT/scripts/lib/run-node.sh" "CLAUDEDIR/hooks/caveman-activate.js"'
WANT_UPS='bash "HIMMELROOT/scripts/lib/run-node.sh" "CLAUDEDIR/hooks/caveman-mode-tracker.js"'

# Fake a non-Windows uname so the rewrite runs on this MINGW box.
FAKEBIN="$(mktemp -d)/bin"; mkdir -p "$FAKEBIN"
printf '#!/bin/sh\necho Linux\n' > "$FAKEBIN/uname"; chmod +x "$FAKEBIN/uname"
# MSYS_NO_PATHCONV=1: stop Git Bash rewriting the fake /fake/... args into
# Windows paths (a Git-Bash-only arg-conversion; real Linux/macOS never mangle).
run_wire() { PATH="$FAKEBIN:$PATH" bash "$WIRE" "$1" "$HP" "$CD"; }

# $1 = caveman SessionStart command, $2 = caveman UserPromptSubmit command
write_settings() {
    cat > "$3" <<EOF
{
  "hooks": {
    "SessionStart": [
      { "hooks": [
        { "type": "command", "command": $1 },
        { "type": "command", "command": "bash \"<himmel-path>/scripts/hooks/check-update-available.sh\"", "timeout": 15 }
      ] }
    ],
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": $2 } ] }
    ]
  }
}
EOF
}

echo "== dangling <node-path> -> wrapper form, sibling preserved =="
s="$(mktemp)"
write_settings '"\"<node-path>\" \"<claude-dir>/hooks/caveman-activate.js\""' '"\"<node-path>\" \"<claude-dir>/hooks/caveman-mode-tracker.js\""' "$s"
run_wire "$s"
got_ss="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")"
got_ups="$(jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' "$s")"
sib="$(jq -r '.hooks.SessionStart[0].hooks[1].command' "$s")"
if [ "$got_ss" = "$WANT_SS" ]; then pass "SessionStart rewritten"; else fail "SessionStart -> '$got_ss'"; fi
if [ "$got_ups" = "$WANT_UPS" ]; then pass "UserPromptSubmit rewritten"; else fail "UserPromptSubmit -> '$got_ups'"; fi
case "$sib" in *check-update-available.sh*) pass "sibling preserved" ;; *) fail "sibling clobbered -> '$sib'" ;; esac
if jq -e . "$s" >/dev/null 2>&1; then pass "valid JSON"; else fail "invalid JSON"; fi

echo "== idempotent (2nd run byte-identical) =="
cp "$s" "$s.before"; run_wire "$s"
if cmp -s "$s" "$s.before"; then pass "idempotent"; else fail "not idempotent"; fi
rm -f "$s" "$s.before"

echo "== bare-node variant converges =="
s="$(mktemp)"
write_settings '"node \"/old/path/hooks/caveman-activate.js\""' '"node \"/old/path/hooks/caveman-mode-tracker.js\""' "$s"
run_wire "$s"
got_ss="$(jq -r '.hooks.SessionStart[0].hooks[0].command' "$s")"
if [ "$got_ss" = "$WANT_SS" ]; then pass "bare-node -> wrapper"; else fail "bare-node -> '$got_ss'"; fi
rm -f "$s"

# (already-wrapped convergence is covered by the idempotent case above.)

rm -rf "$(dirname "$FAKEBIN")"
echo
if [ "$failures" -eq 0 ]; then echo "ALL PASS"; exit 0; else echo "$failures FAILURE(S)"; exit 1; fi
