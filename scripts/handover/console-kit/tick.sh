#!/usr/bin/env bash
# tick.sh — one wake-up-budgeted console snapshot.
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

# Parameter expansion, not dirname: a PATH-shadowed dirname must not pick
# what is sourced before the seam guard.
case "${BASH_SOURCE[0]}" in */*) _csg_dir="${BASH_SOURCE[0]%/*}" ;; *) _csg_dir=. ;; esac
_csg_lib="$_csg_dir/../../lib/chokepoint-seam-guard.sh"
# shellcheck source=scripts/lib/chokepoint-seam-guard.sh
# shellcheck disable=SC1091
if ! { [ -r "$_csg_lib" ] && . "$_csg_lib"; }; then
    echo "tick.sh: cannot load $_csg_lib - refusing (HIMMEL-3914)" >&2
    exit 96
fi
chokepoint_seam_guard scripts/handover/console-kit/tick.sh || exit 96

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# handover_root reads only the live env; feed it the .env HANDOVER_DIR first.
# shellcheck disable=SC1091
if . "$HERE/../../lib/load-dotenv.sh" 2>/dev/null; then load_dotenv HANDOVER_DIR 2>/dev/null || true; fi
# shellcheck source=../../lib/handover-path.sh
. "$HERE/../../lib/handover-path.sh"
# shellcheck source=../../lib/leg-identity.sh
. "$HERE/../../lib/leg-identity.sh"

usage() {
    cat <<'USAGE'
usage: tick.sh [--verbose] [--burn] [--emit-fp] [--doc PATH] [--token TOKEN]
               [--legs "DOC ..."] [--legs-from MANIFEST] [--handover-dir DIR]
               [--repo DIR]

env equivalents: DOC TOKEN LEGS LEGS_FROM HANDOVER_DIR REPO
Relative DOC/LEGS resolve under the handover root; include the bucket prefix
when HANDOVER_DIR names a global state root.

--legs-from MANIFEST (HIMMEL-3748) reads the leg docs from a fleet manifest
(console-kit/fleet-manifest.sh writes it) on every run, so a dispatch or wrap
edits that file and a waiter forwarding the same argv needs no restart. Its
legs join any --legs ones (a doc on both is judged once). A manifest that is
missing or not valid schema-1 JSON fails the tick (rc 1, no TICK line) -- never
an empty leg set that reads as every leg gone.

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

flakes=<rows>/<suites>@<top-suite>*<k> (HIMMEL-5131) sits between fails= and spare=
and is ABSENT unless this repo's suite-flake ledger (run-shell-tests.sh,
HIMMEL-5116) took a row since the console lock's start: <rows> FLAKE rows,
<suites> distinct suites, the suite flaked most and its repeat count (the
per-row suite, case, sha and run: scripts/observability/suite-flake-summary.sh
--format detail). flakes=? when the ledger is unreadable. Advisory: not in
console-wait's action key, so it wakes nothing. Env seams: SUITE_FLAKE_LEDGER,
SUITE_FLAKE_REPO_ID, SUITE_FLAKE_TAIL_ROWS.

parked=<leg>:<age>m[,...] (HIMMEL-2563) follows vmrun= (and flakes= when present), comes
before spare= when present, and is ABSENT
unless a leg's newest trust-ledger row (scripts/trust/shadow-ledger.mjs) is a
permission prompt older than TICK_PARKED_MIN minutes (default 5): the leg is parked on
the auto-mode confirmation dialog, which its fresh lock heartbeat hides. Names only
wake console-wait.sh (a leg joining or leaving the set), never the age. Read via
parked-on-prompt.sh; env seams HIMMEL_TRUST_LEDGER_DIR, TICK_PARKED_TAIL_BYTES.

spare=<pct>@<h>h (HIMMEL-4421) is the very last field and is ABSENT unless the
weekly quota the current burn leaves unspent at the reset (bank-monitor.sh
--spare) is >= TICK_SPARE_MIN percent (default 10) and the reset is <=
TICK_SPARE_HOURS hours away (default 24). Advisory: it is not in console-wait's
action key and wakes nothing.

fails=<n>/<legs>[@<top-class>*<k>][!<recur>][~<skipped>] (HIMMEL-4670) sits just
before spare=: this shift's leg-failures ledger rows (since the console lock's
start), distinct legs, the class most legs hit, the classes the failure router
acted on this shift, and ~<skipped> the leg docs whose wrap digest was skipped
this shift (HIMMEL-4786, leg-digest-step.sh's skips.jsonl; none~<k> with only
skips). fails=none with no rows, fails=? when a ledger or the lock start is
unreadable or the latest wrap digest failed, skip with no --doc. Advisory: not in
console-wait's action key, so it wakes nothing. Env seams:
HIMMEL_LEG_FAILURES_LEDGER, HIMMEL_EVAL_RUNS_LEDGER, HIMMEL_FAILURE_ROUTES_LOG,
LEG_DIGEST_STATE_DIR.

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

deadwin=<label>:closed|held[,...] (HIMMEL-6118) follows closable= and is ABSENT
unless a leg konsole (tabtitle HIMMEL-<n>-N<k>-...) has no child process and is
older than TICK_DEADWIN_GRACE seconds (default 30): its session died. :closed =
tick TERMed the window (the leg's lock is FREE/WRAPPED, or a live <tabtitle>-r<n>
window exists); :held = reported only. console-wait.sh wakes when it appears or
changes. Env seam: TICK_KILL_BIN.

legs= reads a leg's lock as FRESH or STALE (held; an idle-warned lock still reads
FRESH/STALE here -- the IDLE-HELD? flag belongs to the sweep and the exit code),
CLOSABLE (HIMMEL-3747: lock released, the tail says WRAPPED, AND the leg's own
session process is still alive in the census -- the window is sitting there
finished but not yet closed; console-wait.sh wakes on this the same way it
wakes on any other legs= change, since it samples the whole field, so no
change was needed there), WRAPPED (lock released and the tail says WRAPPED,
but either no live session matched or the census itself could not be read --
the normal end of a leg once its window is gone, and also the fail-closed
reading when CLOSABLE cannot be proven), FREE (lock released while the tail
does not say WRAPPED -- a lost lock),
NOLOCK (HIMMEL-5074: a fleet-manifest row marked lockless -- an eval/pilot row
that never takes a queue lock; no lock is read, tails= alone judges it),
UNVERIFIED (a lock named for the doc exists but records a path that does not
resolve here -- neither ruled held nor free: check its owner, never reclaim on
it; HIMMEL-3290), CORRUPT, UNKNOWN (queue-lock status unreadable) or NOTFOUND
(no such doc).

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

board=<ok|STALE:<age>|MISSING|skip> (HIMMEL-3361) is the freshness of the
console's progress board, console-board.html next to the console doc (rendered
by board.mjs -- the ACTION ZERO board step + the standing rule: on every dispatch, GO,
MERGED and WRAPPED, re-render and republish it). ok = the board's embedded
fingerprint equals the one recomputed here from what a board shows (leg locks,
leg tails, open PRs, the queue:, last GO:, epics: and decisions: lines) -- NOT the doc's mtime,
which every Results bullet bumps. STALE:<age> = the board shows an older state
(age = the file's mtime); MISSING = no board was ever rendered; skip = no --doc.
--emit-fp prints a second line, board-fp=<16 hex>, the fingerprint board.mjs
embeds -- one derivation, so the generator and this field cannot disagree.
ponytail: board=ok says the LOCAL file matches the state; tick cannot see
whether the artifact was republished from it -- that stays the console's step.

station=BEHIND:<component>,... (HIMMEL-5945) appears only when the last station-sync.sh
run left a component behind main (state file TICK_STATION_STATE, default
~/.himmel/state/station-sync.state); it clears on the next sync. Follows parked=.

vault=<ok|STALL:<age>,<n>|PUSH-LAG:<age>|skip|unknown> (HIMMEL-4911) is the luna
vault's commit health, from vault-status.sh (git plumbing only, fail-soft): STALL =
<n> staged/modified files, the oldest <age> old (the vault's auto-commit is stuck;
reproduce with the vault's pre-commit hook run, see console-wait.sh), PUSH-LAG = local commits
unpushed for <age>. skip = no vault configured (TICK_VAULT_DIR, else the handover
root's parent). Thresholds: TICK_VAULT_STALL_MIN (20), TICK_VAULT_PUSHLAG_MIN (60).
Sits between tracker= and denials=; console-wait.sh wakes on a class change to
STALL/PUSH-LAG only.

cloud=<ok|STALL:<ticket>[,<ticket>...]|skip> (HIMMEL-5163) is the liveness of the
claude.ai cloud sessions in the bucket's cloud-sessions.tsv (next to --doc), from
cloud-liveness.mjs: STALL = a session with no branch/PR N min after launch, an open
PR with no CLOUD-DONE and no commit for M min, or a CLOUD-DONE no live leg doc names.
skip = no tsv, no --doc, or the forge unreadable. ONE `gh pr list` (inside the gql
budget) and one ls-remote, both timeout-bounded. Thresholds: CLOUD_LIVENESS_BRANCH_MIN
(30), _PR_MIN (60), _DONE_MIN (15), _WINDOW_H (48). Sits after vault=;
console-wait.sh wakes on a class change to STALL only. board.mjs lists each session.

denials=<leg>:<n>[:SHIP-STEP|REPEAT|PAUSE-RISK] (HIMMEL-3724) is classifier
denials seen by scripts/hooks/log-classifier-denial.sh in a trailing window
(TICK_DENIALS_WINDOW_MIN minutes, default 30), grouped by the hook's own
session_title (a worktree slug; any other cwd reads <dir>#<session_id[0:8]>),
one leg per csv entry, joined ",". SHIP-STEP = a denied
ship-step command; PAUSE-RISK = 3+ in the window or an all-time total
approaching the auto-mode pause threshold; REPEAT = 2+ in the window with
neither. denials=none when the window is empty or the log does not exist yet;
denials=skip when jq is missing or the log is unreadable.

ready-mismatch=<flagged>/<ready>,nogo=<k>/<judged>[,ALERT] (HIMMEL-6032) sits with
flakes= and is ABSENT unless a READY (leg docs under the console doc's directory, touched
within TICK_READY_WINDOW_DAYS, default 1) is flagged: a judge NO-GO'd its exact head, or the
PR's files hit scripts/ci/ci-trust-paths.txt while the READY claimed no trust path or said
nothing. ALERT = any trust-path claim mismatch, a NO-GO-at-head rate over 40 percent (5+
judged) or one model at 2x the fleet rate (10+ judged). Changed-file lists are cached under
$TICK_STATE_DIR/ready-files, at most 20 uncached gh calls per tick (TICK_GH_CMD seam) and
TICK_READY_BUDGET_SEC (default 30) of wall clock; a scan that ran out reads ,partial.
--ready-mismatch [--ready-dir DIR] prints the per-READY TSV rows instead of a tick line.

ciq=<in_progress>/<cap>,mac=<n>/<cap>,q=<queued>,wait=<m>m[,SATURATED]
(HIMMEL-3840) is the GitHub Actions queue, from one scripts/ci/queue-latency.sh
probe per tick (bounded by TICK_CIQ_TIMEOUT seconds, default 45). SATURATED =
jobs_in_progress at the cap on two consecutive probes: hold dispatches until it
clears. ciq=unknown = the probe failed, timed out or is missing; it neither
sets nor clears the saturation state ($TICK_STATE_DIR/tick-ciq-last, default
~/.himmel/state). Not part of console-wait's wake key.

--burn adds a per-leg context-burn field (first-turn/avg-ctx, via
scripts/lanes/leg-burn.sh) for every doc in --legs. OPT-IN because it scans
the Claude Code transcript root, which a plain tick must never do: a tick runs
on a wake-up budget and this reads every project's transcripts.
USAGE
}

verbose=0
burn=0
emit_fp=0
ready_mode=0
ready_dir=""
DOC="${DOC:-}"
TOKEN="${TOKEN:-}"
LEGS="${LEGS:-}"
LEGS_FROM="${LEGS_FROM:-}"
REPO="${REPO:-$(cd "$HERE/../../.." && pwd)}"

while [ "$#" -gt 0 ]; do
    case "$1" in
        --verbose) verbose=1; shift ;;
        --burn) burn=1; shift ;;
        --emit-fp) emit_fp=1; shift ;;
        --ready-mismatch) ready_mode=1; shift ;;
        --doc|--token|--legs|--legs-from|--handover-dir|--repo|--ready-dir)
            [ "$#" -ge 2 ] || { usage >&2; exit 2; }
            case "$1" in
                --doc) DOC="$2" ;;
                --token) TOKEN="$2" ;;
                --legs) LEGS="$2" ;;
                --legs-from) LEGS_FROM="$2" ;;
                --handover-dir) HANDOVER_DIR="$2" ;;
                --repo) REPO="$2" ;;
                --ready-dir) ready_dir="$2" ;;
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

# the fleet manifest is re-read on every run. An unreadable one is
# a failed tick (before the heartbeat or any other side effect), never an empty
# fleet that reads as every leg gone.
from_docs=""
if [ -n "$LEGS_FROM" ] && ! from_docs="$(bash "$HERE/fleet-manifest.sh" list "$LEGS_FROM")"; then
    printf 'tick: cannot read fleet manifest: %s\n' "$LEGS_FROM" >&2
    exit 1
fi

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

# a leg doc's label (N<k>) and the session names it may run under
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

# leg_tail_status is shared with close-wrapped-leg.sh's WRAPPED
# gate, so the two readers can never accept different marker-bullet shapes.
# shellcheck source=../../lib/leg-tail-status.sh
. "$HERE/../../lib/leg-tail-status.sh"

# ready_mismatch_scan <bucket-dir> -- READY claims a judge or the diff contradicts
# Prints TSV: one `M1a|M1b|M1c <pr> <head12> <model>` row per flag,
# `COUNT <ready> <flagged> <judged> <nogo> <unchecked>`, one `MODEL <m> <judged> <nogo>`
# row per model, and `ALERT <reason>` rows. rc 1 = nothing to read (no bucket, no list).
#   M1a  the READY head is the head a judge record NO-GO'd: any <bucket>/verdicts/<qid>/*.md
#        carrying a `pr: <n>` line and a `**NO-GO** for head` line at the full head
# A scan past TICK_READY_BUDGET_SEC (default 30) stops reading gh, counts the rest
# unchecked and prints a `PARTIAL` row.
#   M1b  the READY says it touches no trust path, the PR's files hit ci-trust-paths.txt
#   M1c  the PR's files hit ci-trust-paths.txt, the READY never mentions trust
# Changed-file lists come from the ready-files cache under TICK_STATE_DIR (keyed
# <pr>-<head>, so a re-pushed head is a fresh row); a miss costs one `gh pr view`,
# at most 20 per scan, and past that the READY is counted unchecked, never clean.
# ponytail: window is the leg doc's mtime (TICK_READY_WINDOW_DAYS, default 1), a READY
# head repeated across docs counts once but a reworded one twice, the no-trust regex
# reads a docs-only claim as "no trust path", and the model is the doc title's (claude-...)
# token; a structured READY record would replace the regexes.
ready_mismatch_scan() {
    local dir="$1" tp="$REPO/scripts/ci/ci-trust-paths.txt" days="${TICK_READY_WINDOW_DAYS:-1}"
    local cache="${TICK_STATE_DIR:-$HOME/.himmel/state}/ready-files" ghcmd="${TICK_GH_CMD:-gh}"
    local budget=20 pats rec vidx cap t0 partial=0 left doc model line pr head claim files hit jv
    [ -d "$dir" ] && [ -r "$tp" ] || return 1
    case "$days" in ''|*[!0-9]*) days=1 ;; esac
    local window_min=$((10#$days * 1440))
    pats="$(mktemp)" && rec="$(mktemp)" && vidx="$(mktemp)" || return 1
    grep -vE '^[[:space:]]*(#|$)' "$tp" > "$pats"
    cap="${TICK_READY_BUDGET_SEC:-30}"
    case "$cap" in ''|*[!0-9]*) cap=30 ;; esac
    t0=$SECONDS
    # verdict index, one `<pr> <head> GO|NO-GO` row per record: judges file by qid
    # (verdicts/<qid>/<name>.md) and name the PR on a `pr:` line inside
    # shellcheck disable=SC2016  # the backticks are literal verdict text
    find "$dir/verdicts" -mindepth 2 -maxdepth 2 -name '*.md' -print0 2>/dev/null | xargs -0 -r awk '
        FNR == 1 { v = ""; h = ""; p = ""; emitted = 0 }
        v == "" && match($0, /^\*\*(NO-GO|GO)\*\* for head `/) {
            h = substr($0, RLENGTH + 1, 40)
            if (h ~ /^[0-9a-f]+$/ && length(h) == 40) v = ($0 ~ /^\*\*NO-GO/) ? "NO-GO" : "GO" }
        p == "" && /^pr: [0-9]+[ \t]*$/ { p = $2 }
        v != "" && p != "" && !emitted { print p, h, v; emitted = 1 }' > "$vidx"  # swallow-ok: no verdict files leaves the judge column at none
    mkdir -p "$cache" 2>/dev/null
    while read -r doc; do
        model="$(sed -nE 's/^# .*\((claude-[A-Za-z0-9.-]+)[,)].*/\1/p' "$doc" | head -n 1)"
        [ -n "$model" ] || model=unknown
        while read -r line; do
            pr="$(printf '%s\n' "$line" | sed -nE 's/^.*READY[^0-9a-f]*([0-9]+)[[:space:]]+([0-9a-f]{40}).*$/\1/p')"
            head="$(printf '%s\n' "$line" | sed -nE 's/^.*READY[^0-9a-f]*([0-9]+)[[:space:]]+([0-9a-f]{40}).*$/\2/p')"
            [ -n "$pr" ] && [ -n "$head" ] || continue
            grep -q "^$pr	$head	" "$rec" && continue
            if printf '%s\n' "$line" | grep -qiE 'no (ci[- ])?trust[- ]paths?|trust[- ]paths?: (none|no)\b|not a trust path|docs[- ]only|touch(es)? no trust|trust[- ]paths?:? (not touched|untouched)|not touch(es)? (a |any )?(ci[- ])?trust'; then claim=none
            elif printf '%s\n' "$line" | grep -qi 'trust'; then claim=named
            else claim=silent; fi
            files=""
            if [ -r "$cache/$pr-$head" ]; then
                files="$(cat "$cache/$pr-$head")"
            elif [ -n "$(find "$cache" -maxdepth 1 -name "$pr-$head.fail" -mmin -15 2>/dev/null)" ]; then  # swallow-ok: an unreadable cache means no backoff, the budget still bounds the calls
                :  # a lookup that failed in the last 15 minutes is not retried, so it cannot starve later READYs
            elif [ "$budget" -gt 0 ] && [ $((SECONDS - t0)) -ge "$cap" ]; then
                partial=1  # the wall-clock budget is spent: this READY stays unchecked
            elif [ "$budget" -gt 0 ]; then
                budget=$((budget - 1))
                left=$((cap - (SECONDS - t0)))
                [ "$left" -gt 10 ] && left=10
                [ "$left" -ge 1 ] || left=1
                # the first line is the PR's current head: a list read after a later push is not this READY's diff
                if files="$(cd "$REPO" && timeout -k 2 "$left" "$ghcmd" pr view "$pr" --json headRefOid,files -q '.headRefOid, .files[].path' 2>/dev/null)" && [ "${files%%$'\n'*}" = "$head" ]; then  # swallow-ok: a failed gh read leaves hit="?", counted unchecked, never clean
                    files="${files#*$'\n'}"
                    printf '%s\n' "$files" > "$cache/$pr-$head" 2>/dev/null
                else
                    files=""
                    : > "$cache/$pr-$head.fail"
                fi
            fi
            if [ -z "$files" ]; then hit="?"
            elif printf '%s\n' "$files" | grep -Eq -f "$pats"; then hit=1
            else hit=0; fi
            jv=none
            if grep -qx "$pr $head NO-GO" "$vidx"; then jv=NO-GO
            elif grep -qx "$pr $head GO" "$vidx"; then jv=GO; fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$pr" "$head" "$model" "$claim" "$hit" "$jv" >> "$rec"
        done < <(grep -E '^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?READY[^A-Za-z0-9_]' "$doc" 2>/dev/null)
    done < <(find "$dir" -maxdepth 1 -name '*.md' -mmin "-$window_min" 2>/dev/null | sort)
    awk -F'\t' '
        { r++; m[$3]++; if ($5 == "?") unc++
          if ($6 != "none") { j++; mj[$3]++ }
          if ($6 == "NO-GO") { n++; mn[$3]++ }
          f = 0
          if ($6 == "NO-GO") { f = 1; printf "M1a\t%s\t%s\t%s\n", $1, substr($2, 1, 12), $3 }
          if ($5 == "1" && $4 == "none") { f = 1; printf "M1b\t%s\t%s\t%s\n", $1, substr($2, 1, 12), $3; tm++ }
          if ($5 == "1" && $4 == "silent") { f = 1; printf "M1c\t%s\t%s\t%s\n", $1, substr($2, 1, 12), $3; tm++ }
          flagged += f }
        END { printf "COUNT\t%d\t%d\t%d\t%d\t%d\n", r, flagged, j, n, unc
              for (k in m) printf "MODEL\t%s\t%d\t%d\n", k, mj[k], mn[k]
              if (tm > 0) printf "ALERT\ttrust-path claim mismatch x%d\n", tm
              if (j >= 5 && n * 100 > j * 40) printf "ALERT\tNO-GO-at-head rate %d%% over 40%%\n", n * 100 / j
              for (k in m) if (mj[k] >= 10 && n > 0 && mn[k] * j >= 2 * n * mj[k]) printf "ALERT\t%s NO-GO rate at 2x the fleet\n", k }
    ' "$rec"
    [ "$partial" -eq 0 ] || printf 'PARTIAL\t%s\n' "$cap"
    rm -f "$pats" "$rec" "$vidx"
}

clock="$(date +%H:%M 2>/dev/null)" || clock="??:??"

console_doc=""
[ -n "$DOC" ] && console_doc="$(resolve_doc "$DOC")"
if [ "$ready_mode" -eq 1 ]; then
    [ -n "$ready_dir" ] || ready_dir="${console_doc%/*}"
    ready_mismatch_scan "$ready_dir" || { echo "tick: no READY data under '$ready_dir'" >&2; exit 1; }
    exit 0
fi
hb=skip
if [ -n "$console_doc" ] && [ -n "$TOKEN" ]; then
    if bash "$REPO/scripts/handover/queue-lock.sh" heartbeat "$console_doc" "$TOKEN" >/dev/null 2>&1; then
        hb=ok
    else
        hb=fail
    fi
fi

# --legs accepts space- and/or comma-separated entries. `for leg
# in $LEGS` word-splits on IFS whitespace only, so a comma-joined value was
# silently one iteration over one nonexistent path. Normalize commas to
# spaces once so both loops below (this one and the --burn loop) split
# identically regardless of which separator was used.
LEGS_SPLIT="${LEGS//,/ }"
# --legs-from adds the fleet manifest's docs (read above, before
# any side effect). A doc named on both is judged once (first spelling wins),
# compared by the path it resolves to, so a relative --legs entry matches its
# absolute manifest entry.
if [ -n "$LEGS_FROM" ]; then
    legs_seen=" "
    legs_union=""
    for leg in $LEGS_SPLIT $from_docs; do
        leg_key="$(resolve_doc "$leg")"
        case "$legs_seen" in *" $leg_key "*) continue ;; esac
        legs_seen="$legs_seen$leg_key "
        legs_union="$legs_union $leg"
    done
    LEGS_SPLIT="$legs_union"
fi

# a leg that never went LIVE (a backgrounded or forked launch that
# lost its preface, so it never took its lock or wrote a bullet) holds the same
# FREE a lost lock does, forever, so the waiter's key never moved and nothing
# woke the console. NOLIVE is FREE plus a clock; FORKED is FREE plus a
# transcript that ended in a continued-in record. Both are legs= labels only --
# lock_status itself (procs=, closable, held_legs) is untouched.
nolive_min="${TICK_NOLIVE_MIN:-10}"
case "$nolive_min" in ''|*[!0-9]*) nolive_min=10 ;; esac
nolive_min=$((10#$nolive_min))
# the leg preface's GO-hold is 30 minutes; a READY older than that
# with no GO file reads READY!stale in tails=.
go_stale_min="${TICK_GO_STALE_MIN:-30}"
case "$go_stale_min" in ''|*[!0-9]*) go_stale_min=30 ;; esac
go_stale_min=$((10#$go_stale_min))

# launch_dir_default: the console work dir the <name>.launch.log files live in.
launch_dir_default() {
    if [ -n "${TICK_LAUNCH_DIR:-}" ]; then
        printf '%s\n' "$TICK_LAUNCH_DIR"
    elif [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR/himmel-console" ]; then
        printf '%s\n' "$XDG_RUNTIME_DIR/himmel-console"
    else
        printf '%s\n' "${TMPDIR:-/tmp}/himmel-console-$(id -u)"
    fi
}

# leg_start_epoch <leg doc> <candidate names, comma list> -- when the leg was
# dispatched: the fleet manifest's `added` time, else the newest launch-log
# `armed:` line naming the doc or a candidate session, else the doc's mtime.
leg_start_epoch() {
    local doc="$1" cands="$2" t="" ts line armed
    if [ -n "$LEGS_FROM" ] && [ -r "$LEGS_FROM" ]; then
        ts="$(jq -r --arg d "$doc" '[.legs[] | select(.doc == $d) | .added][0] // empty' "$LEGS_FROM" 2>/dev/null)" || ts=""
        [ -z "$ts" ] || t="$(date -d "$ts" +%s 2>/dev/null)" || t=""  # gnu-ok: Linux-only kit
    fi
    if [ -z "$t" ]; then
        armed="$(find "$(launch_dir_default)" -maxdepth 2 -name '*.launch.log' -exec grep -hF ' armed: name=' {} + 2>/dev/null)"  # gnu-ok: Linux-only kit
        line="$(printf '%s\n' "$armed" | awk -v d="doc=$doc" -v c=",$cands," '
            { n = $3; sub(/^name=/, "", n); if (index(c, "," n ",") || index($0, " " d " ")) { if ($1 > last) last = $1 } }
            END { if (last != "") print last }')"
        if [ -n "$line" ]; then
            t="$(date -d "${line/_/ }" +%s 2>/dev/null)" || t=""  # gnu-ok: Linux-only kit
        fi
    fi
    [ -n "$t" ] || t="$(stat -c %Y "$doc" 2>/dev/null)" || t=""  # gnu-ok: Linux-only kit
    printf '%s' "$t"
}

# leg_forked <candidate names, comma list> -- succeeds when the newest session
# transcript whose custom-title IS one of the names ends in a continued-in
# record. The title is the only link (the harness writes it from `claude -n`);
# no transcript found = not forked, never a guess.
leg_forked() {
    local dir="${TICK_PROJECTS_DIR:-$HOME/.claude/projects}" cand f newest=""
    [ -d "$dir" ] || return 1
    for cand in ${1//,/ }; do
        while IFS= read -r f; do
            [ -n "$f" ] || continue
            if [ -z "$newest" ] || [ "$f" -nt "$newest" ]; then newest="$f"; fi
        done < <(find "$dir" -maxdepth 2 -name '*.jsonl' -mmin "-${TICK_FORK_WINDOW_MIN:-1440}" -exec grep -lF "\"customTitle\":\"$cand\"" {} + 2>/dev/null)  # gnu-ok: Linux-only kit
    done
    [ -n "$newest" ] || return 1
    # the last record that is not a trailing cost-state: a resumed session appends
    # assistant/user records after its continued-in, so only the final one counts.
    grep -v '"type":"cost-state"' "$newest" 2>/dev/null | tail -n 1 | grep -q '"type":"continued-in"'  # pipefail-ok: tail reads its input to EOF and grep -q sees one line, so no SIGPIPE upstream
}

legs_summary=""
tails_summary=""
leg_docmap=""
# label<TAB>lock status<TAB>candidate session names, one line per leg (procs= below).
leg_candmap=""
# the census names the -n session the console actually passed
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
    # NOTFOUND (file does not resolve) is a distinct status from
    # MISSING. MISSING means "the lock is gone" -- exactly the signal a
    # console reads as "reclaim this leg's lock" -- and must never be used for
    # "I could not find the file", which is a warning, not a lock verdict.
    lock_status=NOTFOUND
    tail_status="?"
    if [ -f "$leg_doc" ]; then
        # a lockless manifest row (an eval/pilot row that never takes a
        # queue lock) reads NOLOCK, not FREE, and is judged by its tail marker alone.
        row_lockless=0
        if [ -n "$LEGS_FROM" ] && [ -r "$LEGS_FROM" ] \
            && jq -e --arg d "$leg_doc" 'any(.legs[]; .doc == $d and .lockless == true)' "$LEGS_FROM" >/dev/null 2>&1; then
            row_lockless=1
        fi
        if [ "$row_lockless" -eq 1 ]; then
            lock_status=NOLOCK
        else
            lock_out="$(bash "$REPO/scripts/handover/queue-lock.sh" status "$leg_doc" 2>&1)" || true
            case "$lock_out" in
                *'status: FRESH'*) lock_status=FRESH ;;
                *'status: STALE-DEAD'*) lock_status=STALE-DEAD ;;   # HIMMEL-5541: not held; held_legs / held_n skip it
                *'status: STALE'*) lock_status=STALE ;;
                *UNVERIFIED*) lock_status=UNVERIFIED ;;
                free*) lock_status=FREE ;;
                *CORRUPT*) lock_status=CORRUPT ;;
                *) lock_status=UNKNOWN ;;
            esac
        fi
        tail_status="$(leg_tail_status "$leg_doc")"
        [ -n "$tail_status" ] || tail_status="?"
        # a READY whose GO file (<root>/.locks/go/<pr>.<head>) is still
        # absent after $go_stale_min minutes reads READY!stale. tails= is in the
        # console-wait action key, so the entry moving once wakes the console.
        # ponytail: READY age is the leg doc's mtime (a READY leg is idle, so the
        # READY bullet is the last write); a READY bullet with no `<pr> <head>`
        # cannot name a GO file and never goes stale; upgrade = parse the
        # bullet's HH:MM if a doc touched after READY ever hides a stale one.
        if [ "$tail_status" = READY ]; then
            ready_line="$(grep -E '^- ([0-9]{1,2}:[0-9]{2}[[:space:]]+)?(\*\*)?READY[^A-Za-z0-9_]' "$leg_doc" 2>/dev/null | tail -n 1)" || ready_line=""  # pipefail-ok: tail reads its input to EOF
            ready_pr="$(printf '%s\n' "$ready_line" | sed -nE 's/^.*READY[^0-9a-f]*([0-9]+)[[:space:]]+([0-9a-f]{40}).*$/\1/p')"
            ready_head="$(printf '%s\n' "$ready_line" | sed -nE 's/^.*READY[^0-9a-f]*([0-9]+)[[:space:]]+([0-9a-f]{40}).*$/\2/p')"
            ready_m="$(stat -c %Y "$leg_doc" 2>/dev/null)" || ready_m=""  # gnu-ok: Linux-only kit
            if [ -n "$ready_pr" ] && [ -n "$ready_head" ] && [ -n "$root" ] \
                && [ ! -e "$root/.locks/go/$ready_pr.$ready_head" ]; then
                case "$ready_m" in
                    ''|*[!0-9]*) ;;
                    *) if [ $(( $(date +%s) - ready_m )) -ge $(( go_stale_min * 60 )) ]; then tail_status="READY!stale"; fi ;;
                esac
            fi
        fi
        # FREE used to cover both "released cleanly at wrap" and "the
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
    # FREE with no marker bullet ever (tails ?) is a leg that never
    # went LIVE; that, or a transcript that ended in continued-in, shows in legs=
    # in place of FREE. A wrapped or marker-bearing leg is never relabelled.
    # ponytail: the clock is dispatch time, so a leg first listed after the
    # threshold baselines already NOLIVE and the waiter stays silent for it;
    # upgrade = wake on first sight of a NOLIVE, if that ever bites.
    leg_label_state="$lock_status"
    if [ -f "$leg_doc" ] && [ "$lock_status" = FREE ] && [ "$tail_status" = "?" ]; then
        if leg_forked "$leg_cands"; then
            leg_label_state=FORKED
        else
            leg_t="$(leg_start_epoch "$leg_doc" "$leg_cands")"
            if [ -n "$leg_t" ] && [ $(( $(date +%s) - leg_t )) -ge $(( nolive_min * 60 )) ]; then
                leg_label_state=NOLIVE
            fi
        fi
    fi
    legs_summary="$(csv_add "$legs_summary" "$label:$leg_label_state")"
    tails_summary="$(csv_add "$tails_summary" "$label:$tail_status")"
    leg_docmap="$leg_docmap$label=$leg_doc"$'\n'
    leg_candmap="$leg_candmap$label"$'\t'"$lock_status"$'\t'"$leg_cands"$'\n'
done
# #1335: legs_summary's "none" default is resolved further down, once
# the census (below) says whether it can back that up -- see the comment
# there.
[ -n "$tails_summary" ] || tails_summary=none

# cross-reference the console doc's own `## Live state`
# `legs:` line against the lock status just computed above (legs_summary),
# the same way ceiling_summary below cross-references argv against a
# separate invariant. "skip" (no --doc given, same as hb=skip above) and
# "unknown" (doc given but no `## Live state`/`legs:` line found -- e.g. a
# an older doc) are both distinct from "ok": neither says the state
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
# A file name is a cite, never a label: leg_label strips `.md` from
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
# span on the line. `entries` prints each well-formed
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
    # The legs: BLOCK, not just the first `legs:` line: every
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
        # but a bare N<k> never parsed and read as absent.
        # Prose on the line is tolerated: a backticked token is
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
        # the leg set this tick watches is the --legs arm, and Live
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
        # a HELD leg whose Live-state nonce (`<LETTER>-<leg>-<hex>`)
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
                    # be exactly this console. Only the `## Results` section
                    # is read: an acceptance-shaped line quoted
                    # above it, or under a later `## ` heading, confirms
                    # nothing.
                    accepted="$(awk '/^## /{ r = ($0 ~ /^## Results([[:space:]]|$)/) } r' "$span_doc" 2>/dev/null | sed -n -E 's/^- .*SUCCESSION accepted:[^A-Za-z0-9]*([A-Za-z0-9_.-]+).*/\1/p' | tail -n 1)"
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

# name/model come from claude_sessions() (real
# /proc/<pid>/cmdline argv, NUL-delimited), never a flattened `pgrep -af`
# line -- free-text argv (a -p/--append-system-prompt value containing the
# literal substring "-n X") can no longer spoof procs=/models=.
# #1335: resolved from $HERE (this script's own directory), not
# $REPO -- $REPO names the repo THIS console manages (a different checkout
# for every console but himmel's own), while claude-sessions.sh is a himmel
# lane helper that always ships beside tick.sh. $REPO-relative sourcing
# silently failed for any non-himmel $REPO (source: No such file or
# directory), leaving claude_sessions undefined while the tick still printed
# a confident line.
# shellcheck source=../../lanes/lib/claude-sessions.sh
. "$HERE/../../lanes/lib/claude-sessions.sh"
sessions_out="$(claude_sessions)"
sessions_rc=$?
# rc=3 means the census itself succeeded but one or more live
# sessions had an unreadable cmdline -- the readable rows above are still
# trustworthy, so keep them (unlike a real scan failure, rc>1 and not 3,
# where the whole table is suspect and gets discarded below). CAVEAT
# (claude-sessions.sh, same ticket): pgrep's own fatal-error rc is ALSO 3,
# forwarded with no output printed first -- ceiling-conformance.sh already
# tells the two apart by whether sessions_out is empty at rc=3; mirror that
# here so census_failed below is not blind to it.
census_failed=0
if [ "$sessions_rc" -gt 1 ] && { [ "$sessions_rc" -ne 3 ] || [ -z "$sessions_out" ]; }; then
    sessions_out=""
    census_failed=1
fi
# #1335: an empty --legs arm reads legs=none only when the census could
# actually have told us otherwise. A working census (however lossy) that
# simply finds nothing live is a genuine healthy empty fleet -- legs=none
# stays accurate. A census that could not run at all (pgrep/ps themselves
# broken, not merely lossy) leaves this tick with no way to back that claim
# up, so legs=none would be a guess; legs=unsupported says so instead. A
# non-empty --legs arm is unaffected: its legs_summary already comes from
# queue-lock, not the census.
if [ -z "$legs_summary" ]; then
    if [ "$census_failed" -eq 1 ]; then
        legs_summary=unsupported
    else
        legs_summary=none
    fi
fi
sessions_lossy=0
case "$sessions_out" in
    '# lossy'|$'# lossy\n'*) sessions_lossy=1 ;;
esac
unreadable_n=0
if [ "$sessions_rc" -eq 3 ]; then
    unreadable_n="$(printf '%s\n' "$sessions_out" | grep -c '^# unreadable ')"
fi

# count sessions the console actually dispatched (leg_names,
# built from --legs above) against the census name, not a "-leg" spelling
# guess -- a filter that silently matches nothing must never render as 0.
#
# that guard only asked whether the filter EXISTS. A well-formed
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
# a relaunched leg runs as <name>-r<N>: list the base name too, so it
# joins to its leg for procs=, unwatched= and CLOSABLE.
census_names="$(printf '%s\n' "$sessions_out" | awk -F'\t' '$1 !~ /^#/ && NF >= 4 && $2 != "" { print $2; b = $2; if (sub(/-r[0-9]+$/, "", b)) print b }')"
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
closable_n=0
# a WRAPPED leg (lock free, tail says WRAPPED) whose own
# session process is STILL alive in this same census is CLOSABLE -- the
# window sitting there finished but not yet closed is exactly what a console
# should wake up and act on. Never claimed when the census itself could not
# be trusted (census_failed=1): fail closed to plain WRAPPED, same posture as
# the matched_n/unmatched_csv derivation above.
if [ "$census_failed" -eq 0 ]; then
    while IFS=$'\t' read -r w_label w_status w_cands; do
        [ -n "$w_label" ] || continue
        [ "$w_status" = WRAPPED ] || continue
        for w_cand in ${w_cands//,/ }; do
            if grep -Fxq -- "$w_cand" <<< "$census_names"; then
                legs_summary="${legs_summary//$w_label:WRAPPED/$w_label:CLOSABLE}"
                # closable=<n>: only a window that has sat finished for
                # TICK_CLOSABLE_MIN minutes (the doc's mtime: a wrapped leg writes
                # nothing more), so the close the console is doing right now never wakes it.
                w_doc="$(printf '%s' "$leg_docmap" | sed -n "s/^$w_label=//p" | head -n 1)"
                w_mt=""
                [ -z "$w_doc" ] || w_mt="$(stat -c %Y "$w_doc" 2>/dev/null)" || w_mt=""  # gnu-ok: Linux-only kit
                case "${TICK_CLOSABLE_MIN:-5}" in ""|*[!0-9]*) w_min=5 ;; *) w_min=$((10#${TICK_CLOSABLE_MIN:-5})) ;; esac
                if [ -n "$w_mt" ] && [ $(( $(date +%s) - w_mt )) -ge $(( w_min * 60 )) ]; then
                    closable_n=$((closable_n + 1))
                fi
                break
            fi
        done
    done <<< "$leg_candmap"
fi
leg_names_wrapped=",${leg_names},"
# procs= counts only the sessions THIS arm names, so a live leg the
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
    # A field that cannot be computed must say so (NOTFOUND-vs-
    # MISSING, unreadable=): procs=0 and procs=unknown must be
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
    # a degraded scan (rc=3) still counted every readable row
    # above -- append how many pids it could NOT read so the console sees
    # the table is incomplete rather than reading procs= as a clean, complete
    # count.
    [ -z "$unmatched_csv" ] || procs="${procs},unmatched=${unmatched_csv}"
    [ -z "$unwatched_plus" ] || procs="${procs},unwatched=${unwatched_plus}"
    [ "$unreadable_n" -gt 0 ] && procs="${procs},unreadable=${unreadable_n}"
fi

# same session table and leg filter as procs= above, bucketed by
# the tier its real --model argv names (opus/fable cost materially more per
# turn than the sonnet default - CLAUDE.md "raise effort before tier"). Any
# non-Claude id (e.g. a claudex gpt-* model) buckets under "other" rather than
# one unbounded per-model list. A leg matched by the same filter but carrying
# no --model token at all buckets under "unknown"
# rather than falling out of every bucket while still counted in
# procs=.
# same dispatched-name filter as procs= above, same
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
    # /proc absent (macOS, git-bash) degrades claude_sessions()
    # to the old flattened-line parse -- flag it inline (no space, so the
    # tick line stays space-delimited) rather than silently reporting a scan
    # that could again be spoofed by free-text argv.
    [ "$sessions_lossy" -eq 0 ] || models_summary="${models_summary}(lossy)"
fi

# the same ps table, scanned for --autocompact drift against the
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

# Open PRs are the project's, not himmel's: a console always runs in himmel, and
# console.sh records the checkout it is FOR on the doc's project line (`none --
# ...` for himmel itself). board.mjs reads the same line, so board-fp stays in step.
pr_repo="$REPO"
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    # shellcheck disable=SC2016  # single-quoted sed pattern; no expansion wanted
    doc_project="$(sed -n 's/.*The project this console is FOR is \*\*`\([^`]*\)`\*\*.*/\1/p' "$console_doc" | head -n 1)"
    case "$doc_project" in /*) pr_repo="$doc_project" ;; esac
fi
pr_out="$(cd "$pr_repo" 2>/dev/null && gh pr list --limit 200 --json number,headRefName,isDraft,author,isCrossRepository,updatedAt --jq '.[] | [.number, .headRefName, .isDraft, .author.login, .isCrossRepository, .updatedAt] | @tsv' 2>/dev/null)" || { pr_out=""; pr_read_failed=1; }

# unowned-prs= / ext-prs=: an open PR whose head branch names a ticket that
# no leg this tick reads holds (a held or lockless lock), and no recent cloud session
# covers, has no one working it. Fork PRs are listed apart, drafts and PRs younger than
# the grace period never. Built from the one gh read above: no per-PR call.
# ponytail: ownership is the ticket key in the branch name, so a branch with no key reads
# unowned (loud, not silent), and age is the PR's updatedAt, which a comment also moves;
# upgrade = match the leg's own branch, or the last commit's date, if either bites.
ticket_key() { printf '%s\n' "$1" | grep -oiE '[a-z][a-z0-9]*-[0-9]+' | head -n 1 | tr '[:lower:]' '[:upper:]'; }
owner_keys=" "
while IFS=$'\t' read -r o_label o_lock _; do
    case "$o_lock" in FRESH|STALE|NOLOCK|UNVERIFIED) ;; *) continue ;; esac
    o_doc="$(printf '%s' "$leg_docmap" | sed -n "s/^$o_label=//p" | head -n 1)"
    o_key="$(ticket_key "${o_doc##*/}")"
    [ -z "$o_key" ] || owner_keys="$owner_keys$o_key "
done <<< "$leg_candmap"
cloud_tsv=""
[ -n "$console_doc" ] && cloud_tsv="${console_doc%/*}/cloud-sessions.tsv"
if [ -n "$cloud_tsv" ] && [ -f "$cloud_tsv" ]; then
    cloud_window_s=$(( ${CLOUD_LIVENESS_WINDOW_H:-48} * 3600 ))
    while IFS=$'\t' read -r c_time c_key _; do
        c_at="$(date -d "$c_time" +%s 2>/dev/null)" || continue  # gnu-ok: Linux-only kit
        [ $(( $(date +%s) - c_at )) -le "$cloud_window_s" ] && owner_keys="$owner_keys$c_key "
    done < "$cloud_tsv"
fi
unowned_grace_min="${TICK_UNOWNED_GRACE_MIN:-10}"
prs=""
unowned_prs=""
ext_prs=""
while IFS=$'\t' read -r pr pr_branch pr_draft _ pr_fork pr_updated; do
    case "$pr" in ''|*[!0-9]*) continue ;; esac
    prs="$(csv_add "$prs" "#$pr")"
    [ -n "$pr_branch" ] || continue
    if [ "$pr_fork" = true ]; then ext_prs="$(csv_add "$ext_prs" "#$pr")"; continue; fi
    [ "$pr_draft" = true ] && continue
    pr_key="$(ticket_key "$pr_branch")"
    if [ -n "$pr_key" ]; then
        case "$owner_keys" in *" $pr_key "*) continue ;; esac
    fi
    pr_at="$(date -d "$pr_updated" +%s 2>/dev/null)" || continue  # gnu-ok: Linux-only kit
    pr_age=$(( ($(date +%s) - pr_at) / 60 ))
    [ "$pr_age" -ge "$unowned_grace_min" ] || continue
    unowned_prs="$(csv_add "$unowned_prs" "#$pr:${pr_age}m")"
done <<< "$pr_out"
[ -n "$prs" ] || prs=none
[ -n "$unowned_prs" ] || unowned_prs=none
[ -n "$ext_prs" ] || ext_prs=none
# A failed read is not an all-clear: `?` lets the waiter keep its marker instead of counting it as none.
[ -z "${pr_read_failed:-}" ] || { unowned_prs='?'; ext_prs='?'; }

# the board fingerprint -- what console-board.html shows that the
# console authors or a tick already reads: leg locks, leg tails, open PRs, and
# the queue:, last GO:, epics: and decisions: lines. Not the doc mtime (every
# Results bullet bumps that). board.mjs embeds this exact value via --emit-fp.
# ponytail: CI colour and fleet capacity are shown on the board but deliberately
# outside the fingerprint -- they move without a console act, so including them
# would read STALE for changes the console cannot republish for.
board_fp=""
board_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    board_queue="$(grep -m1 '^queue:' "$console_doc" 2>/dev/null)" || board_queue=""
    board_lastgo="$(grep -m1 '^last GO:' "$console_doc" 2>/dev/null)" || board_lastgo=""
    board_epics="$(grep -m1 '^epics:' "$console_doc" 2>/dev/null)" || board_epics=""
    board_decisions="$(grep -m1 '^decisions:' "$console_doc" 2>/dev/null)" || board_decisions=""
    board_fp="$(printf '%s\n%s\n%s\n%s\n%s\n%s\n%s\n' "$legs_summary" "$tails_summary" "$prs" "$board_queue" "$board_lastgo" "$board_epics" "$board_decisions" | sha256sum | cut -c1-16)"
    board_file="${console_doc%/*}/console-board.html"
    if [ ! -f "$board_file" ]; then
        board_summary=MISSING
    else
        board_have="$(sed -n 's/.*name="console-board-fp" content="\([0-9a-f]*\)".*/\1/p' "$board_file" 2>/dev/null | head -n 1)"
        if [ -n "$board_have" ] && [ "$board_have" = "$board_fp" ]; then
            board_summary=ok
        else
            board_mtime="$(stat -c %Y "$board_file" 2>/dev/null)" || board_mtime=""  # gnu-ok: console kit is Linux-only
            board_age=0
            case "$board_mtime" in ''|*[!0-9]*) ;; *) board_age=$(( $(date +%s) - board_mtime )) ;; esac
            [ "$board_age" -ge 0 ] || board_age=0
            if [ "$board_age" -ge 172800 ]; then board_summary="STALE:$((board_age / 86400))d"
            elif [ "$board_age" -ge 3600 ]; then board_summary="STALE:$((board_age / 3600))h"
            else board_summary="STALE:$((board_age / 60))m"; fi
        fi
    fi
fi

# the roadmap tracker's freshness. tracker.py --emit-fp is the one
# derivation (the mirror's newest updated + the plan files), the same value it
# writes to <page>.fp when it renders; a tracker that moved past its render reads
# STALE, aged by the page's mtime. skip = no (or `none`) `tracker:` Live state line.
# ponytail: tracker=ok says the LOCAL page matches Jira + the plan; tick cannot see
# whether the artifact was republished, and it reads the mirror on disk, so a stale
# mirror reads ok until the console refreshes it (node scripts/jira/dist/index.js mirror).
tracker_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    tracker_url="$(sed -n 's/^tracker:[[:space:]]*//p' "$console_doc" 2>/dev/null | head -n 1)"
    case "$tracker_url" in ''|none*) ;; *)
        tracker_dir="${console_doc%/*}"
        tracker_plan="$(sed -n 's/^tracker-plan:[[:space:]]*//p' "$console_doc" 2>/dev/null | head -n 1)"
        [ -n "$tracker_plan" ] || tracker_plan="$tracker_dir/specs/plan/HIMMEL-3882"
        tracker_file="$tracker_dir/roadmap-tracker.html"
        tracker_want="$(python3 "$HERE/tracker.py" --emit-fp --plan-dir "$tracker_plan" --out "$tracker_file" --luna-map "$tracker_dir/roadmap-luna-map.json" ${TICK_TRACKER_MIRROR_DIR:+--mirror-dir "$TICK_TRACKER_MIRROR_DIR"} 2>/dev/null)" || tracker_want=""
        if [ ! -f "$tracker_file" ]; then
            tracker_summary=MISSING
        elif [ -z "$tracker_want" ]; then
            tracker_summary=skip  # cannot derive the reference (no python3, bad plan dir): no verdict
        elif [ "$(cat "$tracker_file.fp" 2>/dev/null)" = "$tracker_want" ]; then
            tracker_summary=ok
        else
            tracker_mtime="$(stat -c %Y "$tracker_file" 2>/dev/null)" || tracker_mtime=""  # gnu-ok: console kit is Linux-only
            tracker_age=0
            case "$tracker_mtime" in ''|*[!0-9]*) ;; *) tracker_age=$(( $(date +%s) - tracker_mtime )) ;; esac
            [ "$tracker_age" -ge 0 ] || tracker_age=0
            if [ "$tracker_age" -ge 172800 ]; then tracker_summary="STALE:$((tracker_age / 86400))d"
            elif [ "$tracker_age" -ge 3600 ]; then tracker_summary="STALE:$((tracker_age / 3600))h"
            else tracker_summary="STALE:$((tracker_age / 60))m"; fi
        fi
        ;;
    esac
fi

# cloud=<ok|STALL:<ticket>[,...]|skip>. cloud-liveness.mjs owns the derivation
# (cloud-sessions.tsv next to the console doc against ONE `gh pr list --state all` and one
# `git ls-remote`); a missing node or helper, a missing tsv, or an unreadable forge reads
# skip, never a failed tick. The 60 s bound sits inside the waiter's tick timeout.
cloud_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ] && [ -f "${console_doc%/*}/cloud-sessions.tsv" ] && command -v node >/dev/null 2>&1; then
    cloud_summary="$(timeout -k 5 60 node "$HERE/cloud-liveness.mjs" --bucket "${console_doc%/*}" --repo "$pr_repo" 2>/dev/null)" || cloud_summary=skip  # gnu-ok: console kit is Linux-only
    case "$cloud_summary" in ok|skip|STALL:*) ;; *) cloud_summary=skip ;; esac
fi

# orphans-wip=<n[:KEY,...]|?|skip>: In Progress / In Review tickets with no
# leg, cloud session or open PR holding them. next-dispatchable.sh --resume-only owns the
# derivation from the Jira mirror (one `gh pr list`, no per-PR diff). Keys are named for
# n <= 5. A failed PR read is `?` (not an all-clear); no mirror or helper reads skip.
orphans_wip=skip
nd_mirror="${NEXT_DISPATCH_MIRROR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}"
if [ -d "$nd_mirror" ] && command -v python3 >/dev/null 2>&1; then
    if nd_out="$(timeout -k 5 60 bash "$HERE/next-dispatchable.sh" --resume-only --top 1000 --owners "$owner_keys" 2>/dev/null)"; then  # gnu-ok: console kit is Linux-only
        case "$nd_out" in
            *'open PRs unknown'*|*'live legs unknown'*) orphans_wip='?' ;;
            *)
                nd_keys="$(printf '%s\n' "$nd_out" | awk -F'\t' '$1 == "RESUME" { print $2 }' | paste -sd, -)"
                nd_n="$(printf '%s\n' "$nd_out" | awk -F'\t' '$1 == "RESUME"' | wc -l | tr -d ' ')"
                if [ "$nd_n" -eq 0 ]; then orphans_wip=0
                elif [ "$nd_n" -le 5 ]; then orphans_wip="$nd_n:$nd_keys"
                else orphans_wip="$nd_n"; fi
                ;;
        esac
    fi
fi

# the luna vault's commit health. vault-status.sh owns the derivation
# (and is fail-soft); a missing or failing helper reads unknown, never a failed tick.
vault_summary="$(HANDOVER_DIR="${HANDOVER_DIR:-$root}" bash "$HERE/vault-status.sh" 2>/dev/null)" || vault_summary=unknown
[ -n "$vault_summary" ] || vault_summary=unknown

# keep the roadmap-plan qmd index fresh WITHOUT ever waiting
# on it: the tick runs under the waiter's 120 s timeout and a refresh runs qmd embed. Only
# `plan-index.sh --check` (a fingerprint) runs inline; stale + due launches --refresh
# DETACHED (plan-index.sh's own lock keeps it to one). ok = fresh; ok:pending = stale but
# inside the minimum interval since the last success (TICK_PLAN_INDEX_MIN_SECS, default
# 900) so a busy mirror cannot cause back-to-back embeds; REFRESHING = launched or running;
# FAIL:<why> = the last refresh failed (same interval backs off the relaunch); skip = no
# plan dir. The console doc dir is NOT watched: its bucket changes on every Results bullet.
# The wrapper takes OUT/.launch first, so an overlapping tick's duplicate exits before it can
# clobber the live refresh's .run.log/.last-fail/.last-run.
# ponytail: a SIGKILL mid-refresh leaves OUT/.lock or .launch, read as FAIL:lock-stuck after an hour
# until removed by hand; a pid-aware takeover when it bites.
plan_index_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    pi_dir="${console_doc%/*}"
    pi_plan="$(sed -n 's/^tracker-plan:[[:space:]]*//p' "$console_doc" 2>/dev/null | head -n 1)"
    [ -n "$pi_plan" ] || pi_plan="$pi_dir/specs/plan/HIMMEL-3882"
    if [ -d "$pi_plan" ]; then
        pi_out="${TICK_PLAN_INDEX_OUT:-${HOME:-/tmp}/.himmel/state/roadmap-plan}"
        pi_min="${TICK_PLAN_INDEX_MIN_SECS:-900}"
        case "$pi_min" in ''|*[!0-9]*) pi_min=900 ;; esac
        pi_args=(--plan-dir "$pi_plan" --out "$pi_out" --watch "${TICK_TRACKER_MIRROR_DIR:-${HOME:-/tmp}/.himmel/state/jira-mirror/HIMMEL}")
        [ -z "$LEGS_FROM" ] || pi_args+=(--watch "$LEGS_FROM")
        pi_age() { local m; m="$(stat -c %Y "$1" 2>/dev/null)" || m=""; case "$m" in ''|*[!0-9]*) echo 999999999 ;; *) echo $(( $(date +%s) - m )) ;; esac; }  # gnu-ok: console kit is Linux-only
        if bash "$HERE/../../roadmap/plan-index.sh" --check "${pi_args[@]}" >/dev/null 2>&1; then
            plan_index_summary=ok
        elif [ -d "$pi_out/.lock" ] || [ -d "$pi_out/.launch" ]; then
            pi_lk="$pi_out/.lock"; [ -d "$pi_lk" ] || pi_lk="$pi_out/.launch"
            if [ "$(pi_age "$pi_lk")" -ge 3600 ]; then plan_index_summary=FAIL:lock-stuck; else plan_index_summary=REFRESHING; fi
        elif [ -f "$pi_out/.last-fail" ] && [ "$(pi_age "$pi_out/.last-fail")" -lt "$pi_min" ]; then
            plan_index_summary="FAIL:$(head -c 60 "$pi_out/.last-fail" 2>/dev/null | tr -c '[:alnum:] ._:-' '_')"
        elif [ -f "$pi_out/.fp" ] && [ -d "$pi_out/docs" ] && [ "$(pi_age "$pi_out/.fp")" -lt "$pi_min" ]; then
            plan_index_summary=ok:pending
        elif mkdir -p "$pi_out" 2>/dev/null; then
            rm -f "$pi_out/.last-run"
            read -r -a pi_launcher <<<"${TICK_PLAN_INDEX_LAUNCHER:-setsid nohup}"
            pi_have=1; [ "${#pi_launcher[@]}" -gt 0 ] || pi_have=0
            for pi_w in "${pi_launcher[@]}"; do command -v "$pi_w" >/dev/null 2>&1 || pi_have=0; done  # command -v with several operands passes if ANY exists
            if [ "$pi_have" = 1 ]; then
                "${pi_launcher[@]}" bash "$HERE/plan-index-launch.sh" "$pi_out" bash "$HERE/../../roadmap/plan-index.sh" --refresh "${pi_args[@]}" </dev/null >/dev/null 2>&1 &
                plan_index_summary=REFRESHING
            else
                echo "no-launcher: ${pi_launcher[*]} not found" >"$pi_out/.last-fail"
                plan_index_summary="FAIL:no-launcher"
            fi
        else
            plan_index_summary=FAIL:no-out-dir
        fi
    fi
fi

bank_cache="${TICK_BANK_CACHE_FILE:-/tmp/claude/statusline-usage-cache.json}"
fh="$(jq -r '.five_hour.utilization | if type == "number" then floor else empty end' "$bank_cache" 2>/dev/null)" || fh=""
wk="$(jq -r '.seven_day.utilization | if type == "number" then floor else empty end' "$bank_cache" 2>/dev/null)" || wk=""
case "$fh" in ''|*[!0-9]*) fh='?' ;; esac
case "$wk" in ''|*[!0-9]*) wk='?' ;; esac

bank_status="$(bun "$REPO/scripts/lanes/bank-status.ts" 2>/dev/null | grep '^claudex ' | head -n 1)" || bank_status=""
codex_fh="$(printf '%s\n' "$bank_status" | sed -n 's/.*5h used=\([0-9][0-9.]*\)%.*/\1/p')"
codex_wk="$(printf '%s\n' "$bank_status" | sed -n 's/.*weekly used=\([0-9][0-9.]*\)%.*/\1/p')"
if [ -n "$codex_fh" ] || [ -n "$codex_wk" ]; then
    # a weekly-only row means the 5h window is absent, i.e. no limit
    if [ -z "$codex_fh" ] && [ -n "$codex_wk" ]; then codex_fh=none; fi
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

# spare=<pct>@<h>h -- weekly quota the current burn leaves unspent
# at the reset (bank-monitor.sh --spare). Shown only when the spare is >=
# TICK_SPARE_MIN percent (default 10) and the reset is <= TICK_SPARE_HOURS hours
# away (default 24); otherwise the field is absent. Advisory only: console-wait's
# action key is a field whitelist that does not name spare=, so it never wakes.
spare_min="${TICK_SPARE_MIN:-10}"
spare_hours="${TICK_SPARE_HOURS:-24}"
case "$spare_min" in ''|*[!0-9]*) spare_min=10 ;; esac
case "$spare_hours" in ''|*[!0-9]*) spare_hours=24 ;; esac
spare_tail=""
spare_out="$(BANK_CACHE_FILE="$bank_cache" bash "$REPO/scripts/lib/bank-monitor.sh" --spare 2>/dev/null)" || spare_out=""
spare_in="$(printf '%s\n' "$spare_out" | sed -n 's/.*seven_day_reset_in=\([0-9][0-9.]*\)h.*/\1/p')"
spare_pct="$(printf '%s\n' "$spare_out" | sed -n 's/.*unspent_at_reset=\([0-9][0-9.]*\).*/\1/p')"
if [ -n "$spare_in" ] && [ -n "$spare_pct" ] \
   && awk -v p="$spare_pct" -v h="$spare_in" -v pm="$spare_min" -v hm="$spare_hours" 'BEGIN { exit !(p + 0 >= pm + 0 && h + 0 <= hm + 0) }'; then
    spare_tail=" spare=$(awk -v p="$spare_pct" 'BEGIN { printf "%d", p }')@$(awk -v h="$spare_in" 'BEGIN { printf "%d", h }')h"
fi

# fails=<n>/<legs>[@<top-class>*<k>][!<recur>][~<skipped>] -- this shift's
# leg-failures ledger rows (ts >= the console lock's `started`): <n> rows, <legs>
# distinct legs, the class with the most distinct legs (then events, then name),
# and !<recur> = distinct classes the failure router decided on this shift with a
# decision other than skipped:* (its log, spec section 4.3; absent until P5 writes
# one). fails=none with no row; fails=? when the lock start, the ledger or the
# routes log is unreadable, or the latest leg-trajectory eval-runs row this shift
# carries meta.digest_error (a failed read under pipefail reads ? too); skip with
# no --doc. Whitespace in a class prints as _ so the TICK line stays one line. Advisory: console-wait.sh's
# action key does not name it, so it wakes nothing. Each path honours the env
# seam its writer uses (leg_ledger.py, eval_runs.py).
fails_summary=skip
if [ -n "$console_doc" ] && [ -f "$console_doc" ]; then
    fails_summary='?'
    fails_start="$(bash "$REPO/scripts/handover/queue-lock.sh" status "$console_doc" 2>/dev/null | sed -n 's/.*"started":"\([0-9][0-9TZ:-]*\)".*/\1/p' | head -n 1)"
    fl_ledger="${HIMMEL_LEG_FAILURES_LEDGER:-$HOME/.himmel/leg-failures.jsonl}"
    fl_evals="${HIMMEL_EVAL_RUNS_LEDGER:-$HOME/.himmel/eval-runs.jsonl}"
    fl_routes="${HIMMEL_FAILURE_ROUTES_LOG:-$HOME/.himmel/state/failure-routes.log.jsonl}"
    # Readable-or-absent: an absent file is an empty one, anything else unreadable is ?.
    fl_ok() { [ ! -e "$1" ] || { [ -f "$1" ] && [ -r "$1" ]; }; }
    fl_rows() { [ ! -e "$1" ] || jq -R -c --arg s "$fails_start" 'fromjson? | select(type == "object" and (.ts | type) == "string" and .ts >= $s)' "$1"; }
    if [ -n "$fails_start" ] && command -v jq >/dev/null 2>&1 \
       && fl_ok "$fl_ledger" && fl_ok "$fl_evals" && fl_ok "$fl_routes"; then
        fl_digest="$(fl_rows "$fl_evals" | jq -s -r 'map(select(.eval == "leg-trajectory")) | if length > 0 and (last.meta.digest_error? // null) != null then "failed" else "ok" end' 2>/dev/null)" || fl_digest=""
        fl_recur="$(fl_rows "$fl_routes" | jq -s -r 'map(select((.class | type) == "string" and (.decision | type) == "string" and (.decision | startswith("skipped") | not))) | map(.class) | unique | length' 2>/dev/null)" || fl_recur=""
        fl_counts="$(fl_rows "$fl_ledger" | jq -s -r '
            map(select((.class | type) == "string"))
            | if length == 0 then "none"
              else
                (map(.leg) | unique | length) as $legs
                | (group_by(.class)
                   | map({c: .[0].class, l: (map(.leg) | unique | length),
                          e: (map(if (.count | type) == "number" then .count else 1 end) | add)})
                   | sort_by(-.l, -.e, .c) | .[0]) as $top
                | "\(length)/\($legs)@\($top.c | gsub("[[:space:][:cntrl:]]"; "_"))*\($top.l)"
              end' 2>/dev/null)" || fl_counts=""
        # ~<k> = distinct docs whose wrap digest was skipped this
        # shift (leg-digest-step.sh's skips.jsonl); unreadable reads ? too.
        fl_skips_log="${LEG_DIGEST_STATE_DIR:-$HOME/.himmel/state/leg-digest}/skips.jsonl"
        fl_skips=""
        fl_ok "$fl_skips_log" && { fl_skips="$(fl_rows "$fl_skips_log" | jq -s -r 'map(.doc) | unique | length' 2>/dev/null)" || fl_skips=""; }
        case "$fl_recur" in ''|*[!0-9]*) fl_counts="" ;; esac
        case "$fl_skips" in ''|*[!0-9]*) fl_counts="" ;; esac
        if [ "$fl_digest" = ok ] && [ -n "$fl_counts" ]; then
            fails_summary="$fl_counts"
            [ "$fl_counts" = none ] || [ "$fl_recur" -eq 0 ] || fails_summary="$fails_summary!$fl_recur"
            [ "$fl_skips" -eq 0 ] || fails_summary="$fails_summary~$fl_skips"
        fi
    fi
fi

# flakes=<rows>/<suites>@<top-suite>*<k> -- this repo's suite-flake
# ledger rows (run-shell-tests.sh) since the console lock's `started`
# (the same shift boundary as fails=), read by scripts/observability/suite-flake-summary.sh
# (bounded tail, repo-id filtered). ABSENT unless a row is new this shift (or `?`
# when the ledger is unreadable), so a quiet shift changes no line. Advisory:
# console-wait.sh's action key does not name it, so it wakes nothing. Env seams:
# SUITE_FLAKE_LEDGER, SUITE_FLAKE_REPO_ID, SUITE_FLAKE_TAIL_ROWS (the writer's).
flakes_tail=""
if [ -n "$console_doc" ] && [ -n "${fails_start:-}" ] && command -v jq >/dev/null 2>&1; then
    fk_since="$(printf '%s' "$fails_start" | jq -R -r 'fromdateiso8601? // empty' 2>/dev/null)"
    case "$fk_since" in ''|*[!0-9]*) fk_since="" ;; esac
    if [ -n "$fk_since" ]; then
        fk_out="$(bash "$REPO/scripts/observability/suite-flake-summary.sh" --since "$fk_since" --format tick 2>/dev/null | head -n 1)" || fk_out=""
        # printable-ASCII whitelist: Unicode whitespace in a suite name must not forge a field
        case "$fk_out" in ''|none) ;; *[!A-Za-z0-9._/+@*?-]*) ;; *) flakes_tail=" flakes=$fk_out" ;; esac
    fi
fi

# ready-mismatch=<flagged>/<ready>,nogo=<k>/<judged>[,ALERT]: READY claims a judge or
# the diff contradicts (ready_mismatch_scan above). ABSENT unless something is flagged or
# alerting, so a clean shift changes no line. Advisory: not in console-wait's action key.
ready_tail=""
if [ -n "$console_doc" ]; then
    rm_out="$(ready_mismatch_scan "${console_doc%/*}" 2>/dev/null)" || rm_out=""  # swallow-ok: no readable data omits the advisory field
    rm_count="$(printf '%s\n' "$rm_out" | awk -F'\t' '$1 == "COUNT" { print $2, $3, $4, $5 }')"
    if [ -n "$rm_count" ]; then
        read -r rm_r rm_f rm_j rm_n <<< "$rm_count"
        rm_alert=""
        printf '%s\n' "$rm_out" | grep -q '^ALERT' && rm_alert=",ALERT"
        printf '%s\n' "$rm_out" | grep -q '^PARTIAL' && rm_alert="$rm_alert,partial"
        if [ "$rm_f" -gt 0 ] || [ -n "$rm_alert" ]; then
            ready_tail=" ready-mismatch=$rm_f/$rm_r,nogo=$rm_n/$rm_j$rm_alert"
        fi
    fi
fi

# parked=<leg>:<age>m,...: a headed leg whose newest trust-ledger row is a
# permission prompt nobody answered for TICK_PARKED_MIN minutes (default 5), i.e. it
# is sitting on the auto-mode confirmation dialog while its lock heartbeat stays
# fresh. ABSENT unless a leg is parked, so a quiet fleet changes no line. Read-only;
# parked-on-prompt.sh holds the rule and the seams (HIMMEL_TRUST_LEDGER_DIR).
parked_tail=""
parked_docs=()
for leg in $LEGS_SPLIT; do parked_docs+=("$(resolve_doc "$leg")"); done
if [ "${#parked_docs[@]}" -gt 0 ]; then
    parked_out="$(bash "$HERE/parked-on-prompt.sh" "${parked_docs[@]}" 2>/dev/null | head -n 1)" || parked_out=""
    case "$parked_out" in ''|parked=none|'parked=?') ;; *[!A-Za-z0-9._:,=+@-]*) ;; parked=*) parked_tail=" $parked_out" ;; esac
fi

# station=BEHIND:<component>,...: the last station-sync.sh run (after a merge) left a
# component behind main. ABSENT when the station was current or no sync has run; it
# clears on the next sync. A file read only, so a quiet fleet changes no line.
station_tail=""
station_state="${TICK_STATION_STATE:-$HOME/.himmel/state/station-sync.state}"
if [ -r "$station_state" ]; then
    station_val="$(head -n 1 "$station_state" 2>/dev/null)" || station_val=""
    case "$station_val" in BEHIND:*[!A-Za-z0-9._,:-]*) ;; BEHIND:*) station_tail=" station=$station_val" ;; esac
fi
# deadwin=<label>:closed|held[,...]: a leg konsole (tabtitle
# HIMMEL-<n>-N<k>-...) with no child process -- its session was killed (OOM)
# and the window sits on "program crashed". ONE ps read, no per-window probe.
# It is TERMed (:closed) only when the leg's lock is free (FREE/WRAPPED) or a
# newer <tabtitle>-r<n> window with a live child is up; else :held (report only).
# A konsole younger than TICK_DEADWIN_GRACE seconds (default 30) has not spawned
# its child yet. ABSENT when none.
deadwin_tail=""; dw_closed=""
dw_grace="${TICK_DEADWIN_GRACE:-30}"
case "$dw_grace" in ""|*[!0-9]*) dw_grace=30 ;; esac
dw_ps="$(ps -eo pid=,ppid=,etimes=,args= 2>/dev/null)" || dw_ps=""  # swallow-ok: an unreadable table reports no dead window, never a false one
if [ -n "$dw_ps" ]; then
    # one awk pass: per konsole leg window "<pid> <etimes> <tabtitle> <haschild>"
    dw_rows="$(printf '%s\n' "$dw_ps" | awk '
        { ppid_seen[$2] = 1 }
        $4 ~ /(^|\/)konsole$/ {
            tt = ""
            for (i = 5; i <= NF; i++) if ($i ~ /^tabtitle=/) { tt = substr($i, 10); break }
            if (tt ~ /^HIMMEL-[0-9]+-N[0-9]+[a-z]*-/) { pid[++n] = $1; et[n] = $3; ttl[n] = tt }
        }
        END { for (j = 1; j <= n; j++) print pid[j], et[j], ttl[j], (pid[j] in ppid_seen) ? 1 : 0 }')"
    while read -r dw_pid dw_et dw_tt dw_alive; do
        [ -n "$dw_pid" ] && [ "$dw_alive" = 0 ] || continue
        case "$dw_et" in ""|*[!0-9]*) continue ;; esac
        [ "$dw_et" -ge "$dw_grace" ] || continue
        dw_label="${dw_tt#HIMMEL-*-}"; dw_label="${dw_label%%-*}"
        dw_free=0
        while IFS=$'\t' read -r dw_l dw_s _; do
            [ "$dw_l" = "$dw_label" ] || continue
            case "$dw_s" in FREE|WRAPPED) dw_free=1 ;; esac
        done <<< "$leg_candmap"
        if [ "$dw_free" -eq 0 ]; then
            # a live relaunch: another leg window titled <tabtitle>-r<n> that has a child
            dw_base="$dw_tt"; dw_n=0
            if [[ "$dw_tt" =~ ^(.*)-r([0-9]+)$ ]]; then dw_base="${BASH_REMATCH[1]}"; dw_n="${BASH_REMATCH[2]}"; fi
            while read -r _ _ dw_rt dw_ra; do
                [ "$dw_ra" = 1 ] || continue
                if [[ "$dw_rt" =~ ^"$dw_base"-r([0-9]+)$ ]] && [ "${BASH_REMATCH[1]}" -gt "$dw_n" ]; then dw_free=1; fi
            done <<< "$dw_rows"
        fi
        if [ "$dw_free" -eq 1 ] && "${TICK_KILL_BIN:-kill}" -TERM "$dw_pid" 2>/dev/null; then
            dw_closed="$(csv_add "$dw_closed" "$dw_label")"
        else
            deadwin_tail="$(csv_add "$deadwin_tail" "$dw_label:held")"
        fi
    done <<< "$dw_rows"
fi
# A closed window leaves ps at once, so :closed is kept in a state file and
# re-reported for TICK_DEADWIN_KEEP seconds (default 300): console-wait needs two
# consecutive samples off its saved key, and a one-tick report would be dropped.
dw_state="${TICK_STATE_DIR:-$HOME/.himmel/state}/tick-deadwin-closed"
dw_keep="${TICK_DEADWIN_KEEP:-300}"
case "$dw_keep" in ""|*[!0-9]*) dw_keep=300 ;; esac
dw_now="$(date +%s)"; dw_new_state=""
for dw_l in ${dw_closed//,/ }; do dw_new_state="$dw_new_state$dw_l $dw_now"$'\n'; done
if [ -r "$dw_state" ]; then
    while read -r dw_l dw_t; do
        case "$dw_t" in ""|*[!0-9]*) continue ;; esac
        [ $((dw_now - dw_t)) -lt "$dw_keep" ] || continue
        case ",$dw_closed," in *",$dw_l,"*) continue ;; esac
        dw_new_state="$dw_new_state$dw_l $dw_t"$'\n'
    done < "$dw_state"
fi
if [ -n "$dw_new_state" ]; then
    mkdir -p "${dw_state%/*}" 2>/dev/null && printf '%s' "$dw_new_state" > "$dw_state" 2>/dev/null  # swallow-ok: a failed state write only drops the closed re-report
    while read -r dw_l _; do [ -n "$dw_l" ] && deadwin_tail="$(csv_add "$deadwin_tail" "$dw_l:closed")"; done <<< "$dw_new_state"
elif [ -e "$dw_state" ]; then
    rm -f "$dw_state" 2>/dev/null  # swallow-ok: a stale state file is re-pruned next tick
fi
[ -z "$deadwin_tail" ] || deadwin_tail=" deadwin=$deadwin_tail"

# closable=<n>: finished windows still open past TICK_CLOSABLE_MIN minutes.
# ABSENT when 0; run `close-wrapped-leg.sh --sweep --fleet <manifest>`.
closable_tail=""
[ "$closable_n" -eq 0 ] || closable_tail=" closable=$closable_n"

fill="$(bash "$REPO/scripts/context-fill.sh" --percent 2>/dev/null)" || fill=""
case "$fill" in ''|*[!0-9]*) fill='?' ;; esac

inbox_summary=""
if [ -n "$root" ] && [ -d "$root/inbox" ]; then
    for inbox_file in "$root"/inbox/*.md; do
        [ -f "$inbox_file" ] || continue
        inbox_name="${inbox_file##*/}"
        inbox_name="${inbox_name%.md}"
        inbox_size="$(wc -c < "$inbox_file" 2>/dev/null | tr -d '[:space:]')"
        case "$inbox_size" in ''|*[!0-9]*) continue ;; esac
        # Hook delivery and native followers have different cursors. A wake
        # follower must never hide rulings the hook has not delivered yet.
        if [ -f "$root/inbox/.cursor/$inbox_name" ]; then
            cursor="$(cat "$root/inbox/.cursor/$inbox_name" 2>/dev/null)" || cursor=0  # swallow-ok: a missing/unreadable cursor conservatively treats the inbox as unread
            case "$cursor" in ''|*[!0-9]*|????????????????*) cursor=0 ;; esac
        else
            cursor="$(cat "$inbox_file.cursor" 2>/dev/null)" || cursor=0  # swallow-ok: a missing/unreadable cursor conservatively treats the inbox as unread
            case "$cursor" in ''|*[!0-9]*|0?*|????????????????*) cursor=0 ;; esac
            [ "$cursor" -le "$inbox_size" ] || cursor=0
        fi
        [ "$inbox_size" -gt "$((10#$cursor))" ] || continue
        # A partial final line is not deliverable by inbox-follow.sh yet.
        unread_lines="$(tail -c +$((10#$cursor + 1)) "$inbox_file" 2>/dev/null | tr -cd '\n' | wc -c | tr -d '[:space:]')"  # swallow-ok: unreadable inboxes are not proven unread and are omitted
        [ "${unread_lines:-0}" -gt 0 ] || continue
        inbox_label="$(leg_label "$inbox_name")"
        inbox_summary="$(csv_add "$inbox_summary" "$inbox_label:$inbox_size/$cursor")"
    done
fi
[ -n "$inbox_summary" ] || inbox_summary=none

# fleet=<live>/<cap> + capacity=. The census is bank-preflight.sh's
# own -- it counts native + claudex + reserved against HIMMEL_FLEET_CAP inline,
# in a script that exits, so its `FLEET ... total=<n>/<cap>` line is the seam
# (a second count here would be the drift this field exists to end). Run as a
# plain read: CADENCE_BANK_LAUNCH stays empty so it can never refuse anything,
# and the ledger goes to /dev/null so a tick writes no cadence-ledger row.
# ponytail: bank-preflight still takes its fleet admission lock and prunes
# expired/consumed reservations while it counts, exactly as any bank read does.
fleet_out="$(CADENCE_BANK_LAUNCH='' CADENCE_BANK_LEDGER=/dev/null bash "$REPO/scripts/lib/bank-preflight.sh" 2>&1)" || fleet_out=""
# bank= uses the selected lane's own preflight verdict. Keep
# or= below informational; it never stands in for the bank admission gate.
if [ "${CADENCE_BANK_LANE:-${LEG_LANE:-native}}" = openrouter ]; then
    or_verdict="$(printf '%s\n' "$fleet_out" | grep -E '^(PROCEED|SKIPPED-BANK|BANK-UNKNOWN|SKIPPED-FLEET)$' | tail -n 1)"
    bank="openrouter:${or_verdict:-BANK-UNKNOWN}"
fi
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
    launch_dir="$(launch_dir_default)"
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

# reuse the fleet census, never read the metered account when
# no OpenRouter leg is live. This informational field is deliberately absent
# from console-wait.sh's action key, so changing credit never wakes a waiter.
openrouter='?'
or_live="$(printf '%s\n' "$fleet_out" | sed -n 's/^bank-preflight: FLEET .*openrouter=\([0-9][0-9]*\) .*/\1/p' | tail -n 1)"
case "$or_live" in
    ''|*[!0-9]*) : ;;
    *)
        if [ "$or_live" -eq 0 ]; then
            openrouter=skip
        elif [ -r "$REPO/scripts/lanes/openrouter-cost.sh" ]; then
            or_cost="$(bash "$REPO/scripts/lanes/openrouter-cost.sh" 2>/dev/null)" || or_cost=''
            or_balance="${or_cost%% *}"
            case "$or_balance" in
                balance=\?|balance=[0-9]*:credit|balance=[0-9]*:key-limit_remaining) openrouter="${or_balance#balance=}" ;;
            esac
        fi
        ;;
esac

# orphans=: shell-tool wrappers older than TICK_ORPHAN_MIN minutes,
# joined to the owning session name -- a poll loop that outlives its wrapped
# leg (TaskStop on an agent does not reap the shell it spawned) surfaces at the
# next tick. Read-only; orphans=? when the process table cannot be read.
orphans_line="$(REPO="$REPO" bash "$HERE/orphan-loops.sh" 2>/dev/null | tail -n 1)" || orphans_line=""
orphans="${orphans_line#orphans=}"
[ -n "$orphans" ] || orphans='?'

# gql=<remaining>/<reset HH:MM>: the GitHub GraphQL budget, shared by
# every leg on the box, so a console sees exhaustion coming instead of hitting it.
# ghb_read is ONE real `gh api -i graphql` call -- `gh api rate_limit` reports the
# REST core bucket and misreports this one -- so a tick pays exactly
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

# denials=<leg>:<n>[:SHIP-STEP|REPEAT|PAUSE-RISK]: rows
# scripts/hooks/log-classifier-denial.sh appended to the jsonl within the
# trailing window, grouped by the hook's own session_title (the worktree
# slug it captured) -- NOT reconciled against this tick's --legs labels.
# SHIP-STEP fires immediately on a denied ship-step command; PAUSE-RISK on 3+
# in the window or an all-time total approaching the auto-mode pause
# threshold (20); REPEAT on 2+ in the window with neither of the above.
# denials=skip when jq is missing or the log is unreadable; denials=none when
# the window is empty or the log does not exist yet. Grouping: a worktree
# row by its slug, any other row by <dir>#<session_id[0:8]> so a re-dispatched
# slug never inherits an old session's count. HARD RULE: input_head and
# reason_tag classify HERE, on this host, and are never printed into the tick
# line (or any later page) -- test-tick.sh and the hook's test pin it. Stateless like every other field here (no persisted
# cross-tick cursor), so "since the last tick" is approximated by a trailing
# window rather than a real cursor -- console-wait's own key-diffing is what
# actually triggers a wake on a class change, not this field's count.
# ponytail: HIMMEL-3724 - leg-label reconciliation and a same-session success/flip check
# for REPEAT are Phase 2, not implemented here.
denials_window_min="${TICK_DENIALS_WINDOW_MIN:-30}"
case "$denials_window_min" in ''|*[!0-9]*) denials_window_min=30 ;; esac
denials_log="${HIMMEL_CLASSIFIER_DENIALS_LOG:-$HOME/.himmel/state/classifier-denials.jsonl}"
denials_summary=skip
if command -v jq >/dev/null 2>&1 && [ -f "$denials_log" ]; then
    denials_cutoff="$(date -u -d "-${denials_window_min} minutes" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"  # gnu-ok: Linux-only kit
    if [ -n "$denials_cutoff" ]; then
        # Bound the read (TICK_DENIALS_TAIL_MAX lines) so a tick's cost stays
        # flat regardless of how large the all-time jsonl has grown -- this
        # is a stateless trailing-window field (no persisted cursor), so a
        # tick is already an approximation; the tail cap just keeps that
        # approximation cheap too. The all-time total below counts within
        # this same bounded tail, not the true unbounded all-time count.
        denials_tail_max="${TICK_DENIALS_TAIL_MAX:-2000}"
        case "$denials_tail_max" in ''|*[!0-9]*) denials_tail_max=2000 ;; esac
        # jq -s needs the WHOLE input to parse before it emits anything, so
        # one malformed line anywhere in the tail would hide every valid
        # denial in it. Pre-filter line-by-line in raw-input mode first
        # (fromjson? never aborts the read, it just drops what doesn't
        # parse; select(type == "object") also drops valid scalars/arrays,
        # which would otherwise fail the field access below, and a row whose
        # input_head is not a string would fail test()), then slurp
        # only the lines that survived.
        # The hook rotates the log to <log>.1 past its byte cap, so read the
        # previous generation first: a window straddling a rotation must not
        # under-count and hide a PAUSE-RISK. (A missing .1 must not fail the
        # pipeline under pipefail, hence the -r guard, not a bare cat.)
        denials_summary="$( { [ -r "$denials_log.1" ] && cat "$denials_log.1"; cat "$denials_log"; } 2>/dev/null | tail -n "$denials_tail_max" | jq -R -c 'fromjson? | select(type == "object" and (.input_head | type) == "string")' 2>/dev/null | jq -s -r --arg cutoff "$denials_cutoff" '
            # A worktree row is labelled by its slug (the leg identity). Any
            # other cwd is a bare directory name a re-dispatched leg would
            # share with its predecessor, so it is labelled <name>#<sid8>
            # instead: one session, one count.
            def leg:
                (.session_title // "unknown") as $t
                | ((.session_id // "") | tostring | .[0:8]) as $sid
                | if (((.cwd // "") | tostring | test("/worktrees/")) or $sid == "") then $t
                  else "\($t)#\($sid)" end;
            . as $all
            | ($all | group_by(leg)
               | map({key: (.[0] | leg), value: length})
               | from_entries) as $totals
            | ($all | map(select(.ts >= $cutoff))) as $recent
            | ($recent | group_by(leg)) as $rgroups
            | if ($rgroups | length) == 0 then "none"
              else
                $rgroups
                | map(
                    (.[0] | leg) as $leg
                    | length as $n
                    | (any(.[]; (.input_head // "") | test("merge-on-green|go\\.sh|git push|gh pr (create|merge)|write-verdicts|pr-check"))) as $ship
                    | ($totals[$leg] // $n) as $total
                    | (if $ship then "SHIP-STEP"
                       elif ($total >= 18 or $n >= 3) then "PAUSE-RISK"
                       elif ($n >= 2) then "REPEAT"
                       else null end) as $class
                    | if $class then "\($leg):\($n):\($class)" else "\($leg):\($n)" end
                  )
                | join(",")
              end
        ' 2>/dev/null)" || denials_summary=""
        [ -n "$denials_summary" ] || denials_summary=skip
    fi
elif command -v jq >/dev/null 2>&1 && [ ! -e "$denials_log" ]; then
    # No log yet = the hook never fired = no denials. "skip" would read as a
    # broken monitor and flap the console-wait key against "none".
    denials_summary=none
fi

# ciq=<in_progress>/<cap>,mac=<n>/<cap>,q=<queued>,wait=<m>m[,SATURATED]
# one scripts/ci/queue-latency.sh probe per tick. SATURATED =
# jobs_in_progress at the cap on two consecutive probes; the previous probe's
# "<in_progress>/<cap>" lives in $TICK_STATE_DIR/tick-ciq-last (default
# ~/.himmel/state, like the denials log). ciq=unknown = the probe is missing,
# failed, timed out or printed something else; it neither sets nor clears the
# state. The probe is bounded by TICK_CIQ_TIMEOUT (default 45 s, well inside
# console-wait's 120 s tick budget). console-wait.sh's wake key deliberately
# does not carry ciq: a changing queue count must not wake the console.
# ponytail: with no timeout binary the probe runs unbounded (queue-latency.sh
# still bounds each gh call to 15 s); one probe is up to ~42 REST calls, so on
# console-wait's 180 s cadence that is ~840 calls/h -- cache or cut MAX_RUNS if
# the shared token's rate limit bites again.
ciq_summary=unknown
ciq_probe="$REPO/scripts/ci/queue-latency.sh"
if [ -f "$ciq_probe" ]; then
    # shellcheck source=../../lib/timeout-bin.sh
    . "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
    ciq_bound="${TICK_CIQ_TIMEOUT:-45}"
    case "$ciq_bound" in ''|*[!0-9]*) ciq_bound=45 ;; esac
    ciq_out="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 "$ciq_bound"} bash "$ciq_probe" 2>/dev/null)" || ciq_out=""
    ciq_nums="$(printf '%s\n' "$ciq_out" | sed -n 's#^ci-queue: jobs_in_progress=\([0-9][0-9]*\)/\([0-9][0-9]*\) macos=\([0-9][0-9]*\)/\([0-9][0-9]*\) queued=\([0-9][0-9]*\) oldest_wait=\([0-9][0-9]*\)m$#\1 \2 \3 \4 \5 \6#p' | head -n 1)"
    if [ -n "$ciq_nums" ]; then
        read -r ciq_ip ciq_cap ciq_mac ciq_macmax ciq_q ciq_wait <<< "$ciq_nums"
        ciq_state="${TICK_STATE_DIR:-$HOME/.himmel/state}/tick-ciq-last"
        ciq_prev="$(cat "$ciq_state" 2>/dev/null)" || ciq_prev=""
        ciq_summary="$ciq_ip/$ciq_cap,mac=$ciq_mac/$ciq_macmax,q=$ciq_q,wait=${ciq_wait}m"
        if [ "$ciq_cap" -gt 0 ] && [ "$ciq_ip" -ge "$ciq_cap" ] && [ "$ciq_prev" = "$ciq_cap/$ciq_cap" ]; then
            ciq_summary="$ciq_summary,SATURATED"
        fi
        # An in-progress count past the cap is stored as the cap, so the
        # comparison above only ever has to match "<cap>/<cap>".
        [ "$ciq_ip" -le "$ciq_cap" ] || ciq_ip="$ciq_cap"
        { mkdir -p "$(dirname "$ciq_state")" && printf '%s/%s\n' "$ciq_ip" "$ciq_cap" > "$ciq_state"; } 2>/dev/null || true
    fi
fi

# vmrun=off|ok:<up>/<want>,busy=<n>|DISAGREE:<up>/<want>,online=0|DEAD|STUCK|
# FAILING: the himmel-vm self-hosted runner, one bounded `vm-runner.sh status
# --tick` call. DEAD = the repo variable is on but no unit is up; STUCK = a job
# past JOB_MAX+600 s; FAILING = a unit is up but its newest ci-runner journal
# line is an error, its journal is unreadable, or GitHub's runner count is
# unreadable; DISAGREE = a unit has had a registered, unfinished runner for
# over CACHE_TTL+60 s and GitHub reports no himmel-vm runner online (a fresher
# registration is still connecting and reads ok). Zero online with every
# runner idle or finished is normal and reads ok.
# console-wait.sh wakes only on a move to DEAD or STUCK; FAILING and DISAGREE
# are shown in the tick line but do not wake it. unknown = the probe is missing, failed or timed out.
vmrun_summary=unknown
vmrun_probe="${HIMMEL_VMRUN_PROBE:-$HERE/vm-runner.sh}"
if [ -f "$vmrun_probe" ]; then
    # shellcheck source=../../lib/timeout-bin.sh
    . "$HERE/../../lib/timeout-bin.sh" 2>/dev/null
    vmrun_out="$(${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" -k 2 30} bash "$vmrun_probe" status --tick 2>/dev/null)" || vmrun_out=""
    case "$vmrun_out" in
        off|DEAD|STUCK|FAILING|DISAGREE:[0-9]*/[0-9]*,online=0|ok:[0-9]*/[0-9]*,busy=[0-9]*) vmrun_summary="$vmrun_out" ;;
    esac
fi

# tick=ARMED|MISSING|UNKNOWN: whether the periodic Monitor
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

# --burn: what each leg is actually paying per API call. The
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
            # the session name has no -YYYY-MM-DD suffix, and a
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
    printf 'worker-session locks: %s\n' "$legs_summary"
    printf 'livestate: %s\n' "$livestate_summary"
    printf 'worker-session processes: %s\n' "$procs"
    printf 'worker-session models: %s\n' "$models_summary"
    printf 'scheduled jobs: %s\n' "$at_count"
    printf 'suite locks: %s\n' "$suites"
    printf 'open PRs: %s\n' "$prs"
    printf 'unowned-prs: %s\n' "$unowned_prs"
    printf 'ext-prs: %s\n' "$ext_prs"
    printf 'subscription usage budget: %s\n' "$bank"
    printf 'fill: %s\n' "$fill"
    printf 'worker-session tails: %s\n' "$tails_summary"
    printf 'inbox size/cursor: %s\n' "$inbox_summary"
    printf 'tick monitor: %s\n' "$tick_status"
    # Printed only under --burn, so a plain --verbose tick is unchanged. An if,
    # not a `[ ] &&` one-liner: this is the last statement of the branch, so a
    # false test would become the script's exit status.
    if [ "$burn" -eq 1 ]; then
        printf 'worker-session burn (first-turn/avg-ctx): %s\n' "$burn_summary"
    fi
    printf 'fleet: %s\n' "$fleet"
    printf 'capacity: %s\n' "$capacity"
    printf 'gql: %s\n' "$gql"
    printf 'orphans: %s\n' "$orphans"
    printf 'nonces: %s\n' "$nonces_summary"
    printf 'worker-session set: %s\n' "$legset_summary"
    printf 'board: %s\n' "$board_summary"
    printf 'tracker: %s\n' "$tracker_summary"
    printf 'denials: %s\n' "$denials_summary"
    printf 'ci queue: %s\n' "$ciq_summary"
    printf 'plan-index: %s\n' "$plan_index_summary"
    printf 'OpenRouter: %s\n' "$openrouter"
    printf 'worker-session failures: %s\n' "$fails_summary"
    printf 'vm runner: %s\n' "$vmrun_summary"
    [ -z "$flakes_tail" ] || printf 'suite flakes: %s\n' "${flakes_tail# flakes=}"
    [ -z "$ready_tail" ] || printf 'ready-mismatch: %s\n' "${ready_tail# ready-mismatch=}"
    [ -z "$parked_tail" ] || printf 'parked on prompt: %s\n' "${parked_tail# parked=}"
    [ -z "$closable_tail" ] || printf 'closable windows: %s\n' "${closable_tail# closable=}"
    [ -z "$deadwin_tail" ] || printf 'dead windows: %s\n' "${deadwin_tail# deadwin=}"
    printf 'vault: %s\n' "$vault_summary"
    printf 'cloud: %s\n' "$cloud_summary"
    printf 'orphans-wip: %s\n' "$orphans_wip"
    [ -z "$station_tail" ] || printf 'station: %s\n' "${station_tail# station=}"
    [ -z "$spare_tail" ] || printf 'spare: %s\n' "${spare_tail# spare=}"
else
    # Keep reader inputs even at their defaults: console-wait.sh rejects
    # missing required fields, and capacity/unowned-prs/tracker clear streaks.
    # Only unconsumed healthy/default values are elided; unknowns stay visible.
    compact_field() {
        case "$1=$2" in
            *=|hb=ok|hb=skip|procs=0|models=none|ceiling=ok|atq=0|suites=0alive/0dead|\
            ext-prs=none|inbox=none|tick=UNKNOWN|burn=none|orphans=none|nonces=ok|nonces=skip|\
            plan-index=ok|plan-index=skip|or=skip|fails=none|fails=skip) return ;;
        esac
        printf ' %s=%s' "$1" "$2"
    }
    printf 'TICK %s' "$clock"
    compact_field hb "$hb"
    compact_field legs "$legs_summary"
    compact_field livestate "$livestate_summary"
    compact_field procs "$procs"
    compact_field models "$models_summary"
    compact_field ceiling "${ceiling_summary#ceiling=}"
    compact_field atq "$at_count"
    compact_field suites "$suites"
    compact_field prs "$prs"
    compact_field unowned-prs "$unowned_prs"
    compact_field ext-prs "$ext_prs"
    compact_field bank "$bank"
    compact_field fill "$fill"
    compact_field tails "$tails_summary"
    compact_field inbox "$inbox_summary"
    compact_field tick "$tick_status"
    [ "$burn" -eq 0 ] || compact_field burn "$burn_summary"
    compact_field fleet "$fleet"
    compact_field capacity "$capacity"
    compact_field gql "$gql"
    compact_field orphans "$orphans"
    compact_field nonces "$nonces_summary"
    compact_field legset "$legset_summary"
    compact_field board "$board_summary"
    compact_field tracker "$tracker_summary"
    compact_field vault "$vault_summary"
    compact_field cloud "$cloud_summary"
    compact_field orphans-wip "$orphans_wip"
    compact_field denials "$denials_summary"
    compact_field ciq "$ciq_summary"
    compact_field plan-index "$plan_index_summary"
    compact_field or "$openrouter"
    compact_field fails "$fails_summary"
    compact_field vmrun "$vmrun_summary"
    printf '%s\n' "$flakes_tail$ready_tail$parked_tail$closable_tail$deadwin_tail$station_tail$spare_tail"
fi
if [ "$emit_fp" -eq 1 ]; then
    printf 'board-fp=%s\n' "$board_fp"
fi
