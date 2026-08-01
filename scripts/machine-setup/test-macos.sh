#!/usr/bin/env bash
# Hermetic control-flow test for scripts/machine-setup/macos.sh (ALPHA installer).
# Real macOS behavior is unverified (no Mac); this asserts the script wires the
# statusline, registers the auto-arm hook, verifies crontab, and is idempotent.
set -uo pipefail

# grepq <text> [grep-args...] — a `grep -q` test against <text> with NO
# pipeline. printf/echo-into-`grep -q` is a trap under this file's
# `set -o pipefail`: grep -q exits the instant it matches, the producer
# then takes SIGPIPE writing the remainder, and pipefail reports the
# PIPELINE as failed — so a SUCCESSFUL match returns non-zero whenever
# the match lands early in a large input. A here-string is not a pipeline,
# so the status is grep's own verdict alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

REPO_ROOT="$(git rev-parse --show-toplevel)"
M="$REPO_ROOT/scripts/machine-setup/macos.sh"
[ -f "$M" ] || { echo "FAIL: $M not found"; exit 1; }
failures=0; pass() { printf '  PASS  %s\n' "$1"; }; fail() { printf '  FAIL  %s\n' "$1"; failures=$((failures+1)); }

t="$(mktemp -d)"; bin="$t/bin"; mkdir -p "$bin"
# crontab present (macOS backend), jq real, plus coreutils
printf '#!/bin/sh\nexit 0\n' > "$bin/crontab"; chmod +x "$bin/crontab"
for x in jq git bash sh sed grep tr head sort uname cat mkdir dirname chmod mv rm; do
    p="$(command -v "$x" 2>/dev/null)" && ln -sf "$p" "$bin/$x"
done

run() { env -i HOME="$t/home" PATH="$bin:$PATH" HIMMEL_PATH="$REPO_ROOT" \
            CLAUDE_DIR="$t/home/.claude" MACOS_ASSUME_YES=1 bash "$M" 2>&1; }

out="$(run)"; rc=$?
if [ "$rc" -eq 0 ]; then pass "macos.sh rc0"; else fail "macos.sh rc=$rc: $out"; fi
if [ -f "$t/home/.claude/settings.json" ]; then pass "settings.json created"; else fail "no settings.json"; fi
if grep -q 'statusLine' "$t/home/.claude/settings.json"; then pass "statusline wired"; else fail "no statusLine"; fi
if grep -q 'auto-arm-on-cap' "$t/home/.claude/settings.json"; then pass "auto-arm hook registered"; else fail "no auto-arm hook"; fi
if grepq "$out" -i 'alpha'; then pass "alpha notice printed"; else fail "no alpha notice"; fi

# idempotency: 2nd run, hook still registered exactly once
run >/dev/null 2>&1
n="$(jq '[.hooks.PreToolUse[]?.hooks[]?.command | select(test("auto-arm-on-cap"))] | length' "$t/home/.claude/settings.json")"
if [ "$n" -eq 1 ]; then pass "auto-arm hook registered once (idempotent)"; else fail "auto-arm hook count=$n"; fi
rm -rf "$t"
echo; if [ "$failures" -eq 0 ]; then echo "ALL PASS"; else echo "$failures FAILED"; exit 1; fi
