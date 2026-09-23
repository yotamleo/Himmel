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
        _ah_root="$(cd "$_ah_dir" && git rev-parse --show-toplevel 2>/dev/null)"
        if [ -z "$_ah_root" ] && [ -n "$_ah_anchor" ]; then
            # No git metadata under $_ah_dir (a non-repo test fixture, not a
            # real worktree). The self-anchor case still needs no genuine
            # root: walk up from here looking for an ancestor that IS the
            # anchor: found -> we're already the anchor's own copy, so a
            # hand-off is not needed either way (matches the pre-HIMMEL-3437
            # depth-2 resolver, which never validated its guessed root was a
            # real repo top). A cross-tree hand-off still requires git, so a
            # non-git wt still fails closed below.
            _ah_walk="$_ah_dir"
            while :; do
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
        _ah_rel="${_ah_dir#"$_ah_root"/}/$_ah_name"
        if [ -z "$_ah_anchor" ]; then
            echo "$_ah_name: HIMMEL_REPO is unset or empty - refusing to let this relative-entry copy ($_ah_root) decide; export it non-empty (adopt/setup wires it into settings.json env), or run the anchored \"<himmel_dir>/$_ah_rel\" spelling" >&2
            exit 2
        fi
        if ! [ "$_ah_root" -ef "$_ah_anchor" ]; then
            if [ ! -f "$_ah_anchor/$_ah_rel" ]; then
                echo "$_ah_name: entered through a non-anchor copy ($_ah_root) and the anchor carries no $_ah_rel ($_ah_anchor) - refusing to let this copy decide; fix HIMMEL_REPO, then re-run" >&2
                exit 2
            fi
            if [ -n "${CR_ANCHOR_HANDED_OFF:-}" ]; then
                echo "$_ah_name: already handed off once and still not the anchor's copy ($_ah_root vs $_ah_anchor) - refusing rather than hand off in a loop" >&2
                exit 2
            fi
            export CR_ANCHOR_HANDED_OFF=1
            echo "$_ah_name: entered through a non-anchor copy ($_ah_root) - handing off to the anchor's copy ($_ah_anchor/$_ah_rel)" >&2
            exec bash "$_ah_anchor/$_ah_rel" "$@"
        fi
        unset _ah_name _ah_dir _ah_root _ah_rel _ah_anchor
        ;;
esac
unset _ah_self
