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

# ─── TTL cache: the probe runs OUT OF BAND (HIMMEL-1844) ────────────────────
# `qmd status` is a cold sqlite read, and cold is the normal case at session
# start: 11.5s measured on the operator's station against ~1.4s warm. This hook
# ran it inline on EVERY startup, compact and resume, which is a large slice of
# the 16% SessionStart timeout rate — and a hook the harness kills prints
# NOTHING, so the runs that most needed the advisory were the ones that lost it.
#
# So the probe moved off the session-start path without moving off the session:
# this run SERVES the last verdict from a cache file — a mkdir -p, a few stats
# for the trust checks below, and one cat, with no `qmd` anywhere — and
# when that file is older than the TTL it kicks a DETACHED refresh whose output
# becomes the cache the NEXT session start serves. The advisory text is
# unchanged byte-for-byte — it is simply up to one TTL old, which is nothing
# against a 36h staleness budget, and it is the same trade the notice already
# makes (`qmd status`'s own figure is a proxy, see docs/internals/enforcement.md).
#
# WHERE THE DEFERRED OUTPUT SURFACES: the next SessionStart — startup, compact
# or resume, whichever comes first — reads the refreshed cache. A station with
# no cache yet is silent for exactly one session; that is the ONLY output this
# design gives up, and it buys back the 16% of sessions that were losing it.
#
# The cache is keyed by nothing but the hook: a change to
# QMD_STALENESS_MAX_AGE_HOURS / QMD_STALENESS_REQUIRE_COLLECTIONS is honoured by
# the next refresh, not the next session. QMD_STALENESS_CACHE_TTL=0 disables the
# cache entirely and probes inline (the pre-HIMMEL-1844 behaviour, block and
# all) — which is also how test-qmd-staleness-notice.sh exercises the routing
# table without a cache file standing in front of every case.
# A PRIVATE SUBDIR of the state dir, not the state dir itself. /tmp/claude is
# shared with the rest of himmel's tmp state, and this hook needs its cache
# directory to be one nobody else can write — so it makes its own rather than
# imposing that on a directory other hooks (and possibly the operator) already
# use. Everything below then owns what it validates and tightens.
CACHE_DIR="${QMD_STALENESS_CACHE_DIR:-/tmp/claude}/qmd-staleness"
CACHE="$CACHE_DIR/qmd-staleness-notice.out"
TTL="${QMD_STALENESS_CACHE_TTL:-3600}"
case "$TTL" in ''|*[!0-9]*) TTL=3600 ;; esac

# Age of $1 in seconds, or empty when it does not exist / cannot be stat'd.
# GNU stat, then BSD stat (stock macOS) — same ladder as check-update-available.
_qmd_age() {
    local mt="" now="" age=""
    now=$(date +%s 2>/dev/null) || return 0
    mt=$(stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null) || return 0
    [ -n "$mt" ] || return 0
    age=$(( now - mt ))
    # A mtime in the FUTURE — clock skew, a restored backup, a copied file — is
    # not evidence of freshness, and a negative age would read as fresh until the
    # clock caught up, suppressing every refresh for as long as the skew lasts.
    # Report it as unknown, which routes to the refresh path.
    if [ "$age" -lt 0 ]; then return 0; fi
    printf '%s' "$age"
}

# Serve a cache only if it is OURS: a regular file, not a symlink, owned by this
# user. The path is predictable and on POSIX /tmp is shared, and unlike the rest
# of /tmp/claude — stamps and statusline JSON — this file's CONTENTS go verbatim
# into the session's context inside a <system-reminder>. That makes a
# foreign-owned or symlinked cache an injection channel, not a stale verdict.
# Anything that fails this reads as NO cache: nothing is printed and a refresh is
# kicked, so a hostile file is never read and never suppresses the probe either.
# `-O` is a POSIX test builtin (effective uid owns it), so this costs no fork and
# needs neither stat nor id — both of which differ across GNU/BSD/Git Bash.
#
# OWNERSHIP IS NOT ENOUGH, which is why _qmd_not_shared_writable exists: a file
# this user owns but that a permissive umask left group- or world-WRITABLE can be
# edited in place by another local user without ever changing hands. There is no
# test builtin for the permission bits, so this is the same GNU→BSD `stat` ladder
# _qmd_age uses; a mode that cannot be read at all counts as untrusted, which
# costs a refresh, not a verdict. A file that fails heals on the next pass — the
# refresh publishes by renaming a fresh mktemp file over it, mode and all.
_qmd_not_shared_writable() {
    local mode grp oth
    mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null) || return 1
    [ -n "$mode" ] || return 1
    oth="${mode: -1}"
    grp="${mode%?}"
    grp="${grp: -1}"
    case "$oth" in 2|3|6|7) return 1 ;; esac
    case "$grp" in 2|3|6|7) return 1 ;; esac
    return 0
}

_qmd_cache_ok() {
    [ -f "$CACHE" ] && [ ! -L "$CACHE" ] && [ -O "$CACHE" ] && [ -r "$CACHE" ] || return 1
    _qmd_not_shared_writable "$CACHE"
}

# The DIRECTORY has to pass the same bar, and for a different reason than the
# file: whoever can write the dir can rename their own file over our cache
# BETWEEN the check above and the read, which turns the leaf test into a race
# rather than a gate — and the refresh would be publishing into a path someone
# else controls. A $CACHE_DIR that does not pass disables the cache entirely and
# this hook probes INLINE: slower, but never reading or writing a path another
# user controls, and never silent.
#
# It CREATES the dir first and validates what is actually there afterwards.
# Exempting a nonexistent path as "trusted, we will make it" would leave the
# window this whole check exists to close — the path is predictable, so someone
# else can create it, or symlink it, in the gap before our `mkdir -p` (which
# succeeds on an existing symlink-to-dir and follows it). Nothing is exempt: if
# the dir is not there and ours after our own attempt to make it, there is no
# cache. `chmod` because a permissive umask (002) would otherwise produce a
# group-writable dir that every LATER session rejects — a self-inflicted
# permanent fallback to the slow probe this ticket is about. Tightening a dir
# this user owns is safe; on a foreign one the chmod simply fails and the check
# below refuses it anyway.
# The state dir ABOVE ours has to be one a stranger cannot swap. Validating only
# the leaf leaves the classic ancestor TOCTOU: replace the parent between the
# check and the read and every check below is answered by a different directory.
# Two shapes are safe — one we own, or the world-writable-but-STICKY /tmp, where
# only an entry's owner may rename or remove it. A world-writable parent WITHOUT
# the sticky bit is neither, so there is no cache and the hook probes inline.
# `${CACHE_DIR%/*}` instead of `dirname`: same answer, no fork, and this runs on
# the session-start path. Only the immediate parent is checked; the trust root
# above it (/tmp, $HOME) is the platform's to guarantee, and walking to / would
# be a directory-per-session cost for a boundary nobody can move anyway.
_qmd_parent_ok() {
    local p mode owner
    p="${CACHE_DIR%/*}"
    [ -n "$p" ] || p="/"
    # CREATE IT IF IT IS NOT THERE, then validate what is — the same
    # create-then-validate rule the leaf follows. Refusing a missing state dir
    # instead would leave a FRESH HOST, where /tmp/claude does not exist yet, on
    # the slow inline probe in every session forever: precisely the outcome this
    # ticket exists to remove, reintroduced by its own security check.
    #
    # Plain `mkdir`, not `mkdir -p`, because its success is the only honest
    # signal that the directory is OURS: if it succeeds we made it, and its mode
    # is ours to set (a permissive umask would otherwise leave it group-writable
    # and every later session would reject it). If it fails the dir already
    # existed, and it is left exactly as found — it is shared with the rest of
    # himmel's tmp state and not this hook's to retighten.
    if mkdir "$p" 2>/dev/null; then
        chmod go-w "$p" 2>/dev/null || true
    fi
    # A SYMLINK parent is refused outright, never followed: every test after this
    # resolves through the link, so an attacker-owned link in sticky /tmp aimed
    # at a user-owned directory would pass all of them and then be re-pointed
    # before the cache is read. `-L` tests the link itself, which is the only
    # test here that does not resolve it.
    [ ! -L "$p" ] || return 1
    [ -d "$p" ] || return 1
    # OWNING a parent is not enough on its own — a 0777 directory this user owns
    # is one any local user can replace entries in, which is the whole attack.
    # Sticky is the exception and the reason /tmp works: there only an entry's
    # own owner may rename or remove it, however wide the directory's own bits.
    # So: sticky, or ours AND not writable by anyone else.
    mode=$(stat -c %a "$p" 2>/dev/null || stat -f %Lp "$p" 2>/dev/null) || return 1
    case "$mode" in
        1???)
            # Sticky protects entries from everyone EXCEPT the directory's own
            # owner, so it is a trust root only when that owner is root or us —
            # which is exactly what /tmp is. A sticky directory a third party
            # owns is still theirs to rewrite, so it earns nothing here.
            owner=$(stat -c %u "$p" 2>/dev/null || stat -f %u "$p" 2>/dev/null) || return 1
            if [ "$owner" = "0" ]; then return 0; fi
            if [ -O "$p" ]; then return 0; fi
            return 1
            ;;
    esac
    [ -O "$p" ] || return 1
    _qmd_not_shared_writable "$p"
}

_qmd_dir_ok() {
    _qmd_parent_ok || return 1
    mkdir -p "$CACHE_DIR" 2>/dev/null || true
    # VALIDATE BEFORE CHMOD. `chmod` follows symlinks, so tightening first would
    # let a symlink at the predictable path aim this hook's chmod at any
    # directory the operator owns — a permission-changing primitive handed to
    # whoever wins the race. Nothing is touched until the path is proven to be a
    # real directory, not a link, and ours.
    [ -d "$CACHE_DIR" ] && [ ! -L "$CACHE_DIR" ] && [ -O "$CACHE_DIR" ] || return 1
    # Tighten only this hook's OWN subdir, never the shared state dir above it:
    # a permissive umask (002) would otherwise create it group-writable, and
    # every later session would then reject it — a self-inflicted permanent
    # fallback to the slow inline probe this ticket is about.
    chmod go-w "$CACHE_DIR" 2>/dev/null || true
    _qmd_not_shared_writable "$CACHE_DIR"
}

# Publish the refresh child's output atomically and release the lock. stdout is
# reassigned FIRST: the capture file is still open on fd 1 here, and on Windows
# renaming a file with a live handle can fail outright — publishing through a
# closed fd is the portable order, not a stylistic one.
# shellcheck disable=SC2317,SC2329  # invoked indirectly, via the EXIT trap.
_qmd_publish() {
    exec >/dev/null 2>&1 || true
    mv -f "$_cache_tmp" "$CACHE" 2>/dev/null || rm -f "$_cache_tmp" 2>/dev/null || true
    rmdir "$CACHE.lock" 2>/dev/null || true
}

if [ "${QMD_STALENESS_REFRESH:-0}" = "1" ]; then
    # Refresh child: run the probe below with stdout captured into the cache.
    # Every branch of this hook ends in `exit 0`, so the EXIT trap is the one
    # publish point and no branch can forget it.
    #
    # THE CHILD OWNS THE LOCK, start to finish. The parent used to acquire it
    # before spawning, which meant a child that never got off the ground left a
    # lock with no owner and suppressed every refresh for the next five minutes.
    # Here the only process that can create the lock is the one that then does
    # the work, so an unowned lock cannot exist; a parent whose child dies early
    # simply spawns another next session. Two sessions starting together both
    # spawn, and the one that loses `mkdir` exits immediately — a cheap bash
    # start, against two `qmd status` probes on one sqlite index, which is how a
    # session start creates the locked index it then warns about.
    _qmd_dir_ok || exit 0
    # A lock older than any live probe could be was left by a killed child
    # (SIGKILL runs no trap), so reap it before trying to acquire.
    _lock_age="$(_qmd_age "$CACHE.lock")"
    if [ -n "$_lock_age" ] && [ "$_lock_age" -gt 300 ]; then
        rmdir "$CACHE.lock" 2>/dev/null || true
    fi
    mkdir "$CACHE.lock" 2>/dev/null || exit 0   # another refresh is already running
    # mktemp, not "$CACHE.$$.tmp": a PID-derived name is guessable, and a plain
    # `>` redirect FOLLOWS a symlink someone else pre-placed there — which would
    # hand this hook out as a write primitive against any file the operator can
    # write. mktemp creates O_EXCL, so it can neither follow nor clobber, and it
    # applies the tightest mode the platform honours (0600 on POSIX; MSYS derives
    # the bits from the ACL and reports 0644, which _qmd_not_shared_writable
    # accepts because it is not writable by anyone else either).
    # Explicit template: BSD mktemp (stock macOS) rejects a bare invocation.
    _cache_tmp="$(mktemp "$CACHE.XXXXXX" 2>/dev/null)" || _cache_tmp=""
    if [ -n "$_cache_tmp" ] && exec >"$_cache_tmp" 2>/dev/null; then
        trap '_qmd_publish' EXIT
    else
        # Nowhere to write the cache: this refresh is a no-op, never a hang.
        # Release the lock, or the next 300s of session starts would skip a
        # refresh that never actually ran.
        if [ -n "$_cache_tmp" ]; then rm -f "$_cache_tmp" 2>/dev/null || true; fi
        rmdir "$CACHE.lock" 2>/dev/null || true
        exit 0
    fi
elif [ "$TTL" -gt 0 ] && _qmd_dir_ok; then
    _cache_age=""
    if _qmd_cache_ok; then _cache_age="$(_qmd_age "$CACHE")"; fi
    if [ -n "$_cache_age" ] && [ "$_cache_age" -lt "$TTL" ]; then
        cat "$CACHE" 2>/dev/null   # fresh: serve it, probe nothing
        exit 0
    fi
    # Read the previous verdict BEFORE spawning anything. A refresh that
    # published while we were still deciding what to print would make this run's
    # output depend on who won — the cold-cache run could suddenly speak, and the
    # stale-cache run could serve the new verdict — which is a coin flip in the
    # hook and a flaky assertion in its suite. Same ordering rule as
    # check-update-available: take the reading, then start the refresh.
    _prev=""
    if _qmd_cache_ok; then _prev="$(cat "$CACHE" 2>/dev/null || true)"; fi
    # shellcheck source=scripts/lib/detach.sh disable=SC1091
    . "$HERE/../lib/detach.sh" 2>/dev/null || true
    if command -v detach_run >/dev/null 2>&1; then
        # Spawn unconditionally; the child takes the lock or exits (see above).
        detach_run env QMD_STALENESS_REFRESH=1 bash "$HERE/qmd-staleness-notice.sh"
        # Serve the previous verdict while the refresh runs. A stale verdict is
        # still the last thing that was true; silence is not. The notice always
        # ends in a newline, which `$(…)` strips and this printf restores, so a
        # served notice is byte-identical to the probe's own output.
        if [ -n "$_prev" ]; then printf '%s\n' "$_prev"; fi
        exit 0
    fi
    # No detach helper — detach.sh is a sibling in this same repo, so this is a
    # broken checkout, not a configuration. Fall through and probe INLINE: the
    # pre-HIMMEL-1844 behaviour. Slow, but this hook must never fail silent.
fi
# TTL=0 (cache disabled), a cache dir this user does not own, and the
# broken-checkout fallback all land here and probe INLINE, printing to stdout
# exactly as this hook always did.

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
