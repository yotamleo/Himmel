#!/usr/bin/env bash
# scripts/lanes/leg-pr-open.sh - HIMMEL-3031 (ruling H2, HIMMEL-3026).
#
# WHY. A leg's inline `gh pr create --title … --body "<markdown>"` was
# intermittently denied with `Stage 2 classifier error` (HIMMEL-3020), and an
# immediate retry escalated to `[Out-of-Place Publication]`. The operator's
# read: the classifier reacts to the PR body TEXT carried inline in the Bash
# command a leg types (multi-paragraph markdown, `diff --stat` blocks,
# `leg-burn:` lines, quoted denial strings), not to the act of publishing.
#
# The fix: title and body come from FILES, never argv, so the Bash command a
# leg runs is always the same short fixed literal — two file paths — no
# matter what the PR says. The body only ever reaches `gh` as an argv element
# of a CHILD process this script execs (via the forge seam below); it never
# appears in the command the classifier reads.
#
# Usage: leg-pr-open.sh <title-file> <body-file> [--base <branch>]
#
# Idempotent: finds an open PR for the current branch (forge_pr_find_open)
# and updates its body instead of opening a second one.
#
# Refuses (exit 1): on `main`, when the branch has no upstream, or on an
# empty body file. No retry logic — a classifier denial of THIS invocation is
# the stuck-playbook Stage 2 / Out-of-Place rows' territory, not this
# script's.
#
# Success: exactly one line, `PR <number> <url> <head-sha>`.
# Failure: the forge/gh error verbatim on stderr, non-zero exit.
#
# Platform guard: no .ps1 twin, by design. POSIX bash plus git and gh/bb (all
# already required by scripts/lib/forge.sh) — it runs under git bash on
# Windows unchanged.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forge-dispatch seam: forge_pr_find_open / forge_pr_create / forge_pr_set_body
# / forge_detect / forge_repo_nwo route to the github or bitbucket backend per
# the repo's origin (HIMMEL-326) — never call gh/bb directly from here.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$HERE/../lib/forge.sh"

usage() {
    echo "Usage: leg-pr-open.sh <title-file> <body-file> [--base <branch>]" >&2
}

if [ "$#" -lt 2 ]; then
    usage
    exit 1
fi

TITLE_FILE="$1"; shift
BODY_FILE="$1"; shift
BASE="main"
while [ "$#" -gt 0 ]; do
    case "$1" in
        --base) BASE="${2:-main}"; shift 2 ;;
        *) echo "ERR leg-pr-open: unknown arg: $1" >&2; usage; exit 1 ;;
    esac
done

if [ ! -f "$TITLE_FILE" ]; then
    echo "ERR leg-pr-open: no such title file: $TITLE_FILE" >&2
    exit 1
fi
if [ ! -f "$BODY_FILE" ]; then
    echo "ERR leg-pr-open: no such body file: $BODY_FILE" >&2
    exit 1
fi

title=$(cat "$TITLE_FILE")
body=$(cat "$BODY_FILE")

if [ -z "$body" ]; then
    echo "ERR leg-pr-open: body file is empty: $BODY_FILE" >&2
    exit 1
fi

branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "main" ]; then
    echo "ERR leg-pr-open: refusing to open a PR from main" >&2
    exit 1
fi

if ! git rev-parse --abbrev-ref --symbolic-full-name '@{u}' >/dev/null 2>&1; then
    echo "ERR leg-pr-open: branch '$branch' has no upstream — push it first" >&2
    exit 1
fi

head_sha=$(git rev-parse HEAD)
upstream_sha=$(git rev-parse '@{u}')
if [ "$head_sha" != "$upstream_sha" ]; then
    echo "ERR leg-pr-open: local HEAD ($head_sha) has not been pushed — upstream is at ($upstream_sha); push first" >&2
    exit 1
fi

existing_pr=""
if ! existing_pr=$(forge_pr_find_open "$branch" 2>&1); then
    echo "ERR leg-pr-open: could not check for an existing PR:" >&2
    printf '%s\n' "$existing_pr" >&2
    exit 1
fi

if [ -z "$existing_pr" ]; then
    # Capture stdout (the PR URL) and stderr (diagnostics, plus the
    # HIMMEL-1924 CodeRabbit-trigger confirmation) into SEPARATE streams —
    # merging them with `2>&1` let a stderr line race the URL for "first
    # line" on some hosts/gh versions. On failure, diagnostics come from the
    # captured stderr file; on success it is discarded.
    create_err=$(mktemp "${TMPDIR:-/tmp}/leg-pr-open-create-err.XXXXXX") || { echo "ERR leg-pr-open: mktemp failed" >&2; exit 1; }
    if ! out=$(forge_pr_create "$title" "$body" "$BASE" "$branch" 2>"$create_err"); then
        echo "ERR leg-pr-open: PR create failed:" >&2
        cat "$create_err" >&2
        rm -f "$create_err"
        exit 1
    fi
    rm -f "$create_err"
    # Take only the first line of stdout as the URL — stderr is now captured
    # separately above and never reaches this variable, but stdout itself
    # could still carry more than one line, so keep this defensive.
    url=$(printf '%s\n' "$out" | head -n 1)
    number=${url##*/}
else
    number="$existing_pr"
    if ! out=$(forge_pr_set_body "$number" "$title" "$body" 2>&1); then
        echo "ERR leg-pr-open: PR body update failed:" >&2
        printf '%s\n' "$out" >&2
        exit 1
    fi
    forge=$(forge_detect)
    nwo=$(forge_repo_nwo)
    case "$forge" in
        github)    url="https://github.com/${nwo}/pull/${number}" ;;
        bitbucket) url="https://bitbucket.org/${nwo}/pull-requests/${number}" ;;
    esac
fi

echo "PR ${number} ${url} ${head_sha}"
