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
#   0 -- launched (or skipped: CR_PROFILE=none, codex companion not found,
#       diff is not high-risk, or this branch already ran once -- HIMMEL-2707)
#   1 -- BLOCKED: a live render lease on this branch, or a prior kickoff's
#       ownership record could not be safely recovered
#
# HIMMEL-2707: the pass had been dormant since HIMMEL-1957 (CODEX_ADV_OK unset
# nowhere) after an audit disproved its "re-runs the suite" justification --
# see docs/internals/enforcement.md. Re-armed, but narrowed to only the diffs
# that plausibly need it: HIGH RISK (scripts/lib/cr-high-risk-diff.sh's shared
# path predicate, cr_paths_are_high_risk, applied to `git diff --name-only`
# against the merge base -- there is no PR yet at kickoff time to ask GitHub
# about) and at most ONCE per branch (a new "${codex_out}.armed" sidecar,
# deliberately NOT part of the .rc/.head reset below so a later /pr-check
# round on the same branch cannot buy a second paid run just by moving HEAD).
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
# shellcheck source=../lib/cr-high-risk-diff.sh
# shellcheck disable=SC1091
. "$HIMMEL_ROOT/scripts/lib/cr-high-risk-diff.sh"
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
# HIMMEL-2707: once-per-branch marker. Deliberately NOT in the line below's
# `rm -f` reset -- that reset runs on EVERY kickoff (each /pr-check round), so
# a marker that got reset there would buy a second paid run just by moving
# HEAD. This file has to outlive rounds; only a fresh branch (or manual
# cleanup) clears it.
codex_armed_file="${codex_out}.armed"
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
# HIMMEL-2707: the path predicate alone (cr_paths_are_high_risk, sourced
# above) applied to a plain git diff -- there is no PR yet at kickoff time,
# so cr_diff_is_high_risk's gh-backed reader cannot be used. Base ref prefers
# origin/$db (the branch's real merge target) and falls back to the local
# $db when there is no origin remote (e.g. a fixture repo, or a solo
# checkout); the diff itself is the three-dot form so it is a merge-base
# diff, not a straight two-ref diff. When neither the base ref nor the diff
# itself can be resolved, this fails OPEN (treats as high risk) rather than
# silently skipping the pass -- same posture as cr_diff_is_high_risk's own
# documented rc 2 ("cannot determine... caller treats as high risk"). The
# pass is advisory-only and never gates a merge, so an extra run costs quota
# but blocks nothing, whereas a missed run on a hooks/guardrails diff loses
# the one reviewer that catches design blind spots; the once-per-branch
# marker below caps the blast radius of that fail-open to a single run.
codex_adv_is_high_risk() {
    local base_ref="" diff_out="" reason=""
    if git rev-parse --verify --quiet "origin/$db" >/dev/null 2>&1; then
        base_ref="origin/$db"
    elif git rev-parse --verify --quiet "$db" >/dev/null 2>&1; then
        base_ref="$db"
    fi
    if [ -z "$base_ref" ]; then
        reason="base ref for '$db' could not be resolved (neither origin/$db nor $db exists)"
    # --no-renames (HIMMEL-2707): with rename detection on, `git diff
    # --name-only` reports only the DESTINATION path of a rename, so moving a
    # protected file (e.g. scripts/hooks/foo.sh) out of its protected
    # directory would surface only the harmless new path and classify
    # ordinary -- deleting a hook without ever tripping the high-risk gate.
    # --no-renames makes git report the rename as what it physically is: a
    # DELETE of the old path plus an ADD of the new one, so the old protected
    # path lands in $diff_out and cr_paths_are_high_risk matches it. This is
    # strictly more conservative than the default (never narrows the match
    # set, only widens it) and needs no second query or extra parsing. It
    # lands on the same fail-safe side as cr_diff_is_high_risk's own rename
    # handling in scripts/lib/cr-high-risk-diff.sh (search "A RENAME is
    # unprovable from the new path alone"), which fails CLOSED (rc 2,
    # cannot-determine -> caller treats as HIGH RISK) rather than trusting the
    # new path -- keep the two postures in step by inspection.
    elif ! diff_out=$(git diff --no-renames --name-only "${base_ref}...HEAD" 2>/dev/null); then
        reason="git diff --no-renames --name-only ${base_ref}...HEAD failed"
    elif printf '%s\n' "$diff_out" | cr_paths_are_high_risk >/dev/null; then
        return 0
    else
        return 1
    fi
    echo "armed: diff undeterminable (fail-open, capped) -- $reason; treating as HIGH RISK, HIMMEL-2707" >&2
    return 0
}
if [ "${CR_PROFILE:-}" = "none" ]; then
    echo "claude-only (CR_PROFILE=none) -- codex adversarial pass not launched"
    : # claude-only -- codex adversarial pass also skipped under none (step 3.1's harvest skips too).
elif [ -z "$companion" ]; then
    echo "codex adversarial pass skipped (codex not configured)"
elif [ -s "$codex_armed_file" ]; then
    echo "codex adversarial pass skipped: already ran once for branch '$branch' (HIMMEL-2707)"
elif ! codex_adv_is_high_risk; then
    echo "codex adversarial pass skipped: not high-risk (HIMMEL-2707)"
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
    elif [ "${CODEX_ADV_OK:-}" = "1" ] && ! printf '%s\n' "$codex_head" > "$codex_armed_file"; then
        # HIMMEL-2707: never launch a paid pass it cannot record as having run
        # -- the once-per-branch marker exists specifically to prevent a
        # second paid run, so a marker it cannot write must block the launch
        # rather than silently skip recording it. Gated on CODEX_ADV_OK=1
        # (the LIVE case) only: the marker's entire purpose is to stop a
        # second PAID run, so a dormant round (CODEX_ADV_OK unset -- the
        # background launch below is a no-op per run-codex-adversarial.sh's
        # own HIMMEL-1957 gate) must not write it at all. Writing it
        # unconditionally used to burn the branch's one allowance on a round
        # that reviewed nothing, permanently starving every later /pr-check
        # round of its paid review -- this was HIMMEL-2707's actual bug.
        echo "codex adversarial pass skipped (cannot record the once-per-branch marker at $codex_armed_file, HIMMEL-2707)"
        rm -f "$codex_armed_file"
    else
        # HIMMEL-2707: this launcher's OWN watchdog (run-codex-adversarial.sh,
        # its 6th positional `timeout-seconds`) used to get a literal `0` here,
        # which DISARMS it entirely (see that script: `if [ "$timeout_secs"
        # -gt 0 ]` -- 0 skips the whole poll-and-kill loop and falls straight
        # through to a blocking `wait`). The only other bound on this PAID
        # background render was codex-adv-harvest.sh's own poll-and-terminate
        # -- which never runs at all if step 3.1 never gets a turn (an aborted
        # /pr-check, a dead session, an interrupted operator). With no harvest
        # and no launcher-side bound, the node process is simply orphaned and
        # keeps running, still burning paid quota, forever -- and on Linux
        # there is no automated reaper (scripts/cleanup/sweep-codex-orphans.ps1
        # is Windows-only). Arm a REAL bound here so the launcher is a
        # self-sufficient backstop, independent of whether harvest ever runs.
        #
        # Derived from the SAME knob harvest.sh normalizes and doubles
        # (CRITIC_TIMEOUT_SECS, default 240), with the identical normalization
        # -- deliberately mirrored, not shared, so the two stay in lockstep by
        # inspection: a non-numeric or <=0 value falls back to 240, and the
        # `10#` prefix forces base-10 arithmetic (a leading zero like "08"
        # would otherwise be read as octal and abort the `$(( ))` expression).
        codex_timeout=${CRITIC_TIMEOUT_SECS:-240}
        case "$codex_timeout" in ''|*[!0-9]*) codex_timeout=240 ;; esac
        [ "$codex_timeout" -gt 0 ] || codex_timeout=240
        codex_to=$(( 10#$codex_timeout * 2 ))
        # codex-adv-harvest.sh declares ITS OWN timeout once its waited
        # counter reaches this same $codex_to, polling in fixed 5s steps -- so
        # harvest's actual observed wait can overshoot codex_to by up to one
        # 5s tick. This +30 is a small headroom margin for that granularity
        # (plus scheduler jitter) -- it is NOT a guarantee about which bound
        # fires first. The two clocks do not start together: this launcher's
        # watchdog starts at KICKOFF (right here), while harvest's bound only
        # starts once harvest itself begins -- which is after the critic panel
        # has run, since the panel is deliberately overlapped with this
        # background pass (that overlap is the whole point of the
        # kickoff/harvest split). So the launcher deadline is
        # `kickoff + codex_launch_timeout`, while the harvest deadline is
        # `kickoff + panel_duration + codex_to` -- whichever expires first
        # wins. With a real panel round (~2 minutes), panel_duration
        # comfortably exceeds this 30s margin, so in the NORMAL case it is
        # THIS launcher watchdog that fires first, by roughly
        # `panel_duration - 30s` -- not a rare-case backstop. Either bound
        # firing is fine: both terminate the same process and each is
        # reported as a distinct rc 124 (harvest's `124)` case classifies it).
        # What this launcher-side bound actually guarantees, unconditionally,
        # is that the paid process can never outlive it -- including the
        # orphan case above (harvest never gets a turn at all: an aborted
        # /pr-check, a dead session), which a bound of `0` used to allow.
        codex_launch_timeout=$(( codex_to + 30 ))
        ( bash "$HIMMEL_ROOT/scripts/cr/run-codex-adversarial.sh" "$companion" "$db" "$codex_out" "$codex_err_file" "$codex_pid_file" "$codex_launch_timeout" "$codex_cleanup_rc_file"
          echo $? > "$codex_rc_file" ) &
        disown 2>/dev/null || true
        # HIMMEL-2377: the backgrounded call above is unconditional (harmless --
        # run-codex-adversarial.sh's own HIMMEL-1957 dormant gate on CODEX_ADV_OK
        # makes it a cheap no-op), but the PRINTED claim must agree with what that
        # gate will actually do, or a reader trusts a launch that never happened
        # (HIMMEL-1957: harvest then reports "dormant/absent -- not launched").
        # Same precondition, checked here only to pick the truthful message.
        if [ "${CODEX_ADV_OK:-}" = "1" ]; then
            echo "codex adversarial pass launched in background (bound ${codex_launch_timeout}s, log: $codex_out) -- harvested in step 3.1 after the critic panel (HIMMEL-1407)"
        else
            echo "codex adversarial pass dormant (CODEX_ADV_OK != 1, HIMMEL-1957) -- not launched; harvested as absent in step 3.1, set CODEX_ADV_OK=1 to launch"
        fi
    fi
fi
