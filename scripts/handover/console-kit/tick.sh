#!/usr/bin/env bash
# tick.sh — one wake-up-budgeted console snapshot (HIMMEL-2767).
#
# Default output is exactly one batched line. --verbose renders the same
# snapshot as labelled human-readable lines. Configuration can come from env
# (DOC, TOKEN, LEGS, HANDOVER_DIR, REPO) or the matching long options below;
# no console document, token, leg, handover root, or checkout is embedded.
# Relative DOC/LEGS values resolve under the handover root. When HANDOVER_DIR is
# a global state root, include the bucket prefix (for example <user>/<repo>/...).
#
# PLATFORM GUARD: no .ps1 twin, by design. This console kit is Linux-only:
# it observes pgrep, atq, /tmp suite locks, and the claudex/konsole lane.
# Bash 3.2-compatible; no associative arrays or mapfile.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/handover-path.sh
. "$HERE/../../lib/handover-path.sh"

usage() {
    cat <<'USAGE'
usage: tick.sh [--verbose] [--burn] [--doc PATH] [--token TOKEN]
               [--legs "DOC ..."] [--handover-dir DIR] [--repo DIR]

env equivalents: DOC TOKEN LEGS HANDOVER_DIR REPO
Relative DOC/LEGS resolve under the handover root; include the bucket prefix
when HANDOVER_DIR names a global state root.

--legs accepts space- and/or comma-separated leg docs -- both spellings
produce identical output: --legs "N1.md N2.md" and --legs "N1.md,N2.md" are
the same list. A --legs entry that does not resolve to a readable file prints
a "tick: no such leg doc: <path>" warning on stderr and is reported as
NOTFOUND in legs=, never as MISSING -- MISSING is reserved for a lock that is
actually gone.

fleet=<live>/<cap> and capacity= (HIMMEL-3167) are always appended, last on the
line. fleet= is bank-preflight.sh's own census (native + claudex + reserved,
HIMMEL_FLEET_CAP) -- never a second count; fleet=? when that census cannot be
read. capacity=UNDERFILLED:<slack> means live < cap AND no leg launched for
TICK_UNDERFILL_MIN minutes (default 10); capacity=ok otherwise, capacity=unknown
when fleet=?. TICK_LAUNCH_DIR overrides the console work dir the launch logs
are read from.

gql=<remaining>/<reset HH:MM> (HIMMEL-3197): the GitHub GraphQL budget, read from
the X-Ratelimit-* headers of ONE `gh api -i graphql` call
(gh-graphql-budget.sh ghb_read); gql=? when the headers cannot be read.

orphans=<owner>:<count>/<oldest>m (HIMMEL-2761) is the last field: shell-tool
wrappers older than TICK_ORPHAN_MIN minutes (default 30), per owning session
name (`orphan` = no live claude session above it), read-only via
orphan-loops.sh; orphans=none when clean, orphans=? when the process table
cannot be read. A leg whose lock is FREE / tail WRAPPED but which still owns a
wrapper here left a background loop running -- tell the leg to TaskStop it.

nonces=<ok|STRANDED:<leg,...>|unknown|skip> (HIMMEL-3254) closes the line: a held
leg in this console doc's `## Live state` whose nonce does not start with this
console's own letter (`<LETTER>-<leg>-<hex>`) was never rotated after a console
succession and can only verify a message from the console its brief names --
rotate it (quote both tokens, see leg-preface.md "Console succession").
unknown = the doc name carries no console letter or has no `legs:` line.

--burn adds a per-leg context-burn field (first-turn/avg-ctx, via
scripts/lanes/leg-burn.sh) for every doc in --legs. OPT-IN because it scans
the Claude Code transcript root, which a plain tick must never do: a tick runs
on a wake-up budget and this reads every project's transcripts.
USAGE
}

verbose=0
burn=0
DOC="${DOC:-}"
TOKEN="${TOKEN:-}"
LEGS="${LEGS:-}"
REPO="${REPO:-$(cd "$HERE/../../.." && pwd)}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
        --burn) burn=1; shift ;;
        --doc|--token|--legs|--handover-dir|--repo)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in
                --doc) DOC="$2" ;;
                --token) TOKEN="$2" ;;
                --legs) LEGS="$2" ;;
                --handover-dir) HANDOVER_DIR="$2" ;;
                --repo) REPO="$2" ;;
            esac
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

# queue-lock.sh is a child process and must resolve the same external root when
# --handover-dir (rather than an already-exported env var) supplied it.
[ -z "${HANDOVER_DIR:-}" ] || export HANDOVER_DIR

if [ -n "${HANDOVER_DIR:-}" ]; then
    root="$(handover_root 2>/dev/null)" || root=""
else
    root="$(cd "$REPO" 2>/dev/null && handover_root 2>/dev/null)" || root=""
fi

resolve_doc() {
    case "$1" in
        /*) printf '%s\n' "$1" ;;
        *.md) printf '%s/%s\n' "$root" "$1" ;;
        *) printf '%s/%s.md\n' "$root" "$1" ;;
    esac
}

leg_label() {
    # HIMMEL-3145: two label spellings share this one namespace. Legacy
    # consoles (archived docs) named a leg <TICKET>-legN<k>-<slug>; every
    # console since HIMMEL-2975 names one <TICKET>-N<k>-<slug> (no "-leg"
    # substring at all -- docs/handover/console-template.md:104 is the
    # contract, and this must extract the same N<k> token the template
    # tells a console to write in its `## Live state` legs: line, or
    # livestate= below compares two namespaces that never intersect.
    local stem="$1" label
    stem="${stem##*/}"
    stem="${stem%.md}"
    label="$(printf '%s\n' "$stem" | sed -n 's/.*-leg\(N[0-9][0-9]*\).*/\1/p')"
    if [ -z "$label" ]; then
        label="$(printf '%s\n' "$stem" | sed -n 's/^[A-Za-z][A-Za-z]*-[0-9][0-9]*-\(N[0-9][0-9]*\).*/\1/p')"
    fi
    [ -n "$label" ] || label="$stem"
    printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_'
}

# HIMMEL-3167: a leg doc is <TICKET>-N<k>-<slug>-<YYYY-MM-DD>[-RESUME].md but
# headed-arm-leg.sh names the session <TICKET>-N<k>-<slug> (no date), so the
# doc stem alone matched nothing and a live leg read procs=0.
undated_stem() {
    printf '%s' "$1" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}$//'
}

csv_add() {
    if [ -n "$1" ]; then
        printf '%s,%s' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

clock="$(date +%H:%M 2>/dev/null)" || clock="??:??"

hb=skip
console_doc=""
[ -n "$DOC" ] && console_doc="$(resolve_doc "$DOC")"
if [ -n "$console_doc" ] && [ -n "$TOKEN" ]; then
    if bash "$REPO/scripts/handover/queue-lock.sh" heartbeat "$console_doc" "$TOKEN" >/dev/null 2>&1; then
        hb=ok
    else
        hb=fail
    fi
fi

# HIMMEL-3130: --legs accepts space- and/or comma-separated entries. `for leg
# in $LEGS` word-splits on IFS whitespace only, so a comma-joined value was
# silently one iteration over one nonexistent path. Normalize commas to
# spaces once so both loops below (this one and the --burn loop) split
# identically regardless of which separator was used.
LEGS_SPLIT="${LEGS//,/ }"

legs_summary=""
tails_summary=""
# HIMMEL-3145: the census names the -n session the console actually passed
# to `claude`, which is the leg doc's stem minus a -RESUME suffix (the same
# string the --burn loop below matches on) -- collect it here so procs=/
# models= can count against what THIS console dispatched instead of
# guessing from a "-leg" spelling.
leg_names=""
for leg in $LEGS_SPLIT; do
    leg_doc="$(resolve_doc "$leg")"
    label="$(leg_label "$leg")"
    leg_stem="${leg##*/}"; leg_stem="${leg_stem%.md}"; leg_stem="${leg_stem%-RESUME}"
    leg_names="$(csv_add "$leg_names" "$leg_stem")"
    leg_undated="$(undated_stem "$leg_stem")"
    [ "$leg_undated" = "$leg_stem" ] || leg_names="$(csv_add "$leg_names" "$leg_undated")"
    # HIMMEL-3130: NOTFOUND (file does not resolve) is a distinct status from
    # MISSING. MISSING means "the lock is gone" -- exactly the signal a
    # console reads as "reclaim this leg's lock" -- and must never be used for
    # "I could not find the file", which is a warning, not a lock verdict.
    lock_status=NOTFOUND
    tail_status="?"
    if [ -f "$leg_doc" ]; then
        lock_out="$(bash "$REPO/scripts/handover/queue-lock.sh" status "$leg_doc" 2>&1)" || true
        case "$lock_out" in
            *'status: FRESH'*) lock_status=FRESH ;;
            *'status: STALE'*) lock_status=STALE ;;
            free*) lock_status=FREE ;;
            *CORRUPT*) lock_status=CORRUPT ;;
            *) lock_status=UNKNOWN ;;
        esac
        tail_status="$(grep -E '^- .*(LIVE|FINDING|READY|BLOCKED|HALTED|WRAPPED)' "$leg_doc" 2>/dev/null \
            | tail -n 1 | grep -Eo '(LIVE|FINDING|READY|BLOCKED|HALTED|WRAPPED)' | head -n 1)" || tail_status=""
        [ -n "$tail_status" ] || tail_status="?"
    else
        printf 'tick: no such leg doc: %s\n' "$leg_doc" >&2
    fi
    legs_summary="$(csv_add "$legs_summary" "$label:$lock_status")"
    tails_summary="$(csv_add "$tails_summary" "$label:$tail_status")"
done
[ -n "$legs_summary" ] || legs_summary=none
[ -n "$tails_summary" ] || tails_summary=none

# HIMMEL-2973 S1: cross-reference the console doc's own `## Live state`
# `legs:` line against the lock status just computed above (legs_summary),
# the same way ceiling_summary below cross-references argv against a
# separate invariant. "skip" (no --doc given, same as hb=skip above) and
# "unknown" (doc given but no `## Live state`/`legs:` line found -- e.g. a
# pre-HIMMEL-2973 doc) are both distinct from "ok": neither says the state
# agrees, only that there was nothing to disagree about.
list_has() {  # list_has <needle> <word> [word...]
    local needle="$1" w
    shift
    for w in "$@"; do
        [ "$w" = "$needle" ] && return 0
    done
    return 1
}

livestate_summary=skip
nonces_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    live_state_body="$(awk '
        $0 == "## Live state" { f = 1; next }
        f && /^## / { exit }
        f { print }
    ' "$console_doc")"
    legs_line="$(printf '%s\n' "$live_state_body" | grep '^legs:' | head -n 1)"
    if [ -n "$legs_line" ]; then
        # Each leg is one backtick span `<label>:<nonce>:<lock-token>:<pid>`
        # (Delta 2's format) -- take the label, the text before the first
        # colon inside the span.
        # shellcheck disable=SC2016  # backtick span pattern, not a shell expansion
        live_legs="$(printf '%s\n' "$legs_line" | grep -oE '`[A-Za-z0-9_]+:[^`]*`' | sed -E 's/^`([A-Za-z0-9_]+):.*`$/\1/')"
        held_legs="$(printf '%s\n' "$legs_summary" | tr ',' '\n' | awk -F: '$2 == "FRESH" || $2 == "STALE" { print $1 }')"
        drift_csv=""
        for l in $live_legs; do
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            list_has "$l" $held_legs || drift_csv="$(csv_add "$drift_csv" "$l")"
        done
        for l in $held_legs; do
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            list_has "$l" $live_legs || drift_csv="$(csv_add "$drift_csv" "$l")"
        done
        drift_csv="$(printf '%s\n' "$drift_csv" | tr ',' '\n' | awk 'NF' | sort -u | tr '\n' ',' | sed 's/,$//')"
        if [ -n "$drift_csv" ]; then
            livestate_summary="DRIFT:${drift_csv}"
        else
            livestate_summary=ok
        fi
        # HIMMEL-3254: nonces=STRANDED:<leg> -- a HELD leg whose Live-state
        # nonce (`<LETTER>-<leg>-<hex>`) still carries a previous console's
        # letter was never rotated onto THIS console, so it can only verify
        # a message from the console its brief names. The letter is this
        # console doc's own (`<prefix>-nextleg-<date><LETTER>-<name>.md`); a
        # wrapped leg (lock not held) has nothing to rotate. The leg-side rule
        # is docs/handover/leg-preface.md "Console succession".
        # ponytail: this reads THIS doc's Live state, so it sees "not rotated
        # in the state the console keeps", not "the leg accepted the
        # rotation" -- a console that rewrites a leg's Live-state nonce
        # before that leg's quote-back reads ok while the leg is still
        # stranded. The console template therefore says: update the nonce
        # only AFTER the quote-back. A doc name with no parseable letter
        # reads unknown, never a guess.
        console_letter="$(printf '%s\n' "${console_doc##*/}" | sed -n -E 's/.*-nextleg-[0-9]{4}-[0-9]{2}-[0-9]{2}([A-Z]{1,2})-.*/\1/p')"
        if [ -z "$console_letter" ]; then
            nonces_summary=unknown
        else
            stranded_csv=""
            # shellcheck disable=SC2016  # backtick span pattern, not a shell expansion
            for span in $(printf '%s\n' "$legs_line" | grep -oE '`[A-Za-z0-9_]+:[^`]*`' | tr -d '`'); do
                span_leg="${span%%:*}"
                span_rest="${span#*:}"
                span_nonce="${span_rest%%:*}"
                # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
                list_has "$span_leg" $held_legs || continue
                case "$span_nonce" in
                    "$console_letter"-*) ;;
                    *) stranded_csv="$(csv_add "$stranded_csv" "$span_leg")" ;;
                esac
            done
            if [ -n "$stranded_csv" ]; then
                nonces_summary="STRANDED:${stranded_csv}"
            else
                nonces_summary=ok
            fi
        fi
    else
        livestate_summary=unknown
        nonces_summary=unknown
    fi
fi

# HIMMEL-2999: name/model come from claude_sessions() (real
# /proc/<pid>/cmdline argv, NUL-delimited), never a flattened `pgrep -af`
# line -- free-text argv (a -p/--append-system-prompt value containing the
# literal substring "-n X") can no longer spoof procs=/models=.
# shellcheck source=../../lanes/lib/claude-sessions.sh
. "$REPO/scripts/lanes/lib/claude-sessions.sh"
sessions_out="$(claude_sessions)"
sessions_rc=$?
# HIMMEL-3002: rc=3 means the census itself succeeded but one or more live
# sessions had an unreadable cmdline -- the readable rows above are still
# trustworthy, so keep them (unlike a real scan failure, rc>1 and not 3,
# where the whole table is suspect and gets discarded below). CAVEAT
# (claude-sessions.sh, same ticket): pgrep's own fatal-error rc is ALSO 3,
# forwarded with no output printed first -- ceiling-conformance.sh already
# tells the two apart by whether sessions_out is empty at rc=3; mirror that
# here so census_failed below (HIMMEL-3145) is not blind to it.
census_failed=0
if [ "$sessions_rc" -gt 1 ] && { [ "$sessions_rc" -ne 3 ] || [ -z "$sessions_out" ]; }; then
    sessions_out=""
    census_failed=1
fi
sessions_lossy=0
case "$sessions_out" in
    '# lossy'|$'# lossy\n'*) sessions_lossy=1 ;;
esac
unreadable_n=0
if [ "$sessions_rc" -eq 3 ]; then
    unreadable_n="$(printf '%s\n' "$sessions_out" | grep -c '^# unreadable ')"
fi

# HIMMEL-3145: count sessions the console actually dispatched (leg_names,
# built from --legs above) against the census name, not a "-leg" spelling
# guess -- a filter that silently matches nothing must never render as 0.
leg_names_wrapped=",${leg_names},"
if [ "$census_failed" -eq 1 ] || [ -z "$leg_names" ]; then
    # A field that cannot be computed must say so (HIMMEL-3130 NOTFOUND-vs-
    # MISSING, HIMMEL-3002 unreadable=): procs=0 and procs=unknown must be
    # distinguishable, or a real scan failure reads as "no legs running".
    # An empty --legs is the same case: there is no dispatch set to count
    # against, so "0" would be a bare guess (and, worse, a matched-nothing
    # filter would print it as a clean 0 -- ",,".index(",name,") is always
    # 0), not a real count. procs= is only ever a count of the dispatched
    # set; without one, it cannot be computed either.
    procs=unknown
else
    procs="$(printf '%s\n' "$sessions_out" | awk -F'\t' -v names="$leg_names_wrapped" '
$1 ~ /^#/ { next }
NF < 4 { next }
{
    name = $2
    if (name == "") next
    if (index(names, "," name ",") == 0) next
    n++
}
END { print n+0 }')"
    # HIMMEL-3002: a degraded scan (rc=3) still counted every readable row
    # above -- append how many pids it could NOT read so the console sees
    # the table is incomplete rather than reading procs= as a clean, complete
    # count.
    [ "$unreadable_n" -gt 0 ] && procs="${procs},unreadable=${unreadable_n}"
fi

# HIMMEL-2976: same session table and leg filter as procs= above, bucketed by
# the tier its real --model argv names (opus/fable cost materially more per
# turn than the sonnet default - CLAUDE.md "raise effort before tier"). Any
# non-Claude id (e.g. a claudex gpt-* model) buckets under "other" rather than
# one unbounded per-model list. A leg matched by the same filter but carrying
# no --model token at all buckets under "unknown" (codex-2, HIMMEL-2976 round
# 1 CR) rather than falling out of every bucket while still counted in
# procs=.
# HIMMEL-3145: same dispatched-name filter as procs= above, same
# unknown-vs-empty distinction on a real census failure or an empty
# dispatch set (no --legs -- see procs= above).
if [ "$census_failed" -eq 1 ] || [ -z "$leg_names" ]; then
    models_summary=unknown
else
    models_summary="$(printf '%s\n' "$sessions_out" | awk -F'\t' -v names="$leg_names_wrapped" '
$1 ~ /^#/ { next }
NF < 4 { next }
{
    name = $2; model = $3
    if (name == "") next
    if (index(names, "," name ",") == 0) next
    if (model == "")             { c_unknown++ }
    else if (model ~ /^claude-opus-/)   c_opus++
    else if (model ~ /^claude-fable-/)  c_fable++
    else if (model ~ /^claude-sonnet-/) c_sonnet++
    else if (model ~ /^claude-haiku-/)  c_haiku++
    else                                c_other++
}
END {
    out = ""
    if (c_sonnet > 0)  out = out (out == "" ? "" : ",") "sonnet:" c_sonnet
    if (c_opus > 0)    out = out (out == "" ? "" : ",") "opus:" c_opus
    if (c_fable > 0)   out = out (out == "" ? "" : ",") "fable:" c_fable
    if (c_haiku > 0)   out = out (out == "" ? "" : ",") "haiku:" c_haiku
    if (c_other > 0)   out = out (out == "" ? "" : ",") "other:" c_other
    if (c_unknown > 0) out = out (out == "" ? "" : ",") "unknown:" c_unknown
    print out
}')"
    [ -n "$models_summary" ] || models_summary=none
    # HIMMEL-2999: /proc absent (macOS, git-bash) degrades claude_sessions()
    # to the old flattened-line parse -- flag it inline (no space, so the
    # tick line stays space-delimited) rather than silently reporting a scan
    # that could again be spoofed by free-text argv.
    [ "$sessions_lossy" -eq 0 ] || models_summary="${models_summary}(lossy)"
fi

# HIMMEL-2974: the same ps table, scanned for --autocompact drift against the
# leg invariant headed-arm.sh:391 refuses to launch without. The script's own
# last line is already "ceiling=ok" / "ceiling=DRIFT:<name,...>" so it drops
# into the tick line unprefixed.
ceiling_summary="$(bash "$REPO/scripts/lanes/ceiling-conformance.sh" 2>/dev/null | tail -n 1)" || ceiling_summary=""
[ -n "$ceiling_summary" ] || ceiling_summary="ceiling=?"

at_out="$(atq 2>/dev/null)" || at_out=""
at_count="$(printf '%s\n' "$at_out" | awk 'NF { n++ } END { print n+0 }')"

suite_alive=0
suite_dead=0
suite_tmp="${TICK_TMPDIR:-${TMPDIR:-/tmp}}"
for lock_dir in "$suite_tmp"/himmel-shell-suite-*.lock; do
    [ -d "$lock_dir" ] || continue
    owner_pid="$(grep -o 'pid=[0-9][0-9]*' "$lock_dir/owner" 2>/dev/null | head -n 1 | cut -d= -f2)"
    if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
        suite_alive=$((suite_alive + 1))
    else
        suite_dead=$((suite_dead + 1))
    fi
done
suites="${suite_alive}alive/${suite_dead}dead"

pr_out="$(cd "$REPO" 2>/dev/null && gh pr list --json number --jq '.[].number' 2>/dev/null)" || pr_out=""
prs=""
while IFS= read -r pr; do
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    prs="$(csv_add "$prs" "#$pr")"
done <<< "$pr_out"
[ -n "$prs" ] || prs=none

bank_cache="${TICK_BANK_CACHE_FILE:-/tmp/claude/statusline-usage-cache.json}"
fh="$(jq -r '.five_hour.utilization | if type == "number" then floor else empty end' "$bank_cache" 2>/dev/null)" || fh=""
wk="$(jq -r '.seven_day.utilization | if type == "number" then floor else empty end' "$bank_cache" 2>/dev/null)" || wk=""
case "$fh" in ''|*[!0-9]*) fh='?' ;; esac
case "$wk" in ''|*[!0-9]*) wk='?' ;; esac

bank_status="$(bun "$REPO/scripts/lanes/bank-status.ts" 2>/dev/null | grep '^claudex ' | head -n 1)" || bank_status=""
codex_fh="$(printf '%s\n' "$bank_status" | sed -n 's/.*5h used=\([0-9][0-9.]*\)%.*/\1/p')"
codex_wk="$(printf '%s\n' "$bank_status" | sed -n 's/.*weekly used=\([0-9][0-9.]*\)%.*/\1/p')"
if [ -n "$codex_fh" ] || [ -n "$codex_wk" ]; then
    [ -n "$codex_fh" ] || codex_fh='?'
    [ -n "$codex_wk" ] || codex_wk='?'
    codex="5h${codex_fh}/wk${codex_wk}"
elif [ -n "$bank_status" ]; then
    case "$bank_status" in
        *flat-rate*) codex=flat ;;
        *unmeasurable*|*' unknown '*) codex='?' ;;
        *) codex='?' ;;
    esac
else
    codex='?'
fi
bank="5h${fh}/wk${wk}/codex=${codex}"

fill="$(bash "$REPO/scripts/context-fill.sh" --percent 2>/dev/null)" || fill=""
case "$fill" in ''|*[!0-9]*) fill='?' ;; esac

inbox_summary=""
if [ -n "$root" ] && [ -d "$root/inbox" ]; then
    for inbox_file in "$root"/inbox/*.md; do
        [ -f "$inbox_file" ] || continue
        inbox_name="${inbox_file##*/}"
        inbox_name="${inbox_name%.md}"
        inbox_label="$(leg_label "$inbox_name")"
        inbox_size="$(wc -c < "$inbox_file" 2>/dev/null | tr -d '[:space:]')"
        case "$inbox_size" in ''|*[!0-9]*) inbox_size='?' ;; esac
        cursor="$(cat "$root/inbox/.cursor/$inbox_name" 2>/dev/null)" || cursor=0
        case "$cursor" in ''|*[!0-9]*) cursor=0 ;; esac
        inbox_summary="$(csv_add "$inbox_summary" "$inbox_label:$inbox_size/$cursor")"
    done
fi
[ -n "$inbox_summary" ] || inbox_summary=none

# fleet=<live>/<cap> + capacity= (HIMMEL-3167). The census is bank-preflight.sh's
# own -- it counts native + claudex + reserved against HIMMEL_FLEET_CAP inline,
# in a script that exits, so its `FLEET ... total=<n>/<cap>` line is the seam
# (a second count here would be the drift this field exists to end). Run as a
# plain read: CADENCE_BANK_LAUNCH stays empty so it can never refuse anything,
# and the ledger goes to /dev/null so a tick writes no cadence-ledger row.
# ponytail: bank-preflight still takes its fleet admission lock and prunes
# expired/consumed reservations while it counts, exactly as any bank read does.
fleet_out="$(CADENCE_BANK_LAUNCH='' CADENCE_BANK_LEDGER=/dev/null bash "$REPO/scripts/lib/bank-preflight.sh" 2>&1 >/dev/null)" || fleet_out=""
fleet_total="$(printf '%s\n' "$fleet_out" | sed -n 's/^bank-preflight: FLEET .*total=\([0-9][0-9]*\)\/\([0-9][0-9]*\)$/\1 \2/p' | tail -n 1)"
underfill_min="${TICK_UNDERFILL_MIN:-10}"
case "$underfill_min" in ''|*[!0-9]*) underfill_min=10 ;; esac
if [ -n "$fleet_total" ]; then
    fleet_live="${fleet_total% *}"
    fleet_cap="${fleet_total#* }"
    fleet="$fleet_live/$fleet_cap"
    # Last dispatch = newest <name>.launch.log under the console work dir: the
    # file's final write is the "konsole launched" line, so its mtime is the
    # real window start (the sig- file is touched again at release, and lock
    # dirs are re-stamped by every heartbeat). The dir is fleet-wide, like the
    # census, so any console's recent launch counts as capacity being filled.
    launch_dir="${TICK_LAUNCH_DIR:-}"
    if [ -z "$launch_dir" ]; then
        if [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR/himmel-console" ]; then
            launch_dir="$XDG_RUNTIME_DIR/himmel-console"
        else
            launch_dir="${TMPDIR:-/tmp}/himmel-console-$(id -u)"
        fi
    fi
    recent_launch="$(find "$launch_dir" -maxdepth 2 -name '*.launch.log' -mmin "-$underfill_min" 2>/dev/null | head -n 1)"  # gnu-ok: console kit is Linux/KDE-only (headed-arm.sh); the launch logs it reads exist nowhere else
    if [ $((10#$fleet_live)) -ge $((10#$fleet_cap)) ] || [ -n "$recent_launch" ]; then
        capacity=ok
    else
        capacity="UNDERFILLED:$((10#$fleet_cap - 10#$fleet_live))"
    fi
else
    fleet='?'
    capacity=unknown
fi

# orphans= (HIMMEL-2761): shell-tool wrappers older than TICK_ORPHAN_MIN minutes,
# joined to the owning session name -- a poll loop that outlives its wrapped
# leg (TaskStop on an agent does not reap the shell it spawned) surfaces at the
# next tick. Read-only; orphans=? when the process table cannot be read.
orphans_line="$(REPO="$REPO" bash "$HERE/orphan-loops.sh" 2>/dev/null | tail -n 1)" || orphans_line=""
orphans="${orphans_line#orphans=}"
[ -n "$orphans" ] || orphans='?'

# gql=<remaining>/<reset HH:MM> (HIMMEL-3197): the GitHub GraphQL budget, shared by
# every leg on the box, so a console sees exhaustion coming instead of hitting it.
# ghb_read is ONE real `gh api -i graphql` call -- `gh api rate_limit` reports the
# REST core bucket and misreports this one (HIMMEL-3190) -- so a tick pays exactly
# one extra request. gql=? when the headers are unreadable; never fails the tick.
gql='?'
if [ -f "$HERE/../../lib/gh-graphql-budget.sh" ]; then
    # shellcheck source=../../lib/gh-graphql-budget.sh
    . "$HERE/../../lib/gh-graphql-budget.sh"
    if ghb_read; then
        gql_reset='?'
        if [ -n "$GHB_RESET" ]; then
            gql_reset="$(date -d "@$GHB_RESET" +%H:%M 2>/dev/null || date -r "$GHB_RESET" +%H:%M 2>/dev/null)" || gql_reset=""
            [ -n "$gql_reset" ] || gql_reset='?'
        fi
        gql="$GHB_REMAINING/$gql_reset"
    fi
fi

# tick=ARMED|MISSING|UNKNOWN (HIMMEL-3144 D2): whether the periodic Monitor
# call that is SUPPOSED to invoke this script every 60 min (the console
# template's `## Monitors` tick row, armed in ACTION ZERO step 10) is
# actually armed. F never armed it and its absence was invisible to F, to
# this script, and to the handover -- the whole point of this field is to
# stop that.
# ponytail: this can only ever report UNKNOWN. A Monitor's armed/pending
# state lives inside the Claude Code session process that armed it -- there
# is no pidfile, `atq` entry, or lock on disk for it (unlike the `at_count`
# scheduled-job census above, which reads real OS state). tick.sh runs as a
# plain subprocess with no access to that in-session state, so ARMED/MISSING
# cannot be told apart from here; faking either would be worse than saying
# so. A console confirms the arm itself, in ACTION ZERO step 10's first
# bullet -- this field exists so a HUMAN or a later script reading a run of
# tick lines can see that no honest signal was available, rather than
# silently assuming one of the other fields would have caught it.
tick_status=UNKNOWN

# --burn (HIMMEL-2830): what each leg is actually paying per API call. The
# session name is the leg doc's stem without the -RESUME suffix - the same
# string headed-arm-leg.sh passes to `claude -n`, which is what leg-burn.sh
# matches on. A leg with no transcript yet (armed, not started) reports "?"
# rather than failing the tick.
burn_summary=""
if [ "$burn" -eq 1 ]; then
    for leg in $LEGS_SPLIT; do
        stem="${leg##*/}"; stem="${stem%.md}"; stem="${stem%-RESUME}"
        burn_label="$(leg_label "$leg")"
        burn_line="$(bash "$REPO/scripts/lanes/leg-burn.sh" "$stem" 2>/dev/null)" || burn_line=""
        if [ -z "$burn_line" ]; then
            # HIMMEL-3167: the session name has no -YYYY-MM-DD suffix (see
            # undated_stem above); retry with the name headed-arm-leg.sh used.
            burn_undated="$(undated_stem "$stem")"
            [ "$burn_undated" = "$stem" ] || burn_line="$(bash "$REPO/scripts/lanes/leg-burn.sh" "$burn_undated" 2>/dev/null)" || burn_line=""
        fi
        if [ -n "$burn_line" ]; then
            burn_ft="$(printf '%s\n' "$burn_line" | sed -n 's/.*first-turn=\([^ ]*\).*/\1/p')"
            burn_avg="$(printf '%s\n' "$burn_line" | sed -n 's/.*avg-ctx=\([^ ]*\).*/\1/p')"
            burn_summary="$(csv_add "$burn_summary" "$burn_label:${burn_ft:-?}/${burn_avg:-?}")"
        else
            burn_summary="$(csv_add "$burn_summary" "$burn_label:?")"
        fi
    done
    [ -n "$burn_summary" ] || burn_summary=none
fi

if [ "$verbose" -eq 1 ]; then
    printf 'TICK %s\n' "$clock"
    printf 'heartbeat: %s\n' "$hb"
    printf 'leg locks: %s\n' "$legs_summary"
    printf 'livestate: %s\n' "$livestate_summary"
    printf 'leg processes: %s\n' "$procs"
    printf 'leg models: %s\n' "$models_summary"
    printf 'scheduled jobs: %s\n' "$at_count"
    printf 'suite locks: %s\n' "$suites"
    printf 'open PRs: %s\n' "$prs"
    printf 'bank: %s\n' "$bank"
    printf 'fill: %s\n' "$fill"
    printf 'leg tails: %s\n' "$tails_summary"
    printf 'inbox size/cursor: %s\n' "$inbox_summary"
    printf 'tick monitor: %s\n' "$tick_status"
    # Printed only under --burn, so a plain --verbose tick is unchanged. An if,
    # not a `[ ] &&` one-liner: this is the last statement of the branch, so a
    # false test would become the script's exit status.
    if [ "$burn" -eq 1 ]; then
        printf 'leg burn (first-turn/avg-ctx): %s\n' "$burn_summary"
    fi
    printf 'fleet: %s\n' "$fleet"
    printf 'capacity: %s\n' "$capacity"
    printf 'gql: %s\n' "$gql"
    printf 'orphans: %s\n' "$orphans"
    printf 'nonces: %s\n' "$nonces_summary"
else
    # `tick=` is always appended (HIMMEL-3144); `burn=` stays APPENDED only
    # under --burn, after it. `fleet=`/`capacity=` (HIMMEL-3167) are appended
    # after everything else, so a consumer keyed on the existing fields and
    # their order sees them only as a tail. `gql=` (HIMMEL-3197) follows them, and
    # `orphans=` (HIMMEL-2761) follows, and `nonces=` (HIMMEL-3254) is last.
    if [ "$burn" -eq 1 ]; then
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s tick=%s burn=%s fleet=%s capacity=%s gql=%s orphans=%s nonces=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary" "$tick_status" "$burn_summary" "$fleet" "$capacity" "$gql" "$orphans" "$nonces_summary"
    else
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s tick=%s fleet=%s capacity=%s gql=%s orphans=%s nonces=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary" "$tick_status" "$fleet" "$capacity" "$gql" "$orphans" "$nonces_summary"
    fi
fi
