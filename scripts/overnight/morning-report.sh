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
NO_UNLANDED=0

usage() {
    cat <<'EOF'
Usage: morning-report.sh [--rows FILE] [--out PATH] [--actions FILE] [--dry-run] [--no-unlanded]

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
  --no-unlanded Suppress the "## Unlanded work" section (HIMMEL-2070).

Environment overrides:
  HANDOVER_DIR       External handover root (Mode B).
  UNLANDED_TSV       Path to a pre-computed unlanded-work.sh --tsv file (test
                     seam) — when set, scripts/unlanded-work.sh is never
                     shelled out to.
  GEN_CHANGELOG_SCRIPT  Path to gen-changelog.sh (test seam) — when set,
                     overrides the default scripts/gen-changelog.sh so a
                     test fixture never shells out to the live generator.
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
        --no-unlanded) NO_UNLANDED=1; shift ;;
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

# Append "## Unlanded work" (HIMMEL-2070): AGED UNLANDED-LIVE branches — work
# committed but never opened as a PR. Advisory: a detector failure must not
# fail this report, but it also must not silently render as "none" (which
# would look identical to a genuinely clean scan) — it gets its own explicit
# "unavailable" line instead. UNLANDED_TSV is a test seam: when set, a
# pre-computed --tsv file is read instead of shelling out to the live repo.
if [ "$NO_UNLANDED" -eq 0 ]; then
    unlanded_tsv=""
    unlanded_ok=1
    if [ -n "${UNLANDED_TSV:-}" ]; then
        if [ -f "$UNLANDED_TSV" ]; then
            # codex-3, HIMMEL-2070 CR round 6: check cat's own exit status —
            # a file that exists but fails to READ (permission denied, I/O
            # error) must not silently render as unlanded_ok=1 (-> "None"),
            # identical to the "empty scan" case this whole section exists
            # to distinguish from a genuine failure.
            unlanded_tsv="$(cat "$UNLANDED_TSV")" || unlanded_ok=0
        else
            unlanded_ok=0
        fi
    else
        unlanded_detector="$SCRIPT_DIR/../unlanded-work.sh"
        if [ -f "$unlanded_detector" ]; then
            # cd into the repo the detector belongs to before invoking it
            # (codex-4, HIMMEL-2070 CR round 2): unlanded-work.sh resolves its
            # OWN repo from the CALLER's cwd, so without this a caller whose
            # cwd is outside (or in a different) git repo silently scans the
            # wrong tree — or none at all. $SCRIPT_DIR/.. is always inside
            # this checkout regardless of where morning-report.sh was invoked
            # from. Capture stderr separately too (codex-2, same round): the
            # detector always exits 0 by contract even on a scan failure (an
            # unresolvable --base) — a discarded stderr made that failure
            # read identically to a genuinely empty scan ("None").
            unlanded_stderr_tmp="$(mktemp)"
            unlanded_tsv="$(cd "$SCRIPT_DIR/.." && bash "$unlanded_detector" --tsv 2>"$unlanded_stderr_tmp")" || unlanded_ok=0
            unlanded_stderr="$(cat "$unlanded_stderr_tmp" 2>/dev/null)"; rm -f "$unlanded_stderr_tmp"
            if [ -z "$unlanded_tsv" ] && [ -n "$unlanded_stderr" ]; then
                unlanded_ok=0
            fi
        else
            unlanded_ok=0
        fi
    fi
    unlanded_section=$'\n\n## Unlanded work\n\n'
    if [ "$unlanded_ok" -eq 0 ]; then
        unlanded_section="${unlanded_section}_unlanded-work scan unavailable._"
    else
        aged_rows="$(printf '%s\n' "$unlanded_tsv" | awk -F'\t' '$1=="UNLANDED-LIVE" && $5=="1"')"
        if [ -z "$(printf '%s' "$aged_rows" | tr -d '[:space:]')" ]; then
            unlanded_section="${unlanded_section}_None — no aged unlanded branch found._"
        else
            unlanded_section="${unlanded_section}$(printf '%s\n' "$aged_rows" | awk -F'\t' '{ printf "- **%s** — +%s commits, age %sh (%s)\n", $2, $3, $4, $6 }')"
        fi
    fi
    report="$report$unlanded_section"
fi

# Append "## Changelog freshness" (HIMMEL-2250): CHANGELOG.md is 100%
# derived from git log, so regenerating it per-commit/per-worktree across
# ~20 parallel branches would guarantee a textual merge conflict on every
# landing — this report already runs once daily on main, after the night's
# merges, and is the one artifact the operator reads every morning, so a
# staleness ROW here is the cheapest structural layer that turns invisible
# rot (the 8-week/1052-entry gap this ticket exists to fix) into a visible
# daily line, without ever regenerating the file itself. ADVISORY ONLY: the
# `--check` rc=1 (stale) case is the EXPECTED common case, not a script
# error, so it must never abort this report under `set -e` — hence the
# `|| changelog_rc=$?` guard, mirroring the unlanded-work section above.
#
# HIMMEL-2364: a GEN_CHANGELOG_SCRIPT override can be relative (e.g. a test
# stub, or an operator pointing at a script next to their cwd). The `-f`
# existence check below and the actual execution MUST agree on the same
# path — resolve to absolute in the CALLER's cwd, before the `cd
# "$SCRIPT_DIR/.."` on the execution line moves us elsewhere, so a relative
# override that genuinely resolves from the caller's cwd doesn't pass the
# check and then fail to exec. An unresolvable path (missing file/dir) is
# left as-is so it still falls through to the existing "not found" branch
# below rather than erroring out here.
#
# codex-1 CR finding: resolving dir and basename in ONE assignment
# (`x="$(cd ... && pwd)/$(basename ...)"`) is a trap — bash reports that
# compound assignment's exit status from the LAST command substitution
# (`basename`, which always succeeds), never the `cd`/`pwd` one, so a
# `|| fallback` on it can NEVER fire. A missing/unresolvable directory then
# silently produces "/<basename>" instead of falling back — a malformed
# path that could coincidentally match a real root-level file. Resolve the
# directory in its OWN assignment first (its exit status is then genuinely
# the `cd`/`pwd` result) and only rebuild changelog_script when that
# resolved to something; otherwise leave it as the original override so it
# falls through to the existing "not found" branch below.
changelog_script="${GEN_CHANGELOG_SCRIPT:-$SCRIPT_DIR/../gen-changelog.sh}"
changelog_script_dir="$(cd "$(dirname "$changelog_script")" 2>/dev/null && pwd)" || changelog_script_dir=""
if [ -n "$changelog_script_dir" ]; then
    changelog_script="$changelog_script_dir/$(basename "$changelog_script")"
fi
changelog_section=$'\n\n## Changelog freshness\n\n'
changelog_rc=0
if [ -f "$changelog_script" ]; then
    changelog_check_out="$(cd "$SCRIPT_DIR/.." && bash "$changelog_script" --check 2>&1)" || changelog_rc=$?
else
    changelog_rc=127
fi
case "$changelog_rc" in
    0) changelog_section="${changelog_section}_Current — CHANGELOG.md matches git history._" ;;
    1)
        # Parse the entry count out of the STRUCTURED "STALE gen-changelog:"
        # line only, not the first digits anywhere in the merged
        # stdout+stderr capture — a stray digit earlier in the stream (a
        # warning line, a config count, etc.) must never be mistaken for the
        # entry count. Fall back to quoting the line verbatim if its shape
        # ever changes underneath this script (also covers the missing-file
        # variant, which has no count). `|| n=""` is load-bearing under
        # `set -o pipefail`: pipefail reports the PIPELINE's status as the
        # rightmost command that failed, not `head`'s own (successful) exit
        # code — so a no-match line makes `grep` fail, the substitution
        # fails, and `set -e` would otherwise abort this whole report on the
        # exact "shape changed" case this fallback exists to survive.
        n="$(printf '%s' "$changelog_check_out" | grep -oE '^STALE gen-changelog: CHANGELOG\.md is [0-9]+ entr\(ies\) behind' | grep -oE '[0-9]+' | head -1)" || n=""
        if [ -n "$n" ]; then
            changelog_section="${changelog_section}- **CHANGELOG.md is $n entries behind** — run \`bash scripts/gen-changelog.sh\` and land it in a PR."
        else
            changelog_section="${changelog_section}- **${changelog_check_out}**"
        fi
        ;;
    *) changelog_section="${changelog_section}_changelog freshness check unavailable._" ;;
esac
report="$report$changelog_section"

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
