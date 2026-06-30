#!/usr/bin/env bash
# macos.sh — ALPHA macOS installer for the himmel auto-arm chain (HIMMEL-594).
#
# *** ALPHA — UNVALIDATED ON REAL macOS ***
# There is no macOS CI/VM in the himmel project (the operator is on Windows), so
# this path is exercised only by mocked unit tests. Please VALIDATE that auto-arm
# actually fires and FILE AN ISSUE if it does not.
#
# Scope (explicit NON-GOAL: full ubuntu.sh parity — brew/node/Claude CLI/clone/
# vault). Assumes git, node, the Claude CLI, and the himmel clone already exist.
# Wires ONLY the himmel-specific bits the usage-cap auto-arm chain needs:
#   1. the statusline (the cap TRIGGER — without it the usage cache never exists
#      and the hook no-ops)
#   2. the auto-arm-on-cap PreToolUse hook (the cap ACTION)
#   3. verifies crontab (the macOS scheduler backend — arm-resume uses crontab,
#      NOT at/atrun, which is off-by-default / SIP-fragile; see arm-resume.sh +
#      scripts/lib/scheduler-backend.sh)
# Idempotent. Honors CLAUDE_DIR (default ~/.claude), HIMMEL_PATH (default: the
# clone this script lives in), and MACOS_ASSUME_YES=1 (skip the hook prompt).
set -euo pipefail

HIMMEL_PATH="${HIMMEL_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

TOTAL_STEPS=5
STEP=0
FAILURES=()
step() {
  STEP=$((STEP + 1))
  echo ""
  echo "══════════════════════════════════════════════"
  echo "[$STEP/$TOTAL_STEPS] $1"
  echo "══════════════════════════════════════════════"
}
fail_nonfatal() {
  echo "  WARNING: $1 failed — continuing"
  FAILURES+=("Step $STEP: $1")
}

echo "════════════════════════════════════════"
echo "himmel macOS installer — *** ALPHA (unvalidated) ***"
echo "  Assumes git / node / Claude CLI / himmel clone already installed."
echo "  Please validate auto-arm fires and file an issue if not."
echo "════════════════════════════════════════"

step "Wire the himmel statusline (the cap trigger)"
{
  # MUST run first: it creates settings.json from {} if absent, and the usage
  # cache the auto-arm hook reads only exists once the statusline runs.
  bash "$HIMMEL_PATH/scripts/lib/wire-statusline.sh" "$SETTINGS" "$HIMMEL_PATH"
} || fail_nonfatal "wire statusline"

step "Register auto-arm-on-cap PreToolUse hook"
{
  ARM_HOOK="$HIMMEL_PATH/scripts/hooks/auto-arm-on-cap.sh"
  if [ ! -f "$SETTINGS" ]; then
    echo "  ERROR: settings.json missing at $SETTINGS — the statusline step did not create it"
    fail_nonfatal "register auto-arm hook"
  elif [ ! -f "$ARM_HOOK" ]; then
    echo "  ERROR: hook script not found: $ARM_HOOK"
    fail_nonfatal "register auto-arm hook"
  else
    REG_ARGS=("$SETTINGS" "bash \"$ARM_HOOK\"")
    [ "${MACOS_ASSUME_YES:-0}" = "1" ] && REG_ARGS+=("--assume-yes")
    bash "$HIMMEL_PATH/scripts/lib/register-auto-arm-hook.sh" "${REG_ARGS[@]}"
  fi
} || fail_nonfatal "register auto-arm hook"

step "Verify the crontab scheduler backend (macOS uses crontab, not atrun)"
{
  if command -v crontab >/dev/null 2>&1; then
    echo "  crontab present."
    echo "  NOTE (ALPHA): on modern macOS, cron may need Full Disk Access granted"
    echo "  to /usr/sbin/cron (System Settings → Privacy & Security → Full Disk"
    echo "  Access). If auto-arm never fires, check this first and file an issue."
  else
    echo "  WARNING: crontab not found — auto-arm cannot schedule a resume."
    echo "  (ALPHA: please file an issue.)"
  fi
} || fail_nonfatal "verify crontab backend"

step "Report scheduler-backend status"
{
  # shellcheck source=scripts/lib/scheduler-backend.sh
  # shellcheck disable=SC1091
  if . "$HIMMEL_PATH/scripts/lib/scheduler-backend.sh" 2>/dev/null; then
    echo "  scheduler backend status: $(scheduler_backend_status) ($(scheduler_backend_os))"
  fi
} || fail_nonfatal "report scheduler-backend status"

step "Seed operator leak denylist (private tooling — skipped if absent)"
{
  # Private-only helper (in PRIVATE_PATHS): present on the operator's mirror,
  # absent on adopter clones → guarded skip. Idempotent.
  SEEDER="$HIMMEL_PATH/scripts/lib/seed-leak-denylist.sh"
  if [ -f "$SEEDER" ]; then bash "$SEEDER"; else echo "  skipped: $SEEDER not present (public/adopter clone)"; fi
} || fail_nonfatal "seed leak denylist"

echo ""
echo "════════════════════════════════════════"
echo "macOS ALPHA setup complete."
if [ ${#FAILURES[@]} -gt 0 ]; then
  echo "Non-fatal failures:"
  for f in "${FAILURES[@]}"; do echo "  - $f"; done
fi
echo "This installer is ALPHA — please validate auto-arm fires and file issues at"
echo "the himmel repo if anything is wrong."
echo "════════════════════════════════════════"
