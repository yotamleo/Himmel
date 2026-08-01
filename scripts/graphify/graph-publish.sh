#!/usr/bin/env bash
# graph-publish.sh — operator-invoked publish of a freshly-refreshed graphify
# graph to the tracked graphify-out/ artifacts (HIMMEL-1129, option 2).
#
# WHY: HIMMEL-1123 flipped himmel's .gitignore so graphify-out/graph.json +
# GRAPH_REPORT.md are TRACKED (win2/weak stations pull the graph instead of
# re-extracting — extraction is LLM-backed spend). But nothing PUBLISHES a
# locally-refreshed graph: refresh-graph-map.sh (option 1, explicitly OUT OF
# SCOPE here) only regenerates graphify-out/ on disk; someone still has to
# `git add` + push + PR it, and that step is easy to forget. win2 then pulls
# an arbitrarily stale shipped graph whose freshness guard misreads mtime as
# FRESH (checkout time, not content age — see check-graph-freshness.sh and
# HIMMEL-1123's manifest.json caveat).
#
# This script is that missing step: an explicit, operator-run "ship what I
# just regenerated" action. It does NOT run on any cadence/hook and does NOT
# touch refresh-graph-map.sh (HIMMEL-1421 owns that script's containment-check
# region this wave — this is a wholly separate, standalone script by design).
#
# WHAT IT DOES (only when there is something newer to publish):
#   1. Verifies this repo tracks graphify-out/graph.json (HIMMEL-1123 applied),
#      BOTH graphify-out/graph.json and graphify-out/GRAPH_REPORT.md exist on
#      disk (CR round 2, codex-1/codex-adv-2: refresh-graph-map.sh's promote
#      ALWAYS moves both together — there is no legitimate completed-refresh
#      state with one but not the other, so the report is REQUIRED, never
#      optional), AND graphify-out/manifest.json is present — refresh-graph-
#      map.sh writes that file LAST in its promote sequence, so its presence
#      is the "this refresh's transaction actually completed" signal; its
#      absence means graph.json/GRAPH_REPORT.md may be a crash-mismatched pair.
#   2. Compares the on-disk bytes against the committed blob at
#      origin/<base>:graphify-out/{graph.json,GRAPH_REPORT.md} (content hash,
#      NOT mtime — mtime is exactly the trap HIMMEL-1123 warned about).
#      Identical -> refuse cleanly, nothing to do.
#   3. Refuses if the working tree has uncommitted changes OUTSIDE
#      graphify-out/{graph.json,GRAPH_REPORT.md} — this script only ever
#      touches those two paths; anything else dirty must be committed/stashed
#      by the operator first (keeps the branch-switch below provably safe).
#   4. Records the publish branch's CURRENT remote OID (if any) before doing
#      any local mutation, then git checkout -B <branch> origin/<base>,
#      `git commit --only` the two paths (conventional commit, self-attesting
#      `Security reviewed: ad-hoc` since graphify-out/*.json is NOT
#      docs-exempt under check-security-reviewed.sh's filter and would
#      otherwise block the push), and pushes pinned to that EXACT recorded
#      OID via `--force-with-lease=<ref>:<oid>` (CR round 2, codex-adv-1: a
#      concurrent publisher's newer commit must be DETECTED and REJECTED, not
#      silently adopted as our own "expected" baseline and overwritten — see
#      the comment at the push site for the full TOCTOU explanation). Then
#      opens/refreshes the PR via scripts/lib/forge.sh (same seam pr-open.sh
#      uses — idempotent create-or-edit).
#   5. Best-effort switches back to the branch the operator was on.
#
# `Security reviewed: ad-hoc` is a DELIBERATE, DATA-ONLY exception to the
# "operator actually reviews it" spirit of that attestation: the commit is a
# regenerated JSON/markdown snapshot with no code surface, so ad-hoc (low-risk,
# operator-judged-adequate per check-security-reviewed.sh's own vocabulary) is
# an honest self-attestation here. Do NOT copy this auto-attestation pattern
# onto a script that commits actual code paths.
#
# Usage:
#   graph-publish.sh [--dry-run] [--base <branch>] [--no-fetch]
#
# Exit codes:
#   0  published (branch pushed + PR opened/updated), or --dry-run preview
#   1  usage error
#   2  required tool missing (git or gh)
#   3  refused: no local graphify-out/graph.json on disk
#   4  refused: repo does not track graphify-out/graph.json (HIMMEL-1123 not
#      applied here — nothing to publish TO)
#   5  refused: nothing newer to publish (local graph == shipped graph)
#   6  refused: working tree has uncommitted changes outside
#      graphify-out/{graph.json,GRAPH_REPORT.md}
#   7  cannot resolve a base ref (fetch failed and no local/origin ref exists)
#   8  checkout/commit/push failed (git error surfaced)
#   9  pushed, but the PR was NOT opened/refreshed (forge undetectable, or
#      `gh pr create`/`gh pr edit` failed) — the branch is pushed; open the PR
#      manually. Distinct from rc=0 on purpose: this is a PARTIAL success
#      (the command's contract is "commit + open/refresh the PR"), and a
#      cadence/scripted caller must be able to see that the PR step did not
#      happen rather than reading a false-green 0.
#  10  refused: graphify-out/manifest.json is missing — refresh-graph-map.sh's
#      transaction marker is absent, so graph.json/GRAPH_REPORT.md may be an
#      inconsistent pair (no completed refresh here, or one crashed
#      mid-promote). Re-run refresh-graph-map.sh first.
#  11  refused: graphify-out/GRAPH_REPORT.md is missing though graph.json
#      (and manifest.json) are present — refresh-graph-map.sh always promotes
#      both together, so this is an anomalous state (report deleted after a
#      completed refresh?). Restore GRAPH_REPORT.md or re-run
#      refresh-graph-map.sh, then retry.
#
# Environment:
#   GH_CMD                 Default `gh` (tests override with a fake).
#   GRAPH_PUBLISH_BASE      Default base branch/ref. Default: main.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$HERE/../lib/forge.sh"

DRY_RUN=0
BASE_REF="${GRAPH_PUBLISH_BASE:-main}"
DO_FETCH=1

usage() {
    cat <<'EOF'
usage: graph-publish.sh [--dry-run] [--base <branch>] [--no-fetch]

Publishes a freshly-refreshed graphify-out/graph.json (+ GRAPH_REPORT.md) by
opening/refreshing a PR — the operator-invoked step HIMMEL-1123's tracked
graph needed and never got. Refuses cleanly when there is nothing newer than
the shipped (committed) graph to publish.

Optional:
  --dry-run       Report what would happen; makes no git/gh mutations. Implies
                  --no-fetch (a real fetch is a network call, not a mutation,
                  but "makes no git/gh calls" should mean exactly that).
  --base <ref>    Base branch to publish against. Default: $GRAPH_PUBLISH_BASE
                  or `main`.
  --no-fetch      Skip `git fetch origin <base>`; use whatever origin/<base>
                  is already known locally (offline mode).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)  DRY_RUN=1; shift ;;
        --base)     BASE_REF="${2:?--base requires a value}"; shift 2 ;;
        --no-fetch) DO_FETCH=0; shift ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "ERR graph-publish: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done
[ "$DRY_RUN" -eq 1 ] && DO_FETCH=0

command -v git >/dev/null 2>&1 || { echo "ERR graph-publish: required tool 'git' not on PATH" >&2; exit 2; }
if [ "$DRY_RUN" -eq 0 ]; then
    command -v "${GH_CMD:-gh}" >/dev/null 2>&1 || { echo "ERR graph-publish: required tool '${GH_CMD:-gh}' not on PATH" >&2; exit 2; }
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "ERR graph-publish: not inside a git repo" >&2; exit 2; }
cd "$repo_root"

GRAPH_PATH="graphify-out/graph.json"
REPORT_PATH="graphify-out/GRAPH_REPORT.md"
corpus=$(basename "$repo_root")

# --- 1. repo tracks the graph at all (HIMMEL-1123 applied here) -------------
if ! git ls-files --error-unmatch "$GRAPH_PATH" >/dev/null 2>&1; then
    echo "ERR graph-publish: this repo does not track $GRAPH_PATH (HIMMEL-1123 not applied here) — nothing to publish to." >&2
    exit 4
fi

# --- 2. a local graph exists on disk -----------------------------------------
[ -f "$GRAPH_PATH" ] || { echo "ERR graph-publish: no local $GRAPH_PATH on disk — run refresh-graph-map.sh first." >&2; exit 3; }

# --- 2a. the report is REQUIRED, never optional (CR round 2, codex-1/-adv-2) -
# refresh-graph-map.sh's promote sequence copies + moves graph.json and
# GRAPH_REPORT.md unconditionally together (verified by reading its promote
# block, same read that grounded the 2b manifest check below) -- there is no
# legitimate completed-refresh state with graph.json present and
# GRAPH_REPORT.md absent. Treating the report as "optional, publish graph.json
# alone if it's missing" would let a deleted/corrupted report through: the
# published graph.json would then sit on the base branch paired with whatever
# OLD GRAPH_REPORT.md is already committed there -- a silently mismatched pair.
[ -f "$REPORT_PATH" ] || { echo "ERR graph-publish: $GRAPH_PATH is present but $REPORT_PATH is missing -- refresh-graph-map.sh always promotes both together, so this is anomalous (report deleted after a completed refresh?). Restore $REPORT_PATH or re-run refresh-graph-map.sh, then retry." >&2; exit 11; }

# --- 2b. refresh-graph-map.sh's transaction must be COMPLETE ----------------
# refresh-graph-map.sh's promote sequence (CR round 1, codex-adv-4): it first
# `rm -f`s graphify-out/manifest.json (invalidating the old stamp), THEN
# promotes graph.json + GRAPH_REPORT.md, and ONLY THEN, last, promotes a fresh
# manifest.json (each step an atomic same-dir rename). manifest.json's
# PRESENCE is therefore exactly "the last promote fully completed" -- its
# ABSENCE means either no refresh ever ran here, or one crashed mid-promote
# (disk full, killed process), in which case graph.json and GRAPH_REPORT.md
# may be an inconsistent pair (one replaced, the other not). Publishing that
# pair would ship a graph without its matching report, or vice versa, with no
# signal anything was wrong. manifest.json itself is intentionally NOT
# published (HIMMEL-1123: its mtimes are machine-local) -- this is a LOCAL
# precondition check only, never committed.
MANIFEST_PATH="graphify-out/manifest.json"
if [ ! -f "$MANIFEST_PATH" ]; then
    echo "ERR graph-publish: $MANIFEST_PATH is missing — refresh-graph-map.sh's transaction marker is absent, so $GRAPH_PATH/$REPORT_PATH may be an inconsistent pair (no refresh has completed here, or one crashed mid-promote). Re-run refresh-graph-map.sh, then retry." >&2
    exit 10
fi

# --- 3. resolve the base ref -------------------------------------------------
if [ "$DO_FETCH" -eq 1 ]; then
    git fetch -q origin "$BASE_REF" 2>/dev/null || echo "graph-publish: WARN git fetch origin $BASE_REF failed — falling back to whatever is known locally" >&2
fi
if git rev-parse --verify --quiet "origin/$BASE_REF" >/dev/null; then
    base_ref="origin/$BASE_REF"
elif git rev-parse --verify --quiet "$BASE_REF" >/dev/null; then
    base_ref="$BASE_REF"
    echo "graph-publish: WARN no origin/$BASE_REF — comparing/branching off local $BASE_REF instead" >&2
else
    echo "ERR graph-publish: cannot resolve origin/$BASE_REF or local $BASE_REF — nothing to publish against." >&2
    exit 7
fi

# --- 4. is there anything newer than the shipped graph? (content hash, not mtime) ---
local_graph_sha=$(git hash-object "$GRAPH_PATH")
base_graph_sha=$(git rev-parse --verify --quiet "${base_ref}:${GRAPH_PATH}" 2>/dev/null || echo "")
local_report_sha=$(git hash-object "$REPORT_PATH")
base_report_sha=$(git rev-parse --verify --quiet "${base_ref}:${REPORT_PATH}" 2>/dev/null || echo "")
if [ "$local_graph_sha" = "$base_graph_sha" ] && [ "$local_report_sha" = "$base_report_sha" ]; then
    echo "graph-publish: nothing to publish — local $GRAPH_PATH + $REPORT_PATH already match ${base_ref}."
    exit 5
fi

# --- 5. working tree must be clean OUTSIDE the two graph paths --------------
dirty_other=$(git status --porcelain -- . ":!${GRAPH_PATH}" ":!${REPORT_PATH}" 2>/dev/null || true)
if [ -n "$dirty_other" ]; then
    echo "ERR graph-publish: working tree has uncommitted changes outside graphify-out/{graph.json,GRAPH_REPORT.md} — commit or stash them first, then re-run:" >&2
    printf '%s\n' "$dirty_other" | sed 's/^/  /' >&2
    exit 6
fi

files_block="- \`$GRAPH_PATH\`
- \`$REPORT_PATH\`"

# Sanitize the corpus (repo dirname) into a valid, unambiguous branch-name
# component (CR round 2, glm-5): a repo dir containing spaces or other
# branch-hostile characters would otherwise reach `git checkout -B` verbatim
# and fail there with a confusing generic rc=8, instead of a clear cause.
corpus_slug=$(printf '%s' "$corpus" | tr -c 'A-Za-z0-9._-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//')
[ -n "$corpus_slug" ] || corpus_slug="repo"

BRANCH="chore/graph-publish-${corpus_slug}"
title="chore(graphify): publish refreshed ${corpus} graph"
commit_msg="chore(graphify): publish refreshed ${corpus} graph

Republishes graphify-out/graph.json + GRAPH_REPORT.md for ${corpus}, regenerated locally via refresh-graph-map.sh (HIMMEL-1129). Not code — a regenerated data snapshot; ad-hoc-reviewed as low-risk per check-security-reviewed.sh's non-docs classification of graphify-out/*.json.

Security reviewed: ad-hoc"
pr_body="## Summary

Publishes a refreshed graphify-out/graph.json + GRAPH_REPORT.md for **${corpus}** so stations without the resources to re-extract (e.g. win2) pull current structure instead of an arbitrarily stale shipped graph (HIMMEL-1129).

## Files changed

${files_block}

## Ticket

- HIMMEL-1129

---

🤖 Opened by \`scripts/graphify/graph-publish.sh\` (HIMMEL-1129)."

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY graph-publish: would publish $GRAPH_PATH + $REPORT_PATH for corpus '$corpus' against $base_ref"
    echo "DRY graph-publish: would checkout -B $BRANCH $base_ref, commit --only the graph paths, force-with-lease-push pinned to the recorded remote OID, then open/refresh a PR"
    echo "--- commit message ---"
    printf '%s\n' "$commit_msg"
    echo "--- /commit message ---"
    exit 0
fi

current_branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")

restore_branch() {
    if [ -n "$current_branch" ] && [ "$current_branch" != "HEAD" ]; then
        git checkout -q "$current_branch" 2>/dev/null || true
    fi
}

# Record the publish branch's CURRENT remote OID NOW, before any local
# mutation, and pin the push below to EXACTLY this value (CR round 2,
# codex-adv-1). Fetching right before push (round 1's fix) was itself racy:
# a concurrent publisher's newer commit landing between our checkout/commit
# and a LATE fetch would be picked up AS our own "expected" baseline, and
# force-with-lease would then happily let us overwrite it with our (older)
# snapshot -- a SILENT regression to a stale graph, with git's own safety
# mechanism defeated by its own freshness. Recording the OID here and pinning
# the push to it means a concurrent advance is DETECTED (the recorded OID no
# longer matches what force-with-lease finds on push) and REJECTED, not
# silently absorbed. remote_oid="" (branch does not exist yet on origin) pins
# to `--force-with-lease=<ref>:` (git's own "must not already exist" form),
# which is a STRONGER guarantee than round 1's bare --force-with-lease gave a
# first-ever publish.
git fetch -q origin "$BRANCH" 2>/dev/null || true
remote_oid=$(git rev-parse --verify --quiet "origin/$BRANCH" 2>/dev/null || echo "")

# TEST-ONLY seam (never set this in production): lets test-graph-publish.sh
# deterministically land a "concurrent publisher" commit on the bare test
# origin between the OID recorded above and the push below, proving the
# pinned lease actually rejects a stale-vs-current mismatch rather than
# silently winning. A no-op unless the env var is set.
# Contract (security hardening): GRAPH_PUBLISH_TEST_RACE_HOOK is a PATH to an
# executable hook FILE, never a string of shell to eval -- an eval here would
# let any caller inject arbitrary code into a script that pushes with
# operator credentials. We execute that file directly, and refuse anything
# that is not a present, executable regular file.
if [ -n "${GRAPH_PUBLISH_TEST_RACE_HOOK:-}" ]; then
    hook_path="$GRAPH_PUBLISH_TEST_RACE_HOOK"
    # Force a path-form invocation: a slash-less relative value would pass the
    # -f/-x checks against ./name but PATH-search on execution, so the file
    # validated and the file run could differ (CR round 1, codex-1).
    case "$hook_path" in
        */*) : ;;
        *) hook_path="./$hook_path" ;;
    esac
    if [ ! -f "$hook_path" ] || [ ! -x "$hook_path" ]; then
        echo "ERR graph-publish: GRAPH_PUBLISH_TEST_RACE_HOOK is set but '$hook_path' is not a present, executable file -- refusing to run it." >&2
        exit 1
    fi
    "$hook_path"
fi

paths=("$GRAPH_PATH" "$REPORT_PATH")

if ! git checkout -B "$BRANCH" "$base_ref"; then
    echo "ERR graph-publish: checkout -B $BRANCH $base_ref failed — see git output above. Working tree is untouched (nothing was committed/pushed)." >&2
    restore_branch
    exit 8
fi

if ! git commit --only -m "$commit_msg" -- "${paths[@]}"; then
    echo "ERR graph-publish: git commit failed." >&2
    restore_branch
    exit 8
fi

if [ -n "$remote_oid" ]; then
    lease_spec="--force-with-lease=refs/heads/${BRANCH}:${remote_oid}"
else
    lease_spec="--force-with-lease=refs/heads/${BRANCH}:"
fi
if ! git push "$lease_spec" origin "$BRANCH"; then
    echo "ERR graph-publish: push rejected -- refs/heads/$BRANCH moved on origin since this publish started (a concurrent publisher likely landed first). Nothing was overwritten; re-run to publish on top of the new tip." >&2
    restore_branch
    exit 8
fi

restore_branch

# From here down, any failure is a PARTIAL success (branch pushed, PR step
# incomplete) -> rc=9, never rc=0. rc=0 must mean "commit + PR" both happened;
# folding a silent PR-open miss into rc=0 is exactly the false-green class a
# cadence/scripted caller could never see (CR round 1, codex-1).
if ! forge_detect >/dev/null 2>&1; then
    echo "graph-publish: pushed $BRANCH but cannot determine forge (need a github.com/bitbucket.org origin) — open the PR manually." >&2
    exit 9
fi

existing_pr=""
if existing_pr=$(forge_pr_find_open "$BRANCH" 2>/dev/null); then
    :
else
    existing_pr=""
fi

if [ -z "$existing_pr" ]; then
    if ! out=$(forge_pr_create "$title" "$pr_body" "$BASE_REF" "$BRANCH" 2>&1); then
        echo "graph-publish: pushed $BRANCH but PR create failed (branch is still pushed; open it manually):" >&2
        printf '%s\n' "$out" >&2
        exit 9
    fi
    echo "graph-publish: opened $out"
else
    if ! out=$(forge_pr_set_body "$existing_pr" "$title" "$pr_body" 2>&1); then
        echo "graph-publish: pushed $BRANCH but PR body update failed (branch is still pushed; PR remains as-is):" >&2
        printf '%s\n' "$out" >&2
        exit 9
    fi
    echo "graph-publish: updated PR #$existing_pr"
fi
exit 0
