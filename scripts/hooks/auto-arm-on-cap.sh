#!/usr/bin/env bash
# auto-arm-on-cap.sh — PreToolUse hook: auto-arm a resume when the usage
# bank nears the cap (HIMMEL-220, the detect half of HIMMEL-122).
#
# ROOT CAUSE this kills: a session hits the usage cap mid-run with NO
# armed resume and NO status handover written — the operator wakes up to
# a cold, stateless restart. Prose ("remember to arm before cap") does
# not enforce (HIMMEL-195); this hook does, structurally:
#
#   1. Every PreToolUse, throttled to one real check per
#      $AUTO_ARM_CHECK_INTERVAL (default 60s; the throttle costs one
#      stat() on the fast path).
#   2. Reads the claude-statusline usage cache (same source
#      resume-slot.sh / cap-reset-time.sh consume). MISSING cache →
#      quiet no-op (maybe no statusline is installed at all). STALE
#      cache → quiet no-op too, but NOT indefinitely (HIMMEL-275): the
#      hook firing proves the session is LIVE, so a cache frozen past
#      $AUTO_ARM_STALE_ESCALATE_AGE across >= $AUTO_ARM_STALE_MIN_CHECKS
#      consecutive real checks means the statusline writer is not
#      refreshing and usage is INVISIBLE — the cap can land with no
#      armed resume (observed 2026-06-10/11). NOTE: on this setup that
#      is the NORM, not a freak malfunction — the statusline's
#      stdin-rates path never rewrites the cache during a live session,
#      so the cache freezes at session start and EVERY long session
#      crosses this bound; expect routine escalations until the
#      upstream statusline fix lands (HIMMEL-275). The escalation fires
#      ONCE per frozen-cache mtime PER SESSION (each concurrent or
#      subsequent live session gets its own one-shot wind-down block;
#      the ARM itself stays globally deduped via arm-resume rc=3):
#      one-shot exit-2 block + SAFETY ARM at the stale cache's
#      five_hour resets_at when still in the future (a stale slot beats
#      no arm), else now+5h. The explicit HH:MM matters: --time smart
#      reads the SAME wedged cache and fail-closes on age>3600s, so
#      detect and recover would die together (the 2026-06-10 chain).
#   3. When ANY window's utilization >= $AUTO_ARM_THRESHOLD (default 90):
#      a. writes a mechanical status snapshot into the handover root
#         (resolved via scripts/lib/handover-path.sh; falls back to the
#         state dir if the root is unresolvable OR unwritable — the arm
#         matters more than the snapshot's address),
#      b. invokes arm-resume.sh --time smart --handover <snapshot>
#         (usage-aware slot: ASAP if headroom returns, else the binding
#         window's reset — resume-slot.sh owns that logic),
#      c. BLOCKS the current tool call ONCE (exit 2) so the model is
#         told loudly: resume is armed, write a full handover NOW and
#         wind down. The fired marker is keyed per cap window AND per
#         session, so every concurrent session gets its own one-shot
#         block while arm-resume's HIMMEL-Resume-* dedup keeps the
#         scheduler at one job.
#   4. arm-resume rc=3 (a HIMMEL-Resume-* job already exists) counts as
#      success — the goal (a queued resume) is already met. Any other
#      arm failure surfaces (exit 1 — non-blocking, stderr shown) and
#      retries next interval; after $AUTO_ARM_MAX_ARM_FAILURES
#      consecutive failures it escalates to the one-shot exit-2 block
#      anyway, telling the model the safety net is torn and to arm
#      manually. The snapshot is keyed per window+session and
#      overwritten in place on retries — no per-interval file spam.
#
# Boundary vs the HIMMEL-207 supervisor: the supervisor parks the OWNER
# (telegram bridge) relaunch at cap reset. This hook arms a WORK-session
# resume. Both funnel through arm-resume.sh's HIMMEL-Resume-* dedup, so
# they cannot double-book the scheduler.
#
# Input: PreToolUse JSON on stdin. Read ONLY on the trip path (for
# session_id); the fast path leaves stdin untouched.
#
# Output / exit semantics (NON-STANDARD for this directory — this is a
# WATCHDOG, not a guard; see scripts/hooks/CLAUDE.md "fail-closed"
# convention, which this hook deliberately inverts):
#   - exit 0 → allow; quiet. Absence-of-signal paths ONLY (disabled,
#              throttled, no/unreadable cache, stale cache below the
#              escalation bound, below threshold, already fired this
#              window / already escalated this wedge by THIS session).
#   - exit 1 → allow; stderr surfaces to the user. Watchdog-MALFUNCTION
#              paths (cannot write state, python3 missing/crashed,
#              snapshot unwritable everywhere, arm-resume missing or
#              failing). A broken watchdog must be seen, not whisper
#              into a discarded stream. Also the nosession dedup skip:
#              with no session_id every session shares ONE escalated
#              marker, so "already escalated" may be suppressing a
#              sibling's wind-down notice — that skip stays visible.
#   - exit 2 → block this one tool call; stderr fed to the model
#              (resume armed / already armed / arm UNFIXABLE — write a
#              handover now). One-shot per session, keyed by cap window
#              (threshold trip) or wedge mtime (stale escalation).
#
# Env knobs (all optional):
#   AUTO_ARM_DISABLE=1          kill switch (set in the launching shell)
#   AUTO_ARM_THRESHOLD          utilization % that trips the arm (default 90)
#   AUTO_ARM_CACHE              usage-cache path override
#   AUTO_ARM_STATE_DIR          throttle/fired marker dir (default /tmp/claude)
#   AUTO_ARM_CHECK_INTERVAL     seconds between real checks (default 60)
#   AUTO_ARM_MAX_CACHE_AGE      max cache age seconds (default 300)
#   AUTO_ARM_MAX_ARM_FAILURES   consecutive arm failures before the
#                               escalation block (default 3)
#   AUTO_ARM_STALE_ESCALATE_AGE cache age (s) past which staleness stops
#                               being a quiet no-op (default 1800)
#   AUTO_ARM_STALE_MIN_CHECKS   consecutive stale real checks before the
#                               safety arm fires (default 3)
#   AUTO_ARM_BIN                arm-resume.sh override (tests stub this)
set -euo pipefail

warn() { echo "auto-arm-on-cap: $*" >&2; }

[ "${AUTO_ARM_DISABLE:-0}" = "1" ] && exit 0

hook_dir=$(cd "$(dirname "$0")" && pwd)
project_dir="${CLAUDE_PROJECT_DIR:-}"

# python3 hang armor (HIMMEL-249) — extracted from this hook's original
# inline _py() into scripts/lib/py-armor.sh so the handover scripts share
# it. Provides py_armor (timeout -k-wrapped python3; caller keeps the
# file-redirect convention for stdout) + py_armor_mtime. A missing lib is
# a watchdog MALFUNCTION (exit 1 — visible, non-blocking) per the exit
# contract above.
_py_lib="$hook_dir/../lib/py-armor.sh"
[ -f "$_py_lib" ] || _py_lib="$project_dir/scripts/lib/py-armor.sh"
# shellcheck source=../lib/py-armor.sh
# shellcheck disable=SC1091
if ! . "$_py_lib" 2>/dev/null; then
    warn "MALFUNCTION: cannot source py-armor.sh (tried $hook_dir/../lib and \$CLAUDE_PROJECT_DIR/scripts/lib)"
    exit 1
fi

THRESHOLD="${AUTO_ARM_THRESHOLD:-90}"
CACHE_PATH="${AUTO_ARM_CACHE:-/tmp/claude/statusline-usage-cache.json}"
STATE_DIR="${AUTO_ARM_STATE_DIR:-/tmp/claude}"
CHECK_INTERVAL="${AUTO_ARM_CHECK_INTERVAL:-60}"
MAX_CACHE_AGE="${AUTO_ARM_MAX_CACHE_AGE:-300}"
MAX_ARM_FAILURES="${AUTO_ARM_MAX_ARM_FAILURES:-3}"
STALE_ESCALATE_AGE="${AUTO_ARM_STALE_ESCALATE_AGE:-1800}"
STALE_MIN_CHECKS="${AUTO_ARM_STALE_MIN_CHECKS:-3}"
ARM_BIN="${AUTO_ARM_BIN:-$hook_dir/../handover/arm-resume.sh}"

# Operator-typo guard: non-numeric knobs would crash the arithmetic
# below under set -e on every tool call. Sanitize to defaults. The
# threshold also rejects multi-dot strings ("9..5") — those would slip
# past a digits-and-dots filter and silently disable the python check.
case "$THRESHOLD" in ''|*[!0-9.]*|*.*.*) THRESHOLD=90 ;; esac
case "$CHECK_INTERVAL" in ''|*[!0-9]*) CHECK_INTERVAL=60 ;; esac
case "$MAX_CACHE_AGE" in ''|*[!0-9]*) MAX_CACHE_AGE=300 ;; esac
case "$MAX_ARM_FAILURES" in ''|*[!0-9]*) MAX_ARM_FAILURES=3 ;; esac
case "$STALE_ESCALATE_AGE" in ''|*[!0-9]*) STALE_ESCALATE_AGE=1800 ;; esac
case "$STALE_MIN_CHECKS" in ''|*[!0-9]*) STALE_MIN_CHECKS=3 ;; esac

# ─── throttle: one real check per interval ─────────────────────────────
last_check="$STATE_DIR/auto-arm-last-check"
now=$(date +%s)
if [ -f "$last_check" ]; then
    lc_mtime=$(py_armor_mtime "$last_check")
    if [ -n "$lc_mtime" ] && [ $((now - lc_mtime)) -lt "$CHECK_INTERVAL" ]; then
        exit 0
    fi
fi
mkdir -p "$STATE_DIR" 2>/dev/null || { warn "MALFUNCTION: cannot create state dir $STATE_DIR"; exit 1; }
touch "$last_check" 2>/dev/null || true
# Hygiene: expire fired/failcount markers older than 8 days so an
# "unknown resets_at" key can never suppress forever (I3 bound) and
# /tmp/claude doesn't accumulate archaeology. The auto-arm-stale-*
# pattern covers the HIMMEL-275 stale-escalation state too (per-wedge-
# per-session escalated markers, the streak counter, the slot temp
# file) — this sweep is what bounds an escalated marker's suppression
# when a wedged cache never recovers. The per-PID sid temp files
# (auto-arm-sid-out.<pid>) are deleted right after the read; the glob
# catches orphans left by killed processes.
find "$STATE_DIR" -maxdepth 1 \( -name 'auto-arm-fired-*' -o -name 'auto-arm-failcount-*' -o -name 'auto-arm-status-*.md' -o -name 'auto-arm-py-*' -o -name 'auto-arm-sid-out*' -o -name 'auto-arm-stale-*' \) -mtime +8 -delete 2>/dev/null || true

# ─── snapshot helpers (shared by the threshold trip + the HIMMEL-275 ───
# stale-cache escalation; both are rare trip paths, so the work stays lazy)
# Where status snapshots land: the handover root when the resolver lib is
# present + functional, else the state dir (the arm matters more than the
# snapshot's address — I5).
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

# Mechanical git state for snapshot bodies (sets globals: cwd_repo,
# branch, dirty).
collect_git_state() {
    cwd_repo=""
    branch=""
    dirty=""
    if [ -n "$project_dir" ]; then
        cwd_repo=$(git -C "$project_dir" rev-parse --show-toplevel 2>/dev/null || echo "$project_dir")
        branch=$(git -C "$project_dir" branch --show-current 2>/dev/null || echo "")
        dirty=$(git -C "$project_dir" status --short 2>/dev/null | head -20 || echo "")
    fi
}

# Session identity (shared by the threshold trip + the stale escalation;
# lazy — trip paths only, the fast path never touches stdin). Reads the
# PreToolUse JSON to key one-shot markers per session — every concurrent
# session deserves its own wind-down notice; the scheduler job itself is
# still deduped by arm-resume. BOUNDED read (the harness sends one JSON
# line and closes; a manual invocation with an open stdin must not hang
# the trip path — same hang class as the python stub). Degrading to
# "nosession" collapses concurrent sessions onto one marker key (only
# the first gets the wind-down notice), so it warns rather than
# degrading silently — and the stale path's marker-exists skip turns
# VISIBLE (exit 1) on a nosession key, because exit-0 stderr is
# discarded by the harness (see the dedup skip below). The sid temp
# file is per-PID ($$) and deleted after the read: a fixed shared path
# would let a concurrent session's py_armor overwrite it between this
# process's write and its head -1 read, keying this session's marker
# as <mtime>-<other-sid> — the other session's own escalation then
# finds its marker already present and exits 0 silently, the exact
# cross-session suppression per-session keying exists to kill.
# Consumes stdin — call at most once per invocation. Sets the global
# $sid.
read_session_id() {
    local payload sid_out
    payload=""
    IFS= read -t 5 -r payload 2>/dev/null || true
    sid_out="$STATE_DIR/auto-arm-sid-out.$$"
    set +e
    printf '%s' "$payload" | py_armor -c 'import json,sys
try: print(json.load(sys.stdin).get("session_id") or "nosession")
except Exception: print("nosession")' >"$sid_out" 2>/dev/null
    set -e
    sid=$(head -1 "$sid_out" 2>/dev/null || echo "")
    rm -f "$sid_out" 2>/dev/null || true
    [ -n "$sid" ] || sid="nosession"
    sid=$(printf '%.12s' "$sid")
    if [ "$sid" = "nosession" ]; then
        warn "no session_id in hook payload — per-session one-shot degrades to first-session-only"
    fi
}

# ─── cache present + fresh? ─────────────────────────────────────────────
# MISSING cache stays a quiet no-op: it can mean no statusline is
# installed at all — there is no wedge to escalate on.
[ -f "$CACHE_PATH" ] || exit 0
cache_mtime=$(py_armor_mtime "$CACHE_PATH")
[ -n "$cache_mtime" ] || exit 0
cache_age=$((now - cache_mtime))
stale_count_file="$STATE_DIR/auto-arm-stale-count"
if [ "$cache_age" -gt "$MAX_CACHE_AGE" ]; then
    # ─── HIMMEL-275: stale cache must not be an INDEFINITE silent no-op ─
    # This hook only runs while a session is making tool calls, so the
    # invocation itself proves the session is LIVE. A cache frozen past
    # STALE_ESCALATE_AGE during a live session means the statusline
    # writer is not refreshing and usage is INVISIBLE: the cap can land
    # with no warning and no armed resume (observed 2026-06-10/11,
    # frozen 8.5h). This is NOT a rare malfunction on this setup — the
    # statusline's stdin-rates path never rewrites the cache during a
    # live session (it freezes at session start), so every long session
    # crosses this bound; expect routine escalations until the upstream
    # statusline fix lands (HIMMEL-275). Short staleness
    # (MAX_CACHE_AGE..STALE_ESCALATE_AGE) keeps the original
    # quiet-no-op grace.
    if [ "$cache_age" -le "$STALE_ESCALATE_AGE" ]; then
        exit 0
    fi
    # One-shot per WEDGE EVENT per SESSION: keyed by the frozen cache's
    # mtime AND the payload's session_id. mtime alone is not enough —
    # the wedge is machine-wide, so a marker keyed only by mtime would
    # let the FIRST session's escalation silence every concurrent
    # sibling AND every subsequent/resumed session under the same wedge
    # for up to 8 days (the hygiene-sweep bound): the original
    # blind-run disease recreated one layer up. Per-session keying
    # gives each live session its own one-shot wind-down block, while
    # the ARM itself stays globally deduped via arm-resume's
    # HIMMEL-Resume-* rc=3 (later sessions' escalations hit rc=3 and
    # just deliver the block). A recovered-then-refrozen cache gets a
    # new mtime → a new escalation. Consuming stdin here is safe: this
    # branch always exits before the threshold path's read below.
    read_session_id
    stale_key=$(printf '%s-%s' "$cache_mtime" "$sid" | tr -c 'A-Za-z0-9._-' '-')
    stale_marker="$STATE_DIR/auto-arm-stale-escalated-$stale_key"
    if [ -f "$stale_marker" ]; then
        # Dedup skip. A per-sid marker exits 0 quietly — the one-shot
        # already did its job for THIS session. But a nosession key is
        # SHARED by every session that degrades (the payload carried no
        # session_id), so this skip may be swallowing a sibling's
        # wind-down notice — and exit-0 stderr is invisible to user and
        # model, so the degrade warn above is never seen on suppressed
        # checks. Exit 1 (visible, non-blocking) instead: the shared
        # notice must be seen, not whispered into a discarded stream.
        if [ "$sid" = "nosession" ]; then
            warn "stale escalation already delivered to another session; session_id unavailable — sharing one wind-down notice"
            exit 1
        fi
        exit 0
    fi
    # Age is the PRIMARY threshold; the consecutive-check count just
    # demands the staleness be OBSERVED across >= STALE_MIN_CHECKS real
    # checks (the throttle spaces those CHECK_INTERVAL apart), so a
    # burst of tool calls — or one freak check against a cache mid-
    # rewrite — cannot escalate alone. The counter resets whenever a
    # fresh cache is seen (below).
    # Shared-state semantics (deliberate): the counter — like the
    # throttle marker above — is GLOBAL across sessions, NOT per-session
    # like the escalated marker. A machine-wide wedge is machine-wide
    # evidence: concurrent sessions' checks all count toward the same
    # streak, so escalation fires FASTER under multi-session load —
    # fine. The flip side: concurrent sessions share ONE throttle, so a
    # busy sibling can starve this session's real checks — also fine,
    # any session's check observes the same machine-wide cache.
    stale_count=$(cat "$stale_count_file" 2>/dev/null || echo 0)
    case "$stale_count" in ''|*[!0-9]*) stale_count=0 ;; esac
    stale_count=$((stale_count + 1))
    if ! printf '%s' "$stale_count" > "$stale_count_file" 2>/dev/null; then
        # Cannot persist the counter → it would sit at 1 forever and the
        # escalation would never fire — the exact silent no-op this path
        # exists to kill. Escalate NOW (same posture as the arm-failure
        # counter below).
        warn "cannot persist stale counter at $stale_count_file — escalating immediately"
        stale_count="$STALE_MIN_CHECKS"
    fi
    [ "$stale_count" -lt "$STALE_MIN_CHECKS" ] && exit 0

    # ─── escalate: SAFETY ARM off the stale data ────────────────────────
    command -v python3 >/dev/null 2>&1 || { warn "MALFUNCTION: python3 missing — stale-cache safety arm impossible"; exit 1; }
    # Safety slot: the stale cache's five_hour resets_at when it is still
    # >2min in the future AND <24h out (arm-resume's HH:MM form can only
    # express today/tomorrow; the 2min floor avoids arming a minute that
    # passes before schtasks/at registers it), else now+5h — one full cap
    # window from now is the conservative "the bank WILL have reset"
    # slot. An explicit HH:MM, NOT --time smart: smart re-reads this same
    # wedged cache and fail-closes on age>3600s, so detect and recover
    # would die together (the 2026-06-10 failure chain). File redirect,
    # never $() — see the threshold check below for the orphan-pipe hang.
    stale_slot_out="$STATE_DIR/auto-arm-stale-slot"
    set +e
    py_armor - "$CACHE_PATH" <<'PY' >"$stale_slot_out" 2>/dev/null
import json, sys, datetime
now = datetime.datetime.now().astimezone()
target = now + datetime.timedelta(hours=5)
source = "now+5h fallback (cached resets_at past/absent)"
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
    raw = (data.get("five_hour") or {}).get("resets_at") if isinstance(data, dict) else None
    if raw:
        dt = datetime.datetime.fromisoformat(str(raw).replace("Z", "+00:00")).astimezone()
        if now + datetime.timedelta(seconds=120) < dt <= now + datetime.timedelta(hours=24):
            target, source = dt, "stale cache resets_at " + str(raw)
except Exception:
    pass
print(target.strftime("%H:%M") + "\t" + source)
PY
    slot_rc=$?
    set -e
    slot_line=$(head -1 "$stale_slot_out" 2>/dev/null || echo "")
    slot_hhmm=$(printf '%s' "$slot_line" | cut -f1)
    slot_source=$(printf '%s' "$slot_line" | cut -f2-)
    if [ "$slot_rc" -ne 0 ] || [ -z "$slot_hhmm" ]; then
        warn "MALFUNCTION: stale-cache slot python crashed (rc=$slot_rc) — cannot compute safety-arm time; retrying next interval"
        exit 1
    fi

    collect_git_state
    snapshot_dir=$(resolve_snapshot_dir)
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    write_stale_snapshot() {
        {
            echo "---"
            echo "type: handover"
            echo "task: auto-arm SAFETY snapshot (statusline wedged, usage invisible)"
            echo "created: $ts"
            echo "armed-by: auto-arm-on-cap hook stale-cache escalation (HIMMEL-275)"
            [ -n "$cwd_repo" ] && echo "resume_cwd: $cwd_repo"
            echo "---"
            echo
            echo "# Safety-armed resume — statusline usage cache wedged"
            echo
            echo "The auto-arm-on-cap hook found the usage cache frozen for ${cache_age}s"
            echo "(escalation bound ${STALE_ESCALATE_AGE}s) across ${stale_count} consecutive"
            echo "live checks. Utilization was INVISIBLE, so a resume was safety-armed at"
            echo "${slot_hhmm} (${slot_source}) without waiting for a threshold crossing."
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
    snapshot="$snapshot_dir/auto-arm-status-stale-$cache_mtime.md"
    if ! write_stale_snapshot "$snapshot"; then
        snapshot="$STATE_DIR/auto-arm-status-stale-$cache_mtime.md"
        if ! write_stale_snapshot "$snapshot"; then
            warn "MALFUNCTION: cannot write safety snapshot anywhere ($snapshot_dir nor $STATE_DIR)"
            exit 1
        fi
    fi

    if [ ! -f "$ARM_BIN" ]; then
        warn "MALFUNCTION: arm-resume not found at $ARM_BIN; safety snapshot written to $snapshot but NOT armed"
        exit 1
    fi
    set +e
    # --dedup-any (HIMMEL-340): this is a machine-wide SAFETY arm, not a
    # per-handover work arm — it must defer to ANY queued resume so a wedged
    # cache across concurrent sessions can never fan out duplicate relaunches.
    arm_out=$(bash "$ARM_BIN" --dedup-any --time "$slot_hhmm" --handover "$snapshot" 2>&1)
    arm_rc=$?
    set -e
    case "$arm_rc" in
        0|3)
            # 0 = armed; 3 = a HIMMEL-Resume job already exists — goal
            # met either way (same dedup contract as the threshold trip).
            armed_word="SAFETY RESUME ARMED at ${slot_hhmm}"
            [ "$arm_rc" = "3" ] && armed_word="a resume is ALREADY armed (dedup)"
            if ! : > "$stale_marker" 2>/dev/null; then
                # One-shot marker unpersistable (e.g. STATE_DIR went
                # read-only — in which case the throttle marker and the
                # counter are failing right alongside it, so EVERY tool
                # call lands here). An exit-2 block now would repeat on
                # every call while claiming "this block fires once" —
                # actively false. The arm itself succeeded/deduped, so
                # degrade to a loud non-blocking warn (exit 1): visible
                # every check, but never a block loop. The counter is
                # left in place on purpose — the next check re-warns
                # instead of going quiet.
                warn "STATUSLINE WEDGED and ${armed_word} (${slot_source}), but the one-shot marker $stale_marker is UNWRITABLE — cannot persist block-dedup state, so the exit-2 block is downgraded to this repeating warning. Snapshot: $snapshot. Write a full handover NOW and wind down."
                exit 1
            fi
            rm -f "$stale_count_file" 2>/dev/null || true
            {
                echo "auto-arm-on-cap: STATUSLINE WEDGED — usage cache frozen for ${cache_age}s (> ${STALE_ESCALATE_AGE}s) across ${stale_count} live checks."
                echo "On this setup that is ROUTINE, not a freak failure: the statusline's stdin-rates path never rewrites the cache mid-session, so it freezes at session start and long sessions land here until the upstream statusline fix (HIMMEL-275)."
                echo "Usage is INVISIBLE: the cap can land with no warning — ${armed_word} (${slot_source})."
                echo "Status snapshot: $snapshot"
                echo "ACTION REQUIRED: write a full handover NOW (it will be picked up on resume),"
                echo "finish or park the in-flight step, then wind down — the bank may already be"
                echo "near the cap. This block fires once per session; your next tool call will proceed."
            } >&2
            exit 2
            ;;
        *)
            # Surfaced, non-blocking; the counter stays >= STALE_MIN_CHECKS
            # and no marker was set, so the next real check (>= one
            # CHECK_INTERVAL away) retries the arm.
            warn "MALFUNCTION: stale-cache safety arm failed (rc=$arm_rc); retrying next interval. Output: $arm_out"
            exit 1
            ;;
    esac
fi
rm -f "$stale_count_file" 2>/dev/null || true  # fresh cache — the stale streak is broken

command -v python3 >/dev/null 2>&1 || { warn "MALFUNCTION: python3 missing — usage check impossible"; exit 1; }

# ─── threshold check (python owns float compare + JSON parse) ──────────
# Emits "TRIP\t<util>\t<window>\t<resets_display>\t<window_key>" or "OK".
# Exit codes: 0 = verdict printed; 2 = cache unusable (quiet no-op);
# anything else = the watchdog's own brain crashed (surface it).
# Schema-drift guard (I2): a cache where NO window carries a parseable
# numeric utilization exits 2 — it must not coerce to 0% and stand down.
# Unknown resets_at (I3): the window key falls back to a time bucket of
# the window's nominal length, so suppression self-expires.
# Output goes to a FILE, never $(...) command substitution: when the
# wedged Store stub spawns an orphan child that inherits the stdout
# handle, timeout kills the stub but the orphan keeps the pipe open and
# $() waits on EOF forever (verified live — `timeout -k` alone was not
# enough). A file redirect never blocks the parent.
py_err="$STATE_DIR/auto-arm-py-err"
py_out="$STATE_DIR/auto-arm-py-out"
set +e
py_armor - "$CACHE_PATH" "$THRESHOLD" <<'PY' >"$py_out" 2>"$py_err"
import json, sys, time

try:
    threshold = float(sys.argv[2])
except Exception:
    sys.exit(3)  # bad threshold = config malfunction, NOT quiet bad-cache
try:
    with open(sys.argv[1]) as f:
        data = json.load(f)
except Exception:
    sys.exit(2)
if not isinstance(data, dict):
    sys.exit(2)

WINDOW_LEN = {"five_hour": 5 * 3600, "seven_day": 7 * 86400}
now = time.time()
best = None
parseable = 0
null_windows = []
for w in ("five_hour", "seven_day"):
    o = data.get(w)
    if not isinstance(o, dict):
        continue
    if "utilization" not in o:
        continue  # schema drift — key absent, not explicitly null
    raw = o["utilization"]
    if raw is None:
        null_windows.append(w)
        sys.stderr.write(f"auto-arm-on-cap: {w.replace('_','-')} utilization is null — treating as UNKNOWN\n")
        continue
    try:
        u = float(raw)
    except (TypeError, ValueError):
        continue
    parseable += 1
    if best is None or u > best[0]:
        resets = o.get("resets_at")
        if resets:
            display, key = resets, resets
        else:
            bucket = int(now // WINDOW_LEN[w])
            display, key = "unknown", f"bucket{bucket}"
        best = (u, w, display, key)
if parseable == 0 and null_windows:
    sys.exit(4)  # fresh cache but all utilization fields null — surface as MALFUNCTION
if parseable == 0 or best is None:
    sys.exit(2)  # schema drift / no usable signal — NOT "0%, all fine"
if best[0] >= threshold:
    print(f"TRIP\t{best[0]:.0f}\t{best[1]}\t{best[2]}\t{best[3]}")
else:
    print("OK")
PY
rc=$?
set -e
verdict=$(head -1 "$py_out" 2>/dev/null || echo "")
if [ "$rc" -eq 2 ]; then
    exit 0  # unusable cache — justified quiet no-op
fi
if [ "$rc" -eq 3 ]; then
    warn "MALFUNCTION: AUTO_ARM_THRESHOLD '$THRESHOLD' is not a number — watchdog cannot evaluate"
    exit 1
fi
if [ "$rc" -eq 4 ]; then
    # Fresh cache but all utilization fields null — statusline PR #2 guard wrote null.
    # An unknown utilization must NOT silently disable the watchdog (parallel to
    # python3-missing MALFUNCTION above: we have a cache but cannot evaluate it).
    warn "MALFUNCTION: all utilization fields are null in a fresh cache — $(head -3 "$py_err" 2>/dev/null || echo 'no detail')"
    exit 1
fi
if [ "$rc" -ne 0 ]; then
    # Includes rc=124/137 — the GNU-timeout cap killing a hung python stub.
    warn "MALFUNCTION: usage-check python crashed (rc=$rc): $(head -3 "$py_err" 2>/dev/null || echo 'no stderr captured')"
    exit 1
fi
# Forward any partial-null warnings the python block wrote (e.g. one window null,
# other parseable) — they land in py_err but would otherwise be silently discarded.
if [ -s "$py_err" ]; then
    cat "$py_err" >&2
fi
case "$verdict" in TRIP*) ;; *) exit 0 ;; esac

util=$(printf '%s' "$verdict" | cut -f2)
window=$(printf '%s' "$verdict" | cut -f3)
resets_display=$(printf '%s' "$verdict" | cut -f4)
window_key=$(printf '%s' "$verdict" | cut -f5)

# ─── session identity (per-session one-shot; code-review I1) ───────────
# Read the PreToolUse JSON now (trip path only) — bounded-read +
# degrade-warn contract documented at read_session_id above. Reached
# only with a FRESH cache (the stale branch exits), so stdin is still
# unconsumed here.
read_session_id

# ─── one-shot guard per cap window per session ──────────────────────────
fired_key=$(printf '%s-%s-%s' "$window" "$window_key" "$sid" | tr -c 'A-Za-z0-9._-' '-')
fired_marker="$STATE_DIR/auto-arm-fired-$fired_key"
[ -f "$fired_marker" ] && exit 0

# Consecutive-arm-failure counter is per cap window (shared across
# sessions — the scheduler is the shared resource that's failing).
window_only_key=$(printf '%s-%s' "$window" "$window_key" | tr -c 'A-Za-z0-9._-' '-')
failcount_file="$STATE_DIR/auto-arm-failcount-$window_only_key"

# ─── write the mechanical status snapshot ───────────────────────────────
# Stable name per window+session: retries overwrite in place (C2 — no
# per-interval spam into the version-controlled handover root).
snapshot_dir=$(resolve_snapshot_dir)
ts=$(date -u +%Y%m%dT%H%M%SZ)
collect_git_state

write_snapshot() {
    {
        echo "---"
        echo "type: handover"
        echo "task: auto-arm cap snapshot (usage ${util}% >= ${THRESHOLD}% on ${window})"
        echo "created: $ts"
        echo "armed-by: auto-arm-on-cap hook (HIMMEL-220)"
        [ -n "$cwd_repo" ] && echo "resume_cwd: $cwd_repo"
        echo "---"
        echo
        echo "# Auto-armed resume — usage cap approached"
        echo
        echo "The auto-arm-on-cap hook detected ${window} utilization at ${util}%"
        echo "(threshold ${THRESHOLD}%) and armed a resume via arm-resume.sh --time smart."
        echo "Window resets at: ${resets_display}."
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
    # Handover root unwritable — the ARM matters more than the snapshot's
    # address (I5). Retry in the state dir before giving up.
    snapshot="$STATE_DIR/auto-arm-status-$fired_key.md"
    if ! write_snapshot "$snapshot"; then
        # Both preferred locations unwritable — one last attempt in a
        # mktemp scratch dir so the arm can still proceed.
        _tmp_snap_dir=""
        if _tmp_snap_dir=$(mktemp -d "${TMPDIR:-/tmp}/auto-arm-snap-XXXXXX" 2>/dev/null); then
            snapshot="$_tmp_snap_dir/auto-arm-status-$fired_key.md"
        fi
        if [ -z "$_tmp_snap_dir" ] || ! write_snapshot "$snapshot"; then
            warn "MALFUNCTION: cannot write status snapshot anywhere ($snapshot_dir, $STATE_DIR, or tmpdir) — session will NOT auto-arm"
            exit 1
        fi
    fi
fi

# ─── arm the resume ─────────────────────────────────────────────────────
if [ ! -f "$ARM_BIN" ]; then
    warn "MALFUNCTION: arm-resume not found at $ARM_BIN; snapshot written to $snapshot but NOT armed"
    exit 1
fi
set +e
# --dedup-any (HIMMEL-340): a machine-wide cap is a machine-wide event — this
# safety arm must defer to ANY queued resume (operator/supervisor/sibling
# session) so concurrent sessions hitting the cap never double-book the
# scheduler. Per-handover multislot is for explicit work arms, not this.
arm_out=$(bash "$ARM_BIN" --dedup-any --time smart --handover "$snapshot" 2>&1)
arm_rc=$?
set -e

case "$arm_rc" in
    0|3)
        # 0 = armed; 3 = a HIMMEL-Resume job already exists — goal met
        # either way (dedup with operator/supervisor arms is by design).
        touch "$fired_marker" 2>/dev/null || true
        rm -f "$failcount_file" 2>/dev/null || true
        armed_word="RESUME ARMED (--time smart)"
        [ "$arm_rc" = "3" ] && armed_word="a resume is ALREADY armed (dedup)"
        {
            echo "auto-arm-on-cap: usage ${util}% >= ${THRESHOLD}% on ${window} — ${armed_word}."
            echo "Status snapshot: $snapshot"
            echo "ACTION REQUIRED: write a full handover NOW (it will be picked up on resume),"
            echo "finish or park the in-flight step, then wind down. This block fires once;"
            echo "your next tool call will proceed."
        } >&2
        exit 2
        ;;
    *)
        # Arm failed. Surface it (exit 1 — non-blocking but visible),
        # count it, and after MAX_ARM_FAILURES consecutive failures
        # escalate to the one-shot block anyway: a watchdog that can see
        # the cliff must still bark when its own legs are broken (C2).
        fails=$(cat "$failcount_file" 2>/dev/null || echo 0)
        case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
        fails=$((fails + 1))
        _counter_unpersistable=0
        if ! printf '%s' "$fails" > "$failcount_file" 2>/dev/null; then
            # Cannot persist the counter → the escalation bound would
            # silently never trigger (fails stuck at 1). Escalate NOW
            # rather than retry invisibly forever.
            warn "cannot persist failcount at $failcount_file — escalating immediately"
            _counter_unpersistable=1
            fails="$MAX_ARM_FAILURES"
        fi
        if [ "$fails" -ge "$MAX_ARM_FAILURES" ]; then
            touch "$fired_marker" 2>/dev/null || true
            # Clear the shared counter: it has served its purpose for
            # this window; without this, sibling sessions escalate on
            # their FIRST observed failure with an inflated count.
            rm -f "$failcount_file" 2>/dev/null || true
            {
                echo "auto-arm-on-cap: usage ${util}% >= ${THRESHOLD}% on ${window} — COULD NOT ARM a resume"
                if [ "$_counter_unpersistable" -eq 1 ]; then
                    echo "(arm-resume.sh failed — counter unpersistable, escalating immediately (single observation), last rc=$arm_rc)."
                else
                    echo "(arm-resume.sh failed $fails consecutive times, last rc=$arm_rc)."
                fi
                echo "Last output: $arm_out"
                echo "ACTION REQUIRED: the auto-arm safety net is TORN. Arm manually"
                echo "(bash scripts/handover/arm-resume.sh --time smart --handover $snapshot),"
                echo "write a full handover NOW, and wind down."
            } >&2
            exit 2
        fi
        warn "MALFUNCTION: arm-resume.sh failed (rc=$arm_rc, consecutive=$fails/$MAX_ARM_FAILURES); retrying next interval. Output: $arm_out"
        exit 1
        ;;
esac
