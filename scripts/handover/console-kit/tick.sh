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
usage: tick.sh [--verbose] [--doc PATH] [--token TOKEN] [--legs "DOC ..."]
               [--handover-dir DIR] [--repo DIR]

env equivalents: DOC TOKEN LEGS HANDOVER_DIR REPO
Relative DOC/LEGS resolve under the handover root; include the bucket prefix
when HANDOVER_DIR names a global state root.
USAGE
}

verbose=0
DOC="${DOC:-}"
TOKEN="${TOKEN:-}"
LEGS="${LEGS:-}"
REPO="${REPO:-$(cd "$HERE/../../.." && pwd)}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
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
if [ -n "$DOC" ] && [ -n "$TOKEN" ]; then
    console_doc="$(resolve_doc "$DOC")"
    if bash "$REPO/scripts/handover/queue-lock.sh" heartbeat "$console_doc" "$TOKEN" >/dev/null 2>&1; then
        hb=ok
    else
        hb=fail
    fi
fi

legs_summary=""
tails_summary=""
for leg in $LEGS; do
    leg_doc="$(resolve_doc "$leg")"
    label="$(leg_label "$leg")"
    lock_status=MISSING
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
    fi
    legs_summary="$(csv_add "$legs_summary" "$label:$lock_status")"
    tails_summary="$(csv_add "$tails_summary" "$label:$tail_status")"
done
[ -n "$legs_summary" ] || legs_summary=none
[ -n "$tails_summary" ] || tails_summary=none

proc_out="$(pgrep -af 'claude' 2>/dev/null)" || proc_out=""
procs="$(printf '%s\n' "$proc_out" | awk '/claude / && / -n (HIMMEL|LUNA)-/ && /-leg/ && !/-console/ { n++ } END { print n+0 }')"

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

if [ "$verbose" -eq 1 ]; then
    printf 'TICK %s\n' "$clock"
    printf 'heartbeat: %s\n' "$hb"
    printf 'leg locks: %s\n' "$legs_summary"
    printf 'leg processes: %s\n' "$procs"
    printf 'scheduled jobs: %s\n' "$at_count"
    printf 'suite locks: %s\n' "$suites"
    printf 'open PRs: %s\n' "$prs"
    printf 'bank: %s\n' "$bank"
    printf 'fill: %s\n' "$fill"
    printf 'leg tails: %s\n' "$tails_summary"
    printf 'inbox size/cursor: %s\n' "$inbox_summary"
else
    printf 'TICK %s hb=%s legs=%s procs=%s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s\n' \
        "$clock" "$hb" "$legs_summary" "$procs" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary"
fi
