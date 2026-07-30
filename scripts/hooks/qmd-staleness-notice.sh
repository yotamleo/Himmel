#!/usr/bin/env bash
# qmd-staleness-notice.sh — SessionStart hook: warn when this station's qmd
# index cannot be trusted (HIMMEL-1286).
#
# WHY A HOOK AND NOT A SLASH COMMAND: the failure this closes is a session
# answering confidently off a stale index, and a session that would remember to
# run a staleness check is not the session that gets burned. The lean-invoke
# default (HIMMEL-177) is the right call for most capabilities precisely
# because the operator knows when a rule applies and Claude does not — but here
# nobody knows, which is the entire problem. `qmd status` is a local sqlite
# read, so the always-on cost is one cheap subprocess per session.
#
# SILENT ON THE HEALTHY PATH. A fresh index prints NOTHING — no output, no
# context spent. Every line a SessionStart hook emits is paid for in every
# session forever, and a daily "index is fine" banner is exactly the always-on
# noise that trains a reader to skip the block, taking the real warning with it.
# Output happens only when there is something wrong.
#
# NEVER BLOCKS, NEVER FAILS A SESSION. Always exits 0. A station with no qmd at
# all (rc 2) is silent — adopters who do not use qmd must not be nagged by a
# tool they never installed. That is the ONLY silent non-verdict.
#
# EVERYTHING ELSE THAT IS NOT A VERDICT SPEAKS UP AS "UNVERIFIED". `qmd status`
# failing (rc 7), the probe timing out (124/137), an unreadable report (rc 6),
# an exit code this hook does not recognise — none of those is evidence of
# health, and each was previously silent. That silence recreated the exact hole
# this ticket exists to close, one level up: a corrupt or locked index, a
# crashed qmd, or a wedged process produced NO warning, and the session went on
# to report confident absences off a substrate that had stopped answering.
# "I could not verify" is a signal, not a reason to say nothing — which
# overturns the earlier reading that a slow probe is not a staleness claim. It
# is not a staleness claim; it is a TRUST claim, and that is what the reader
# needs.
#
# The notice deliberately tells a receiving station NOT to reindex: it embeds
# ~50x slower than the host, so the fix is a host-side push
# (scripts/luna/ship-index.sh), never a local rebuild.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GUARD="$HERE/../luna/qmd-staleness.sh"
# Deliberately NOT a silent exit. An absent guard is not the adopter-without-qmd
# case (that is rc 2, below, and stays silent) — the hook and the guard ship in
# the same repo, one directory apart, so if this file is running and that one is
# missing the checkout is INCONSISTENT and the freshness check is permanently
# off. Exiting 0 quietly there is the same silent-stop this ticket exists to
# kill, just relocated into the wiring. The advisory is defined further down, so
# the check itself is deferred until after it.
GUARD_MISSING=0
[ -f "$GUARD" ] || GUARD_MISSING=1

# QMD_STALENESS_MAX_AGE_HOURS overrides the guard's own 36h default without
# editing settings.json — a station on a different ship cadence needs a
# different budget, and that is config, not code.
budget="${QMD_STALENESS_MAX_AGE_HOURS:-36}"
# QMD_STALENESS_REQUIRE_COLLECTIONS is per-STATION policy (the host carries
# salus, win2 deliberately does not, an adopter carries neither), so it can only
# come from the environment — and it is opt-in: unset means the collection set
# is not checked. A value the guard rejects surfaces on rc 1 below, loudly,
# rather than silently checking nothing.
require="${QMD_STALENESS_REQUIRE_COLLECTIONS:-}"

set -- --quiet --max-age-hours "$budget"
if [ -n "$require" ]; then
    set -- "$@" --require-collections "$require"
fi

out=""
rc=0

# unverified <why> — the index could not be checked. Distinct from a staleness
# verdict on purpose: the reader must not conclude the index is stale, only that
# nothing here proved it current. Ends the hook (always rc 0). Defined BEFORE
# the guard runs because the missing-guard case below needs it too.
unverified() {
    printf '<system-reminder>\n'
    printf 'qmd index freshness is UNVERIFIED this session: %s.\n' "$1"
    if [ -n "$out" ]; then
        printf '\n%s\n' "$out"
    fi
    printf '\nThis is NOT a staleness verdict — the check could not run, so the index\n'
    printf 'may be fine. Treat qmd MISSES AS UNPROVEN either way: a miss is only\n'
    printf 'evidence of absence when the index is verifiably current, and here it\n'
    printf 'could not be verified (HIMMEL-1286).\n'
    printf '</system-reminder>\n'
    exit 0
}

if [ "$GUARD_MISSING" -eq 1 ]; then
    unverified "the staleness guard is missing at $GUARD, so this checkout is inconsistent (the hook is wired but the script it calls is absent)"
fi

# A wedged qmd must never hold a session open — AND, on this hook, must never
# take the warning down with it.
#
# THE OUTER TIMEOUT IS NOT A SUBSTITUTE FOR AN INNER ONE. The earlier version
# degraded to an UNBOUNDED call when coreutils `timeout` was absent (stock
# macOS), on the reasoning that the SessionStart entry in settings.json carries
# its own harness-enforced timeout. That reasoning was wrong in the one
# direction that matters: the harness kills the hook PROCESS, and this hook
# prints nothing until the guard returns — so a hung qmd got the hook killed
# BEFORE it could reach the rc 124 branch, and the session heard silence on
# exactly the wedged-index condition the UNVERIFIED advisory exists to report.
# An outer timeout bounds the HANG; only an inner one can REPORT it.
#
# So the fallback is a real bound: a foreground poll loop, not `sleep N & kill`.
# The distinction is load-bearing on Git Bash — a backgrounded killer outlives
# the hook when the guard finishes early and gets stranded, leaking a process
# per session. Here the waiting happens in the hook's own process, so there is
# nothing left behind either way, and the TERM reaches the same target
# `timeout` would have signalled.
GUARD_BUDGET_SECS=15
# `command -v timeout` is NOT the test — this is Git Bash's oldest trap, and
# qmd-cadence.sh already carries the fix (see its liveness probe). Windows ships
# C:\Windows\System32\timeout.exe, which is a SLEEP, not a command runner: no
# -k, no subcommand. Where PATH resolves to that one, `timeout -k 3 15 bash …`
# fails INSTANTLY with a usage error — and this hook would then read that rc as
# the guard's own rc 1 and print "qmd staleness check is MISCONFIGURED", a
# diagnosis pointing at the operator's env vars for a fault that is neither
# theirs nor real, while never checking the index at all. The check that
# silently stops checking, one more time, in a new disguise.
#
# Only GNU coreutils names itself in --version (the Windows one writes an
# "Invalid value for timeout (/T)" error to stderr and nothing to stdout).
# Captured into a variable rather than piped into grep -q: an early-exiting
# reader can SIGPIPE the producer, and under pipefail that reads as "not GNU" —
# dropping the bounded path on exactly the hosts that have it.
_timeout_ver="$(timeout --version 2>/dev/null || true)"
case "$_timeout_ver" in
    *oreutils*) _have_gnu_timeout=1 ;;
    *)          _have_gnu_timeout=0 ;;
esac
if [ "$_have_gnu_timeout" -eq 1 ]; then
    out=$(timeout -k 3 "$GUARD_BUDGET_SECS" bash "$GUARD" "$@" 2>&1) || rc=$?
else
    # NOT unbounded — unlike qmd-cadence's probe, which may degrade that way
    # because a blocked ARM is a loud, interactive failure. This hook runs
    # unattended at every session start and its whole product is a warning, so
    # an unbounded call here means the harness kills the hook mid-probe and the
    # session hears nothing. The poll loop below is the bound that can report.
    # EXPLICIT TEMPLATE. A bare `mktemp` is a GNU extension; BSD mktemp — which
    # is what stock macOS ships — requires a template and exits non-zero without
    # one. That platform is the entire reason this fallback exists (no coreutils
    # `timeout` either), so the GNU-only spelling meant the one system that
    # takes this branch could never create the capture file and the hook
    # reported UNVERIFIED on EVERY session start: a permanent false alarm, in
    # the code path added to avoid a permanent silence.
    guard_out_file=$(mktemp "${TMPDIR:-/tmp}/qmd-staleness.XXXXXX" 2>/dev/null) || guard_out_file=""
    if [ -z "$guard_out_file" ]; then
        # No temp file to capture into, and no GNU timeout either — so there is
        # no way to run the guard under a bound that can still be REPORTED.
        # Running it unbounded was the previous answer and it is the wrong one:
        # this is the same trade the whole hook rejects, since an unbounded probe
        # is precisely what lets the harness kill the hook before it can speak.
        # Say so instead. A machine that can neither mktemp nor supply coreutils
        # has bigger problems, and "I could not check" is the honest report.
        unverified "no GNU timeout and no writable temp file, so the guard could not be run under a bound that could be reported"
    else
        # `set -m` puts the background job in its OWN process group, which is
        # what makes the group-targeted kill below possible. This is not
        # gold-plating: GNU `timeout` does exactly the same by default — its
        # --foreground flag is documented as the OPT-OUT ("in this mode,
        # children of COMMAND will not be timed out"). An earlier round of this
        # hook signalled only the wrapper pid on the claim that `timeout`
        # behaves that way too. It does not. Signalling only the wrapper orphans
        # the `qmd status` child, which keeps holding the SQLite index — so the
        # hook would report a timeout while leaving behind the very process that
        # caused it, once per session.
        set -m
        bash "$GUARD" "$@" >"$guard_out_file" 2>&1 &
        guard_pid=$!
        set +m
        # WALL CLOCK, not iterations. Counting `sleep 1` rounds assumes a round
        # costs a second; it does not. Each round forks, and on Git Bash a fork
        # is expensive enough that 15 rounds MEASURED 36s on the operator's
        # station — a 15s budget silently behaving as a 36s one, at every
        # session start, in the code path whose entire job is to stay bounded so
        # it can report before the harness kills the hook. It also made the
        # suite's hang cases a coin flip: with a 25s fake hang, the guard could
        # die of natural causes before an overshooting loop noticed, so the
        # timeout branch never ran and the hook reported NOTHING — the permanent
        # silence this file exists to prevent, reintroduced by its own bound.
        # `SECONDS` is a bash builtin, so this needs nothing on PATH — which
        # matters here: this branch is the one reached when PATH is stripped
        # bare, and the suite's own stub PATH carries no `date`.
        _budget_start=$SECONDS
        while [ $((SECONDS - _budget_start)) -lt "$GUARD_BUDGET_SECS" ] && kill -0 "$guard_pid" 2>/dev/null; do
            sleep 1
        done
        if kill -0 "$guard_pid" 2>/dev/null; then
            # TERM, then KILL — the same escalation `timeout -k 3` performs, so
            # a guard that ignores TERM still goes away. REAPED before the
            # capture is read: without the wait, the guard can still be writing
            # into the temp file while it is being read and unlinked, so the
            # advisory could quote a half-written diagnostic.
            # Negative pid = the whole process GROUP, so the wedged `qmd status`
            # descendant goes too. Falls back to the bare pid if the group
            # signal is refused (a shell without job control), because killing
            # the wrapper is still better than killing nothing.
            kill -TERM -"$guard_pid" 2>/dev/null || kill -TERM "$guard_pid" 2>/dev/null
            _grace_start=$SECONDS
            while [ $((SECONDS - _grace_start)) -lt 3 ] && kill -0 "$guard_pid" 2>/dev/null; do
                sleep 1
            done
            kill -KILL -"$guard_pid" 2>/dev/null || kill -KILL "$guard_pid" 2>/dev/null
            wait "$guard_pid" 2>/dev/null
            # Same code `timeout` reports, so ONE routing branch below covers
            # both paths — a second "timed out" code would be a second thing to
            # keep in sync, and the case statement is the whole contract here.
            rc=124
        else
            wait "$guard_pid"
            rc=$?
        fi
        out=$(cat "$guard_out_file" 2>/dev/null)
        rm -f "$guard_out_file"
    fi
fi

case "$rc" in
    0)   exit 0 ;;   # fresh + complete — say nothing
    2)
        # No usable qmd — normally not our business, and the adopter exemption
        # depends on that silence. But QMD_STALENESS_REQUIRE_COLLECTIONS is an
        # explicit declaration that THIS station depends on qmd and on specific
        # collections. Once that is set, "qmd is gone" stops being an adopter
        # who never installed it and becomes a substrate that disappeared out
        # from under a stated policy — the monitor quietly ceasing to monitor,
        # which is the one outcome this hook exists to prevent. Silence stays
        # the default; a configured policy revokes it.
        if [ -n "$require" ]; then
            unverified "qmd is not usable here, yet QMD_STALENESS_REQUIRE_COLLECTIONS ($require) declares this station depends on it"
        fi
        exit 0 ;;
    7)   unverified "'qmd status' failed, so the index could not be read" ;;
    124|137) unverified "the staleness probe timed out (a wedged qmd or a locked index)" ;;
    1)
        # Config/usage error — a bad QMD_STALENESS_MAX_AGE_HOURS or
        # QMD_STALENESS_REQUIRE_COLLECTIONS. This MUST be loud. rc 1 used to
        # fall into the `*` catch-all below, which meant one typo in the budget
        # silently disabled the staleness check for every future session, with
        # the guard's own diagnostic captured in $out and then thrown away. A
        # monitor that quietly stops monitoring is the exact failure this ticket
        # exists to kill, so the one thing it must never do is fail quiet about
        # its own configuration. $out names WHICH setting is wrong.
        printf '<system-reminder>\n'
        printf 'qmd staleness check is MISCONFIGURED and did not run:\n%s\n' "$out"
        printf '\nFix it in the launching shell: QMD_STALENESS_MAX_AGE_HOURS is a\n'
        printf 'non-negative integer number of hours; QMD_STALENESS_REQUIRE_COLLECTIONS\n'
        printf 'is a comma-separated list of collection names. Until then this session\n'
        printf 'has NO index freshness signal — treat qmd misses as unproven.\n'
        printf '</system-reminder>\n'
        exit 0 ;;
    # rc 6 is "I could not READ the report", which is a TRUST claim, not a
    # freshness verdict — the guard's own rc-6 text already says "treat the
    # index as UNVERIFIED". Routing it through the verdict branch framed it as
    # one ("a miss is only evidence of absence when the index is current"),
    # which reads as a finding about the index rather than about the reader.
    6)   unverified "'qmd status' could not be parsed, so nothing about the index was established" ;;
    3|4|5|8) ;;      # stale / incomplete / missing collections — real verdicts
    # An rc this hook does not know is a guard it no longer understands. Failing
    # quiet here was the same bet as rc 1 used to be, and lost the same way: a
    # future exit code silently disables the check for every session until
    # someone notices the absence of a warning, which nobody ever does.
    *)   unverified "the staleness guard exited with an unrecognised code ($rc)" ;;
esac

printf '<system-reminder>\n'
printf '%s\n' "$out"
printf '\nThis is a SessionStart advisory (HIMMEL-1286), not an instruction to act.\n'
printf 'It matters for how you READ qmd results this session: a miss is only\n'
printf 'evidence of absence when the index is current.\n'
printf '</system-reminder>\n'
exit 0
