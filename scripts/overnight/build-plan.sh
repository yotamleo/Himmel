#!/usr/bin/env bash
# overnight/build-plan — emit a plan.md for /overnight-shift (HIMMEL-134).
#
# Queries jira for tickets matching the operator's filter, then prints a
# dispatch plan to stdout (or `--out` file). The plan is what the
# `/overnight-shift` slash command shows the operator before they
# confirm dispatch. The dispatch step itself is handled by Claude
# (subagent Task tool); this script only emits the plan.
#
# Output shape:
#   # Overnight shift plan — <timestamp>
#
#   Filter:
#     project=<KEY> status=<status> limit=<N> priority=<order>
#
#   Tickets (1..N):
#   1. <KEY> — <type> — <status> — <title>
#   2. ...
#
#   Dispatch tree:
#     - one worktree per ticket: <type-slug>/<key>-<title-slug>
#     - one Task subagent per ticket
#     - per-agent guardrails: existing PreToolUse hooks (no extra config)
#
# Exit codes:
#   0  plan written to stdout (or --out path)
#   1  usage / input error
#   2  jira CLI failed
#   3  no tickets matched (warn — operator can still proceed manually)
set -euo pipefail

PROJECT="${OVERNIGHT_PROJECT:-HIMMEL}"
STATUS="${OVERNIGHT_STATUS:-To Do,In Progress}"
LIMIT="${OVERNIGHT_LIMIT:-5}"
PRIORITY="${OVERNIGHT_PRIORITY:-key-desc}"
OUT_FILE=""
JIRA_CMD="${JIRA_CMD:-}"

usage() {
    cat <<'EOF'
Usage: build-plan.sh [--project KEY] [--status STATUS] [--limit N]
                     [--priority ORDER] [--out PATH]

Builds the dispatch plan for /overnight-shift by querying jira.

Optional:
  --project KEY      Jira project key. Default $OVERNIGHT_PROJECT or HIMMEL.
  --status STATUS    Comma-separated status filter passed to `jira list`.
                     Default: "To Do,In Progress".
  --limit N          Max tickets in the plan. Default 5.
  --priority ORDER   Documented sort order. v1 supports `key-desc` (default;
                     newest tickets first as a proxy for "most recently
                     filed"). Other values pass through unchanged for
                     forward-compat with a future priority-aware
                     jira CLI extension.
  --out PATH         Write plan to PATH in addition to stdout.

Environment overrides:
  JIRA_CMD           Override the jira plugin command (default:
                     `node $repo/scripts/jira/dist/index.js`). Tests
                     override this to inject canned ticket output.
  OVERNIGHT_PROJECT  Default project key.
  OVERNIGHT_STATUS   Default status filter.
  OVERNIGHT_LIMIT    Default limit.
  OVERNIGHT_PRIORITY Default priority order.
  WHERE_ARE_WE_LEDGER  Override the where-are-we ledger path (HIMMEL-517 L3
                     push-side provisioning; default
                     `$repo/.where-are-we/ledger.jsonl`). Tests seed a temp ledger.
  PROVISION_CMD      Override the provision CLI (default
                     `node $repo/scripts/where-are-we/provision.mjs`).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --project)  PROJECT="${2:-HIMMEL}"; shift 2 ;;
        --status)   STATUS="${2:-To Do,In Progress}"; shift 2 ;;
        --limit)    LIMIT="${2:-5}"; shift 2 ;;
        --priority) PRIORITY="${2:-key-desc}"; shift 2 ;;
        --out)      OUT_FILE="${2:-}"; shift 2 ;;
        -h|--help)  usage; exit 0 ;;
        *)          echo "ERR build-plan: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || [ "$LIMIT" -lt 1 ]; then
    echo "ERR build-plan: --limit must be a positive integer (got '$LIMIT')" >&2
    exit 1
fi

# Resolve the repo root unconditionally (HIMMEL-517): the where-are-we
# provisioning seams below need it even when JIRA_CMD is injected (tests do), so
# it must NOT be assigned only inside the `if [ -z "$JIRA_CMD" ]` block — under
# `set -u` an unset $repo_root would abort the script.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root=$(cd "$script_dir/../.." && pwd)

# Resolve jira CLI. Default: node $repo/scripts/jira/dist/index.js.
if [ -z "$JIRA_CMD" ]; then
    if [ -f "$repo_root/scripts/jira/dist/index.js" ] && command -v node >/dev/null 2>&1; then
        JIRA_CMD="node $repo_root/scripts/jira/dist/index.js"
    else
        echo "ERR build-plan: jira CLI not found at $repo_root/scripts/jira/dist/index.js and JIRA_CMD not set" >&2
        exit 2
    fi
fi

# where-are-we L3 push-side provisioning (HIMMEL-517): each non-epic ticket's
# subagent prompt is pre-loaded with that ticket's prior ledger slice. Both
# seams are overridable for hermetic tests (mirrors JIRA_CMD).
LEDGER="${WHERE_ARE_WE_LEDGER:-$repo_root/.where-are-we/ledger.jsonl}"
PROVISION_CMD="${PROVISION_CMD:-node $repo_root/scripts/where-are-we/provision.mjs}"

# Query. The jira CLI emits TSV: KEY \t TYPE \t STATUS \t TITLE.
if ! tickets_raw=$($JIRA_CMD list --project "$PROJECT" --status "$STATUS" --limit "$LIMIT" 2>/dev/null); then
    echo "ERR build-plan: jira list failed for project=$PROJECT status='$STATUS' limit=$LIMIT" >&2
    exit 2
fi

if [ -z "$tickets_raw" ]; then
    {
        echo "# Overnight shift plan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "_No tickets matched filter: project=$PROJECT status='$STATUS' limit=${LIMIT}_"
        echo
        echo "Operator: tweak filters or dispatch manually."
    } | tee ${OUT_FILE:+"$OUT_FILE"}
    exit 3
fi

# Build plan -----------------------------------------------------------

# Slugify a title (lowercase, non-alnum -> dash, trim, 30-char cap).
slugify() {
    local s
    s=$(printf '%s' "$1" \
        | tr '[:upper:]' '[:lower:]' \
        | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
        | cut -c1-30 \
        | sed -E 's/-+$//')
    # Empty / whitespace-only title would yield an empty slug, producing
    # a dangling `feat/HIMMEL-N-` worktree path that clean-garden.sh
    # rejects. Fall back to a literal `ticket` placeholder.
    printf '%s' "${s:-ticket}"
}

# Choose worktree type from ticket type. jira `Task` -> `feat`,
# `Story` -> `feat`, `Bug` -> `fix`, `Epic` is excluded from dispatch
# (epics shouldn't be implemented as a single worktree).
choose_type() {
    case "$1" in
        Bug)              echo "fix" ;;
        Task|Story|*)     echo "feat" ;;
    esac
}

plan=$(
    {
        echo "# Overnight shift plan — $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo
        echo "## Filter"
        echo
        echo "- project: \`$PROJECT\`"
        echo "- status: \`$STATUS\`"
        echo "- limit: \`$LIMIT\`"
        echo "- priority: \`$PRIORITY\` (v1: key-desc; jira CLI does not yet"
        echo "  expose priority field — see HIMMEL-146 for envification work)"
        echo
        echo "## Tickets"
        echo
        i=0
        while IFS=$'\t' read -r key type status title; do
            [ -z "$key" ] && continue
            # Epics: include in the plan as informational rows but mark
            # them as `skip` so the operator can decide.
            i=$((i+1))
            wtype=$(choose_type "$type")
            slug=$(slugify "$title")
            if [ "$type" = "Epic" ]; then
                echo "$i. **$key** — $type — $status — $title"
                echo "   - **SKIP** (epics are not directly dispatched)"
            else
                echo "$i. **$key** — $type — $status — $title"
                echo "   - worktree: \`$wtype/$key-$slug\`"
                echo "   - subagent prompt: \"Read $key spec via jira plugin, implement per ticket, run tests, commit + push + open PR\""
                # L3 push-side provisioning (HIMMEL-517): embed this ticket's prior
                # ledger slice. Fail-open — no node/ledger/item → empty → block
                # skipped → plan unchanged (the `2>/dev/null || true` + empty-test
                # IS the guard; no separate node-presence check needed).
                slice=$($PROVISION_CMD slice --ledger "$LEDGER" --for "$key" 2>/dev/null || true)
                if [ -n "$slice" ]; then
                    echo "   - prior ledger state:"
                    printf '%s\n' "$slice" | sed 's/^/     /'
                fi
            fi
        done <<< "$tickets_raw"
        echo
        echo "## Dispatch tree"
        echo
        echo "- One worktree per non-epic ticket (created via \`scripts/worktree.sh\`)."
        echo "- One Task subagent per ticket, running in parallel."
        echo "- Per-agent guardrails: existing PreToolUse hooks"
        echo "  (block-edit-on-main, block-read-secrets, block-mcp-when-plugin-exists)."
        echo
        echo "## After all subagents return"
        echo
        echo "- Write the consolidated morning report (HIMMEL-258): one row per"
        echo "  ticket (ticket, branch, PR, status, outcome, decision) piped into"
        echo "  \`scripts/overnight/morning-report.sh\` — decisions-needed grouped"
        echo "  at top; output path resolved via \`handover_root\`."
        echo "- Run \`/handover-flush\` to reconcile state across worktrees."
        echo "- Operator reads the ONE report, then drills into PRs"
        echo "  (\`/pr-check\`) + merges — no per-ticket discovery."
    }
)

if [ -n "$OUT_FILE" ]; then
    printf '%s\n' "$plan" > "$OUT_FILE"
fi
printf '%s\n' "$plan"
exit 0
