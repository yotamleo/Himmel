#!/usr/bin/env bash
# uninstall.sh — offboard the himmel operator surface (HIMMEL-227).
# Symmetric teardown of what setup.sh + install-plugins.sh onboard:
#
#   [1/6] stop the telegram bun bridge      (bun supervisor.ts --kill)
#   [2/6] remove telegram pairing + bridge state
#         (channel dir incl. access.json + bot-token .env; bridge root)
#   [3/6] remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge
#         logon task on Windows)
#   [4/6] uninstall Claude plugins + marketplaces
#         (machine-setup/uninstall-plugins.sh — user-scope, affects all repos)
#   [5/6] uninstall git hooks (pre-commit/pre-push/commit-msg)
#   [6/6] unwire ~/.claude/settings.json (statusLine, env.HIMMEL_REPO,
#         env.LUNA_VAULT_PATH, the UNIVERSAL hooks — what setup.sh/adopt wired)
#
# Destructive. Fail-closed: without --yes an interactive run prompts; a
# non-interactive run aborts (rc=2). --dry-run prints every action without
# executing anything.
#
# Usage:
#   bash scripts/uninstall.sh [--dry-run] [--yes]
#        [--keep-telegram-state] [--skip-plugins] [--skip-tasks] [--skip-hooks]
#        [--skip-settings]
#
# Flags:
#   --dry-run              Print actions instead of running them.
#   --yes                  Skip the confirmation prompt.
#   --keep-telegram-state  Keep the channel dir (token + access.json) and
#                          bridge state; still stops the bridge process.
#   --skip-plugins         Keep Claude plugins + marketplaces installed.
#   --skip-tasks           Keep HIMMEL-Resume-* / HimmelTelegramBridge jobs.
#   --skip-hooks           Keep the repo's pre-commit git hooks.
#   --skip-settings        Keep the user-scope ~/.claude/settings.json wiring
#                          (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, hooks).
#
# Env overrides (tests):
#   TELEGRAM_CHANNEL_DIR — default $HOME/.claude/channels/telegram
#   BRIDGE_ROOT          — default $HOME/.claude/handover/bridge
#                          (same var the bridge's bus.ts honors)
#   HIMMEL_USER_SETTINGS — default $HOME/.claude/settings.json (the [6/6] target)
#
# Exit codes: 0 = done (per-step problems are WARNs); 2 = aborted
# (no confirmation) or bad flag.
set -uo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

DRY_RUN=0
YES=0
KEEP_TELEGRAM_STATE=0
SKIP_PLUGINS=0
SKIP_TASKS=0
SKIP_HOOKS=0
SKIP_SETTINGS=0
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)             DRY_RUN=1 ;;
    --yes)                 YES=1 ;;
    --keep-telegram-state) KEEP_TELEGRAM_STATE=1 ;;
    --skip-plugins)        SKIP_PLUGINS=1 ;;
    --skip-tasks)          SKIP_TASKS=1 ;;
    --skip-hooks)          SKIP_HOOKS=1 ;;
    --skip-settings)       SKIP_SETTINGS=1 ;;
    -h|--help)
      sed -n '2,/^set -u/p' "$0" | sed 's/^# \{0,1\}//' | head -n -1
      exit 0
      ;;
    *) echo "ERROR: unknown flag: $1" >&2; exit 2 ;;
  esac
  shift
done

CHANNEL_DIR="${TELEGRAM_CHANNEL_DIR:-$HOME/.claude/channels/telegram}"
BRIDGE_ROOT="${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"
# Test override (HIMMEL_USER_SETTINGS) so the [6/6] settings-unwire can target a
# temp file instead of the operator's real ~/.claude/settings.json.
USER_SETTINGS="${HIMMEL_USER_SETTINGS:-$HOME/.claude/settings.json}"

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY: $*"
  else
    "$@"
  fi
}

# Obviously wrong rm -rf target (empty / root / $HOME itself)? rc=0 = yes.
# Checked by the caller (with `continue`, mirroring the ps1 sibling) so a
# refusal is never conflated with an rm FAILURE — the residue WARN must not
# tell the operator to manually remove $HOME.
suspicious_rm_path() {
  case "$1" in
    ""|"/"|"$HOME"|"$HOME/") return 0 ;;
    *) return 1 ;;
  esac
}

echo "==> himmel uninstall (offboard)"
echo ""
echo "This will:"
echo "  1. stop the telegram bun bridge (if running)"
if [ "$KEEP_TELEGRAM_STATE" -eq 0 ]; then
  echo "  2. REMOVE telegram pairing + bridge state:"
  echo "       $CHANNEL_DIR   (bot-token .env + access.json)"
  echo "       $BRIDGE_ROOT   (sessions, inbox/outbox, supervisor state)"
else
  echo "  2. keep telegram state (--keep-telegram-state)"
fi
if [ "$SKIP_TASKS" -eq 0 ]; then
  echo "  3. remove HIMMEL-Resume-* scheduled jobs (+ HimmelTelegramBridge logon task)"
else
  echo "  3. keep scheduled jobs (--skip-tasks)"
fi
if [ "$SKIP_PLUGINS" -eq 0 ]; then
  echo "  4. uninstall Claude plugins + marketplaces from settings-template"
  echo "     (USER-SCOPE: affects every repo on this machine)"
else
  echo "  4. keep Claude plugins (--skip-plugins)"
fi
if [ "$SKIP_HOOKS" -eq 0 ]; then
  echo "  5. uninstall this repo's git hooks (pre-commit/pre-push/commit-msg)"
else
  echo "  5. keep git hooks (--skip-hooks)"
fi
if [ "$SKIP_SETTINGS" -eq 0 ]; then
  echo "  6. unwire ~/.claude/settings.json (statusLine, HIMMEL_REPO,"
  echo "     LUNA_VAULT_PATH, UNIVERSAL hooks — non-himmel keys untouched)"
else
  echo "  6. keep ~/.claude/settings.json wiring (--skip-settings)"
fi
echo ""

if [ "$DRY_RUN" -eq 1 ]; then
  echo "(dry-run — nothing will be executed)"
elif [ "$YES" -ne 1 ]; then
  if [ -t 0 ] && [ -t 1 ]; then
    printf "Proceed? [y/N] "
    read -r _ans
    case "$_ans" in
      [yY]|[yY][eE][sS]) : ;;
      *) echo "Aborted."; exit 2 ;;
    esac
  else
    echo "ERROR: non-interactive run without --yes — aborting (fail-closed)." >&2
    echo "  Re-run with --yes to confirm, or --dry-run to preview." >&2
    exit 2
  fi
fi
echo ""

# --- [1/6] stop the bridge -------------------------------------------------
# Uses the documented cross-platform lever (supervisor.pid under the bridge
# root; see docs/internals/telegram-bridge.md). BRIDGE_ROOT is passed through
# so a non-default root kills the matching bridge, not another one.
# bridge_maybe_running gates step 2: removing state while a supervisor may
# still be live would be recreated by it (and on Windows, locked files make
# the removal fail partway).
bridge_maybe_running=0
echo "[1/6] Stopping telegram bridge..."
if [ ! -f "$BRIDGE_ROOT/supervisor.pid" ]; then
  echo "  no supervisor.pid under $BRIDGE_ROOT — bridge not running, skipping."
elif ! command -v bun >/dev/null 2>&1; then
  echo "  WARN: supervisor.pid exists but bun is not on PATH — cannot stop the bridge." >&2
  if [[ "$OSTYPE" == "msys" || "$OSTYPE" == "cygwin" || "$OSTYPE" == "win"* ]] \
      || command -v pwsh >/dev/null 2>&1; then
    echo "  Stop it manually: pwsh -File scripts/telegram/restart-bridge.ps1 -StatusOnly (inspect), then kill." >&2
  else
    echo "  Find the supervisor pid in $BRIDGE_ROOT/supervisor.pid and kill it manually." >&2
  fi
  bridge_maybe_running=1
else
  run env BRIDGE_ROOT="$BRIDGE_ROOT" bun --cwd "$REPO_ROOT/scripts/telegram" supervisor.ts --kill
  _rc=$?
  # --kill rc: 0 = killed/already gone, 1 = pidfile absent (not running),
  # 2 = pidfile unreadable/corrupt OR a signal failed (e.g. EPERM) → bridge
  # MAY still be running (supervisor keeps the pidfile in that case).
  if [ "$DRY_RUN" -eq 0 ] && [ "$_rc" -ge 2 ]; then
    echo "  WARN: supervisor --kill rc=$_rc — bridge may still be running; check manually." >&2
    bridge_maybe_running=1
  fi
fi
echo ""

# --- [2/6] remove telegram pairing + bridge state ----------------------------
echo "[2/6] Removing telegram pairing + bridge state..."
if [ "$KEEP_TELEGRAM_STATE" -eq 1 ]; then
  echo "  kept (--keep-telegram-state)."
elif [ "$bridge_maybe_running" -eq 1 ]; then
  echo "  SKIPPED: step 1 could not stop the bridge — a running supervisor would" >&2
  echo "  recreate (or hold locks on) state under $BRIDGE_ROOT. Kill the bridge" >&2
  echo "  manually, then re-run uninstall." >&2
else
  for _dir in "$CHANNEL_DIR" "$BRIDGE_ROOT"; do
    if suspicious_rm_path "$_dir"; then
      echo "  WARN: refusing to remove suspicious path: '$_dir'" >&2
      continue
    fi
    if [ -d "$_dir" ]; then
      if run rm -rf -- "$_dir"; then
        if [ "$DRY_RUN" -eq 0 ]; then
          echo "  removed: $_dir"
        fi
      else
        echo "  WARN: failed to remove $_dir — residue remains; remove it manually." >&2
      fi
    else
      echo "  absent, skipping: $_dir"
    fi
  done
  echo "  NOTE: deleting the local token does NOT revoke it — if decommissioning"
  echo "  the bot, revoke the token via @BotFather too."
fi
echo ""

# --- [3/6] remove scheduled jobs ---------------------------------------------
# Mirrors scripts/handover/arm-resume.sh job discovery: schtasks task names
# on Windows; at-job body marker / crontab line marker on Linux/macOS.
echo "[3/6] Removing scheduled jobs (HIMMEL-Resume-*, HimmelTelegramBridge)..."
if [ "$SKIP_TASKS" -eq 1 ]; then
  echo "  kept (--skip-tasks)."
elif command -v schtasks >/dev/null 2>&1; then
  # MSYS_NO_PATHCONV=1 per call (HIMMEL-125): gitbash otherwise mangles
  # /query-style flags into Windows paths before schtasks sees them.
  # Capture the /query rc separately (setup.sh qmd-list precedent): piping
  # straight through grep would mask an enumeration failure as "no tasks".
  _query_out=$(MSYS_NO_PATHCONV=1 schtasks /query /fo CSV /nh 2>&1)
  _query_rc=$?
  if [ "$_query_rc" -ne 0 ]; then
    echo "  WARN: schtasks /query failed (rc=$_query_rc) — cannot enumerate;" >&2
    echo "  HIMMEL-Resume-* / HimmelTelegramBridge tasks may remain." >&2
  else
    # shellcheck disable=SC1003  # `"\\'` strips both quote and literal backslash from schtasks's path-prefixed task names
    _tasks=$(printf '%s\n' "$_query_out" \
      | grep -o '"\\\?HIMMEL-Resume-[^"]*"' 2>/dev/null \
      | tr -d '"\\' | sort -u || true)
    if MSYS_NO_PATHCONV=1 schtasks /query /tn "HimmelTelegramBridge" >/dev/null 2>&1; then
      _tasks=$(printf '%s\nHimmelTelegramBridge' "$_tasks")
    fi
    _found=0
    while IFS= read -r _task; do
      [ -z "$_task" ] && continue
      _found=1
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "DRY: schtasks /delete /tn $_task /f"
      elif MSYS_NO_PATHCONV=1 schtasks /delete /tn "$_task" /f >/dev/null 2>&1; then
        echo "  deleted scheduled task: $_task"
      else
        echo "  WARN: failed to delete scheduled task: $_task" >&2
      fi
    done <<EOF
$_tasks
EOF
    [ "$_found" -eq 0 ] && echo "  no matching scheduled tasks found."
  fi
else
  _found=0
  _query_failed=0
  if command -v atq >/dev/null 2>&1; then
    # Capture the atq rc separately — `atq || true` would mask an
    # enumeration failure as "no jobs" (same precedent as above).
    _atq_out=$(atq 2>&1)
    _atq_rc=$?
    if [ "$_atq_rc" -ne 0 ]; then
      _query_failed=1
      echo "  WARN: atq failed (rc=$_atq_rc) — cannot enumerate at jobs; they may remain." >&2
    else
      while IFS= read -r _line; do
        [ -z "$_line" ] && continue
        _job_id=$(printf '%s' "$_line" | awk '{print $1}')
        [ -z "$_job_id" ] && continue
        if at -c "$_job_id" 2>/dev/null | grep -q 'HIMMEL-Resume-'; then
          _found=1
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY: atrm $_job_id"
          elif atrm "$_job_id" 2>/dev/null; then
            echo "  removed at job: $_job_id"
          else
            echo "  WARN: failed to remove at job: $_job_id" >&2
          fi
        fi
      done <<EOF
$_atq_out
EOF
    fi
  fi
  if command -v crontab >/dev/null 2>&1; then
    # Snapshot `crontab -l` output + rc FIRST (pipeline-cadence cron_read
    # precedent): piping `crontab -l 2>/dev/null` straight into grep would mask
    # a read failure as "no match", and feeding the rewrite below from a failed
    # (empty) listing would install an EMPTY crontab — wiping every unrelated
    # job. Fail-closed classifier: only rc=1 with empty stderr or the standard
    # "no crontab for <user>" message is trusted as "no crontab installed";
    # anything else WARNs and skips the rewrite.
    _cron_err=$(mktemp)
    _cron_out=$(LC_ALL=C crontab -l 2>"$_cron_err")
    _cron_rc=$?
    if [ "$_cron_rc" -eq 0 ]; then
      case "$_cron_out" in
        *HIMMEL-Resume-*)
          _found=1
          if [ "$DRY_RUN" -eq 1 ]; then
            echo "DRY: crontab — strip lines containing HIMMEL-Resume-"
          # `|| true` inside the group: grep -v exits 1 when every line matched
          # (legit: only HIMMEL lines existed → install an empty crontab); with
          # pipefail that rc would otherwise mask a successful rewrite as failed.
          elif { printf '%s\n' "$_cron_out" | grep -vF 'HIMMEL-Resume-' || true; } | crontab -; then
            echo "  stripped HIMMEL-Resume-* lines from crontab"
          else
            echo "  WARN: failed to rewrite crontab — HIMMEL-Resume-* lines may remain." >&2
          fi
          ;;
      esac
    elif [ "$_cron_rc" -eq 1 ] && { [ ! -s "$_cron_err" ] || grep -qi 'no crontab' "$_cron_err"; }; then
      : # no crontab installed — genuinely nothing to do
    else
      _query_failed=1
      echo "  WARN: crontab -l failed (rc=$_cron_rc) — cannot enumerate cron jobs;" >&2
      echo "  HIMMEL-Resume-* lines may remain." >&2
    fi
    rm -f "$_cron_err"
  fi
  [ "$_found" -eq 0 ] && [ "$_query_failed" -eq 0 ] && echo "  no matching scheduled jobs found."
fi
echo ""

# --- [4/6] uninstall plugins + marketplaces ----------------------------------
echo "[4/6] Uninstalling Claude plugins + marketplaces..."
if [ "$SKIP_PLUGINS" -eq 1 ]; then
  echo "  kept (--skip-plugins)."
elif ! command -v claude >/dev/null 2>&1; then
  echo "  claude CLI not on PATH — skipping (nothing to uninstall through)."
else
  _plug_args=()
  [ "$DRY_RUN" -eq 1 ] && _plug_args+=(--dry-run)
  if ! bash "$REPO_ROOT/scripts/machine-setup/uninstall-plugins.sh" ${_plug_args[@]+"${_plug_args[@]}"}; then
    echo "  WARN: uninstall-plugins.sh reported failures — re-run it directly to inspect." >&2
  fi
fi
echo ""

# --- [5/6] uninstall git hooks -------------------------------------------------
# Mirror of setup-hooks.sh / setup.sh step 2.
echo "[5/6] Uninstalling git hooks (this repo)..."
if [ "$SKIP_HOOKS" -eq 1 ]; then
  echo "  kept (--skip-hooks)."
elif ! command -v pre-commit >/dev/null 2>&1; then
  echo "  pre-commit not on PATH — skipping."
else
  for _hook_type in "" "pre-push" "commit-msg"; do
    if [ -n "$_hook_type" ]; then
      _cmd_args=(--hook-type "$_hook_type")
      _label="--hook-type $_hook_type"
    else
      _cmd_args=()
      _label="pre-commit (default)"
    fi
    if ! (cd "$REPO_ROOT" && run pre-commit uninstall ${_cmd_args[@]+"${_cmd_args[@]}"}); then
      echo "  WARN: pre-commit uninstall $_label failed." >&2
    fi
  done
fi
echo ""

# --- [6/6] unwire user-scope settings.json (HIMMEL-460) ----------------------
# Symmetric inverse of setup.sh [9/10] + adopt --scope user: remove the
# statusLine, env.HIMMEL_REPO, env.LUNA_VAULT_PATH, and the UNIVERSAL hooks that
# himmel wired into ~/.claude/settings.json. Each helper removes ONLY its own
# key/stanza (refuses invalid JSON, preserves every non-himmel key: rtk guard,
# the operator's own hooks, MCP config). --dry-run flows through to each.
echo "[6/6] Unwiring ~/.claude/settings.json (statusLine, HIMMEL_REPO, LUNA_VAULT_PATH, hooks)..."
_user_settings="$USER_SETTINGS"
if [ "$SKIP_SETTINGS" -eq 1 ]; then
  echo "  kept (--skip-settings)."
elif [ ! -f "$_user_settings" ]; then
  echo "  no $_user_settings — nothing to unwire."
elif [ "$DRY_RUN" -eq 1 ]; then
  # The single-key unwire helpers have no dry-run flag, so gate at this level to
  # keep --dry-run a true no-op (SC6). unwire-pretooluse-hooks has its own flag.
  echo "DRY: unwire statusLine (himmel), env.HIMMEL_REPO, env.LUNA_VAULT_PATH from $_user_settings"
  bash "$REPO_ROOT/scripts/lib/unwire-pretooluse-hooks.sh" "$_user_settings" 1 \
    || echo "  WARN: unwire-pretooluse-hooks dry-run reported a problem." >&2
else
  for _unwire in unwire-statusline unwire-himmel-repo unwire-luna-vault; do
    if ! bash "$REPO_ROOT/scripts/lib/$_unwire.sh" "$_user_settings"; then
      echo "  WARN: $_unwire reported a problem; setup-state may remain." >&2
    fi
  done
  bash "$REPO_ROOT/scripts/lib/unwire-pretooluse-hooks.sh" "$_user_settings" \
    || echo "  WARN: unwire-pretooluse-hooks reported a problem." >&2
fi
echo ""

echo "Uninstall complete."
echo ""
echo "NOT touched (by design):"
echo "  - ~/.claude/settings.json non-himmel keys (MCP config, your own hooks, rtk guard)"
echo "  - the himmel clone itself, .env, and worktrees"
echo "  - ~/.claude/handover/registry.json + handover state outside the bridge root"
