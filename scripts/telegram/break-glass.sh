#!/usr/bin/env bash
# break-glass.sh <op> <arg> <time> — operator break-glass ops (HIMMEL-5047).
#
# Reached ONLY through auto-action.sh, which the trusted Telegram bridge spawns
# on the HIMMEL-4820 typed path (operator id + allowed chat + whole,
# non-forwarded, non-caption message + a per-op TELEGRAM_AUTO_ACTIONS name).
# Every op here except station-status is also behind the bridge's one-time
# `/confirm <code>` step (auto-action.ts CONFIRM_OPS); this script never sees
# an unconfirmed mutating request from the bridge.
#
# Ops (arg "-" means none):
#   station-status    -        read-only snapshot: load, memory, bank, consoles,
#                              last tick, waiter heartbeats, primary state
#   revert-main       <pr>     open GitHub's revert PR for the PR that is the
#                              default branch's HEAD, merge it with --admin
#                              (break-glass: operator-initiated, confirm-coded,
#                              audited) while it is still HEAD, then sync the
#                              primary
#   repin-hooks       -        fast-forward the primary to origin/<default>; the
#                              HIMMEL-2528 monotonic re-pin heals each session's
#                              hook-integrity pin once its hooks equal the tip
#   launch-leg        <N-label> <bypass|->
#                              launch ONE leg of the current console's fleet in
#                              its own linked worktree (resume a manifest leg, or
#                              start a fresh one from the console-written
#                              launch-<label>.sh whose sha256 the console
#                              recorded); with bypass, ONLY
#                              HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 is exported
#   cr-reset          <pr>     scripts/cr/cr-reset.sh: back up and reset the PR
#                              branch's review-round counters
#   close-wrapped     <N-label|-> console-kit/close-wrapped-leg.sh on that leg,
#                              or on every fleet leg (it refuses unless the
#                              lock is free and the tail is WRAPPED)
#   relaunch-console  <name>   `console.sh next --arm --name <name>` from the
#                              primary, every *_OK scrubbed (no bypass flag)
#   restart-bridge    -        restart telegram-bridge.service 3 s from now, so
#                              the reply and audit line land first
#   allow-rule        <id>     (HIMMEL-5048) add ONE permission allow rule to the
#                              primary's untracked local settings file. The rule
#                              text comes only from the checked-in registry
#                              allow-rules.json (id -> exact text), never from the
#                              message; idempotent, and the old file is backed up
#                              (<file>.bak-<epoch>-<pid>) before every write
#
# Exit codes:
#   (allow-rule: 20 registry missing / 26 id not in the registry or its entry is
#   not one clean line of text / 27 target unreadable, not the expected shape, or
#   the write failed)
#   0 done / 1 bad input (close-wrapped: a named close refused) / 2 unknown
#   op / 5, 12, 13 also relayed from cr-reset.sh / 12 PR not revertable (not merged, or
#   not on the default branch) / 13 gh or fetch failed / 18 merge or ff failed
#   / 25 revert merged but its record could not be written
#   / 19 agent marker (CLAUDECODE) / 20 prerequisite missing (unit, script) /
#   21 primary not on the default branch or has tracked changes / 22 primary
#   diverged from origin / 23 leg label does not resolve to exactly one leg
#   with a present linked worktree / 24 hooks still differ after the sync
#
# Seams (tests): BREAK_GLASS_PRIMARY (primary checkout), BREAK_GLASS_GH (gh),
# BREAK_GLASS_SYSTEMCTL (systemctl), BREAK_GLASS_RESTART_CMD,
# BREAK_GLASS_CONSOLE_CMD, BREAK_GLASS_LEG_CMD, BREAK_GLASS_BANK_CMD,
# BREAK_GLASS_FLEET (fleet manifest), BREAK_GLASS_STATE (launch logs),
# BREAK_GLASS_MERGE_TRIES / BREAK_GLASS_MERGE_SLEEP, BREAK_GLASS_ALLOW_REGISTRY
# (registry file), BREAK_GLASS_ALLOW_TARGET (file allow-rule writes).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/git-clean.sh
. "$SCRIPT_DIR/../lib/git-clean.sh"
git_env_scrub

OP="${1:-}"; ARG="${2:-}"; TIME="${3:-}"
if [ -z "$OP" ] || [ -z "$ARG" ] || [ -z "$TIME" ]; then
    echo "ERR break-glass: usage: break-glass.sh <op> <arg> <time>" >&2
    exit 1
fi

# Gate 0, for EVERY op: an agent can reach this file through the classifier, so
# the agent marker refuses here, not only in the bridge (same rule as
# cr-grant-delta in auto-action.sh).
if [ -n "${CLAUDECODE:-}" ]; then
    echo "ERR break-glass: refusing from inside a Claude session (CLAUDECODE set)" >&2
    exit 19
fi

case "$OP" in
    station-status|revert-main|repin-hooks|launch-leg|cr-reset|close-wrapped|relaunch-console|restart-bridge|allow-rule) ;;
    *) echo "ERR break-glass: unknown op: $OP" >&2; exit 2 ;;
esac

GH="${BREAK_GLASS_GH:-gh}"
SYSTEMCTL="${BREAK_GLASS_SYSTEMCTL:-systemctl}"

primary_dir() {
    if [ -n "${BREAK_GLASS_PRIMARY:-}" ]; then printf '%s\n' "$BREAK_GLASS_PRIMARY"; return 0; fi
    local common
    common="$(git -C "$SCRIPT_DIR" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || return 1
    dirname "$common"
}

PRIMARY="$(primary_dir)" || { echo "ERR break-glass: cannot resolve the primary checkout" >&2; exit 20; }

default_branch() {
    local ref
    ref="$(git -C "$PRIMARY" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null)" || ref=""
    ref="${ref#origin/}"
    printf '%s\n' "${ref:-main}"
}

# Scrub every *_OK bypass and the bridge token from THIS process, so a child
# launched below inherits none of them.
scrub_env() {
    local v
    while IFS= read -r v; do
        case "$v" in *_OK) unset "$v" ;; esac
    done < <(compgen -e)
    unset TELEGRAM_BOT_TOKEN TELEGRAM_OWN_POLLER
}

age_of() {
    local f="$1" m
    m="$(stat -c %Y "$f" 2>/dev/null)" || { echo "absent"; return 0; } # gnu-ok: the bridge runs only on the Linux station
    echo "$(( $(date +%s) - m ))s"
}

# ff-only sync of the primary to origin/<default>. Refuses rather than touch a
# primary that is off the default branch, has tracked changes, or has diverged.
sync_primary() {
    local def head
    def="$(default_branch)"
    head="$(git -C "$PRIMARY" symbolic-ref --quiet --short HEAD 2>/dev/null)" || head=""
    if [ "$head" != "$def" ]; then
        echo "ERR break-glass: primary is on '${head:-detached}', not $def; left alone" >&2
        return 21
    fi
    if [ -n "$(git -C "$PRIMARY" status --porcelain --untracked-files=no 2>/dev/null)" ]; then
        echo "ERR break-glass: primary has tracked changes; left alone" >&2
        return 21
    fi
    git -C "$PRIMARY" fetch --quiet origin "$def" || { echo "ERR break-glass: fetch origin $def failed" >&2; return 13; }
    if ! git -C "$PRIMARY" merge-base --is-ancestor HEAD "origin/$def"; then
        echo "ERR break-glass: primary has diverged from origin/$def; left alone" >&2
        return 22
    fi
    git -C "$PRIMARY" merge --quiet --ff-only "origin/$def" || { echo "ERR break-glass: ff-only merge failed" >&2; return 18; }
    if ! git -C "$PRIMARY" diff --quiet "origin/$def" -- scripts/hooks scripts/guardrails; then
        echo "ERR break-glass: hooks still differ from origin/$def after the sync" >&2
        return 24
    fi
    echo "primary=$(git -C "$PRIMARY" rev-parse HEAD)"
    return 0
}

op_station_status() {
    local f bank now hb st age live=0 stale=0 oldest=0 lines=""
    echo "host $(hostname 2>/dev/null) up $(cut -d' ' -f1 /proc/uptime 2>/dev/null)s"
    echo "load $(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
    echo "mem $(awk '/^MemAvailable:/{printf "%d MiB available", $2/1024}' /proc/meminfo 2>/dev/null)"
    # The primary line comes before every unbounded section: a truncated reply
    # (HIMMEL-5091) must never drop it.
    echo "primary $(git -C "$PRIMARY" symbolic-ref --quiet --short HEAD 2>/dev/null || echo detached)" \
        "$(git -C "$PRIMARY" rev-parse --short HEAD 2>/dev/null)" \
        "$( [ -z "$(git -C "$PRIMARY" status --porcelain --untracked-files=no 2>/dev/null)" ] && echo clean || echo dirty)"
    bank="${BREAK_GLASS_BANK_CMD:-bash $PRIMARY/scripts/lib/bank-preflight.sh}"
    echo "bank:"
    # shellcheck disable=SC2086 # the seam is a command line by design
    timeout 20 $bank 2>&1 | head -n 8 | sed 's/^/  /' # gnu-ok: the bridge runs only on the Linux station
    echo "consoles:"
    # A row with no session name is labelled, never printed blank.
    bash "$PRIMARY/scripts/telegram/console-census.sh" 2>/dev/null | head -n 10 \
        | awk -F'\t' '{ if ($2 == "") $2 = "(unnamed)"; print $1 " " $2 " " $3 " " $4 }' | sed 's/^/  /'
    echo "last tick: $(age_of "$HOME/.himmel/state/tick-ciq-last") ago"
    now="$(date +%s)"
    for f in "${BRIDGE_ROOT:-$HOME/.claude/handover/bridge}"/consoles/*.md.wait; do
        [ -e "$f" ] || continue
        hb="$(sed -n 's/^hb=\([0-9][0-9]*\) .*/\1/p' "$f" 2>/dev/null | head -n 1)"
        st="$(sed -n 's/.* state=\([a-z]*\).*/\1/p' "$f" 2>/dev/null | head -n 1)"
        age=$(( now - 10#${hb:-0} ))
        case "$st" in
            waiting|sampling)
                if [ -n "$hb" ] && [ "$age" -ge 0 ] && [ "$age" -lt 600 ]; then
                    live=$((live + 1))
                    [ "$live" -le 8 ] && lines="$lines""waiter $(basename "$f" .md.wait): ${age}s ago
"
                    continue
                fi ;;
        esac
        stale=$((stale + 1))
        [ "${hb:-0}" -gt 0 ] && [ "$age" -gt "$oldest" ] && oldest=$age
    done
    echo "waiters: $live live, $stale stale (oldest ${oldest}s)"
    [ -z "$lines" ] || printf '%s' "$lines"
    return 0
}

# After a revert merges, a failed primary sync must never invite a second
# revert: the revert PR number is recorded, and a re-call only re-syncs.
revert_sync() {
    local rnum="$1" rc
    sync_primary && return 0
    rc=$?
    echo "ERR break-glass: already reverted (revert PR $rnum), sync failed; fix the primary, then /repin-hooks" >&2
    return "$rc"
}

op_revert_main() {
    local pr="$ARG" def view state base id merge tip head rnum tries i done_file
    case "$pr" in ''|*[!0-9]*) echo "ERR break-glass: bad PR number: '$pr'" >&2; return 1 ;; esac
    def="$(default_branch)"
    # Keyed by the primary checkout too: PR numbers repeat across repos.
    done_file="${BREAK_GLASS_STATE:-$HOME/.himmel/state/break-glass}/revert-$(printf '%s' "$PRIMARY" | sha256sum | cut -c1-12)-$pr.done"
    if [ -f "$done_file" ]; then
        rnum="$(cat "$done_file")"
        echo "already reverted PR $pr (revert PR $rnum); syncing the primary only"
        revert_sync "$rnum"
        return $?
    fi
    view="$(cd "$PRIMARY" && "$GH" pr view "$pr" --json id,state,baseRefName,mergeCommit 2>/dev/null)" \
        || { echo "ERR break-glass: gh pr view $pr failed" >&2; return 13; }
    state="$(printf '%s' "$view" | jq -r '.state // empty')"
    base="$(printf '%s' "$view" | jq -r '.baseRefName // empty')"
    id="$(printf '%s' "$view" | jq -r '.id // empty')"
    merge="$(printf '%s' "$view" | jq -r '.mergeCommit.oid // empty')"
    if [ "$state" != "MERGED" ] || [ "$base" != "$def" ] || [ -z "$id" ]; then
        echo "ERR break-glass: PR $pr is not a merged PR into $def (state=$state base=$base)" >&2
        return 12
    fi
    # Break-glass reverts only the PR that IS main's HEAD: anything older is a
    # normal reviewed revert, never an --admin one from a phone.
    git -C "$PRIMARY" fetch --quiet origin "$def" || { echo "ERR break-glass: fetch origin $def failed" >&2; return 13; }
    tip="$(git -C "$PRIMARY" rev-parse "origin/$def" 2>/dev/null)"
    if [ -z "$merge" ] || [ "$merge" != "$tip" ]; then
        head="$(git -C "$PRIMARY" log -1 --format=%s "origin/$def" | grep -oE '\(#[0-9]+\)$' | tr -d '()')"
        echo "ERR break-glass: PR $pr is not $def's HEAD (HEAD is ${head:-a commit with no PR number}, $(printf '%.12s' "$tip")); only the HEAD PR can be break-glass reverted" >&2
        return 12
    fi
    # GitHub's own revert keeps the original title inside `Revert "…"`, so the
    # ticket ID the commit-msg gate needs rides along.
    # shellcheck disable=SC2016 # $id is a GraphQL variable, not a shell one
    rnum="$(cd "$PRIMARY" && "$GH" api graphql \
        -f query='mutation($id:ID!){revertPullRequest(input:{pullRequestId:$id}){revertPullRequest{number}}}' \
        -f id="$id" --jq '.data.revertPullRequest.revertPullRequest.number' 2>/dev/null)" \
        || { echo "ERR break-glass: revertPullRequest failed for PR $pr" >&2; return 13; }
    case "$rnum" in ''|*[!0-9]*) echo "ERR break-glass: no revert PR number returned" >&2; return 13 ;; esac
    echo "revert_pr=$rnum"
    tries="${BREAK_GLASS_MERGE_TRIES:-10}"
    i=0
    # The revert PR is mergeable only once GitHub has computed it; retry briefly.
    # Main may move meanwhile (another merge, a second /revert-main): HEAD is
    # re-checked before EVERY attempt, and if it moved this is no longer a HEAD
    # revert, so the revert PR is left open for a normal reviewed merge.
    # ponytail: a sub-second window between the check and the merge remains (gh
    # pins only the PR head, not the base), upgrade path: a base-sha-pinned merge API.
    while :; do
        git -C "$PRIMARY" fetch --quiet origin "$def" || { echo "ERR break-glass: fetch origin $def failed; revert PR $rnum left open" >&2; return 13; }
        if [ "$(git -C "$PRIMARY" rev-parse "origin/$def" 2>/dev/null)" != "$tip" ]; then
            echo "ERR break-glass: $def moved past PR $pr before the merge; revert PR $rnum left open for review" >&2
            return 12
        fi
        (cd "$PRIMARY" && "$GH" pr merge "$rnum" --squash --admin >/dev/null 2>&1) && break
        i=$((i + 1))
        if [ "$i" -ge "$tries" ]; then
            echo "ERR break-glass: merge of revert PR $rnum failed; it is left open" >&2
            return 18
        fi
        sleep "${BREAK_GLASS_MERGE_SLEEP:-3}"
    done
    echo "merged revert PR $rnum"
    if ! { mkdir -p "${done_file%/*}" && chmod 700 "${done_file%/*}" && printf '%s\n' "$rnum" > "$done_file"; } 2>/dev/null; then
        echo "ERR break-glass: merged revert PR $rnum but could not record it; do not /revert-main again, use /repin-hooks" >&2
        return 25
    fi
    revert_sync "$rnum"
}

# The current console's fleet manifest: the seam, else the newest
# *-console.fleet.json under the handover root.
fleet_manifest() {
    local fleet="${BREAK_GLASS_FLEET:-}"
    if [ -z "$fleet" ]; then
        # shellcheck source=../lib/handover-path.sh
        . "$PRIMARY/scripts/lib/handover-path.sh"
        # ponytail: newest *-console.fleet.json by mtime stands in for "the current
        # console", upgrade path: a console pointer file if two consoles ever run.
        # gnu-ok: the bridge runs only on the Linux station (find -printf)
        fleet="$(find "$(handover_root)" -maxdepth 4 -name '*-console.fleet.json' -printf '%T@ %p\n' 2>/dev/null \
            | sort -rn | head -n 1 | cut -d' ' -f2-)"
    fi
    if [ -z "$fleet" ] || [ ! -f "$fleet" ]; then
        echo "ERR break-glass: no console fleet manifest found" >&2
        return 23
    fi
    printf '%s\n' "$fleet"
}

# A detached launch reports only that it started, so check what it needs first.
have_detach() {
    command -v setsid >/dev/null 2>&1 && command -v nohup >/dev/null 2>&1 && return 0
    echo "ERR break-glass: setsid/nohup missing; cannot detach a launch" >&2
    return 1
}

valid_label() {
    case "$1" in N[0-9]*) ;; *) return 1 ;; esac
    case "$1" in *[!A-Za-z0-9]*) return 1 ;; esac
    return 0
}

# Start a fresh leg from bucket/launch-<label>.sh, accepted only when its
# sha256 equals the one gen-briefs.py recorded at write time in the sidecar
# beside the manifest (<manifest stem>.launchers.sha256, sha256sum format).
launch_from_launcher() {
    local label="$1" bypass="$2" fleet="$3" launcher sidecar want have line
    sidecar="${fleet%.json}.launchers.sha256"
    # The launcher sits in gen-briefs.py's --bucket, which need not be the
    # manifest's directory: take its path from the newest sidecar line.
    line="$(awk -v n="launch-$label.sh" '{ f = $0; sub(/^[0-9a-f]+  /, "", f); k = split(f, a, "/"); if (a[k] == n) l = $0 } END { print l }' "$sidecar" 2>/dev/null)"
    want="${line%%  *}"
    launcher="${line#*  }"
    if [ -z "$line" ] || [ ! -f "$launcher" ]; then
        echo "ERR break-glass: $label is not in $(basename "$fleet") and has no recorded launch-$label.sh" >&2
        return 23
    fi
    have="$(sha256sum "$launcher" | cut -d' ' -f1)"
    if [ -z "$want" ] || [ "$want" != "$have" ]; then
        echo "ERR break-glass: launch-$label.sh does not match the sha256 the console recorded; refusing" >&2
        return 23
    fi
    scrub_env
    [ "$bypass" = "bypass" ] && export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1
    have_detach || return 23
    setsid nohup bash "$launcher" >/dev/null 2>&1 &  # t13b-ok: one operator-confirmed leg launch, detached once, not a service
    echo "launching $label from $launcher ($bypass, pid $!)"
    return 0
}

op_launch_leg() {
    local label="$ARG" bypass="$TIME" fleet docs n doc wt gitdir common model state now log launcher
    valid_label "$label" || { echo "ERR break-glass: bad leg label: '$label'" >&2; return 1; }
    case "$bypass" in bypass|-) ;; *) echo "ERR break-glass: bad bypass flag: '$bypass'" >&2; return 1 ;; esac
    fleet="$(fleet_manifest)" || return 23
    docs="$(jq -r --arg l "$label" '.legs[]? | select(.label == $l) | .doc' "$fleet" 2>/dev/null)" \
        || { echo "ERR break-glass: cannot read $(basename "$fleet")" >&2; return 23; }
    n="$(printf '%s' "$docs" | grep -c .)"
    if [ "$n" -eq 0 ]; then
        launch_from_launcher "$label" "$bypass" "$fleet"
        return $?
    fi
    if [ "$n" -ne 1 ]; then
        echo "ERR break-glass: $label matches $n legs in $(basename "$fleet"); need exactly one" >&2
        return 23
    fi
    doc="$docs"
    # A manifest leg runs the primary's own launcher, which no sha256 sidecar
    # records, so the hook-integrity bypass is for sidecar launchers only.
    if [ "$bypass" = "bypass" ]; then
        echo "ERR break-glass: --hook-bypass is only for a sha256-recorded launch-$label.sh; send /launch-leg $label without it" >&2
        return 23
    fi
    [ -f "$doc" ] || { echo "ERR break-glass: leg doc missing: $doc" >&2; return 23; }
    wt="$(sed -n '1,/^---$/{s/^resume_cwd:[[:space:]]*//p}' "$doc" | head -n 1)"
    [ -n "$wt" ] && [ -d "$wt" ] || { echo "ERR break-glass: worktree missing for $label: '${wt}'" >&2; return 23; }
    gitdir="$(git -C "$wt" rev-parse --path-format=absolute --git-dir 2>/dev/null)" || gitdir=""
    common="$(git -C "$wt" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" || common=""
    if [ -z "$gitdir" ] || [ "$gitdir" = "$common" ] \
        || [ "$common" != "$(git -C "$PRIMARY" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" ]; then
        echo "ERR break-glass: $wt is not a linked worktree of $PRIMARY; refusing to launch there" >&2
        return 23
    fi
    model="$(grep -m1 -oE '\((claude|gpt)-[a-z0-9.-]+,' "$doc" | tr -d '(,')"
    [ -n "$model" ] || { echo "ERR break-glass: no model named in $(basename "$doc")" >&2; return 23; }
    state="${BREAK_GLASS_STATE:-$HOME/.himmel/state/break-glass}"
    mkdir -p "$state" && chmod 700 "$state"
    now="$(date +%s)"
    : > "$state/$label.signal"
    log="$state/$label-$now.log"
    launcher="${BREAK_GLASS_LEG_CMD:-bash $PRIMARY/scripts/handover/console-kit/headed-arm-leg.sh}"
    # shellcheck disable=SC2086 # the seam is a command line by design
    set -- $launcher
    if ! command -v "$1" >/dev/null 2>&1 || { [ "$1" = bash ] && [ ! -f "$2" ]; }; then
        echo "ERR break-glass: leg launcher not found: $launcher" >&2
        return 23
    fi
    have_detach || return 23
    scrub_env
    [ "$bypass" = "bypass" ] && export HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1
    export LEG_REPO="$wt"
    # shellcheck disable=SC2086 # the seam is a command line by design
    setsid nohup $launcher --profile leg-impl --fleet "$fleet" --console "$(basename "${fleet%.fleet.json}")" \
        "$(basename "${doc%.md}")" "$doc" "$state/$label.signal" "$now" "$log" "$model" \
        >/dev/null 2>&1 &
    echo "launching $label in $wt (model $model, $bypass, pid $!); log $log"
    return 0
}

op_cr_reset() {
    case "$ARG" in ''|*[!0-9]*) echo "ERR break-glass: bad PR number: '$ARG'" >&2; return 1 ;; esac
    bash "${BREAK_GLASS_CR_RESET:-$PRIMARY/scripts/cr/cr-reset.sh}" "$ARG"
}

op_close_wrapped() {
    local label="$ARG" fleet docs doc closer closed=0 refused=0 out
    if [ "$label" != "-" ]; then
        valid_label "$label" || { echo "ERR break-glass: bad leg label: '$label'" >&2; return 1; }
    fi
    fleet="$(fleet_manifest)" || return 23
    if [ "$label" = "-" ]; then
        docs="$(jq -r '.legs[]?.doc' "$fleet" 2>/dev/null)" \
            || { echo "ERR break-glass: cannot read $(basename "$fleet")" >&2; return 23; }
    else
        docs="$(jq -r --arg l "$label" '.legs[]? | select(.label == $l) | .doc' "$fleet" 2>/dev/null)" \
            || { echo "ERR break-glass: cannot read $(basename "$fleet")" >&2; return 23; }
        if [ "$(printf '%s' "$docs" | grep -c .)" -ne 1 ]; then
            echo "ERR break-glass: $label does not name exactly one leg in $(basename "$fleet")" >&2
            return 23
        fi
    fi
    closer="${BREAK_GLASS_CLOSE_CMD:-bash $PRIMARY/scripts/handover/console-kit/close-wrapped-leg.sh}"
    while IFS= read -r doc; do
        [ -n "$doc" ] || continue
        # shellcheck disable=SC2086 # the seam is a command line by design
        if out="$(cd "$PRIMARY" && $closer --fleet "$fleet" "$doc" 2>&1)"; then
            closed=$((closed + 1)); echo "closed $(basename "$doc")"
        else
            refused=$((refused + 1))
            [ "$label" = "-" ] || echo "refused $(basename "$doc"): $(printf '%s' "$out" | tail -n 1)"
        fi
    done <<< "$docs"
    echo "closed=$closed left=$refused"
    [ "$label" = "-" ] && return 0
    [ "$refused" -eq 0 ] || return 1
}

op_relaunch_console() {
    local name="$ARG" cmd
    [ "$name" = "-" ] && name="console"
    if ! [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
        echo "ERR break-glass: bad console name: '$name'" >&2
        return 1
    fi
    cmd="${BREAK_GLASS_CONSOLE_CMD:-bash $PRIMARY/scripts/handover/console/console.sh}"
    scrub_env
    # shellcheck disable=SC2086 # the seam is a command line by design
    (cd "$PRIMARY" && $cmd next --arm --name "$name")
}

op_restart_bridge() {
    if ! "$SYSTEMCTL" --user cat telegram-bridge.service >/dev/null 2>&1; then
        echo "ERR break-glass: telegram-bridge.service is not installed" >&2
        return 20
    fi
    if [ -n "${BREAK_GLASS_RESTART_CMD:-}" ]; then
        # shellcheck disable=SC2086 # the seam is a command line by design
        $BREAK_GLASS_RESTART_CMD
    else
        systemd-run --user --quiet --collect --on-active=3 "$SYSTEMCTL" --user restart telegram-bridge.service
    fi || { echo "ERR break-glass: could not schedule the bridge restart" >&2; return 18; }
    echo "bridge restart scheduled in 3s"
}

# allow-rule <id>: the ONE rule text the checked-in registry maps the id to is
# added to permissions.allow of the primary's UNTRACKED local settings file (the
# tracked one would dirty the primary and break /repin-hooks' ff-only pull).
op_allow_rule() {
    local id="$ARG" reg tgt rule new bak
    if ! [[ "$id" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
        echo "ERR break-glass: bad rule id: '$id'" >&2
        return 1
    fi
    reg="${BREAK_GLASS_ALLOW_REGISTRY:-$SCRIPT_DIR/allow-rules.json}"
    [ -f "$reg" ] || { echo "ERR break-glass: allow-rule registry not found: $reg" >&2; return 20; }
    rule="$(jq -r --arg id "$id" 'if type == "object" and (.[$id] | type) == "string" then .[$id] else empty end' "$reg" 2>/dev/null)" \
        || { echo "ERR break-glass: cannot read the allow-rule registry" >&2; return 20; }
    if [ -z "$rule" ] || [[ "$rule" =~ [[:cntrl:]] ]]; then
        echo "ERR break-glass: no reviewed rule for id '$id'" >&2
        return 26
    fi
    tgt="${BREAK_GLASS_ALLOW_TARGET:-$PRIMARY/.claude/settings.local.json}"
    if [ -e "$tgt" ] && ! jq -e 'type == "object" and ((.permissions // {}) | type == "object") and ((.permissions.allow // []) | type == "array")' "$tgt" >/dev/null 2>&1; then
        echo "ERR break-glass: $tgt is not a settings object with an allow list; left alone" >&2
        return 27
    fi
    if [ -e "$tgt" ] && jq -e --arg r "$rule" '(.permissions.allow // []) | index($r) != null' "$tgt" >/dev/null 2>&1; then
        echo "rule '$id' already present in $tgt; nothing written"
        return 0
    fi
    mkdir -p "${tgt%/*}" 2>/dev/null || { echo "ERR break-glass: cannot create ${tgt%/*}" >&2; return 27; }
    new="$(mktemp "$tgt.XXXXXX")" || { echo "ERR break-glass: cannot create a temp file beside $tgt" >&2; return 27; }
    if ! { if [ -e "$tgt" ]; then cat "$tgt"; else echo '{}'; fi; } \
        | jq --arg r "$rule" '.permissions.allow = ((.permissions.allow // []) + [$r])' > "$new" 2>/dev/null; then
        rm -f "$new"
        echo "ERR break-glass: could not build the new settings" >&2
        return 27
    fi
    if [ -e "$tgt" ]; then
        bak="$tgt.bak-$(date +%s)-$$"
        cp -p "$tgt" "$bak" || { rm -f "$new"; echo "ERR break-glass: backup of $tgt failed; nothing written" >&2; return 27; }
    fi
    mv "$new" "$tgt" || { rm -f "$new"; echo "ERR break-glass: could not write $tgt" >&2; return 27; }
    echo "rule '$id' added to $tgt${bak:+ (backup $bak)}"
}

# Every op runs scrubbed (launch-leg re-exports its one bypass after this).
scrub_env

case "$OP" in
    station-status) op_station_status ;;
    revert-main) op_revert_main ;;
    repin-hooks) sync_primary ;;
    launch-leg) op_launch_leg ;;
    cr-reset) op_cr_reset ;;
    close-wrapped) op_close_wrapped ;;
    relaunch-console) op_relaunch_console ;;
    restart-bridge) op_restart_bridge ;;
    allow-rule) op_allow_rule ;;
esac
exit $?
