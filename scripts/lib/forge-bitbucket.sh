#!/usr/bin/env bash
# forge-bitbucket.sh — Bitbucket Cloud backend for the forge seam (HIMMEL-326).
#
# Symmetric with forge-github.sh: every verb shells out to the himmel
# `bitbucket` CLI (scripts/bitbucket/dist/index.js) the same way the github
# backend shells out to `gh`. The CLI emits JSON (the `gh --json` analogue);
# this backend projects it to the scalar each verb's caller expects, parsing
# with node (guaranteed present — the CLI itself runs under node) so there is
# no jq dependency. Sourced by forge.sh; not run directly.

# Resolve the bitbucket CLI command. Default mirrors the Jira-CLI convention:
# invoke dist/index.js by absolute path from the PRIMARY checkout (dist/ is an
# untracked build artifact; worktrees lack it). Override via BITBUCKET_CMD
# (tests point this at a stub that echoes fixture JSON — the BITBUCKET_CMD seam,
# exact parallel to GH_CMD, spec §8).
_bb_cmd() {
    if [ -n "${BITBUCKET_CMD:-}" ]; then
        printf '%s' "$BITBUCKET_CMD"
        return 0
    fi
    local common primary
    common=$(git rev-parse --git-common-dir 2>/dev/null) || common=""
    if [ -n "$common" ]; then
        primary=$(cd "$(dirname "$common")" && pwd)
        printf 'node %s/scripts/bitbucket/dist/index.js' "$primary"
    else
        printf 'bitbucket'
    fi
}

# Run the bitbucket CLI ($BITBUCKET_CMD may be "node /path/index.js" — split on
# spaces so the leading words become argv, not a single command).
_bb() {
    # shellcheck disable=SC2046  # intentional word-split of the command string
    $(_bb_cmd) "$@"
}

# Read JSON on stdin, print a top-level string field (empty if absent). Parse
# defensively so a non-JSON line never crashes the caller.
_bb_str_field() {
    node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let j={};try{j=JSON.parse(s||"null")||{}}catch{};process.stdout.write(String(j[process.argv[1]]??""))})' "$1"
}

bb_forge_auth_status() {
    _bb auth status >/dev/null 2>&1
}

# NOTE on the capture-then-parse shape below: piping `_bb … | node` would mask a
# CLI failure (auth 401 / network / 404) because the pipeline's exit status is
# node's, not the CLI's — node would parse empty stdin and print "" / "0",
# silently turning an error into a plausible-but-wrong answer (a clean-garden
# prune skip, a duplicate-PR create). So each read verb captures the CLI stdout,
# propagates a non-zero CLI exit, and only then parses. (The GitHub backend gets
# this for free — its verbs are single `gh` calls whose exit propagates.)
bb_forge_repo_nwo() {
    local out
    out=$(_bb repo view) || return 1
    printf '%s' "$out" | _bb_str_field full_name
}

bb_forge_default_branch() {
    local out
    out=$(_bb repo view) || return 1
    printf '%s' "$out" | _bb_str_field default_branch
}

bb_forge_user_slug() {
    _bb user --slug
}

# echo the open PR id for a branch, or "" if none.
bb_forge_pr_find_open() {
    local branch="$1" out
    out=$(_bb pr list --head "$branch" --state OPEN) || return 1
    printf '%s' "$out" |
        node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let a=[];try{a=JSON.parse(s||"[]")}catch{};process.stdout.write(Array.isArray(a)&&a[0]?String(a[0].id):"")})'
}

# create a PR; echo its URL. args: TITLE BODY BASE HEAD
# Capture-then-parse (see the note above the read verbs): a direct
# `_bb … | _bb_str_field` pipe would mask a CLI failure (the pipeline exit
# status is node's), reporting a failed create as success with a blank URL.
bb_forge_pr_create() {
    local title="$1" body="$2" base="$3" head="$4" out
    out=$(_bb pr create --title "$title" --body "$body" --source "$head" --destination "$base") || return 1
    printf '%s' "$out" | _bb_str_field url
}

# update an existing PR body via the `pr edit` CLI verb (PUT .../{id}). The
# Bitbucket PUT requires a title (a bare description update 400s), so the seam
# passes one — pr-open regenerates the title each run, keeping it in sync.
# args: NUMBER TITLE BODY. Capture-then-discard so the CLI's JSON echo doesn't
# leak to stdout; propagate a non-zero CLI exit (pr-open treats a set_body
# failure as best-effort, exactly like the GitHub path).
bb_forge_pr_set_body() {
    local number="$1" title="$2" body="$3" out
    out=$(_bb pr edit "$number" --title "$title" --body "$body") || return 1
    return 0
}

# Bitbucket Cloud has no mergeable field and no dry-run merge (spec §5.1). The
# only definitive conflict signal is the 400 at real merge time, so a non-
# destructive pre-check cannot determine mergeability — echo UNKNOWN
# (non-blocking). The conflict surfaces in bb_forge_pr_merge. args: NUMBER
bb_forge_pr_mergeable() {
    echo "UNKNOWN"
}

# count merged PRs whose source branch is BRANCH (clean-garden prune signal).
bb_forge_pr_has_merged() {
    local branch="$1" out
    out=$(_bb pr list --head "$branch" --state MERGED) || return 1
    printf '%s' "$out" |
        node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{let a=[];try{a=JSON.parse(s||"[]")}catch{};process.stdout.write(String(Array.isArray(a)?a.length:0))})'
}

# squash-merge + close source branch. args: NUMBER [VETTED_HEAD_SHA]
# rc 0 = merged; rc 4 = failure. The CLI exits 2 on a merge conflict (the
# verified §5.1 signal, atomic — nothing merged); surface that distinctly from a
# generic failure so a caller can tell "rebase needed" from "auth/network died".
#
# VETTED_HEAD_SHA (HIMMEL-1058) is accepted for seam parity and IGNORED: the
# Bitbucket Cloud merge endpoint has no --match-head-commit equivalent, so the
# TOCTOU window cannot be closed here. It stays theoretical on this backend —
# the CR/CI gates that produce a vetted SHA are GitHub-only (pr-merge.sh runs
# them under `[ "$forge" = "github" ]`), so no bitbucket caller has one to pass.
bb_forge_pr_merge() {
    local number="$1"
    if _bb pr merge "$number" --squash --delete-branch; then
        echo "forge(bitbucket): merged PR #$number"
        return 0
    fi
    local rc=$?
    if [ "$rc" -eq 2 ]; then
        echo "ERR forge(bitbucket): PR #$number has merge conflicts (nothing merged, spec §5.1) — rebase and retry." >&2
    else
        echo "ERR forge(bitbucket): pr merge #$number failed (rc=$rc)." >&2
    fi
    return 4
}

# file a CR deferred-issue; echo the issue URL. args: REPO TITLE BODY LABEL.
# REPO ($1) and LABEL ($4) are github-shaped and IGNORED here: the bitbucket CLI
# derives {workspace}/{repo} from the origin remote, and Bitbucket issues carry
# no free-form labels (only a `kind`). Capture-then-parse (see the note above the
# read verbs) so a CLI failure isn't masked into a blank URL.
#
# rc 3 = the issue tracker is disabled (CLI exit 3 on the verified §5.2 404) —
# propagated distinctly so the deferred filer degrades gracefully (skip + warn)
# rather than treating it as a hard failure. rc 1 = any other failure.
bb_forge_issue_create() {
    local title="$2" body="$3" out rc=0
    out=$(_bb issue create --title "$title" --body "$body") || rc=$?
    if [ "$rc" -eq 0 ]; then
        printf '%s' "$out" | _bb_str_field url
        return 0
    fi
    if [ "$rc" -eq 3 ]; then
        return 3
    fi
    return 1
}
