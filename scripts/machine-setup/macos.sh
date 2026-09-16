#!/usr/bin/env bash
# macos.sh — ALPHA macOS installer for the himmel auto-arm chain (HIMMEL-594),
# plus the uv + bun toolchain (HIMMEL-3068).
#
# *** ALPHA — UNVALIDATED ON REAL macOS ***
# There is no macOS CI/VM in the himmel project (the operator is on Windows), so
# this path is exercised only by mocked unit tests. Please VALIDATE that auto-arm
# actually fires, and that uv/bun resolve, and FILE AN ISSUE if either does not.
#
# Scope (explicit NON-GOAL: full ubuntu.sh parity — node/Claude CLI/clone/vault
# are still assumed to already exist). uv and bun are NOT optional extras,
# though, so this script installs both via Homebrew (HIMMEL-3068):
#   - uv is a HARD dependency of graphify (scripts/lib/graphify-bin.sh —
#     /graphify, graph-cadence.sh, the graphify MCP server all need it), and
#     macOS previously had no install path for it at all.
#   - bun is a HARD dependency of himmel-update.sh's qmd fork updater
#     (update_qmd_fork) and the jira CLI dist rebuild's npm-absent fallback.
# Homebrew (not a curl-pipe installer) is the idiomatic macOS path here, and it
# is what lets himmel-update.sh's toolchain step (HIMMEL-3068) offer a real
# upgrade route later (`brew upgrade uv` / `brew upgrade oven-sh/bun/bun`)
# instead of freezing these tools at whatever version this script happened to
# install. Wires:
#   0. Homebrew presence (precondition for the uv/bun steps below — fails
#      LOUD via the same non-fatal fail_nonfatal() every other step in this
#      file already uses, never a silent skip into a `brew` command that
#      cannot resolve)
#   1. uv + uvx (`brew install uv` — homebrew-core, no tap needed)
#   2. bun (`brew install oven-sh/bun/bun` — bun is NOT in homebrew-core as of
#      2026-09; the oven-sh/bun tap is still required. Verified against
#      github.com/oven-sh/homebrew-bun and bun.com/docs/installation, both
#      current as of this writing — re-check before assuming this is stale.)
#   3. the statusline (the cap TRIGGER — without it the usage cache never exists
#      and the hook no-ops)
#   4. the auto-arm-on-cap PreToolUse hook (the cap ACTION)
#   5. verifies crontab (the macOS scheduler backend — arm-resume uses crontab,
#      NOT at/atrun, which is off-by-default / SIP-fragile; see arm-resume.sh +
#      scripts/lib/scheduler-backend.sh)
#   6. hands off to the himmelctl install wizard (HIMMEL-3068) — arming a
#      cadence (drift-fix/upstream-watch/repo-sync/pull-cadence/...) was
#      previously reachable only by separately running himmelctl, so this is
#      where arming stops being undiscoverable, same as ubuntu.sh/win11.ps1
#      already do at the end of their own runs.
# Idempotent. Honors CLAUDE_DIR (default ~/.claude), HIMMEL_PATH (default: the
# clone this script lives in), and MACOS_ASSUME_YES=1 (skip the hook prompt).
set -euo pipefail

HIMMEL_PATH="${HIMMEL_PATH:-$(cd "$(dirname "$0")/../.." && pwd)}"
CLAUDE_DIR="${CLAUDE_DIR:-$HOME/.claude}"
SETTINGS="$CLAUDE_DIR/settings.json"

TOTAL_STEPS=9
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
echo "  Please validate auto-arm fires, uv/bun resolve, and file an issue if not."
echo "════════════════════════════════════════"

HAVE_BREW=0
step "Verify Homebrew is present (installs uv + bun below)"
{
  if command -v brew >/dev/null 2>&1; then
    HAVE_BREW=1
    echo "  brew found: $(brew --version 2>/dev/null | head -1)"
  else
    echo "  Homebrew not found — install it from https://brew.sh, then re-run this script"
    echo "  to get uv/bun. Proceeding WITHOUT them (both steps below will skip)."
    false
  fi
} || fail_nonfatal "Homebrew not found — uv/bun install skipped"

step "Install uv + uvx via Homebrew (graphify hard dependency)"
{
  if [ "$HAVE_BREW" -eq 1 ]; then
    brew install uv
    uv --version
  else
    echo "  skipped: Homebrew not found (see previous step) — install uv manually (https://astral.sh/uv) or install Homebrew and re-run." >&2
    false
  fi
} || fail_nonfatal "install uv"

step "Install bun via Homebrew (qmd fork updater + jira CLI hard dependency)"
{
  if [ "$HAVE_BREW" -eq 1 ]; then
    # bun is NOT in homebrew-core (verified 2026-09 against
    # github.com/oven-sh/homebrew-bun + bun.com/docs/installation) — the
    # oven-sh/bun tap is still required. `brew tap` is idempotent (a no-op if
    # already tapped); the fully-qualified formula name (tap/formula) works
    # whether or not a bare `bun` name is already resolvable from some other
    # tap, and is what upstream's own docs give as the install command.
    brew tap oven-sh/bun
    brew install oven-sh/bun/bun
    bun --version
  else
    echo "  skipped: Homebrew not found (see previous step) — install bun manually (https://bun.sh) or install Homebrew and re-run." >&2
    false
  fi
} || fail_nonfatal "install bun"

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

step "Hand off to the himmelctl install wizard (cadences, plugins, hooks)"
{
  # HIMMEL-3068: arming a cadence (drift-fix, upstream-watch, repo-sync,
  # pull-cadence, ...) was previously reachable only by separately running
  # himmelctl, so it never happened on a fresh machine unless the operator
  # remembered to. ubuntu.sh/win11.ps1 already end by delegating to this
  # same wizard (HIMMEL-887) via `exec` -- deliberately NOT an exec here,
  # since macos.sh (unlike those two) still wants to print its own summary
  # below afterward. Bootstrap.sh short-circuits straight to `node bin.js
  # install` when node is already on PATH (true here per this file's own
  # assumptions), so this is the same wizard those installers hand off to,
  # not a second implementation. Interactive; a non-interactive/no-TTY run
  # refuses loudly (the wizard's own documented contract) rather than hang
  # or silently no-op -- caught by fail_nonfatal like every other step here.
  HIMMELCTL_REPO_ROOT="$HIMMEL_PATH" bash "$HIMMEL_PATH/scripts/himmelctl/bootstrap.sh" --default-scope user
} || fail_nonfatal "himmelctl install wizard hand-off"

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
