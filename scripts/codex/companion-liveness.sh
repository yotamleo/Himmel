#!/usr/bin/env bash
# companion-liveness.sh (HIMMEL-741) - flag stuck codex-companion jobs.
#
# WHY: the codex-companion background task-worker can die silently, leaving its
# job pinned at "queued"/"running" in the per-workspace job registry forever;
# any dispatcher polling `codex-companion status` then waits for a job whose
# runner is already dead. This probe reads the registry for a workspace and
# reports active jobs older than a threshold whose recorded runner pid is dead
# (or was never a separate process), so the stall is visible instead of silent.
#
# GROUNDING (verified on this machine + codex-companion 1.0.5 source):
#   State dir (lib/state.mjs resolveStateDir):
#     $CLAUDE_PLUGIN_DATA/state/<slug>-<sha256(realpath(workspace))[:16]>/
#     slug = basename(workspace) with [^A-Za-z0-9._-]+ -> '-'. Fallback state
#     root when CLAUDE_PLUGIN_DATA is unset: <os.tmpdir>/codex-companion.
#     On this box: ~/.claude/plugins/data/codex-openai-codex/state/
#       himmel-380d03577bfc6dc9/state.json
#   state.json shape (lib/state.mjs): { version, config, jobs: [ {
#       id, kind, kindLabel, title, workspaceRoot, jobClass, status,
#       createdAt, updatedAt, startedAt, completedAt, pid, logFile, ... } ] }
#   status in queued|running|completed|failed|cancelled; ACTIVE = queued|running
#     (codex-companion.mjs isActiveJobStatus). A backgrounded worker records its
#     detached pid (enqueueBackgroundTask: pid = child.pid); a foreground job
#     records pid=null (runs inside the parent, no separate runner).
#   Example real record (completed): pid=null, status="completed",
#     updatedAt="2026-07-07T10:14:16.500Z".
#
# RESOLUTION ORDER (first hit wins):
#   CODEX_STATE_DIR   - a single <slug>-<hash> dir (used verbatim; test seam).
#   CODEX_STATE_ROOT  - the 'state' dir that CONTAINS the <slug>-<hash> dirs.
#   CLAUDE_PLUGIN_DATA/state
#   ~/.claude/plugins/data/codex-openai-codex/state   (this machine's default)
# Workspace = $1 or $PWD; its slug selects <state-root>/<slug>-* dirs.
# Threshold = CODEX_STUCK_THRESHOLD_SECS (default 1800 = 30m).
#
#   scripts/codex/companion-liveness.sh [workspace-dir]
# Exit codes (mirrors scripts/codex/startup-health.sh contract):
#   0 = healthy (no stuck jobs)   1 = findings (stuck jobs)   2 = cannot read
set -euo pipefail

THRESHOLD="${CODEX_STUCK_THRESHOLD_SECS:-1800}"
WORKSPACE="${1:-$PWD}"

NODE_BIN=""
for c in node node.exe; do
  if command -v "$c" >/dev/null 2>&1; then NODE_BIN="$c"; break; fi
done
if [ -z "$NODE_BIN" ]; then
  echo "cannot-read: node not found on PATH (needed to parse the JSON registry)." >&2
  exit 2
fi

# --- platform + pid liveness (mirror arm-resume.sh _pid_alive) ---------------
case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
  msys*|cygwin*|win32*|MINGW*|MSYS*) PLATFORM=windows ;;
  linux*|Linux*)                     PLATFORM=linux ;;
  darwin*|Darwin*)                   PLATFORM=macos ;;
  *)                                 PLATFORM=unknown ;;
esac

_pid_alive() {
  local pid="$1"
  [ -n "$pid" ] || return 1
  case "$PLATFORM" in
    windows)
      local out rc
      out=$(MSYS_NO_PATHCONV=1 tasklist /FI "PID eq $pid" 2>&1); rc=$?
      case "$out" in
        *"No tasks"*) return 1 ;;
        *"$pid"*)     [ "$rc" -eq 0 ] && return 0 ;;
      esac
      return 1
      ;;
    *)
      kill -0 "$pid" 2>/dev/null
      ;;
  esac
}

# --- resolve the state dir(s) for this workspace -----------------------------
STATE_DIRS=()
if [ -n "${CODEX_STATE_DIR:-}" ]; then
  STATE_DIRS=("$CODEX_STATE_DIR")
else
  # Candidate roots, mirroring lib/state.mjs: CLAUDE_PLUGIN_DATA/state when the
  # harness sets it, else os.tmpdir()/codex-companion (the companion's REAL
  # fallback). The plugins/data path is kept as a candidate because in-session
  # runs get CLAUDE_PLUGIN_DATA pointed there. All existing roots are scanned -
  # a probe checking only one can falsely report healthy.
  STATE_ROOTS=()
  if [ -n "${CODEX_STATE_ROOT:-}" ]; then
    STATE_ROOTS=("$CODEX_STATE_ROOT")
  else
    [ -n "${CLAUDE_PLUGIN_DATA:-}" ] && STATE_ROOTS+=("$CLAUDE_PLUGIN_DATA/state")
    STATE_ROOTS+=("$HOME/.claude/plugins/data/codex-openai-codex/state")
    STATE_ROOTS+=("${TMPDIR:-${TEMP:-/tmp}}/codex-companion")
  fi
  # slug = basename(workspace), sanitized exactly like lib/state.mjs.
  base="$(basename "$WORKSPACE")"
  slug="$(printf '%s' "$base" | sed 's/[^A-Za-z0-9._-][^A-Za-z0-9._-]*/-/g; s/^-*//; s/-*$//')"
  [ -n "$slug" ] || slug="workspace"
  found_root=0
  for r in "${STATE_ROOTS[@]}"; do
    [ -d "$r" ] || continue
    found_root=1
    for d in "$r/$slug"-*; do
      [ -d "$d" ] && STATE_DIRS+=("$d")
    done
  done
  if [ "$found_root" -eq 0 ]; then
    echo "healthy: no codex-companion state root (checked: ${STATE_ROOTS[*]}) (no jobs to check)."
    exit 0
  fi
fi

if [ "${#STATE_DIRS[@]}" -eq 0 ]; then
  echo "healthy: no codex-companion state dir for workspace '$WORKSPACE' (no jobs to check)."
  exit 0
fi

# --- emit active jobs from each state.json via node --------------------------
# node prints TAB-separated: status  pid  ageSecs  id  title  (one active job
# per line). Exits 3 if the file is present but unparseable (-> cannot-read).
extract_active() {
  local statefile="$1"
  # shellcheck disable=SC2016  # the single-quoted body is JS for node, not bash.
  "$NODE_BIN" -e '
    const fs = require("fs");
    const f = process.argv[1];
    let raw;
    try { raw = fs.readFileSync(f, "utf8"); } catch { process.exit(0); }
    let o;
    try { o = JSON.parse(raw); } catch { process.exit(3); }
    const jobs = Array.isArray(o.jobs) ? o.jobs : [];
    const now = Date.now();
    for (const j of jobs) {
      const st = j.status;
      if (st !== "queued" && st !== "running") continue;
      const ts = Date.parse(j.updatedAt || j.startedAt || j.createdAt || "");
      const age = Number.isFinite(ts) ? Math.max(0, Math.round((now - ts) / 1000)) : -1;
      // "-" sentinel for a null pid: TAB is whitespace-IFS in bash `read`, so an
      // empty interior field would collapse and shift every later column.
      const pid = (j.pid === null || j.pid === undefined) ? "-" : String(j.pid);
      const title = String(j.title || "").replace(/[\t\r\n]+/g, " ").slice(0, 60);
      process.stdout.write([st, pid, age, j.id || "?", title].join("\t") + "\n");
    }
  ' "$statefile"
}

findings=0
checked_files=0

for dir in "${STATE_DIRS[@]}"; do
  statefile="$dir/state.json"
  [ -f "$statefile" ] || continue
  checked_files=$((checked_files + 1))

  active_out="$(extract_active "$statefile")" || {
    rc=$?
    if [ "$rc" -eq 3 ]; then
      echo "cannot-read: $statefile is not valid JSON." >&2
      exit 2
    fi
    echo "cannot-read: failed to read $statefile (node rc=$rc)." >&2
    exit 2
  }

  [ -n "$active_out" ] || continue

  while IFS=$'\t' read -r status pid age id title; do
    [ -n "${status:-}" ] || continue
    [ "$pid" = "-" ] && pid=""   # decode the null-pid sentinel
    # A job is STUCK when it is old enough AND has no live runner. A live pid
    # means the worker is still doing the job (not stuck), regardless of age.
    if [ "$age" -ge 0 ] && [ "$age" -lt "$THRESHOLD" ]; then
      continue   # too fresh to call stuck
    fi
    if [ -n "$pid" ] && _pid_alive "$pid"; then
      continue   # runner alive -> working, not stuck
    fi
    runner="dead pid $pid"
    [ -n "$pid" ] || runner="no runner pid (foreground/never-detached)"
    if [ "$findings" -eq 0 ]; then
      echo "STUCK codex-companion job(s) - active but no live runner:"
    fi
    findings=$((findings + 1))
    printf '  %-9s age=%ss  %s  [%s]  %s\n' "$status" "$age" "$id" "$runner" "$title"
  done <<EOF
$active_out
EOF
done

if [ "$checked_files" -eq 0 ]; then
  echo "healthy: no state.json under the resolved state dir(s) (no jobs to check)."
  exit 0
fi

if [ "$findings" -gt 0 ]; then
  echo "$findings stuck job(s) found (threshold ${THRESHOLD}s)."
  exit 1
fi

echo "healthy: no stuck codex-companion jobs (threshold ${THRESHOLD}s)."
exit 0
