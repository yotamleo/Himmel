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
    local stem="$1" label
    stem="${stem##*/}"
    stem="${stem%.md}"
    label="$(printf '%s\n' "$stem" | sed -n 's/.*-leg\(N[0-9][0-9]*\).*/\1/p')"
    [ -n "$label" ] || label="$stem"
    printf '%s' "$label" | tr -c 'A-Za-z0-9_.-' '_'
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
for leg in $LEGS_SPLIT; do
    leg_doc="$(resolve_doc "$leg")"
    label="$(leg_label "$leg")"
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
    else
        livestate_summary=unknown
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
# where the whole table is suspect and gets discarded below).
if [ "$sessions_rc" -gt 1 ] && [ "$sessions_rc" -ne 3 ]; then
    sessions_out=""
fi
sessions_lossy=0
case "$sessions_out" in
    '# lossy'|$'# lossy\n'*) sessions_lossy=1 ;;
esac
unreadable_n=0
if [ "$sessions_rc" -eq 3 ]; then
    unreadable_n="$(printf '%s\n' "$sessions_out" | grep -c '^# unreadable ')"
fi

procs="$(printf '%s\n' "$sessions_out" | awk -F'\t' '
$1 ~ /^#/ { next }
NF < 4 { next }
{
    name = $2
    if (name !~ /^(HIMMEL|LUNA)-/) next
    if (name !~ /-leg/) next
    if (name ~ /-console$/) next
    n++
}
END { print n+0 }')"
# HIMMEL-3002: a degraded scan (rc=3) still counted every readable row above
# -- append how many pids it could NOT read so the console sees the table is
# incomplete rather than reading procs= as a clean, complete count.
[ "$unreadable_n" -gt 0 ] && procs="${procs},unreadable=${unreadable_n}"

# HIMMEL-2976: same session table and leg filter as procs= above, bucketed by
# the tier its real --model argv names (opus/fable cost materially more per
# turn than the sonnet default - CLAUDE.md "raise effort before tier"). Any
# non-Claude id (e.g. a claudex gpt-* model) buckets under "other" rather than
# one unbounded per-model list. A leg matched by the same filter but carrying
# no --model token at all buckets under "unknown" (codex-2, HIMMEL-2976 round
# 1 CR) rather than falling out of every bucket while still counted in
# procs=.
models_summary="$(printf '%s\n' "$sessions_out" | awk -F'\t' '
$1 ~ /^#/ { next }
NF < 4 { next }
{
    name = $2; model = $3
    if (name !~ /^(HIMMEL|LUNA)-/) next
    if (name !~ /-leg/) next
    if (name ~ /-console$/) next
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
# HIMMEL-2999: /proc absent (macOS, git-bash) degrades claude_sessions() to
# the old flattened-line parse -- flag it inline (no space, so the tick line
# stays space-delimited) rather than silently reporting a scan that could
# again be spoofed by free-text argv.
[ "$sessions_lossy" -eq 0 ] || models_summary="${models_summary}(lossy)"

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
    # Printed only under --burn, so a plain --verbose tick is unchanged. An if,
    # not a `[ ] &&` one-liner: this is the last statement of the branch, so a
    # false test would become the script's exit status.
    if [ "$burn" -eq 1 ]; then
        printf 'leg burn (first-turn/avg-ctx): %s\n' "$burn_summary"
    fi
else
    # The burn field is APPENDED only under --burn: a default tick line stays
    # byte-identical to what every console already parses.
    if [ "$burn" -eq 1 ]; then
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s burn=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary" "$burn_summary"
    else
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary"
    fi
fi
