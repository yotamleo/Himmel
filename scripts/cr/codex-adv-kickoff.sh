#!/usr/bin/env bash
# scripts/cr/codex-adv-kickoff.sh -- HIMMEL-2226
#
# Background-launches the codex adversarial pass (step 3 of
# .claude/commands/pr-check.md, HIMMEL-1407: overlap the codex companion's
# wall-clock with the critic panel instead of stacking after it; harvested
# separately in step 3.1 / codex-adv-completion-check.sh). This used to be an
# inline ```bash fence in pr-check.md that the orchestrating Claude session
# ran verbatim. Extracted to a real script for HIMMEL-2226 because a
# worktree-isolated session's Bash tool refuses ANY shell function definition
# on the command line (the fence defines recover_codex_survivor() and
# recover_codex_state()) -- that refusal only applies to the runbook's command
# line, not to code inside a script file it invokes, so the recovery logic
# below is unchanged from the fence it was extracted from. Every
# "${CLAUDE_PROJECT_DIR:?}" reference is replaced by a SCRIPT_DIR-derived
# HIMMEL_ROOT (same convention as scripts/cr/pr-check-external.sh) since
# CLAUDE_PROJECT_DIR is genuinely unset in an isolated session's Bash-tool
# shells. Behavior, messages, and exit codes are otherwise byte-equivalent to
# the fence.
#
# Usage: bash scripts/cr/codex-adv-kickoff.sh
#   (no arguments -- re-derives the default branch, current branch, and
#   CR_PROFILE itself, exactly like the fence it replaces)
#
# Exit codes:
#   0 -- launched (or skipped: CR_PROFILE=none, or codex companion not found)
#   1 -- BLOCKED: a live render lease on this branch, or a prior kickoff's
#       ownership record could not be safely recovered
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
db=$(. "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null && default_branch || echo main)
# shellcheck source=../lib/load-dotenv.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/load-dotenv.sh"; load_dotenv --root "$(_load_dotenv_primary_for "$HIMMEL_ROOT")" CR_PROFILE || true
# shellcheck source=../lib/proc-tree.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/proc-tree.sh"
export CR_PROFILE
branch=$(git branch --show-current)
# HIMMEL-1509 launch claim (subsumes HIMMEL-1496): one render per branch,
# coordinated through the render-lease registry instead of the retired :00
# launch window. This probe is the loud fast-path refusal; the ATOMIC claim
# lives inside run-codex-adversarial.sh (mkdir = the lock, taken before node
# spawns), so two kickoffs racing past this probe still cannot double-launch
# - the loser exits 75 with its own diagnostic. RENDER_LEASE_BRANCH is the
# launcher's opt-in.
# shellcheck source=../lib/render-lease.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/render-lease.sh"
export RENDER_LEASE_BRANCH="$branch"
if [ -n "$branch" ] && ! render_lease_probe "$branch"; then
    echo "codex adversarial kickoff BLOCKED: branch '$branch' holds a live render lease ($(render_lease_dir_for "$branch")) -- a concurrent /pr-check render owns this branch (HIMMEL-1509); wait for it to finish, or adjudicate a stale lease via the sweep before retrying" >&2
    exit 1
fi
git_dir=$(git rev-parse --git-common-dir)
# Branch-scoped under the SHARED git-common-dir, same convention as
# cr-pending/cr-prior-blocking (HIMMEL-1219) -- concurrent /pr-check runs on
# different branches must not collide on one file. mkdir -p the parent
# because a branch name contains '/' (e.g. fix/himmel-1407-...).
codex_out="${git_dir}/codex-adv-out/${branch}"
codex_pid_file="${codex_out}.pid"
codex_retry_pid_file="${codex_pid_file}.retry"
codex_rc_file="${codex_out}.rc"
codex_cleanup_rc_file="${codex_pid_file}.cleanup-rc"
# Companion stderr goes to its OWN sibling file, not merged into
# $codex_out (glm-3, CR round 2, HIMMEL-1407): findings capture must stay
# stdout-only, or diagnostic chatter on an otherwise-successful run gets
# forwarded to adjudication as review output. Preserved (not deleted) by
# the harvest fence below for debugging -- the old `2>/dev/null` discard is
# exactly what hid this ticket's root cause for 28 runs.
codex_err_file="${codex_out}.err"
# HIMMEL-2321/HIMMEL-1175 (CR round 4): the commit this pass actually
# reviews, resolved and recorded at LAUNCH time (below) - the one moment
# unambiguous about what the companion is about to diff against. Same
# "${codex_out}.SUFFIX" sibling convention as .rc/.err/.pid above.
# codex-adv-harvest.sh reads this back to stamp the CR ledger; without it,
# the self-write skips rather than guessing.
codex_head_file="${codex_out}.head"
mkdir -p "$(dirname "$codex_out")"
# HIMMEL-1474 r11 kickoff recovery start. Never overwrite a prior run's
# ownership handles. A completed clean record is stale and removable; an
# identity-verified leader or r14 survivor anchor is recovered; an active or
# unverifiable record blocks this kickoff with the handles intact.
recover_codex_survivor() {
    # Braced positional refs, not bare dollar-digits (HIMMEL-2051): the
    # braced form is identical bash but isn't matched by the Skill-tool
    # positional-arg substitution regex, which only fires on a bare
    # dollar sign directly followed by a digit.
    local state_label="${1}" survivor_pid="${2}" survivor_identity="${3}" identity_rc
    if [ -z "$survivor_pid" ] || [ -z "$survivor_identity" ]; then
        echo "codex adversarial kickoff BLOCKED: $state_label survivor record is malformed; manual recovery required" >&2
        return 1
    fi
    identity_rc=0
    proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
    if [ "$identity_rc" -eq 1 ]; then
        if proc_tree_process_alive "$survivor_pid"; then
            echo "codex adversarial kickoff BLOCKED: $state_label survivor pid $survivor_pid has an identity mismatch; no signal sent" >&2
            return 1
        fi
        return 0
    fi
    if [ "$identity_rc" -ne 0 ]; then
        echo "codex adversarial kickoff BLOCKED: $state_label survivor pid $survivor_pid cannot be identity-verified (identity rc=$identity_rc); no signal sent" >&2
        return 1
    fi
    kill -TERM "$survivor_pid" 2>/dev/null || true
    sleep 1
    identity_rc=0
    proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
    if [ "$identity_rc" -eq 0 ]; then
        kill -KILL "$survivor_pid" 2>/dev/null || true
        sleep 1
        identity_rc=0
        proc_tree_process_identity_matches "$survivor_pid" "$survivor_identity" || identity_rc=$?
    fi
    if [ "$identity_rc" -eq 1 ]; then
        proc_tree_process_alive "$survivor_pid" || return 0
    fi
    echo "codex adversarial kickoff BLOCKED: $state_label survivor pid $survivor_pid remains live or unverifiable after recovery (identity rc=$identity_rc); preserve recovery sidecars" >&2
    return 1
}
recover_codex_state() {
    local state_label="${1}" state_pid_file="${2}" state_identity_file="${2}.identity" state_cleanup_rc_file="${2}.cleanup-rc" state_survivors_file="${2}.survivors"
    local state_pid state_identity state_cleanup_rc identity_rc recovery_rc survivor_pid survivor_identity
    [ -e "$state_pid_file" ] || { rm -f "$state_identity_file" "$state_cleanup_rc_file" "$state_survivors_file"; return 0; }
    if [ ! -s "$state_pid_file" ] || [ ! -s "$state_identity_file" ]; then
        echo "codex adversarial kickoff BLOCKED: $state_label ownership record is incomplete ($state_pid_file / $state_identity_file); refusing to overwrite it" >&2
        return 1
    fi
    if [ ! -s "$state_cleanup_rc_file" ]; then
        echo "codex adversarial kickoff BLOCKED: $state_label render is still active or cleanup status is missing; preserve $state_pid_file and $state_identity_file and recover it before retrying" >&2
        return 1
    fi
    state_cleanup_rc=$(cat "$state_cleanup_rc_file")
    if [ "$state_cleanup_rc" = "0" ]; then
        rm -f "$state_pid_file" "$state_identity_file" "$state_cleanup_rc_file" "$state_survivors_file"
        return 0
    fi
    state_pid=$(cat "$state_pid_file")
    state_identity=$(cat "$state_identity_file")
    identity_rc=0
    proc_tree_process_identity_matches "$state_pid" "$state_identity" || identity_rc=$?
    if [ "$identity_rc" -ne 1 ]; then
        if [ "$identity_rc" -ne 0 ]; then
            echo "codex adversarial kickoff BLOCKED: $state_label cleanup rc=$state_cleanup_rc and launch identity cannot be verified (identity rc=$identity_rc); no signal sent; preserve recovery sidecars" >&2
            return 1
        fi
        recovery_rc=0
        proc_tree_terminate "$state_pid" 1 "$state_identity" || recovery_rc=$?
        if [ "$recovery_rc" -eq 0 ]; then
            rm -f "$state_pid_file" "$state_identity_file" "$state_cleanup_rc_file" "$state_survivors_file"
            echo "codex adversarial kickoff recovered prior $state_label render pid/group $state_pid" >&2
            return 0
        fi
        if [ "$recovery_rc" -ne 3 ]; then
            echo "codex adversarial kickoff BLOCKED: $state_label recovery cleanup rc=$recovery_rc; preserve recovery sidecars" >&2
            return 1
        fi
    fi
    # HIMMEL-1501: either the identity probe or proc_tree_terminate can
    # confirm the leader exited/recycled. In both races the survivors
    # sidecar is the remaining recovery authority.
    case "$state_cleanup_rc" in
        1|2|3) ;;
        *)
            echo "codex adversarial kickoff BLOCKED: $state_label cleanup rc=$state_cleanup_rc cannot use survivor-anchor recovery; preserve recovery sidecars" >&2
            return 1
            ;;
    esac
    if [ ! -e "$state_survivors_file" ]; then
        echo "codex adversarial kickoff BLOCKED: $state_label cleanup rc=$state_cleanup_rc has a dead leader but no survivors sidecar (legacy pre-r14 record); manual recovery required before removing $state_pid_file / $state_identity_file / $state_cleanup_rc_file" >&2
        return 1
    fi
    while IFS=$'\t' read -r survivor_pid survivor_identity || [ -n "$survivor_pid$survivor_identity" ]; do
        recover_codex_survivor "$state_label" "$survivor_pid" "$survivor_identity" || return 1
    done < "$state_survivors_file"
    rm -f "$state_pid_file" "$state_identity_file" "$state_cleanup_rc_file" "$state_survivors_file"
    echo "codex adversarial kickoff recovered prior $state_label render through survivor anchors" >&2
    return 0
}
recover_codex_state "primary" "$codex_pid_file" || exit 1
recover_codex_state "retry" "$codex_retry_pid_file" || exit 1
# HIMMEL-1474 r11 kickoff recovery end.
rm -f "$codex_rc_file" "$codex_cleanup_rc_file" "$codex_head_file"; : > "$codex_out"; : > "$codex_err_file"
# Resolve via bash glob, NOT `ls` (HIMMEL-741c: Git Bash `ls` classify suffix
# `*` on executables corrupts the path). Last glob match = highest lexical.
companion=""
for _c in "$HOME/.claude/plugins/cache/openai-codex/codex/"*/scripts/codex-companion.mjs; do
    [ -f "$_c" ] && companion="$_c"
done
# Windows node mangles an MSYS /c/... path into C:\c\... -- hand it a native
# (mixed-form) path when cygpath exists; POSIX systems pass through unchanged.
if [ -n "$companion" ] && command -v cygpath >/dev/null 2>&1; then
    companion=$(cygpath -m "$companion")
fi
if [ "${CR_PROFILE:-}" = "none" ]; then
    echo "claude-only (CR_PROFILE=none) -- codex adversarial pass not launched"
    : # claude-only -- codex adversarial pass also skipped under none (step 3.1's harvest skips too).
elif [ -z "$companion" ]; then
    echo "codex adversarial pass skipped (codex not configured)"
else
    # A real OS background job, NOT `timeout`-wrapped (that would just
    # reintroduce the foreground timebox one level up -- the exact thing
    # this restructure removes). The shared launcher records NODE's own pid
    # and starts its Layer B client-lease heartbeat -- not the wrapper's $!:
    # signaling a bash wrapper does not propagate to its running child, so
    # a wrapper-pid kill on the timeout path would leave node alive and
    # orphaned, still consuming quota (the exact cost HIMMEL-1407 exists
    # to stop; also the Windows grandchild-kill trap). The wrapper lingers
    # only to write node's exit status to $codex_rc_file after node exits,
    # so step 3.1's harvest -- a separate bash fence with no job-table link
    # back to this one -- can tell "still running" apart from "ran and
    # failed" using only the pid + rc files on disk.
    # HIMMEL-2321/HIMMEL-1175 (CR round 4): resolve and record the head this
    # pass reviews BEFORE launching it - launch time is the one moment this
    # is unambiguous (the companion diffs against whatever HEAD is right
    # now). A pass whose head cannot be resolved or recorded must not launch
    # at all: its findings could never be safely attributed to a commit.
    codex_head="$(git rev-parse --verify --quiet HEAD 2>/dev/null)" || codex_head=""
    if [ -z "$codex_head" ]; then
        echo "codex adversarial pass skipped (cannot resolve HEAD -- its findings could never be attributed to a commit, HIMMEL-2321/HIMMEL-1175)"
    elif ! printf '%s\n' "$codex_head" > "$codex_head_file"; then
        echo "codex adversarial pass skipped (cannot record the launched head at $codex_head_file -- its findings could never be attributed, HIMMEL-2321/HIMMEL-1175)"
        rm -f "$codex_head_file"
    else
        ( bash "$HIMMEL_ROOT/scripts/cr/run-codex-adversarial.sh" "$companion" "$db" "$codex_out" "$codex_err_file" "$codex_pid_file" 0 "$codex_cleanup_rc_file"
          echo $? > "$codex_rc_file" ) &
        disown 2>/dev/null || true
        # HIMMEL-2377: the backgrounded call above is unconditional (harmless --
        # run-codex-adversarial.sh's own HIMMEL-1957 dormant gate on CODEX_ADV_OK
        # makes it a cheap no-op), but the PRINTED claim must agree with what that
        # gate will actually do, or a reader trusts a launch that never happened
        # (HIMMEL-1957: harvest then reports "dormant/absent -- not launched").
        # Same precondition, checked here only to pick the truthful message.
        if [ "${CODEX_ADV_OK:-}" = "1" ]; then
            echo "codex adversarial pass launched in background -- harvested in step 3.1 after the critic panel (HIMMEL-1407)"
        else
            echo "codex adversarial pass dormant (CODEX_ADV_OK != 1, HIMMEL-1957) -- not launched; harvested as absent in step 3.1, set CODEX_ADV_OK=1 to launch"
        fi
    fi
fi
