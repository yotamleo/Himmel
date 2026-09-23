#!/usr/bin/env bash
# scripts/cr/pr-check-context.sh - the /pr-check runbook's step-0 TRUSTED
# ANCHOR entry point: resolves and prints the shared per-run context
# (HIMMEL-2226), decides the himmel/adopter lane from the HIMMEL_REPO anchor,
# and deliberately delegates to the reviewed branch's own copy of itself when
# that branch touches scripts/cr/ (HIMMEL-2335).
#
# WHY this is a script and not a fence: Claude Code's worktree-isolation guard
# screens every Bash-tool command in a worktree-isolated session and refuses
# anything it cannot statically verify safe - including sourcing a
# runtime-determined path (`. "$var/lib.sh"`). A 13-shape bisection
# (HIMMEL-2335) found two more refusal rules the old step-0 fence tripped at
# once: (R1) expansion of an env var the guard cannot resolve is refused EVEN
# WHEN THE VAR IS SET - `echo "$HIMMEL_REPO"` refused, `d=$(printenv
# HIMMEL_REPO); echo "$d"` accepted; (R2) a `[ ]` test on a value derived from
# command substitution is refused - `a=$(printenv X); if [ -z "$a" ]` refused,
# `if h=$(printenv X); then` (branching on exit status, not a `[ ]` test on
# the captured value) accepted. The old fence's own
# `if [ -z "$HIMMEL_REPO" ] ... elif [ "$cwd_common" -ef "$HIMMEL_REPO/.git" ]`
# lane comparison hit both. Step 0 now enters through ONE call with no
# lane-comparison branching left in the fence:
#
#   if himmel_repo=$(printenv HIMMEL_REPO | grep .); then
#       bash "$himmel_repo/scripts/cr/pr-check-context.sh"
#   else
#       echo "pr-check: HIMMEL_REPO is unset or empty ..." >&2; exit 2
#   fi
#
# The `| grep .` matches only a non-empty line, so a set-but-EMPTY
# HIMMEL_REPO fails the assignment and takes the else branch too (see the
# Usage note below) - without it, `printenv HIMMEL_REPO` on an empty var
# still exits 0, and the if-branch runs with himmel_repo="", collapsing to
# `bash "/scripts/cr/pr-check-context.sh"`: under Git Bash on Windows that is
# `C:\scripts\cr\pr-check-context.sh`, a location an ORDINARY user can create
# without admin rights, and a file planted there would run AS THE TRUSTED
# ENTRY POINT ahead of every check below. Do not remove the `| grep .`.
#
# Everything the old fence's `if`/`elif`/`else` used to decide - unset vs
# empty vs the himmel/adopter lane comparison - now happens INSIDE this
# script, against real shell variables the guard never sees (see "Anchor +
# delegation" below).
#
# Anchor + delegation (HIMMEL-2335). himmel's location MUST come from outside
# the repo under review (HIMMEL-2226 Finding 1: a crafted repo can carry its
# own scripts/cr/critic-panel.sh or bake any path into its own pre-push
# hook), so this script reads HIMMEL_REPO from its OWN process environment -
# never re-derived from cwd or a repo-supplied file - and refuses (exit 2) if
# it is unset OR EMPTY, naming the remedy. It then compares the cwd's
# git-common-dir against `$HIMMEL_REPO/.git` by inode (`-ef`, so a trailing
# slash / symlink / slash-style / Windows-casing difference cannot
# misclassify it):
#   - MATCH    -> anchor_lane=himmel.   himmel_dir = this cwd's own
#     `--show-toplevel` (the branch/worktree, NOT the anchor) - deliberate:
#     it is what lets a change to scripts/cr/ review ITSELF.
#   - NO MATCH -> anchor_lane=adopter. himmel_dir = the anchor, NEVER
#     anything the reviewed repo supplied.
# On the himmel lane, when NOT already the anchor itself, the branch's
# changes to the guarded paths in cr_guarded below - scripts/cr/,
# scripts/lib/, scripts/guardrails/lib.sh, scripts/check-ci.sh and
# scripts/handover/resolve-active-item.sh (HIMMEL-3382, widened by
# HIMMEL-3493: the merge-base diff of COMMITTED history PLUS WORKING-TREE and
# UNTRACKED changes, scoped to those paths; the runbook's step-0 himmel-lane
# precheck runs the same diff, and its silence is necessary, not sufficient,
# for this script's "no") are classified TRI-STATE into
# `cr_diff_state`: "no" (every git call succeeded, the set is empty), "yes"
# (every git call succeeded, the set is non-empty), or "unknown" (merge-base
# could not be computed, OR any of the three git calls failed - either
# failure is treated identically: never delegate on an unknown diff). The
# exact set decided on is printed as `cr_diff_files=` below. When
# cr_diff_state=yes AND this run is not itself the
# verified delegate (the recursion guard - see "Identity handshake, not a
# boolean" below) AND the branch carries its own
# scripts/cr/pr-check-context.sh, this run appends one `delegation` row to the
# CR ledger through the ANCHOR's own ledger-append.sh, prints a stderr
# diagnostic, then re-execs the BRANCH's copy of this same script with
# PR_CHECK_ANCHOR_DELEGATED="$anchor" set (the delegating anchor's OWN path,
# not a bare `1` - see "Identity handshake, not a boolean" below). That
# disables the delegate copy's own delegation check, so it produces the
# actual context instead of re-delegating forever. The trusted anchor is what
# decides delegation happens and logs it - the branch copy never elects
# itself.
#
# THE single guarantee (HIMMEL-2335 round 6): himmel_dir may be left pointing
# at the BRANCH ONLY IF cr_diff_state=no (the diff touches no cr_guarded
# path and their bytes match the anchor's at step 0 - see the ponytail at
# the end-of-decision assertion, HIMMEL-3497), OR the delegation is provably
# logged (verified_delegate=yes -
# this run IS a verified delegate a genuine anchor handed off to - OR
# ledger_written=yes - this run IS the anchor and its own ledger-append.sh
# call just succeeded). This is now enforced by ONE assertion at the very end
# of the decision, not by three separate per-branch `himmel_dir="$anchor"`
# patches: three CR findings (soft-decline on a failed ledger write, a
# spoofed/foreign recursion guard, and an unknown merge-base) were each the
# SAME defect - a branch of this decision that left himmel_dir at the branch
# when it should not have - independently patched where each was found. The
# single assertion is what now guarantees it structurally: a future branch of
# this decision that forgets to reset himmel_dir is caught there instead of
# shipping. A failed ledger write (most commonly: the anchor checkout
# predates HIMMEL-2335, so its ledger-append.sh does not know the
# "delegation" kind yet - a genuine bootstrap defect, not just a test
# artifact, since ANY branch that both adds a new ledger kind and delegates
# hits it) no longer aborts the run - the invariant is "never delegate
# UNLOGGED", and declining to delegate satisfies that exactly. This run
# instead WARNS on stderr, does NOT delegate, and the end-of-decision
# assertion falls back to the anchor's own (trusted, conservative) code.
#
# Identity handshake, not a boolean (HIMMEL-2335 round 4, CR panel [codex-2]).
# PR_CHECK_ANCHOR_DELEGATED is set to the DELEGATING ANCHOR'S OWN PATH, never
# a bare `1`. A bare boolean was unsafe: ANY pre-existing non-empty value in
# the process environment - a stray export, a leftover from an earlier run, a
# hostile launching shell - would satisfy `[ -z "$PR_CHECK_ANCHOR_DELEGATED" ]`
# just as well as a genuine handoff, and all three of these would then happen
# at once: delegation gets SUPPRESSED (so no ledger row is ever written),
# himmel_dir stays the BRANCH (so the branch's own unreviewed scripts/cr/
# executes on every later /pr-check fence), and the run still PRINTS
# delegated=yes (claiming the anchor delegated deliberately when it never ran
# at all) - the exact "logged claim vs. unlogged reality" gap the ledger
# exists to prevent.
#
# HIMMEL-2378: binding the guard to the anchor's PATH alone (round 4's fix)
# still let a STALE value verify - a value equal to $anchor left over from an
# EARLIER run in the same shell verifies at ANY LATER branch/head, not just
# the run it was minted for, reproducing the same suppressed-ledger-row /
# delegated=yes gap round 4 closed, just narrower (stray/stale values only -
# forging the value outright grants no capability the actor does not already
# have from controlling $HIMMEL_REPO itself, so that is not the threat this
# closes). PR_CHECK_ANCHOR_DELEGATED now carries a 4-field capability,
# "$anchor|$branch|$head|$nonce", minted fresh for each delegation and bound
# to the (branch, head) it is handed off for. The nonce is also recorded in a
# file under the shared git-common-dir, BRANCH- AND HEAD-SCOPED
# ($git_dir/cr-delegation/$branch/$head, mirroring cr-prior-blocking/<branch>
# and cr-aggregate-verdicts/<branch> in write-verdicts.sh - "round 1b" there,
# for the branch half only) - NOT one shared file: $git_dir is the SAME
# shared git-common-dir across every worktree in the checkout, and himmel
# runs concurrent /pr-check on independent branches by design
# (overnight-shift), so a single unscoped file would let lane B's mint
# overwrite lane A's before lane A's delegate reads it - lane A's
# verification would then fail on the nonce (fail-safe: it never wrongly
# ACCEPTS) but, since its own recursion guard never got to fire, it
# delegates AGAIN, writing a second, spurious `delegation` ledger row for
# the same (branch, head). Branch-scoping closes that: two concurrent
# anchors touching different branches mint to different files and never
# collide. CR round 3 [codex-1]: branch alone was only HALF the reason -
# two overlapping checks on the SAME branch at DIFFERENT heads still
# collided on one slot (the identical defect, one level down), so head is
# also part of the path, not just a field inside the file. mkdir -p's the
# branch's parent directory (a
# nested branch like fix/x needs the same treatment write-verdicts.sh's own
# branch-scoped paths do) and its own write's exit status is checked - see
# the mint site below; a failed write must not delegate, same posture as a
# failed ledger-append.sh call - and, CR round 1 [codex-2], the mint (both
# the nonce and the capability FILE) happens before the ledger row is ever
# appended: a failed WRITE after an already-logged row would leave a real
# `delegation` row on record for a handoff that never happened, and worse,
# ledger_written would already be yes - condition (c) of the end-of-decision
# assertion below - leaving himmel_dir at the BRANCH for a delegation that
# never occurred. Minting first means a failed write never reaches
# ledger-append.sh at all. The delegate verifies the anchor field the same
# inode-safe way as before AND that branch/head/nonce all match its own
# resolved branch/head and the file's contents, THEN CONSUMES it - CR round 1
# [codex-3]: via `rm -f` (unlink), not `: >` truncation - an unlink is
# atomic (the directory entry either still names this inode or it doesn't,
# no partial-write window) - with its OWN exit status checked: an
# unconsumable capability is by definition not one-time, so a failed rm
# fails CLOSED (does not verify) rather than trusting a match it could not
# actually retire. (This does not defend against two DIFFERENT /pr-check
# processes both reading the file before either unlinks it - that needs two
# runs racing on the SAME branch at the SAME head, which the repo's
# single-writer convention rules out independently of this script.) A
# leftover from an earlier run now carries an earlier head and is rejected,
# not merely an earlier path. Legacy shape: a bare anchor PATH with no "|"
# (what an anchor checkout that predates HIMMEL-2378 still emits) is CR
# round 1 [codex-1] NO LONGER accepted - once the anchor itself carries this
# code it only ever mints the new 4-field shape, so after the upgrade window
# the only bare-path values still in circulation are exactly the
# stale/stray ones this ticket exists to reject; accepting them unbound and
# unconsumed would have swallowed this ticket's whole purpose. Consequence,
# deliberately accepted: an OLDER anchor handing a bare path to a NEWER
# delegate no longer verifies either - the delegate declines and (himmel
# lane, diff still touching scripts/cr/) delegates AGAIN itself, minting the
# new shape; that second hop's own delegate verifies normally. It converges
# after exactly ONE extra hop - every hop still logged, never unlogged,
# never infinite - at the cost of one extra ledger row, confined to the
# window between this landing and the primary checkout picking it up.
# Anything that does not verify: empty, "1", a stale path, a stale or
# already-consumed capability, a capability minted for a
# different branch or head - is treated as "not delegated", so the run
# proceeds through the normal delegation logic, which either delegates (and
# logs it) or soft-declines (and warns) - both safe, both logged.
# delegated=yes is printed ONLY on the verified-handshake path.
#
# Usage: pr-check-context.sh
#   No arguments - /pr-check itself takes none, ever (HIMMEL-2226). There is
#   no retarget: cwd selects the repo under review; HIMMEL_REPO (this
#   script's own env, re-read on every invocation including a delegated one)
#   selects the trusted anchor; the anchor/lane comparison above then picks
#   which checkout's scripts/cr/ actually runs. No fence in the runbook ever
#   cd's.
#   A set-but-EMPTY HIMMEL_REPO now hits the fence-level guard FIRST and
#   never reaches this script's own check #1 at all: the step-0 fence pipes
#   the assignment through `grep .` - `if himmel_repo=$(printenv HIMMEL_REPO
#   | grep .); then` - and `grep .` matches only a non-empty line, so an
#   empty `printenv` output fails the assignment and the fence takes its
#   else branch (the same "unset or empty" remedy message and exit 2 an
#   unset var gets), never invoking this script.
#   Before this fix the fence had no `| grep .`: `printenv HIMMEL_REPO` on a
#   set-but-empty var still printed (an empty line) and exited 0, so the old
#   `if himmel_repo=$(printenv HIMMEL_REPO); then` branch was taken with
#   `himmel_repo=""`, and `bash "$himmel_repo/scripts/cr/..."` collapsed to
#   `bash "/scripts/cr/pr-check-context.sh"` - an absolute path with no
#   leading directory. On a POSIX host with nothing at that path bash merely
#   reported "No such file or directory", rc=127 - documented at the time as
#   "fail-closed" - but under Git Bash on Windows that path resolves to
#   `C:\scripts\cr\pr-check-context.sh`, a location an ORDINARY user can
#   create without admin rights, and a file planted there would have
#   executed AS THE TRUSTED ENTRY POINT ahead of every check below. Do not
#   remove the `| grep .` from the fence.
#   This script's own check #1 below still guards every OTHER entry path (a
#   direct invocation, a test harness) the fence-level `| grep .` does not
#   gate. Remedy either way: adopt/setup wires HIMMEL_REPO into
#   settings.json `env`, or export it non-empty in the launching shell, then
#   re-run.
#
# Stdout contract - one "pr-check-context: key=value" line per datum, so the
# orchestrating session can read these back as literals in later fences (the
# prefix is grep-able and mirrors the old fence's
# "pr-check: repo=... branch=... base=... head=..." transcript line):
#   pr-check-context: himmel_dir=<absolute path to the checkout THIS run's
#     scripts/cr/ actually come from - the branch's own on the himmel lane,
#     the anchor on the adopter lane>
#   pr-check-context: repo=<absolute path to the repo under review ($PWD)>
#   pr-check-context: branch=<current branch>
#   pr-check-context: head=<full HEAD SHA>
#   pr-check-context: base=<protected default branch: main or master>
#   pr-check-context: marker=<path to the pending CR marker for this branch>
#   pr-check-context: lane=<the marker's 3rd field (full|docs-audit|...), or
#     empty when the marker does not exist yet>
#   pr-check-context: anchor_lane=<himmel|adopter, from the HIMMEL_REPO
#     git-common-dir comparison above - NOT the same field as lane= above,
#     which is the marker's own 3rd field and means something unrelated>
#   pr-check-context: delegated=<yes|no - "yes" only on the run that IS the
#     verified delegate (PR_CHECK_ANCHOR_DELEGATED carries a capability this
#     run's own (branch, head, and the one-time nonce recorded on disk) all
#     verify against, not merely "is set" - see "Identity handshake, not a
#     boolean" above): the branch copy the anchor handed off to, which then
#     produces the actual context>
#   pr-check-context: cr_diff_files=<comma-joined, sorted, deduped set this
#     run decided on for cr_diff_state (HIMMEL-3382) - the merge-base diff of
#     committed history plus working-tree/untracked changes under the
#     cr_guarded paths (HIMMEL-3493); empty when cr_diff_state is
#     no or unknown>
# Nothing else is written to stdout; diagnostics go to stderr.
#
# Side effects: pre-truncates (via scripts/cr/write-verdicts.sh, HIMMEL-2131)
# the two branch-scoped verdict scratch files under the reviewed repo's
# shared git-common-dir - see the HIMMEL-1219 comments below for why. A
# delegating anchor run also appends one `delegation` row to the CR ledger
# before handing off, and does NOT itself truncate the verdict-scratch files
# - the delegate run does that when IT resolves context, exactly once.
#
# Exit codes:
#   0  context resolved and printed, and either the verdict files were
#      truncated or this run delegated cleanly to the branch copy (which
#      then exits 0 itself, having done the truncation)
#   2  HIMMEL_REPO is unset or empty (no trusted anchor); this himmel
#      checkout could not be confirmed (scripts/cr/critic-panel.sh missing
#      under the resolved HIMMEL_ROOT); $PWD is not a git work tree; or a
#      verdict-file truncation failed. NOTE: a himmel-lane checkout whose own
#      toplevel cannot be resolved via `git rev-parse --show-toplevel` is NOT
#      in this list - like an unreadable diff or a failed merge-base, it
#      degrades to the anchor (rc=0, delegated=no) rather than aborting; see
#      "Anchor + delegation" above. Likewise a failed delegation ledger write
#      is NOT in this list any more - it warns on stderr and continues to a
#      normal exit 0 (delegated=no) instead of aborting; see "Anchor +
#      delegation" above.
#   3  the current branch name contains a character outside the safe alphabet
#      [A-Za-z0-9._/+-] that could break out of a substituted-literal fence
#      downstream (HIMMEL-2226); nothing is printed and no side effect runs
set -uo pipefail

# CodeRabbit security finding (HIMMEL-3382): clear every git-repo-selection
# env var this process may have inherited from its caller BEFORE the first
# git call below - GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR would otherwise
# silently retarget every `git` invocation in this script (including the
# HIMMEL_ROOT/anchor checks) at a repo this script never chose, and
# GIT_INDEX_FILE/GIT_OBJECT_DIRECTORY/GIT_ALTERNATE_OBJECT_DIRECTORIES/
# GIT_PREFIX carry the same risk for the index and object store.
#
# Console adversarial round 1 (HIMMEL-3454 finding 4): GIT_CONFIG_* was not
# covered, and a config value can retarget or hide input the same way a
# GIT_DIR override can - GIT_CONFIG_COUNT/KEY_0/VALUE_0=core.excludesFile
# hides an untracked file, GIT_CONFIG_PARAMETERS='core.fileMode=false' hides
# a mode change, and GIT_CONFIG_GLOBAL pointed at a scratch file carrying
# `[core] worktree = <anchor>` silently redirects every later git call at
# the anchor. Cleared the same way: every GIT_CONFIG_KEY_n/VALUE_n pair is
# caller-numbered, so they are found by scanning the actual environment
# rather than assumed to stop at index 0. GIT_CONFIG_NOSYSTEM is SET, not
# unset - unsetting it would let a system-level gitconfig back in, which is
# the opposite of this block's purpose.
#
# Console adversarial delta review (HIMMEL-3382): GIT_LITERAL_PATHSPECS/
# GIT_GLOB_PATHSPECS/GIT_NOGLOB_PATHSPECS/GIT_ICASE_PATHSPECS were not
# covered either. The diff/ls-files calls below rely on the `:(top)` magic
# pathspec to anchor at the worktree root regardless of cwd; an inherited
# GIT_LITERAL_PATHSPECS=1 turns `:(top)scripts/cr/` into a literal,
# non-existent path, so every one of the three calls silently returns empty
# and cr_diff_state falls back to "no" - a fail-open on exactly the diff this
# script exists to catch.
#
# HIMMEL-3472: GIT_REPLACE_REF_BASE too - it points git at a replace-ref
# namespace of the caller's choosing (the diff calls below also pass
# --no-replace-objects, the same pair guard-pr-check-literal.sh uses).
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX \
    GIT_CONFIG GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_COUNT GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS \
    GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS GIT_REPLACE_REF_BASE
while IFS='=' read -r gcvar _; do
    unset "$gcvar"
done < <(env | grep -E '^GIT_CONFIG_(KEY|VALUE)_[0-9]+=')
export GIT_CONFIG_NOSYSTEM=1

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
HIMMEL_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# HIMMEL-2335 - the trust anchor. Read from THIS script's own environment,
# never re-derived from cwd or a repo-supplied file (HIMMEL-2226 Finding 1) -
# a crafted repo under review must never be able to steer where himmel's
# scripts are believed to live. Refuses on unset OR EMPTY: a set-but-empty
# HIMMEL_REPO cannot reach this check at all through the runbook's own
# step-0 fence any more (the fence pipes the assignment through `grep .`,
# which fails on an empty printenv output and takes the else branch before
# this script ever runs - see the Usage note above), but every OTHER entry
# path (a direct invocation, a test harness, a future caller) still needs
# this defensive check to fail closed rather than silently treating an empty
# anchor as "no anchor comparison needed".
anchor="${HIMMEL_REPO:-}"
if [ -z "$anchor" ]; then
    echo "pr-check-context: HIMMEL_REPO is unset or empty - cannot locate himmel from a trusted source outside the repo under review; adopt/setup wires it into settings.json env, or export it in your launching shell, then re-run" >&2
    exit 2
fi

# HIMMEL-3359 - the himmel-lane RELATIVE entry. A leg may start step 0 as the
# bare literal `bash scripts/cr/pr-check-context.sh` (the one shape a
# permission allow rule can match; the canonical fence is a compound no rule
# can). That runs THIS copy - the branch's - so a copy that is not the
# anchor's never decides anything: it hands straight to the anchor's copy,
# which then makes the lane + delegation decision and writes the delegation
# row exactly as the canonical entry does, delegating back here with a
# capability when the diff touches scripts/cr/. The hand-off runs HERE, before
# this copy sources anything of the branch's own (guardrails/lib.sh is sourced
# only further down): a branch that edits only lib.sh is not a scripts/cr/
# diff, so the bare literal is permitted on it, and its lib.sh must never get
# a chance to reassign HIMMEL_REPO or print a forged context first. The only
# run allowed past this point is one whose PR_CHECK_ANCHOR_DELEGATED has the
# full anchor|branch|head|nonce shape and names THIS anchor, and that run
# still hands off below (after the capability check, before lib.sh) unless
# it is the FULLY verified delegate. A stray value, a bare anchor path or a
# bare `1` hands off like no value at all. A missing anchor copy fails closed
# rather than letting this copy decide for itself.
# ponytail: this guard is defense in depth, NOT the trust root. It lives in
# the branch's own bytes, so a branch that deletes it also deletes the
# hand-off. The trust root is the runbook condition (console ruling): the bare
# literal is permitted only on a diff that touches no cr_guarded path
# (scripts/cr/, scripts/lib/, scripts/guardrails/lib.sh, scripts/check-ci.sh,
# scripts/handover/resolve-active-item.sh), and a branch that could delete
# this guard is exactly such a diff, which must enter by the canonical absolute fence.
hand_off_to_anchor() {
    if [ ! -f "$anchor/scripts/cr/pr-check-context.sh" ]; then
        echo "pr-check-context: entered through a non-anchor copy ($SCRIPT_DIR) and the anchor carries no scripts/cr/pr-check-context.sh ($anchor) - refusing to let this copy decide; fix HIMMEL_REPO, then re-run" >&2
        exit 2
    fi
    echo "pr-check-context: entered through a non-anchor copy ($SCRIPT_DIR) - handing off to the anchor's copy ($anchor/scripts/cr/pr-check-context.sh)" >&2
    exec bash "$anchor/scripts/cr/pr-check-context.sh"
}
if ! [ "$HIMMEL_ROOT" -ef "$anchor" ]; then
    guard_anchor="${PR_CHECK_ANCHOR_DELEGATED:-}"
    case "$guard_anchor" in
        *'|'*'|'*'|'*) ;;
        *) hand_off_to_anchor ;;
    esac
    guard_anchor="${guard_anchor%|*}"
    guard_anchor="${guard_anchor%|*}"
    guard_anchor="${guard_anchor%|*}"
    if ! { [ -n "$guard_anchor" ] && [ "$guard_anchor" -ef "$anchor" ]; }; then
        hand_off_to_anchor
    fi
fi

# Fail closed if HIMMEL_ROOT does not look like a himmel checkout - every
# later step (sourcing lib.sh, calling write-verdicts.sh) depends on it.
if [ ! -f "$HIMMEL_ROOT/scripts/cr/critic-panel.sh" ]; then
    echo "pr-check-context: cannot find $HIMMEL_ROOT/scripts/cr/critic-panel.sh - HIMMEL_ROOT resolved wrong, aborting" >&2
    exit 2
fi

repo="$PWD"
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "pr-check-context: $repo is not a git work tree - aborting" >&2
    exit 2
fi

# HIMMEL-2335 - lane comparison, moved here from the runbook's old step-0
# fence (an inline `[ "$cwd_common" -ef "$HIMMEL_REPO/.git" ]` test on a
# command-substitution value is refused by the worktree-isolation guard;
# see the header comment). Inode compare (`-ef`), not a string compare, so a
# trailing slash / symlink / slash-style / Windows-casing difference between
# the two paths cannot misclassify the lane - a foreign repo cannot fake a
# match short of being a registered worktree of the anchor itself.
cwd_common=$(git rev-parse --path-format=absolute --git-common-dir)
if [ "$cwd_common" -ef "$anchor/.git" ]; then
    anchor_lane=himmel
    # Deliberate - NOT $anchor: this is what lets a change to THIS branch's
    # own scripts/cr/ review itself (see "Anchor + delegation" above). Safe
    # because the git-common-dir match already proved the cwd is himmel.
    # Checked (not bare $(...)): an unchecked failure here would leave
    # himmel_dir empty rather than falling back to the anchor, and unlike
    # the cwd_common comparison above (whose failure lands on the already-
    # conservative adopter/anchor branch) an empty himmel_dir has no such
    # safe default. Same rule as the diff-read check below: a failure here
    # degrades to the anchor (himmel_dir_is_anchor=yes short-circuits the
    # delegation block entirely, so cr_diff_state stays at its "unknown"
    # default and delegated stays "no") rather than a hard abort - this run
    # still produces a full, usable context on rc=0.
    if himmel_dir=$(git rev-parse --show-toplevel); then
        # -ef, not a string compare: on the self-review case (cwd IS the
        # anchor, no delegate involved) $himmel_dir and $anchor name the same
        # directory but can be spelled differently (trailing slash / casing).
        # The single end-of-decision assertion below relies on this flag.
        himmel_dir_is_anchor=no
        if [ "$himmel_dir" -ef "$anchor" ]; then
            himmel_dir_is_anchor=yes
        fi
    else
        echo "pr-check-context: could not resolve this checkout's toplevel via git rev-parse --show-toplevel - falling back to the anchor ($anchor); this branch's own scripts/cr/ was NOT self-reviewed this run" >&2
        himmel_dir="$anchor"
        himmel_dir_is_anchor=yes
    fi
else
    anchor_lane=adopter
    # Never anything the reviewed repo supplied.
    himmel_dir="$anchor"
    himmel_dir_is_anchor=yes
fi

branch=$(git branch --show-current)
# HIMMEL-2226 - refuse a branch name carrying a shell metacharacter BEFORE it
# is printed. Every later /pr-check fence substitutes this value as literal
# TEXT (e.g. --branch '<branch>'), and the branch is repo-controlled on an
# adopter repo or a throwaway clone of an upstream PR (HIMMEL-2035), so a
# single quote in the name breaks out of the substituted literal and injects
# shell - the same substituted-literal class as $ARGUMENTS and <marker>. A
# prose "escape or refuse" convention cannot fire before the shell parses
# pasted text, so this is a structural refusal at the one chokepoint every
# lane runs first, killing the class for all 23 substitution sites at once.
# ALLOWLIST (not a denylist - a denylist can miss a metacharacter): the exact
# safe ref-name alphabet git itself accepts for a branch;
# himmel's own type/slug branches are a strict subset, so this refuses nothing
# that works today. An empty branch (detached HEAD) does not match and is left
# to the existing behaviour. Distinct exit code 3 - NOT 2 - so this input
# refusal is diagnosable apart from the environment-resolution failures above.
case "$branch" in
    *[!A-Za-z0-9._/+-]*)
        offending=$(printf '%s' "$branch" | tr -d 'A-Za-z0-9._/+-')
        echo "pr-check-context: branch name '$branch' contains character(s) outside the safe alphabet [A-Za-z0-9._/+-] ('$offending') that could break out of a substituted-literal /pr-check fence (HIMMEL-2226) - rename the branch and re-run" >&2
        exit 3
        ;;
esac
head=$(git rev-parse HEAD)
# Use --git-common-dir (shared .git), not --git-dir (per-worktree), so the
# marker lookup matches the pre-push hook's write path even when /pr-check is
# invoked from a different worktree.
git_dir=$(git rev-parse --git-common-dir)
marker="$git_dir/cr-pending/$branch"

# HIMMEL-2335 round 4 (CR panel [codex-2]) / HIMMEL-2378 - identity handshake
# bound to (branch, head) and one-time, not a bare boolean and not merely
# anchor-path equality (see the header comment "Identity handshake, not a
# boolean"). PR_CHECK_ANCHOR_DELEGATED carries "$anchor|$branch|$head|$nonce"
# from a genuine delegating anchor. "|" is safe as the field separator: the
# branch alphabet is restricted to [A-Za-z0-9._/+-] (checked above, before
# this point) and head/nonce are both hex, so none of those three trailing
# fields can ever contain "|" - only the anchor (a filesystem path)
# conceivably could, which is why the fields are peeled off the RIGHT below
# (three single-field strips), leaving whatever remains - "|" included - as
# the anchor field, rather than a left-to-right split desyncing on it.
# CR round 1 [codex-1]: a bare anchor PATH from an anchor checkout that
# predates HIMMEL-2378 never contains "|" either, but is NO LONGER accepted
# below - see the header comment "Identity handshake, not a boolean" for why
# and for the one-extra-hop consequence.
guard_val="${PR_CHECK_ANCHOR_DELEGATED:-}"
verified_delegate=no
# Branch- AND head-scoped (CR round 3 [codex-1] - branch-scoping alone was
# only half the reason: it fixed lane-A-vs-lane-B (two DIFFERENT branches
# colliding on one slot), but left run-at-head-A-vs-run-at-head-B on the
# SAME branch unfixed - two overlapping checks on the same branch at
# different heads still overwrote each other's slot before either
# consumed it, same defect class, one level down). head as a nested path
# component (not appended into one filename): mkdir -p already creates the
# branch's own directory for a nested branch like fix/x (see the mint site
# below), so nesting head one level deeper costs nothing extra and needs
# no new separator-safety argument (a git object id is hex only, never
# contains "/"). Same shape as marker="$git_dir/cr-pending/$branch" above
# and write-verdicts.sh's own cr-prior-blocking/<branch>,
# cr-aggregate-verdicts/<branch> for the branch half of it.
cap_file="$git_dir/cr-delegation/$branch/$head"
if [ -n "$guard_val" ]; then
    case "$guard_val" in
    *'|'*)
        # New shape: anchor|branch|head|nonce, peeled from the right.
        g_nonce="${guard_val##*|}"
        g_rest="${guard_val%|*}"
        g_head="${g_rest##*|}"
        g_rest="${g_rest%|*}"
        g_branch="${g_rest##*|}"
        g_anchor="${g_rest%|*}"
        anchor_ok=no
        if [ -d "$g_anchor" ] && [ -d "$anchor" ]; then
            ! [ "$g_anchor" -ef "$anchor" ] || anchor_ok=yes
        elif [ "$g_anchor" = "$anchor" ]; then
            anchor_ok=yes
        fi
        if [ "$anchor_ok" = yes ] && [ "$g_branch" = "$branch" ] \
           && [ "$g_head" = "$head" ] && [ -f "$cap_file" ]; then
            # Cross-check the env-carried nonce against the file the minting
            # anchor also wrote it to (same branch+head recorded there too) -
            # a value that only matches the env side proves nothing, since
            # the env is exactly what a stray export or a hostile launching
            # shell controls.
            cap_line=$(cat "$cap_file" 2>/dev/null) || cap_line=""
            cf_nonce="${cap_line##*|}"
            cf_rest="${cap_line%|*}"
            cf_head="${cf_rest##*|}"
            cf_branch="${cf_rest%|*}"
            if [ -n "$cf_nonce" ] && [ "$cf_nonce" = "$g_nonce" ] \
               && [ "$cf_branch" = "$branch" ] && [ "$cf_head" = "$head" ]; then
                # CR round 2 [codex-1]: consume by CLAIMING the file, and
                # let the claim decide the verdict. `rm` WITHOUT -f is the
                # claim primitive: unlink is atomic, so of two processes
                # racing on the same capability exactly ONE gets rc=0 and
                # the loser gets ENOENT and fails closed. Round 1 used
                # `rm -f`, which is NOT a claim at all - it reports success
                # even when another process already removed the file, so
                # both racers would have set verified_delegate=yes. The
                # earlier comment leaned on the single-writer convention to
                # excuse that; a convention this script does not enforce is
                # not a substitute for a primitive that is correct on its
                # own. stderr is dropped because losing the race is an
                # ordinary outcome here, not an error to report.
                if rm "$cap_file" 2>/dev/null; then
                    verified_delegate=yes
                fi
            fi
        fi
        ;;
    *)
        # CR round 1 [codex-1]: the legacy (pre-HIMMEL-2378, round-4) bare
        # anchor-path shape is EXPLICITLY REFUSED here, not merely "falls
        # through" - once the anchor itself carries this code it only ever
        # mints the new 4-field shape, so the only bare-path values still in
        # circulation afterward are exactly the stale/stray ones this
        # ticket exists to reject (a leftover export, a value pasted from an
        # old terminal); accepting them unbound and un-consumed would
        # swallow this whole ticket's purpose. verified_delegate stays "no"
        # - the normal delegation logic below then either delegates (and
        # logs it) or soft-declines (and warns), same as any other
        # unverified value. Consequence, deliberately accepted: an OLDER
        # anchor handing a bare path to a NEWER delegate no longer verifies
        # either - the delegate declines and, still on the himmel lane with
        # the diff still touching scripts/cr/, delegates AGAIN itself,
        # minting the new shape; that second hop's own delegate verifies
        # normally. It converges after exactly ONE extra hop - every hop
        # still logged, never unlogged, never infinite.
        ;;
    esac
fi

# HIMMEL-3359 - a non-anchor copy that reached here carried a capability of
# the right shape, but only the FULLY verified delegate may run on: anything
# else (a stale or forged value that merely names this anchor) hands off to
# the anchor now, before this copy sources the branch's lib.sh or can elect
# itself into the delegation block below. One hop only: if the anchor this
# copy already handed off to delegates back with a capability that still
# fails, the anchor is broken (it logged a row for a capability it never
# wrote) and a second hand-off would loop forever - fail closed instead.
if ! [ "$HIMMEL_ROOT" -ef "$anchor" ] && [ "$verified_delegate" = no ]; then
    if [ -n "${PR_CHECK_ANCHOR_HANDED_OFF:-}" ]; then
        echo "pr-check-context: the anchor ($anchor) delegated to this copy ($SCRIPT_DIR) again with a capability it cannot verify - refusing rather than hand off in a loop" >&2
        exit 2
    fi
    export PR_CHECK_ANCHOR_HANDED_OFF=1
    hand_off_to_anchor
fi

# guardrails/lib.sh gives default_branch (main OR master, HIMMEL-297).
# shellcheck source=../guardrails/lib.sh
# shellcheck disable=SC1091
if ! . "$HIMMEL_ROOT/scripts/guardrails/lib.sh" 2>/dev/null; then
    echo "pr-check-context: cannot source guardrails/lib.sh - aborting" >&2
    exit 2
fi
# Same fallback the old step-0 fence used: default_branch already always
# prints a non-empty name on its own, this is defense in depth only.
base=$(default_branch "$repo")
[ -n "$base" ] || base=main
# Console adversarial round 1 (HIMMEL-3454 finding 2/5): a bare branch name
# is ambiguous - `git merge-base HEAD main` can resolve a same-named TAG
# ahead of the branch, silently shrinking the diff. Match the runbook's own
# step-0 precheck, which always spells this out in full: prefer the
# remote-tracking ref, falling back to the local branch only when the
# remote ref is absent (never a bare name).
base_ref="refs/remotes/origin/$base"
if ! git rev-parse --verify -q "$base_ref" >/dev/null 2>&1; then
    base_ref="refs/heads/$base"
fi

# HIMMEL-2335 - deliberate delegation. himmel lane ONLY: the trusted anchor
# decides whether execution hands off to the branch's own copy of this
# script, and logs that decision - the branch never elects itself. Every
# precondition below must hold, or this run does its own work exactly as
# before (delegated stays "no").
#
# HIMMEL-3382 - the diff: the merge-base diff of COMMITTED history PLUS
# WORKING-TREE and UNTRACKED changes, scoped to cr_guarded (HIMMEL-3382 added
# scripts/guardrails/lib.sh, which this script sources; HIMMEL-3493 added
# scripts/lib/, scripts/check-ci.sh and scripts/handover/resolve-active-item.sh,
# which a "no" run executes from the branch). The runbook's step-0 himmel-lane
# precheck (both twins) runs the same diff over the same paths, but this
# script ALSO compares bytes (HIMMEL-3472) and ignores __pycache__/, so the
# precheck's silence is necessary, not sufficient, for a "no" here - the
# fence fails safe. Each of the three git calls
# below is scoped to those paths directly via its own pathspec, not a
# post-hoc `grep '^scripts/cr/'` filter, and each has its own exit status
# checked separately - nothing here pipes a git call's output into grep, so
# the pre-HIMMEL-3382 pipefail/SIGPIPE hazard this comment used to document
# (a failed `git diff` piped into `grep -q` misread as a clean diff) cannot
# recur. cr_diff_files carries the exact set decided on (sorted, deduped,
# printed on stdout below) - cr_diff_state is TRI-STATE, computed once:
# =no (every git call succeeded, the set is empty), =yes (every git call
# succeeded, the set is non-empty), or =unknown (merge-base or any of the
# three calls failed - never delegate on an unknown diff, and the single
# end-of-decision assertion below treats "unknown" the same as "yes": both
# refuse to leave himmel_dir at the branch unlogged).
#
# HIMMEL-3472 - the git diff alone can read clean while the branch's bytes
# differ, and a false "no" leaves himmel_dir at the branch unlogged. A leg
# can move refs/remotes/origin/main to its own HEAD (the ref lives in the
# shared git-common-dir), map the base's tree onto its own with a replace
# ref, set assume-unchanged/skip-worktree index bits, configure a clean
# filter or an fsmonitor hook that reports nothing, or set core.fileMode=false
# over an exec-bit change; and scripts/cr inherited from main as a symlink
# takes the real files outside the pathspec. So "no" also requires the
# branch's guarded files to equal the ANCHOR's WORKING TREE byte for byte and
# mode for mode - the bytes this script falls back to when it refuses the
# branch - hashed the way guard-pr-check-literal.sh does it: find + git
# hash-object --no-filters, so no ref, index bit, filter, fsmonitor or
# fileMode setting is consulted. The anchor tree is the base, not a ref,
# because every ref is one update-ref away for a leg. The comparison only
# refines a "no": a git "no" whose bytes differ becomes "unknown", never
# "yes" - it cannot tell a hidden edit from a primary checkout that is behind
# or ahead of the branch's base (T37: main's later scripts/cr/ commit is not
# the branch's change), so it delegates nothing and the anchor's copy runs.
#
# HIMMEL-3493 - the scope is what a "no" run executes from the branch, not
# just scripts/cr/: later /pr-check fences run <himmel_dir>/scripts/cr/*,
# which source the shared libs under scripts/lib/ (load-dotenv,
# shared-branch-lock, gh-graphql-budget, cr-default-base, proc-tree, ...),
# and the runbook also runs <himmel_dir>/scripts/check-ci.sh (more
# scripts/lib/) and scripts/handover/resolve-active-item.sh (lib/handover-
# path.sh). The whole scripts/lib/ directory is guarded, not a hand-kept
# list: an edit to a lib nothing reaches only turns "no" into a delegation
# or unknown, the fail-safe direction. test-cr-guarded-closure.sh derives
# the closure from the scripts and the runbook twins and fails when a new
# source or exec site reaches outside this list. __pycache__/ directories
# are left out of both the diff and the manifest: the primary checkout
# carries an ignored scripts/lib/__pycache__/ from the VM tooling, which
# would make every branch's bytes differ, and no /pr-check path runs
# Python from scripts/lib/.
gitd() { git --no-replace-objects -c core.fsmonitor=false -c core.untrackedCache=false "$@"; }
#
# The closure also follows script paths stored in a variable and run later
# (console adversarial review of #1148): handover-bridge.sh hands
# append-cr-{findings,bugs}.sh (and bug.sh) to node, critic-panel.sh runs
# ${CRITIC_INVOKE:-.../hermes/invoke.sh} (egress-gate.sh and the egress
# matrix it evaluates, the alibaba quota probe under scripts/telegram/), and
# bank-preflight.sh runs the statusline usage-cache producer and the
# scripts/lanes/bank-status.ts chain. Those are guarded file by file, not by
# directory, so a branch touching an unrelated lane or telegram file keeps
# its relative himmel-lane spelling. egress-matrix.json is data, not code,
# but it is the egress policy invoke.sh enforces, so it is guarded too.
cr_guarded="scripts/cr scripts/lib scripts/guardrails/lib.sh scripts/check-ci.sh scripts/handover/resolve-active-item.sh
scripts/handover/append-cr-findings.sh scripts/handover/append-cr-bugs.sh scripts/handover/bug.sh
scripts/hermes/invoke.sh scripts/hermes/egress-gate.sh
scripts/guardrails/egress-matrix-eval.mjs scripts/guardrails/egress-matrix.json
scripts/statusline/usage-cache-producer.sh
scripts/lanes/bank-status.ts scripts/lanes/bank-status-core.mjs scripts/lanes/funded-max-pct.mjs
scripts/lanes/resolve.mjs scripts/lanes/check.mjs scripts/lanes/probe.mjs scripts/lanes/set-lane-override.mjs
scripts/observability/quota-sources.ts
scripts/telegram/alibaba-probe-once.ts scripts/telegram/quota-gauge.ts scripts/telegram/quota-gauge-alibaba.ts"
cr_pathspecs=(':(top)scripts/cr/' ':(top)scripts/lib/' ':(top)scripts/guardrails/lib.sh' ':(top)scripts/check-ci.sh'
    ':(top)scripts/handover/resolve-active-item.sh'
    ':(top)scripts/handover/append-cr-findings.sh' ':(top)scripts/handover/append-cr-bugs.sh' ':(top)scripts/handover/bug.sh'
    ':(top)scripts/hermes/invoke.sh' ':(top)scripts/hermes/egress-gate.sh'
    ':(top)scripts/guardrails/egress-matrix-eval.mjs' ':(top)scripts/guardrails/egress-matrix.json'
    ':(top)scripts/statusline/usage-cache-producer.sh'
    ':(top)scripts/lanes/bank-status.ts' ':(top)scripts/lanes/bank-status-core.mjs' ':(top)scripts/lanes/funded-max-pct.mjs'
    ':(top)scripts/lanes/resolve.mjs' ':(top)scripts/lanes/check.mjs' ':(top)scripts/lanes/probe.mjs'
    ':(top)scripts/lanes/set-lane-override.mjs'
    ':(top)scripts/observability/quota-sources.ts'
    ':(top)scripts/telegram/alibaba-probe-once.ts' ':(top)scripts/telegram/quota-gauge.ts'
    ':(top)scripts/telegram/quota-gauge-alibaba.ts'
    ':(top,exclude,glob)scripts/**/__pycache__/**')
cr_manifest() { # cr_manifest <root> - "<mode> <blob-id> <path>" per guarded file, sorted
    local root=$1 odd files execs oids modes p d present=()
    # A symlink or other non-regular entry (a symlinked parent directory of
    # any guarded entry too) cannot be compared file for file: say ODD and
    # let the caller decide unknown.
    for p in $cr_guarded; do
        d=$p
        while d=$(dirname "$d") && [ "$d" != . ]; do
            if [ -L "$root/$d" ]; then echo ODD; return 0; fi
        done
    done
    # Only the entries this tree has: an entry missing from both trees
    # contributes nothing to either side, and one missing from only one
    # tree makes the manifests differ.
    for p in $cr_guarded; do
        if [ -e "$root/$p" ] || [ -L "$root/$p" ]; then present+=("$p"); fi
    done
    [ "${#present[@]}" -gt 0 ] || return 1
    odd=$(cd "$root" && find "${present[@]}" -type d -name __pycache__ -prune -o \( \( ! -type d ! -type f \) -o -name '*[[:cntrl:]]*' \) -print 2>/dev/null) || return 1
    [ -z "$odd" ] || { echo ODD; return 0; }
    files=$(cd "$root" && find "${present[@]}" -type d -name __pycache__ -prune -o -type f -print 2>/dev/null) || return 1
    [ -n "$files" ] || return 1
    execs=$(cd "$root" && find "${present[@]}" -type d -name __pycache__ -prune -o -type f -perm -100 -print 2>/dev/null) || return 1
    oids=$(printf '%s\n' "$files" \
        | git --no-replace-objects -C "$root" -c core.fsmonitor=false hash-object --no-filters --stdin-paths 2>/dev/null) || return 1
    modes=$(awk 'NR == FNR { x[$0] = 1; next } { print (($0 in x) ? "100755" : "100644") }' \
        <(printf '%s\n' "$execs") <(printf '%s\n' "$files")) || return 1
    [ "$(printf '%s\n' "$files" | wc -l)" = "$(printf '%s\n' "$oids" | wc -l)" ] || return 1
    paste -d' ' <(printf '%s\n' "$modes") <(printf '%s\n' "$oids") <(printf '%s\n' "$files") | LC_ALL=C sort
}
delegated=no
cr_diff_state=unknown
cr_diff_files=
ledger_written=no
if [ "$anchor_lane" = "himmel" ] && [ "$himmel_dir_is_anchor" = no ]; then
    # Console adversarial round 1 (HIMMEL-3454 finding 1): a plain pathspec
    # is resolved relative to CWD, not the repo root - invoked from a
    # subdirectory it silently misses the guarded paths entirely. ":(top)"
    # anchors each pathspec to the worktree root regardless of cwd (finding 3): dropping --exclude-standard from the untracked-files
    # call also counts a GITIGNORED file under these paths - an unreviewed
    # scripts/cr/ change hidden behind .gitignore must not read as "no diff".
    # HIMMEL-3472: no replace refs, no repo-configured fsmonitor. --full-name
    # on the untracked leg: run from a subdirectory it otherwise prints
    # cwd-relative paths while both diff legs print top-relative ones.
    if mb=$(gitd merge-base HEAD "$base_ref" 2>/dev/null); then
        if committed_files=$(gitd diff --name-only "$mb"..HEAD -- "${cr_pathspecs[@]}" 2>/dev/null); then
            if worktree_files=$(gitd diff --name-only HEAD -- "${cr_pathspecs[@]}" 2>/dev/null); then
                if untracked_files=$(gitd ls-files --others --full-name -- "${cr_pathspecs[@]}" 2>/dev/null); then
                    # HIMMEL-3472 (HIMMEL-3454 round-1 codex-2): the
                    # normalizer's own status is checked too - a failed
                    # sort would otherwise yield an empty set, read as "no".
                    # awk, not grep -v: grep exits 1 on an empty result.
                    if cr_diff_files=$(printf '%s\n%s\n%s\n' "$committed_files" "$worktree_files" "$untracked_files" | awk 'length' | sort -u); then
                        if [ -n "$cr_diff_files" ]; then
                            cr_diff_state=yes
                        else
                            cr_diff_state=no
                        fi
                    else
                        cr_diff_files=
                        echo "pr-check-context: could not normalize the guarded diff set ($cr_guarded) - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
                    fi
                else
                    echo "pr-check-context: could not compute git ls-files --others -- $cr_guarded - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
                fi
            else
                echo "pr-check-context: could not compute git diff --name-only HEAD -- $cr_guarded - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
            fi
        else
            echo "pr-check-context: could not compute git diff --name-only $mb..HEAD -- $cr_guarded - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
        fi
    else
        echo "pr-check-context: could not compute merge-base HEAD..$base_ref - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
    fi

    # HIMMEL-3472 - the byte comparison against the anchor (see above). Only
    # a "no" is checked: "yes" already delegates with a row, and unknown
    # stays unknown.
    if [ "$cr_diff_state" = no ]; then
        if ! branch_manifest=$(cr_manifest "$himmel_dir") || ! anchor_manifest=$(cr_manifest "$anchor"); then
            echo "pr-check-context: could not hash the guarded paths ($cr_guarded) in the branch ($himmel_dir) or the anchor ($anchor) - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
            cr_diff_state=unknown
        elif [ "$branch_manifest" = ODD ] || [ "$anchor_manifest" = ODD ]; then
            echo "pr-check-context: a symlink, non-regular file or control-character name sits under the guarded paths ($cr_guarded) in the branch ($himmel_dir) or the anchor ($anchor) - cr_diff_state=unknown (never delegate on an unknown diff)" >&2
            cr_diff_state=unknown
        elif [ "$branch_manifest" != "$anchor_manifest" ]; then
            byte_files=$(LC_ALL=C comm -3 <(printf '%s\n' "$anchor_manifest") <(printf '%s\n' "$branch_manifest") \
                | awk '{ sub(/^\t/, ""); sub(/^[^ ]* [^ ]* /, ""); print }' | LC_ALL=C sort -u | tr '\n' ' ')
            echo "pr-check-context: git reports no change under the guarded paths ($cr_guarded), but the branch's bytes ($himmel_dir) differ from the anchor's ($anchor): $byte_files- cr_diff_state=unknown (never delegate on an unknown diff; the anchor's copy runs)" >&2
            cr_diff_state=unknown
        fi
    fi

    # Attempt delegation only when the diff is KNOWN to touch scripts/cr/,
    # this run is not itself the verified delegate (recursion guard - see
    # "Identity handshake, not a boolean" above), and the branch actually
    # carries its own copy of this script to delegate to.
    if [ "$cr_diff_state" = yes ] \
       && [ "$verified_delegate" = no ] \
       && [ -f "$himmel_dir/scripts/cr/pr-check-context.sh" ]; then
        # CR round 1 [codex-2]: mint the nonce and write the capability file
        # BEFORE logging the ledger row - reordered from an earlier draft
        # that logged first. Order matters: a failed WRITE after an
        # already-appended ledger row would leave a real `delegation` row on
        # record for a handoff that never happened - and worse,
        # ledger_written would already be yes, which is condition (c) of the
        # end-of-decision assertion below, so himmel_dir would be left at
        # the BRANCH for a delegation that never occurred. Minting first
        # means a failed write never reaches ledger-append.sh at all: zero
        # rows, ledger_written stays no, and the assertion correctly forces
        # the anchor. openssl is Git for Windows' own bundled dependency (it
        # ships openssl.exe for HTTPS transport), so it is present in every
        # Git Bash this script already requires; /dev/urandom+od is the
        # POSIX fallback if some environment lacks it, and $RANDOM/$$/head
        # is a last resort that is not cryptographically strong but is
        # still unpredictable enough to defeat a STALE value (the threat
        # this closes - see the header comment) since a stale value can
        # never carry a LATER run's nonce, whatever its quality.
        cap_nonce=$(openssl rand -hex 16 2>/dev/null) || cap_nonce=""
        if [ -z "$cap_nonce" ]; then
            cap_nonce=$(head -c16 /dev/urandom 2>/dev/null | od -An -tx1 | tr -d ' \n') || cap_nonce=""
        fi
        [ -n "$cap_nonce" ] || cap_nonce="$RANDOM$RANDOM$$-$head"
        # mkdir -p the branch's own directory - now $head's immediate
        # parent (CR round 3 [codex-1]: cr-delegation/<branch>/<head>, not
        # just <branch>) - a nested branch like fix/himmel-2378-x still
        # needs cr-delegation/fix/himmel-2378-x/ created first, same as
        # write-verdicts.sh's own branch-scoped paths, and check the
        # write's own exit status - this file is a gate input, and this
        # script checks every $(...) / write whose failure matters.
        if mkdir -p "$(dirname "$cap_file")" 2>/dev/null \
           && printf '%s|%s|%s\n' "$branch" "$head" "$cap_nonce" > "$cap_file"; then
            # (a) the capability exists on disk - NOW the ANCHOR's own
            # ledger-append.sh logs the delegation it is about to make. On
            # success, hand off below. On failure - most commonly the anchor
            # checkout predates HIMMEL-2335 and its ledger-append.sh does
            # not know the "delegation" kind yet - the invariant is "never
            # delegate UNLOGGED", and declining to delegate satisfies it
            # exactly, so this WARNS and falls through to the single
            # end-of-decision assertion below instead of aborting the whole
            # gate over a logging failure.
            if bash "$anchor/scripts/cr/ledger-append.sh" delegation \
                    --branch "$branch" --head "$head" \
                    --reason "diff touches scripts/cr/ - branch self-review required" \
                    --detail "anchor=$anchor delegate=$himmel_dir"; then
                ledger_written=yes
                # (b) diagnostic naming anchor, delegate, head and reason.
                echo "pr-check-context: delegating to the branch's own scripts/cr/pr-check-context.sh - this diff (head=$head) touches scripts/cr/, so branch self-review takes over. anchor=$anchor delegate=$himmel_dir" >&2
                # (c) hand off. PR_CHECK_ANCHOR_DELEGATED="$anchor|$branch|
                # $head|$cap_nonce" - never a bare path or boolean - is what
                # the delegate copy's guard above verifies against: only a
                # value whose anchor matches its own resolved $anchor AND
                # whose branch/head match its own AND whose nonce matches
                # the file just written satisfies it, so a stray/foreign/
                # stale value in the delegate's environment can never forge
                # this handshake. That disables the delegate copy's own
                # delegation check (recursion guard), so it produces the
                # actual context instead of re-delegating forever.
                PR_CHECK_ANCHOR_DELEGATED="$anchor|$branch|$head|$cap_nonce" exec bash "$himmel_dir/scripts/cr/pr-check-context.sh"
            fi
            # CR round 4 [codex-2]: the capability was minted for a handoff
            # that is not happening, so drop it rather than leave an orphan
            # under cr-delegation/<branch>/<head> - now that the slot is
            # head-scoped, repeated failures across heads accumulate one
            # stale file each instead of overwriting a single slot.
            rm -f "$cap_file"
            echo "pr-check-context: WARNING - could not log the delegation through the anchor's ledger-append.sh ($anchor/scripts/cr/ledger-append.sh), most likely because it does not support the 'delegation' kind, meaning the anchor checkout is OLDER than this branch; remedy: upgrade the primary checkout so it can review this branch's own scripts/cr/ changes." >&2
        else
            echo "pr-check-context: WARNING - could not write the delegation capability file ($cap_file) - declining to delegate rather than log a delegation whose handoff capability was never written." >&2
        fi
    fi
fi
# delegated=yes ONLY on the verified handshake (guard_val equals THIS run's
# own resolved anchor) - never merely "the env var was set to something".
[ "$verified_delegate" = no ] || delegated=yes

# HIMMEL-2335 round 6 - the single end-of-decision assertion. This REPLACES
# the three separate per-branch himmel_dir="$anchor" patches that CR rounds
# 3, 4 and 5 each added independently for the SAME underlying defect (a
# branch of this decision left himmel_dir at the BRANCH when it should not
# have: soft-decline/ledger-write-failure, spoofed recursion guard, and an
# unknown merge-base). himmel_dir may be left pointing at the BRANCH (i.e.
# this run's own scripts/cr/, or a genuine delegate's, executes on every
# later /pr-check fence) ONLY IF:
#   (a) cr_diff_state=no          - everything a "no" run executes from the
#       branch (cr_guarded: scripts/cr/, scripts/lib/, guardrails/lib.sh,
#       check-ci.sh, handover/resolve-active-item.sh - the closure
#       test-cr-guarded-closure.sh pins) matches the anchor's byte for byte
#       and mode for mode at step 0, OR
#       ponytail: "at step 0" only. Nothing pins those bytes between this
#       check and the later fences that execute them, so an edit made to the
#       branch's guarded files AFTER step 0 (a background job, a swapped
#       hard link) runs unchecked (TOCTOU). Only running the anchor's copy on
#       "no" closes that, at the cost of the relative himmel-lane spelling
#       (HIMMEL-3338); tracked on HIMMEL-3497.
#   (b) verified_delegate=yes     - this run IS the verified delegate a
#       genuine anchor handed off to (the identity handshake above), OR
#   (c) ledger_written=yes        - this run IS the anchor and its own
#       ledger-append.sh call just above succeeded (covers the
#       never-exercised-in-practice case where the exec on the line above
#       itself then fails and this process falls through to run the rest of
#       its OWN script instead of the delegate's - falling back to the
#       anchor here would be safe but wrong, since the delegation this run
#       just logged is real).
# Any other combination - a not-known-clean diff (yes or unknown) with NONE
# of (a)/(b)/(c) true - forces himmel_dir back to the anchor and warns. This
# is the ONE place that now guarantees the invariant: a future branch of
# this decision that forgets to reset himmel_dir is caught HERE, instead of
# shipping the branch's own scripts/cr/ unlogged.
if [ "$himmel_dir_is_anchor" = no ] \
   && [ "$cr_diff_state" != no ] \
   && [ "$verified_delegate" != yes ] \
   && [ "$ledger_written" != yes ]; then
    echo "pr-check-context: WARNING - refusing to leave himmel_dir at the branch's own scripts/cr/ ($himmel_dir) unlogged: cr_diff_state=$cr_diff_state, verified_delegate=$verified_delegate, ledger_written=$ledger_written - none of the conditions that permit branch self-review hold; forcing himmel_dir back to the anchor ($anchor). This branch's own scripts/cr/ was NOT self-reviewed this run." >&2
    himmel_dir="$anchor"
fi

# HIMMEL-1219 - reset the prior-pass blocking scratch NOW, before the
# step-3.2 phase-A adjudicator can write it. It persists in the shared
# git-common-dir across runs and worktrees; without this reset a stale
# verdict from a PRIOR run would leak into step 3.2 phase B's conserve/run
# decision (waste a CodeRabbit call on a now-clean diff, or skip one on a
# now-dirty diff). This script is the first thing every lane (docs-audit
# included) runs, unconditionally, before any producer - so this is the
# single guard the reset cannot be skipped through.
#
# HIMMEL-1219 round 3 - the file holds panel/codex ADJUDICATION VERDICTS
# (one "VERDICT [<slug>-N] = <verdict>" line per candidate, written in step
# 3.2 phase A after the session adjudicates them), not a raw candidate count.
# Step 3.2 phase B derives the blocking count structurally from those
# verdicts - a candidate blocks unless EVERY collected verdict for its ID is
# disproved, the same rule step 4 uses (round 5) - so an all-disproved round
# reads as 0 blockers and CodeRabbit RUNS. The reset below is a TRUNCATE to
# empty (the known-clean verdicts log), not a "0" integer. An empty, missing,
# or unreadable file at read time still parses as 0 blockers -> RUN
# CodeRabbit (fail-open, never silently conserve): a forgotten phase-A write
# fails OPEN, not closed.
#
# Branch-scoped (round 1b): $git_dir is the SHARED git-common-dir common to
# every worktree in the checkout, so an unscoped file would have two
# CONCURRENT /pr-check runs on different branches racing on ONE file - run
# B's reset wiping run A's verdicts mid-flight, then run A reading 0
# blockers and spending a scarce CodeRabbit call its adjudication already
# flagged (the exact waste this gate exists to prevent), or the reverse (B's
# verdicts making A silently conserve a call it should spend). Scoped per
# branch exactly like the marker above (cr-pending/<branch>).
#
# HIMMEL-1219 round 5 - the aggregate-verdicts file (cr-aggregate-verdicts/
# <branch>) that step 4's orphan-check diffs the prior-blocking file against
# is pre-truncated too. The session rewrites it in step 4, but this
# pre-truncate guarantees a STALE aggregate from a prior run can never mask
# an orphan: if the session then skips that write, the empty file makes
# every phase-A candidate an orphan -> fail-closed, never a false-clean.
# Branch-scoped for the same concurrent-worktree reason as above.
#
# HIMMEL-2131 - both files are written through write-verdicts.sh, the
# classifier-sanctioned single-purpose writer, rather than a bare `: > file`
# redirect: the auto-mode classifier denies that inline shape as a
# self-declare-clean write (it pattern-matches the rm-the-CR-marker shape
# HIMMEL-1064 exists to stop). Empty stdin is a valid input for
# write-verdicts.sh and writes an empty file, rc=0 - exactly the truncate
# these two calls need. write-verdicts.sh resolves its own target via
# --git-common-dir from $PWD, which is unchanged here, so it lands in the
# same git_dir this script just computed.
if ! printf '' | bash "$HIMMEL_ROOT/scripts/cr/write-verdicts.sh" prior-blocking --branch "$branch"; then
    echo "pr-check-context: failed to truncate cr-prior-blocking/$branch - aborting" >&2
    exit 2
fi
if ! printf '' | bash "$HIMMEL_ROOT/scripts/cr/write-verdicts.sh" aggregate --branch "$branch"; then
    echo "pr-check-context: failed to truncate cr-aggregate-verdicts/$branch - aborting" >&2
    exit 2
fi

# HIMMEL-2226 round 2 - the step-2 lane check used to substitute the printed
# marker= path as a literal into an awk fence ('<marker>'), which a
# repo-controlled branch name (it is embedded in the marker path) can break
# out of - a single quote inside the branch name terminates the string and
# injects shell. The marker path never leaves this script as anything but a
# real shell variable, so the lane read belongs here instead: same field
# parse the runbooks used to run themselves (-F' [|] ' is a literal bracket
# class, NOT \| - gawk warns on \| and reads it as alternation, splitting on
# every space and returning the wrong field). No marker yet -> empty lane;
# the runbooks already stop at "nothing to do" before the lane matters, so
# this is not a new failure mode and does not touch the exit-code contract
# above.
lane=""
if [ -f "$marker" ]; then
    lane=$(awk -F' [|] ' '{print $3; exit}' "$marker" 2>/dev/null)
fi

printf 'pr-check-context: himmel_dir=%s\n' "$himmel_dir"
printf 'pr-check-context: repo=%s\n' "$repo"
printf 'pr-check-context: branch=%s\n' "$branch"
printf 'pr-check-context: head=%s\n' "$head"
printf 'pr-check-context: base=%s\n' "$base"
printf 'pr-check-context: marker=%s\n' "$marker"
printf 'pr-check-context: lane=%s\n' "$lane"
printf 'pr-check-context: anchor_lane=%s\n' "$anchor_lane"
printf 'pr-check-context: delegated=%s\n' "$delegated"
# HIMMEL-3382 - the exact set this run decided on (comma-joined, empty when
# cr_diff_state is no or unknown): the runbook points at this line instead
# of restating the diff recipe itself.
cr_diff_files_csv=$(printf '%s\n' "$cr_diff_files" | grep -v '^$' | tr '\n' ',' | sed 's/,$//')
printf 'pr-check-context: cr_diff_files=%s\n' "$cr_diff_files_csv"

exit 0
