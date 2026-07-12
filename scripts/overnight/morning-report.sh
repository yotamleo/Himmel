#!/usr/bin/env bash
# overnight/morning-report — consolidated morning report for /overnight-shift
# (HIMMEL-258).
#
# The run-end path of /overnight-shift collects one TSV row per dispatched
# ticket and feeds it here (stdin or --rows FILE):
#
#   KEY \t BRANCH \t PR \t STATUS \t OUTCOME [\t DECISION]
#
#   STATUS   ∈ done | blocked | partial
#   DECISION non-empty marks an item that needs a human call (6th field
#            optional; empty/absent = no decision needed)
#
# Emits ONE markdown artifact instead of per-ticket discovery across N
# branches/PRs/reports: a "Decisions needed" block grouped at the top,
# then a per-ticket table ordered decisions-first (has-decision > blocked
# > partial > done; input order preserved within a group). Rationale:
# human review is the serial fraction that caps fanout speedup (Amdahl) —
# batch the mandatory checkpoint into a single entry point.
#
# Output path resolves via the HIMMEL-118 single-root resolver
# (scripts/lib/handover-path.sh — never hardcode ./handovers/):
#   - Mode B (HANDOVER_DIR set) → $HANDOVER_DIR/overnight-report-$(date -u +%F).md
#     Broken HANDOVER_DIR fails closed (exit 2) — no fallback, matching the
#     resolver's fail-closed design. Fix HANDOVER_DIR or pass --out.
#   - Mode A (inline)           → $repo/handovers/overnight-report-$(date -u +%F).md
#     (created on demand via handover_root_ensure — this is a write op)
#   - --out PATH overrides; --dry-run prints without touching files but
#     previews the SAME resolution the real run would perform (broken
#     HANDOVER_DIR still exits 2; Mode A previews <repo>/handovers/
#     without the mkdir).
#
# Exit codes:
#   0  report written (or printed under --dry-run)
#   1  usage / input error (no rows, missing columns, bad status)
#   2  env unusable (output path unresolvable)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/handover-path.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/handover-path.sh"

ROWS_FILE=""
OUT_FILE=""
ACTIONS_FILE=""
DRY_RUN=0

usage() {
    cat <<'EOF'
Usage: morning-report.sh [--rows FILE] [--out PATH] [--actions FILE] [--dry-run]

Reads one TSV row per dispatched ticket (stdin by default):

  KEY \t BRANCH \t PR \t STATUS \t OUTCOME [\t DECISION]

  STATUS ∈ done|blocked|partial. A non-empty DECISION field marks the
  ticket as needing a human call; those items are grouped at the top of
  the report and their rows sort first in the ticket table.

Optional:
  --rows FILE   Read rows from FILE instead of stdin.
  --out PATH    Output path. Default:
                <handover-root>/overnight-report-YYYY-MM-DD.md, resolved
                via handover_root_ensure (scripts/lib/handover-path.sh).
                A broken HANDOVER_DIR fails closed (exit 2) — no fallback.
  --actions FILE  Standing operator actions appended verbatim as a
                "## Standing operator actions" section. Default:
                <dirname OUT_FILE>/operator-actions.md. A durable list that
                survives every regeneration (one-off notes elsewhere do not
                resurface in a regenerated report). Skipped when absent/blank.
  --dry-run     Print the report to stdout; touch no files.

Environment overrides:
  HANDOVER_DIR   External handover root (Mode B).
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --rows)
            [ -n "${2:-}" ] || { echo "ERR morning-report: --rows requires a FILE" >&2; exit 1; }
            ROWS_FILE="$2"; shift 2 ;;
        --out)
            [ -n "${2:-}" ] || { echo "ERR morning-report: --out requires a PATH" >&2; exit 1; }
            OUT_FILE="$2"; shift 2 ;;
        --actions)
            [ -n "${2:-}" ] || { echo "ERR morning-report: --actions requires a FILE" >&2; exit 1; }
            ACTIONS_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *)         echo "ERR morning-report: unknown arg: $1" >&2; usage >&2; exit 1 ;;
    esac
done

# Read rows ------------------------------------------------------------

if [ -n "$ROWS_FILE" ]; then
    if [ ! -f "$ROWS_FILE" ]; then
        echo "ERR morning-report: --rows file not found: $ROWS_FILE" >&2
        exit 1
    fi
    rows_raw=$(cat "$ROWS_FILE")
else
    if [ -t 0 ]; then
        echo "morning-report: reading TSV rows from stdin (Ctrl-D to end)..." >&2
    fi
    rows_raw=$(cat)
fi

# Strip CRs first (CRLF row files on Windows would otherwise leave a
# trailing \r polluting the last field), then drop blank lines up front so
# validation line numbers match content rows.
rows=$(printf '%s\n' "$rows_raw" | tr -d '\r' | grep -v '^[[:space:]]*$' || true)
if [ -z "$rows" ]; then
    echo "ERR morning-report: no ticket rows on input (expected TSV: KEY, BRANCH, PR, STATUS, OUTCOME[, DECISION])" >&2
    exit 1
fi

# Validate: 5 or 6 tab-separated fields, non-empty KEY/BRANCH, recognised
# status. Fail loudly — malformed rows mean the caller mis-assembled the
# TSV (e.g. a literal tab inside OUTCOME shifts fields and would silently
# mislabel DECISION), and a silently wrong report is worse than no report.
errors=$(printf '%s\n' "$rows" | awk -F'\t' '
    NF < 5 { printf "row %d: expected >=5 tab-separated fields, got %d\n", NR, NF; next }
    NF > 6 { printf "row %d: expected <=6 tab-separated fields, got %d (literal tab inside a field?)\n", NR, NF; next }
    $1 == "" { printf "row %d: empty KEY field\n", NR }
    $2 == "" { printf "row %d: empty BRANCH field\n", NR }
    $4 != "done" && $4 != "blocked" && $4 != "partial" {
        printf "row %d: invalid status \"%s\" (want done|blocked|partial)\n", NR, $4
    }
')
if [ -n "$errors" ]; then
    printf 'ERR morning-report: bad input rows:\n%s\n' "$errors" >&2
    exit 1
fi

# Resolve --out when not passed. Write path uses _ensure (we WRITE here,
# the Mode A inline dir may legitimately not exist yet); --dry-run uses
# the PURE resolver so "touch no files" stays true (no mkdir side effect).
# Resolution failure fails CLOSED (exit 2) — never fall back to a guessed
# path, matching the resolver's fail-closed design: the operator's single
# morning entry point must not land in the wrong location.
if [ -z "$OUT_FILE" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
        # Preview the SAME resolution the real run would perform, minus the
        # mkdir — otherwise the dry run masks exactly the failures (or
        # successes) the operator is trying to validate:
        #   - broken HANDOVER_DIR fails closed here too (exit 2), with the
        #     resolver diagnostic NOT suppressed;
        #   - Mode A in a git repo previews <repo>/handovers/... even when
        #     the dir doesn't exist yet (the real run would mkdir it).
        if [ -n "${HANDOVER_DIR:-}" ]; then
            if ! root=$(handover_root); then
                echo "ERR morning-report: HANDOVER_DIR='$HANDOVER_DIR' is set but unusable — fix HANDOVER_DIR or pass --out" >&2
                exit 2
            fi
            OUT_FILE="$root/overnight-report-$(date -u +%F).md"
        elif repo_root=$(git rev-parse --show-toplevel 2>/dev/null); then
            OUT_FILE="$repo_root/handovers/overnight-report-$(date -u +%F).md"
        else
            OUT_FILE="<unresolved-handover-root>/overnight-report-$(date -u +%F).md"
            echo "WARN morning-report: output path unresolvable (HANDOVER_DIR unset, not in a git repo) — a real run would exit 2" >&2
        fi
    elif root=$(handover_root_ensure); then
        OUT_FILE="$root/overnight-report-$(date -u +%F).md"
    elif [ -n "${HANDOVER_DIR:-}" ]; then
        echo "ERR morning-report: HANDOVER_DIR='$HANDOVER_DIR' is set but unusable — fix HANDOVER_DIR or pass --out" >&2
        exit 2
    else
        echo "ERR morning-report: cannot resolve output path (HANDOVER_DIR unset, not in a git repo) — pass --out" >&2
        exit 2
    fi
fi

# Resolve standing operator actions. Default sits next to the report so it
# follows the same handover-root resolution. Read verbatim (markdown), strip
# CRs (CRLF-edited files on Windows), and treat whitespace-only as absent.
if [ -z "$ACTIONS_FILE" ]; then
    ACTIONS_FILE="$(dirname "$OUT_FILE")/operator-actions.md"
fi
actions_body=""
if [ -f "$ACTIONS_FILE" ]; then
    actions_body=$(tr -d '\r' < "$ACTIONS_FILE")
    printf '%s' "$actions_body" | grep -q '[^[:space:]]' || actions_body=""
fi

# Order rows decisions-first --------------------------------------------
# Decorate (has-decision rank, status rank, input order) → sort → strip.

sorted=$(printf '%s\n' "$rows" | awk -F'\t' '{
    d = ($6 != "") ? 0 : 1
    s = ($4 == "blocked") ? 0 : ($4 == "partial") ? 1 : 2
    printf "%d\t%d\t%06d\t%s\n", d, s, NR, $0
}' | sort -t "$(printf '\t')" -k1,1n -k2,2n -k3,3n | cut -f4-)

total=$(printf '%s\n' "$sorted" | grep -c .)
n_done=$(printf '%s\n' "$sorted" | awk -F'\t' '$4=="done"' | grep -c . || true)
n_blocked=$(printf '%s\n' "$sorted" | awk -F'\t' '$4=="blocked"' | grep -c . || true)
n_partial=$(printf '%s\n' "$sorted" | awk -F'\t' '$4=="partial"' | grep -c . || true)
n_decisions=$(printf '%s\n' "$sorted" | awk -F'\t' '$6!=""' | grep -c . || true)

# Template --------------------------------------------------------------

report=$(
    cat <<EOF
# Overnight shift report — $(date -u +%F)

> Auto-generated by \`scripts/overnight/morning-report.sh\` (HIMMEL-258).
> Morning review: read this ONE report, then drill into PRs — work the
> decisions block first, then review PRs in table order (\`/pr-check\`).

**$total tickets**: $n_done done, $n_partial partial, $n_blocked blocked — decisions needed: **$n_decisions**.

## Decisions needed ($n_decisions)

EOF
    if [ "$n_decisions" -gt 0 ]; then
        printf '%s\n' "$sorted" | awk -F'\t' '$6 != "" {
            pr = ($3 != "") ? $3 : "—"
            printf "- **%s** — %s (status: %s, PR: %s)\n", $1, $6, $4, pr
        }'
    else
        printf '_None — no ticket needs a human decision._\n'
    fi
    printf '\n## Tickets (%s)\n\n' "$total"
    printf '| Ticket | Branch | PR | Status | Outcome |\n|---|---|---|---|---|\n'
    printf '%s\n' "$sorted" | awk -F'\t' 'NF {
        for (i = 1; i <= NF; i++) gsub(/\|/, "\\|", $i)
        pr = ($3 != "") ? $3 : "—"
        printf "| %s | `%s` | %s | %s | %s |\n", $1, $2, pr, $4, $5
    }'
)

# Append standing operator actions verbatim (durable — survives regeneration).
if [ -n "$actions_body" ]; then
    report="$report"$'\n\n'"## Standing operator actions"$'\n\n'"$actions_body"
fi

# Write / print ----------------------------------------------------------

if [ "$DRY_RUN" -eq 1 ]; then
    echo "DRY morning-report: would write to $OUT_FILE"
    echo "DRY morning-report: body:"
    printf '%s\n' "$report"
    exit 0
fi

mkdir -p "$(dirname "$OUT_FILE")"
printf '%s\n' "$report" > "$OUT_FILE"
echo "morning-report: wrote $OUT_FILE ($total tickets, $n_decisions decisions needed)"
exit 0
