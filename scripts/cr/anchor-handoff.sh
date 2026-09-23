#!/usr/bin/env bash
# scripts/cr/anchor-handoff.sh - hand a relative-entry gate writer off to the
# anchor's copy (HIMMEL-3395). Sourced, never run, as the FIRST statement of
# each scripts/cr/ gate writer the leg profiles auto-allow:
#
#   . "$(dirname "${BASH_SOURCE[0]}")/anchor-handoff.sh"
#
# WHY: plugin-profiles.json gateAllow pre-approves the relative literals
# `bash scripts/cr/<writer>.sh …` (write-verdicts, clear-cr-marker,
# panel-first-pass, docs-audit-panel, codex-adv-kickoff, codex-adv-harvest,
# doc-freshness-advisory, known-findings, ledger-append, and since HIMMEL-3495
# review-round, orphan-check, impacted-suites, cr-scores). From a leg's
# worktree that literal runs the BRANCH's copy, so a branch that edits its own
# verdict writer or marker clearer would run it unseen under the allow rule.
# Every writer resolves the reviewed repo from cwd (git-common-dir /
# show-toplevel) and uses its own directory only for helper libs, so running
# the anchor's copy from the same cwd reviews the same branch with trusted
# code - the pr-check-env.sh HIMMEL-3375 pattern, shared.
#
# Scope: only a RELATIVE entry hands off - the one shape an allow rule can
# match. An absolute entry (suites, internal callers such as
# codex-adv-harvest -> ledger-append, the runbook's "<himmel_dir>/…" spelling)
# never matched an allow rule, stays visible to the classifier, and runs as
# invoked; handing those off would make a worktree's own suites test the
# anchor's copy instead of the branch's.
#
# On the relative door it fails closed: HIMMEL_REPO unset/empty (read from
# this process's own environment, never derived from cwd or a branch file), or
# an anchor with no copy of the writer, exits 2 rather than letting the
# branch's copy decide. One hop only: a hand-off that lands on a copy which is
# still not the anchor refuses instead of looping.
# ponytail: this file and the one line sourcing it are branch bytes. What makes
# them undeletable on the relative door is guard-pr-check-literal.sh
# (HIMMEL-3495), which denies a relative run unless the entry script and this
# file equal the anchor's byte for byte - a branch that deletes either is
# refused before it runs. HIMMEL_REPO is still read from the environment, so
# whoever sets it picks the anchor (a residual the hook shares). The absolute door is left
# open on purpose: `bash /abs/worktree/scripts/cr/<writer>.sh` runs the
# branch's copy, because no allow rule matches that spelling, so the classifier
# or the operator sees it. "Relative" is decided on the entry path AS INVOKED
# (`./scripts/cr/x.sh` counts), never on a resolved path. The structural
# control is the narrowed allow list (HIMMEL-3402): no prefix rule reaches
# scripts/cr/.

_ah_self="${BASH_SOURCE[1]:-$0}"
case "$_ah_self" in
    /* | [A-Za-z]:[\\/]*) ;;
    *)
        _ah_name="$(basename "$_ah_self")"
        _ah_root="$(cd "$(dirname "$_ah_self")/../.." && pwd)"
        _ah_anchor="${HIMMEL_REPO:-}"
        if [ -z "$_ah_anchor" ]; then
            echo "$_ah_name: HIMMEL_REPO is unset or empty - refusing to let this relative-entry copy ($_ah_root) decide; export it non-empty (adopt/setup wires it into settings.json env), or run the anchored \"<himmel_dir>/scripts/cr/$_ah_name\" spelling" >&2
            exit 2
        fi
        if ! [ "$_ah_root" -ef "$_ah_anchor" ]; then
            if [ ! -f "$_ah_anchor/scripts/cr/$_ah_name" ]; then
                echo "$_ah_name: entered through a non-anchor copy ($_ah_root) and the anchor carries no scripts/cr/$_ah_name ($_ah_anchor) - refusing to let this copy decide; fix HIMMEL_REPO, then re-run" >&2
                exit 2
            fi
            if [ -n "${CR_ANCHOR_HANDED_OFF:-}" ]; then
                echo "$_ah_name: already handed off once and still not the anchor's copy ($_ah_root vs $_ah_anchor) - refusing rather than hand off in a loop" >&2
                exit 2
            fi
            export CR_ANCHOR_HANDED_OFF=1
            echo "$_ah_name: entered through a non-anchor copy ($_ah_root) - handing off to the anchor's copy ($_ah_anchor/scripts/cr/$_ah_name)" >&2
            exec bash "$_ah_anchor/scripts/cr/$_ah_name" "$@"
        fi
        unset _ah_name _ah_root _ah_anchor
        ;;
esac
unset _ah_self
