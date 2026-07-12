#!/usr/bin/env bash
# handover/generate-morning-briefing — daily 🌅 Morning Report generator.
#
# HIMMEL-135 (core) + HIMMEL-574 (morning-report schema). Templates live
# git/gh/jira/worktree state into the curated "🌅 Morning Report" schema and
# writes a dated report to the handover bucket — at ~zero Claude tokens by
# default. Sections:
#
#   ## TL;DR             — derived counts (heuristic; --llm enriches)
#   ## ✅ Completed       — merged PRs (gh) + commits + Done cross-ref
#   ## 🔴 In-flight WIP   — jira In Progress correlated to worktrees/open-PRs
#   ## 🧹 Stale worktrees — worktrees on MERGED-PR branches
#   ## 📋 Backlog         — flat To-Do list (--llm clusters by theme)
#   ## 📄 Docs drift     — mapped sources changed without their docs (HIMMEL-587)
#   ## Suggested order    — heuristic ordering (--llm enriches)
#
# Default run costs ~no Claude tokens. `--llm` enriches TL;DR + Suggested
# order + Backlog theme-clustering via a bounded interactive claude turn
# (the interactive form with stdin closed, NOT the headless -p/--print/--bg
# forms; stays on Max quota, passes the no-headless gate), failing open
# per-block to the deterministic heuristic.
#
# Output path via the HIMMEL-118 single-root resolver:
#   - Mode B (HANDOVER_DIR set) → $HANDOVER_DIR/morning-report-$(date +%F).md
#   - Mode A (inline) → $repo/handovers/morning-report-$(date +%F).md
#
# Exit codes:
#   0  report written (stdout + --out path)
#   1  usage / input error
#   2  required tool missing or env unusable
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"
# forge_detect (HIMMEL-326): the date-ranged merged-PR query below is a
# GitHub-specific `gh pr list --search` (no forge-seam verb covers a date range),
# so it's gated to a github origin — as are the HIMMEL-574 PR-correlation calls.
# shellcheck source=../lib/forge.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/forge.sh"

GH_CMD="${GH_CMD:-gh}"
GIT_CMD="${GIT_CMD:-git}"
JIRA_CMD="${JIRA_CMD:-}"
CLAUDE_CMD="${CLAUDE_CMD:-claude}"
SINCE_SHA=""
SINCE_DATE=""
OUT_FILE=""
DRY_RUN=0
JIRA_LIMIT=200
LLM=0
LLM_MODEL="sonnet"
BACKLOG_LIMIT=40

usage() {
    cat <<'EOF'
Usage: generate-morning-briefing.sh [--since SHA] [--since-date YYYY-MM-DD]
                                    [--out PATH] [--jira-limit N]
                                    [--backlog-limit N] [--llm]
                                    [--llm-model MODEL] [--dry-run]

Generates the dated 🌅 Morning Report by templating live git/gh/jira/worktree
state into the curated schema. Default run costs ~no Claude tokens.

Optional:
  --since SHA              Marker commit. Default: last tag (`git
                           describe --tags --abbrev=0`) or `HEAD~50`.
  --since-date YYYY-MM-DD  Date filter for `gh pr list --search
                           'merged:>DATE'`. Default: today LOCAL (date +%F).
  --out PATH               Output path. Default:
                           $HANDOVER_DIR/morning-report-$(date +%F).md
                           (Mode B) or $repo/handovers/... (Mode A).
  --jira-limit N           Max rows per jira status query. Default 200.
  --backlog-limit N        Max To-Do rows rendered in Backlog. Default 40.
  --llm                    Enrich TL;DR + Suggested order + Backlog clustering
                           via a bounded `claude` turn (default OFF). Also
                           enabled by MORNING_REPORT_LLM=1.
  --llm-model MODEL        Model for --llm. Default `sonnet`.
  --dry-run                Print the report to stdout; touch no files.

Environment overrides:
  GH_CMD / GIT_CMD / JIRA_CMD / CLAUDE_CMD   Test overrides.
  HANDOVER_DIR                               External handover root (Mode B).
  MORNING_REPORT_LLM=1                        Enable --llm.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --since)         SINCE_SHA="${2:-}"; shift 2 ;;
        --since-date)    SINCE_DATE="${2:-}"; shift 2 ;;
        --out)           OUT_FILE="${2:-}"; shift 2 ;;
        --jira-limit)    JIRA_LIMIT="${2:-200}"; shift 2 ;;
        --backlog-limit) BACKLOG_LIMIT="${2:-40}"; shift 2 ;;
        --llm)           LLM=1; shift ;;
        --llm-model)     LLM_MODEL="${2:-sonnet}"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *)               echo "ERR briefing: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

[ "${MORNING_REPORT_LLM:-0}" = "1" ] && LLM=1

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

# LOCAL day, computed ONCE (HIMMEL-574; was date -u). Reused for the
# --since-date default, the output filename, and the header so a run spanning
# local midnight can't put one date in the filename and another in the header.
today=$(date +%F)

# Resolve --since-date when not passed — LOCAL day.
[ -z "$SINCE_DATE" ] && SINCE_DATE="$today"

# Resolve --out when not passed.
if [ -z "$OUT_FILE" ]; then
    # _ensure: this script WRITES the report to OUT_FILE, so we need the Mode A
    # inline dir to exist. Stderr is NOT suppressed: a broken HANDOVER_DIR (Mode
    # B typo) must surface so the operator notices the silent fallback to
    # <repo>/handovers/ that would otherwise write to the wrong root.
    if root=$(handover_root_ensure); then
        OUT_FILE="$root/morning-report-$today.md"
    else
        echo "WARNING: handover_root_ensure failed — falling back to $repo_root/handovers/" >&2
        OUT_FILE="$repo_root/handovers/morning-report-$today.md"
    fi
fi

# Resolve jira CLI (best-effort; absence is non-fatal).
if [ -z "$JIRA_CMD" ]; then
    if [ -f "$repo_root/scripts/jira/dist/index.js" ] && command -v node >/dev/null 2>&1; then
        JIRA_CMD="node $repo_root/scripts/jira/dist/index.js"
    fi
fi

briefing_forge=$(forge_detect 2>/dev/null || true)

# Docs drift (HIMMEL-587) — advisory; gated by HIMMEL_DOC_FRESHNESS morning leg.
# Source the clone's .env so the morning leg activates when himmel turned it on
# there (mirrors inject-where-are-we.sh; the cadence/skill may not export it).
if [ -f "$repo_root/.env" ]; then
    # shellcheck source=../lib/load-dotenv.sh
    # shellcheck disable=SC1091
    . "$SCRIPT_DIR/../lib/load-dotenv.sh"
    load_dotenv --root "$repo_root" HIMMEL_DOC_FRESHNESS || true
fi
# shellcheck source=../lib/doc-freshness.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/doc-freshness.sh"
docs_drift=""
if df_leg_active morning; then
    docs_drift="$(df_detect "${SINCE_SHA}..HEAD" "" "$repo_root" 2>/dev/null || true)"
fi

# Reachability flags — distinguish "tool returned nothing" from "tool call
# FAILED" so a jira/gh outage doesn't render as a confident all-clear (a 0 must
# read as "unknown", not "none"). jira_ok starts 0 when the CLI isn't even
# resolved; both flip to 0 on a real query failure below.
jira_ok=1
[ -z "$JIRA_CMD" ] && jira_ok=0
pr_map_ok=1

# Gather sections (all PARENT-scope; the template heredoc only prints these) ----

# Commits since SINCE_SHA.
if commits_raw=$($GIT_CMD -C "$repo_root" log --oneline "${SINCE_SHA}..HEAD" 2>/dev/null); then
    :
else
    commits_raw=""
fi
commit_count=$(printf '%s\n' "$commits_raw" | grep -c . || true)

# Extract HIMMEL-N / LUNA-N ticket keys from commit messages.
# bash 3.2-safe (macOS): no mapfile.
ticket_keys=()
while IFS= read -r _line; do ticket_keys+=("$_line"); done < <(printf '%s\n' "$commits_raw" \
    | grep -oE '[A-Z][A-Z0-9]+-[0-9]+' \
    | sort -u)

# Merged PRs via gh (best-effort) — GitHub only (date-ranged `--search`).
pr_table=""
pr_count=0
if [ "$briefing_forge" = "github" ] && command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    if pr_json=$($GH_CMD pr list --state merged --search "merged:>$SINCE_DATE" --limit 100 --json number,title,mergedAt 2>/dev/null); then
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

# Done tickets via jira (best-effort) — cross-referenced against commit keys.
done_block=""
if [ -n "$JIRA_CMD" ]; then
    if done_raw=$($JIRA_CMD list --status Done --limit "$JIRA_LIMIT" 2>/dev/null); then
        if [ ${#ticket_keys[@]} -gt 0 ]; then
            done_block=$(printf '%s\n' "$done_raw" | awk -F'\t' -v keys="$(IFS='|'; echo "${ticket_keys[*]}")" '
                BEGIN { split(keys, k, "|"); for (i in k) want[k[i]]=1 }
                want[$1] { printf "- %s — %s — %s\n", $1, $2, $4 }
            ')
        fi
    else
        jira_ok=0
        echo "WARNING: briefing: jira 'Done' query failed — counts may be incomplete" >&2
    fi
fi

# All-state PR map (single call; github only) — reused by In-flight + Stale.
# Lines: STATE<TAB>headRefName<TAB>number. The 500 cap is a generous safety
# bound on total PRs scanned for branch correlation (a different axis from the
# jira-limit knob).
pr_map=""
if [ "$briefing_forge" = "github" ] && command -v "${GH_CMD%% *}" >/dev/null 2>&1; then
    if all_json=$($GH_CMD pr list --state all --limit 500 --json number,state,headRefName,title 2>/dev/null); then
        if command -v jq >/dev/null 2>&1; then
            pr_map=$(printf '%s' "$all_json" | jq -r '.[] | "\(.state)\t\(.headRefName)\t\(.number)"' 2>/dev/null || true)
        fi
    else
        pr_map_ok=0
        echo "WARNING: briefing: gh PR-state query failed — stale + PR correlation skipped" >&2
    fi
fi

# Worktree branches (porcelain → "branch refs/heads/<name>" lines).
wt_porcelain=$($GIT_CMD -C "$repo_root" worktree list --porcelain 2>/dev/null || true)
wt_branches=$(printf '%s\n' "$wt_porcelain" | awk '/^branch /{sub("refs/heads/","",$2); print $2}')

# In-Progress tickets.
inprogress_raw=""
if [ -n "$JIRA_CMD" ]; then
    if ! inprogress_raw=$($JIRA_CMD list --status 'In Progress' --limit "$JIRA_LIMIT" 2>/dev/null); then
        jira_ok=0; inprogress_raw=""
        echo "WARNING: briefing: jira 'In Progress' query failed — counts may be incomplete" >&2
    fi
fi

# Stale worktrees: branches whose PR is MERGED. Exclude main + current checkout.
# "no PR yet" is active WIP, NOT stale.
cur_branch=$($GIT_CMD -C "$repo_root" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
stale_rows=""
while IFS= read -r br; do
    [ -z "$br" ] && continue
    [ "$br" = "main" ] && continue
    [ "$br" = "$cur_branch" ] && continue
    merged_pr=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$br" 'tolower($2)==tolower(b) && $1=="MERGED"{print $3; exit}')
    if [ -n "$merged_pr" ]; then
        stale_rows="$stale_rows| \`$br\` | PR #$merged_pr MERGED | prune |"$'\n'
    fi
done <<EOF_WT
$wt_branches
EOF_WT

# Backlog (To-Do) tickets.
backlog_raw=""
if [ -n "$JIRA_CMD" ]; then
    if ! backlog_raw=$($JIRA_CMD list --status 'To Do' --limit "$JIRA_LIMIT" 2>/dev/null); then
        jira_ok=0; backlog_raw=""
        echo "WARNING: briefing: jira 'To Do' query failed — counts may be incomplete" >&2
    fi
fi
backlog_rows=$(printf '%s\n' "$backlog_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{print}')
backlog_total=$(printf '%s\n' "$backlog_rows" | grep -c . || true)

# Deterministic judgment strings -----------------------------------------------

inprog_count=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{c++} END{print c+0}')
stale_count=$(printf '%s\n' "$stale_rows" | grep -c . || true)
done_count=$(printf '%s\n' "$done_block" | grep -c . || true)

tldr_default="**${inprog_count}** in-flight · **${stale_count}** stale worktrees · **${done_count}** Done (cross-ref'd) · **${backlog_total}** backlog"

order_default=$(
    n=1
    [ "$stale_count" -gt 0 ] && { printf '%d. Prune %s stale worktree(s) (/clean).\n' "$n" "$stale_count"; n=$((n+1)); }
    open_prs=$(printf '%s\n' "$pr_map" | awk -F'\t' '$1=="OPEN"{c++} END{print c+0}')
    [ "$open_prs" -gt 0 ] && { printf '%d. Review/merge %s open PR(s) (/pr-check).\n' "$n" "$open_prs"; n=$((n+1)); }
    [ "$inprog_count" -gt 0 ] && { printf '%d. Advance %s In-Progress ticket(s).\n' "$n" "$inprog_count"; n=$((n+1)); }
    [ "$backlog_total" -gt 0 ] && printf '%d. Pull from the %s-item backlog.\n' "$n" "$backlog_total"
    :   # force final exit 0 — a trailing short-circuit && would propagate rc1 to
        # the assignment and abort under set -e (empty backlog / jira down).
)
[ -z "$order_default" ] && order_default="_Nothing in flight — pick from the backlog._"

# --llm enrichment (opt-in, fail-open per block) -------------------------------

tldr_final="$tldr_default"
order_final="$order_default"
backlog_block_final=""   # empty => template uses the deterministic backlog render

# extract_block RAW NAME → text between <<<NAME_BEGIN>>>/<<<NAME_END>>> (exclusive).
extract_block() {
    printf '%s\n' "$1" | sed -n "/<<<$2_BEGIN>>>/,/<<<$2_END>>>/p" | sed '1d;$d'
}

if [ "$LLM" -eq 1 ]; then
    llm_prompt="You are enriching a daily engineering Morning Report. Below is the
deterministic report body. Produce ONLY three blocks, each wrapped EXACTLY in
its sentinel lines and nothing else outside them:

<<<TLDR_BEGIN>>>
3-5 bullet TL;DR of the most important state
<<<TLDR_END>>>
<<<ORDER_BEGIN>>>
a numbered suggested order of what to do next
<<<ORDER_END>>>
<<<BACKLOG_BEGIN>>>
the backlog tickets clustered into 3-6 named themes (markdown)
<<<BACKLOG_END>>>

--- REPORT BODY ---
In-flight: ${inprog_count}; stale: ${stale_count}; Done: ${done_count}; backlog: ${backlog_total}
Backlog tickets:
${backlog_rows}
In-Progress:
${inprogress_raw}"
    if llm_out=$($CLAUDE_CMD --model "$LLM_MODEL" "$llm_prompt" </dev/null 2>/dev/null); then
        t=$(extract_block "$llm_out" TLDR);    if [ -n "$t" ]; then tldr_final="$t"; else echo "WARNING: --llm TLDR block empty; using heuristic" >&2; fi
        o=$(extract_block "$llm_out" ORDER);   if [ -n "$o" ]; then order_final="$o"; else echo "WARNING: --llm ORDER block empty; using heuristic" >&2; fi
        b=$(extract_block "$llm_out" BACKLOG); if [ -n "$b" ]; then backlog_block_final="$b"; fi
    else
        echo "WARNING: --llm: '$CLAUDE_CMD' failed; using deterministic heuristics" >&2
    fi
fi

# Template ---------------------------------------------------------------------

briefing=$(
    cat <<EOF
# 🌅 Morning Report — $today

> Auto-generated by \`scripts/handover/generate-morning-briefing.sh\`
> (HIMMEL-135/574). Source markers: \`--since $SINCE_SHA\`,
> \`--since-date $SINCE_DATE\`. Point-in-time snapshot — continuity is a session's job.

EOF
    # Reachability banner — when a tool call FAILED (not just returned nothing),
    # the counts below are unknown, not zero. Surface it so a 0 isn't read as "none".
    if [ "$jira_ok" -eq 0 ] || [ "$pr_map_ok" -eq 0 ]; then
        printf '> ⚠️ '
        [ "$jira_ok" -eq 0 ] && printf 'jira unavailable — In-flight / Backlog / Done counts are INCOMPLETE. '
        [ "$pr_map_ok" -eq 0 ] && printf 'gh PR state unavailable — Stale + PR correlation SKIPPED. '
        printf '\n\n'
    fi
    printf '## TL;DR\n\n%s\n\n' "$tldr_final"
    printf '## ✅ Completed (%s PRs merged to main)\n\n' "$pr_count"
    if [ -n "$pr_table" ]; then
        printf '| PR | Ticket | Summary |\n|---|---|---|\n%s\n' "$pr_table"
    else
        printf '_No merged PRs found via gh since %s. Check gh auth + filter._\n' "$SINCE_DATE"
    fi
    printf '\n### Commits (%s since %s)\n\n' "$commit_count" "$SINCE_SHA"
    if [ -n "$commits_raw" ]; then
        # shellcheck disable=SC2016  # backticks here are markdown literal, not subshell
        printf '```\n%s\n```\n' "$commits_raw"
    else
        printf '_No commits found since %s._\n' "$SINCE_SHA"
    fi
    printf '\n### Tickets transitioned to Done (cross-referenced against commits)\n\n'
    if [ -n "$done_block" ]; then
        printf '%s\n' "$done_block"
    elif [ ${#ticket_keys[@]} -eq 0 ]; then
        printf '_No ticket keys detected in commit messages._\n'
    else
        printf '_Ticket keys detected in commits: %s. jira CLI unavailable or no Done matches._\n' "$(IFS=,; echo "${ticket_keys[*]}")"
    fi

    # In-flight WIP -----------------------------------------------------------
    printf '\n## 🔴 In-flight WIP\n\n'
    # annotated_branches MUST be initialized OUTSIDE the if — the catch-all below
    # references it unconditionally; under set -u an unset var aborts this subshell.
    annotated_branches=""
    wip_keys=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' 'NF>=3 && $1!="KEY"{print $1}')
    if [ -n "$wip_keys" ]; then
        while IFS= read -r key; do
            [ -z "$key" ] && continue
            title=$(printf '%s\n' "$inprogress_raw" | awk -F'\t' -v k="$key" '$1==k{print $4; exit}')
            key_lc=$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')
            br=$(printf '%s\n' "$wt_branches" | tr '[:upper:]' '[:lower:]' | grep -F "$key_lc" | head -1 || true)
            if [ -n "$br" ]; then
                pr=$(printf '%s\n' "$pr_map" | awk -F'\t' -v b="$br" 'tolower($2)==b && $1=="OPEN"{print $3; exit}')
                annotated_branches="$annotated_branches$br"$'\n'
                if [ -n "$pr" ]; then
                    printf -- '- **%s** — %s — worktree %s, PR #%s\n' "$key" "$title" "$br" "$pr"
                else
                    printf -- '- **%s** — %s — worktree %s (no PR)\n' "$key" "$title" "$br"
                fi
            else
                printf -- '- **%s** — %s — (uncorrelated: no key-bearing branch)\n' "$key" "$title"
            fi
        done <<EOF_WIP
$wip_keys
EOF_WIP
    else
        printf '_No In-Progress tickets._\n'
    fi
    catchall=$(printf '%s\n' "$pr_map" | awk -F'\t' -v seen="$annotated_branches" '
        BEGIN{ n=split(seen,s,"\n"); for(i in s) skip[tolower(s[i])]=1 }
        $1=="OPEN" && !( tolower($2) in skip ){ printf "- PR #%s — %s\n", $3, $2 }')
    if [ -n "$catchall" ]; then
        printf '\n_Other open PRs / worktrees (no In-Progress ticket):_\n%s\n' "$catchall"
    fi

    # Stale worktrees ---------------------------------------------------------
    printf '\n## 🧹 Stale worktrees\n\n'
    if [ -n "$stale_rows" ]; then
        printf '| Worktree branch | State | Action |\n|---|---|---|\n%s' "$stale_rows"
    elif [ "$briefing_forge" != "github" ]; then
        printf '_PR state unavailable on non-github forge — stale detection skipped._\n'
    elif [ "$pr_map_ok" -eq 0 ]; then
        printf '_gh PR-state query failed — stale detection unavailable (NOT a clean garden)._\n'
    else
        printf '_No stale worktrees (no merged-PR branches checked out)._\n'
    fi

    # Backlog -----------------------------------------------------------------
    printf '\n## 📋 Backlog (%s To Do)\n\n' "$backlog_total"
    if [ -n "$backlog_block_final" ]; then
        printf '%s\n' "$backlog_block_final"
    elif [ "$backlog_total" -gt 0 ]; then
        # head may close the pipe early → SIGPIPE/141 → pipefail; guard with || true.
        { printf '%s\n' "$backlog_rows" | head -n "$BACKLOG_LIMIT" \
            | awk -F'\t' '{printf "- %s — %s\n", $1, $4}'; } || true
        if [ "$backlog_total" -gt "$BACKLOG_LIMIT" ]; then
            printf '_…and %s more (raise --backlog-limit to see all)._\n' "$((backlog_total - BACKLOG_LIMIT))"
        fi
    else
        printf '_No To-Do tickets (or jira unavailable)._\n'
    fi

    # Docs drift (HIMMEL-587) -------------------------------------------------
    printf '\n## 📄 Docs drift\n\n'
    if ! df_leg_active morning; then
        # shellcheck disable=SC2016  # backticks here are markdown literal, not subshell
        printf '_Doc-freshness off (set HIMMEL_DOC_FRESHNESS to include `morning`)._\n'
    elif [ -n "$docs_drift" ]; then
        printf '%s\n' "$docs_drift" | awk -F'\t' 'NF>=2{printf "- %s → update %s\n", $1, $2}'
    else
        printf '_No mapped-source-vs-doc drift since %s._\n' "$SINCE_SHA"
    fi

    # Suggested order ---------------------------------------------------------
    printf '\n## Suggested order\n\n%s\n' "$order_final"
)

# Write / print ----------------------------------------------------------------

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
