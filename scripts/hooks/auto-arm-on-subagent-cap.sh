#!/usr/bin/env bash
# auto-arm-on-subagent-cap.sh — PostToolUse hook: auto-arm a resume when the
# usage cap surfaces as a subagent (Agent tool) result text (HIMMEL-276).
#
# WHY: The PreToolUse hook auto-arm-on-cap.sh detects the cap through the
# statusline usage cache. But when the cap hits MID-AGENT-WAVE the session's
# own tool calls keep succeeding while the SUBAGENTS return
# "You have hit your session limit" as their tool RESULT text. The PreToolUse
# hook never fires on a successful call and the statusline cache (frozen at
# session start on this setup) reads low — so the cap can land with NO armed
# resume and NO handover (observed 2026-06-10/11, chunk-3 session).
#
# This hook closes that gap: it fires AFTER every Agent tool call, scans the
# result for the session-limit sentinel strings, and if found triggers the
# same arm + one-shot-block path as auto-arm-on-cap.sh.
#
# Detection sentinels (case-insensitive, substring match on raw result text):
#   "You have hit your session limit"    — primary subagent cap string
#   "usage limit reached"                — alternate Claude cap phrasing
# Deliberately NO broader "claude usage limit" variant: a research subagent
# whose legitimate result text merely DISCUSSES Claude usage limits must not
# trip a spurious one-shot block + arm (verification CR on PR #452).
#
# Input: PostToolUse JSON on stdin:
#   { "session_id": "...", "tool_name": "Agent",
#     "tool_input": {...}, "tool_response": { "type": "tool_result",
#       "content": "You have hit your session limit ..." } }
# The tool_response.content may be a string or an array; both are scanned.
#
# Output / exit semantics (same WATCHDOG contract as auto-arm-on-cap.sh):
#   - exit 0 → allow / no action (disabled, wrong tool, no sentinel, already
#               fired this session, arm succeeded).
#   - exit 1 → allow; stderr surfaces. Watchdog MALFUNCTION (missing arm bin,
#               snapshot unwritable everywhere, py-armor missing, arm failed).
#   - exit 2 → block this one tool call; stderr fed to the model. Cap detected
#               — resume armed (or already armed); write a handover NOW. One-
#               shot per session to avoid blocking every remaining subagent.
#
# Env knobs (all optional):
#   AUTO_ARM_DISABLE=1           kill switch (shared with auto-arm-on-cap.sh)
#   AUTO_ARM_SUBAGENT_DISABLE=1  extra kill switch for this hook only
#   AUTO_ARM_STATE_DIR           throttle/fired marker dir (default /tmp/claude)
#   AUTO_ARM_BIN                 arm-resume.sh override (tests stub this)
#   CLAUDE_PROJECT_DIR           project root (library lookup + git state)
set -euo pipefail

warn() { echo "auto-arm-on-subagent-cap: $*" >&2; }

[ "${AUTO_ARM_DISABLE:-0}" = "1" ] && exit 0
[ "${AUTO_ARM_SUBAGENT_DISABLE:-0}" = "1" ] && exit 0

hook_dir=$(cd "$(dirname "$0")" && pwd)
project_dir="${CLAUDE_PROJECT_DIR:-}"

# py-armor: same lib as auto-arm-on-cap.sh (python3 hang armor, HIMMEL-249).
# A missing lib is a watchdog MALFUNCTION (exit 1, non-blocking) per contract.
_py_lib="$hook_dir/../lib/py-armor.sh"
[ -f "$_py_lib" ] || _py_lib="$project_dir/scripts/lib/py-armor.sh"
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! . "$_py_lib" 2>/dev/null; then
    warn "MALFUNCTION: cannot source py-armor.sh (tried $hook_dir/../lib and \$CLAUDE_PROJECT_DIR/scripts/lib)"
    exit 1
fi

STATE_DIR="${AUTO_ARM_STATE_DIR:-/tmp/claude}"
ARM_BIN="${AUTO_ARM_BIN:-$hook_dir/../handover/arm-resume.sh}"

# ─── read the full PostToolUse payload ─────────────────────────────────────
# Bounded read: the harness sends one JSON line and closes stdin. The hook
# must not hang on an open stdin (manual invocation, test stub). py_armor
# enforces a timeout on the python parse so even a pathological input cannot
# hang the tool-call loop.
payload=""
IFS= read -t 5 -r payload 2>/dev/null || true
[ -z "$payload" ] && exit 0   # no payload — quiet pass (not a hook invocation)

# ─── extract tool_name + tool_response content via python ──────────────────
# Output schema: "AGENT_RESULT\t<sid>\t<content>" or "NOT_AGENT" or "SKIP".
# Uses the established py_armor temp-file pattern (same as auto-arm-on-cap.sh
# lines 483-484) to avoid TWO hang sources:
#   1. Orphan-pipe: a shell pipeline keeps the shell waiting for all procs;
#      if the Windows Store stub spawns an orphan that inherits the pipe
#      read-end, the write side blocks when the payload fills the 64 KB pipe
#      buffer (Agent results can be large). File redirect avoids this.
#   2. $() substitution: the orphan keeps the pipe open; $() waits on EOF.
#      This hook uses file output + head -1, never $() — same contract.
# Payload is written to a per-PID temp file so concurrent hook invocations
# don't collide; both files are deleted right after use.
mkdir -p "$STATE_DIR" 2>/dev/null || { warn "MALFUNCTION: cannot create state dir $STATE_DIR"; exit 1; }
parse_out="$STATE_DIR/auto-arm-sub-parse.$$"
payload_tmp="$STATE_DIR/auto-arm-sub-payload.$$"
printf '%s\n' "$payload" > "$payload_tmp" 2>/dev/null || true
set +e
py_armor - "$payload_tmp" <<'PY' >"$parse_out" 2>/dev/null
import json, sys
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    print("SKIP")
    sys.exit(0)
if not isinstance(data, dict):
    print("SKIP")
    sys.exit(0)
tool = (data.get("tool_name") or "").strip()
if tool != "Agent":
    print("NOT_AGENT")
    sys.exit(0)
resp = data.get("tool_response") or {}
# tool_response may be {"type":"tool_result","content":"..."} or
# {"type":"tool_result","content":[...]} or the response object itself.
content = resp.get("content") if isinstance(resp, dict) else resp
if content is None:
    # Try top-level output field used in some hook versions
    content = data.get("output") or ""
if isinstance(content, list):
    parts = []
    for item in content:
        if isinstance(item, dict):
            parts.append(item.get("text") or item.get("content") or "")
        elif isinstance(item, str):
            parts.append(item)
    content = "\n".join(str(p) for p in parts)
if not isinstance(content, str):
    content = str(content)
# Strip tabs from sid: a malformed session_id with a tab would corrupt the
# tab-delimited output format and break the fired_marker key, causing the
# one-shot dedup to fail (second sentinel → second block instead of pass).
sid = (data.get("session_id") or "nosession").strip().replace("\t", "")[:12]
if not sid:
    sid = "nosession"
# tab-delimit: AGENT_RESULT<TAB>sid<TAB>content
# Strip tabs from content too (safe: sentinel patterns never contain tabs).
print("AGENT_RESULT\t" + sid + "\t" + content.replace("\n", " ").replace("\r", " ").replace("\t", " "))
PY
parse_rc=$?
set -e
parse_line=$(head -1 "$parse_out" 2>/dev/null || echo "")
rm -f "$parse_out" "$payload_tmp" 2>/dev/null || true

if [ "$parse_rc" -ne 0 ] || [ -z "$parse_line" ]; then
    # Python crashed or produced no output — quiet no-op (fail-open).
    exit 0
fi

case "$parse_line" in
    NOT_AGENT|SKIP) exit 0 ;;
    AGENT_RESULT*) ;;
    *) exit 0 ;;
esac

sid=$(printf '%s' "$parse_line" | cut -f2)
result_text=$(printf '%s' "$parse_line" | cut -f3-)

[ -z "$sid" ] && sid="nosession"

# ─── sentinel scan (fast path — pure shell, no python) ─────────────────────
# Sentinel strings that indicate the cap was hit inside a subagent.
#
# FALSE-POSITIVE GUARD (HIMMEL-294): a subagent reviewing this hook's own
# docs may QUOTE the sentinel strings in double quotes or backticks. Those
# are not real cap hits. Strip backtick-quoted spans and double-quoted spans
# from the text BEFORE matching so quoted sentinels don't trip the watchdog.
# sed is bash-3.2-safe and available everywhere the rest of this hook runs.
cap_detected=0
lowered=$(printf '%s' "$result_text" | tr '[:upper:]' '[:lower:]')
# shellcheck disable=SC2016  # literal sed patterns — no expansion wanted
stripped=$(printf '%s' "$lowered" | sed 's/`[^`]*`//g; s/"[^"]*"//g') || stripped="$lowered"
case "$stripped" in
    *"you have hit your session limit"*) cap_detected=1 ;;
    *"usage limit reached"*) cap_detected=1 ;;
esac
[ "$cap_detected" = "0" ] && exit 0

# ─── cap detected — one-shot guard per session ─────────────────────────────
# Key by session_id only (not a cap window — we have no window info here).
# "sub" prefix distinguishes from the PreToolUse hook's markers.
fired_key=$(printf 'sub-%s' "$sid" | tr -c 'A-Za-z0-9._-' '-')
fired_marker="$STATE_DIR/auto-arm-fired-$fired_key"
[ -f "$fired_marker" ] && exit 0   # already blocked this session

# ─── git state for the snapshot ────────────────────────────────────────────
cwd_repo=""
branch=""
dirty=""
if [ -n "$project_dir" ]; then
    cwd_repo=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null || echo "$project_dir")
    branch=$(git -C "$project_dir" branch --show-current 2>/dev/null || echo "")
    dirty=$(git -C "$project_dir" status --short 2>/dev/null | head -20 || echo "")
fi

# ─── snapshot dir (same resolver as auto-arm-on-cap.sh) ────────────────────
resolve_snapshot_dir() {
    local dir="" lib
    lib="$hook_dir/../lib/handover-path.sh"
    [ -f "$lib" ] || lib="$project_dir/scripts/lib/handover-path.sh"
    if [ -f "$lib" ]; then
        # Run handover_root in a subshell that cds to hook_dir first so
        # the Mode A git rev-parse resolves the MAIN REPO root, not the
        # session's cwd (which may be a worktree) — HIMMEL-294.
        set +e
        # shellcheck source=../lib/handover-path.sh
        # shellcheck disable=SC1090,SC1091
        dir=$( (cd "$hook_dir" 2>/dev/null && . "$lib" 2>/dev/null && handover_root 2>/dev/null) ) || dir=""
        set -e
    fi
    [ -n "$dir" ] || dir="$STATE_DIR"
    printf '%s\n' "$dir"
}

snapshot_dir=$(resolve_snapshot_dir)
ts=$(date -u +%Y%m%dT%H%M%SZ)

write_snapshot() {
    {
        echo "---"
        echo "type: handover"
        echo "task: auto-arm subagent-cap snapshot (in-flight subagent hit session limit)"
        echo "created: $ts"
        echo "armed-by: auto-arm-on-subagent-cap hook (HIMMEL-276)"
        [ -n "$cwd_repo" ] && echo "resume_cwd: $cwd_repo"
        echo "---"
        echo
        echo "# Auto-armed resume — subagent hit usage cap mid-wave"
        echo
        echo "The auto-arm-on-subagent-cap hook (HIMMEL-276) detected the session-limit"
        echo "sentinel in an Agent tool result. The main-loop is still responsive but"
        echo "subagents are capped — further Agent dispatches will fail with the same"
        echo "message until the cap resets."
        echo
        echo "## Mechanical state at arm time"
        echo
        echo "- repo: ${cwd_repo:-unknown}"
        echo "- branch: ${branch:-unknown}"
        echo "- dirty files (first 20):"
        if [ -n "$dirty" ]; then
            printf '%s\n' "$dirty" | sed 's/^/    /'
        else
            echo "    (clean or unknown)"
        fi
        echo
        echo "## Resume instructions"
        echo
        echo "1. Run /handover-resume-armed to surface the origin session's transcript + stop point."
        echo "2. Check TaskList / the session's task tracking for in-flight work."
        echo "3. Check git status across .claude/worktrees/ for uncommitted work."
        echo "4. A richer operator-facing handover may exist next to this file"
        echo "   (the origin session was told to write one when this fired)."
    } > "$1" 2>/dev/null
}

snapshot="$snapshot_dir/auto-arm-status-$fired_key.md"
if ! write_snapshot "$snapshot"; then
    snapshot="$STATE_DIR/auto-arm-status-$fired_key.md"
    if ! write_snapshot "$snapshot"; then
        _tmp_snap_dir=""
        if _tmp_snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/auto-arm-sub-snap-XXXXXX" 2>/dev/null); then
            snapshot="$_tmp_snap_dir/auto-arm-status-$fired_key.md"
        fi
        if [ -z "$_tmp_snap_dir" ] || ! write_snapshot "$snapshot"; then
            warn "MALFUNCTION: cannot write status snapshot anywhere ($snapshot_dir, $STATE_DIR, or tmpdir)"
            exit 1
        fi
    fi
fi

# ─── arm the resume ─────────────────────────────────────────────────────────
if [ ! -f "$ARM_BIN" ]; then
    warn "MALFUNCTION: arm-resume not found at $ARM_BIN; snapshot written to $snapshot but NOT armed"
    exit 1
fi
set +e
# --dedup-any (HIMMEL-340): a subagent-cap is a machine-wide event — this
# safety arm must defer to ANY queued resume so it never fans out duplicate
# relaunches alongside the PreToolUse watchdog or a sibling session.
arm_out=$(bash "$ARM_BIN" --dedup-any --time smart --handover "$snapshot" 2>&1)
arm_rc=$?
set -e

case "$arm_rc" in
    0|3)
        # 0 = armed; 3 = a HIMMEL-Resume job already exists — goal met.
        touch "$fired_marker" 2>/dev/null || true
        armed_word="RESUME ARMED (--time smart)"
        [ "$arm_rc" = "3" ] && armed_word="a resume is ALREADY armed (dedup)"
        {
            echo "auto-arm-on-subagent-cap: in-flight subagent returned session-limit sentinel — ${armed_word}."
            echo "Status snapshot: $snapshot"
            echo "ACTION REQUIRED: write a full handover NOW (it will be picked up on resume),"
            echo "finish or park the in-flight step, then wind down. This block fires once;"
            echo "your next tool call will proceed."
        } >&2
        exit 2
        ;;
    *)
        warn "MALFUNCTION: arm-resume.sh failed (rc=$arm_rc); snapshot at $snapshot. Output: $arm_out"
        exit 1
        ;;
esac
