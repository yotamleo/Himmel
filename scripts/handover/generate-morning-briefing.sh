#!/usr/bin/env bash
# handover/generate-morning-briefing — overnight session summary generator.
#
# HIMMEL-135 (HIMMEL-32 child). Replaces the hand-written
# `overnight-summary-YYYY-MM-DD.md` pattern with a generator. Pulls
# from three sources and templates them into the established schema:
#
#   1. git commits since a marker SHA (--since SHA, default: last tag
#      or HEAD~50).
#   2. merged PRs from gh (--search merged:>DATE).
#   3. Done tickets from jira list (best-effort; jira CLI doesn't yet
#      expose --updated-since, so we list all Done and cross-reference
#      against the commit/PR set).
#
# Output schema mirrors yotam_docs/handovers/yotam/overnight-summary-2026-05-24.md:
#   - Title with the date.
#   - `## Code shipped (N PRs merged to main)` table.
#   - `## Commits` raw `git log --oneline` listing.
#   - `## Tickets transitioned to Done` (cross-referenced).
#
# Resolves output path via the HIMMEL-118 single-root resolver:
#   - Mode B (HANDOVER_DIR set) → $HANDOVER_DIR/overnight-summary-$(date +%F).md
#   - Mode A (inline) → $repo/handovers/overnight-summary-$(date +%F).md
#
# Exit codes:
#   0  briefing written (stdout + --out path)
#   1  usage / input error
#   2  required tool missing or env unusable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

GH_CMD="${GH_CMD:-gh}"
GIT_CMD="${GIT_CMD:-git}"
JIRA_CMD="${JIRA_CMD:-}"
SINCE_SHA=""
SINCE_DATE=""
OUT_FILE=""
DRY_RUN=0
JIRA_LIMIT=50

usage() {
    cat <<'EOF'
Usage: generate-morning-briefing.sh [--since SHA] [--since-date YYYY-MM-DD]
                                    [--out PATH] [--jira-limit N] [--dry-run]

Generates an overnight summary by pulling git/gh/jira state since a
marker and templating it into the established schema.

Optional:
  --since SHA              Marker commit. Default: last tag (`git
                           describe --tags --abbrev=0`) or `HEAD~50`
                           if no tags. Used for git log + cross-ref.
  --since-date YYYY-MM-DD  Date filter for `gh pr list --search
                           'merged:>DATE'`. Default: today UTC.
  --out PATH               Output path. Default:
                           $HANDOVER_DIR/overnight-summary-$(date -u +%F).md
                           (Mode B) or $repo/handovers/... (Mode A).
  --jira-limit N           Max Done tickets to pull. Default 50.
  --dry-run                Print the briefing to stdout; touch no files.

Environment overrides:
  GH_CMD / GIT_CMD / JIRA_CMD   Test overrides.
  HANDOVER_DIR                  External handover root (Mode B).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)       SINCE_SHA="${2:-}"; shift 2 ;;
        --since-date)  SINCE_DATE="${2:-}"; shift 2 ;;
        --out)         OUT_FILE="${2:-}"; shift 2 ;;
        --jira-limit)  JIRA_LIMIT="${2:-50}"; shift 2 ;;
        --dry-run)     DRY_RUN=1; shift ;;
        -h|--help)     usage; exit 0 ;;
        *)             echo "ERR briefing: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! command -v "${GIT_CMD%% *}" >/dev/null 2>&1; then
    echo "ERR briefing: required tool 'git' not on PATH" >&2
    exit 2
fi

repo_root=$($GIT_CMD rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    echo "ERR briefing: not inside a git repo" >&2
    exit 2
fi

# Resolve --since SHA when not passed.
if [ -z "$SINCE_SHA" ]; then
    if last_tag=$($GIT_CMD -C "$repo_root" describe --tags --abbrev=0 2>/dev/null); then
        SINCE_SHA="$last_tag"
    else
        SINCE_SHA="HEAD~50"
    fi
fi

# Resolve --since-date when not passed.
[ -z "$SINCE_DATE" ] && SINCE_DATE=$(date -u +%F)

# Resolve --out when not passed.
if [ -z "$OUT_FILE" ]; then
    # _ensure: this script WRITES the briefing to OUT_FILE, so we need
    # the Mode A inline dir to exist. Pure handover_root returns rc=2 if
    # it doesn't yet, which would force the bare-fallback path below to
    # fire even when Mode A is correctly configured but un-bootstrapped.
    # Stderr is NOT suppressed: a broken HANDOVER_DIR (Mode B typo) must
    # surface its diagnostic so the operator notices the silent fallback
    # to <repo>/handovers/ that would otherwise write to the wrong root.
    if root=$(handover_root_ensure); then
        OUT_FILE="$root/overnight-summary-$(date -u +%F).md"
    else
        echo "WARNING: handover_root_ensure failed — falling back to $repo_root/handovers/" >&2
        OUT_FILE="$repo_root/handovers/overnight-summary-$(date -u +%F).md"
    fi
fi

# Resolve jira CLI (best-effort; absence is non-fatal — briefing still
# generates with the gh+git portions).
if [ -z "$JIRA_CMD" ]; then
    if [ -f "$repo_root/scripts/jira/dist/index.js" ] && command -v node >/dev/null 2>&1; then
        JIRA_CMD="node $repo_root/scripts/jira/dist/index.js"
    fi
fi

# Gather sections -------------------------------------------------------

# Commits since SINCE_SHA.
if commits_raw=$($GIT_CMD -C "$repo_root" log --oneline "${SINCE_SHA}..HEAD" 2>/dev/null); then
    :
else
    commits_raw=""
fi
commit_count=$(printf '%s\n' "$commits_raw" | grep -c . || true)

# Extract HIMMEL-N / LUNA-N ticket keys from commit messages.
mapfile -t ticket_keys < <(printf '%s\n' "$commits_raw" \
    | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' \
    | sort -u)

# Merged PRs via gh (best-effort).
pr_table=""
pr_count=0
if command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    # gh pr list --json bundles number/title/mergedAt/mergeCommit; filter
    # by `merged:>SINCE_DATE` via --search.
    if pr_json=$($GH_CMD pr list --state merged --search "merged:>$SINCE_DATE" --limit 100 --json number,title,mergedAt 2>/dev/null); then
        # Parse with jq when available; otherwise emit a simple list.
        if command -v jq >/dev/null 2>&1; then
            pr_table=$(printf '%s' "$pr_json" | jq -r '
                .[] | "| #\(.number) | \(.title | capture("(?<key>[A-Z][A-Z0-9]+-[0-9]+)").key // "—") | \(.title | sub("^[a-z]+(\\([^)]+\\))?:[[:space:]]*"; "")) |"' 2>/dev/null || true)
            pr_count=$(printf '%s' "$pr_json" | jq 'length' 2>/dev/null || echo 0)
        else
            pr_table=$(printf '%s' "$pr_json" \
                | grep -oE '"number":[0-9]+' \
                | awk -F':' '{printf "| #%s | — | (jq missing) |\n", $2}')
            pr_count=$(printf '%s\n' "$pr_table" | grep -c . || true)
        fi
    fi
fi

# Done tickets via jira (best-effort).
done_block=""
if [ -n "$JIRA_CMD" ]; then
    if done_raw=$($JIRA_CMD list --status Done --limit "$JIRA_LIMIT" 2>/dev/null); then
        # Cross-ref: only include Done tickets that appeared in commits.
        if [ ${#ticket_keys[@]} -gt 0 ]; then
            done_block=$(printf '%s\n' "$done_raw" | awk -F'\t' -v keys="$(IFS='|'; echo "${ticket_keys[*]}")" '
                BEGIN { split(keys, k, "|"); for (i in k) want[k[i]]=1 }
                want[$1] { printf "- %s — %s — %s\n", $1, $2, $4 }
            ')
        fi
    fi
fi

# Template --------------------------------------------------------------

briefing=$(
    cat <<EOF
# Overnight + Day Session Summary — $(date -u +%F)

> Auto-generated by \`scripts/handover/generate-morning-briefing.sh\`
> (HIMMEL-135). Source markers: \`--since $SINCE_SHA\`,
> \`--since-date $SINCE_DATE\`.

## Code shipped ($pr_count PRs merged to main)

EOF
    if [ -n "$pr_table" ]; then
        printf '| PR | Ticket | Summary |\n|---|---|---|\n%s\n' "$pr_table"
    else
        printf '_No merged PRs found via gh since %s. Check gh auth + filter._\n' "$SINCE_DATE"
    fi
    printf '\n## Commits (%s since %s)\n\n' "$commit_count" "$SINCE_SHA"
    if [ -n "$commits_raw" ]; then
        # shellcheck disable=SC2016  # backticks here are markdown literal, not subshell
        printf '```\n%s\n```\n' "$commits_raw"
    else
        printf '_No commits found since %s._\n' "$SINCE_SHA"
    fi
    printf '\n## Tickets transitioned to Done (cross-referenced against commits)\n\n'
    if [ -n "$done_block" ]; then
        printf '%s\n' "$done_block"
    elif [ ${#ticket_keys[@]} -eq 0 ]; then
        printf '_No ticket keys detected in commit messages._\n'
    else
        printf '_Ticket keys detected in commits: %s. jira CLI unavailable or no Done matches._\n' "$(IFS=,; echo "${ticket_keys[*]}")"
    fi
    printf '\n## Items for operator review\n\n'
    # shellcheck disable=SC2016  # markdown literal backticks, not subshells
    printf -- '- Verify the PR table is complete (gh search window: `merged:>%s`).\n' "$SINCE_DATE"
    printf -- '- Cross-check Jira Done transitions against the ticket keys list.\n'
    # shellcheck disable=SC2016  # markdown literal backticks, not subshells
    printf -- '- Schedule next session via `scripts/handover/arm-resume.sh` or `/context-hop`.\n'
)

# Write / print --------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY briefing: would write to $OUT_FILE"
    echo "DRY briefing: body:"
    printf '%s\n' "$briefing"
    exit 0
fi

mkdir -p "$(dirname "$OUT_FILE")"
printf '%s\n' "$briefing" > "$OUT_FILE"
echo "briefing: wrote $OUT_FILE ($pr_count PRs, $commit_count commits, ${#ticket_keys[@]} ticket keys)"
exit 0
