#!/usr/bin/env bash
# Flow-run ledger append helpers (HIMMEL-921). Bash twin of
# scripts/telegram/flow-run-ledger.ts. Emits byte-identical canonical JSONL
# lifecycle rows and appends them to ~/.himmel/flow-runs.jsonl by default.
# bash 3.2-safe (no associative arrays, no mapfile).

# PATH self-heal: emitted .bat runners invoke this lib via the bare
# usr\bin\bash.exe (the arm-time `command -v bash` resolution), which does
# NOT bootstrap the MSYS PATH the way the bin\bash.exe wrapper does. On a
# host whose WINDOWS PATH lacks Git's usr\bin (live win2 station fire, s53),
# dirname/date/mkdir/mv are all missing and the append silently dies. The
# in-process /usr/bin mount always exists for an MSYS bash, so heal from it.
command -v dirname >/dev/null 2>&1 && command -v date >/dev/null 2>&1 \
    && command -v mkdir >/dev/null 2>&1 && command -v mv >/dev/null 2>&1 \
    || PATH="/usr/bin:/bin:$PATH"

_fr_src="${BASH_SOURCE[0]:-$0}"
_fr_self_dir=$(cd "$(dirname "$_fr_src")" 2>/dev/null && pwd) || _fr_self_dir="$(dirname "$_fr_src")"
# shellcheck source=flow-run-ledger-path.sh
# shellcheck disable=SC1091
. "$_fr_self_dir/flow-run-ledger-path.sh"

FLOW_RUN_ROTATE_BYTES=10485760

# Keep the truncation signatures in this shared lib and mirror them in the TS
# twin. The classifier scans only the run-log tail.
FLOW_RUN_TRUNCATION_SIGNATURE_RE='Background tasks still running.*terminating'

# The ONE retryable-upstream signature list (HIMMEL-1152). A cadence leg that
# dies on a transient Anthropic API failure — the 2026-07-17 harvest run died
# on the literal line `API Error: Server error mid-response. The response above
# may be incomplete.` after harvesting 7 clips — is worth re-invoking: every
# pipeline stage is idempotent through its own markers (harvested_at:,
# processed:, the _done/ move), so a re-invoke RESUMES instead of redoing.
# Deliberately NARROW: the claude CLI's `API Error:` prefix must be on the
# line, so ordinary log prose mentioning "overloaded" or a 500 cannot arm a
# retry, and every other failure is treated as real and never retried. Runner
# only — no TS consumer, so the twin does not mirror it.
FLOW_RUN_TRANSIENT_SIGNATURE_RE='API Error:.*([Ss]erver error|[Oo]verloaded|mid-response|5[0-9][0-9])'

# Cadence runners stamp this word into their log immediately before each
# attempt, so the scan below reads ONLY the current attempt's output. Without
# it, attempt 2's own (non-transient) failure would be judged against
# attempt 1's leftover error line and burn the whole retry budget.
FLOW_RUN_ATTEMPT_MARKER='cadence-attempt'

_fr_now_utc() {
    date -u +%Y-%m-%dT%H:%M:%SZ
}

# Minimal JSON string escape (matches TS jsonStr): backslash, dquote,
# CR/LF/TAB. bash 3.2-safe parameter expansion.
_fr_json_str() {
    local s="$1"
    s=${s//\\/\\\\}
    s=${s//\"/\\\"}
    s=${s//$'\n'/\\n}
    s=${s//$'\r'/\\r}
    s=${s//$'\t'/\\t}
    printf '"%s"' "$s"
}

_fr_json_null_str() {
    if [ -n "${1:-}" ]; then
        _fr_json_str "$1"
    else
        printf 'null'
    fi
}

_fr_json_int() {
    case "${1:-}" in
        "") printf 'null' ;;
        *)  printf '%s' "$1" ;;
    esac
}

# Compact an ISO timestamp to MINUTES precision (YYYYMMDDTHHMM) — the run_id
# grain the design pins (seconds + zone offset dropped; pid disambiguates).
_fr_compact_ts() {
    local ts="$1" compact
    compact="${ts:0:16}"
    compact="${compact//-/}"
    compact="${compact//:/}"
    printf '%s' "$compact"
}

flow_run_id() {
    local flow="${1:-}" fired_at="${2:-}" pid="${3:-}"
    [ -n "$fired_at" ] || fired_at=$(_fr_now_utc)
    [ -n "$pid" ] || pid="$$"
    printf '%s-%s-%s\n' "$flow" "$(_fr_compact_ts "$fired_at")" "$pid"
}

flow_run_row_start() {
    local flow="${1:-}" run_id="${2:-}" fired_at="${3:-}" host="${4:-}" lane="${5:-}" model="${6:-}" task_name="${7:-}" log_path="${8:-}" pid="${9:-}"
    [ -n "$fired_at" ] || fired_at=$(_fr_now_utc)
    printf '{"v":1,"ev":"start","flow":%s,"run_id":%s,"fired_at":%s,"host":%s,"lane":%s,"model":%s,"task_name":%s,"log_path":%s,"pid":%s}' \
        "$(_fr_json_str "$flow")" "$(_fr_json_str "$run_id")" "$(_fr_json_str "$fired_at")" \
        "$(_fr_json_null_str "$host")" "$(_fr_json_null_str "$lane")" "$(_fr_json_null_str "$model")" \
        "$(_fr_json_null_str "$task_name")" "$(_fr_json_null_str "$log_path")" "$(_fr_json_int "$pid")"
}

flow_run_row_end() {
    local flow="${1:-}" run_id="${2:-}" ended_at="${3:-}" exit_code="${4:-}" outcome="${5:-}" items_processed="${6:-}" note="${7:-}"
    [ -n "$ended_at" ] || ended_at=$(_fr_now_utc)
    printf '{"v":1,"ev":"end","flow":%s,"run_id":%s,"ended_at":%s,"exit_code":%s,"outcome":%s,"items_processed":%s,"note":%s}' \
        "$(_fr_json_str "$flow")" "$(_fr_json_str "$run_id")" "$(_fr_json_str "$ended_at")" \
        "$(_fr_json_int "$exit_code")" "$(_fr_json_str "$outcome")" "$(_fr_json_int "$items_processed")" \
        "$(_fr_json_null_str "$note")"
}

# flow_run_classify <exit_code> [log_path] [extra_marker_re] [required_marker]
# required_marker (HIMMEL-1716): when the leg's prompt asks the agent to print
# a bare terminal marker ONLY on genuine completion (PIPELINE-LEG-DONE), a
# zero exit with no such line in the log tail is a leg that parked, was
# blocked on a prompt, or bailed early -- classify it `parked`, never
# `complete`. A missing log counts as no marker. Truncation still wins.
flow_run_classify() {
    local exit_code="${1:-}" log_path="${2:-}" extra_marker_re="${3:-}" required_marker="${4:-}"
    if [ "${exit_code:-0}" != "0" ]; then
        printf 'error\n'
        return 0
    fi
    if [ -n "$log_path" ] && [ -f "$log_path" ]; then
        if tail -n 50 "$log_path" 2>/dev/null | grep -Eq "$FLOW_RUN_TRUNCATION_SIGNATURE_RE"; then
            printf 'truncated\n'
            return 0
        fi
        if [ -n "$extra_marker_re" ] && tail -n 50 "$log_path" 2>/dev/null | grep -Eq "$extra_marker_re"; then
            printf 'truncated\n'
            return 0
        fi
    fi
    if [ -n "$required_marker" ]; then
        if [ -z "$log_path" ] || [ ! -f "$log_path" ] \
            || ! tail -n 50 "$log_path" 2>/dev/null | tr -d '\r' | grep -Fxq -- "$required_marker"; then
            printf 'parked\n'
            return 0
        fi
    fi
    printf 'complete\n'
}

# flow_run_is_transient <exit_code> [log_path]
# rc 0 -> the run FAILED and the current attempt's log carries the transient
# upstream signature: the caller may retry it. rc 1 -> everything else,
# including a zero exit, a missing/unreadable log, and a failure with no
# signature. Fail-closed on purpose: no evidence is not a retry.
flow_run_is_transient() {
    local exit_code="${1:-}" log_path="${2:-}"
    [ "${exit_code:-0}" != "0" ] || return 1
    [ -n "$log_path" ] && [ -f "$log_path" ] || return 1
    # Reset the buffer at every attempt marker, so what reaches grep is the
    # text written after the LAST one (the whole log when a caller stamps no
    # marker at all).
    awk -v m="$FLOW_RUN_ATTEMPT_MARKER" '
        index($0, m) { buf = ""; next }
        { buf = buf $0 "\n" }
        END { printf "%s", buf }
    ' "$log_path" 2>/dev/null | grep -Eq "$FLOW_RUN_TRANSIENT_SIGNATURE_RE"
}

flow_run_append() {
    local line="${1:-}" path dir size
    path=$(flow_run_ledger_path)
    # HIMMEL-2241: a MISSED test redirect must fail LOUD, never silently
    # pollute production telemetry. run-shell-tests.sh exports
    # HIMMEL_SUITE_LOCK_HELD for the whole suite run, so a write reaching here
    # with the marker set and NO explicit override is a fixture spawning a real
    # wrapper that fell back to ~/.himmel/flow-runs.jsonl -- the shape that
    # paged HimmelFlowRunError for runs that never happened. Quarantine the row
    # in the suite's own temp root and say so on stderr. A genuine flow outside
    # any suite has the marker unset and is untouched, and a fixture that DID
    # redirect never reaches this branch.
    if [ -n "${HIMMEL_SUITE_LOCK_HELD:-}" ] && [ -z "${HIMMEL_FLOW_RUNS_LEDGER:-}" ]; then
        path="${TMPDIR:-/tmp}/flow-runs-unredirected.jsonl"
        printf '[flow-run-ledger] HIMMEL-2241 WARN: shell suite running (HIMMEL_SUITE_LOCK_HELD set) with no HIMMEL_FLOW_RUNS_LEDGER override; row quarantined in %s instead of the production ledger. Export HIMMEL_FLOW_RUNS_LEDGER to a scratch path in the fixture that spawned this wrapper.\n' "$path" >&2
    fi
    dir=$(dirname "$path")
    [ -d "$dir" ] || mkdir -p "$dir" 2>/dev/null || true
    if [ -f "$path" ]; then
        size=$(wc -c < "$path" 2>/dev/null | tr -d '[:space:]') || size=0
        case "$size" in ''|*[!0-9]*) size=0 ;; esac
        if [ "$size" -ge "$FLOW_RUN_ROTATE_BYTES" ]; then
            mv -f "$path" "$path.1" 2>/dev/null || true
        fi
    fi
    printf '%s\n' "$line" >> "$path"
}

_fr_emit_append_start() {
    local flow="${1:-}" fired_at="${2:-}" host="${3:-}" lane="${4:-}" model="${5:-}" task_name="${6:-}" log_path="${7:-}" pid="${8:-}" run_id row
    [ -n "$fired_at" ] || fired_at=$(_fr_now_utc)
    [ -n "$pid" ] || pid="$$"
    # Default the host HERE so runner emitters can pass "" instead of baking a
    # fire-time hostname subshell into generated runner text (a literal
    # `uname -n` in a runner trips blanket ` -n ` assertions in the arm-resume
    # suite, and every emitter would repeat the same fallback chain).
    [ -n "$host" ] || host=$(hostname 2>/dev/null || uname -n 2>/dev/null)
    [ -n "$host" ] || host=unknown
    run_id=$(flow_run_id "$flow" "$fired_at" "$pid")
    row=$(flow_run_row_start "$flow" "$run_id" "$fired_at" "$host" "$lane" "$model" "$task_name" "$log_path" "$pid")
    flow_run_append "$row"
    printf '%s\n' "$run_id"
}

_fr_emit_append_end() {
    local row
    row=$(flow_run_row_end "$@")
    flow_run_append "$row"
}

_fr_is_main=0
[ "${BASH_SOURCE[0]:-}" = "${0:-}" ] && _fr_is_main=1
if [ "$_fr_is_main" = "1" ]; then
    case "${1:-}" in
        --emit-start)
            shift
            flow_run_row_start "$@"
            ;;
        --emit-end)
            shift
            flow_run_row_end "$@"
            ;;
        --classify)
            shift
            flow_run_classify "$@"
            ;;
        # Unlike its siblings this verb answers through the EXIT CODE (the
        # generated .bat reads it with `if errorlevel 1`), so it exits here
        # instead of falling through to the unconditional `exit 0` below.
        --is-transient)
            shift
            flow_run_is_transient "$@" && exit 0
            exit 1
            ;;
        --append-start)
            shift
            _fr_emit_append_start "$@"
            ;;
        --append-end)
            shift
            _fr_emit_append_end "$@"
            ;;
        *)
            echo "usage: flow-run-ledger.sh (--emit-start|--emit-end|--classify|--is-transient|--append-start|--append-end) ..." >&2
            exit 2
            ;;
    esac
    exit 0
fi
