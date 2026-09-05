#!/usr/bin/env bash
# scripts/codex/dispatch-codex-exec.sh - the codex-exec lane's dispatch
# chokepoint (HIMMEL-781, follow-up to the HIMMEL-741 diagnosis).
#
# WHY: the lane's safety requirements must be structural, not prose (the
# lanes.json row alone cannot enforce them). This wrapper encodes the
# HIMMEL-741 invariants at the single entry point (arg checks run first,
# then the preflight, then codex - nothing reaches codex unchecked):
#   1. ACL preflight: normalize-worktree-acl.sh <worktree> runs before the
#      codex CLI is invoked and aborts the dispatch on failure (Windows
#      aged-worktree SID gap; the preflight is a no-op on other platforms).
#   2. Model pinned to gpt-5.5 unless the caller names one explicitly
#      (codex-variant model names 400 under ChatGPT-plan auth).
#   3. --background refused (upstream: background jobs die silently; use the
#      default --wait behavior + scripts/codex/companion-liveness.sh).
#   4. Workspace-redirect (-C/--cd/--add-dir) and sandbox-widening flags
#      refused - the preflight covers only the dispatched worktree.
#   5. Shared-branch mode (--shared-branch, HIMMEL-800), opt-in: the caller
#      names an EXISTING branch the worktree must already be checked out on
#      (the caller states intent, the wrapper verifies reality - branch
#      match, never main/master, no uncommitted changes). On success the
#      wrapper acquires the single-writer lock (scripts/lib/shared-branch-
#      lock.sh) for the duration of the codex run so parallel lanes cannot
#      write the shared branch concurrently, and releases it on every
#      CATCHABLE exit path (an EXIT trap; a SIGKILL/hard-kill cannot be
#      trapped, so recover a leaked lock manually with the helper's release
#      verb). Exit 4 = the lock is held by another writer; recovery is the
#      lock helper's own release verb (see scripts/codex/README.md).
#      Default posture (no --shared-branch) is unchanged: own worktree, own
#      throwaway branch, no lock.
#   6. Job registry + descendant reap (HIMMEL-840): the codex-exec CLI sandbox
#      leaks its own MCP-server fleet (npx/node children under cmd.exe
#      wrappers) that the HIMMEL-741 app-server fingerprint cannot see (no
#      codex path marker survives on those processes once codex.exe is gone).
#      This wrapper now ALWAYS runs codex as a child (never exec's it, in
#      either path - exec would drop the trap below), records the child pid
#      under CODEX_JOBS_DIR right after it starts, and on EXIT reaps the
#      child's still-live descendants via reap-mcp-fleet.{sh,ps1} before
#      removing the registry entry. A stale registry entry (dispatcher killed
#      before its own EXIT trap ran) is still visible to reap-mcp-fleet's
#      registry-driven maintenance mode.
#   7. Reasoning-effort passthrough (HIMMEL-905), opt-in: the caller may pass
#      --reasoning-effort <value> or --reasoning-effort=<value> with value in
#      none|low|medium|high|xhigh|max. The codex CLI has no native flag for
#      this - the wrapper validates the enum, strips the raw flag from the
#      passthrough, and translates it into a trusted `-c
#      model_reasoning_effort="<value>"` override appended to pin_args (the
#      caller-supplied `-c`/`--config` flag itself stays refused above; only
#      this wrapper-computed override is emitted). Does NOT change the
#      model pin below - GPT-5.6 availability is not verified in-repo, so
#      gpt-5.5 stays pinned; this flag only lets a gpt-5.5 (or a caller-named
#      model) run at a non-default reasoning effort.
#   8. Watchdog + ledger (HIMMEL-2023, HIMMEL-1788 instance 5): the wait below
#      used to be UNBOUNDED, so a wedged headless run was invisible - no
#      timeout, no kill, and (unlike the codex-wsl twin) no flow-run-ledger
#      row to show it had even started. Now:
#        - the run is timeboxed to CODEX_EXEC_TIMEOUT (default 1800s, the
#          codex-exec lane's own `timeoutSeconds` in scripts/lanes/lanes.json
#          - registry METADATA that nothing used to enforce; the suite pins
#          the two together so they cannot drift apart silently);
#        - on expiry the process TREE is killed via scripts/lib/proc-tree.sh
#          (group signal, verified, Windows taskkill fallback), the dispatch
#          exits 124 - the code GNU `timeout` and run-shell-tests.sh already
#          use - and says so on stderr;
#        - start/end rows land in ~/.himmel/flow-runs.jsonl exactly as
#          dispatch-codex-wsl.sh writes them, outcome complete|timeout|error;
#        - the job-registry JSON is PRESERVED under $CODEX_JOBS_DIR/failed/
#          on a timeout or a nonzero exit instead of being deleted by the
#          EXIT trap, so the forensic trace outlives the failure. It leaves
#          the live-jobs glob ($JOBS_DIR/*.json) so reap-mcp-fleet's
#          maintenance scan does not re-report a dead job forever.
#      STDIN: `codex exec` reads stdin to EOF even when the prompt is argv
#      ("Reading additional input from stdin..."), so an INHERITED TTY blocks
#      forever before a token is spent. A terminal is never a brief - when
#      stdin is a tty the child gets </dev/null; a genuinely piped/redirected
#      brief still crosses as the caller's own stdin (see the <&0 note below).
#
# Usage:
#   dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [--reasoning-effort <none|low|medium|high|xhigh|max>] [codex exec args...]
#
# Exit: 0 codex rc | 2 usage/refusal | 4 lock held | 124 watchdog timeout | 127 no codex
#
# Environment:
#   CODEX_BIN            Override the codex CLI (tests inject a stub).
#   CODEX_ACL_NORMALIZE  Override the preflight script path (tests).
#   SBL_HELPER           Override the shared-branch-lock.sh path (tests).
#   CODEX_JOBS_DIR        Override the job registry dir (tests; default
#                         $HOME/.himmel/state/codex-exec-jobs).
#   CODEX_REAP_HELPER     Override the reap-mcp-fleet.sh path (tests).
#   CODEX_EXEC_TIMEOUT    Watchdog budget in seconds (default 1800 = the
#                         codex-exec lane's timeoutSeconds).
#   HIMMEL_FLOW_RUNS_LEDGER  Ledger path override (the flow-run-ledger lib's
#                         own var; tests point it at a temp file).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="${CODEX_ACL_NORMALIZE:-$SCRIPT_DIR/normalize-worktree-acl.sh}"
CODEX="${CODEX_BIN:-codex}"
LOCK_HELPER="${SBL_HELPER:-$SCRIPT_DIR/../lib/shared-branch-lock.sh}"
JOBS_DIR="${CODEX_JOBS_DIR:-$HOME/.himmel/state/codex-exec-jobs}"
REAP_HELPER="${CODEX_REAP_HELPER:-$SCRIPT_DIR/reap-mcp-fleet.sh}"
# Invariant 8: the lane's timeoutSeconds, overridable per dispatch. Kept as a
# literal default rather than parsed out of lanes.json so the chokepoint has
# no JSON-reader dependency on its hot path; test-dispatch-codex-exec.sh
# asserts the two match, which is what actually prevents the drift.
EXEC_TIMEOUT="${CODEX_EXEC_TIMEOUT:-1800}"

# HIMMEL-999: the passthrough-args filter is shared with dispatch-codex-wsl.sh.
# shellcheck source=codex-arg-filter.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/codex-arg-filter.sh"
# Invariant 8: the ledger the codex-wsl twin already writes, and the ONE
# process-tree kill (HIMMEL-1338) - never a hand-rolled taskkill here.
# shellcheck source=../lib/flow-run-ledger.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/flow-run-ledger.sh"
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/proc-tree.sh"

usage() {
    echo "usage: dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [codex exec args...]" >&2
    exit 2
}

# codex-adv-style minimal JSON string escaping (backslash, quote) - mirrors
# shared-branch-lock.sh's _sbl_json_escape. Worktree paths on Windows carry
# backslashes that must not break the registry file's JSON.
_json_escape() {
    printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

# Invariant 6 state, initialized up front (set -u safe) and read by the
# single composed EXIT trap below regardless of which early-exit path fires.
# WORKTREE/SHARED_BRANCH are declared here too (ahead of their normal parsing
# spot below) so the trap never trips set -u on an early usage() exit.
WORKTREE=""
SHARED_BRANCH=""
LOCK_ACQUIRED=""
CODEX_CHILD_PID=""
JOB_FILE=""
STARTED_AT=""
# Invariant 8 state.
RUN_ID=""
LEDGER_STARTED=""
EFFECTIVE_MODEL=""
CODEX_RC=""
WATCH_PID=""
TIMEOUT_FLAG=""

# Invariant 8: one end row per started run, emitted exactly once. `outcome`
# is explicit for the timeout path; otherwise derived from the exit code the
# same way the codex-wsl twin derives it.
_emit_end_row() {
    local rc="$1" outcome="${2:-}"
    if [ -z "$outcome" ]; then
        outcome="complete"
        [ "$rc" -eq 0 ] 2>/dev/null || outcome="error"
    fi
    flow_run_append "$(flow_run_row_end "codex-exec" "$RUN_ID" "" "$rc" "$outcome" 1 "")"
    LEDGER_STARTED=""
}

# Invariant 8: keep the registry entry as evidence instead of deleting it.
# Moved into failed/ rather than left in place so reap-mcp-fleet's live-jobs
# glob ($JOBS_DIR/*.json) does not keep re-reporting a job that is already
# dead. Clearing JOB_FILE disarms the EXIT trap's rm for this dispatch.
# A failed move still keeps the evidence (JOB_FILE is cleared either way, so
# the trap's rm never fires on it) but leaves it in the LIVE glob, where
# reap-mcp-fleet's maintenance scan will keep reporting a job that is already
# dead. Evidence beats glob hygiene, so the file stays - but say so, because a
# silently-degraded preserve is the exact shape this whole invariant exists to
# remove (panel codex-3).
_preserve_job_file() {
    [ -n "$JOB_FILE" ] && [ -f "$JOB_FILE" ] || return 0
    if ! { mkdir -p "$JOBS_DIR/failed" 2>/dev/null \
        && mv -f "$JOB_FILE" "$JOBS_DIR/failed/$(basename "$JOB_FILE")" 2>/dev/null; }; then
        echo "dispatch-codex-exec.sh: WARN could not move the job registry entry to $JOBS_DIR/failed/ - keeping it at $JOB_FILE instead (evidence preserved; reap-mcp-fleet's maintenance scan will report it as a dead job until removed)" >&2
    fi
    JOB_FILE=""
}

# Single composed EXIT trap (HIMMEL-800 lock-release + HIMMEL-840 fleet-reap).
# Registered once, up front, so every early-exit path (usage errors, deny-
# listed flags, preflight failure) also runs it - each branch below is a
# no-op until its guard var is actually set, so nothing fires for a dispatch
# that never reached codex.
# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT`
_dispatch_cleanup() {
    if [ -n "$WATCH_PID" ]; then
        kill -TERM -"$WATCH_PID" 2>/dev/null || kill -TERM "$WATCH_PID" 2>/dev/null
        wait "$WATCH_PID" 2>/dev/null
    fi
    if [ -n "$SHARED_BRANCH" ] && [ -n "$LOCK_ACQUIRED" ]; then
        bash "$LOCK_HELPER" release "$WORKTREE" "$SHARED_BRANCH"
    fi
    # Invariant 8: an abnormal-but-catchable exit between the start row and
    # the normal end row would otherwise leave a dangling start (the ledger's
    # own "still running" reading). Emit the end row here too - _emit_end_row
    # clears LEDGER_STARTED, so the normal path never double-writes.
    if [ -n "$LEDGER_STARTED" ]; then
        _emit_end_row "${CODEX_RC:-1}"
    fi
    [ -n "$TIMEOUT_FLAG" ] && rm -f "$TIMEOUT_FLAG" 2>/dev/null
    if [ -n "$CODEX_CHILD_PID" ]; then
        bash "$REAP_HELPER" --root-pid "$CODEX_CHILD_PID" --started-at "$STARTED_AT" --kill || true
        [ -n "$JOB_FILE" ] && rm -f "$JOB_FILE" 2>/dev/null
    fi
    return 0
}
trap _dispatch_cleanup EXIT

# Invariant 8: a malformed budget must REFUSE, never silently degrade back to
# the unbounded wait this invariant exists to remove. The upper bound is not
# cosmetic: a digit string too large for `sleep` makes it exit IMMEDIATELY with
# "invalid time interval", which the watchdog would read as its budget having
# elapsed and kill a run that had just started (panel r3, dropped citation).
# 86400 = one day; a codex dispatch budget beyond that is a typo, not intent.
case "$EXEC_TIMEOUT" in
    ''|*[!0-9]*|0) echo "dispatch-codex-exec.sh: CODEX_EXEC_TIMEOUT must be a positive integer number of seconds, got '$EXEC_TIMEOUT'" >&2; exit 2 ;;
esac
# The length test comes FIRST and is not redundant: `[ <20-digit> -gt … ]`
# overflows bash's own integer conversion and returns an ERROR rc, which the
# `||` would read as "not too large" - letting through exactly the value this
# ceiling exists to refuse. Anything over 6 digits is already past 86400.
if [ "${#EXEC_TIMEOUT}" -gt 6 ] || [ "$EXEC_TIMEOUT" -gt 86400 ]; then
    echo "dispatch-codex-exec.sh: CODEX_EXEC_TIMEOUT=$EXEC_TIMEOUT exceeds the 86400s (1 day) ceiling - refusing (a value sleep cannot parse would fire the watchdog instantly and kill the run)" >&2
    exit 2
fi

if [ "${1:-}" = "--worktree" ]; then
    [ -n "${2:-}" ] || usage
    WORKTREE="$2"
    shift 2
fi
[ -n "$WORKTREE" ] || usage
[ -d "$WORKTREE" ] || { echo "dispatch-codex-exec.sh: worktree not found: $WORKTREE" >&2; exit 2; }

if [ "${1:-}" = "--shared-branch" ]; then
    [ -n "${2:-}" ] || usage
    SHARED_BRANCH="$2"
    shift 2
fi

# codex-adv r5: an arbitrary existing directory must not become a
# workspace-write codex workspace (the ACL preflight no-ops off-Windows, so it
# is not the path constraint). Canonicalize and require a .claude/worktrees
# path - the same containment rule normalize-worktree-acl.ps1 enforces.
# pwd -P (codex-adv final round): logical pwd would let a symlink/junction
# placed under .claude/worktrees satisfy the string check while the physical
# target lives outside it. Dispatch uses the PHYSICAL path too.
WT_ABS="$(cd "$WORKTREE" 2>/dev/null && pwd -P)" || { echo "dispatch-codex-exec.sh: cannot resolve worktree: $WORKTREE" >&2; exit 2; }
case "$WT_ABS" in
    */.claude/worktrees/*) ;;
    *) echo "dispatch-codex-exec.sh: refusing worktree outside .claude/worktrees: $WT_ABS (the lane dispatches only into repo worktrees)" >&2; exit 2 ;;
esac
WORKTREE="$WT_ABS"

# Invariant 5 (HIMMEL-800): shared-branch mode gate. Trunk is checked FIRST
# and unconditionally - main/master is refused as the requested branch
# regardless of what the worktree actually has checked out (fail fast on an
# obviously-wrong request before doing any git introspection). Then the
# caller's stated intent is verified against reality (branch match), then
# the tree must be clean - a shared handoff starts from committed state,
# not an ambient local diff a concurrent writer would never see.
if [ -n "$SHARED_BRANCH" ]; then
    case "$SHARED_BRANCH" in
        main|master) echo "dispatch-codex-exec.sh: --shared-branch refuses trunk branch '$SHARED_BRANCH' - never point a worker at main/master" >&2; exit 2 ;;
    esac
    CURRENT_BRANCH="$(git -C "$WORKTREE" rev-parse --abbrev-ref HEAD 2>/dev/null)" || { echo "dispatch-codex-exec.sh: cannot resolve the checked-out branch for $WORKTREE" >&2; exit 2; }
    if [ "$CURRENT_BRANCH" != "$SHARED_BRANCH" ]; then
        echo "dispatch-codex-exec.sh: --shared-branch '$SHARED_BRANCH' does not match the worktree's checked-out branch '$CURRENT_BRANCH' - the caller names the intent, the wrapper verifies the reality" >&2
        exit 2
    fi
    WT_STATUS="$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" || { echo "dispatch-codex-exec.sh: cannot determine worktree status for $WORKTREE" >&2; exit 2; }
    if [ -n "$WT_STATUS" ]; then
        echo "dispatch-codex-exec.sh: --shared-branch '$SHARED_BRANCH' refused - worktree has uncommitted changes (shared handoff starts from committed state)" >&2
        exit 2
    fi
fi

if ! codex_filter_passthrough_args "$@"; then
    exit 2
fi
have_model="$CAF_HAVE_MODEL"
have_sandbox="$CAF_HAVE_SANDBOX"
reasoning_effort="$CAF_REASONING_EFFORT"
NEW_ARGS=()
if [ "${#CAF_NEW_ARGS[@]}" -gt 0 ]; then
    NEW_ARGS=("${CAF_NEW_ARGS[@]}")
fi
# Rebuild the positional args with --reasoning-effort/its value stripped
# (codex has no native flag for it - Invariant 7 translates it to -c below).
# The count guard avoids "${NEW_ARGS[@]}" on a zero-element array, which
# is an unbound-variable error under `set -u` on pre-4.4 bash (macOS ships
# 3.2 - this script is Bash 3.2 safe).
if [ "${#NEW_ARGS[@]}" -gt 0 ]; then
    set -- "${NEW_ARGS[@]}"
else
    set --
fi

# Invariant 1: ACL preflight, fail-closed.
if ! bash "$NORMALIZE" "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: ACL preflight failed for $WORKTREE - dispatch aborted (manual recovery: bash scripts/codex/normalize-worktree-acl.sh <worktree>)" >&2
    exit 1
fi

# Invariant 5 (HIMMEL-800): acquire the single-writer lock now that the gate
# and the ACL preflight both passed. The composed EXIT trap (registered up
# front) releases on every CATCHABLE exit from here on (codex CLI missing,
# worktree vanishing, codex nonzero exit) once LOCK_ACQUIRED is set - a
# leaked lock is worse than a redundant release call. A SIGKILL/hard-kill is
# NOT catchable, so a crash there can still leak the lock; recover it
# manually with the helper's release verb (see scripts/codex/README.md).
if [ -n "$SHARED_BRANCH" ]; then
    bash "$LOCK_HELPER" acquire "$WORKTREE" "$SHARED_BRANCH" codex-exec
    SBL_RC=$?
    if [ "$SBL_RC" -ne 0 ]; then
        # Honest messaging (M1): rc 11 = genuinely held by another writer (the
        # helper already printed holder info to stderr); any other nonzero is a
        # usage/derivation/filesystem error from the helper, not contention.
        # Both still exit 4 (the lane's "lock not acquired" code).
        if [ "$SBL_RC" -eq 11 ]; then
            echo "dispatch-codex-exec.sh: shared-branch lock not acquired for '$SHARED_BRANCH' - another worker holds it (recovery: bash scripts/lib/shared-branch-lock.sh release <dir> <branch> if the holder is stale)" >&2
        else
            echo "dispatch-codex-exec.sh: shared-branch lock not acquired for '$SHARED_BRANCH' (rc=$SBL_RC) - the lock helper could not derive a git common dir or hit a filesystem error (see its stderr above)" >&2
        fi
        exit 4
    fi
    # Do NOT register a new trap here - the composed _dispatch_cleanup trap is
    # already active (registered up front); setting LOCK_ACQUIRED is enough
    # to arm its lock-release branch. This also keeps a lock held by another
    # writer (the rc-4 path above) untouched by our own trap.
    LOCK_ACQUIRED=1
fi

# The codex CLI must resolve before the tail exec (a bare bash "not found"
# line would not name the CODEX_BIN override; CR round-3 finding).
if ! command -v "$CODEX" >/dev/null 2>&1; then
    echo "dispatch-codex-exec.sh: codex CLI not found: $CODEX (install it or set CODEX_BIN)" >&2
    exit 127
fi

# The worktree can vanish between the -d check and here (the preflight takes
# real wall-clock) - name that failure distinctly from a preflight abort.
if ! cd "$WORKTREE"; then
    echo "dispatch-codex-exec.sh: worktree vanished before dispatch: $WORKTREE" >&2
    exit 1
fi

# Invariant 2: pin gpt-5.5 unless the caller named a model explicitly.
# HIMMEL-2546 re-pinned the critic path (scripts/cr/critics.json etc.) from
# gpt-5.6-sol to gpt-6-astra; this dormant lane's own gpt-5.5 pin is
# deliberately untouched.
# Sandbox pin (codex-adv r4): ambient $CODEX_HOME/config.toml can default the
# sandbox to danger-full-access - always pass an EXPLICIT safe --sandbox when
# the caller did not name one, so ambient config cannot widen the run.
pin_args=""
if [ "$have_model" -eq 1 ]; then
    echo "dispatch-codex-exec.sh: WARN caller-named model overrides the gpt-5.5 pin (codex-variant names 400 on ChatGPT auth)" >&2
    EFFECTIVE_MODEL="caller-named"
else
    pin_args="--model gpt-5.5"
    EFFECTIVE_MODEL="gpt-5.5"
fi
if [ "$have_sandbox" -eq 0 ]; then
    pin_args="$pin_args --sandbox workspace-write"
fi
# Invariant 7 (HIMMEL-905): translate the validated --reasoning-effort enum
# into a trusted -c override (codex has no native flag for this). The value
# is quoted (a real TOML string) so it survives pin_args' later unquoted
# word-splitting as ONE argv token; the enum has no embedded whitespace so
# splitting on the surrounding space is safe.
if [ -n "$reasoning_effort" ]; then
    # shellcheck disable=SC2089  # the embedded quotes are intentional TOML string syntax for the -c override; see SC2090 note below where pin_args is expanded
    pin_args="$pin_args -c model_reasoning_effort=\"$reasoning_effort\""
fi
# Invariants 5+6 (HIMMEL-800/840): NEVER exec codex in either path - exec
# replaces this process image, which would drop the composed EXIT trap above
# (losing both the shared-branch lock release and the fleet reap). Run codex
# as a background child so its pid is known immediately, register the job
# registry entry, then wait for it and propagate its exit code.
# <&0 (CR fix): backgrounding a child in a non-interactive script redirects
# its stdin to /dev/null by default - a silent regression vs the old `exec`
# tail for any caller that PIPES context to codex exec. Explicitly wire the
# caller's own stdin through to the backgrounded child.
# Invariant 8 (stdin): ...but only when stdin is NOT a terminal. `codex exec`
# reads stdin to EOF even with an argv prompt, so an inherited TTY is an
# infinite brief - it hangs before spending a token, which is precisely the
# unobservable failure this invariant closes. A tty is never a brief.
STARTED_AT="$(date +%s)"
# Invariant 8: ledger start row BEFORE the spawn, so a dispatch that dies
# without ever reaching its end row still shows up as having started.
RUN_ID="codex-exec-$STARTED_AT-$$"
flow_run_append "$(flow_run_row_start "codex-exec" "$RUN_ID" "" "$(hostname 2>/dev/null || echo unknown)" "codex-exec" "$EFFECTIVE_MODEL" "$WORKTREE" "" "$$")"
LEDGER_STARTED=1
# The watchdog flag file is created empty and NON-empty means "the watchdog
# fired" (the `[ -s ]` idiom run-shell-tests.sh uses for the same handoff) -
# the watchdog subshell cannot set a variable in this shell.
# Created BEFORE the spawn, and a failure REFUSES rather than degrades (panel
# r2 codex-1): without the flag the watchdog would still kill the tree, but
# this shell could no longer TELL that it did - the run would report the
# child's bare signal status (143) instead of 124, skip the loud stderr line,
# keep no evidence, and cancel the watchdog mid-escalation. A watchdog whose
# verdict cannot be read is exactly the unobservable failure Invariant 8
# exists to remove, so it is not an acceptable degraded mode. Refusing here,
# before codex starts, also means nothing has been spent when it happens.
if ! TIMEOUT_FLAG="$(mktemp 2>/dev/null)" || [ -z "$TIMEOUT_FLAG" ]; then
    echo "dispatch-codex-exec.sh: cannot create the watchdog flag file (mktemp failed; TMPDIR=${TMPDIR:-<unset>}) - refusing to run codex with an unreadable watchdog verdict" >&2
    exit 2
fi
# `set -m` puts the child in its OWN process group, which is what makes the
# watchdog's group signal reach codex's descendants instead of codex alone
# (scripts/lib/proc-tree.sh USAGE block). Restored immediately after.
set -m
if [ -t 0 ]; then
    # shellcheck disable=SC2086,SC2090  # pin_args is a fixed, space-safe flag list built above; embedded quotes (HIMMEL-905 -c override) are intentional, single argv tokens once split
    "$CODEX" exec $pin_args "$@" </dev/null &
else
    # shellcheck disable=SC2086,SC2090  # see above
    "$CODEX" exec $pin_args "$@" <&0 &
fi
CODEX_CHILD_PID=$!
# Invariant 8: the watchdog. Its own group too, so standing it down below
# takes its `sleep` with it rather than leaking one sleeper per dispatch.
( sleep "$EXEC_TIMEOUT"
  # Flag BEFORE terminating, not after: proc_tree_terminate spends its TERM
  # grace before returning, and by then the parent's `wait` has already been
  # released by the kill and stood this watchdog down - the flag would never
  # be written and a killed run would report the child's bare 143.
  # rc 1 = the probe CONFIRMS the child had already exited, i.e. it finished
  # in the instant before this fired. Nothing to kill, nothing to claim.
  proc_tree_process_alive "$CODEX_CHILD_PID"
  [ "$?" -eq 1 ] && exit 0
  echo fired > "$TIMEOUT_FLAG"
  proc_tree_terminate "$CODEX_CHILD_PID" >&2 ) &
WATCH_PID=$!
set +m

# Job registry (HIMMEL-840): one file per job so a leaked fleet (dispatcher
# killed before its own EXIT trap ran) is still visible to reap-mcp-fleet's
# registry-driven maintenance mode. Best-effort: a write failure here does
# not abort the dispatch - the at-source reap below still works off
# CODEX_CHILD_PID/STARTED_AT regardless of whether the registry file exists.
mkdir -p "$JOBS_DIR" 2>/dev/null
JOB_FILE="$JOBS_DIR/${STARTED_AT}-${CODEX_CHILD_PID}.json"
printf '{"codex_pid":%s,"dispatch_pid":%s,"worktree":"%s","started_at":%s}\n' \
    "$CODEX_CHILD_PID" "$$" "$(_json_escape "$WORKTREE")" "$STARTED_AT" \
    > "$JOB_FILE" 2>/dev/null

wait "$CODEX_CHILD_PID"
CODEX_RC=$?

# Invariant 8: reading the flag is race-free here - `wait` has returned, so a
# watchdog that has not flagged yet will find the child confirmed gone and
# flag nothing. Whether to stand it down depends on WHY the child is gone
# (run-shell-tests.sh's asymmetry): if the watchdog is the reason, it may be
# mid-escalation and cancelling it would strand the survivor it was about to
# SIGKILL - let it finish. Otherwise it is still asleep; cancel it (group
# signal first, so its own `sleep` goes too, rather than leaking a sleeper
# per dispatch).
if [ -s "$TIMEOUT_FLAG" ]; then
    wait "$WATCH_PID" 2>/dev/null
else
    kill -TERM -"$WATCH_PID" 2>/dev/null || kill -TERM "$WATCH_PID" 2>/dev/null
    wait "$WATCH_PID" 2>/dev/null
fi
WATCH_PID=""

if [ -s "$TIMEOUT_FLAG" ]; then
    # LOUD: the whole point of this invariant is that a wedged unattended run
    # can no longer end quietly. 124 is what GNU `timeout` and
    # run-shell-tests.sh already report, so downstream readers keep their
    # meaning.
    CODEX_RC=124
    echo "dispatch-codex-exec.sh: codex-exec: TIMEOUT after ${EXEC_TIMEOUT}s - killed tree (worktree $WORKTREE, run $RUN_ID; raise the budget with CODEX_EXEC_TIMEOUT, evidence kept at $JOBS_DIR/failed/)" >&2
    _emit_end_row 124 timeout
    _preserve_job_file
elif [ "$CODEX_RC" -ne 0 ]; then
    _emit_end_row "$CODEX_RC"
    _preserve_job_file
else
    _emit_end_row 0
fi
exit "$CODEX_RC"
