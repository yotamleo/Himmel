#!/usr/bin/env bash
# scripts/handover/console-kit/grant-round.sh - HIMMEL-5058: the console grants
# ONE more /pr-check review round itself, on a persisted judge record, so the
# operator no longer hand-pastes `printf '2\n' > .git/cr-review-rounds/<b>.round`.
#
# Usage: grant-round.sh <pr> <new-head> <qid>
#
# A PR parks at the round-3 cap (review-round.sh, HIMMEL-2780/4600). The cap
# exists so a leg cannot buy itself rounds; the console is not the author, and
# an independent judge's record is a second non-author check (the go.sh
# --trust-reviewed trust model). Granted only when every condition holds:
#   (a) verdicts/<qid>/ holds a record for <new-head> that write-verdict.sh
#       wrote and signed (the HIMMEL-4984 mac), naming this PR (and this branch,
#       when it carries one), and every record in the qid parses;
#   (b) the PR is an OPEN same-repo type/slug branch that has reached the cap
#       (.round >= 3) and has .head state, i.e. there is a round to grant;
#   (c) <new-head> is the PR's live head, re-read under the counter lock;
#   (d) the qid is unconsumed: no *.verdicts file names it, so one record buys
#       one round across every branch (the judge_nogo_record / judge_scope_record
#       rule, HIMMEL-4720).
# The grant takes the review-counter lock review-round.sh start takes (the same
# namespace as cr-reset.sh), backs up the old .round, records the qid as
# `<head> <head> <qid>/<name>` in <branch>.verdicts (the consumption record the
# scans above read), lowers .round to 2 so the next `start` is the one round it
# counts as 3, and appends one audit line to cr-review-rounds/grant-round.audit.
# .head and .delta are left alone: the later delta scope is unchanged.
#
# Refused from a console leg (HIMMEL_CONSOLE_LEG) and a console relay
# (HIMMEL_CONSOLE_RELAY), as write-verdict.sh refuses them: a leg must not buy
# its own review rounds. The console is not a leg, so it runs this itself.
# ponytail: same-uid ceiling - the record mac key is readable by the same uid
# (HIMMEL-3578), and the leg marker is an environment variable; the upgrade path
# is a separate-uid verdict store. This does not cover HIMMEL-5109 (a NO-GO on a
# test- or comment-only descendant): that needs review-round.sh itself.
#
# Exit: 0 granted / 1 bad input / 3 leg or relay caller, or the verdict scope is
# unresolved / 4 no qualifying signed record / 5 lock or state error / 12 not
# grantable (fork, not OPEN, below the cap, no .head state) / 13 gh failed /
# 14 qid already consumed / 15 NEW_HEAD is not the live PR head.
# Seams: GRANT_ROUND_GH (gh), GRANT_ROUND_PRIMARY (the checkout whose git common
# dir holds the state; default this script's own repo), GRANT_ROUND_LOCK_LIB.
# Platform guard: POSIX bash 3.2+.
set -uo pipefail
# HIMMEL-3437: a relative-entry copy that is not the anchor's hands off to it.
case "${BASH_SOURCE[0]}" in */*) _ah_d="${BASH_SOURCE[0]%/*}" ;; *) _ah_d=. ;; esac
. "$_ah_d/../../cr/anchor-handoff.sh" || exit 2

usage() {
    echo "usage: grant-round.sh <pr> <new-head> <qid>" >&2
    exit 1
}
[ "$#" -eq 3 ] || usage
PR=$1 HEAD_SHA=$2 QID=$3
case "$PR" in ''|0*|*[!0-9]*) echo "grant-round: <pr> must be a PR number without a leading zero (got '$PR')" >&2; exit 1 ;; esac
case "$HEAD_SHA" in *[!0123456789abcdef]*) echo "grant-round: <new-head> must be the full 40-char lowercase hex sha" >&2; exit 1 ;; esac
[ "${#HEAD_SHA}" -eq 40 ] || { echo "grant-round: <new-head> must be the full 40-char lowercase hex sha" >&2; exit 1; }
case "$QID" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo "grant-round: qid '$QID' is not a path segment ([A-Za-z0-9][A-Za-z0-9._-]*)" >&2; exit 1 ;; esac

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$HERE/../../lib"
# shellcheck source=scripts/lib/go-gate.sh
# shellcheck disable=SC1091
if ! . "$LIB/go-gate.sh" 2>/dev/null || ! declare -F console_leg >/dev/null 2>&1 \
        || ! declare -F go_verdict_snapshot >/dev/null 2>&1 || ! declare -F go_verdict_mac_ok_text >/dev/null 2>&1; then
    echo "grant-round: cannot load scripts/lib/go-gate.sh - refusing (the leg check must fail closed)" >&2
    exit 3
fi
if console_leg; then
    echo "grant-round: refusing - this is a console-spawned leg (HIMMEL_CONSOLE_LEG is set); a leg never buys its own review round." >&2
    exit 3
fi
case "$(printf '%s' "${HIMMEL_CONSOLE_RELAY:-}" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]')" in
    ''|0|false|off|no) ;;
    *) echo "grant-round: refusing - this is a console relay (HIMMEL_CONSOLE_RELAY is set); a relay never grants a round." >&2; exit 3 ;;
esac
# shellcheck source=scripts/lib/git-clean.sh
. "$LIB/git-clean.sh" 2>/dev/null && git_env_scrub
# shellcheck source=scripts/lib/handover-path.sh
# shellcheck disable=SC1091
. "$LIB/handover-path.sh" 2>/dev/null || { echo "grant-round: cannot load scripts/lib/handover-path.sh" >&2; exit 3; }

ANCHOR="$(cd "$HERE/../../.." && pwd)"
PRIMARY="${GRANT_ROUND_PRIMARY:-$ANCHOR}"
GH="${GRANT_ROUND_GH:-gh}"
LOCK_LIB="${GRANT_ROUND_LOCK_LIB:-$LIB/shared-branch-lock.sh}"

# --- the PR ----------------------------------------------------------------
pr_json() { (cd "$PRIMARY" && "$GH" pr view "$PR" --json headRefName,headRefOid,isCrossRepository,state 2>/dev/null); }
view="$(pr_json)" || { echo "grant-round: gh pr view $PR failed" >&2; exit 13; }
branch="$(printf '%s' "$view" | jq -r '.headRefName // empty')"
live_head="$(printf '%s' "$view" | jq -r '.headRefOid // empty')"
[ "$(printf '%s' "$view" | jq -r '.isCrossRepository')" = "false" ] || { echo "grant-round: PR $PR is from a fork; refusing" >&2; exit 12; }
[ "$(printf '%s' "$view" | jq -r '.state // empty')" = "OPEN" ] || { echo "grant-round: PR $PR is not OPEN" >&2; exit 12; }
if ! [[ "$branch" =~ ^[a-z]+/[A-Za-z0-9._+-]+$ ]] || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
    echo "grant-round: PR $PR head branch '$branch' is not a type/slug branch" >&2
    exit 12
fi
if [ "$live_head" != "$HEAD_SHA" ]; then
    echo "grant-round: $HEAD_SHA is not PR $PR's live head ($live_head); a record for an older head grants nothing" >&2
    exit 15
fi

# --- (a) the signed record ---------------------------------------------------
ROOT="$(go_resolve_root "$ANCHOR")" && [ -n "$ROOT" ] || { echo "grant-round: cannot resolve the handover root" >&2; exit 3; }
SCOPE="$(go_verdict_scope "$ANCHOR")" && [ -n "$SCOPE" ] || { echo "grant-round: cannot resolve this repo's verdict scope" >&2; exit 3; }
vdir="$ROOT"
[ -d "$vdir" ] && [ ! -L "$vdir" ] || { echo "grant-round: handover root '$vdir' is not a plain directory" >&2; exit 4; }
for seg in "${SCOPE%%/*}" "${SCOPE#*/}" verdicts "$QID"; do
    vdir="$vdir/$seg"
    if [ ! -d "$vdir" ] || [ -L "$vdir" ]; then
        echo "grant-round: no verdict record directory for qid $QID" >&2
        exit 4
    fi
done
re_session='^writer-session: [A-Za-z0-9-]+$'
re_written='^written-at: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
record=""
for f in "$vdir"/*.md; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ -L "$f" ] || [ ! -f "$f" ]; then echo "grant-round: $f is not a plain file - qid $QID refused" >&2; exit 4; fi
    name="${f##*/}"; name="${name%.md}"
    case "$name" in ''|[!A-Za-z0-9]*|*[!A-Za-z0-9._-]*) echo "grant-round: record name '$name' is not a path segment - qid $QID refused" >&2; exit 4 ;; esac
    if ! go_verdict_snapshot "$f"; then
        echo "grant-round: $f cannot be read whole (unreadable, empty or NUL) - qid $QID refused" >&2
        exit 4
    fi
    snap=$GO_VERDICT_SNAP
    l1="" l2="" l3="" l4="" l5="" l6="" l7="" l8="" l9="" l10="" l11=""
    # shellcheck disable=SC2034  # l9 is the blank line the read must consume
    { IFS= read -r l1; IFS= read -r l2; IFS= read -r l3; IFS= read -r l4
      IFS= read -r l5; IFS= read -r l6; IFS= read -r l7; IFS= read -r l8
      IFS= read -r l9; IFS= read -r l10; IFS= read -r l11; } <<EOF_SNAP 2>/dev/null
$snap
EOF_SNAP
    if [ "$l1" != "# VERDICT $QID - $name" ] || [ -n "$l2$l5$l7" ] || [ "$l6" != "## Verdict" ] \
        || ! [[ $l3 =~ $re_session ]] || ! [[ $l4 =~ $re_written ]]; then
        echo "grant-round: $f does not parse as a write-verdict.sh record - qid $QID refused" >&2
        exit 4
    fi
    # shellcheck disable=SC2016  # the backticks are the verdict line's literal text
    word="$(printf '%s\n' "$l8" | sed -nE 's/^\*\*(GO|NO-GO)\*\* for head `([0-9a-f]{40})`\.?$/\1 \2/p')"
    [ -n "$word" ] || { echo "grant-round: $f has no verdict line - qid $QID refused" >&2; exit 4; }
    [ -z "$record" ] || continue
    [ "${word#* }" = "$HEAD_SHA" ] || continue
    go_verdict_mac_ok_text "$snap" "$SCOPE" "$QID" "$name" || continue
    [ "$l10" = "pr: $PR" ] || continue
    case "$l11" in 'branch: '*) [ "${l11#branch: }" = "$branch" ] || continue ;; esac
    record="$QID/$name"
done
if [ -z "$record" ]; then
    echo "grant-round: no signed write-verdict.sh record in $QID names head $HEAD_SHA for PR $PR (branch $branch)" >&2
    exit 4
fi

# --- state, under the review-counter lock ------------------------------------
common="$(git -C "$PRIMARY" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
    || { echo "grant-round: cannot resolve the git common dir" >&2; exit 5; }
dir="$common/cr-review-rounds"
round_f="$dir/$branch.round" head_f="$dir/$branch.head" verd_f="$dir/$branch.verdicts"
audit_f="$dir/grant-round.audit"
[ -f "$LOCK_LIB" ] || { echo "grant-round: counter lock library missing at $LOCK_LIB" >&2; exit 5; }
if ! (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$LOCK_LIB" acquire-wait "." "$branch" "grant-round" 10 60 >/dev/null 2>&1); then
    echo "grant-round: cannot acquire the review-counter lock for $branch" >&2
    exit 5
fi
owner="$(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status "." "$branch" 2>/dev/null)"
case "$owner" in
    '{"pid":'*) ;;
    *)
        # We just acquired it, so a plain release is ours to make: release-if-owner
        # needs an owner and an owner-less lock is never TTL-reclaimed.
        (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$LOCK_LIB" release "." "$branch" >/dev/null 2>&1) || true
        echo "grant-round: counter lock holder state for $branch is missing or unreadable; refusing" >&2
        exit 5
        ;;
esac
# A qid is consumed across branches, so the consumed-qid scan needs one lock all grants share.
glock="_grant-round-qid-scan"
if ! (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round SHARED_BRANCH_LOCK_HOLDER_PID=$$ \
        bash "$LOCK_LIB" acquire-wait "." "$glock" "grant-round" 10 60 >/dev/null 2>&1); then
    (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$LOCK_LIB" release-if-owner "." "$branch" "$owner" >/dev/null 2>&1) || true
    echo "grant-round: cannot acquire the grant-round qid lock" >&2
    exit 5
fi
gowner="$(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status "." "$glock" 2>/dev/null)"
case "$gowner" in
    '{"pid":'*) ;;
    *)
        # Same as the branch lock above: release both plainly, never scan unowned.
        (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$LOCK_LIB" release "." "$glock" >/dev/null 2>&1) || true
        (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
            bash "$LOCK_LIB" release-if-owner "." "$branch" "$owner" >/dev/null 2>&1) || true
        echo "grant-round: qid lock holder state is missing or unreadable; refusing" >&2
        exit 5
        ;;
esac
release() {
    (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$LOCK_LIB" release-if-owner "." "$glock" "$gowner" >/dev/null 2>&1) || true
    (cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round \
        bash "$LOCK_LIB" release-if-owner "." "$branch" "$owner" >/dev/null 2>&1) || true
}
fail() { release; echo "grant-round: $2" >&2; exit "$1"; }

# (d) consumed: any *.verdicts naming the qid. Only rc 1 means "not consumed".
scan=0
grep -rqsF --include='*.verdicts' " $QID/" "$dir" 2>/dev/null || scan=$?
[ "$scan" -ne 0 ] || fail 14 "qid $QID is already consumed (a *.verdicts file names it); one record buys one round"
[ "$scan" -eq 1 ] || [ ! -d "$dir" ] || fail 5 "cannot scan $dir for a consumed $QID (grep rc $scan)"

# (b) a round to grant.
[ -f "$round_f" ] && [ ! -L "$round_f" ] && [ -f "$head_f" ] && [ ! -L "$head_f" ] \
    || fail 12 "no review-round .round/.head state for $branch; nothing to grant"
round="$(cat "$round_f" 2>/dev/null)"
case "$round" in ''|*[!0-9]*) fail 5 "invalid counter state in $round_f - refusing to rewrite it" ;; esac
[ "$round" -ge 3 ] || fail 12 "$branch is at round $round, below the cap of 3; there is no round to grant"
{ [ ! -e "$verd_f" ] || { [ -f "$verd_f" ] && [ ! -L "$verd_f" ]; }; } || fail 5 "$verd_f is not a plain file"

# (c) the head again, under the lock: do not mutate against an outdated PR head.
view2="$(pr_json)" || fail 13 "gh pr view $PR failed"
[ "$(printf '%s' "$view2" | jq -r '.headRefOid // empty')" = "$HEAD_SHA" ] \
    && [ "$(printf '%s' "$view2" | jq -r '.headRefName // empty')" = "$branch" ] \
    || fail 15 "PR $PR head moved while the lock was taken"
[ "$(printf '%s' "$view2" | jq -r '.state // empty')" = "OPEN" ] \
    && [ "$(printf '%s' "$view2" | jq -r '.isCrossRepository')" = "false" ] \
    || fail 12 "PR $PR is no longer an open same-repo PR"

ts="$(date +%Y%m%dT%H%M%S)-$$"
cp -p "$round_f" "$round_f.bak-$ts" || fail 5 "could not back up $round_f"
tmp_verd="$verd_f.tmp.$$"
pre_verd="$verd_f.pre.$$"
if [ -e "$verd_f" ]; then cp -p "$verd_f" "$pre_verd" || fail 5 "could not back up $verd_f"; fi
tmp_round="$round_f.tmp.$$"
# Both new files are fully written before either is renamed, so the only window
# left is the two renames. A SIGKILL inside it leaves the qid spent with no round
# granted (fail-closed: no extra round); the .round backup and cr-reset recover it.
if ! { cat "$verd_f" 2>/dev/null || [ ! -e "$verd_f" ]; } > "$tmp_verd" \
    || ! printf '%s %s %s\n' "$HEAD_SHA" "$HEAD_SHA" "$record" >> "$tmp_verd" \
    || ! printf '2\n' > "$tmp_round"; then
    rm -f "$tmp_verd" "$tmp_round" "$pre_verd"
    fail 5 "cannot stage the grant for $branch"
fi
# The audit line goes in before either rename: a failed append then changes nothing.
audit_tail="pr=$PR branch=$branch head=$HEAD_SHA record=$record"
if ! printf '%s %s round=%s->2 by=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$audit_tail" "$round" \
        "${CLAUDE_CODE_SESSION_ID:-unknown}" >> "$audit_f"; then
    rm -f "$tmp_verd" "$tmp_round" "$pre_verd"
    fail 5 "cannot append the audit line to $audit_f; nothing was granted"
fi
# The qid must not stay spent on a round that was never granted; the audit line then says so.
# A signal after the .round rename must keep the grant: .round was >= 3 under the lock, so 2 means it landed.
undo() {
    [ "$(cat "$round_f" 2>/dev/null)" = 2 ] && return 0
    if [ -e "$pre_verd" ]; then mv "$pre_verd" "$verd_f"; else rm -f "$verd_f"; fi
    rm -f "$tmp_round"
    printf '%s ROLLED-BACK %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$audit_tail" >> "$audit_f" 2>/dev/null || true
}
# Both locks carry a 60 s TTL and the gh read above can stall past it, so a waiter
# may have reclaimed one; shared-branch-lock.sh requires a holder to re-verify it
# still owns the lock immediately before its decisive action. Nothing is renamed
# yet, so a lost lock refuses with the state untouched (release-if-owner leaves
# the new holder's lock alone).
now_owner="$(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status "." "$branch" 2>/dev/null)"
now_gowner="$(cd "$PRIMARY" && SHARED_BRANCH_LOCK_NS=himmel-cr-review-round bash "$LOCK_LIB" status "." "$glock" 2>/dev/null)"
if [ "$now_owner" != "$owner" ] || [ "$now_gowner" != "$gowner" ]; then
    rm -f "$tmp_verd" "$tmp_round" "$pre_verd" "$round_f.bak-$ts"
    printf '%s ROLLED-BACK lock-lost %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$audit_tail" >> "$audit_f" 2>/dev/null || true
    fail 5 "lost the review-counter or qid lock before the renames; nothing was granted"
fi
trap 'undo; release; exit 5' INT TERM HUP
if ! mv "$tmp_verd" "$verd_f"; then
    rm -f "$tmp_verd"
    undo
    fail 5 "cannot record the judge record $record as consumed for $branch"
fi
if ! mv "$tmp_round" "$round_f"; then
    undo
    fail 5 "cannot persist the granted round for $branch"
fi
trap - INT TERM HUP
rm -f "$pre_verd"
release
echo "granted one review round on $branch (PR $PR): round $round -> 2, $record consumed, backup .round.bak-$ts"
exit 0
