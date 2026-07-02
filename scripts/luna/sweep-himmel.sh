#!/usr/bin/env bash
# sweep-himmel.sh — LUNA-5 Wedge A.
#
# Walks recent himmel merged PRs + yotam_docs handover commits in a time
# window and emits a single PARA-compliant Obsidian markdown file listing
# them as "candidate" entries. Default mode is --dry-run (prints to stdout).
# With --pr, clones the luna-brain repo, writes the candidate file into
# 00-Inbox/, pushes a branch, and opens a PR.
#
# Why this exists: the operator runs a himmel monorepo + a yotam_docs
# handover repo. Architectural decisions, plugin additions, and learnings
# accumulate in PR bodies and handover notes. Periodically, those should
# graduate into the luna second-brain so future-Claude can surface them
# during retrieval. This script does the periodic walk; promotion to
# 10-Projects / 30-Resources is a separate manual triage step performed
# in the luna vault directly.
#
# Output format matches luna-brain/_CLAUDE.md:
#   - frontmatter: type, date, tags, ai-first: true, source
#   - "For future Claude" preamble (2-3 sentences)
#   - per-PR + per-commit sections with source URLs and dates
#
# This is Wedge A of LUNA-5. Wedge B (/luna-ingest <x.com-url>) ships
# separately.

set -euo pipefail

SCRIPT_NAME="$(basename "$0")"

# Default values
DAYS=7
SINCE=""
DAYS_EXPLICIT=0
SINCE_EXPLICIT=0
MODE="dry-run"   # dry-run (default) | pr | out
OUT_PATH=""
HIMMEL_REPO_FULL="yotamleo/himmel"
LUNA_BRAIN_REPO_FULL="yotamleo/luna-brain"
YOTAM_DOCS_PATH="${YOTAM_DOCS_PATH:-$HOME/Documents/github/yotam_docs}"

# Distinct exit codes
EXIT_NO_CHANGES=3

usage() {
    cat <<EOF
$SCRIPT_NAME — sweep recent himmel + yotam_docs activity into a luna candidate file.

USAGE:
    $SCRIPT_NAME [--days N | --since YYYY-MM-DD]
                 [--dry-run | --pr | --out PATH]
                 [--yotam-docs PATH] [-h|--help]

OPTIONS:
    --days N          Look back N days (default: 7). Mutually exclusive with --since.
    --since DATE      Look back to absolute date (YYYY-MM-DD).
    --dry-run         Print candidate markdown to stdout (DEFAULT).
    --out PATH        Write candidate markdown to PATH.
    --pr              Clone luna-brain, write to 00-Inbox/, push, open PR.
    --yotam-docs PATH Override path to yotam_docs checkout
                      (default: \$YOTAM_DOCS_PATH or ~/Documents/github/yotam_docs).
    -h, --help        Show this help.

EXAMPLES:
    $SCRIPT_NAME                                  # last 7 days, print to stdout
    $SCRIPT_NAME --days 14 --out /tmp/sweep.md    # last 14 days, write to file
    $SCRIPT_NAME --since 2026-05-01 --pr          # since May 1, open PR in luna-brain

REQUIREMENTS:
    - gh (authenticated for yotamleo/himmel + yotamleo/luna-brain)
    - jq
    - git
    - A local clone of yotam_docs (for handover commit walk)
EOF
}

die() {
    echo "$SCRIPT_NAME: error: $*" >&2
    exit 1
}

log() {
    echo "$SCRIPT_NAME: $*" >&2
}

# ---- arg parsing -----------------------------------------------------

while [[ $# -gt 0 ]]; do
    case "$1" in
        --days)
            [[ -n "${2:-}" ]] || die "--days requires an integer argument"
            [[ "$2" =~ ^[0-9]+$ ]] || die "--days argument must be a positive integer, got: $2"
            [[ "$SINCE_EXPLICIT" -eq 1 ]] && die "--days and --since are mutually exclusive"
            DAYS="$2"
            DAYS_EXPLICIT=1
            shift 2
            ;;
        --since)
            [[ -n "${2:-}" ]] || die "--since requires a YYYY-MM-DD argument"
            [[ "$2" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || die "--since must be YYYY-MM-DD, got: $2"
            [[ "$DAYS_EXPLICIT" -eq 1 ]] && die "--days and --since are mutually exclusive"
            SINCE="$2"
            SINCE_EXPLICIT=1
            shift 2
            ;;
        --dry-run)
            MODE="dry-run"
            shift
            ;;
        --pr)
            MODE="pr"
            shift
            ;;
        --out)
            [[ -n "${2:-}" ]] || die "--out requires a PATH argument"
            MODE="out"
            OUT_PATH="$2"
            shift 2
            ;;
        --yotam-docs)
            [[ -n "${2:-}" ]] || die "--yotam-docs requires a PATH argument"
            YOTAM_DOCS_PATH="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument: $1 (use -h for help)"
            ;;
    esac
done

# ---- prereq checks ---------------------------------------------------

command -v gh  >/dev/null 2>&1 || die "gh CLI not installed or not on PATH"
command -v jq  >/dev/null 2>&1 || die "jq not installed or not on PATH"
command -v git >/dev/null 2>&1 || die "git not installed or not on PATH"

# Pre-flight: an unauthenticated gh returns rc=0 + `[]` from pr list, which
# would be indistinguishable from a genuinely quiet week. Fail loud here.
if ! gh_auth_err=$(gh auth status --hostname github.com 2>&1); then
    die "gh not authenticated for github.com — run \`gh auth login\` first. Details: $gh_auth_err"
fi

# Resolve SINCE if --days was used
if [[ -z "$SINCE" ]]; then
    # GNU date and BSD date diverge; try GNU first, fall back to BSD
    if SINCE=$(date -u -d "${DAYS} days ago" +%Y-%m-%d 2>/dev/null); then
        :
    elif SINCE=$(date -u -v "-${DAYS}d" +%Y-%m-%d 2>/dev/null); then
        :
    else
        die "could not compute SINCE date — neither GNU nor BSD date worked"
    fi
fi

TODAY=$(date -u +%Y-%m-%d)
log "sweep window: $SINCE to $TODAY (mode: $MODE)"

# ---- gather PRs ------------------------------------------------------

log "querying merged PRs in $HIMMEL_REPO_FULL since $SINCE …"

# `--state merged` restricts state; `merged:>=DATE` bounds the window
# (gh sends both to the GitHub search API). Limit 100 = sane upper bound
# for a weekly sweep; bump if the operator's velocity exceeds it.
PR_JSON=$(gh pr list \
    --repo "$HIMMEL_REPO_FULL" \
    --state merged \
    --search "merged:>=$SINCE" \
    --limit 100 \
    --json number,title,body,mergedAt,url,author,labels \
    2>&1) || die "gh pr list failed: $PR_JSON"

PR_COUNT=$(echo "$PR_JSON" | jq 'length')
log "found $PR_COUNT merged PRs in window"

# ---- gather handover commits ----------------------------------------

HANDOVER_COMMITS=""
HANDOVER_COUNT=0
if [[ -d "$YOTAM_DOCS_PATH/.git" ]]; then
    log "walking yotam_docs handover commits in $YOTAM_DOCS_PATH since $SINCE …"
    # Format: SHA<US>ISO_DATE<US>SUBJECT (US = ASCII 0x1f unit separator,
    # not TAB — git subjects can contain literal TABs and would silently
    # corrupt the per-commit split. Unit separator is reserved for this.)
    git_log_err=""
    # Append "00:00:00 +0000" so git treats SINCE as a UTC midnight, matching
    # gh's UTC interpretation of the PR `merged:>=DATE` qualifier above.
    # Without this, `git log --since="YYYY-MM-DD"` resolves to LOCAL midnight,
    # which silently shifts the handover window by up to ±24h vs the PR window.
    if HANDOVER_COMMITS=$(git -C "$YOTAM_DOCS_PATH" log \
        --since="${SINCE} 00:00:00 +0000" \
        --pretty=format:$'%H\x1f%ai\x1f%s' \
        -- handovers/yotam/ 2>&1); then
        if [[ -z "$HANDOVER_COMMITS" ]]; then
            HANDOVER_COUNT=0
        else
            HANDOVER_COUNT=$(printf '%s\n' "$HANDOVER_COMMITS" | wc -l | tr -d ' ')
        fi
        log "found $HANDOVER_COUNT handover commits in window"
    else
        git_log_err="$HANDOVER_COMMITS"
        HANDOVER_COMMITS=""
        HANDOVER_COUNT=0
        log "WARN: git log on $YOTAM_DOCS_PATH failed (continuing with 0 handover commits): $git_log_err"
    fi
else
    log "WARN: yotam_docs not found at $YOTAM_DOCS_PATH — skipping handover walk"
fi

# ---- emit candidate markdown ----------------------------------------

emit_candidate_md() {
    cat <<EOF
---
date: $TODAY
type: resource
tags:
  - sweep
  - himmel
  - luna-5-wedge-a
ai-first: true
source: scripts/luna/sweep-himmel.sh window $SINCE..$TODAY
---

# Himmel sweep — $SINCE to $TODAY

> For future Claude: aggregated activity from the yotamleo/himmel monorepo and yotamleo/yotam_docs handover repo over this window. Use this to find recent architectural decisions, plugin additions, ticket closures, or handover-noted patterns without re-walking PR history. Promote individual items into 10-Projects/, 30-Resources/, or 60-Maps/ if they earn a permanent home.

## Summary
- Merged PRs (himmel): **$PR_COUNT**
- Handover commits: **$HANDOVER_COUNT**
- Window: $SINCE to $TODAY (UTC)
- Generator: \`scripts/luna/sweep-himmel.sh\` (LUNA-5 Wedge A)

---

## Merged PRs

EOF

    if [[ "$PR_COUNT" -eq 0 ]]; then
        echo "_No merged PRs in this window._"
        echo ""
    else
        # Read via process substitution (not `jq | while read`) so the loop
        # runs in the PARENT shell — a pipe-fed while loop would swallow silent
        # jq failures and leave the script rc=0 with partial output. bash
        # 3.2-safe (macOS): no mapfile.
        PR_LINES=()
        while IFS= read -r _line; do PR_LINES+=("$_line"); done < <(printf '%s' "$PR_JSON" | jq -r '.[] | @json')
        for pr_line in "${PR_LINES[@]}"; do
            pr_number=$(echo "$pr_line" | jq -r '.number')
            pr_title=$(echo "$pr_line" | jq -r '.title')
            pr_url=$(echo "$pr_line" | jq -r '.url')
            pr_merged=$(echo "$pr_line" | jq -r '.mergedAt')
            pr_author=$(echo "$pr_line" | jq -r '.author.login // "unknown"')
            # head -c 600 = first 600 BYTES (not chars) of the PR body. A
            # multibyte trailing character (emoji / CJK) can be sliced
            # mid-codepoint and render as mojibake in the candidate file;
            # acceptable for an excerpt the operator triages, and avoids a
            # GNU-vs-BSD-specific char count fallback.
            pr_body_excerpt=$(echo "$pr_line" | jq -r '.body // ""' | head -c 600 | tr '\r\n' '  ' | sed 's/  */ /g')
            pr_labels=$(echo "$pr_line" | jq -r '[.labels[]?.name] | join(", ")')

            cat <<INNER
### [PR #${pr_number}](${pr_url}) — ${pr_title}
- Merged: \`${pr_merged}\` by @${pr_author}
- Labels: ${pr_labels:-_none_}
- Body excerpt: ${pr_body_excerpt:-_(empty)_}

INNER
        done
    fi

    cat <<EOF

---

## Handover commits

EOF

    if [[ "$HANDOVER_COUNT" -eq 0 ]]; then
        echo "_No handover commits in this window._"
        echo ""
    else
        # Format: SHA<US>ISO_DATE<US>SUBJECT (US = 0x1f, see git log call).
        while IFS=$'\x1f' read -r sha iso_date subject; do
            [[ -z "$sha" ]] && continue
            short_sha="${sha:0:8}"
            cat <<INNER
### \`${short_sha}\` — ${subject}
- Date: \`${iso_date}\`

INNER
        done <<< "$HANDOVER_COMMITS"
    fi

    cat <<EOF

---

## Triage guidance

For each entry above, future-Claude or the operator should decide:
1. Does it belong in \`10-Projects/\` (active work) or \`30-Resources/\` (reference)?
2. Does the linked content warrant a dedicated note with its own frontmatter?
3. Does it update an existing note in luna (cross-reference, recency marker update)?

This file lives in \`00-Inbox/\` until processed.
EOF
}

CANDIDATE_MD=$(emit_candidate_md)

# ---- dispatch by mode -----------------------------------------------

case "$MODE" in
    dry-run)
        echo "$CANDIDATE_MD"
        ;;
    out)
        out_dir="$(dirname "$OUT_PATH")"
        mkdir -p "$out_dir" || die "could not create output dir: $out_dir"
        printf '%s\n' "$CANDIDATE_MD" > "$OUT_PATH" || die "could not write $OUT_PATH"
        log "wrote $OUT_PATH"
        ;;
    pr)
        TMPDIR=$(mktemp -d -t luna-brain-sweep-XXXXXX) || die "mktemp failed"
        trap 'rm -rf "$TMPDIR"' EXIT

        log "cloning $LUNA_BRAIN_REPO_FULL to $TMPDIR …"
        clone_err=$(gh repo clone "$LUNA_BRAIN_REPO_FULL" "$TMPDIR/luna-brain" -- --depth 1 2>&1) \
            || die "gh repo clone failed: $clone_err"

        # Branch name includes UTC HHMMSS so same-day re-runs don't collide.
        # luna-brain branch protection only covers `main`; feature branches
        # are unrestricted, but a colliding push to an existing branch
        # would still fail (or, worse, fast-forward over a pending PR).
        BRANCH="luna/sweep-himmel-${TODAY}-$(date -u +%H%M%S)"
        OUT_FILE="$TMPDIR/luna-brain/00-Inbox/sweep-${TODAY}-from-himmel.md"

        cd "$TMPDIR/luna-brain" || die "could not cd into clone at $TMPDIR/luna-brain"

        # Last-ditch collision guard.
        if git ls-remote --exit-code origin "$BRANCH" >/dev/null 2>&1; then
            die "branch $BRANCH already exists on origin — unexpected; aborting to avoid clobber"
        fi

        checkout_err=$(git checkout -b "$BRANCH" 2>&1) || die "git checkout -b failed: $checkout_err"
        mkdir -p 00-Inbox || die "could not create 00-Inbox/ in clone"
        printf '%s\n' "$CANDIDATE_MD" > "$OUT_FILE" || die "could not write $OUT_FILE"
        git add 00-Inbox/ || die "git add failed"
        if git diff --cached --quiet; then
            log "WARN: no changes after writing $OUT_FILE — same content already on main, skipping PR"
            exit "$EXIT_NO_CHANGES"
        fi

        # Explicit identity + gpgsign override: the ephemeral clone inherits
        # no git config and may not have a signing key reachable under the
        # scheduled-task user; this commit is auto-generated and attributed to
        # the running user's global git identity (with a neutral fallback).
        sweep_name=$(git config --global user.name 2>/dev/null || echo "himmel-sweep")
        sweep_email=$(git config --global user.email 2>/dev/null || echo "himmel-sweep@users.noreply.github.com")
        commit_err=$(git \
            -c user.name="$sweep_name" \
            -c user.email="$sweep_email" \
            -c commit.gpgsign=false \
            commit -m "sweep: himmel ${SINCE}..${TODAY} ($PR_COUNT PRs, $HANDOVER_COUNT handover commits)" 2>&1) \
            || die "git commit failed: $commit_err"

        push_err=$(git push -u origin "$BRANCH" 2>&1) || die "git push failed: $push_err"

        if ! pr_url=$(gh pr create \
            --repo "$LUNA_BRAIN_REPO_FULL" \
            --base main \
            --head "$BRANCH" \
            --title "sweep(himmel): $SINCE to $TODAY ($PR_COUNT PRs, $HANDOVER_COUNT handover commits)" \
            --body "$(cat <<PRBODY
Auto-generated sweep of recent himmel + yotam_docs activity. Lands in \`00-Inbox/\` for triage per the LUNA \_CLAUDE.md weekly-process rule.

- Window: $SINCE to $TODAY (UTC)
- Merged PRs walked: $PR_COUNT
- Handover commits walked: $HANDOVER_COUNT

Generated by \`scripts/luna/sweep-himmel.sh\` (LUNA-5 Wedge A) in the himmel repo.
PRBODY
)" 2>&1); then
            # Rollback: delete the orphaned remote branch so a retry can
            # re-push cleanly without operator intervention.
            log "ERROR: gh pr create failed; rolling back remote branch $BRANCH"
            git push origin --delete "$BRANCH" >/dev/null 2>&1 || \
                log "WARN: rollback of remote branch $BRANCH failed — operator may need to clean it up manually"
            die "gh pr create failed: $pr_url"
        fi

        log "PR opened: $pr_url"
        ;;
    *)
        die "internal error: unknown MODE=$MODE"
        ;;
esac
