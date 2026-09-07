#!/usr/bin/env bash
# reconcile-workers.sh -- reconcile offload-lane worker metadata after an
# unclean dispatcher/session exit (HIMMEL-1463).
#
# A worker wrapper normally moves meta.json from status=running to a terminal
# state. If the dispatching Claude session exits first, the wrapper and worker
# can die together, leaving a false running row and (in shared-branch mode) a
# stale writer lock. This helper marks only running rows whose recorded pid is
# confirmed dead and whose metadata is older than the terminal-write grace
# window as orphaned, preserving every other metadata field via an atomic JSON
# rewrite. An unprobeable or still-settling row stays running and keeps its lock.
# A shared lock is removed only when its own recorded holder pid is confirmed dead.
#
# Usage:
#   bash scripts/handover/reconcile-workers.sh
#   bash scripts/handover/reconcile-workers.sh --list-live
#
# Env:
#   WORKER_BRIDGE_ROOT   Bridge root override (default: BRIDGE_ROOT, then
#                        ~/.claude/handover/bridge).
#   WORKER_PID_ALIVE_CMD Test seam: executable invoked as <cmd> <pid>; rc 0
#                        means live, rc 1 confirmed dead, every other rc
#                        unprobeable. Production probes both MSYS and native
#                        Windows pid namespaces.
#   RECONCILE_GRACE_SECS Minimum meta.json age before a confirmed-dead worker
#                        may be orphaned (default: 120).
#   RECONCILE_UNPROBEABLE_CEILING_SECS Absolute backstop (default: 172800 =
#                        48h) for rows whose pid was never written (the
#                        writeLiveWorkerMeta fallback marker shape, HIMMEL-
#                        1511): once the session directory is older than
#                        this ceiling, the row is terminal-marked even
#                        though liveness stays unprobeable. Deliberately far
#                        larger than RECONCILE_GRACE_SECS -- a backstop, not
#                        a grace replacement.
#   RECONCILE_TEST_NOW_MS Test seam: epoch-ms override for "now" in the
#                        ceiling check, so an exact-boundary case can be
#                        tested without racing the wall clock (real elapsed
#                        time between an mtime write and the check always
#                        makes the observed age strictly greater than any
#                        nominal ceiling, which can never expose a `>` vs
#                        `>=` off-by-one). Unset in production.
#
# Exit: 0 success/nothing to do; 2 malformed metadata or reconciliation error.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRIDGE="${WORKER_BRIDGE_ROOT:-${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}}"
MODE="${1:-reconcile}"
RECONCILE_GRACE_SECS="${RECONCILE_GRACE_SECS:-120}"
RECONCILE_UNPROBEABLE_CEILING_SECS="${RECONCILE_UNPROBEABLE_CEILING_SECS:-172800}"

case "$MODE" in
    reconcile|--list-live) : ;;
    -h|--help)
        echo "usage: reconcile-workers.sh [--list-live]"
        exit 0
        ;;
    *)
        echo "ERR reconcile-workers: unknown arg: $MODE" >&2
        exit 2
        ;;
esac

case "$RECONCILE_GRACE_SECS" in
    ''|*[!0-9]*)
        echo "ERR reconcile-workers: RECONCILE_GRACE_SECS must be a non-negative integer" >&2
        exit 2
        ;;
esac

case "$RECONCILE_UNPROBEABLE_CEILING_SECS" in
    ''|*[!0-9]*)
        echo "ERR reconcile-workers: RECONCILE_UNPROBEABLE_CEILING_SECS must be a non-negative integer" >&2
        exit 2
        ;;
esac

# worker_pid_alive <pid> -- rc 0 live, rc 1 confirmed dead, rc 2 unprobeable.
# Bun reports native Windows pids; the shared-lock shell historically recorded
# an MSYS pid. Checking both errs safely toward live if a number happens to exist
# in both namespaces. Missing/failed census data must never authorize cleanup.
worker_pid_alive() {
    local pid="$1" out rc
    case "$pid" in
        ''|*[!0-9]*|0) return 2 ;;
    esac

    if [ -n "${WORKER_PID_ALIVE_CMD:-}" ]; then
        "$WORKER_PID_ALIVE_CMD" "$pid"
        rc=$?
        case "$rc" in
            0|1) return "$rc" ;;
            *)
                echo "WARN reconcile-workers: worker PID probe command failed for PID $pid (rc=$rc); liveness is unprobeable" >&2
                return 2
                ;;
        esac
    fi

    if kill -0 "$pid" 2>/dev/null; then
        return 0
    fi

    case "${OSTYPE:-$(uname -s 2>/dev/null || echo unknown)}" in
        msys*|cygwin*|win32*|MINGW*)
            if ! command -v tasklist >/dev/null 2>&1; then
                echo "WARN reconcile-workers: tasklist unavailable for native PID $pid; liveness is unprobeable" >&2
                return 2
            fi
            out=$(MSYS_NO_PATHCONV=1 tasklist /FO CSV /NH /FI "PID eq $pid" 2>&1)
            rc=$?
            if [ "$rc" -eq 0 ]; then
                case "$out" in
                    *\"$pid\"*) return 0 ;;
                    *) return 1 ;;
                esac
            fi
            echo "WARN reconcile-workers: tasklist failed for PID $pid (rc=$rc); liveness is unprobeable" >&2
            return 2
            ;;
    esac
    return 1
}

# _worker_census -- HIMMEL-2066 batch replacement for the old per-file
# _worker_meta_fields: ONE node process for the whole census run instead of
# one `node -e` spawn per meta.json. ~0.5s node startup x hundreds of
# meta.json files under Windows/Git-Bash ate the ASAP arm lead and tripped
# the caller's timeout.
#
# Reads newline-delimited "origPath\x1fopenPath" pairs on stdin (always
# $BRIDGE/<lane>-sessions/<session>/meta.json -- no newlines in practice) and
# writes one row per PARSEABLE file to stdout:
# "origPath\x1fstatus\x1fpid\x1fshared_branch\x1frepo_dir\x1flane\x1ftask_name\n"
# -- same unit-separator convention as before (survives bash 3.2's `read`
# with empty fields). A file that fails to parse writes
# "ERR reconcile-workers: cannot parse <origPath>: <msg>" to stderr and NO
# stdout row, but every other path still gets processed; the process exits 2
# at the very end iff anything failed to parse, mirroring the old per-file
# FAILED=1-but-keep-going contract.
#
# openPath (not origPath) is what actually gets fs.readFileSync'd: node.exe
# is a native Windows binary, and MSYS/Git-Bash only rewrites POSIX-looking
# ARGV elements into Windows form for a native child automatically -- it
# does not touch data piped through stdin. The old per-file call passed its
# one path as an argv element and got that translation for free; the caller
# below does the equivalent translation itself (via cygpath, batched once)
# before piping. origPath -- the untranslated bash-native path -- is what
# gets reported back in each row, so every downstream consumer (the other
# per-candidate node helpers below, --list-live output, callers' own path
# matching) keeps seeing the same path shape as before this change.
_worker_census() {
    # shellcheck disable=SC2016  # JavaScript template literals, not shell expansion.
    node -e '
const fs = require("fs");
const readline = require("readline");
let failed = false;
const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
rl.on("line", (line) => {
    if (line === "") return;
    const sep = line.indexOf("\x1f");
    const origPath = sep === -1 ? line : line.slice(0, sep);
    const openPath = sep === -1 ? line : line.slice(sep + 1);
    let o;
    try { o = JSON.parse(fs.readFileSync(openPath, "utf8")); }
    catch (e) {
        console.error(`ERR reconcile-workers: cannot parse ${origPath}: ${e.message}`);
        failed = true;
        return;
    }
    const vals = [o.status, o.pid, o.shared_branch, o.repo_dir, o.lane, o.task_name];
    process.stdout.write(origPath + "\x1f" + vals.map(v => v == null ? "" : String(v)).join("\x1f") + "\n");
});
rl.on("close", () => { process.exit(failed ? 2 : 0); });
'
}

# _worker_meta_is_fresh <meta.json> -- rc 0 while the terminal writer may still
# be settling, rc 1 once the grace window has elapsed, rc 2 on a stat error.
_worker_meta_is_fresh() {
    # shellcheck disable=SC2016  # JavaScript template literal, not shell expansion.
    node -e '
const fs = require("fs");
const p = process.argv[1];
const graceMs = Number(process.argv[2]) * 1000;
try { process.exit(Date.now() - fs.statSync(p).mtimeMs < graceMs ? 0 : 1); }
catch (e) { console.error(`ERR reconcile-workers: cannot stat ${p}: ${e.message}`); process.exit(2); }
' "$1" "$RECONCILE_GRACE_SECS"
}

# _worker_mark_orphaned <meta.json> <expected-pid> -- compare-and-rewrite. The
# re-read prevents clobbering a terminal writer that won the race after census.
_worker_mark_orphaned() {
    # shellcheck disable=SC2016  # JavaScript template literals, not shell expansion.
    node -e '
const fs = require("fs");
const p = process.argv[1];
const expected = Number(process.argv[2]);
let o;
try { o = JSON.parse(fs.readFileSync(p, "utf8")); }
catch (e) { console.error(`ERR reconcile-workers: cannot re-read ${p}: ${e.message}`); process.exit(2); }
if (o.status !== "running" || Number(o.pid) !== expected) process.exit(3);
o.status = "orphaned";
const tmp = `${p}.tmp-reconcile-${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(o, null, 2) + "\n");
fs.renameSync(tmp, p);
' "$1" "$2"
}

# _worker_unprobeable_ceiling_exceeded <meta.json> -- rc 0 once the session
# directory (the meta.json's parent dir) is older than the absolute
# RECONCILE_UNPROBEABLE_CEILING_SECS backstop, rc 1 while still within it,
# rc 2 on a stat error (fail open toward NOT exceeded -- a stat failure must
# never authorize cleanup, same contract as worker_pid_alive above).
_worker_unprobeable_ceiling_exceeded() {
    # shellcheck disable=SC2016  # JavaScript template literal, not shell expansion.
    node -e '
const fs = require("fs");
const path = require("path");
const p = process.argv[1];
const ceilingMs = Number(process.argv[2]) * 1000;
const now = process.argv[3] ? Number(process.argv[3]) : Date.now();
try { process.exit(now - fs.statSync(path.dirname(p)).mtimeMs >= ceilingMs ? 0 : 1); }
catch (e) { console.error(`ERR reconcile-workers: cannot stat ${path.dirname(p)}: ${e.message}`); process.exit(2); }
' "$1" "$RECONCILE_UNPROBEABLE_CEILING_SECS" "${RECONCILE_TEST_NOW_MS:-}"
}

# _worker_mark_orphaned_unprobeable <meta.json> -- terminal-mark a row whose
# pid was never written (HIMMEL-1511) once it exceeds the unprobeable ceiling
# backstop. Re-read both status and pid so a worker that acquired its first real
# pid after census wins the race and exits 3, same convention as
# _worker_mark_orphaned above.
_worker_mark_orphaned_unprobeable() {
    # shellcheck disable=SC2016  # JavaScript template literals, not shell expansion.
    node -e '
const fs = require("fs");
const p = process.argv[1];
let o;
try { o = JSON.parse(fs.readFileSync(p, "utf8")); }
catch (e) { console.error(`ERR reconcile-workers: cannot re-read ${p}: ${e.message}`); process.exit(2); }
const pid = o.pid == null ? "" : String(o.pid);
if (o.status !== "running" || /^[1-9][0-9]*$/.test(pid)) process.exit(3);
o.status = "orphaned";
const tmp = `${p}.tmp-reconcile-${process.pid}`;
fs.writeFileSync(tmp, JSON.stringify(o, null, 2) + "\n");
fs.renameSync(tmp, p);
' "$1"
}

_worker_common_dir() {
    local repo="$1" out
    out=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || out=""
    if [ -n "$out" ]; then
        printf '%s\n' "$out"
        return 0
    fi
    out=$(git -C "$repo" rev-parse --git-common-dir 2>/dev/null) || out=""
    [ -n "$out" ] || return 1
    case "$out" in
        /*|[A-Za-z]:/*|[A-Za-z]:\\*) printf '%s\n' "$out" ;;
        *) (cd "$repo" 2>/dev/null && cd "$out" 2>/dev/null && pwd -P) ;;
    esac
}

_worker_lockdir() {
    local repo="$1" branch="$2" common slug
    common=$(_worker_common_dir "$repo") || return 1
    slug=$(printf '%s' "$branch" | tr -c 'a-zA-Z0-9-' '-')
    printf '%s/himmel-shared-branch/%s.lock\n' "$common" "$slug"
}

_worker_lock_owner_pid() {
    node -e '
const fs = require("fs");
try {
  const o = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  if (Number.isInteger(o.pid) && o.pid > 0) process.stdout.write(String(o.pid));
} catch (_) {}
' "$1"
}

# _worker_release_dead_lock <repo> <branch> -- atomically CLAIM the stale lock
# directory by rename before deleting it. Once renamed, a new dispatcher may
# acquire the original path and cannot be removed by this cleanup.
_worker_release_dead_lock() {
    local repo="$1" branch="$2" lockdir owner owner_now claimed rc
    lockdir=$(_worker_lockdir "$repo" "$branch") || return 1
    [ -d "$lockdir" ] || return 1
    [ -f "$lockdir/owner.json" ] || return 1
    owner=$(_worker_lock_owner_pid "$lockdir/owner.json")
    [ -n "$owner" ] || return 1
    worker_pid_alive "$owner"
    rc=$?
    [ "$rc" -eq 1 ] || return 1

    # Re-read immediately before the atomic claim. The owner cannot change
    # while the directory exists; acquire uses mkdir and cannot enter it.
    owner_now=$(_worker_lock_owner_pid "$lockdir/owner.json")
    [ "$owner_now" = "$owner" ] || return 1
    claimed="${lockdir}.reconcile.$$"
    if [ -e "$claimed" ]; then
        echo "WARN reconcile-workers: stale-lock claim path already exists '$claimed'; left the lock in place" >&2
        return 1
    fi
    if ! mv "$lockdir" "$claimed" 2>/dev/null; then
        echo "WARN reconcile-workers: could not claim stale lock '$lockdir'; left it in place" >&2
        return 1
    fi
    rm -rf "$claimed"
    if [ -d "$claimed" ]; then
        echo "WARN reconcile-workers: claimed stale lock '$claimed' could not be removed" >&2
        return 1
    fi
    return 0
}

FAILED=0

# HIMMEL-2066: gather every meta.json path FIRST, then hand the whole batch
# to one _worker_census node process below, instead of spawning node once
# per file inside this loop. Zero files -> census_paths stays empty ->
# _worker_census is never invoked at all.
census_paths=""
for lane_dir in "$BRIDGE/glm-sessions" "$BRIDGE/claudex-sessions"; do
    for meta in "$lane_dir"/*/meta.json; do
        [ -f "$meta" ] || continue
        census_paths="$census_paths$meta"$'\n'
    done
done

if [ -n "$census_paths" ]; then
    # node.exe cannot open the bash-native (MSYS/POSIX-style) path directly on
    # Windows -- see _worker_census's doc comment above. cygpath -f converts
    # the WHOLE list in one extra process (still O(1) spawns for the batch,
    # not O(files)); everywhere else (no cygpath, i.e. not Windows) the
    # "open" path is just the original path, unchanged.
    census_orig_file=$(mktemp 2>/dev/null) && census_open_file=$(mktemp 2>/dev/null)
    if [ -z "${census_orig_file:-}" ] || [ -z "${census_open_file:-}" ]; then
        echo "ERR reconcile-workers: mktemp failed for worker census batch" >&2
        rm -f "${census_orig_file:-}"
        FAILED=1
        census_rows=""
    else
        printf '%s' "$census_paths" > "$census_orig_file"
        if command -v cygpath >/dev/null 2>&1; then
            cygpath -w -f "$census_orig_file" > "$census_open_file"
            cygpath_rc=$?
            # Name the real cause up front -- without this, a failed batch
            # conversion looks identical to hundreds of individually corrupt
            # meta.json files (each still fails its own JSON.parse below).
            [ "$cygpath_rc" -eq 0 ] || echo "ERR reconcile-workers: cygpath batch conversion failed rc=$cygpath_rc" >&2
        else
            cp "$census_orig_file" "$census_open_file"
        fi
        census_rows=$(paste -d $'\x1f' "$census_orig_file" "$census_open_file" | _worker_census)
        rc=$?
        [ "$rc" -eq 0 ] || FAILED=1
        rm -f "$census_orig_file" "$census_open_file"
    fi

    # Read from fd 3, not the loop body's inherited stdin (fd 0): the loop
    # body below calls several node helpers per candidate row, and if any of
    # them ever reads from an inherited stdin (a test stub intercepting node
    # this way caught it -- HIMMEL-2066), that read would silently steal
    # bytes meant for THIS loop's next iteration, dropping rows. Row fields
    # are single-line JSON scalars from this codebase's own writers (status/
    # pid/branch/etc. are never multi-line strings), so a bare newline always
    # means "next row" -- there's no embedded-newline case to guard against.
    while IFS=$'\x1f' read -r meta status pid branch repo_dir lane task_name <&3; do
        [ -n "$meta" ] || continue
        [ "$status" = "running" ] || continue

        if worker_pid_alive "$pid"; then
            if [ "$MODE" = "--list-live" ]; then
                printf '%s task=%s pid=%s meta=%s\n' "${lane:-unknown}" "${task_name:-unknown}" "$pid" "$meta"
            fi
            continue
        else
            probe_rc=$?
        fi
        if [ "$probe_rc" -ne 1 ]; then
            # HIMMEL-1511: a pid that was NEVER written (empty, 0, or junk --
            # the same set worker_pid_alive itself short-circuits on above,
            # matching writeLiveWorkerMeta's fallback marker shape) gets an
            # absolute-ceiling backstop so it cannot block arming forever.
            # A pid that failed to PROBE (tasklist/probe-command failure)
            # keeps a real recorded pid here and is deliberately excluded --
            # that stays a pure grace-based case, not the relic shape.
            case "$pid" in
                ''|*[!0-9]*|0)
                    if [ "$MODE" = "reconcile" ] && _worker_unprobeable_ceiling_exceeded "$meta"; then
                        _worker_mark_orphaned_unprobeable "$meta"
                        rc=$?
                        if [ "$rc" -eq 0 ]; then
                            summary="reconcile-workers: orphaned ${lane:-unknown}/${task_name:-unknown} pid=never-written (unprobeable past ${RECONCILE_UNPROBEABLE_CEILING_SECS}s ceiling)"
                            if [ -n "$branch" ]; then
                                [ -n "$repo_dir" ] || repo_dir="$SCRIPT_DIR/../.."
                                if _worker_release_dead_lock "$repo_dir" "$branch"; then
                                    summary="$summary; released shared lock $branch"
                                fi
                            fi
                            echo "$summary"
                            continue
                        fi
                        if [ "$rc" -ne 3 ]; then
                            FAILED=1
                            continue
                        fi
                    fi
                    ;;
            esac
            echo "WARN reconcile-workers: unprobeable ${lane:-unknown}/${task_name:-unknown} pid=${pid:-absent}; treating as possibly alive, leaving metadata and any shared lock untouched" >&2
            if [ "$MODE" = "--list-live" ]; then
                printf '%s task=%s pid=%s state=unprobeable meta=%s\n' "${lane:-unknown}" "${task_name:-unknown}" "${pid:-absent}" "$meta"
            fi
            continue
        fi

        if _worker_meta_is_fresh "$meta"; then
            echo "WARN reconcile-workers: settling ${lane:-unknown}/${task_name:-unknown} pid=${pid:-absent}; meta.json is newer than the ${RECONCILE_GRACE_SECS}s grace, leaving metadata and any shared lock untouched" >&2
            if [ "$MODE" = "--list-live" ]; then
                printf '%s task=%s pid=%s state=settling meta=%s\n' "${lane:-unknown}" "${task_name:-unknown}" "${pid:-absent}" "$meta"
            fi
            continue
        else
            freshness_rc=$?
        fi
        if [ "$freshness_rc" -ne 1 ]; then
            FAILED=1
            continue
        fi
        [ "$MODE" = "reconcile" ] || continue

        _worker_mark_orphaned "$meta" "$pid"
        rc=$?
        if [ "$rc" -eq 3 ]; then
            continue
        fi
        if [ "$rc" -ne 0 ]; then
            FAILED=1
            continue
        fi

        summary="reconcile-workers: orphaned ${lane:-unknown}/${task_name:-unknown} pid=${pid:-0}"
        if [ -n "$branch" ]; then
            [ -n "$repo_dir" ] || repo_dir="$SCRIPT_DIR/../.."
            if _worker_release_dead_lock "$repo_dir" "$branch"; then
                summary="$summary; released shared lock $branch"
            fi
        fi
        echo "$summary"
    done 3<<< "$census_rows"
fi

[ "$FAILED" -eq 0 ] || exit 2
exit 0
