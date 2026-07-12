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
#
# Usage:
#   dispatch-codex-exec.sh --worktree <path> [--shared-branch <branch>] [--reasoning-effort <none|low|medium|high|xhigh|max>] [codex exec args...]
#
# Environment:
#   CODEX_BIN            Override the codex CLI (tests inject a stub).
#   CODEX_ACL_NORMALIZE  Override the preflight script path (tests).
#   SBL_HELPER           Override the shared-branch-lock.sh path (tests).
#   CODEX_JOBS_DIR        Override the job registry dir (tests; default
#                         $HOME/.himmel/state/codex-exec-jobs).
#   CODEX_REAP_HELPER     Override the reap-mcp-fleet.sh path (tests).
#
# Bash 3.2 safe (macOS / Git Bash on Windows).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NORMALIZE="${CODEX_ACL_NORMALIZE:-$SCRIPT_DIR/normalize-worktree-acl.sh}"
CODEX="${CODEX_BIN:-codex}"
LOCK_HELPER="${SBL_HELPER:-$SCRIPT_DIR/../lib/shared-branch-lock.sh}"
JOBS_DIR="${CODEX_JOBS_DIR:-$HOME/.himmel/state/codex-exec-jobs}"
REAP_HELPER="${CODEX_REAP_HELPER:-$SCRIPT_DIR/reap-mcp-fleet.sh}"

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

# Single composed EXIT trap (HIMMEL-800 lock-release + HIMMEL-840 fleet-reap).
# Registered once, up front, so every early-exit path (usage errors, deny-
# listed flags, preflight failure) also runs it - each branch below is a
# no-op until its guard var is actually set, so nothing fires for a dispatch
# that never reached codex.
# shellcheck disable=SC2329,SC2317 # invoked indirectly via `trap ... EXIT`
_dispatch_cleanup() {
    if [ -n "$SHARED_BRANCH" ] && [ -n "$LOCK_ACQUIRED" ]; then
        bash "$LOCK_HELPER" release "$WORKTREE" "$SHARED_BRANCH"
    fi
    if [ -n "$CODEX_CHILD_PID" ]; then
        bash "$REAP_HELPER" --root-pid "$CODEX_CHILD_PID" --started-at "$STARTED_AT" --kill || true
        [ -n "$JOB_FILE" ] && rm -f "$JOB_FILE" 2>/dev/null
    fi
}
trap _dispatch_cleanup EXIT

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

# codex-adv r5/r6: 'codex exec resume' (esp. resume --all) selects sessions
# ACROSS cwds - it can route work into state outside the preflighted
# worktree. Codex accepts options BEFORE the subcommand token (e.g.
# '--json resume --all'), so a first-arg check is bypassable: refuse the
# bare tokens anywhere in the passthrough. (A prompt that is literally the
# single word 'resume'/'review' is refused too - pass a real sentence.)
for a in "$@"; do
    case "$a" in
        resume|review) echo "dispatch-codex-exec.sh: 'codex exec $a' refused - the lane dispatches fresh runs only (resume/review can escape the preflighted worktree)" >&2; exit 2 ;;
    esac
done

# Invariant 3: refuse --background anywhere in the passthrough args.
# Invariant 4 (codex-adv CR round 2): refuse workspace-redirect and
# sandbox-widening flags - otherwise a caller can point codex at a directory
# the ACL preflight never touched (-C/--cd/--add-dir) or drop the sandbox
# entirely, defeating the lane guard this wrapper exists to enforce.
have_model=0
have_sandbox=0
reasoning_effort=""
prev=""
NEW_ARGS=()
for a in "$@"; do
    case "$prev" in
        --sandbox|-s)
            case "$a" in
                danger-full-access) echo "dispatch-codex-exec.sh: '$prev danger-full-access' refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
            esac
            ;;
        --reasoning-effort)
            case "$a" in
                none|low|medium|high|xhigh|max) reasoning_effort="$a" ;;
                *) echo "dispatch-codex-exec.sh: --reasoning-effort value '$a' not in none|low|medium|high|xhigh|max" >&2; exit 2 ;;
            esac
            prev="$a"
            continue
            ;;
    esac
    # ALLOW-LIST (codex-adv final round): deny-listing clap's option surface
    # is unwinnable (attached short forms, --enable/--disable feature flags
    # that rewrite config, future flags). Specific deny cases stay for their
    # actionable messages; EVERYTHING ELSE dash-prefixed is refused by the
    # catch-all. Allowed: --model/-m (all forms), --sandbox/-s with a
    # non-danger value (all forms), --reasoning-effort (HIMMEL-905, stripped
    # from the passthrough - see Invariant 7 above), --json, and positional
    # prompt words.
    case "$a" in
        --reasoning-effort) prev="$a"; continue ;;
        --reasoning-effort=*)
            rev_val="${a#--reasoning-effort=}"
            case "$rev_val" in
                none|low|medium|high|xhigh|max) reasoning_effort="$rev_val" ;;
                *) echo "dispatch-codex-exec.sh: --reasoning-effort value '$rev_val' not in none|low|medium|high|xhigh|max" >&2; exit 2 ;;
            esac
            prev="$a"
            continue
            ;;
        --background|--background=*) echo "dispatch-codex-exec.sh: --background refused (upstream silent-death, HIMMEL-741) - use the default wait behavior + companion-liveness.sh" >&2; exit 2 ;;
        -C*|--cd|--cd=*) echo "dispatch-codex-exec.sh: workspace-redirect flag '$a' refused - the wrapper owns the worktree (pass it via --worktree)" >&2; exit 2 ;;
        --add-dir|--add-dir=*) echo "dispatch-codex-exec.sh: --add-dir refused - the ACL preflight covers only the dispatched worktree" >&2; exit 2 ;;
        --dangerously-bypass-approvals-and-sandbox|--yolo) echo "dispatch-codex-exec.sh: sandbox-bypass flag '$a' refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
        --sandbox=danger-full-access|-s=danger-full-access|-sdanger-full-access) echo "dispatch-codex-exec.sh: sandbox danger-full-access refused - the lane guard requires a sandboxed run" >&2; exit 2 ;;
        -c*|--config|--config=*) echo "dispatch-codex-exec.sh: config-override flag '$a' refused - -c/--config can widen sandbox_permissions past the lane guard" >&2; exit 2 ;;
        -p*|--profile|--profile=*) echo "dispatch-codex-exec.sh: profile flag '$a' refused - a config profile can widen the sandbox past the lane guard" >&2; exit 2 ;;
        --dangerously-bypass-hook-trust|--ignore-rules) echo "dispatch-codex-exec.sh: trust-bypass flag '$a' refused - the lane guard does not vet hook sources or waive execpolicy rules" >&2; exit 2 ;;
        --enable|--enable=*|--disable|--disable=*) echo "dispatch-codex-exec.sh: feature flag '$a' refused - config-equivalent (can disable the hooks feature past the lane guard)" >&2; exit 2 ;;
        -o*|--output-last-message|--output-last-message=*) echo "dispatch-codex-exec.sh: output-file flag '$a' refused - a CLI-level write to a caller-supplied path can escape the worktree" >&2; exit 2 ;;
        --model|--model=*|-m|-m?*) have_model=1 ;;
        --sandbox|--sandbox=*|-s|-s=*|-s?*) have_sandbox=1 ;;
        --json) ;;  # structured output - inert
        -*) echo "dispatch-codex-exec.sh: flag '$a' is not in the lane allow-list (--model/-m, --sandbox/-s safe values, --reasoning-effort, --json) - refused" >&2; exit 2 ;;
    esac
    NEW_ARGS+=("$a")
    prev="$a"
done
# Trailing bare --reasoning-effort (nothing follows): the main switch strips
# the token before the value-validation branch ever runs, so without this
# guard the flag vanishes silently and the run proceeds at default effort.
if [ "$prev" = "--reasoning-effort" ]; then
    echo "dispatch-codex-exec.sh: --reasoning-effort requires a value (none|low|medium|high|xhigh|max)" >&2
    exit 2
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
# Sandbox pin (codex-adv r4): ambient $CODEX_HOME/config.toml can default the
# sandbox to danger-full-access - always pass an EXPLICIT safe --sandbox when
# the caller did not name one, so ambient config cannot widen the run.
pin_args=""
if [ "$have_model" -eq 1 ]; then
    echo "dispatch-codex-exec.sh: WARN caller-named model overrides the gpt-5.5 pin (codex-variant names 400 on ChatGPT auth)" >&2
else
    pin_args="--model gpt-5.5"
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
STARTED_AT="$(date +%s)"
# shellcheck disable=SC2086,SC2090  # pin_args is a fixed, space-safe flag list built above; embedded quotes (HIMMEL-905 -c override) are intentional, single argv tokens once split
"$CODEX" exec $pin_args "$@" <&0 &
CODEX_CHILD_PID=$!

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
exit "$CODEX_RC"
