#!/usr/bin/env bash
# graphify-freshness-advisory.sh — SessionStart advisory: warn when the himmel
# graphify graph cannot be trusted (HIMMEL-1643; the C1 routing line says
# "treat it as current" — this hook is what keeps that claim honest).
# SILENT when fresh (every SessionStart line is paid in every session forever).
# THREE states (r2 panel codex-2): fresh -> nothing; stale OR absent/corrupt ->
# one banner (an absent graph is definitively not current); the advisory's OWN
# failures -> silent exit 0 (fail-open covers our bugs, never the graph state).
# ALWAYS exits 0. Pattern sibling: qmd-staleness-notice.sh (HIMMEL-1286).
#
# PLAN DEVIATION (plan-critic r1 F2, restated here per Step 3.5): the spec's
# literal `graphmap-cadence.sh --run-once` DOES NOT EXIST (that script's verbs
# are arm|status|disarm). The banner's refresh command source of truth is the
# checker's own REMEDIATION line (`refresh-graph-map.sh --name … --corpus-root
# …`), re-printed below via `$out` — not hardcoded here.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKER="${GRAPHIFY_ADVISORY_CHECKER:-$HERE/../graphify/check-graph-freshness.sh}"
# PRIMARY-CHECKOUT ANCHORING (codex-adv-r3-2, PR #1633). The graph is a
# per-REPO artifact: the daily cadence maintains it in the PRIMARY checkout,
# and its checker-required stamps (manifest.json, .graphify_root) are
# GITIGNORED — a linked worktree checks out the tracked graph.json but never
# the stamps, so an own-tree default here would false-banner ABSENT in every
# worktree session. This was the third round of the same invariant violation
# (the hook's own tree is NOT necessarily the graph-owning root), so the
# defaults anchor to the primary root: git-common-dir's parent IS the primary
# checkout, from any linked worktree. Fail-open: git absent / resolution
# failure falls back to the hook's own tree (the pre-fix behaviour), and the
# GRAPHIFY_ADVISORY_OUT / GRAPHIFY_ADVISORY_REPO overrides win unchanged.
_default_root="$HERE/../.."
if _common="$(git -C "$_default_root" rev-parse --git-common-dir 2>/dev/null)" && [ -n "$_common" ]; then
    case "$_common" in
        /*|[A-Za-z]:*) : ;;                       # absolute (POSIX or drive-letter)
        *) _common="$_default_root/$_common" ;;   # relative (".git" in the primary itself)
    esac
    _primary="$(dirname "$_common")"
    [ -d "$_primary" ] && _default_root="$_primary"
fi
# Repo-root graphify-out (checker resolves corpus via its .graphify_root marker).
OUT_DIR="${GRAPHIFY_ADVISORY_OUT:-$_default_root/graphify-out}"
REPO_ROOT="${GRAPHIFY_ADVISORY_REPO:-$_default_root}"
# 2 days = tolerate one missed daily run (pairs with the qmd advisory's 36h
# philosophy on the checker's day-granular interface).
budget="${GRAPHIFY_STALENESS_MAX_AGE_DAYS:-2}"
# check-graph-freshness.sh exits 1 for BOTH "stale" AND "usage error", so a
# non-integer budget would surface as a false STALE banner every session.
# Validate it: empty or non-numeric -> our own default, never a false banner.
case "$budget" in
    ''|*[!0-9]*) budget=2 ;;
esac

# Adopter exemption — PORTABLE + STRUCTURAL (plan-critic r1 F3/F4 replaced the
# schtasks probe, which was Windows-only dead code): a repo that VERSION-TRACKS
# graphify-out/ has adopted graphs, so an absent/broken working-tree graph is
# anomalous and must banner; a repo with no tracked graphify-out/ never adopted
# and stays silent. Accepted loss: an adopter who also never committed the
# graph reads as never-adopted — documented, not silent-by-accident.
if [ ! -d "$OUT_DIR" ]; then
    tracked="$(git -C "$REPO_ROOT" ls-files -- 'graphify-out/*' 2>/dev/null | head -1)" || tracked=""
    [ -n "$tracked" ] || exit 0   # never adopted -> silent
fi

[ -f "$CHECKER" ] || exit 0   # our own wiring broken -> silent (T5)

rc=0
out=$(bash "$CHECKER" --out "$OUT_DIR" --max-age-days "$budget" 2>&1) || rc=$?

case "$rc" in
    0) exit 0 ;;                       # fresh — say nothing
    1) state="STALE" ;;                # checker WARN: older than budget
    2) state="ABSENT/untrustworthy" ;; # missing/orphaned/corrupt
    *) exit 0 ;;                       # checker crashed in a way we don't know: our problem, silent
esac

printf '<system-reminder>\n'
printf 'graphify graph is %s — the HIMMEL-621 routing line says "treat it as\n' "$state"
printf 'current", which does NOT hold this session.\n\n%s\n\n' "$out"
printf 'The daily refresh cadence (HIMMEL-829) is HIMMEL-GraphMap-Himmel /\n'
printf 'HIMMEL-GraphMap-Luna (13:20/13:00). If it silently broke, rebuild via\n'
printf 'scripts/graphify/refresh-graph-map.sh (invocation in the checker output\n'
printf 'above). Structure queries still answer — treat them as last-refresh\n'
printf 'snapshots, and treat graph MISSES as unproven (HIMMEL-1643).\n'
printf '</system-reminder>\n'
exit 0
