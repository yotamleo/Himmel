#!/usr/bin/env bash
# handover/pr-open — open or update the PR for the current handover branch.
#
# HIMMEL-141 (HIMMEL-59 v2 child). Pairs with auto-commit.sh:
# - auto-commit.sh creates the handover/<TICKET>-<slug> branch + pushes.
# - pr-open.sh opens a PR with a structured body (## Summary, ## Files
#   changed, ## Ticket), idempotent across re-runs. Subsequent pushes
#   trigger `gh pr edit --body` when the body needs refreshing.
#
# Body shape:
#   ## Summary
#   <one to two lines pulled from the Jira ticket (--short) when available>
#
#   ## Files changed
#   <git diff --name-status base..HEAD, formatted as a bullet list>
#
#   ## Ticket
#   - HIMMEL-N: <jira browse URL>
#
# Failure modes (per spec):
# - `gh pr create` fails (no auth, no remote, no permissions): warn,
#   exit 0. The branch is still pushed; an operator can open the PR
#   later. This is a "best-effort wedge", not load-bearing.
# - branch-delete-fails (cosmetic, worktree-held): ignored downstream
#   in pr-merge.sh — not relevant here.
#
# Exit codes:
#   0  PR opened, updated, or skipped (best-effort)
#   1  usage error
#   2  required tool missing
#   3  not in a handover branch (refuses; misuse)
#
# Environment overrides:
#   FORGE / GH_CMD / BITBUCKET_CMD   Forge-seam overrides (HIMMEL-326). The PR
#                ops route through scripts/lib/forge.sh, so this works on GitHub
#                and Bitbucket Cloud alike. The github backend still honors the
#                GH_CMD test seam (tests set GH_CMD=<stub> to capture calls).
#   JIRA_CMD     Default `node $repo/scripts/jira/dist/index.js`.
#   HANDOVER_PR_AUTO=0  Skip PR open/update entirely (env-gated opt-out).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Forge-dispatch seam: forge_pr_find_open / forge_pr_create / forge_pr_set_body
# route to the github or bitbucket backend per the repo's origin (HIMMEL-326).
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

JIRA_CMD="${JIRA_CMD:-}"
DRY_RUN=0
BASE_REF="${HANDOVER_PR_BASE:-main}"

usage() {
    cat <<'EOF'
Usage: pr-open.sh [--dry-run] [--base <branch>]

Opens or updates the PR for the current handover branch in the cwd's
git repo. Idempotent across re-runs.

Refuses (rc=3) if HEAD is not on a `handover/*` branch — the script
is scoped to the auto-commit branched flow.

Optional:
  --dry-run         Print intended gh calls; don't invoke them.
  --base <branch>   Compare base for "Files changed" + PR target.
                    Default: $HANDOVER_PR_BASE or `main`.

Environment:
  GH_CMD                 Default `gh` (tests override with `echo`).
  HANDOVER_PR_AUTO=0     Skip entirely (no-op exit 0).
  HANDOVER_PR_BASE       Base ref for `Files changed` + PR --base.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)   DRY_RUN=1; shift ;;
        --base)      BASE_REF="${2:-main}"; shift 2 ;;
        -h|--help)   usage; exit 0 ;;
        *)           echo "ERR pr-open: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if [ "${HANDOVER_PR_AUTO:-1}" = "0" ]; then
    echo "pr-open: HANDOVER_PR_AUTO=0 — skipping."
    exit 0
fi

if ! command -v git >/dev/null 2>&1; then
    echo "ERR pr-open: required tool 'git' not on PATH" >&2
    exit 2
fi

repo_root=$(git rev-parse --show-toplevel 2>/dev/null || true)
if [ -z "$repo_root" ]; then
    echo "ERR pr-open: not inside a git repo" >&2
    exit 2
fi

current_branch=$(git -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
case "$current_branch" in
    handover/*) ;;
    *)
        echo "ERR pr-open: not on a handover/* branch (current: $current_branch). Refusing." >&2
        exit 3
        ;;
esac

# Extract ticket from branch name. Pattern: handover/<TICKET>-<slug>
# or handover/session-YYYY-MM-DD. Best-effort — falls through cleanly
# when the branch is a session/* form.
ticket=""
if [[ "$current_branch" =~ handover/([A-Z][A-Z0-9]+-[0-9]+) ]]; then
    ticket="${BASH_REMATCH[1]}"
fi

# Resolve jira CLI (best-effort). When not found we just omit the
# ticket-title line from the Summary — the body still renders.
if [ -z "$JIRA_CMD" ]; then
    if [ -f "$repo_root/scripts/jira/dist/index.js" ] && command -v node >/dev/null 2>&1; then
        JIRA_CMD="node $repo_root/scripts/jira/dist/index.js"
    fi
fi

ticket_title=""
ticket_summary=""
if [ -n "$ticket" ] && [ -n "$JIRA_CMD" ]; then
    # `jira get HIMMEL-N --short` prints "<KEY>\t<Type>\t<Status>\t<Title>"
    # on a single line; we want the trailing title field.
    if jira_line=$($JIRA_CMD get "$ticket" --short 2>/dev/null); then
        ticket_title=$(printf '%s' "$jira_line" | awk -F'\t' '{print $NF}')
    fi
    if [ -z "$ticket_summary" ]; then
        ticket_summary="$ticket_title"
    fi
fi

# Body construction ----------------------------------------------------------

# Title: handover(scope): HIMMEL-N <subject>. When no ticket, default to
# the branch name as the subject.
if [ -n "$ticket" ]; then
    if [ -n "$ticket_title" ]; then
        title="handover: ${ticket} ${ticket_title}"
    else
        title="handover: ${ticket}"
    fi
else
    title="handover: ${current_branch#handover/}"
fi

# Files changed: git diff --name-status base..HEAD. If base is missing
# (fresh repo) fall back to listing all tracked files.
files_block=""
if git -C "$repo_root" rev-parse --verify --quiet "$BASE_REF" >/dev/null 2>&1; then
    files_raw=$(git -C "$repo_root" diff --name-status "$BASE_REF"..HEAD 2>/dev/null || true)
elif git -C "$repo_root" rev-parse --verify --quiet "origin/$BASE_REF" >/dev/null 2>&1; then
    files_raw=$(git -C "$repo_root" diff --name-status "origin/$BASE_REF"..HEAD 2>/dev/null || true)
else
    files_raw=$(git -C "$repo_root" diff --name-status HEAD~1..HEAD 2>/dev/null || true)
fi
if [ -n "$files_raw" ]; then
    files_block=$(printf '%s\n' "$files_raw" | awk '{printf "- `%s` (%s)\n", $2, $1}')
else
    files_block="_no files changed (empty diff vs $BASE_REF)_"
fi

# Ticket section
if [ -n "$ticket" ]; then
    project_key="${ticket%%-*}"
    project_key_lc=$(printf '%s' "$project_key" | tr '[:upper:]' '[:lower:]')
    ticket_block="- ${ticket}: https://${project_key_lc}.atlassian.net/browse/${ticket}"
else
    ticket_block="_no ticket — session branch_"
fi

# Summary line — short ticket title when known.
if [ -n "$ticket_summary" ]; then
    summary_block="${ticket_summary}"
else
    summary_block="Handover mutation on \`${current_branch}\`."
fi

body=$(cat <<EOF
## Summary

${summary_block}

## Files changed

${files_block}

## Ticket

${ticket_block}

---

🤖 Opened by \`scripts/handover/pr-open.sh\` (HIMMEL-141).
EOF
)

# Idempotent open/update ------------------------------------------------------

# Determining the forge needs an origin remote. If we can't, skip best-effort:
# the branch is still pushed, so an operator can open the PR later — this is the
# documented "best-effort wedge", not a load-bearing step.
if ! forge=$(forge_detect 2>/dev/null); then
    echo "pr-open: cannot determine forge (need a github.com or bitbucket.org origin) — skipping (best-effort)" >&2
    exit 0
fi

# Detect an existing open PR via the forge seam. A forge/CLI failure here is
# tolerated (treated as "no PR found") — the create attempt below is itself
# best-effort, so an unusable CLI still exits 0 with the branch pushed.
existing_pr=""
if existing_pr=$(forge_pr_find_open "$current_branch" 2>/dev/null); then
    :
else
    existing_pr=""
fi

if [ "$DRY_RUN" -eq 1 ]; then
    if [ -z "$existing_pr" ]; then
        echo "DRY pr-open: would create a PR on $forge (base $BASE_REF, head $current_branch)"
    else
        echo "DRY pr-open: would update the body of PR #$existing_pr on $forge"
    fi
    echo "--- body ---"
    printf '%s\n' "$body"
    echo "--- /body ---"
    exit 0
fi

if [ -z "$existing_pr" ]; then
    if ! out=$(forge_pr_create "$title" "$body" "$BASE_REF" "$current_branch" 2>&1); then
        echo "pr-open: PR create failed (best-effort, branch is still pushed):" >&2
        printf '%s\n' "$out" >&2
        exit 0
    fi
    echo "pr-open: opened $out"
else
    if ! out=$(forge_pr_set_body "$existing_pr" "$title" "$body" 2>&1); then
        echo "pr-open: PR body update failed (best-effort, PR remains as-is):" >&2
        printf '%s\n' "$out" >&2
        exit 0
    fi
    echo "pr-open: updated PR #$existing_pr"
fi
exit 0
