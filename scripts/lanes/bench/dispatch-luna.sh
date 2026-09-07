#!/usr/bin/env bash
# scripts/lanes/bench/dispatch-luna.sh — HIMMEL-1723 P2.3
# Dispatches ONE luna-cell bench run by invoking scripts/claude-codex
# DIRECTLY (spec §2.2) — cwd set to the materialized fixture dir, stdin
# closed, effort pinned and recorded.
#
# This file (and every other file under scripts/lanes/bench/) must NEVER
# route through the Telegram worker spawner for the claudex lane. That path
# composes a worker-identity preamble into the prompt (biasing the very
# minimality property this bench scores), refuses any cwd that is not a
# himmel checkout, mints a git worktree + branch, and instructs the model to
# commit — every one of those is fatal to a bench that must measure the
# MODEL, not the harness. scripts/lanes/tests/bench-no-telegram-spawner.test.mjs
# greps this whole directory for that spawner's literal script-name substring
# and fails the build if it appears anywhere, mirroring the P2.8 ledger-path
# guard — so if you are about to reference that path even in a comment
# explaining why NOT to use it, don't: describe it by ticket/behavior instead
# (as this comment does), or the structural guard needs a comment carve-out,
# which is a weaker invariant to hold than "the substring never appears".
#
# Usage:
#   dispatch-luna.sh <task-dir> <run-id> [--dry-run] [--effort <level>]
#
#   task-dir    fixture directory (must contain input/ and prompt.md)
#   run-id      <task>-luna-<rep>, e.g. T7-luna-1
#   --dry-run   materialize (so a real cwd can be shown) but print the exact
#               argv + env that WOULD be used and exit 0 WITHOUT launching
#               anything real
#   --effort    CLAUDE_CODE_EFFORT_LEVEL to pin (default: high, the
#               launcher's own registry-default per spec §3.1.1 — luna's
#               headline comparison is registry-default vs registry-default)
#
# On a real (non-dry-run) dispatch, prints exactly one RESULT line to stdout;
# everything else (the launcher's own stdout/stderr) goes to the run_log
# file, never to this script's stdout, so RESULT stays the one
# machine-parseable line a caller (run-batch.sh) needs to parse:
#   RESULT<TAB>run_id=<id><TAB>exit_code=<n><TAB>duration_ms=<n><TAB>fixture_path=<dir><TAB>transcript_path=<path|-><TAB>run_log=<path>
#
# Fields are TAB-separated, not space-separated (codex CR): three of the six
# values are filesystem paths, and a fixture or scratch dir containing a space
# (common under a Windows user profile) would otherwise truncate silently at
# the first space in run-batch.sh's _field parser — a corrupted manifest that
# still looks well-formed. Tabs cannot occur in these paths in practice.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
LAUNCHER="${BENCH_CLAUDE_CODEX_BIN:-$REPO_ROOT/scripts/claude-codex}"
MATERIALIZE="$HERE/materialize.sh"
# shellcheck source=../../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$REPO_ROOT/scripts/lib/proc-tree.sh"

DRY_RUN=0
EFFORT="${BENCH_LUNA_EFFORT:-high}"
TIMEOUT_SECS="${BENCH_LUNA_TIMEOUT_SECS:-1200}"   # 20 minutes, spec §4.1
task_dir=""
run_id=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --effort)
            [ $# -ge 2 ] || { echo "dispatch-luna.sh: --effort needs a value" >&2; exit 2; }
            EFFORT="$2"; shift 2 ;;
        *)
            if [ -z "$task_dir" ]; then task_dir="$1"
            elif [ -z "$run_id" ]; then run_id="$1"
            else echo "dispatch-luna.sh: unexpected argument: $1" >&2; exit 2
            fi
            shift ;;
    esac
done
if [ -z "$task_dir" ] || [ -z "$run_id" ]; then
    echo "usage: dispatch-luna.sh <task-dir> <run-id> [--dry-run] [--effort <level>]" >&2
    exit 2
fi

prompt_file="$task_dir/prompt.md"
if [ ! -f "$prompt_file" ]; then
    echo "dispatch-luna.sh: no prompt.md under $task_dir" >&2
    exit 2
fi
prompt_text="$(cat "$prompt_file")"

fixture_path="$("$MATERIALIZE" "$task_dir" "$run_id")" || { echo "dispatch-luna.sh: materialize failed" >&2; exit 3; }

if [ "$DRY_RUN" -eq 1 ]; then
    prompt_bytes="$(printf '%s' "$prompt_text" | wc -c)"
    echo "DRY-RUN argv: bash $LAUNCHER --permission-mode dontAsk <prompt.md contents, $prompt_bytes bytes>"
    echo "DRY-RUN env: CODEX_MODEL=gpt-5.6-luna CLAUDE_CODE_EFFORT_LEVEL=$EFFORT"
    echo "DRY-RUN cwd: $fixture_path"
    echo "DRY-RUN stdin: closed"
    exit 0
fi

log_dir="${BENCH_RUN_LOG_DIR:-${BENCH_SCRATCH_ROOT:-${TMPDIR:-/tmp}/himmel-bench}/run-logs}"
mkdir -p "$log_dir" || { echo "dispatch-luna.sh: cannot create $log_dir" >&2; exit 3; }
run_log="$log_dir/$run_id.log"

now_ms() {
    local n
    n="$(date +%s%N 2>/dev/null)"
    case "$n" in
        ''|*N*) echo "$(( $(date +%s) * 1000 ))" ;;
        *) echo "$(( n / 1000000 ))" ;;
    esac
}

started_ms="$(now_ms)"

# Job control gives the launcher (and every descendant it spawns) a
# dedicated process group on POSIX and Git Bash, which proc_tree_terminate
# relies on for a real TREE kill on timeout (spec §4.1: 20-minute budget,
# tree-kill on overrun).
#
# "${BASH:-bash}" (never a bare `bash`): on Windows a bare `bash` on PATH can
# resolve to the WSL launcher instead of Git Bash (confirmed empirically —
# WSL bash cannot even read a C:/Users/... Windows-form path). $BASH is a
# bash builtin always set to the CONCRETE interpreter currently running this
# very script, so re-using it to launch $LAUNCHER guarantees the same,
# already-correct interpreter rather than repeating a fresh, ambiguous PATH
# lookup.
set -m
( cd "$fixture_path" && CODEX_MODEL=gpt-5.6-luna CLAUDE_CODE_EFFORT_LEVEL="$EFFORT" \
    "${BASH:-bash}" "$LAUNCHER" --permission-mode dontAsk "$prompt_text" ) < /dev/null > "$run_log" 2>&1 &
pid=$!
set +m

waited=0
exit_code=""
while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$TIMEOUT_SECS" ]; then
        proc_tree_terminate "$pid" 3 >/dev/null 2>&1
        echo "dispatch-luna.sh: TIMEOUT after ${TIMEOUT_SECS}s, tree-killed pid $pid" >> "$run_log"
        wait "$pid" 2>/dev/null
        exit_code=124
        break
    fi
    sleep 5
    waited=$((waited + 5))
done
if [ -z "$exit_code" ]; then
    wait "$pid"
    exit_code=$?
fi

ended_ms="$(now_ms)"
duration_ms=$((ended_ms - started_ms))

# Resolve the transcript this dispatch wrote (spec §6.1): cwd is
# $fixture_path, unique per run-id (materialize.sh mints a fresh scratch dir
# every call), so the session's project slug names AT MOST one dispatch's
# worth of transcripts. Slug algorithm mirrors scripts/luna/backfill-sessions.sh
# :_path_to_slug (Claude Code's own path->slug encoding, verified empirically
# against a real ~/.claude/projects listing): convert to Windows drive-letter
# form first (cygpath -w — a no-op off Windows), then map every
# non-[a-zA-Z0-9] char to '-', strip a leading '-'.
win_path="$fixture_path"
if command -v cygpath >/dev/null 2>&1; then
    win_path="$(cygpath -w "$fixture_path" 2>/dev/null)"
    [ -n "$win_path" ] || win_path="$fixture_path"
fi
slug="$(printf '%s' "$win_path" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"
codex_home="${HOME:-$USERPROFILE}"
proj_dir="$codex_home/.claude-codex/projects/$slug"
transcript_path="-"
if [ -d "$proj_dir" ]; then
    # find + sort on mtime (shellcheck SC2012: `ls -t` mishandles
    # non-alphanumeric filenames) — GNU -printf first (Git Bash), BSD
    # `stat -f` fallback, mirroring proc-tree.sh's newest_mtime convention.
    newest="$(find "$proj_dir" -maxdepth 1 -type f -name '*.jsonl' -printf '%T@\t%p\n' 2>/dev/null | sort -rn | head -1 | cut -f2-)"
    if [ -z "$newest" ]; then
        newest="$(find "$proj_dir" -maxdepth 1 -type f -name '*.jsonl' -exec stat -f '%m %N' {} + 2>/dev/null | sort -rn | head -1 | cut -d' ' -f2-)"
    fi
    [ -n "$newest" ] && transcript_path="$newest"
fi

printf 'RESULT\trun_id=%s\texit_code=%s\tduration_ms=%s\tfixture_path=%s\ttranscript_path=%s\trun_log=%s\n' \
    "$run_id" "$exit_code" "$duration_ms" "$fixture_path" "$transcript_path" "$run_log"
