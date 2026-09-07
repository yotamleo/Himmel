#!/usr/bin/env bash
# scripts/hooks/refresh-statusline-caches-periodic.sh — keep the statusline
# caches warm OFF the render path (HIMMEL-718 Task 3.2).
#
# WHY: the spawn-free hud composer (scripts/statusline/hud-custom-lines.sh) and
# the now cache-only where-are-we segment READ pre-computed caches but never
# rebuild them — the detached in-render rebuilds were the orphaned-bash leak
# class this migration eliminates. This hook is where those two refreshes now
# live. It runs SYNCHRONOUSLY, so nothing it spawns is detached — no orphan can
# outlive it. It feeds BOTH the still-live bash bar and the hud composer.
#
# INVOCATION CADENCE (accurate — Claude Code has no timer/"periodic" hook event):
#   - Wired at SessionStart today (docs/setup/settings-template.json). During the
#     migration interim the legacy bar's own render-time refresh
#     (statusline.sh:870, `& disown`, 30s throttle) keeps the caches warm, so a
#     SessionStart-only refresh here is sufficient.
#   - At the Task 4.1 cutover (statusLine repointed to hud, the legacy bar's
#     render-time refresh removed) this same hook ALSO gets a per-turn
#     UserPromptSubmit trigger for in-session freshness. It is TTL-throttled
#     (below) so a per-turn call is a cheap stat-check no-op until the cache
#     actually ages out — matching OQ2 (per-session, TTL-throttled; NO always-on
#     scheduler). The "periodic" in the filename is this throttled role, not a
#     timer.
#
# Refreshes (each TTL-throttled — skipped when the cache is still fresh):
#   1. the epic rollup cache  (scripts/where-are-we/statusline-rollup.sh)
#   2. the all-sessions economics index (lib/../statusline/lib/all-sessions-index.sh)
#
# FAIL-OPEN: a hook must never block or fail the session (a cache-warmer is not a
# guardrail — cf. auto-arm-on-cap's watchdog exception). Every step is guarded;
# the script always exits 0.
#
# Seams (tests): --cwd <dir> ; HIMMEL_WHERE_ARE_WE_ROLLUP_DIR (rollup cache dir,
#   default /tmp/claude) ; HIMMEL_WHERE_ARE_WE_ROLLUP_CMD (rollup refresh cmd) ;
#   HIMMEL_WHERE_ARE_WE_ROLLUP_TTL (rollup freshness secs, default 900) ;
#   CLAUDE_ALL_SESSIONS_CACHE_DIR (economics cache dir, default /tmp/claude) ;
#   CLAUDE_PROJECTS_DIR (transcript root, default ~/.claude/projects) ;
#   HIMMEL_STATUSLINE_PERIOD (all|week|month, default all) ;
#   HIMMEL_STATUSLINE_REFRESH_TTL (economics freshness secs, default 30).
#
# NOTE: this hook warms ONLY the period it resolves (default all). If an operator
# sets HIMMEL_STATUSLINE_PERIOD=week|month, that var must be visible to BOTH this
# hook's env AND the composer's env, or the composer's non-`all` row reads a
# cache the hook never rebuilt (fails open to a stale/0 row, not garbage).
set -uo pipefail

cwd_override=""
while [ $# -gt 0 ]; do
    case "$1" in
        --cwd) cwd_override="${2:-}"; shift 2 ;;
        *)     shift ;;
    esac
done

SD="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$SD/.." && pwd)"

# Drain stdin (SessionStart JSON) so the caller's pipe never blocks; use its
# .cwd if no --cwd was passed.
input=""
if [ ! -t 0 ]; then input="$(cat 2>/dev/null || true)"; fi

cwd="$cwd_override"
if [ -z "$cwd" ] && [ -n "$input" ]; then
    cwd="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null || true)"
fi
[ -n "$cwd" ] || cwd="$PWD"

now_epoch="$(date +%s)"
# Returns 0 (fresh → skip refresh) when $1 exists and is younger than $2 secs.
# Keeps a per-turn UserPromptSubmit invocation (Task 4.1) a cheap no-op until the
# cache actually ages out.
_cache_fresh() {
    local f="$1" ttl="$2" mt
    [ -f "$f" ] || return 1
    case "$ttl" in ''|*[!0-9]*) return 1 ;; esac
    mt=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "$(( now_epoch - mt ))" -lt "$ttl" ]
}

# ── 1. Epic rollup ──────────────────────────────────────────────────────────
# Derive the ticket KEY from the branch (same branchToKey rule as the segment),
# then refresh that key's rollup synchronously (lock-guarded, no fork).
branch="$(git -C "$cwd" symbolic-ref --short HEAD 2>/dev/null || true)"
key=""
case "$branch" in
    */*)
        rest="${branch#*/}"
        cand="$(printf '%s' "$rest" | sed -n 's/^\([A-Za-z][A-Za-z]*-[0-9][0-9]*\).*/\1/p')"
        [ -n "$cand" ] && key="$(printf '%s' "$cand" | tr '[:lower:]' '[:upper:]')"
        ;;
esac
if [ -n "$key" ]; then
    cachedir="${HIMMEL_WHERE_ARE_WE_ROLLUP_DIR:-/tmp/claude}"
    cache="$cachedir/where-are-we-rollup-$key.json"
    # Reap a stale rollup lock (>300s) BEFORE the presence gate below. Once this
    # hook is the sole rollup refresher (Task 4.1 cutover), a lock leaked by a
    # hard-killed rollup — e.g. the SessionStart `timeout` killing it mid-rebuild
    # — would otherwise wedge the gate forever, since [ ! -d "$cache.lock" ]
    # skips and never re-invokes the subscript's own reaper. Mirrors the
    # economics block's reaper below.
    if [ -d "$cache.lock" ]; then
        rlm=$(stat -c %Y "$cache.lock" 2>/dev/null || stat -f %m "$cache.lock" 2>/dev/null || echo 0)
        if [ "$(( now_epoch - rlm ))" -gt 300 ]; then rmdir "$cache.lock" 2>/dev/null || true; fi
    fi
    if ! _cache_fresh "$cache" "${HIMMEL_WHERE_ARE_WE_ROLLUP_TTL:-900}" \
       && [ ! -d "$cache.lock" ]; then
        mkdir -p "$cachedir" 2>/dev/null || true
        rollup_cmd="${HIMMEL_WHERE_ARE_WE_ROLLUP_CMD:-bash $ROOT/where-are-we/statusline-rollup.sh}"
        # shellcheck disable=SC2086  # rollup_cmd is the intentional "bash <path>" seam word-split
        $rollup_cmd --key "$key" --out "$cache" >/dev/null 2>&1 || true
    fi
fi

# ── 2. All-sessions economics index ─────────────────────────────────────────
# Source the shared rebuild lib and run it synchronously under the same atomic
# mkdir-lock the legacy bar uses (so the two refreshers never collide).
# shellcheck source=scripts/statusline/lib/all-sessions-index.sh disable=SC1091
. "$ROOT/statusline/lib/all-sessions-index.sh" 2>/dev/null || true
if command -v rebuild_all_sessions_index >/dev/null 2>&1 \
   && command -v resolve_window >/dev/null 2>&1; then
    period="${HIMMEL_STATUSLINE_PERIOD:-all}"
    window_id="all-stats"; window_start=0; window_end=9999999999
    resolve_window "$period"
    econ_dir="${CLAUDE_ALL_SESSIONS_CACHE_DIR:-/tmp/claude}"
    proj_root="${CLAUDE_PROJECTS_DIR:-$HOME/.claude/projects}"
    cache_file="$econ_dir/cache-${window_id}.json"
    index_file="$econ_dir/cache-${window_id}-index.json"
    lock="${index_file}.lock"
    mkdir -p "$econ_dir" 2>/dev/null || true
    # Releases the economics lock. The owner-pid marker lives INSIDE the lock
    # dir so `mkdir` stays the atomic acquire and a lock created by the legacy
    # bar (which writes no marker) is still a plain empty dir it can rmdir.
    _econ_release_lock() {
        rm -f "$lock/owner.pid" "$lock/heartbeat" 2>/dev/null || true
        # `rmdir` only removes an EMPTY dir, so any entry this function does not
        # know about — a marker written by a future version, an editor swapfile,
        # a filesystem turd — makes the release silently fail and wedges the
        # refresh for every later session (the reaper below would keep finding a
        # lock it just declined to remove). Fall back to a recursive remove: by
        # the time this runs the lock is either OURS or has been positively
        # confirmed dead, so there is no live owner to pull the rug from under.
        # Narrowly scoped — "$lock" is always "$index_file.lock" under $econ_dir.
        rmdir "$lock" 2>/dev/null || rm -rf "$lock" 2>/dev/null || true
    }
    # Spawn-free lock heartbeat (HIMMEL-1300). Passed to the rebuild via the
    # `command -v _hud_rb_heartbeat` seam in all-sessions-index.sh, which calls
    # it once per transcript. `printf` + redirect are builtins — no touch(1)
    # fork in the per-file hot path. It stamps a SEPARATE file rather than
    # re-writing owner.pid, so a concurrent reaper can never catch the pid
    # marker mid-truncate and mistake this live owner for a marker-less lock.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly, from the sourced
    # lib's `command -v _hud_rb_heartbeat` seam — never called by name here.
    _hud_rb_heartbeat() {
        printf '%s\n' "$$" > "$lock/heartbeat" 2>/dev/null || true
    }
    # Kill-path cleanup: release the lock AND drop the temps this pass left
    # behind — the rebuild's mktemps (registered by the lib in
    # $_HUD_RB_TMPFILES) plus the two `.$$.tmp` staging files the atomic
    # publish uses. The lib is SOURCED, so `$$` is this process and the staging
    # names match (HIMMEL-1300 R3-4).
    _econ_cleanup() {
        rm -f "${index_file}.$$.tmp" "${cache_file}.$$.tmp" 2>/dev/null || true
        command -v _hud_rb_rmtemps >/dev/null 2>&1 && _hud_rb_rmtemps
        _econ_release_lock
    }
    # The SIGNAL path must EXIT; cleaning up is not enough. A bash INT/TERM
    # trap RESUMES the interrupted script once the handler returns — it does
    # not terminate. Demonstrated directly: a script trapping TERM with a
    # cleanup-only handler ran its cleanup on the signal and then continued to
    # the last line. So a cleanup-only signal trap here released the lock and
    # deleted the pass's temps while rebuild_all_sessions_index was STILL
    # running — leaving the checkpoint writer publishing through temps that no
    # longer exist, and (the real damage) leaving the lock free so the next
    # session's refresher could acquire it and write the same cache/index
    # concurrently. That is precisely the double-writer the lock exists to
    # prevent, reached BY the kill that is the normal termination mode here.
    # Exit 0, not 128+signo: hooks in this repo fail CLOSED (a non-zero exit
    # blocks the action), and this one is a cache-warmer whose documented
    # contract is that it never blocks the session. Disarm EXIT first so the
    # cleanup does not run a second time on the way out.
    # shellcheck disable=SC2317,SC2329  # invoked indirectly, via the trap below.
    _econ_signal_exit() {
        _econ_cleanup
        trap - EXIT
        exit 0
    }
  if ! _cache_fresh "$cache_file" "${HIMMEL_STATUSLINE_REFRESH_TTL:-30}"; then
    # Reap a leaked lock. HIMMEL-1300 R3-4: a hook timeout-kill never reaches
    # the release below, and while the index heals a kill is the NORMAL
    # termination mode — so with only the 300s age threshold EVERY overrun
    # leaked the lock and any session started within the next 5 minutes skipped
    # the refresh entirely. The lock now records its owner PID: an owner that is
    # gone means the lock is dead, reap it immediately. The 300s age threshold
    # is KEPT as the fallback — it covers a lock with no pid marker (the legacy
    # bar's own mkdir-lock, so the two refreshers still interoperate) and the
    # pathological PID-reuse case where a dead owner's number is live again.
    if [ -d "$lock" ]; then
        lock_stale=0
        lock_pid=""
        # The -f guard is load-bearing: a failing `<` redirect is reported by
        # the SHELL, so its own `2>/dev/null` cannot suppress the message — and
        # a marker-less legacy-bar lock is the normal case, not an error.
        [ -f "$lock/owner.pid" ] && lock_pid=$(tr -dc '0-9' < "$lock/owner.pid" 2>/dev/null)  # fail-open-ok: an unreadable pid marker reads as no marker — the lock is judged by heartbeat/mtime and never reaped on a read failure (fail-safe; see comment above)
        if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
            lock_stale=1
        else
            # Either no pid marker (a legacy-bar lock) or a LIVE pid. The age
            # test alone was wrong for the live case: a genuine owner grinding
            # through a slow rebuild crosses 300s and was reaped out from under
            # itself, so a second refresher then ran concurrently on the same
            # cache files. A live owner now re-stamps $lock/heartbeat once per
            # transcript, so measure THAT when it exists — a fresh heartbeat
            # proves the owner is still working, while an alive-but-silent pid
            # is a recycled PID number sitting on a dead lock and still ages
            # out. The lock dir's own mtime stays the fallback: it covers the
            # marker-less legacy lock and an owner killed before its first
            # heartbeat.
            lock_ref="$lock"
            [ -f "$lock/heartbeat" ] && lock_ref="$lock/heartbeat"
            lock_mtime=$(stat -c %Y "$lock_ref" 2>/dev/null || stat -f %m "$lock_ref" 2>/dev/null || echo 0)
            [ "$(( $(date +%s) - lock_mtime ))" -gt 300 ] && lock_stale=1
        fi
        if [ "$lock_stale" -eq 1 ]; then
            # Own-or-lose reap (HIMMEL-1327). The old `[ stale ] && _econ_release_lock`
            # raced a concurrent refresher: two hooks that both classified the same
            # lock stale would both release it; A then mkdir'd a FRESH lock, but B
            # (still holding its stale verdict) ran its own release and deleted A's
            # LIVE lock, and B's mkdir succeeded too — two refreshers rebuilding the
            # same cache files at once. This hook is PERIODIC and fires from every
            # session, so concurrent invocation is the normal case, not an edge.
            #
            # (1) Re-validate the owner BEFORE reaping. The verdict above is against
            # the lock as it was when classified; a concurrent refresher may have
            # since reaped it and acquired a FRESH lock (a LIVE owner.pid, or a
            # just-created dir). Reaping THAT pulls the rug from a live owner and
            # reopens the double-writer, so a now-live owner — or a now-fresh lock —
            # aborts the reap, and the mkdir below then loses to that lock instead.
            # The check mirrors the classification above so the two can never
            # disagree on the same state (a recycled pid with a stale heartbeat
            # still ages out; a live owner with a fresh heartbeat still survives).
            reap_pid=""
            [ -f "$lock/owner.pid" ] && reap_pid=$(tr -dc '0-9' < "$lock/owner.pid" 2>/dev/null)
            reap_ok=0
            if [ -n "$reap_pid" ] && ! kill -0 "$reap_pid" 2>/dev/null; then
                reap_ok=1
            else
                # A LIVE pid falls through here too, exactly as the
                # classification does: an alive-but-silent pid is a recycled
                # PID number sitting on a dead lock and must still age out.
                # Gating the age fallback behind "no pid" instead would let a
                # recycled PID pin a dead lock forever.
                reap_ref="$lock"
                [ -f "$lock/heartbeat" ] && reap_ref="$lock/heartbeat"
                reap_mtime=$(stat -c %Y "$reap_ref" 2>/dev/null || stat -f %m "$reap_ref" 2>/dev/null || echo 0)
                [ "$(( $(date +%s) - reap_mtime ))" -gt 300 ] && reap_ok=1
            fi
            # (2) Rename-first. Only the refresher whose mv wins performs the
            # removal, so a concurrent reaper that lost the rename finds nothing to
            # move, removes nothing, and its mkdir then loses to the winner's fresh
            # lock. The copy it removes is its own private `.dead.$$` sibling, so it
            # can never touch another owner's live lock. (Plain `rm -rf "$lock"`
            # shared the reap target with every concurrent reaper; a private rename
            # does not.)
            if [ "$reap_ok" -eq 1 ] && mv "$lock" "$lock.dead.$$" 2>/dev/null; then
                rm -rf "$lock.dead.$$" 2>/dev/null || true
            fi
        fi
    fi
    if mkdir "$lock" 2>/dev/null; then
        printf '%s\n' "$$" > "$lock/owner.pid" 2>/dev/null || true
        # SIGKILL cannot be trapped — that path is covered by the dead-owner
        # reap above; these traps cover SIGTERM/SIGINT and any early exit.
        # INT/TERM route through _econ_signal_exit (which EXITS) rather than
        # sharing the EXIT handler — see that function for why a cleanup-only
        # signal trap kept the rebuild running past its own lock release.
        trap '_econ_cleanup' EXIT
        trap '_econ_signal_exit' INT TERM
        if [ "$window_id" = "all-stats" ]; then
            rebuild_all_sessions_index "$proj_root" "$cache_file" "$index_file"
        else
            rebuild_all_sessions_index "$proj_root" "$cache_file" "$index_file" "$window_start" "$window_end"
        fi
        trap - EXIT INT TERM
        _econ_cleanup
    fi
  fi
fi

exit 0
