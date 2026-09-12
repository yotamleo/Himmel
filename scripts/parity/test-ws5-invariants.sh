#!/usr/bin/env bash
# WS5 Task 5 invariants test (HIMMEL-654). Assertion-only: greps the
# integrated WS5 branch diff (git diff <base>...HEAD) for the four locks that
# make lane parity durable without growing always-on surface or root-doctrine
# bloat.
#
#   T12 no-bloat     -- root CLAUDE.md does not grow on net (add-del <=1);
#                       pure churn (net 0) or shrinkage passes. (Changed
#                       2026-09-06 from a symmetric per-side cap to a
#                       net-growth cap, HIMMEL-2581 -- the per-side form
#                       failed ordinary rewordings, e.g. PR #2101/HIMMEL-2413's
#                       add=2 del=2, and even pure deletions, neither of which
#                       is the rule-block bloat this check exists to catch.)
#   T13 no-always-on -- no new SessionStart/PreToolUse hook registration in
#                       .claude/settings.json or any */hooks.json, and no
#                       unbounded-loop / background-service / JS-timer marker
#                       in the SHIPPED source the diff adds (test fixtures are
#                       excluded: a harness loop is not runtime surface).
#   T14 locks        -- no per-token-lane wiring in shipped source; the
#                       gemini/copilot/cursor index rows stay deferred.
#                       (The former T14(a) claude-codex-launcher prohibition
#                       was retired 2026-07-13, HIMMEL-979.)
#   T15 x-platform   -- every NEW scripts/**/*.sh ships a .ps1 twin OR carries
#                       a documented platform-guard marker in its header.
#
# Public propagation-snapshot guard (HIMMEL-2642): T12/T13/T15 assume
# $BASE...HEAD is a normal feature-branch diff -- what one PR authored. A
# public re-baseline (propagate-public.sh's `snapshot`/`reship` modes) breaks
# that assumption: it re-projects the ENTIRE private tree onto the public
# repo's main in one commit, so hundreds of scripts the private repo has
# carried for months read as brand-new relative to PUBLIC's own git history.
# T14 is untouched by this (T14(c) reads a doc directly, not diff-scoped) and
# keeps running -- and keeps failing -- on every diff, snapshot or not; only
# T12/T13/T15 are SKIPPED (never silently, always with a named reason), so a
# snapshot that genuinely breaks T14 still fails the suite. Two EARLIER
# revisions of this guard inferred "is this a snapshot" from added-file volume
# and, later, volume PLUS scripts/lib/public-clone-paths.sh's absence -- both
# were heuristics, and a critic panel found a hole in each. The guard now
# checks one thing: whether propagate-public.sh itself wrote
# `.himmel-public-projection` into this tree (see the check right after BASE
# resolves, below, and propagate-public.sh's snapshot_core/reship for the
# write side). No inference, no threshold.
#
# Platform guard (gitbash-only): Git Bash on Windows / any POSIX bash 3.2+.
# Pure git + grep over the branch diff; NOT ported to native PowerShell. A
# test harness needs no .ps1 twin (project convention: a documented platform
# guard suffices for a test fixture).
#
# Usage:
#   bash scripts/parity/test-ws5-invariants.sh [--base <ref>]
#     --base <ref>   diff base (defaults to origin/main); HEAD is the tip.
#
# Exit codes: 0 = PASS, 1 = FAIL.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$SCRIPT_DIR/../.." && pwd)"
BASE="origin/main"

while [ $# -gt 0 ]; do
    case "$1" in
        --base)
            if [ $# -lt 2 ]; then
                echo "FAIL: --base requires a ref argument" >&2
                exit 1
            fi
            BASE="$2"
            shift 2
            ;;
        *)
            echo "FAIL: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

cd "$REPO" || { echo "FAIL: cannot cd to repo root $REPO" >&2; exit 1; }

if ! git rev-parse --verify --quiet "$BASE" >/dev/null; then
    # CI checkouts (shallow / single-ref) may lack origin/main -- fall back to
    # a local main; with NO resolvable base there is no diff to scope the
    # invariants over, so SKIP (exit 0), matching the harness skip convention.
    # An EXPLICIT --base that does not resolve still FAILS (caller error).
    if [ "$BASE" = "origin/main" ] && git rev-parse --verify --quiet main >/dev/null; then
        echo "note: origin/main does not resolve; falling back to local main"
        BASE=main
    elif [ "$BASE" = "origin/main" ]; then
        echo "SKIP: no resolvable diff base (origin/main and main both absent -- shallow CI checkout?); nothing to scope"
        exit 0
    else
        echo "FAIL: diff base ref does not resolve: $BASE" >&2
        exit 1
    fi
fi

# ----------------------------------------------------------------------------
# Public propagation-snapshot guard (HIMMEL-2642) -- EXPLICIT MARKER, not an
# inferred signal.
#
# History: this guard went through three designs. (1) a threshold on added
# scripts/**/*.sh volume -- a critic showed the cited evidence was a
# per-COMMIT maximum, which does not bound a per-PR-RANGE diff. (2) volume
# PLUS scripts/lib/public-clone-paths.sh's absence -- a second critic showed
# that signal distinguishes "public repo" from "private repo", not
# "propagation snapshot" from "feature PR": an ordinary public-repo PR adding
# >100 scripts would ALSO have lost T12/T13/T15 under it. Two rounds, two
# holes in two different inferred signals -- that pattern is itself the
# finding: inference is the wrong shape for this check, not a tuning problem.
#
# So there is no inference left. propagate-public.sh's `snapshot` and
# `reship` paths (the only two that produce or extend a propagation PR) write
# `.himmel-public-projection` directly into the tree they build, through the
# SAME staging/scan/verify pipeline as everything else they write (see their
# own comments). Its presence is the ONLY question this guard asks. No
# volume threshold, no second file's absence, no re-derivable statistic --
# a fact the propagator itself asserts by writing it.
#
# Ride-back guard (HIMMEL-2642 follow-up): the marker must never appear on a
# PRIVATE tree (a stray copy would falsely skip T12/T13/T15 there too).
# scripts/propagate-public.sh is ITSELF private-only, by its own header, and
# scripts/lib/propagation-drift.sh already relies on exactly that fact as
# "a sufficient private signal" (its Guard 1) -- reused here rather than
# inventing a second mechanism: if the marker and propagate-public.sh are
# EVER both present, something rode the marker back into a private tree, and
# that is an unconditional FAIL, checked before anything below can act on
# the marker's presence.
# PRESENCE is not enough, and design (4) is why (a fourth critic, and the last
# hole): the marker is COMMITTED into the public tree, so every branch cut from
# public main after a propagation INHERITS it. Presence therefore identifies
# projection ANCESTRY -- "this tree descends from a snapshot" -- not "this diff
# IS a snapshot", so an ordinary public-repo feature PR would inherit the
# exemption and skip T12/T13/T15 indefinitely.
#
# What distinguishes the two is the DIFF, and the marker already carries it:
# snapshot and reship REWRITE the marker on every run (a fresh private base SHA
# and timestamp), so it is always added-or-modified in a propagation diff and
# never touched in a branch that merely inherited it. So ask the diff, not the
# filesystem. This needs no new mechanism and no second signal -- it reads the
# same fact the propagator already asserts, scoped to the range under review.
#
# Captured into a variable rather than piped into `grep -q`: this file runs
# under `set -o pipefail` (line 54), where grep -q exits at its first match and
# the producer's SIGPIPE flips the pipeline's status (HIMMEL-1430).
PUBLIC_PROJECTION_MARKER=".himmel-public-projection"
PRIVATE_ONLY_SIGNAL="scripts/propagate-public.sh"
FAIL=0
marker_in_diff="$(git diff --name-only "$BASE...HEAD" -- "$PUBLIC_PROJECTION_MARKER" 2>/dev/null)"
if [ -f "$PUBLIC_PROJECTION_MARKER" ] && [ -f "$PRIVATE_ONLY_SIGNAL" ]; then
    echo "FAIL: $PUBLIC_PROJECTION_MARKER is present alongside $PRIVATE_ONLY_SIGNAL -- a public-only propagation marker rode back into a private tree (HIMMEL-2642). This checkout is treated as private: T12/T13/T15 still run below." >&2
    FAIL=$((FAIL + 1))
    PROPAGATION_SNAPSHOT=0
elif [ -f "$PUBLIC_PROJECTION_MARKER" ] && [ -n "$marker_in_diff" ]; then
    PROPAGATION_SNAPSHOT=1
    SNAPSHOT_REASON="$PUBLIC_PROJECTION_MARKER written by this diff -- propagate-public.sh rewrites it on every snapshot/reship, so this range IS a projection (HIMMEL-2642), not a feature branch that merely inherited the marker; T12/T13/T15 assume the diff is PR-authored content, so skipping. T14 still runs (see file header)."
else
    PROPAGATION_SNAPSHOT=0
fi
SHIPPED="$(mktemp)"
trap 'rm -f "$SHIPPED"' EXIT

# Corpus of ADDED lines from SHIPPED source (every changed file whose basename
# does NOT start with "test-"). Test fixtures are excluded because they
# legitimately describe the very concepts they assert; the always-on and
# per-token-lane invariants are about production runtime + docs, not harness
# comments. (This also keeps the test from flagging its own assertion text.)
while IFS= read -r f; do
    [ -n "$f" ] || continue
    base="${f##*/}"
    # data ledgers (HIMMEL-2894 suite-durations.tsv) list suite basenames,
    # which legitimately contain the marker words; T13 is about runtime
    # surface, and a TSV has none.
    case "$base" in test-* | *.tsv) continue ;; esac
    git diff "$BASE...HEAD" -- "$f" | grep '^+' | grep -v '^+++'
done < <(git diff "$BASE...HEAD" --name-only) > "$SHIPPED"

# ----------------------------------------------------------------------------
# T12 -- no-bloat (AC6): root CLAUDE.md does not grow on net (add-del <=1).
# Changed 2026-09-06 from a symmetric per-side cap (add<=1 AND del<=1) to a
# net-growth cap, HIMMEL-2581: the per-side form failed ordinary rewordings
# (PR #2101/HIMMEL-2413, add=2 del=2 -- the same shape the HIMMEL-2581 doc
# sweep hit) and even a pure multi-line deletion, neither of which is the
# rule-block bloat this check exists to catch. Verdict computed by
# t12_verdict() in t12-no-bloat-lib.sh, shared with its control
# (test-t12-no-bloat-lib.sh) so the threshold itself is exercised directly
# against synthetic add/del pairs, not just inferred from this suite passing.
#
# Sourced INSIDE the not-a-projection branch below, not unconditionally
# (HIMMEL-2642 follow-up): a propagation-snapshot tree's `.himmel-public-
# projection` marker can legitimately be present while the marker's own
# private base SHA predates a later private-only addition of THIS file --
# ordinary two-step propagation lag (observed live: the open yotamleo/Himmel
# PR #567 was based on private 69a2751b; t12-no-bloat-lib.sh landed in
# private commit 25e937e0, confirmed NOT an ancestor of 69a2751b via
# `git merge-base --is-ancestor`, i.e. added to private AFTER that PR's base
# -- not a propagation bug, just not reshipped yet). snapshot_verify's own
# claim (1) already guarantees this file's presence/byte-content on any
# public tree whose marker base SHA postdates its creation -- a per-file
# manifest entry here would duplicate that generic completeness proof for
# one name. Sourcing it only where it is actually used means a tree in that
# lag window (marker present, dependency not yet reshipped) never needs it
# at all, since T12 is skipped in exactly that branch.
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T12 no-bloat: $SNAPSHOT_REASON"
else
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/t12-no-bloat-lib.sh"
    claude_ns="$(git diff "$BASE...HEAD" --numstat -- CLAUDE.md | head -n 1)"
    claude_add=0
    claude_del=0
    if [ -n "$claude_ns" ]; then
        claude_add="$(printf '%s' "$claude_ns" | awk '{print $1}')"
        claude_del="$(printf '%s' "$claude_ns" | awk '{print $2}')"
        case "$claude_add" in '' | *[!0-9]*) claude_add=0 ;; esac
        case "$claude_del" in '' | *[!0-9]*) claude_del=0 ;; esac
    fi
    if ! t12_verdict "$claude_add" "$claude_del"; then
        FAIL=$((FAIL + 1))
    fi
fi

# ----------------------------------------------------------------------------
# T13 -- no new always-on surface (AC7).
# (a) no new SessionStart/PreToolUse registration in the hook-reg files;
# (b) no unbounded-loop / background-service / JS-timer marker in shipped src.
# ----------------------------------------------------------------------------
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T13 no-always-on: $SNAPSHOT_REASON"
else
    # (a) hook-registration files only: .claude/settings.json + any */hooks.json.
    t13a_hit=0
    while IFS= read -r hf; do
        [ -n "$hf" ] || continue
        if git diff "$BASE...HEAD" -- "$hf" | grep '^+' | grep -v '^+++' \
            | grep -E '(SessionStart|PreToolUse)' >/dev/null; then
            t13a_hit=1
            echo "FAIL T13(a): new SessionStart/PreToolUse registration in $hf" >&2
        fi
    done < <(git diff "$BASE...HEAD" --name-only \
        | grep -E '(^|/)hooks\.json$|^\.claude/settings\.json$' || true)

    # (b) shipped-source loop / service / timer markers.
    t13b_hit=0
    if grep -Ei 'while[[:space:]]+true|setInterval|daemon' "$SHIPPED" >/dev/null; then
        t13b_hit=1
        echo "FAIL T13(b): unbounded-loop / background-service / JS-timer marker in shipped source." >&2
    fi

    if [ "$t13a_hit" -eq 0 ] && [ "$t13b_hit" -eq 0 ]; then
        echo "PASS T13 no-always-on: no new hook registration; no loop/service/timer in shipped source."
    else
        FAIL=$((FAIL + 1))
    fi
fi

# ----------------------------------------------------------------------------
# T14 -- locks (AC8).
# (a) RETIRED 2026-07-13 (operator decision, HIMMEL-979): the D9 no-claude-codex
#     lock was superseded -- the claude-codex lane (scripts/claude-codex{,.ps1})
#     ships with native guard posture (Claude Code IS the harness, same column
#     as claude-glm). See docs/internals/lane-parity.md "claude-codex lock".
# (b) no per-token-lane wiring in shipped source;
# (c) gemini/copilot/cursor index rows stay deferred.
# ----------------------------------------------------------------------------
t14b_hit=0
if grep -Ei 'token-lane' "$SHIPPED" >/dev/null; then
    t14b_hit=1
    echo "FAIL T14(b): per-token-lane wiring in shipped source." >&2
fi

t14c_hit=0
PARITY_DOC="docs/internals/lane-parity.md"
if [ ! -f "$PARITY_DOC" ]; then
    t14c_hit=1
    echo "FAIL T14(c): lane-parity index doc missing ($PARITY_DOC)." >&2
else
    # Every gemini/copilot/cursor TABLE row must carry the 'deferred' token.
    bad_rows="$(grep -Ei '^\|.*gemini|^\|.*copilot|^\|.*cursor' "$PARITY_DOC" \
        | grep -Eiv 'deferred' || true)"
    if [ -n "$bad_rows" ]; then
        t14c_hit=1
        echo "FAIL T14(c): gemini/copilot/cursor row(s) not deferred:" >&2
        printf '%s\n' "$bad_rows" >&2
    fi
    if ! grep -Eiq '^\|.*(gemini|copilot|cursor).*deferred' "$PARITY_DOC"; then
        t14c_hit=1
        echo "FAIL T14(c): no deferred gemini/copilot/cursor row in $PARITY_DOC." >&2
    fi
fi

if [ "$t14b_hit" -eq 0 ] && [ "$t14c_hit" -eq 0 ]; then
    echo "PASS T14 locks: no per-token-lane wiring; gemini/copilot/cursor deferred. (T14(a) claude-codex lock retired, HIMMEL-979.)"
else
    FAIL=$((FAIL + 1))
fi

# ----------------------------------------------------------------------------
# T15 -- cross-platform (AC9): every NEW scripts/**/*.sh ships a .ps1 twin OR
# a documented platform-guard marker in its header. Predicate shared with
# scripts/hooks/check-new-shell-platform-guard.sh via
# scripts/lib/platform-guard.sh (HIMMEL-2682) so the two cannot drift.
# ----------------------------------------------------------------------------
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "SKIP T15 x-platform: $SNAPSHOT_REASON"
else
    # shellcheck source=scripts/lib/platform-guard.sh
    # shellcheck disable=SC1091
    . "$REPO/scripts/lib/platform-guard.sh"
    t15_fail=0
    t15_n=0
    while IFS= read -r sh_path; do
        [ -n "$sh_path" ] || continue
        t15_n=$((t15_n + 1))
        if platform_guard_ok "$sh_path"; then
            twin="${sh_path%.sh}.ps1"
            if [ -f "$twin" ]; then
                echo "ok T15: $sh_path -> .ps1 twin present ($twin)."
            else
                echo "ok T15: $sh_path -> documented platform-guard marker."
            fi
            continue
        fi
        echo "FAIL T15: $sh_path has neither a .ps1 twin nor a platform-guard marker." >&2
        t15_fail=1
    done < <(git diff "$BASE...HEAD" --diff-filter=A --name-only -- 'scripts/' \
        | grep -E '\.sh$' || true)

    if [ "$t15_n" -eq 0 ]; then
        echo "PASS T15 x-platform: no new scripts/**/*.sh in the diff (vacuous)."
    elif [ "$t15_fail" -eq 0 ]; then
        echo "PASS T15 x-platform: all ${t15_n} new scripts/**/*.sh have a twin or guard."
    else
        FAIL=$((FAIL + 1))
    fi
fi

# ----------------------------------------------------------------------------
# Verdict
# ----------------------------------------------------------------------------
if [ "$FAIL" -ne 0 ]; then
    if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
        echo "FAIL: WS5 invariants test failed ($FAIL section(s)) -- T12/T13/T15 skipped (propagation snapshot), T14 ran and failed." >&2
    else
        echo "FAIL: WS5 invariants test failed ($FAIL section(s))." >&2
    fi
    exit 1
fi
if [ "$PROPAGATION_SNAPSHOT" -eq 1 ]; then
    echo "PASS: WS5 invariants test (T14 locks ran; T12 no-bloat, T13 no-always-on, T15 x-platform SKIPPED -- propagation snapshot, HIMMEL-2642)."
else
    echo "PASS: WS5 invariants test (T12 no-bloat, T13 no-always-on, T14 locks, T15 x-platform)."
fi
exit 0
