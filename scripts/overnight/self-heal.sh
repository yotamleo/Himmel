#!/usr/bin/env bash
# self-heal.sh — Self-healing post-return retry/triage over /overnight-shift
# (HIMMEL-476, C2).
#
# WHY ----------------------------------------------------------------------
# /overnight-shift is fire-and-forget: the parent fans out all Task subagents
# in ONE message and only sees their results after EVERY subagent returns.
# There is no live gate-result stream to monitor, and a returned subagent
# cannot be "resumed" — only replaced. So C2 is a POST-RETURN pass, not a live
# monitor (that distinction keeps it independent of HIMMEL-465 VM supervision).
#
# Today a single mechanical gate failure (a stray shellcheck finding, a BOM, a
# diff-range slip) silently kills an overnight ticket and the operator nurses
# each pipeline by morning. C2 sits UPSTREAM of the consolidated morning report
# (scripts/overnight/morning-report.sh, HIMMEL-258 — reused UNCHANGED) and adds
# a retry/triage stage between the fanout-return and the report:
#
#   classify : parse each subagent result; for a CLOSED ALLOW-LIST of
#              mechanical failures (lint / encoding / diff-range) emit a
#              fix-subagent DISPATCH SPEC; SUBSTANTIVE/CR failures are TRIAGED
#              (reported, never auto-fixed — fail-safe); done tickets pass through.
#   reconcile: after the parent dispatches the fresh fix subagents and
#              re-collects their results, merge them back into the final
#              morning-report rows — auto-fixed-green becomes `done`, a fix that
#              STILL fails (or a fix subagent that never returned) becomes an
#              operator-gated blocker (bounded: one auto-fix attempt, never a loop).
#
# SINGLE-WRITER: this script never edits a branch. The parent owns dispatch +
# merge/synthesis; each fix subagent writes ONLY its own branch. Merge stays an
# operator/leg action. No run is stopped on the first failure — every record is
# processed (the failures are DATA, not control flow; hence `set -uo pipefail`,
# not `set -e`).
#
# CLI ----------------------------------------------------------------------
#   self-heal.sh classify  --rows-in  IN   [--rows-out ROWS] [--dispatch-out PLAN]
#   self-heal.sh reconcile --plan PLAN --fixed FIXED --rows-in ROWS [--rows-out FINAL]
#
# classify INPUT  (the swarm result ledger — one row per dispatched ticket):
#       KEY <tab> BRANCH <tab> PR <tab> STATUS <tab> OUTCOME <tab> LOGFILE
#   STATUS ∈ done|blocked|partial. LOGFILE is a path to the subagent's captured
#   result/log (field 6, may be empty for done rows). This 6-field LEDGER is
#   DISTINCT from a morning-report row (whose optional 6th field is DECISION).
#
# classify OUTPUT:
#   --rows-out  morning-report-ready rows (KEY⇥BRANCH⇥PR⇥STATUS⇥OUTCOME[⇥DECISION]):
#                 done           → passed through as a `done` row,
#                 substantive    → triage row with DECISION (operator-gated blocker),
#                 mechanical     → HELD (NOT emitted here — pending reconcile).
#   --dispatch-out  one fix-subagent dispatch spec per mechanical failure:
#                 KEY <tab> BRANCH <tab> CLASS <tab> FIX_INSTRUCTION
#
# reconcile INPUT:
#   --plan   the classify dispatch-out (which branches were dispatched).
#   --fixed  re-collected fix results: KEY⇥BRANCH⇥PR⇥STATUS⇥OUTCOME.
#   --rows-in the classify rows-out (done + substantive rows so far).
# reconcile OUTPUT (--rows-out, default stdout): the FINAL morning-report rows,
#   ready to pipe into morning-report.sh.
#
# Exit codes: 0 ok · 1 usage / input error · (failures in the data never fail
# the script — that is the whole point).
#
# bash 3.2-safe; shellcheck-clean; cross-platform (Git Bash / macOS / Linux).

set -uo pipefail

TAB="$(printf '\t')"

# --- classification allow-list -------------------------------------------
# CLOSED allow-list: a failure is auto-fixable ONLY if it matches one of these
# mechanical classes. Anything else defaults to SUBSTANTIVE (fail-safe).
#
# Precedence: a STRONG substantive signal WINS over a mechanical match (a log
# that carries both a shellcheck finding AND a failing unit test must NOT be
# auto-fixed — fixing the lint would not fix the test). The strong-signal set is
# deliberately narrow: it does NOT include bare "fail"/"error"/"Failed", because
# a pre-commit run prints "shellcheck....Failed" for a PURE lint failure — that
# must still classify as mechanical. Only unambiguous substance counts.
_RE_SUBSTANTIVE='assert|traceback|merge conflict|[[:<:]]CONFLICT[[:>:]]|[[:<:]]critical[[:>:]]|logic error|segfault|core dumped|panic:|[[:<:]]CR[[:>:]].*(finding|blocker|comment)|(unit |failing )test|tests? (are )?(failing|red)'
_RE_LINT='shellcheck|shell-lint|SC[0-9]{4}'
_RE_ENCODING='byte-order mark|[[:<:]]BOM[[:>:]]|SC1082|CRLF|invalid (utf-?8|encoding)'
_RE_DIFFRANGE='diff[- ]range|merge-base|two-dot|wrong base|patch context'

# GNU/BSD grep spells word boundaries differently; [[:<:]]/[[:>:]] are BSD-only
# and \b is the GNU form. Probe once and normalise the patterns so the same
# classifier behaves identically on macOS (BSD grep) and Linux/Git Bash (GNU).
# The replacement is written as TWO backslashes (\\b) inside this single-quoted
# sed program: sed emits a single literal backslash + b → the pattern \bCONFLICT\b,
# which GNU grep -E reads as a real word boundary. (Verified in-file: two
# backslashes is correct here; four would emit \\b — a literal backslash that
# never matches. Don't "fix" this from a shell one-liner — an interactive shell
# strips a backslash level the file does not, which makes the correct form look
# broken.) Tests 18/20 pin this on GNU grep.
if printf 'x' | grep -E '[[:<:]]x' >/dev/null 2>&1; then
    : # BSD word boundaries supported as written
else
    _RE_SUBSTANTIVE="$(printf '%s' "$_RE_SUBSTANTIVE" | sed 's/\[\[:<:\]\]/\\b/g; s/\[\[:>:\]\]/\\b/g')"
    _RE_ENCODING="$(printf '%s' "$_RE_ENCODING" | sed 's/\[\[:<:\]\]/\\b/g; s/\[\[:>:\]\]/\\b/g')"
fi

# classify_failure CONTENT -> echoes one of: substantive|lint|encoding|diff-range
_classify_failure() {
    local content="$1"
    if printf '%s' "$content" | grep -Eiq -- "$_RE_SUBSTANTIVE"; then
        echo substantive; return
    fi
    # Encoding signatures (BOM / SC1082 / CRLF) are MORE SPECIFIC than the
    # generic lint match, and a BOM finding is often surfaced via shell-lint
    # output (which also matches _RE_LINT) — so probe encoding first to land the
    # more precise class + fix instruction.
    if printf '%s' "$content" | grep -Eiq -- "$_RE_ENCODING";  then echo encoding;   return; fi
    if printf '%s' "$content" | grep -Eiq -- "$_RE_LINT";      then echo lint;       return; fi
    if printf '%s' "$content" | grep -Eiq -- "$_RE_DIFFRANGE"; then echo "diff-range"; return; fi
    echo substantive
}

# _fix_instruction CLASS BRANCH -> a scoped, single-writer fix-subagent prompt.
_fix_instruction() {
    local class="$1" branch="$2"
    case "$class" in
        lint)
            printf 'On branch %s ONLY: run scripts/lint/shell-lint.sh --staged (or on the changed shell files), fix the reported shellcheck/lint findings ONLY (do NOT change logic), re-commit keeping the SAME attestation trailers in the first commit, and push. Re-collect the result.' "$branch" ;;
        encoding)
            printf 'On branch %s ONLY: strip the UTF-8 BOM / fix the CRLF or encoding finding on the changed files (content-preserving), re-commit keeping the SAME attestation trailers, and push. Do NOT change logic. Re-collect the result.' "$branch" ;;
        diff-range)
            printf 'On branch %s ONLY: recompute the diff range against the correct merge-base (use the merge-base range, not two-dot), re-run the affected step, re-commit, and push. Do NOT change logic. Re-collect the result.' "$branch" ;;
        *)
            printf 'On branch %s ONLY: apply the scoped mechanical fix and push.' "$branch" ;;
    esac
}

# --- arg parsing ----------------------------------------------------------

die() { printf 'self-heal: %s\n' "$1" >&2; exit 1; }

usage() {
    awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"
}

[ $# -ge 1 ] || { usage >&2; exit 1; }
SUBCMD="$1"; shift

# strip CR + drop blank lines from a TSV blob (CRLF-safe on Windows)
_clean_rows() { tr -d '\r' | grep -v '^[[:space:]]*$' || true; }

cmd_classify() {
    local rows_in="" rows_out="" plan_out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --rows-in)      [ -n "${2:-}" ] || die "--rows-in requires a FILE"; rows_in="$2"; shift 2 ;;
            --rows-out)     [ -n "${2:-}" ] || die "--rows-out requires a PATH"; rows_out="$2"; shift 2 ;;
            --dispatch-out) [ -n "${2:-}" ] || die "--dispatch-out requires a PATH"; plan_out="$2"; shift 2 ;;
            -h|--help)      usage; exit 0 ;;
            *) die "classify: unknown arg: $1" ;;
        esac
    done
    [ -n "$rows_in" ] || die "classify: --rows-in is required"
    [ -f "$rows_in" ] || die "classify: --rows-in file not found: $rows_in"

    local rows; rows="$(_clean_rows < "$rows_in")"
    [ -n "$rows" ] || die "classify: no rows on input (expected ledger TSV: KEY,BRANCH,PR,STATUS,OUTCOME,LOGFILE)"

    # Validate field count (5 or 6; LOGFILE optional) and status up front so a
    # mis-assembled ledger fails loudly rather than silently mis-triaging.
    local errors
    errors="$(printf '%s\n' "$rows" | awk -F'\t' '
        NF < 5 { printf "row %d: expected >=5 tab-separated fields, got %d\n", NR, NF; next }
        NF > 6 { printf "row %d: expected <=6 tab-separated fields, got %d (literal tab inside a field?)\n", NR, NF; next }
        $1 == "" { printf "row %d: empty KEY field\n", NR }
        $2 == "" { printf "row %d: empty BRANCH field\n", NR }
        $4 != "done" && $4 != "blocked" && $4 != "partial" {
            printf "row %d: invalid status \"%s\" (want done|blocked|partial)\n", NR, $4
        }')"
    [ -z "$errors" ] || { printf 'self-heal classify: bad input rows:\n%s\n' "$errors" >&2; exit 1; }

    local out_rows="" out_plan=""
    local n_done=0 n_sub=0 n_mech=0
    local key branch pr status outcome logfile content class

    while IFS="$TAB" read -r key branch pr status outcome logfile; do
        [ -n "$key" ] || continue
        if [ "$status" = "done" ]; then
            out_rows="$out_rows$key$TAB$branch$TAB$pr$TAB""done$TAB$outcome"$'\n'
            n_done=$((n_done + 1))
            continue
        fi

        # Non-done: read the captured log (if any) and classify.
        content=""
        if [ -n "${logfile:-}" ] && [ -f "$logfile" ]; then
            content="$(tr -d '\r' < "$logfile")"
        fi
        # No detail captured → cannot prove it is mechanical → fail-safe triage.
        if [ -z "$content" ]; then
            out_rows="$out_rows$key$TAB$branch$TAB$pr$TAB$status$TAB$outcome${TAB}operator-gated blocker: no failure detail captured — manual triage"$'\n'
            n_sub=$((n_sub + 1))
            continue
        fi

        class="$(_classify_failure "$content")"
        case "$class" in
            substantive)
                out_rows="$out_rows$key$TAB$branch$TAB$pr$TAB$status$TAB$outcome${TAB}operator-gated blocker: substantive failure — no auto-fix"$'\n'
                n_sub=$((n_sub + 1)) ;;
            *)
                # Mechanical → HELD (not a report row yet); emit a dispatch spec.
                local instr; instr="$(_fix_instruction "$class" "$branch")"
                out_plan="$out_plan$key$TAB$branch$TAB$class$TAB$instr"$'\n'
                n_mech=$((n_mech + 1)) ;;
        esac
    done <<EOF
$rows
EOF

    # Emit rows.
    if [ -n "$rows_out" ]; then printf '%s' "$out_rows" > "$rows_out"; else printf '%s' "$out_rows"; fi
    # Emit dispatch plan.
    if [ -n "$plan_out" ]; then
        printf '%s' "$out_plan" > "$plan_out"
    elif [ -n "$out_plan" ]; then
        printf 'self-heal classify: %d mechanical failure(s) need a fix subagent but no --dispatch-out given:\n%s' "$n_mech" "$out_plan" >&2
    fi

    printf 'self-heal classify: %d done, %d substantive (triaged), %d mechanical (dispatch specs)\n' \
        "$n_done" "$n_sub" "$n_mech" >&2
}

cmd_reconcile() {
    local plan="" fixed="" rows_in="" rows_out=""
    while [ $# -gt 0 ]; do
        case "$1" in
            --plan)     [ -n "${2:-}" ] || die "--plan requires a FILE"; plan="$2"; shift 2 ;;
            --fixed)    [ -n "${2:-}" ] || die "--fixed requires a FILE"; fixed="$2"; shift 2 ;;
            --rows-in)  [ -n "${2:-}" ] || die "--rows-in requires a FILE"; rows_in="$2"; shift 2 ;;
            --rows-out) [ -n "${2:-}" ] || die "--rows-out requires a PATH"; rows_out="$2"; shift 2 ;;
            -h|--help)  usage; exit 0 ;;
            *) die "reconcile: unknown arg: $1" ;;
        esac
    done
    [ -n "$plan" ]    || die "reconcile: --plan is required"
    [ -n "$rows_in" ] || die "reconcile: --rows-in is required"
    [ -f "$plan" ]    || die "reconcile: --plan file not found: $plan"
    [ -f "$rows_in" ] || die "reconcile: --rows-in file not found: $rows_in"
    # --fixed may legitimately be absent (every fix subagent died) — treat a
    # missing file as "no results returned" so the silent-death path still fires.
    local fixed_rows=""
    if [ -n "$fixed" ] && [ -f "$fixed" ]; then fixed_rows="$(_clean_rows < "$fixed")"; fi

    local final; final="$(_clean_rows < "$rows_in")"
    # Carry the classify rows through verbatim, then append a reconciled row per
    # dispatched (held) branch.
    [ -z "$final" ] || final="$final"$'\n'

    local plan_rows; plan_rows="$(_clean_rows < "$plan")"
    local pkey pbranch
    local n_green=0 n_stillfail=0 n_noreturn=0
    if [ -n "$plan_rows" ]; then
        # Fields 3 (class) + 4 (instruction) are not needed at reconcile time —
        # discard them into the throwaway var.
        while IFS="$TAB" read -r pkey pbranch _; do
            [ -n "$pkey" ] || continue
            # Look up this branch in the re-collected fix results (exact match on
            # field 2). First match wins.
            local frow
            frow="$(printf '%s\n' "$fixed_rows" | awk -F'\t' -v b="$pbranch" '$2==b{print; exit}')"
            if [ -z "$frow" ]; then
                final="$final$pkey$TAB$pbranch$TAB—${TAB}blocked${TAB}(no result returned)${TAB}fix subagent did not return — manual triage"$'\n'
                n_noreturn=$((n_noreturn + 1))
                continue
            fi
            local fkey fbranch fpr fstatus foutcome
            IFS="$TAB" read -r fkey fbranch fpr fstatus foutcome <<EOF2
$frow
EOF2
            if [ "$fstatus" = "done" ]; then
                final="$final$fkey$TAB$fbranch$TAB$fpr$TAB""done$TAB$foutcome"$'\n'
                n_green=$((n_green + 1))
            else
                final="$final$fkey$TAB$fbranch$TAB$fpr$TAB$fstatus$TAB$foutcome${TAB}auto-fix attempted, still failing — manual triage (no second auto-fix)"$'\n'
                n_stillfail=$((n_stillfail + 1))
            fi
        done <<EOF
$plan_rows
EOF
    fi

    # Surface orphan fix results: a --fixed branch NOT in the plan is never
    # consumed above and would otherwise vanish without trace. The plan drives
    # dispatch, so an orphan means a result was collected for a branch nobody
    # dispatched — a process anomaly worth a loud line (charter: no silent drops).
    if [ -n "$fixed_rows" ] && [ -n "$plan_rows" ]; then
        local orphans
        orphans="$(awk -F'\t' 'NR==FNR{seen[$2]=1; next} !($2 in seen){printf "  %s\t%s\n",$1,$2}' \
            <(printf '%s\n' "$plan_rows") <(printf '%s\n' "$fixed_rows") 2>/dev/null)"
        if [ -n "$orphans" ]; then
            printf 'self-heal reconcile: fix result(s) for un-dispatched branch(es) (not in any report row):\n%s\n' "$orphans" >&2
        fi
    fi

    if [ -n "$rows_out" ]; then printf '%s' "$final" > "$rows_out"; else printf '%s' "$final"; fi
    printf 'self-heal reconcile: %d auto-fixed green, %d still failing, %d no-return (escalated)\n' \
        "$n_green" "$n_stillfail" "$n_noreturn" >&2
}

case "$SUBCMD" in
    classify)  cmd_classify "$@" ;;
    reconcile) cmd_reconcile "$@" ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown subcommand: $SUBCMD (want classify|reconcile)" ;;
esac
