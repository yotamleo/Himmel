#!/usr/bin/env bash
# scripts/cr/anchor-handoff.sh - hand a relative-entry gate writer off to the
# anchor's copy (HIMMEL-3395; generalized to any depth under the repo root by
# HIMMEL-3437). Sourced, never run, as the FIRST statement of each pre-approved
# gate-writer entry script:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh"
#
# WHY: plugin-profiles.json / .claude/settings.json pre-approve the RELATIVE
# literals of a set of gate-writer entry scripts — the nine original
# scripts/cr/ writers (write-verdicts, clear-cr-marker, panel-first-pass,
# docs-audit-panel, codex-adv-kickoff, codex-adv-harvest, doc-freshness-advisory,
# known-findings, ledger-append, and since HIMMEL-3495 review-round,
# orphan-check, impacted-suites, cr-scores), and since HIMMEL-3437 also
# scripts/handover/merge-on-green.sh and scripts/handover/console-kit/go.sh.
# From a leg's worktree that literal runs the BRANCH's copy, so a branch that
# edits its own gate writer would run it unseen under the allow rule. Every
# writer resolves the reviewed repo from cwd (git-common-dir / show-toplevel)
# and uses its own directory only for helper libs, so running the anchor's
# copy from the same cwd reviews the same branch with trusted code - the
# pr-check-env.sh HIMMEL-3375 pattern, shared.
#
# Depth-agnostic (HIMMEL-3437): the sourcing script's own repo root is found
# via `git rev-parse --show-toplevel` (not a hardcoded `../..` walk, which
# only held for two-levels-deep scripts/cr/*.sh), and the anchor target is
# that root-relative path re-applied under HIMMEL_REPO - so this same file,
# still physically living at scripts/cr/anchor-handoff.sh, hands off a
# scripts/cr/<writer>.sh (depth 2) exactly as it hands off a
# scripts/handover/console-kit/go.sh (depth 3). A tree this resolver cannot
# place inside a git worktree (`git rev-parse` fails) refuses rather than
# guess a root.
#
# Scope: only a RELATIVE entry hands off - the one shape an allow rule can
# match. An absolute entry (suites, internal callers such as
# codex-adv-harvest -> ledger-append, the runbook's "<himmel_dir>/…" spelling)
# never matched an allow rule, stays visible to the classifier, and runs as
# invoked; handing those off would make a worktree's own suites test the
# anchor's copy instead of the branch's.
#
# On the relative door it fails closed: HIMMEL_REPO unset/empty (read from
# this process's own environment, never derived from cwd or a branch file), a
# repo root this copy cannot resolve, or an anchor with no copy of the entry
# script at the same root-relative path, exits 2 rather than letting the
# branch's copy decide. One hop only: a hand-off that lands on a copy which is
# still not the anchor refuses instead of looping.
# ponytail: this file and the one line sourcing it are branch bytes. For the
# nine original scripts/cr/ writers, guard-pr-check-literal.sh (HIMMEL-3495)
# denies a relative run unless the entry script and this file equal the
# anchor's byte for byte, so a branch that deletes either is refused before it
# runs. guard-pr-check-literal's TARGETS list covers scripts/cr only
# (HIMMEL-3437 comment thread) - it does NOT yet extend that same byte-compare
# to scripts/handover/merge-on-green.sh or console-kit/go.sh, so for those two
# this file's hand-off is defence in depth, not yet undeletable on its own;
# closing that gap is a scripts/hooks/ edit tracked as a HIMMEL-3437 follow-up.
# HIMMEL_REPO is still read from the environment, so whoever sets it picks the
# anchor (a residual the hook shares, where the hook applies). The absolute
# door is left open on purpose: `bash /abs/worktree/scripts/cr/<writer>.sh`
# runs the branch's copy, because no allow rule matches that spelling, so the
# classifier or the operator sees it. "Relative" is decided on the entry path
# AS INVOKED (`./scripts/cr/x.sh` counts), never on a resolved path. The
# structural control is the narrowed allow list (HIMMEL-3402): no prefix rule
# reaches scripts/cr/, and none reaches scripts/handover/ either.

_ah_self="${BASH_SOURCE[1]:-$0}"
case "$_ah_self" in
    /* | [A-Za-z]:[\\/]*) ;;
    *)
        _ah_name="$(basename "$_ah_self")"
        _ah_dir="$(cd "$(dirname "$_ah_self")" && pwd)"
        _ah_anchor="${HIMMEL_REPO:-}"
        # HIMMEL-3451: a relative HIMMEL_REPO (".", "..", a bare name) resolves
        # against whatever cwd happens to be at `-ef` test time below, so it can
        # accidentally equal $_ah_root and make a branch self-anchor. The anchor
        # is only ever meant to be pinned by an absolute path (adopt/setup wire
        # it that way); reject anything else before it reaches any -ef test.
        if [ -n "$_ah_anchor" ]; then
            case "$_ah_anchor" in
                /* | [A-Za-z]:[\\/]*) ;;
                *)
                    echo "$_ah_name: HIMMEL_REPO ($_ah_anchor) is not an absolute path - refusing to let a relative anchor decide" >&2
                    exit 2
                    ;;
            esac
        fi
        # -u GIT_DIR/GIT_WORK_TREE/GIT_COMMON_DIR (HIMMEL-3437 F4): a caller
        # that inherits any of these pointed at the anchor makes git resolve
        # the anchor as the toplevel regardless of $_ah_dir, so this copy
        # would believe it was ALREADY the anchor and skip the hand-off,
        # running its own (possibly branch) bytes under the anchor's name.
        # cwd is the only trusted signal for "where does this file live".
        _ah_root="$(cd "$_ah_dir" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git rev-parse --show-toplevel 2>/dev/null)"
        _ah_prefix=""
        # Tracks whether $_ah_root came from a genuine git toplevel resolve
        # (below) rather than the non-git walk-up fallback further down -
        # only the former needs the ls-files tracked-path check: the
        # walk-up already proves self-anchor identity by directory equality
        # against $_ah_anchor, and there is no git index to check there.
        _ah_via_git=0
        if [ -n "$_ah_root" ]; then
            # show-prefix is the path from the repo's toplevel down to cwd,
            # computed by git itself - correct regardless of any
            # logical/physical divergence between `pwd` (used for _ah_dir
            # above) and git's own (physical) toplevel, unlike the old
            # string-subtraction this replaced (HIMMEL-3437 F1: a symlinked
            # worktree path made that subtraction a no-op, leaving _ah_rel
            # absolute instead of relative and breaking the hand-off).
            _ah_prefix="$(cd "$_ah_dir" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git rev-parse --show-prefix 2>/dev/null)"
            # Belt-and-suspenders on top of the -u fix above: the resolved
            # root+prefix must actually reconstruct $_ah_dir. If some OTHER
            # env var this fix doesn't know about ever steers git the same
            # way, this still refuses to self-anchor on a mismatch instead
            # of trusting a toplevel that doesn't point back at this file.
            if ! [ "$_ah_dir" -ef "$_ah_root/$_ah_prefix" ]; then
                _ah_root=""
            else
                _ah_via_git=1
            fi
        fi
        if [ -z "$_ah_root" ] && [ -n "$_ah_anchor" ]; then
            # No git metadata under $_ah_dir (a non-repo test fixture, not a
            # real worktree). The self-anchor case still needs no genuine
            # root: walk up from here looking for an ancestor that IS the
            # anchor: found -> we're already the anchor's own copy, so a
            # hand-off is not needed either way (matches the pre-HIMMEL-3437
            # depth-2 resolver, which never validated its guessed root was a
            # real repo top). A cross-tree hand-off still requires git, so a
            # non-git wt still fails closed below. A `.git` entry anywhere
            # between here and a matched ancestor means git rev-parse failed
            # for some OTHER reason (a corrupted/misdirected worktree, not a
            # genuine non-git tree) - stop instead of treating that as a
            # self-anchor match (HIMMEL-3437 F2: without this check, a
            # worktree nested under the anchor with its own broken .git ran
            # its own bytes unchecked instead of failing closed).
            _ah_walk="$_ah_dir"
            while :; do
                if [ -e "$_ah_walk/.git" ]; then
                    break
                fi
                if [ "$_ah_walk" -ef "$_ah_anchor" ]; then
                    _ah_root="$_ah_anchor"
                    break
                fi
                _ah_parent="$(dirname "$_ah_walk")"
                [ "$_ah_parent" = "$_ah_walk" ] && break
                _ah_walk="$_ah_parent"
            done
            unset _ah_walk _ah_parent
        fi
        if [ -z "$_ah_root" ]; then
            echo "$_ah_name: cannot resolve this copy's own repo root (git rev-parse --show-toplevel failed under $_ah_dir) - refusing to let it decide" >&2
            exit 2
        fi
        _ah_rel="${_ah_prefix}$_ah_name"
        if [ -z "$_ah_anchor" ]; then
            echo "$_ah_name: HIMMEL_REPO is unset or empty - refusing to let this relative-entry copy ($_ah_root) decide; export it non-empty (adopt/setup wires it into settings.json env), or run the anchored \"<himmel_dir>/$_ah_rel\" spelling" >&2
            exit 2
        fi
        # HIMMEL-3451: the anchor must be a PRIMARY checkout, never a linked
        # worktree (the caller's own included) - a worktree's git-common-dir
        # points at the primary's .git elsewhere, never at its own .git. Without
        # this, HIMMEL_REPO pointed at the caller's own worktree made
        # "$_ah_root" -ef "$_ah_anchor" true below, so the branch treated
        # itself as already-the-anchor and ran its own (possibly tampered)
        # bytes with no hand-off at all. A HIMMEL_REPO that is not a git repo
        # at all is left to the existing "anchor carries no $_ah_rel" refusal
        # further down, so only a GENUINE (but wrong) worktree is caught here.
        # This defends against an HONEST linked worktree only - whoever
        # controls HIMMEL_REPO and the tree's .git can still point it at a
        # tree that IS its own primary checkout; that residual is the same
        # "whoever sets HIMMEL_REPO picks the anchor" class already documented
        # in this file's header, not something this check can close.
        _ah_anchor_common=""
        if [ -d "$_ah_anchor" ]; then
            _ah_anchor_common="$(cd "$_ah_anchor" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
        fi
        if [ -n "$_ah_anchor_common" ] && ! [ "$_ah_anchor_common" -ef "$_ah_anchor/.git" ]; then
            echo "$_ah_name: HIMMEL_REPO ($_ah_anchor) is not the anchor's own checkout - its git-common-dir ($_ah_anchor_common) is not $_ah_anchor/.git, so it is a linked worktree, not the primary anchor - refusing" >&2
            exit 2
        fi
        if [ -z "$_ah_anchor_common" ] && [ -e "$_ah_anchor/.git" ]; then
            echo "$_ah_name: HIMMEL_REPO ($_ah_anchor) has a .git entry but its git-common-dir could not be resolved - refusing rather than assume it is the primary anchor" >&2
            exit 2
        fi
        unset _ah_anchor_common
        # CodeRabbit (PR #1212): root -ef anchor alone is not proof this IS the
        # anchor's own tracked copy. A directory with NO .git of its own (an
        # orphaned worktree under $HIMMEL_REPO/.claude/worktrees/ whose gitlink
        # was removed entirely, not merely broken - F2 above only catches a
        # broken one) makes git's own ancestor walk resolve --show-toplevel to
        # the ANCHOR itself even though this tree is not really its content.
        # .claude/worktrees/ is gitignored, so requiring the anchor's OWN git
        # index to track this literal relative path closes it: an orphaned
        # worktree fails this and falls through to the real hand-off attempt
        # below, which then correctly fails closed (not the anchor, and the
        # anchor carries no file at this untracked-only relative path either).
        # The orphaned-worktree bypass only reaches this via a genuine git
        # toplevel resolve (its .git removal still leaves the ANCHOR's own
        # .git discoverable above it), so the tracked-path check gates only
        # $_ah_via_git=1; the non-git walk-up path already proved identity
        # by directory equality and has no git index to check against.
        _ah_is_anchor=0
        if [ "$_ah_root" -ef "$_ah_anchor" ]; then
            if [ "$_ah_via_git" -eq 1 ]; then
                # -u GIT_INDEX_FILE joins the F4 scrub list here (HIMMEL-3437
                # review round 2): this call reads the anchor's INDEX, not
                # just its toplevel, so a caller-supplied GIT_INDEX_FILE (or
                # GIT_DIR, which locates the default index) pointed at a
                # crafted index that happens to track $_ah_rel made an
                # orphaned worktree's copy pass this check exactly as an
                # unset GIT_DIR made F4's rev-parse calls report the anchor
                # as the toplevel - same fail-open class, this call just
                # missed it.
                env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE git -C "$_ah_anchor" ls-files --error-unmatch -- "$_ah_rel" >/dev/null 2>&1 && _ah_is_anchor=1
            else
                _ah_is_anchor=1
            fi
        fi
        if [ "$_ah_is_anchor" -eq 0 ]; then
            if [ ! -f "$_ah_anchor/$_ah_rel" ]; then
                echo "$_ah_name: entered through a non-anchor copy ($_ah_root) and the anchor carries no $_ah_rel ($_ah_anchor) - refusing to let this copy decide; fix HIMMEL_REPO, then re-run" >&2
                exit 2
            fi
            if [ -n "${CR_ANCHOR_HANDED_OFF:-}" ]; then
                echo "$_ah_name: already handed off once and still not the anchor's copy ($_ah_root vs $_ah_anchor) - refusing rather than hand off in a loop" >&2
                exit 2
            fi
            # CodeRabbit (PR #1212) follow-up: a nested worktree with no .git
            # of its own, physically living INSIDE the anchor's tree (e.g.
            # $HIMMEL_REPO/.claude/worktrees/<orphan>), resolves its hand-off
            # target ($_ah_anchor/$_ah_rel) to this exact same file - execing
            # an absolute path re-enters this file on the unconditional
            # "already anchored" door (the case statement above), running the
            # untrusted bytes with no further check. A genuine hand-off target
            # is always a physically DIFFERENT file from the one deciding to
            # hand off; refuse rather than exec a self-referential "hand-off".
            if [ "$_ah_anchor/$_ah_rel" -ef "$_ah_dir/$_ah_name" ]; then
                echo "$_ah_name: hand-off target ($_ah_anchor/$_ah_rel) is this same file - refusing rather than re-run it unchecked as an absolute entry" >&2
                exit 2
            fi
            # HIMMEL-3451: before trusting the hand-off, byte-compare this
            # helper's own file and the two libs a scripts/cr/ or
            # scripts/handover/ entry sources (scripts/guardrails/lib.sh,
            # scripts/lib/load-dotenv.sh) against the anchor's copies at the
            # same root-relative path. This is defense in depth alongside
            # guard-pr-check-literal.sh's own byte-compare (which does not run
            # outside a himmel-project hook chain, HIMMEL-3558): a tree whose
            # copy of any of the three disagrees with the anchor's is treated
            # as tampered and refused, rather than handed off while leaving a
            # differing copy of shared trust code sitting in the worktree.
            # Only checked when THIS tree carries the file - a fixture or a
            # tree that never had it is not "tampered", just incomplete.
            #
            # This file's OWN root-relative path is NOT "${_ah_prefix}anchor-handoff.sh"
            # (HIMMEL-3451 review round 2): $_ah_prefix is the ENTRY script's
            # prefix (e.g. scripts/handover/ or scripts/handover/console-kit/),
            # but this file always physically lives at scripts/cr/anchor-handoff.sh
            # regardless of who sources it. Using the entry's prefix resolved
            # to a nonexistent scripts/handover/anchor-handoff.sh for the two
            # handover entries, so `[ -f "$_ah_dep_local" ]` was false and the
            # compare silently never ran for them - proven by probe: a
            # tampered helper was refused via clear-cr-marker.sh (depth 2) but
            # handed off unchecked via go.sh (depth 3). Resolve this file's
            # own path from BASH_SOURCE[0] instead, which always points at
            # THIS file however it was sourced.
            # git rev-parse --show-prefix, not a pwd/string-subtraction of
            # $_ah_root (HIMMEL-3437 F1, same reason $_ah_prefix above uses
            # it): `pwd` is logical and symlink-preserving, `--show-toplevel`
            # is physical, and a symlinked worktree makes the two diverge -
            # a string-subtraction against $_ah_root then leaves this empty
            # and wrongly refuses hand-off through a symlinked path (T14).
            _ah_self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
            if _ah_self_prefix="$(cd "$_ah_self_dir" && env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR git rev-parse --show-prefix 2>/dev/null)"; then
                _ah_self_rel="${_ah_self_prefix}$(basename "${BASH_SOURCE[0]}")"
            else
                _ah_self_rel=""
            fi
            unset _ah_self_prefix
            if [ -z "$_ah_self_rel" ]; then
                echo "$_ah_name: cannot resolve this file's own root-relative path under $_ah_root - refusing rather than skip the self-compare" >&2
                exit 2
            fi
            for _ah_dep in "$_ah_self_rel" scripts/guardrails/lib.sh scripts/lib/load-dotenv.sh; do
                _ah_dep_local="$_ah_root/$_ah_dep"
                _ah_dep_anchor="$_ah_anchor/$_ah_dep"
                if [ -f "$_ah_dep_local" ]; then
                    if [ ! -f "$_ah_dep_anchor" ] || ! cmp -s "$_ah_dep_local" "$_ah_dep_anchor"; then
                        echo "$_ah_name: this tree's $_ah_dep differs from the anchor's ($_ah_anchor) - refusing to hand off; run the anchored \"<himmel_dir>/$_ah_rel\" spelling instead" >&2
                        exit 2
                    fi
                fi
            done
            unset _ah_dep _ah_dep_local _ah_dep_anchor _ah_self_dir _ah_self_rel
            export CR_ANCHOR_HANDED_OFF=1
            echo "$_ah_name: entered through a non-anchor copy ($_ah_root) - handing off to the anchor's copy ($_ah_anchor/$_ah_rel)" >&2
            exec bash "$_ah_anchor/$_ah_rel" "$@"
        fi
        unset _ah_name _ah_dir _ah_root _ah_rel _ah_anchor _ah_prefix _ah_is_anchor _ah_via_git
        ;;
esac
unset _ah_self
