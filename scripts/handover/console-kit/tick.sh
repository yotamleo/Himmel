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
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"

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
orphans= lists only wrappers older than that, so a live leg without one never
shows here: procs=...,unwatched= (below) is what names a live leg the arm omits.

legs= reads a leg's lock as FRESH or STALE (held; an idle-warned lock still reads
FRESH/STALE here -- the IDLE-HELD? flag belongs to the sweep and the exit code),
WRAPPED (lock released and the tail says WRAPPED -- the normal end of a leg),
FREE (lock released while the tail does not say WRAPPED -- a lost lock),
CORRUPT, UNKNOWN (queue-lock status unreadable) or NOTFOUND (no such doc).

legset=<ok|STALE:unarmed=A+B;unlisted=C|unknown|skip> (HIMMEL-3293) compares
this console's `## Live state` legs with the --legs arm. unarmed = listed in
Live state but not in the arm; unlisted = in the arm, not held, and absent from
Live state. STALE means the arm is out of date -- re-arm the tick with the
current leg docs (absolute paths) -- and is never leg trouble. livestate=DRIFT
names only a leg the arm covers (a not-held one Live state still lists, or a
held one it omits); a Live-state leg the arm omits is reported as unarmed
here, not as DRIFT. legset=unknown when
livestate=unknown, skip when there is no --doc.

procs=<n>,...,unwatched=<A+B> also names a live claude session, in the process
census, whose leg label (N<digits><letters>) the arm does not name -- a leg the
tick is not watching. It reads the whole census, so with several consoles on
one host another console's legs can appear here.

nonces=<ok|RELAYED:<leg,...>|UNCONFIRMED:<leg,...>|unknown|skip> (HIMMEL-3254)
closes the line. It reads, for each HELD leg in this console doc's `## Live
state`, whether the nonce starts with this console's own letter
(`<LETTER>-<leg>-<hex>`). A leg whose nonce carries a PREVIOUS console's letter
is not rotated, which is a valid state: a relay may keep the leg's token. So the
leg's own handover doc decides: its LATEST `- ... SUCCESSION accepted:` Results
bullet naming this console as the incoming session = RELAYED (the leg took this
console over, informational, nothing to do); no such bullet = UNCONFIRMED (this
console cannot tell whether the leg was re-briefed -- ask the leg for its quote-back, or have the
predecessor relay it, which is the stronger form; a chain, see leg-preface.md
"Console succession", is only for a predecessor that is gone and never replaces
an accepted relay). UNCONFIRMED wins the field when both occur.
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

# uniq_join <sep> <comma list> -- sorted, de-duplicated, re-joined with <sep>.
uniq_join() {
    printf '%s\n' "$2" | tr ',' '\n' | awk 'NF' | sort -u | tr '\n' "$1" | sed 's/.$//'
}

# HIMMEL-3277: a leg doc's label (N<k>) and the session names it may run under
# come from ONE derivation, scripts/lib/leg-identity.sh (sourced above). The two
# used to be separate local regexes -- leg_label() here, undated_stem() -- that
# no test ever tried against a name the harness produced, so a doc filed per
# leg-brief-template.md joined to neither a session nor a legs: label.

csv_add() {
    if [ -n "$1" ]; then
        printf '%s,%s' "$1" "$2"
    else
        printf '%s' "$2"
    fi
}

# HIMMEL-3305: a leg's tails= status is the marker on its newest marker-bearing
# `- ` bullet. The vocabulary (docs/handover/leg-preface.md -- change the two
# together) is LIVE / FINDING / RESOLVED / READY / BLOCKED / HALTED / WRAPPED.
# RESOLVED retires a FINDING the console has answered: without it FINDING stayed
# the newest marker for the whole window the leg spent doing the authorised work,
# and a console could not tell "answer me" from "you answered me half an hour ago".
# A bullet may name more than one marker ("RESOLVED -- FINDING accepted, back to
# LIVE"); the status is the highest-PRECEDENCE one, never the first or last in
# reading order: a bullet that closes a state outranks the state it mentions, so
# WRAPPED > READY > RESOLVED > BLOCKED > HALTED > FINDING > LIVE. A marker is a
# whole word (UNRESOLVED is a CR-thread count, not RESOLVED). SHIPPED / MERGED are
# deliberately NOT markers -- a leg between GREEN and READY reports LIVE.
# ponytail: precedence is per bullet, so a bullet that merely MENTIONS a
# higher-precedence marker in prose ("LIVE -- send READY at green") reads as that
# marker; the preface tells a leg to name one marker per bullet.
LEG_TAIL_MARKERS="WRAPPED READY RESOLVED BLOCKED HALTED FINDING LIVE"
leg_tail_status() {  # leg_tail_status <leg doc> -- prints the marker, or nothing
    local doc="$1" line m
    line="$(grep -E '^- (.*[^A-Za-z0-9_])?(WRAPPED|READY|RESOLVED|BLOCKED|HALTED|FINDING|LIVE)([^A-Za-z0-9_]|$)' "$doc" 2>/dev/null \
        | tail -n 1)" || return 0
    for m in $LEG_TAIL_MARKERS; do
        if printf '%s\n' "$line" | grep -Eq "(^|[^A-Za-z0-9_])$m([^A-Za-z0-9_]|\$)"; then
            printf '%s' "$m"
            return 0
        fi
    done
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
leg_docmap=""
# label<TAB>lock status<TAB>candidate session names, one line per leg (procs= below).
leg_candmap=""
# HIMMEL-3145: the census names the -n session the console actually passed
# to `claude`, which is the leg doc's stem minus a -RESUME suffix (the same
# string the --burn loop below matches on) -- collect it here so procs=/
# models= can count against what THIS console dispatched instead of
# guessing from a "-leg" spelling.
leg_names=""
for leg in $LEGS_SPLIT; do
    leg_doc="$(resolve_doc "$leg")"
    ident="$(leg_identity "$leg")"
    label="${ident%%$'\t'*}"
    leg_cands="${ident#*$'\t'}"
    for cand in ${leg_cands//,/ }; do
        leg_names="$(csv_add "$leg_names" "$cand")"
    done
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
        tail_status="$(leg_tail_status "$leg_doc")"
        [ -n "$tail_status" ] || tail_status="?"
        # HIMMEL-3293: FREE used to cover both "released cleanly at wrap" and "the
        # lock vanished while the leg worked", and only the second is a reason to
        # act. A released lock whose doc's LAST status bullet is WRAPPED is the
        # clean wrap: it reads WRAPPED (tails= already says so); FREE is left to
        # mean a lock that is gone with no wrap behind it (lost, or never acquired).
        # ponytail: WRAPPED is the leg's own last bullet, self-reported -- a leg
        # that wrote WRAPPED and is somehow still working reads WRAPPED, not FREE.
        if [ "$lock_status" = FREE ] && [ "$tail_status" = WRAPPED ]; then
            lock_status=WRAPPED
        fi
    else
        printf 'tick: no such leg doc: %s\n' "$leg_doc" >&2
    fi
    legs_summary="$(csv_add "$legs_summary" "$label:$lock_status")"
    tails_summary="$(csv_add "$tails_summary" "$label:$tail_status")"
    leg_docmap="$leg_docmap$label=$leg_doc"$'\n'
    leg_candmap="$leg_candmap$label"$'\t'"$lock_status"$'\t'"$leg_cands"$'\n'
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

# legs_label_shaped <token> -- is this the first field of an attempted entry
# rather than a prose token? A label is what leg-identity.sh derives: the
# canonical N<k>[letters], or the stem of a leg doc (which the derivation
# reduces to its N<k>, so its label differs from the stem). A token that
# derivation leaves alone and that is not N<k> (`legs`, `procs`, `bank`) is prose.
# A file name is a cite, never a label (HIMMEL-3284): leg_label strips `.md` from
# a doc path, so `stuck-playbook.md` "reduces" to `stuck-playbook` and a
# `stuck-playbook.md:408` cite read as a label-shaped span with a colon -- a
# MALFORMED leg that never existed. A label leg_label emits never ends in `.md`.
legs_label_shaped() {
    local re_canon='^N[0-9]+[a-z]*$'
    [[ $1 =~ $re_canon ]] && return 0
    case "$1" in *.md) return 1 ;; esac
    [ "$(leg_label "$1")" != "$1" ]
}

# legs_line_spans <entries|malformed> <legs: line> -- classify every backtick
# span on the line (HIMMEL-3280). `entries` prints each well-formed
# `<label>:<nonce>:<lock-token>:<pid>` span, one per line, backticks stripped
# (exactly four non-empty fields, first one all LEG_LABEL_CLASS). `malformed`
# prints the LABEL of each label-shaped span that has a colon but is not that
# (a truncated or padded real entry) -- the label only, since the span carries a
# nonce and a lock token. Everything else is prose and is ignored: a span with
# whitespace, a first field outside the label class or not label-shaped, or no
# colon at all (`N191` mentioned in a note).
legs_line_spans() {
    local mode="$1" span f1 colons entry
    # shellcheck disable=SC2016  # backtick span pattern, not a shell expansion
    printf '%s\n' "$2" | grep -oE '`[^`]*`' | tr -d '`' | while IFS= read -r span; do
        case "$span" in
            ''|*[[:space:]]*) continue ;;
        esac
        f1="${span%%:*}"
        [ "$f1" != "$span" ] || continue
        case "$f1" in
            ''|*[!$LEG_LABEL_CLASS]*) continue ;;
        esac
        colons="${span//[!:]/}"
        entry=0
        if [ "${#colons}" -eq 3 ]; then
            case ":$span:" in *::*) ;; *) entry=1 ;; esac
        fi
        if [ "$entry" -eq 1 ]; then
            [ "$mode" = entries ] && printf '%s\n' "$span"
        elif [ "$mode" = malformed ] && legs_label_shaped "$f1"; then
            printf '%s\n' "$f1"
        fi
    done
}

livestate_summary=skip
nonces_summary=skip
legset_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    live_state_body="$(awk '
        $0 == "## Live state" { f = 1; next }
        f && /^## / { exit }
        f { print }
    ' "$console_doc")"
    # The legs: BLOCK (HIMMEL-3281), not just the first `legs:` line: every
    # `legs:` line plus the lines wrapped directly under it, up to the first blank
    # line, the next `field:` line (`queue:`, `last GO:`, `acked:`) or a list-marker
    # / `>` / `#` line (a wrapped continuation is never one, and a detail bullet
    # written straight under `legs:` must not have its `x.md:408` cites read as
    # entries). Reading the
    # first line only made every span on a wrapped line invisible -- not MALFORMED,
    # not FREE, just absent -- so a held leg read DRIFT and a stale one read ok.
    # ponytail: the block ENDS at a blank, `word:` or list-marker line, so a leg
    # span past any of them (a per-leg detail bullet, another field) is not an entry; a held
    # leg named only there reads DRIFT, which is true -- the block never named it.
    legs_line="$(printf '%s\n' "$live_state_body" | awk '
        /^legs:/ { f = 1; print; next }
        f && (/^[[:space:]]*$/ || /^[A-Za-z][A-Za-z ]*:/ || /^[[:space:]]*([-*+]|[0-9]+[.)])[[:space:]]/ || /^[[:space:]]*[>#]/) { f = 0 }
        f { print }
    ')"
    if [ -n "$legs_line" ]; then
        # Each leg is one backtick span `<label>:<nonce>:<lock-token>:<pid>`
        # (Delta 2's format) -- take the label, the text before the first
        # colon inside the span. The label class is leg-identity.sh's own
        # (LEG_LABEL_CLASS, which includes "-" and "."): a narrower class here
        # rejected every hyphenated label, so a span naming a leg by anything
        # but a bare N<k> never parsed and read as absent (HIMMEL-3277).
        # Prose on the line is tolerated (HIMMEL-3280): a backticked token is
        # an entry only if it is four non-empty fields under a label
        # (legs_line_spans), so `legs:` in a note is not a leg. A span that
        # LOOKS like an entry (label-shaped first field, a colon) but is not
        # four fields is reported MALFORMED by label, never dropped: dropping
        # it would read the leg as absent and DRIFT would then blame the
        # console for a leg that was written, just wrongly.
        live_spans="$(legs_line_spans entries "$legs_line")"
        live_legs="$(printf '%s\n' "$live_spans" | sed -E 's/:.*$//')"
        malformed_legs="$(legs_line_spans malformed "$legs_line")"
        held_legs="$(printf '%s\n' "$legs_summary" | tr ',' '\n' | awk -F: '$2 == "FRESH" || $2 == "STALE" { print $1 }')"
        # HIMMEL-3293: the leg set this tick watches is the --legs arm, and Live
        # state is the console's own record; the two are supplied separately and
        # can disagree. A leg Live state names that the arm does not is UNARMED --
        # this tick has no lock for it, so it can say nothing about its health --
        # and is reported under legset= as an input problem, never as DRIFT (which
        # blamed a healthy leg for the console's stale arm). DRIFT keeps the two
        # cases the tick CAN judge: an armed leg whose lock is not held that Live
        # state still names, and a held leg Live state omits.
        # Why not derive the leg set from Live state alone (the ticket's preferred
        # shape)? A span is `<label>:<nonce>:<lock-token>:<pid>` -- it names no doc,
        # so a label cannot be joined to a lock or a tail without trusting the
        # self-reported token or pid, and a wrong one would read as a lost lock.
        # ponytail: the arm still decides which legs get lock/tail/nonce checks;
        # an unarmed held leg is named but not verified until the console re-arms.
        armed_legs="$(printf '%s' "$leg_candmap" | awk -F'\t' 'NF { print $1 }')"
        drift_csv=""
        unarmed_csv=""
        for l in $live_legs; do
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            if list_has "$l" $held_legs; then
                continue
            fi
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            if list_has "$l" $armed_legs; then
                drift_csv="$(csv_add "$drift_csv" "$l")"
            else
                unarmed_csv="$(csv_add "$unarmed_csv" "$l")"
            fi
        done
        # An armed leg that holds no lock and is not in Live state is a wrapped leg
        # the console already dropped: harmless, but the arm still names it.
        unlisted_csv=""
        for l in $armed_legs; do
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            list_has "$l" $held_legs $live_legs $malformed_legs || unlisted_csv="$(csv_add "$unlisted_csv" "$l")"
        done
        legset_summary=""
        [ -z "$unarmed_csv" ] || legset_summary="unarmed=$(uniq_join + "$unarmed_csv")"
        if [ -n "$unlisted_csv" ]; then
            legset_summary="${legset_summary:+$legset_summary;}unlisted=$(uniq_join + "$unlisted_csv")"
        fi
        if [ -n "$legset_summary" ]; then legset_summary="STALE:$legset_summary"; else legset_summary=ok; fi
        for l in $held_legs; do
            # A malformed span still NAMES its leg (badly): it reads MALFORMED,
            # not also "held but unnamed".
            # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
            list_has "$l" $live_legs $malformed_legs || drift_csv="$(csv_add "$drift_csv" "$l")"
        done
        drift_csv="$(printf '%s\n' "$drift_csv" | tr ',' '\n' | awk 'NF' | sort -u | tr '\n' ',' | sed 's/,$//')"
        malformed_csv="$(printf '%s\n' "$malformed_legs" | awk 'NF' | sort -u | tr '\n' ',' | sed 's/,$//')"
        livestate_summary=""
        [ -z "$malformed_csv" ] || livestate_summary="MALFORMED:${malformed_csv}"
        if [ -n "$drift_csv" ]; then
            livestate_summary="${livestate_summary:+$livestate_summary;}DRIFT:${drift_csv}"
        fi
        [ -n "$livestate_summary" ] || livestate_summary=ok
        # HIMMEL-3254: a HELD leg whose Live-state nonce (`<LETTER>-<leg>-<hex>`)
        # still carries a previous console's letter is NOT necessarily
        # stranded: a relay may keep the leg's token (leg-preface.md "Console
        # succession"), so an unrotated nonce is the common, valid state. The
        # leg's own handover doc says which it is -- the leg writes
        # `- <time> SUCCESSION accepted: <console> replaces <old>` under
        # Results when it takes a console over. That bullet naming THIS
        # console = RELAYED (informational); none = UNCONFIRMED (this
        # console cannot tell whether the leg was re-briefed). The letter is
        # this console doc's own (`<prefix>-nextleg-<date><LETTER>-<name>.md`)
        # and the console name in the bullet is that doc's stem; a wrapped leg
        # (lock not held) has nothing to rotate.
        # ponytail: both reads are self-reported state, not proof. A leg that
        # accepted but has not yet written its bullet reads UNCONFIRMED for a
        # moment, and a console that rewrites a leg's Live-state nonce before
        # that leg's quote-back reads ok while the leg is still unverified
        # (the console template says: update the nonce only AFTER the
        # quote-back). A doc name with no parseable letter reads unknown,
        # never a guess.
        console_letter="$(printf '%s\n' "${console_doc##*/}" | sed -n -E 's/.*-nextleg-[0-9]{4}-[0-9]{2}-[0-9]{2}([A-Z]{1,2})-.*/\1/p')"
        console_stem="${console_doc##*/}"; console_stem="${console_stem%.md}"
        if [ -z "$console_letter" ]; then
            nonces_summary=unknown
        else
            unconfirmed_csv=""
            relayed_csv=""
            for span in $live_spans; do
                span_leg="${span%%:*}"
                span_rest="${span#*:}"
                span_nonce="${span_rest%%:*}"
                # shellcheck disable=SC2086  # word-split on purpose: list_has takes "$@"
                list_has "$span_leg" $held_legs || continue
                case "$span_nonce" in
                    "$console_letter"-*) continue ;;
                esac
                # one `label=path` per line, so a path with spaces stays whole
                span_doc="$(printf '%s' "$leg_docmap" | awk -v k="$span_leg" 'index($0, k "=") == 1 { print substr($0, length(k) + 2); exit }')"
                accepted=""
                if [ -n "$span_doc" ] && [ -f "$span_doc" ]; then
                    # The LATEST acceptance bullet's INCOMING session (the first
                    # name after the colon, not the one after `replaces`) must
                    # be exactly this console.
                    accepted="$(sed -n -E 's/^- .*SUCCESSION accepted:[^A-Za-z0-9]*([A-Za-z0-9_.-]+).*/\1/p' "$span_doc" 2>/dev/null | tail -n 1)"
                fi
                if [ -n "$accepted" ] && [ "$accepted" = "$console_stem" ]; then
                    relayed_csv="$(csv_add "$relayed_csv" "$span_leg")"
                else
                    unconfirmed_csv="$(csv_add "$unconfirmed_csv" "$span_leg")"
                fi
            done
            if [ -n "$unconfirmed_csv" ]; then
                nonces_summary="UNCONFIRMED:${unconfirmed_csv}"
            elif [ -n "$relayed_csv" ]; then
                nonces_summary="RELAYED:${relayed_csv}"
            else
                nonces_summary=ok
            fi
        fi
    else
        livestate_summary=unknown
        nonces_summary=unknown
        legset_summary=unknown
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
#
# HIMMEL-3277: that guard only asked whether the filter EXISTS. A well-formed
# leg_names that cannot match anything (a doc named one way, a session named
# another) still rendered a confident 0 beside two live, lock-holding legs. The
# test is population-level, over the HELD legs (FRESH/STALE lock): a wrapped or
# missing leg expects no process, so its absence is a real zero, not a suspicion.
#   - no held leg matches any census row -> the derivation itself is suspect:
#     procs=/models= read unknown, exactly like a failed census;
#   - some do -> the derivation demonstrably works, so the rest are genuinely
#     not running: count the live ones and name the rest as unmatched=<a>+<b>
#     instead of blanking the whole field.
# ponytail: a degraded census (rc=3, unreadable=<n>) can hide a live leg's row,
# so an unmatched= name may be a leg whose cmdline was unreadable -- the
# appended unreadable= flag is that caveat; unmatched= is not suppressed by it.
census_names="$(printf '%s\n' "$sessions_out" | awk -F'\t' '$1 !~ /^#/ && NF >= 4 && $2 != "" { print $2 }')"
held_n=0
matched_n=0
unmatched_csv=""
while IFS=$'\t' read -r m_label m_status m_cands; do
    [ -n "$m_label" ] || continue
    case "$m_status" in FRESH|STALE) ;; *) continue ;; esac
    held_n=$((held_n + 1))
    m_hit=0
    for m_cand in ${m_cands//,/ }; do
        if grep -Fxq -- "$m_cand" <<< "$census_names"; then
            m_hit=1
            break
        fi
    done
    if [ "$m_hit" -eq 1 ]; then
        matched_n=$((matched_n + 1))
    elif [ -n "$unmatched_csv" ]; then
        unmatched_csv="$unmatched_csv+$m_label"
    else
        unmatched_csv="$m_label"
    fi
done <<< "$leg_candmap"
leg_names_wrapped=",${leg_names},"
# HIMMEL-3293: procs= counts only the sessions THIS arm names, so a live leg the
# arm does not name (dispatched after it, or another console's) was dropped
# without a word -- an unwatched leg is the state this instrument must never hide.
# Every leg-shaped census row (a session whose name derives an N<k> label, which
# excludes consoles and other non-leg sessions) that is not one of the arm's
# candidate names is named here by label. orphans= cannot cover this: it lists
# shell-tool wrappers older than TICK_ORPHAN_MIN minutes per owning session, so a
# session with no aged wrapper never appears in it at all.
# ponytail: with several consoles on one box another console's legs read here too;
# the census carries no owner, so a label in neither this console's Live state nor
# its arm is another console's or a leg this console lost track of -- the tick
# cannot say which.
unwatched_csv=""
re_unwatched_label='^N[0-9]+[a-z]*$'
while IFS= read -r u_name; do
    [ -n "$u_name" ] || continue
    case "$leg_names_wrapped" in *",$u_name,"*) continue ;; esac
    u_label="$(leg_label "$u_name")"
    [[ $u_label =~ $re_unwatched_label ]] || continue
    unwatched_csv="$(csv_add "$unwatched_csv" "$u_label")"
done <<< "$census_names"
unwatched_plus="$(uniq_join + "$unwatched_csv")"
filter_unusable=0
if [ "$census_failed" -eq 1 ] || [ -z "$leg_names" ]; then
    filter_unusable=1
elif [ "$held_n" -gt 0 ] && [ "$matched_n" -eq 0 ]; then
    filter_unusable=1
fi
if [ "$filter_unusable" -eq 1 ]; then
    # A field that cannot be computed must say so (HIMMEL-3130 NOTFOUND-vs-
    # MISSING, HIMMEL-3002 unreadable=): procs=0 and procs=unknown must be
    # distinguishable, or a real scan failure reads as "no legs running".
    # An empty --legs is the same case: there is no dispatch set to count
    # against, so "0" would be a bare guess (and, worse, a matched-nothing
    # filter would print it as a clean 0 -- ",,".index(",name,") is always
    # 0), not a real count. procs= is only ever a count of the dispatched
    # set; without one, it cannot be computed either.
    procs=unknown
    [ -z "$unwatched_plus" ] || procs="${procs},unwatched=${unwatched_plus}"
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
    [ -z "$unmatched_csv" ] || procs="${procs},unmatched=${unmatched_csv}"
    [ -z "$unwatched_plus" ] || procs="${procs},unwatched=${unwatched_plus}"
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
if [ "$filter_unusable" -eq 1 ]; then
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
            # HIMMEL-3167/3277: the session name has no -YYYY-MM-DD suffix, and a
            # legacy-spelled doc's session is the derived <TICKET>-N<k> name; try
            # every candidate leg_identity names until one has a transcript.
            burn_ident="$(leg_identity "$leg")"
            burn_cands="${burn_ident#*$'\t'}"
            for burn_cand in ${burn_cands//,/ }; do
                [ "$burn_cand" = "$stem" ] && continue
                burn_line="$(bash "$REPO/scripts/lanes/leg-burn.sh" "$burn_cand" 2>/dev/null)" || burn_line=""
                [ -z "$burn_line" ] || break
            done
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
    printf 'leg set: %s\n' "$legset_summary"
else
    # `tick=` is always appended (HIMMEL-3144); `burn=` stays APPENDED only
    # under --burn, after it. `fleet=`/`capacity=` (HIMMEL-3167) are appended
    # after everything else, so a consumer keyed on the existing fields and
    # their order sees them only as a tail. `gql=` (HIMMEL-3197) follows them, and
    # `orphans=` (HIMMEL-2761) follows, `nonces=` (HIMMEL-3254) follows it, and
    # `legset=` (HIMMEL-3293) is last.
    if [ "$burn" -eq 1 ]; then
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s tick=%s burn=%s fleet=%s capacity=%s gql=%s orphans=%s nonces=%s legset=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary" "$tick_status" "$burn_summary" "$fleet" "$capacity" "$gql" "$orphans" "$nonces_summary" "$legset_summary"
    else
        printf 'TICK %s hb=%s legs=%s livestate=%s procs=%s models=%s %s atq=%s suites=%s prs=%s bank=%s fill=%s tails=%s inbox=%s tick=%s fleet=%s capacity=%s gql=%s orphans=%s nonces=%s legset=%s\n' \
            "$clock" "$hb" "$legs_summary" "$livestate_summary" "$procs" "$models_summary" "$ceiling_summary" "$at_count" "$suites" "$prs" "$bank" "$fill" "$tails_summary" "$inbox_summary" "$tick_status" "$fleet" "$capacity" "$gql" "$orphans" "$nonces_summary" "$legset_summary"
    fi
fi
