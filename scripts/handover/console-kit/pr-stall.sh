#!/usr/bin/env bash
# pr-stall.sh — lists open PRs that are stuck, with the class and the action,
# and maps each to the leg that owns it through the fleet manifest.
#
#   pr-stall.sh [--repo owner/name] [--manifest fleet.json] [--conflict-min N]
#               [--noci-min N] [--slow-min M] [--idle-h H] [--notify]
#
# Prints one line per stuck PR, then one summary line:
#   STALL <pr> <class> <leg-label|-> <detail>
#   STALL-SUMMARY stuck=<N> queue=<queued+in_progress runs>
#
# Classes, most actionable first (a PR carrying several prints the first and
# lists the rest as `also=` in the detail):
#   conflict  mergeable=CONFLICTING or mergeStateStatus=DIRTY. GitHub starts no
#             pull_request CI on a conflicting PR, so the leg waits for CI that
#             never comes. Action: merge origin/main (merge commit, no rebase).
#   no-ci     not conflicting, zero check runs, and the PR last updated (the
#             push) more than --noci-min minutes ago (default 10). Action: empty
#             re-push or workflow re-run. mergeable UNKNOWN (GitHub computes it
#             lazily after a push) is re-read once, then treated as not-yet-
#             known: never conflict, and never no-ci.
#   ci-slow   a check IN_PROGRESS or QUEUED longer than --slow-min minutes
#             (default 45). Report only; the detail carries the runner queue
#             depth so saturation reads differently from a hang.
#   idle      no update for --idle-h hours (default 3). Report only.
# --conflict-min is accepted for symmetry with the ticket's wording but a
# conflict is reported at once: its signal is not time-dependent.
#
# --notify sends the owning leg the action through inbox-send.sh, for conflict
# and no-ci only (ci-slow and idle are for the console), ONE message per
# (pr, class, head), recorded in ${XDG_RUNTIME_DIR:-/tmp}/himmel-console/
# pr-stall.sent so a repeat run does not re-send. A PR with no leg in the
# manifest is listed with leg `-` and never sent to.
#
# PR to leg: a manifest leg owns a PR when its doc names the PR's head branch
# or `PR <n>` / `pull/<n>`. Session name: leg-identity.sh's first name.
#
# Exit: 0 (also when nothing is stuck); 3 when gh itself fails, with
# `STALL-UNKNOWN gh failed` on stdout, never a silent empty list; 2 usage.
#
# Test seams: PR_STALL_NOW (ISO-8601 clock), PR_STALL_INBOX_SEND (sender).
#
# ponytail: updatedAt stands in for the push time, so a comment resets the
# no-ci clock and delays detection; upgrade: read the head's push event from
# the PR timeline.
# tick.sh folds the STALL rows into a stall= field (cached, fail-soft) and
# console-wait.sh wakes once per new conflict or no-ci token.
#
# PLATFORM GUARD: no .ps1 twin, by design — the console kit is Linux-only
# (GNU date). needs gh and jq.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"

usage() {
    printf 'usage: pr-stall.sh [--repo owner/name] [--manifest fleet.json] [--conflict-min N] [--noci-min N] [--slow-min M] [--idle-h H] [--notify]\n' >&2
    exit 2
}

repo="yotamleo/Himmel"; manifest=""; noci_min=10; slow_min=45; idle_h=3; notify=0
num() { case "$1" in ''|*[!0-9]*) usage ;; esac; }
while [ "$#" -gt 0 ]; do
    case "$1" in
        --repo) [ "$#" -ge 2 ] || usage; repo="$2"; shift 2 ;;
        --manifest) [ "$#" -ge 2 ] || usage; manifest="$2"; shift 2 ;;
        --conflict-min) [ "$#" -ge 2 ] || usage; num "$2"; shift 2 ;;
        --noci-min) [ "$#" -ge 2 ] || usage; num "$2"; noci_min=$((10#$2)); shift 2 ;;
        --slow-min) [ "$#" -ge 2 ] || usage; num "$2"; slow_min=$((10#$2)); shift 2 ;;
        --idle-h) [ "$#" -ge 2 ] || usage; num "$2"; idle_h=$((10#$2)); shift 2 ;;
        --notify) notify=1; shift ;;
        *) usage ;;
    esac
done

if [ -n "${PR_STALL_NOW:-}" ]; then
    # swallow-ok: stderr only; a failed date exits through usage
    now="$(date -u -d "$PR_STALL_NOW" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$PR_STALL_NOW" +%s 2>/dev/null)" || usage  # gnu-ok: GNU -d paired with the BSD -j -f fallback
else
    now="$(date -u +%s)"
fi

unknown() { printf 'STALL-UNKNOWN gh failed\n'; exit 3; }

fields="number,headRefName,headRefOid,mergeable,mergeStateStatus,statusCheckRollup,updatedAt,createdAt"
# swallow-ok: stderr only; every failed read below exits 3 through unknown
list="$(gh pr list -R "$repo" --state open --limit 1000 --json "$fields" 2>/dev/null)" || unknown
# swallow-ok: stderr only; a failed read exits 3 through unknown
runs="$(gh run list -R "$repo" --limit 50 --json status 2>/dev/null)" || unknown
# swallow-ok: stderr only; a failed read exits 3 through unknown
queue="$(printf '%s' "$runs" | jq '[.[] | select(.status == "queued" or .status == "in_progress")] | length' 2>/dev/null)" || unknown
# swallow-ok: stderr only; a failed read exits 3 through unknown
numbers="$(printf '%s' "$list" | jq -r '.[].number' 2>/dev/null)" || unknown

# leg_for <pr> <branch> -> "<label>\t<session>" or empty
leg_for() {
    [ -n "$manifest" ] && [ -r "$manifest" ] || return 0
    local doc label rows
    # swallow-ok: an unreadable manifest leaves the PR unmapped (leg -), never mapped wrongly
    rows="$(jq -r '.legs[]? | [.doc, (.label // "-")] | @tsv' "$manifest" 2>/dev/null)"
    while IFS="$TAB" read -r doc label; do
        [ -r "$doc" ] || continue
        # whole branch token only: feat/foo must not match a doc naming feat/foo-extra
        if grep -oE '[A-Za-z0-9._/+-]+' "$doc" 2>/dev/null | grep -qxF -- "$2" || grep -Eq -- "(PR |pull/)#?$1([^0-9]|$)" "$doc" 2>/dev/null; then
            printf '%s\t%s\n' "$label" "$(leg_identity "$doc" | cut -f2 | cut -d, -f1)"
            return 0
        fi
    done <<EOF
$rows
EOF
}

# classify: stdin one PR json -> "<classes,comma>\t<detail per class ; separated>"
# shellcheck disable=SC2016  # jq program, not shell
JQ_CLASSIFY='
def secs($t): if ($t // "") == "" or ($t | startswith("0001")) then null else ($t | fromdateiso8601) end;
def conflicting: .mergeable == "CONFLICTING" or .mergeStateStatus == "DIRTY";
(.statusCheckRollup // [] | map(select(.__typename == "CheckRun"))) as $runs
| secs(.updatedAt) as $upd
| (($now - $upd) / 60 | floor) as $age_min
| [ $runs[] | select(.status == "IN_PROGRESS" or .status == "QUEUED")
    | (($now - (secs(.startedAt) // $upd)) / 60 | floor) ] as $busy
| [
    (if conflicting then ["conflict", "mergeStateStatus=\(.mergeStateStatus) head=\(.headRefOid[0:9]) action=merge origin/main (merge commit, no rebase, no force-push)"] else empty end),
    (if ($runs | length) == 0 and (conflicting | not) and .mergeable != "UNKNOWN" and $age_min >= $noci then ["no-ci", "0 check runs \($age_min)m after the push head=\(.headRefOid[0:9]) action=empty re-push or workflow re-run"] else empty end),
    (if ($busy | length) > 0 and ($busy | max) >= $slow then ["ci-slow", "\($busy | length) check(s) in flight, oldest \($busy | max)m queue=\($queue)"] else empty end),
    (if $age_min >= ($idle * 60) then ["idle", "no update for \($age_min / 60 | floor)h"] else empty end)
  ] as $c
| if ($c | length) == 0 then empty
  else "\($c | map(.[0]) | join(","))\t\($c[0][1])"
  end'

TAB="$(printf '\t')"
stuck=0
sent_dir="${XDG_RUNTIME_DIR:-/tmp}/himmel-console"
sent_file="$sent_dir/pr-stall.sent"
send="${PR_STALL_INBOX_SEND:-$HERE/inbox-send.sh}"
# one notifying run at a time, so check-send-record below cannot double-send
# ponytail: no flock binary (stock macOS) notifies unlocked, so two concurrent runs can
# double-send; upgrade path = a mkdir lock.
if [ "$notify" = 1 ]; then
    # prim-ok: a blocking lock held on fd 9 until the script exits; with_lock wraps one command
    if ! { mkdir -p "$sent_dir" && exec 9>"$sent_dir/pr-stall.lock" && { ! command -v flock >/dev/null 2>&1 || flock 9; }; }; then
        printf 'pr-stall: cannot take the notify lock, listing without --notify\n' >&2
        notify=0
    fi
fi

for n in $numbers; do
    # swallow-ok: stderr only; a failed select exits 3 through unknown
    pr="$(printf '%s' "$list" | jq -c --argjson n "$n" '.[] | select(.number == $n)' 2>/dev/null)" || unknown
    # swallow-ok: a failed mergeable read skips the re-read; the classify step below fails closed
    if [ "$(printf '%s' "$pr" | jq -r '.mergeable' 2>/dev/null)" = "UNKNOWN" ]; then
        # swallow-ok: stderr only; a failed read exits 3 through unknown
        pr="$(gh pr view "$n" -R "$repo" --json "$fields" 2>/dev/null)" || unknown
    fi
    # swallow-ok: stderr only; a failed classify exits 3 through unknown
    res="$(printf '%s' "$pr" | jq -r --argjson now "$now" --argjson noci "$noci_min" --argjson slow "$slow_min" --argjson idle "$idle_h" --argjson queue "$queue" "$JQ_CLASSIFY" 2>/dev/null)" || unknown
    [ -n "$res" ] || continue
    classes="${res%%"$TAB"*}"; detail="${res#*"$TAB"}"
    class="${classes%%,*}"
    also=""; [ "$class" = "$classes" ] || also=" also=${classes#*,}"
    branch="$(printf '%s' "$pr" | jq -r '.headRefName')"; head="$(printf '%s' "$pr" | jq -r '.headRefOid')"
    leg="$(leg_for "$n" "$branch")"
    label="-"; session=""
    if [ -n "$leg" ]; then label="${leg%%"$TAB"*}"; session="${leg#*"$TAB"}"; fi
    stuck=$((stuck + 1))
    printf 'STALL %s %s %s %s%s\n' "$n" "$class" "$label" "$detail" "$also"

    [ "$notify" = 1 ] && [ -n "$session" ] || continue
    case "$class" in conflict|no-ci) ;; *) continue ;; esac
    key="$repo $n $class $head"
    grep -qxF -- "$key" "$sent_file" 2>/dev/null && continue
    action="${detail#*action=}"
    if "$send" "$session" "PR $n is stuck ($class): $action" >/dev/null 2>&1; then
        mkdir -p "$sent_dir" && printf '%s\n' "$key" >> "$sent_file"
    else
        printf 'pr-stall: notify of PR %s (%s) failed, will retry next run\n' "$n" "$class" >&2
    fi
done

printf 'STALL-SUMMARY stuck=%s queue=%s\n' "$stuck" "$queue"
exit 0
