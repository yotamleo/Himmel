#!/usr/bin/env bash
# scripts/hermes/invoke.sh — single chokepoint for shelling out to hermes-agent.
#
# Mirror of scripts/gemini/invoke.sh (HIMMEL-158): all himmel entrypoints that
# need a hermes one-shot funnel through here so interpreter/model/toolset
# resolution lives in one place. Story 1 of the hermes critic pipeline
# (HIMMEL-273).
#
# Why not the `hermes` console script: the hermes.exe setuptools wrapper is
# unreliable under non-TTY shells on Windows (spike 2026-06-12 — wrapper runs
# >120s with no output where the module entry answers in seconds). We invoke
# the venv python directly and enter via hermes_cli.main.
#
# Why a prompt FILE (not argv, not stdin): argv hits the Windows spawn
# length limit on large diffs (same issue as HIMMEL-270 for gemini), and
# hermes one-shot runs hung in the spike when stdin was consumed/closed.
# The prompt travels via a temp file read inside the python snippet.
#
# Toolsets: DEFAULT `todo` — hermes -z sets HERMES_YOLO_MODE=1 (auto-approves
# every tool call), so an unconstrained one-shot may execute terminal/browser
# tools with no human in the loop. `todo` is the minimal harmless built-in
# bundle (no fs / terminal / network). Callers that genuinely want tools must
# opt in via --toolsets.
#
# Auth: defers ENTIRELY to hermes (its own .env + config.yaml provider chain,
# HIMMEL-278). No pre-flight credential check here.
#
# No retries. Exits with hermes' return code, UNLESS the watchdog below fires.
#
# Watchdog + deny-escalation (HIMMEL-2025): a parity_guard pre_tool_call DENY
# is not terminal to hermes — hermes' tool_executor.py feeds the block back to
# the model as an ordinary tool result and the agent may retry the same/an
# adjacent action; run_agent.py's max_iterations defaults to sys.maxsize, so an
# unattended run whose every tool call is denied can spin indefinitely, burning
# the bank silently. This chokepoint now bounds every one-shot two ways,
# mirroring dispatch-codex-exec.sh's watchdog (HIMMEL-2023):
#   1. a hard wall-clock timebox (HERMES_INVOKE_TIMEOUT, default 1800s — the
#      hermes-oneshot lane's own timeoutSeconds in scripts/lanes/lanes.json);
#   2. a poll for the deny-escalation marker parity_guard.py writes after N
#      identical (same tool + args hash) denies in a row
#      (PARITY_GUARD_DENY_ESCALATE_N, default 3) — the state directory is
#      created here and handed down via PARITY_GUARD_STATE_DIR so the guard
#      subprocess (a child of the hermes process this launches) can reach it.
# Either condition kills the hermes process TREE (scripts/lib/proc-tree.sh)
# and exits loudly: 124 for a wall-clock timeout (same code GNU `timeout` and
# the codex watchdog use), 125 for a deny-escalation abort. Start/end rows
# land in ~/.himmel/flow-runs.jsonl (scripts/lib/flow-run-ledger.sh),
# outcome complete|error|timeout|denied|truncated (the last added by the
# iteration-budget scan below, HIMMEL-2049).
#
# Iteration-budget truncation (HIMMEL-2049): separately from the watchdog,
# hermes' OWN turn loop can exhaust its "agent.max_turns" iteration budget
# (one API call per iteration; default 500, himmel_agent profile ships 150)
# and still exit 0 — the CLI prints "⚠ Iteration budget reached (N/max) —
# response may be incomplete" to stdout and calls it done. This chokepoint
# scans the captured hermes output for that banner and overrides rc to 126
# (outcome "truncated" in the ledger) so a truncated run can never read as a
# clean rc=0 pass. Knob: agent.max_turns in the profile config.yaml (or the
# legacy root-level max_turns / HERMES_MAX_ITERATIONS env var) — no invoke.sh
# flag for it.
#
# Usage:
#   invoke.sh "PONG"                                   # positional prompt
#   echo "hi" | invoke.sh -                            # read prompt from stdin
#   invoke.sh --model nvidia/nemotron-3-nano-30b-a3b "review this"
#   invoke.sh --prompt-file /tmp/big-pack.txt          # large prompt via file
#   invoke.sh --toolsets coding "do work with tools"
#   invoke.sh --log /tmp/run.log "PONG"
#
# Environment (see also the per-flag Usage section below):
#   HERMES_INVOKE_TIMEOUT       Watchdog wall-clock budget in seconds
#                                (default 1800; ceiling 86400).
#   PARITY_GUARD_DENY_ESCALATE_N  Identical-deny count that aborts the run
#                                (default 3; read by parity_guard.py, inherited
#                                by the hermes subprocess this launches).
#   HIMMEL_FLOW_RUNS_LEDGER     Ledger path override (tests).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

usage() {
    cat >&2 <<'EOF'
Usage: invoke.sh [--model <name>] [--profile <name>] [--toolsets <list>]
                 [--prompt-file <path>] [--log <path>] [<prompt>|-]

  <prompt>           Prompt text. If `-` or omitted (and no --prompt-file),
                     read from stdin.
  --model <name>     Model override (hermes -m). Default: hermes config default.
  --provider <name>  Provider override (hermes --provider). Needed when the
                     model id is newer than hermes' internal catalog — without
                     it hermes silently routes unknown ids to its DEFAULT
                     provider (observed: an OpenRouter :free id landing on
                     codex, HIMMEL-727). Omit to keep hermes' own routing.
  --profile <name>   Run under this hermes profile (hermes -p), i.e. its SOUL +
                     config (e.g. himmel_agent = senior main-tier reviewer). Fail-
                     open: if the profile does not exist, warn and use the default
                     profile rather than error (hermes itself exits 1 on a missing
                     profile, which must never break a CR one-shot).
  --toolsets <list>  Comma-separated hermes toolsets. Default: todo (minimal,
                     harmless — hermes one-shot auto-approves tool calls).
  --prompt-file <p>  Read the prompt from this file (large packs / diffs).
  --log <path>       Tee stdout + stderr to this log file.

Environment:
  HERMES_PY          Override the python interpreter used to run hermes
                     (default: %LOCALAPPDATA%/hermes/hermes-agent/venv python;
                     tests inject a stub through this).
EOF
}

model=""
provider=""
profile=""
toolsets="todo"
prompt_file=""
log=""
prompt=""
prompt_set=0

while [ $# -gt 0 ]; do
    case "$1" in
        --model)
            [ $# -ge 2 ] || { echo "invoke.sh: --model requires a value" >&2; exit 2; }
            model="$2"; shift 2 ;;
        --provider)
            [ $# -ge 2 ] || { echo "invoke.sh: --provider requires a value" >&2; exit 2; }
            provider="$2"; shift 2 ;;
        --profile)
            [ $# -ge 2 ] || { echo "invoke.sh: --profile requires a value" >&2; exit 2; }
            profile="$2"; shift 2 ;;
        --toolsets)
            [ $# -ge 2 ] || { echo "invoke.sh: --toolsets requires a value" >&2; exit 2; }
            toolsets="$2"; shift 2 ;;
        --prompt-file)
            [ $# -ge 2 ] || { echo "invoke.sh: --prompt-file requires a value" >&2; exit 2; }
            prompt_file="$2"; shift 2 ;;
        --log)
            [ $# -ge 2 ] || { echo "invoke.sh: --log requires a value" >&2; exit 2; }
            log="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        -)
            prompt_set=0; shift ;;
        --)
            shift
            if [ $# -gt 0 ]; then prompt="$1"; prompt_set=1; shift; fi
            break ;;
        -*)
            echo "invoke.sh: unknown flag: $1" >&2; usage; exit 2 ;;
        *)
            prompt="$1"; prompt_set=1; shift ;;
    esac
done

# Resolve the prompt source: --prompt-file wins, else positional, else stdin.
tmp_prompt=""
# Watchdog/deny-escalation state (HIMMEL-2025), declared up front (set -u
# safe) so the trap never trips on an early exit before they are assigned.
watch_pid=""
timeout_flag=""
state_dir=""
scratch_log=""
# shellcheck disable=SC2317,SC2329  # invoked indirectly via the EXIT trap (SC2329 = the renamed "function never invoked" check)
cleanup() {
    [ -n "$tmp_prompt" ] && rm -f "$tmp_prompt"
    if [ -n "$watch_pid" ]; then
        kill -TERM -"$watch_pid" 2>/dev/null || kill -TERM "$watch_pid" 2>/dev/null
        wait "$watch_pid" 2>/dev/null
    fi
    [ -n "$timeout_flag" ] && rm -f "$timeout_flag" 2>/dev/null
    [ -n "$state_dir" ] && rm -rf "$state_dir" 2>/dev/null
    [ -n "$scratch_log" ] && rm -f "$scratch_log" 2>/dev/null
}
trap cleanup EXIT

if [ -n "$prompt_file" ]; then
    [ -f "$prompt_file" ] || { echo "invoke.sh: prompt file not found: $prompt_file" >&2; exit 2; }
    [ -s "$prompt_file" ] || { echo "invoke.sh: prompt file is empty: $prompt_file" >&2; exit 2; }
else
    if [ "$prompt_set" -eq 0 ]; then
        prompt="$(cat)"
    fi
    if [ -z "$prompt" ]; then
        echo "invoke.sh: empty prompt (none given and stdin was empty)" >&2
        exit 2
    fi
    tmp_prompt="$(mktemp "${TMPDIR:-/tmp}/hermes-prompt.XXXXXX")"
    printf '%s' "$prompt" > "$tmp_prompt"
    prompt_file="$tmp_prompt"
fi

# Resolve the hermes interpreter at RUNTIME via the shared resolver (HIMMEL-613):
# HERMES_PY overrides (tests stub through it) ONLY when it still points at an
# executable, else probe the venv — a moved/rebuilt venv re-resolves instead of
# breaking on a stale path.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/resolve-hermes-py.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/resolve-hermes-py.sh"
py="$(resolve_hermes_py)" || py=""
if [ -z "$py" ]; then
    echo "invoke.sh: hermes interpreter not found (set HERMES_PY or install hermes)" >&2
    exit 3
fi

# Watchdog (HIMMEL-2025): the run-shell-tests.sh/codex timeout convention —
# see scripts/codex/dispatch-codex-exec.sh Invariant 8.
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/flow-run-ledger.sh"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/proc-tree.sh"

invoke_timeout="${HERMES_INVOKE_TIMEOUT:-1800}"
case "$invoke_timeout" in
    ''|*[!0-9]*|0) echo "invoke.sh: HERMES_INVOKE_TIMEOUT must be a positive integer number of seconds, got '$invoke_timeout'" >&2; exit 2 ;;
esac
# Length guard first: a >6-digit string overflows bash's own `-gt` integer
# conversion (error rc, which `||` would misread as "not too large") — mirrors
# dispatch-codex-exec.sh's CODEX_EXEC_TIMEOUT ceiling check exactly.
if [ "${#invoke_timeout}" -gt 6 ] || [ "$invoke_timeout" -gt 86400 ]; then
    echo "invoke.sh: HERMES_INVOKE_TIMEOUT=$invoke_timeout exceeds the 86400s (1 day) ceiling — refusing" >&2
    exit 2
fi

# Deny-escalation state dir (HIMMEL-2025): handed to the hermes subprocess (and
# transitively to every parity_guard.py invocation it spawns) via
# PARITY_GUARD_STATE_DIR so the guard can persist an identical-deny counter
# across the many pre_tool_call calls one hermes run makes, and signal an
# abort by writing "$state_dir/abort". Best-effort: a failure here only
# disables the deny-escalation safety net, not the core allow/block verdict or
# the wall-clock timebox below, so it does not refuse the dispatch.
state_dir="$(mktemp -d "${TMPDIR:-/tmp}/hermes-guard-state.XXXXXX" 2>/dev/null)" || state_dir=""
abort_marker=""
if [ -n "$state_dir" ]; then
    export PARITY_GUARD_STATE_DIR="$state_dir"
    abort_marker="$state_dir/abort"
else
    # Don't let a stale/foreign PARITY_GUARD_STATE_DIR from the ambient
    # environment leak through when OUR state dir failed to create — the
    # documented contract is "unset -> escalation is inert".
    unset PARITY_GUARD_STATE_DIR
fi

# The watchdog flag file: created empty, non-empty means "the watchdog fired"
# (dispatch-codex-exec.sh's own idiom). A failure here REFUSES rather than
# degrades — without it a kill still happens but this shell could not tell you
# it did, which is the unobservable failure this ticket exists to close.
timeout_flag="$(mktemp "${TMPDIR:-/tmp}/hermes-watchdog.XXXXXX" 2>/dev/null)" || timeout_flag=""
if [ -z "$timeout_flag" ]; then
    echo "invoke.sh: cannot create the watchdog flag file (mktemp failed; TMPDIR=${TMPDIR:-<unset>}) — refusing to run hermes with an unreadable watchdog verdict" >&2
    exit 2
fi

# Capture sink for the iteration-budget scan below (HIMMEL-2049): hermes'
# own banner ("Iteration budget reached (N/max) — response may be
# incomplete") prints to stdout but hermes still exits 0, so this chokepoint
# needs the text to grep after the run, not just its rc. Reuse --log's tee
# destination when given; otherwise tee to a throwaway scratch file so
# detection works uninstrumented too.
capture_log="$log"
if [ -z "$capture_log" ]; then
    scratch_log="$(mktemp "${TMPDIR:-/tmp}/hermes-invoke-cap.XXXXXX" 2>/dev/null)" || scratch_log=""
    capture_log="$scratch_log"
fi
# Same fail-closed contract as the watchdog flag above: a silent fail-open
# here would run hermes with no working capture, and a genuine
# iteration-budget exit would then read as a clean rc 0 again — the exact
# unobservable failure this ticket exists to close (CR finding codex-1,
# HIMMEL-2049). Covers both an mktemp failure (scratch path, above) AND a
# --log destination that cannot actually be written (e.g. a bad directory) —
# a caller-supplied --log path is not otherwise validated before this.
# Checked HERE, before the ledger start row below (CR finding codex-1 round
# 3) — the same reason the watchdog-flag check above also precedes it: a
# refusal after the start row would append a "start" with no matching "end",
# leaving the run looking merely unfinished rather than refused.
# Residual (declined, round 5): this proves the destination is writable NOW,
# not that later writes during the run will still succeed (e.g. the
# filesystem fills up mid-run) — a TOCTOU gap. That is the same class of
# best-effort guarantee the timeout_flag/state_dir mktemp checks above
# already accept for this whole script; monitoring free space through a run
# is out of scope here and not something any other chokepoint in this repo
# does either.
if [ -z "$capture_log" ] || ! : > "$capture_log" 2>/dev/null; then
    echo "invoke.sh: cannot write a capture file for the iteration-budget scan ('${capture_log:-<mktemp failed>}'; TMPDIR=${TMPDIR:-<unset>}) — refusing to run hermes with an unobservable truncation verdict" >&2
    exit 2
fi

# Windows-native python needs a Windows path for the prompt file.
pf_native="$prompt_file"
if command -v cygpath >/dev/null 2>&1; then
    pf_native="$(cygpath -w "$prompt_file")"
fi

# Profile selection (HIMMEL-558): pass `-p <profile>` so the one-shot runs under
# that profile's SOUL + config (e.g. himmel_agent = the senior main-tier reviewer
# persona, NOT the user-default junior SOUL). FAIL-OPEN guard: hermes exits 1 on a
# missing profile, which would break a CR one-shot — so only forward -p when the
# profile directory exists; otherwise warn and let hermes use its default profile.
# `default` is always valid (it is the hermes root itself, no profiles/ subdir).
profile_arg=""
if [ -n "$profile" ]; then
    _hh="${HERMES_HOME:-}"
    if [ -z "$_hh" ]; then
        if [ -n "${LOCALAPPDATA:-}" ]; then _hh="$LOCALAPPDATA/hermes"; else _hh="$HOME/.local/share/hermes"; fi
    fi
    if [ "$profile" = "default" ] || [ -d "$_hh/profiles/$profile" ]; then
        profile_arg="$profile"
    else
        echo "invoke.sh: hermes profile '$profile' not found under $_hh/profiles — using default profile" >&2
    fi
fi

run_hermes() {
    HERMES_PROMPT_FILE="$pf_native" HERMES_ONESHOT_MODEL="$model" HERMES_ONESHOT_PROVIDER="$provider" HERMES_ONESHOT_PROFILE="$profile_arg" HERMES_ONESHOT_TOOLSETS="$toolsets" \
    "$py" -c '
import os, sys, io
with io.open(os.environ["HERMES_PROMPT_FILE"], encoding="utf-8") as fh:
    prompt = fh.read()
argv = ["hermes", "--cli"]
model = os.environ.get("HERMES_ONESHOT_MODEL", "")
provider = os.environ.get("HERMES_ONESHOT_PROVIDER", "")
profile = os.environ.get("HERMES_ONESHOT_PROFILE", "")
toolsets = os.environ.get("HERMES_ONESHOT_TOOLSETS", "")
if profile:
    argv += ["-p", profile]
if model:
    argv += ["-m", model]
if provider:
    argv += ["--provider", provider]
if toolsets:
    argv += ["-t", toolsets]
argv += ["-z", prompt]
sys.argv = argv
from hermes_cli.main import main
main()
'
}

# HIMMEL-729 wiring chunk B — best-effort Alibaba quota-gauge probe piggybacked
# on a qwen* dispatch. Fire-and-forget: backgrounded, all output to /dev/null,
# NEVER blocks or fails the dispatch (it cannot reach the dispatch rc). The
# runner self-throttles (60s freshness marker) and skips silently when the
# Alibaba env vars are unset. Invoke-only — no always-on surface. The shell edit
# stays minimal; the logic lives in the TS runner (scripts/telegram/alibaba-probe-once.ts).
alibaba_quota_piggyback() {
    [ -n "$model" ] || return 0
    case "$model" in
        [Qq][Ww][Ee][Nn]*) : ;;  # qwen* (qwen-plus, qwen3-coder-plus, …) — case-insensitive
        *) return 0 ;;
    esac
    command -v bun >/dev/null 2>&1 || return 0
    local runner="$SCRIPT_DIR/../telegram/alibaba-probe-once.ts"
    [ -f "$runner" ] || return 0
    ( bun "$runner" >/dev/null 2>&1 || true ) &   # detached; never affects the dispatch
    disown 2>/dev/null || true
}

# Ledger start row BEFORE the spawn, so a run that dies without a normal end
# row still shows up as having started (flow-run-ledger.sh convention).
started_at="$(date +%s)"
run_id="hermes-invoke-${started_at}-$$"
flow_run_append "$(flow_run_row_start "hermes-invoke" "$run_id" "" "$(hostname 2>/dev/null || echo unknown)" "hermes-invoke" "${model:-default}" "$PWD" "${log:-}" "$$")"

# `set -m` gives the backgrounded run_hermes its own process group, which is
# what lets the watchdog's group signal reach hermes' descendants (proc-tree's
# USAGE contract). `>(tee "$capture_log")` (process substitution, not a pipe)
# keeps run_hermes as the ONE backgrounded job so `$!` names it directly,
# instead of a pipeline's last stage — the same reason dispatch-codex-exec.sh
# never pipes its watched child either.
set -m
if [ -n "$capture_log" ]; then
    run_hermes > >(tee "$capture_log") 2>&1 &
else
    run_hermes &
fi
hermes_pid=$!
( while :; do
    # Alive-check FIRST (dispatch-codex-exec.sh idiom): rc 1 = confirmed the
    # child already exited before this tick — nothing to kill, nothing to
    # claim. Checking before the abort/timeout branches (not after) is what
    # keeps a run that finishes right at the deadline from being misreported
    # as a kill (CR round 1 finding).
    proc_tree_process_alive "$hermes_pid"
    [ "$?" -eq 1 ] && exit 0
    if [ -n "$abort_marker" ] && [ -e "$abort_marker" ]; then
        printf 'denied' > "$timeout_flag"
        proc_tree_terminate "$hermes_pid" >&2
        exit 0
    fi
    now="$(date +%s)"
    if [ $((now - started_at)) -ge "$invoke_timeout" ]; then
        printf 'timeout' > "$timeout_flag"
        proc_tree_terminate "$hermes_pid" >&2
        exit 0
    fi
    sleep 1
done ) &
watch_pid=$!
set +m

wait "$hermes_pid"
rc=$?

# Whether to stand the watchdog down depends on why hermes is gone: if it is
# the reason (flag already set), it may be mid-escalation — let it finish
# rather than cancelling a kill in flight. Otherwise it is still polling;
# cancel it (group signal first so its own `sleep` goes too).
if [ -s "$timeout_flag" ]; then
    wait "$watch_pid" 2>/dev/null
else
    kill -TERM -"$watch_pid" 2>/dev/null || kill -TERM "$watch_pid" 2>/dev/null
    wait "$watch_pid" 2>/dev/null
fi
watch_pid=""

# `wait "$hermes_pid"` above only waits for run_hermes itself — the `tee`
# reading the OTHER end of the `>(tee "$capture_log")` process substitution
# is a separate async job that may not have flushed the banner's final bytes
# yet (CR finding codex-2, HIMMEL-2049). hermes_pid and watch_pid are both
# reaped by this point, so a bare `wait` here can only be waiting on that
# tee (if one is open), before the budget scan below reads the file.
wait 2>/dev/null

flag_reason="$(cat "$timeout_flag" 2>/dev/null || true)"
case "$flag_reason" in
    timeout)
        rc=124
        echo "invoke.sh: TIMEOUT after ${invoke_timeout}s — killed hermes process tree (raise the budget with HERMES_INVOKE_TIMEOUT)" >&2
        flow_run_append "$(flow_run_row_end "hermes-invoke" "$run_id" "" 124 timeout 1 "")"
        ;;
    denied)
        deny_reason="$(cat "$abort_marker" 2>/dev/null || true)"
        rc=125
        echo "invoke.sh: ABORTED — parity_guard denied the same tool call repeatedly (${deny_reason:-no reason captured}); killed hermes process tree" >&2
        flow_run_append "$(flow_run_row_end "hermes-invoke" "$run_id" "" 125 denied 1 "$deny_reason")"
        ;;
    *)
        # HIMMEL-2049: hermes' own CLI still exits 0 when it hits its
        # iteration budget mid-run (the "summarize what you have" fallback
        # still counts as a clean process exit) — the only signal is this
        # banner in its stdout. Scan the captured output for it and override
        # the rc, since a silent rc=0 here is exactly what let a truncated
        # run pass as complete.
        # Anchored to the COMPLETE known banner lines (numbers + the
        # differentiating trailing clause each of hermes' 3 emission sites
        # uses — cli.py's final print, turn_finalizer.py's status emit and
        # its own print), not just the "Iteration budget (…) (N/max)"
        # fragment — a bare fragment match could also fire on a model
        # response that merely discusses or paraphrases hermes' own budget
        # mechanism (CR finding codex-2, HIMMEL-2049). Residual (declined,
        # round 4): a response that quotes hermes' full, exact banner line —
        # numbers and differentiating suffix both — is still indistinguishable
        # from the CLI actually emitting it. The ticket's ask is text-scanning
        # stdout/stderr; a structured completion signal would need an
        # upstream hermes API this one-shot chokepoint does not have, and
        # hermes' own ANSI markup around the banner is not reliably present
        # under non-TTY redirection (unverified without a live run, which
        # this ticket's contract rules out) to use as a further anchor.
        # Narrowed further (CR finding codex-1, round 6): hermes only ever
        # emits the banner right before the process exits, never mid-response
        # — so scan just the TAIL of the capture, not the whole file. A model
        # response that happens to discuss/quote the banner deep inside a
        # longer answer now falls outside the scanned window; only a match in
        # the run's last few lines (where the CLI's own banner always lands)
        # still counts.
        budget_line=""
        if [ -n "$capture_log" ] && [ -f "$capture_log" ]; then
            budget_line="$(tail -n 20 "$capture_log" 2>/dev/null | grep -Eo 'Iteration budget (reached|exhausted) \([0-9]+/[0-9]+\) — (response may be incomplete|asking model to summarise|requesting summary\.\.\.)' | tail -1)"
        fi
        if [ -n "$budget_line" ]; then
            rc=126
            echo "invoke.sh: TRUNCATED — hermes hit its iteration budget (${budget_line}) — the response may be incomplete (knob: agent.max_turns in the profile config.yaml, or HERMES_MAX_ITERATIONS)" >&2
            flow_run_append "$(flow_run_row_end "hermes-invoke" "$run_id" "" 126 truncated 1 "$budget_line")"
        else
            outcome=complete
            [ "$rc" -eq 0 ] || outcome=error
            flow_run_append "$(flow_run_row_end "hermes-invoke" "$run_id" "" "$rc" "$outcome" 1 "")"
        fi
        ;;
esac

alibaba_quota_piggyback   # best-effort, fire-and-forget, never touches rc
exit "$rc"
