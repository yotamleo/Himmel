#!/usr/bin/env bash
# scripts/lanes/bench/run-batch.sh — HIMMEL-1723 P2.9
# The batch driver: P2.1-P2.8 build single-shot primitives (materialize one
# fixture, dispatch one luna run, write one manifest, ...); nothing walks the
# task x cell x rep matrix. This does.
#
# The luna cell is the only one this driver can actually DISPATCH — the
# Haiku cell needs the Agent tool, which exists only inside a live Claude
# Code session (spec §2.6), so this driver models that seam explicitly
# instead of pretending both cells are scriptable: `emit-manual-queue` prints
# the pending haiku run-ids + their literal prompts for the orchestrating
# agent to execute by hand, and `ingest-haiku` writes the resulting manifest
# once that agent reports back.
#
# Subcommands:
#   matrix              --tasks-dir <dir> --reps <n> [--tasks T1,T2,...] [--cells luna,haiku]
#                        print every run-id in the task x cell x rep matrix,
#                        one per line: "<run-id>\t<task>\t<cell>\t<rep>"
#
#   dispatch-luna        --tasks-dir <dir> --runs-dir <dir> --reps <n>
#                        [--tasks ...] [--retry-cap 2] [--bank-check-every 10]
#                        [--dry-run] [--effort <level>]
#                        Iterates the luna slice of the matrix. RESUMES by
#                        run-id: a run-id with an already-complete
#                        runs/<id>.json (non-null exit_code) is skipped, so an
#                        aborted batch resumes instead of restarting.
#                        Checks the banks (bank-snapshot.sh check) before the
#                        first paid attempt and every --bank-check-every paid
#                        attempts after that; on a threshold breach the batch
#                        ABORTS (nonzero exit) and every run completed so far
#                        is left intact and resumable.
#                        A dispatch that fails --retry-cap times in a row is
#                        recorded error-harness-final (spec §3.4) and the
#                        batch CONTINUES to the next run-id — a harness
#                        failure on one task must not lose the rest of the
#                        batch.
#
#   emit-manual-queue    --tasks-dir <dir> --runs-dir <dir> --reps <n> [--tasks ...]
#                        Prints every pending (not-yet-complete) haiku run-id
#                        with its task and the literal prompt.md content, for
#                        the orchestrating agent to dispatch one Agent-tool
#                        call per entry (run-id echoed into the prompt per
#                        spec §2.7) and then call ingest-haiku with the result.
#
#   ingest-haiku         --tasks-dir <dir> --runs-dir <dir> --run-id <id>
#                        --task <t> --rep <n> --fixture-path <dir>
#                        [--transcript-path <path>]
#                        (--tasks-dir and --fixture-path are REQUIRED — the
#                        earlier usage line omitted both while the guard below
#                        enforced them, so a call made exactly as documented
#                        exited 2; codex CR)
#                        --fixture-path <dir> --transcript-path <path>
#                        --exit-code <n> --duration-ms <n> [--verdict <v>] [--effort <e>]
#                        Writes runs/<run-id>.json for a haiku run the
#                        orchestrating agent just executed manually.
#
# BENCH_CLAUDE_CODEX_BIN / BENCH_LUNA_TIMEOUT_SECS (dispatch-luna.sh's own
# test hooks) pass through untouched, which is how the retry-cap and
# bank-abort behavior are exercised hermetically in
# scripts/lanes/tests/bench-run-batch.test.mjs without a real codex dispatch.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
BENCH_DIR="$HERE"

usage() {
    echo "usage: run-batch.sh <matrix|dispatch-luna|emit-manual-queue|ingest-haiku> [flags...]" >&2
    exit 2
}

cmd="${1:-}"
[ -n "$cmd" ] || usage
shift

TASKS_DIR=""
RUNS_DIR=""
REPS=""
TASKS_OPT=""
CELLS_OPT=""
RETRY_CAP=2
BANK_CHECK_EVERY=10
DRY_RUN=0
EFFORT="${BENCH_LUNA_EFFORT:-high}"

# ingest-haiku's own flags (parsed separately below; global parse loop
# tolerates them so a single dispatch table can cover every subcommand).
IH_RUN_ID=""; IH_TASK=""; IH_REP=""; IH_FIXTURE_PATH=""; IH_TRANSCRIPT_PATH=""
IH_EXIT_CODE=""; IH_DURATION_MS=""; IH_VERDICT=""; IH_EFFORT="${BENCH_HAIKU_EFFORT:-low}"

while [ $# -gt 0 ]; do
    case "$1" in
        --tasks-dir) TASKS_DIR="$2"; shift 2 ;;
        --runs-dir) RUNS_DIR="$2"; shift 2 ;;
        --reps) REPS="$2"; shift 2 ;;
        --tasks) TASKS_OPT="$2"; shift 2 ;;
        --cells) CELLS_OPT="$2"; shift 2 ;;
        --retry-cap) RETRY_CAP="$2"; shift 2 ;;
        --bank-check-every) BANK_CHECK_EVERY="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        --effort) EFFORT="$2"; shift 2 ;;
        --run-id) IH_RUN_ID="$2"; shift 2 ;;
        --task) IH_TASK="$2"; shift 2 ;;
        --rep) IH_REP="$2"; shift 2 ;;
        --fixture-path) IH_FIXTURE_PATH="$2"; shift 2 ;;
        --transcript-path) IH_TRANSCRIPT_PATH="$2"; shift 2 ;;
        --exit-code) IH_EXIT_CODE="$2"; shift 2 ;;
        --duration-ms) IH_DURATION_MS="$2"; shift 2 ;;
        --verdict) IH_VERDICT="$2"; shift 2 ;;
        *) echo "run-batch.sh $cmd: unknown argument: $1" >&2; exit 2 ;;
    esac
done

_list_tasks() {
    if [ -n "$TASKS_OPT" ]; then
        printf '%s\n' "$TASKS_OPT" | tr ',' '\n'
    else
        local d
        for d in "$TASKS_DIR"/*/; do
            [ -f "${d}prompt.md" ] || continue
            basename "$d"
        done
    fi
}

_list_cells() {
    if [ -n "$CELLS_OPT" ]; then
        printf '%s\n' "$CELLS_OPT" | tr ',' '\n'
    else
        printf 'luna\nhaiku\n'
    fi
}

emit_matrix() {
    local task cell rep
    for task in $(_list_tasks); do
        for cell in $(_list_cells); do
            rep=1
            while [ "$rep" -le "$REPS" ]; do
                printf '%s-%s-%s\t%s\t%s\t%s\n' "$task" "$cell" "$rep" "$task" "$cell" "$rep"
                rep=$((rep + 1))
            done
        done
    done
}

# _is_complete <run-id> — a manifest is "complete" once it has been written
# with a non-null exit_code (buildRunRecord's JSON.stringify(...,null,2)
# always renders a null field as the literal `"exit_code": null`, so its
# ABSENCE from the file is a reliable, dependency-free completeness check).
_is_complete() {
    local run_id="$1"
    local f="$RUNS_DIR/$run_id.json"
    [ -f "$f" ] || return 1  # fail-open-ok: known candidate (HIMMEL-1776 ask-4 list) — an unreadable manifest reads as complete; bench-reporting only, not a guard
    grep -q '"exit_code": null' "$f" && return 1
    return 0
}

_field() {
    # $1 = a TAB-separated "RESULT<TAB>k=v<TAB>k=v ..." line (dispatch-luna.sh),
    # $2 = field name -> its value on stdout.
    # Split on TAB, not space (codex CR): fixture_path / transcript_path /
    # run_log are filesystem paths, and a space in any of them truncated the
    # value silently under the old `[^ ]*` match — producing a manifest that
    # still parsed but pointed at a nonexistent path. Anchoring each candidate
    # at ^ also stops a field name that is a suffix of another from matching.
    printf '%s\n' "$1" | tr '\t' '\n' | grep -oE "^$2=.*" | head -1 | cut -d= -f2-
}

cmd_matrix() {
    if [ -z "$TASKS_DIR" ] || [ -z "$REPS" ]; then
        echo "matrix: --tasks-dir and --reps are required" >&2; exit 2
    fi
    emit_matrix
}

cmd_dispatch_luna() {
    if [ -z "$TASKS_DIR" ] || [ -z "$RUNS_DIR" ] || [ -z "$REPS" ]; then
        echo "dispatch-luna: --tasks-dir, --runs-dir, --reps are required" >&2; exit 2
    fi
    mkdir -p "$RUNS_DIR" 2>/dev/null

    local run_id task cell rep attempts=0

    while IFS="$(printf '\t')" read -r run_id task cell rep; do
        [ "$cell" = "luna" ] || continue

        if [ "$DRY_RUN" -eq 1 ]; then
            "${BASH:-bash}" "$BENCH_DIR/dispatch-luna.sh" "$TASKS_DIR/$task" "$run_id" --dry-run --effort "$EFFORT"
            continue
        fi

        if _is_complete "$run_id"; then
            echo "run-batch: skip (already complete): $run_id"
            continue
        fi

        local task_dir="$TASKS_DIR/$task" prompt_file="$TASKS_DIR/$task/prompt.md"
        local attempt=0 launcher_exit="" result_line="" duration_ms="0" fixture_path="" transcript_path="-"
        while [ "$attempt" -lt "$RETRY_CAP" ]; do
            if [ $((attempts % BANK_CHECK_EVERY)) -eq 0 ]; then
                if ! "${BASH:-bash}" "$BENCH_DIR/bank-snapshot.sh" check; then
                    echo "run-batch: ABORTING before paid attempt $((attempts + 1)) — bank threshold breached; completed runs are intact and resumable" >&2
                    exit 5
                fi
            fi
            attempt=$((attempt + 1))
            attempts=$((attempts + 1))
            result_line="$("${BASH:-bash}" "$BENCH_DIR/dispatch-luna.sh" "$task_dir" "$run_id" --effort "$EFFORT" 2>>"${BENCH_DISPATCH_ERR_LOG:-/dev/null}" | grep '^RESULT')"
            if [ -z "$result_line" ]; then
                echo "run-batch: attempt $attempt/$RETRY_CAP for $run_id produced no RESULT line (harness failure)" >&2
                launcher_exit=""
                continue
            fi
            launcher_exit="$(_field "$result_line" exit_code)"
            duration_ms="$(_field "$result_line" duration_ms)"
            fixture_path="$(_field "$result_line" fixture_path)"
            transcript_path="$(_field "$result_line" transcript_path)"
            if [ "$launcher_exit" = "0" ]; then break; fi
            echo "run-batch: attempt $attempt/$RETRY_CAP for $run_id: launcher exit_code=$launcher_exit" >&2
        done

        # verdict stays "" (-> no --verdict payload, buildRunRecord defaults
        # it to null) on a clean dispatch — verify.sh scoring happens later
        # (spec P5.5) — and becomes error-harness-final once the retry cap is
        # exhausted. --verdict is passed UNCONDITIONALLY (never inside a
        # conditionally-empty array): "${arr[@]}" on a zero-element array
        # throws under `set -u` on bash <4.4 (bash 3.2 on macOS), so
        # run-manifest.mjs treats an empty --verdict value as "not supplied"
        # instead.
        local verdict=""
        if [ "$launcher_exit" = "0" ]; then
            : # clean dispatch
        else
            verdict="error-harness-final"
            launcher_exit="${launcher_exit:-1}"
        fi
        node "$BENCH_DIR/run-manifest.mjs" write \
            --runs-dir "$RUNS_DIR" --run-id "$run_id" --task "$task" --cell luna --rep "$rep" \
            --model gpt-5.6-luna --effort "$EFFORT" --prompt-file "$prompt_file" \
            --fixture-path "${fixture_path:-unknown}" --transcript-path "${transcript_path:--}" \
            --exit-code "$launcher_exit" --duration-ms "$duration_ms" --verdict "$verdict" >/dev/null

    done < <(emit_matrix)

    exit 0
}

cmd_emit_manual_queue() {
    if [ -z "$TASKS_DIR" ] || [ -z "$RUNS_DIR" ] || [ -z "$REPS" ]; then
        echo "emit-manual-queue: --tasks-dir, --runs-dir, --reps are required" >&2; exit 2
    fi
    local run_id task cell rep
    while IFS="$(printf '\t')" read -r run_id task cell rep; do
        [ "$cell" = "haiku" ] || continue
        _is_complete "$run_id" && continue
        echo "=== $run_id ==="
        echo "task: $task"
        echo "run_id: $run_id"
        echo "rep: $rep"
        echo "--- prompt.md ---"
        cat "$TASKS_DIR/$task/prompt.md"
        echo "--- end ---"
        echo
    done < <(emit_matrix)
}

cmd_ingest_haiku() {
    if [ -z "$RUNS_DIR" ] || [ -z "$TASKS_DIR" ] || [ -z "$IH_RUN_ID" ] || [ -z "$IH_TASK" ] || [ -z "$IH_REP" ] || [ -z "$IH_FIXTURE_PATH" ]; then
        echo "ingest-haiku: --tasks-dir, --runs-dir, --run-id, --task, --rep, --fixture-path are required" >&2; exit 2
    fi
    mkdir -p "$RUNS_DIR" 2>/dev/null
    local prompt_file="$TASKS_DIR/$IH_TASK/prompt.md"
    # --verdict passed unconditionally (empty string = "not supplied") for the
    # same bash-3.2 empty-array reason documented in cmd_dispatch_luna.
    node "$BENCH_DIR/run-manifest.mjs" write \
        --runs-dir "$RUNS_DIR" --run-id "$IH_RUN_ID" --task "$IH_TASK" --cell haiku --rep "$IH_REP" \
        --model claude-haiku-4-5 --effort "$IH_EFFORT" --prompt-file "$prompt_file" \
        --fixture-path "$IH_FIXTURE_PATH" --transcript-path "${IH_TRANSCRIPT_PATH:--}" --verdict "$IH_VERDICT" \
        --exit-code "${IH_EXIT_CODE:-0}" --duration-ms "${IH_DURATION_MS:-0}"
}

case "$cmd" in
    matrix) cmd_matrix ;;
    dispatch-luna) cmd_dispatch_luna ;;
    emit-manual-queue) cmd_emit_manual_queue ;;
    ingest-haiku) cmd_ingest_haiku ;;
    *) usage ;;
esac
