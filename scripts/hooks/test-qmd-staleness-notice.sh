#!/usr/bin/env bash
# Smoke test for scripts/hooks/qmd-staleness-notice.sh (HIMMEL-1286).
#
# The hook is a pure ROUTER: it runs scripts/luna/qmd-staleness.sh and decides,
# per exit code, whether the session hears anything. That decision is the whole
# behaviour, and it is the part that failed review — rc 2 was silent for BOTH
# "no qmd here" and "qmd is broken", so a corrupt index warned nobody. So every
# case here drives a FAKE guard that exits with a chosen code, which makes the
# routing table directly assertable without a real qmd, a real index, or a real
# 15s timeout.
#
# The hook resolves the guard as ../luna/qmd-staleness.sh relative to its OWN
# location, so each case copies the hook into a sandbox with a fake guard at
# that relative path. The real guard is never invoked.
#
# Exit codes: 0 all pass; 1 at least one fail.
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/qmd-staleness-notice.sh"

FAILED=0
pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILED=$((FAILED + 1)); }

# has NAME OUT SUBSTR — assert OUT contains SUBSTR.
has() {
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1 (missing '$3')" ;;
    esac
}
# hasnt NAME OUT SUBSTR — assert OUT does NOT contain SUBSTR.
hasnt() {
    case "$2" in
        *"$3"*) fail "$1 (unexpected '$3')" ;;
        *) pass "$1" ;;
    esac
}
# empty NAME OUT — assert OUT is empty.
empty() {
    if [ -z "$2" ]; then pass "$1"; else fail "$1 (got output: $2)"; fi
}
# is0 NAME RC — assert RC is 0.
is0() {
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1 (rc=$2)"; fi
}

# Explicit template: BSD `mktemp -d` (stock macOS) requires one and fails with a
# usage error without it. This suite exists partly to pin that exact trap in the
# hook — and it simulates a BSD mktemp further down — so a bare `mktemp -d` in
# its OWN setup would have killed it on macOS before a single case ran. The test
# has to obey the rule it enforces.
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/qmd-staleness-notice.XXXXXX")
# shellcheck disable=SC2329,SC2317
cleanup() { rm -rf "$SANDBOX" 2>/dev/null || true; }
trap cleanup EXIT

mkdir -p "$SANDBOX/hooks" "$SANDBOX/luna"
cp "$HOOK" "$SANDBOX/hooks/qmd-staleness-notice.sh"
GUARD="$SANDBOX/luna/qmd-staleness.sh"

# The fake guard prints a canned line on stderr (the real one banners there) and
# exits FAKE_RC. It also records its own argv so the pass-through cases can
# assert what the hook handed it.
cat >"$GUARD" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGV_FILE"
[ -n "${FAKE_SAY:-}" ] && printf '%s\n' "$FAKE_SAY" >&2
if [ -n "${FAKE_HANG:-}" ]; then
    # Hang in a CHILD and publish its pid, standing in for the `qmd status`
    # subprocess that actually wedges on a locked index. Killing the guard
    # wrapper alone leaves this one holding the index — which is the whole
    # point of the descendant-cleanup case below.
    sleep "$FAKE_HANG" &
    [ -n "${FAKE_CHILD_PID_FILE:-}" ] && printf '%s\n' "$!" > "$FAKE_CHILD_PID_FILE"
    # A NATIVE Windows grandchild, published by WINPID. `sleep` above is an
    # MSYS program, and MSYS process groups are a construct of msys-2.0.dll —
    # so killing an MSYS descendant proves nothing about a native one, and the
    # real subject IS native: qmd here is a bun-compiled PE. Measured: a native
    # child spawned this way INHERITS the MSYS job pgid and dies with the group
    # signal, in both the parent-alive and the re-parented case. Pinned here so
    # that stays a property of the suite rather than of a probe transcript.
    # Absolute paths, supplied by the caller: this branch runs under a PATH
    # stripped to the fallback's own needs, and padding that stub dir to make
    # these resolve would dilute the very condition the case exists to create.
    if [ -n "${FAKE_NATIVE_WINPID_FILE:-}" ]; then
        "$FAKE_PING_BIN" -n "$FAKE_HANG" 127.0.0.1 >/dev/null 2>&1 &
        _native_pid=$!
        "$FAKE_PS_BIN" -W 2>/dev/null \
            | "$FAKE_AWK_BIN" -v p="$_native_pid" '$1==p{print $4}' \
            > "$FAKE_NATIVE_WINPID_FILE"
    fi
    wait
fi
exit "${FAKE_RC:-0}"
EOF
chmod +x "$GUARD"

ARGV_FILE="$SANDBOX/argv.txt"

# run RC SAY [ENV=VAL ...] — run the hook against a guard that exits RC after
# printing SAY (pass '' for a silent guard). Stderr is dropped: the hook's whole
# product is what it puts on STDOUT for the session to read.
#
# QMD_STALENESS_CACHE_TTL=0 disables the HIMMEL-1844 TTL cache for every case in
# this suite, so each one drives the ROUTER directly instead of reading whatever
# a previous case left in the cache file. It is set BEFORE "$@" so a case that
# wants the cache can still override it — which the cache section at the end
# does. Every direct `env … bash "$SANDBOX/hooks/…"` call below carries it too.
run() {
    local rc="$1" say="$2"; shift 2
    env FAKE_RC="$rc" FAKE_SAY="$say" FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 "$@" \
        bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null
}

echo "== silent paths (only these two) =="
# A healthy index prints NOTHING: every line a SessionStart hook emits is paid
# for in every session forever.
empty "rc 0 (fresh + complete) is silent" "$(run 0 '')"
# The adopter exemption — and the ONLY non-verdict that stays quiet.
empty "rc 2 (no qmd on this station) is silent" "$(run 2 'ERR: no usable qmd found')"

echo "== but a declared policy revokes the rc 2 exemption =="
# QMD_STALENESS_REQUIRE_COLLECTIONS is an explicit statement that THIS station
# depends on qmd. Once it is set, a vanished qmd is not an adopter who never
# installed it — it is the substrate disappearing out from under a stated
# policy, i.e. the monitor quietly ceasing to monitor.
out=$(run 2 'ERR: no usable qmd found' QMD_STALENESS_REQUIRE_COLLECTIONS=himmel,luna)
has "rc 2 + a required set is NOT silent" "$out" "UNVERIFIED this session"
has "it names the policy that revoked the exemption" "$out" "QMD_STALENESS_REQUIRE_COLLECTIONS"
has "it echoes the declared set" "$out" "himmel,luna"
# The exemption survives for everyone who declared nothing — including a
# station that only customised the budget.
empty "rc 2 stays silent with only a budget set" "$(run 2 'x' QMD_STALENESS_MAX_AGE_HOURS=12)"

echo "== an unreadable report is a TRUST claim, not a verdict =="
# rc 6 is "I could not parse the report". Routing it through the verdict branch
# framed it as a finding about the INDEX ("a miss is only evidence of absence
# when the index is current") when it is a finding about the READER. The
# guard's own rc-6 text already says "treat the index as UNVERIFIED".
out=$(run 6 'ERR qmd-staleness: could not read the Documents block')
has "rc 6 is labelled UNVERIFIED" "$out" "UNVERIFIED this session"
has "rc 6 relays the guard's diagnostic" "$out" "could not read the Documents block"
hasnt "rc 6 does not assert staleness" "$out" "may be STALE"

echo "== verdicts speak up =="
for rc in 3 4 5 8; do
    out=$(run "$rc" "GUARD-BANNER-$rc")
    has "rc $rc emits a system-reminder" "$out" "<system-reminder>"
    has "rc $rc relays the guard's own text" "$out" "GUARD-BANNER-$rc"
done
out=$(run 3 'GUARD-BANNER-3')
has "a verdict frames how to READ qmd results" "$out" "evidence of absence when the index is current"
hasnt "a verdict is not labelled UNVERIFIED" "$out" "UNVERIFIED this session"

echo "== could-not-verify is a SIGNAL, not silence =="
# The finding this suite exists for. Each of these used to exit 0 silently, so
# a corrupt index, a wedged qmd, or a guard that grew a new exit code produced
# no warning at all — the same silent-degradation hole the guard closes, one
# level up.
out=$(run 7 "ERR: 'qmd status' failed (exit 1)")
has "rc 7 (qmd status failed) is NOT silent" "$out" "<system-reminder>"
has "rc 7 is labelled UNVERIFIED" "$out" "UNVERIFIED this session"
has "rc 7 names the cause" "$out" "'qmd status' failed"
has "rc 7 relays the guard's diagnostic" "$out" "exit 1"
hasnt "rc 7 does not claim the index is stale" "$out" "is STALE"
has "rc 7 still tells the reader misses are unproven" "$out" "MISSES AS UNPROVEN"

for rc in 124 137; do
    out=$(run "$rc" '')
    has "rc $rc (timed out) is NOT silent" "$out" "UNVERIFIED this session"
    has "rc $rc names the timeout" "$out" "timed out"
done

out=$(run 99 '')
has "an unrecognised rc is NOT silent" "$out" "UNVERIFIED this session"
has "an unrecognised rc names itself" "$out" "(99)"

echo "== misconfiguration is loud =="
out=$(run 1 'ERR qmd-staleness: --max-age-hours must be a non-negative integer')
has "rc 1 says MISCONFIGURED" "$out" "MISCONFIGURED"
has "rc 1 relays which setting is wrong" "$out" "--max-age-hours"
has "rc 1 names the budget env var" "$out" "QMD_STALENESS_MAX_AGE_HOURS"
has "rc 1 names the collections env var" "$out" "QMD_STALENESS_REQUIRE_COLLECTIONS"

echo "== config pass-through =="
run 0 '' >/dev/null
has "default budget is passed" "$(cat "$ARGV_FILE")" "--max-age-hours 36"
has "the guard is run quietly" "$(cat "$ARGV_FILE")" "--quiet"
hasnt "no collection set is required by default" "$(cat "$ARGV_FILE")" "--require-collections"
run 0 '' QMD_STALENESS_MAX_AGE_HOURS=12 >/dev/null
has "QMD_STALENESS_MAX_AGE_HOURS overrides the budget" "$(cat "$ARGV_FILE")" "--max-age-hours 12"
run 0 '' QMD_STALENESS_REQUIRE_COLLECTIONS=himmel,luna >/dev/null
has "QMD_STALENESS_REQUIRE_COLLECTIONS is passed through" "$(cat "$ARGV_FILE")" "--require-collections himmel,luna"
# Set-but-empty is treated as unset here rather than forwarded: `VAR=` is how a
# shell UNSETS an exported value, and the guard rejects an empty operand (rc 1),
# so forwarding it would turn "I turned this off" into a MISCONFIGURED banner
# every session.
run 0 '' QMD_STALENESS_REQUIRE_COLLECTIONS= >/dev/null
hasnt "an empty required set is not forwarded" "$(cat "$ARGV_FILE")" "--require-collections"

echo '== the no-timeout fallback must still REPORT, not just survive =='
# The regression this covers: the fallback used to run the guard UNBOUNDED on
# the reasoning that the SessionStart entry's own harness timeout bounds it.
# It does — but it bounds it by KILLING THE HOOK PROCESS, and the hook prints
# nothing until the guard returns. So a hung qmd took the warning down with it
# and the session heard silence on exactly the wedged-index condition the
# advisory exists to report. An outer timeout bounds the hang; only an inner
# one can report it.
#
# `timeout` is simulated as ABSENT by running the hook under a PATH holding
# only stubs for what the fallback itself needs — the honest way to select that
# branch, since the branch is chosen by `command -v timeout`.
NOTIMEOUT_BIN="$SANDBOX/no-timeout-bin"
mkdir -p "$NOTIMEOUT_BIN"
stub_ok=1
for t in dirname mktemp bash sleep cat rm; do
    real=$(command -v "$t" 2>/dev/null) || { stub_ok=0; break; }
    printf '#!/bin/sh\nexec "%s" "$@"\n' "$real" > "$NOTIMEOUT_BIN/$t"
    chmod +x "$NOTIMEOUT_BIN/$t"
done
# Assert the stub PATH really has no `timeout` — the whole point of this dir.
# (The previous form also required `command -v timeout` on the OUTER PATH, which
# made it unfireable: the loop above never creates a timeout stub, so the second
# test was always false and the guard could not trigger whatever the first said.)
if [ -e "$NOTIMEOUT_BIN/timeout" ]; then
    stub_ok=0   # a stray stub would defeat the whole point
fi
if [ "$stub_ok" -ne 1 ]; then
    pass "no-timeout fallback SKIPPED (could not build a timeout-free PATH)"
else
    # A guard that returns promptly: the fallback must route exactly like the
    # `timeout` path, not merely avoid crashing.
    out=$(env FAKE_RC=3 FAKE_SAY='GUARD-BANNER-3' FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 \
        PATH="$NOTIMEOUT_BIN" bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
    has "fallback still relays a verdict" "$out" "GUARD-BANNER-3"
    # A guard that HANGS. Takes the full 15s budget on purpose — this is the
    # one case that cannot be simulated by an exit code, because the defect was
    # that no code was ever reached.
    # BSD mktemp (stock macOS) REQUIRES a template and fails without one. Since
    # macOS is also the platform with no coreutils `timeout`, it is the one
    # system that actually takes this branch — so a GNU-only bare `mktemp` here
    # meant the capture file could never be created and the hook reported
    # UNVERIFIED every single session: a permanent false alarm inside the path
    # added to prevent a permanent silence. The stub refuses a no-argument call
    # exactly as BSD does.
    BSDTMP_BIN="$SANDBOX/bsd-mktemp-bin"
    mkdir -p "$BSDTMP_BIN"
    for f in "$NOTIMEOUT_BIN"/*; do cp "$f" "$BSDTMP_BIN/"; done
    real_mktemp=$(command -v mktemp)
    printf '#!/bin/sh\nif [ $# -eq 0 ]; then echo "usage: mktemp template" >&2; exit 1; fi\nexec "%s" "$@"\n' \
        "$real_mktemp" > "$BSDTMP_BIN/mktemp"
    chmod +x "$BSDTMP_BIN/mktemp"
    out=$(env FAKE_RC=3 FAKE_SAY='GUARD-BANNER-3' FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 \
        PATH="$BSDTMP_BIN" bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
    has "a BSD mktemp still lets the guard run" "$out" "GUARD-BANNER-3"
    hasnt "and does not degrade to a permanent UNVERIFIED" "$out" "UNVERIFIED this session"

    CHILD_PID_FILE="$SANDBOX/child.pid"
    : > "$CHILD_PID_FILE"
    # Windows only, and folded into THIS hang case rather than given its own:
    # a second 25s hang would double the suite's slowest stretch to prove one
    # extra assertion. Empty file elsewhere, which reads as "skipped" below.
    NATIVE_WINPID_FILE="$SANDBOX/native.winpid"
    : > "$NATIVE_WINPID_FILE"
    ping_bin=$(command -v ping 2>/dev/null || true)
    ps_bin=$(command -v ps 2>/dev/null || true)
    awk_bin=$(command -v awk 2>/dev/null || true)
    native_req=""
    if command -v tasklist >/dev/null 2>&1 && ps -W >/dev/null 2>&1 \
        && [ -n "$ping_bin" ] && [ -n "$ps_bin" ] && [ -n "$awk_bin" ]; then
        native_req="$NATIVE_WINPID_FILE"   # empty elsewhere → the guard skips it
    fi
    out=$(env FAKE_RC=0 FAKE_SAY='' FAKE_HANG=25 FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 \
        FAKE_CHILD_PID_FILE="$CHILD_PID_FILE" \
        FAKE_NATIVE_WINPID_FILE="$native_req" FAKE_PING_BIN="$ping_bin" \
        FAKE_PS_BIN="$ps_bin" FAKE_AWK_BIN="$awk_bin" \
        PATH="$NOTIMEOUT_BIN" bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
    has "a hung guard is REPORTED, not silently killed" "$out" "UNVERIFIED this session"
    has "and reported as a timeout" "$out" "timed out"
    # DESCENDANT CLEANUP. The guard's own child stands in for the wedged `qmd
    # status` that holds the SQLite index. An earlier cut signalled only the
    # wrapper pid, on the mistaken claim that GNU `timeout` does the same — it
    # does not (its --foreground flag is documented as the OPT-OUT from timing
    # out children). Killing the wrapper alone would orphan this process, so
    # every session start would leak one more holder of the index it was
    # complaining about.
    child_pid=$(cat "$CHILD_PID_FILE" 2>/dev/null || echo "")
    if [ -z "$child_pid" ]; then
        fail "the wedged descendant is killed too" "the fake guard never published a child pid"
    else
        sleep 1
        if kill -0 "$child_pid" 2>/dev/null; then
            kill -KILL "$child_pid" 2>/dev/null   # do not leak it out of the suite
            fail "the wedged descendant is killed too" "pid $child_pid survived the timeout"
        else
            pass "the wedged descendant is killed too"
        fi
    fi
    # And the NATIVE one. `sleep` above is an MSYS program, so killing it says
    # nothing about a native PE — and native is the case that matters, since
    # qmd is a bun-compiled executable. Windows-only by nature; a non-Windows
    # station reports it skipped rather than silently claiming coverage.
    if [ -z "$native_req" ]; then
        pass "native-descendant case SKIPPED (no tasklist/ps -W on this station)"
    else
        native_winpid=$(cat "$NATIVE_WINPID_FILE" 2>/dev/null || echo "")
        if [ -z "$native_winpid" ]; then
            fail "the wedged NATIVE descendant is killed too" \
                "the fake guard never published a native winpid"
        else
            sleep 1
            if tasklist //FI "PID eq $native_winpid" 2>/dev/null | grep -q "$native_winpid"; then
                fail "the wedged NATIVE descendant is killed too" \
                    "winpid $native_winpid survived the timeout"
            else
                pass "the wedged NATIVE descendant is killed too"
            fi
        fi
    fi
fi

echo '== a Windows timeout.exe on PATH must not defeat the check =='
# Git Bash's oldest trap. Windows ships C:\Windows\System32\timeout.exe, which
# is a SLEEP, not a command runner: no -k, no subcommand. A `command -v timeout`
# test passes on it, then `timeout -k 3 15 bash "$GUARD"` fails INSTANTLY with a
# usage error — and the hook used to read that rc as the GUARD's rc 1 and print
# "MISCONFIGURED", blaming the operator's env vars for a fault that is neither
# theirs nor real, while never checking the index at all. qmd-cadence.sh already
# carries the coreutils discriminator for exactly this; the hook now does too.
if [ "$stub_ok" -ne 1 ]; then
    pass "non-GNU timeout case SKIPPED (no timeout-free PATH to build on)"
else
    WINTIMEOUT_BIN="$SANDBOX/win-timeout-bin"
    mkdir -p "$WINTIMEOUT_BIN"
    for f in "$NOTIMEOUT_BIN"/*; do cp "$f" "$WINTIMEOUT_BIN/"; done
    # Faithful stand-in: rejects --version (writes to stderr, nothing to stdout)
    # and fails on any GNU-style invocation, exactly like the real timeout.exe.
    printf '#!/bin/sh\necho "Invalid value for timeout (/T)" >&2\nexit 1\n' > "$WINTIMEOUT_BIN/timeout"
    chmod +x "$WINTIMEOUT_BIN/timeout"
    out=$(env FAKE_RC=3 FAKE_SAY='GUARD-BANNER-3' FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 \
        PATH="$WINTIMEOUT_BIN" bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
    has "the guard still runs under a non-GNU timeout" "$out" "GUARD-BANNER-3"
    hasnt "and is NOT misreported as operator misconfiguration" "$out" "MISCONFIGURED"
    # The bound must survive too: a non-GNU timeout routes to the poll loop, not
    # to an unbounded call, so a hung guard is still REPORTED.
    out=$(env FAKE_RC=0 FAKE_SAY='' FAKE_HANG=25 FAKE_ARGV_FILE="$ARGV_FILE" QMD_STALENESS_CACHE_TTL=0 \
        PATH="$WINTIMEOUT_BIN" bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
    has "a hang is still bounded and reported" "$out" "UNVERIFIED this session"
    has "and still named as a timeout" "$out" "timed out"
fi

echo "== never blocks a session =="
for rc in 0 1 2 3 6 7 8 99 124; do
    run "$rc" 'x' >/dev/null 2>&1
    is0 "rc $rc still exits 0" "$?"
done
# A checkout where the hook is wired but the guard is absent. It must not
# error — but it must not be SILENT either. This is not the
# adopter-without-qmd case (that is rc 2, and stays quiet): the hook and the
# guard ship in the same repo one directory apart, so a hook running without
# its guard is an INCONSISTENT checkout with the freshness check permanently
# off. Silence there is the same silent-stop this ticket exists to kill,
# relocated into the wiring.
mkdir -p "$SANDBOX/bare/hooks"
cp "$HOOK" "$SANDBOX/bare/hooks/qmd-staleness-notice.sh"
out=$(QMD_STALENESS_CACHE_TTL=0 bash "$SANDBOX/bare/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null)
is0 "a missing guard still exits 0" "$?"
has "a missing guard is REPORTED, not silent" "$out" "UNVERIFIED this session"
has "and named as the wiring fault it is" "$out" "staleness guard is missing"

echo "== TTL cache: the probe runs out of band (HIMMEL-1844) =="
# The cases above disable the cache to reach the router. These four are the
# cache's own contract — what the session-start path serves, and where the
# deferred verdict surfaces. What is NOT pinned here: that a detached process is
# fast, or how `qmd status` behaves. The seam is ours — cache in, cache out.
# QMD_STALENESS_CACHE_DIR names the STATE dir; the hook keeps its cache in a
# private `qmd-staleness/` subdir of it, which it creates and owns. The fixtures
# below write straight into that subdir, so they mkdir it themselves.
CACHE_STATE_DIR="$SANDBOX/cache"
CACHE_DIR="$CACHE_STATE_DIR/qmd-staleness"
CACHE="$CACHE_DIR/qmd-staleness-notice.out"
# The hook resolves detach.sh as ../lib/ from its own location, exactly as it
# resolves the guard, so the sandbox needs the real one at that relative path.
mkdir -p "$SANDBOX/lib"
cp "$(cd "$(dirname "$0")" && pwd)/../lib/detach.sh" "$SANDBOX/lib/detach.sh"

# runc RC SAY [ENV=VAL ...] — like run(), but with the cache ENABLED and pointed
# at the sandbox.
runc() {
    local rc="$1" say="$2"; shift 2
    env FAKE_RC="$rc" FAKE_SAY="$say" FAKE_ARGV_FILE="$ARGV_FILE" \
        QMD_STALENESS_CACHE_DIR="$CACHE_STATE_DIR" "$@" \
        bash "$SANDBOX/hooks/qmd-staleness-notice.sh" </dev/null 2>/dev/null
}
# wait_for_cache PATTERN — bounded poll for the detached refresh to publish.
# The ONE place this suite waits on the out-of-band leg. It returns the instant
# the file matches, so the 20s ceiling is only ever paid by a real failure.
wait_for_cache() {
    local i=0
    while [ "$i" -lt 20 ]; do
        if [ -s "$CACHE" ] && grep -q "$1" "$CACHE" 2>/dev/null; then return 0; fi
        sleep 1
        i=$((i + 1))
    done
    return 1
}

# 1. A fresh cache is served and the slow path never runs — the whole point.
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
printf 'CACHED-NOTICE\n' > "$CACHE"
# The fixture has to obey the guard it is testing: a plain `>` uses the ambient
# umask, so under the very common 002 this file would be 0664 — group-writable,
# correctly refused, and case 1 would fail against a working implementation. Case
# 7 below creates that condition ON PURPOSE; here it is noise.
chmod go-w "$CACHE" 2>/dev/null || true
: > "$ARGV_FILE"
out=$(runc 3 'GUARD-BANNER-3')
has "a fresh cache is served" "$out" "CACHED-NOTICE"
hasnt "and the guard did not speak this session" "$out" "GUARD-BANNER-3"
empty "the guard was never invoked at all" "$(cat "$ARGV_FILE" 2>/dev/null)"

# 2. A cold cache is silent for exactly ONE session, and the verdict it could
#    not produce in time reaches the NEXT session start. The second run's guard
#    is rc 0 (silent), so anything on stdout can only have come from the cache.
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
out=$(runc 3 'GUARD-BANNER-3')
empty "a cold cache costs one silent session" "$out"
if wait_for_cache 'GUARD-BANNER-3'; then
    has "the deferred verdict reaches the NEXT session start" "$(runc 0 '')" "GUARD-BANNER-3"
else
    fail "the deferred verdict reaches the NEXT session start" "refresh never published"
fi

# 3. A STALE cache still speaks. Silence would be the regression this hook
#    exists to prevent, so the last verdict is served while the refresh runs.
printf 'OLD-NOTICE\n' > "$CACHE"
chmod go-w "$CACHE" 2>/dev/null || true   # umask 002 would make this 0664 (see case 1)
sleep 2   # age the cache past the 1s TTL used below
out=$(runc 4 'GUARD-BANNER-4' QMD_STALENESS_CACHE_TTL=1)
has "a stale cache still speaks" "$out" "OLD-NOTICE"
hasnt "without waiting for the probe" "$out" "GUARD-BANNER-4"
if wait_for_cache 'GUARD-BANNER-4'; then
    pass "and the refresh replaces it out of band"
else
    fail "and the refresh replaces it out of band" "cache still holds the old notice"
fi

# 4. Served-from-cache output is the SAME output, not a summary of it.
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
inline=$(runc 5 'GUARD-BANNER-5' QMD_STALENESS_CACHE_TTL=0)
runc 5 'GUARD-BANNER-5' >/dev/null 2>&1
if wait_for_cache 'GUARD-BANNER-5' && [ "$inline" = "$(runc 5 'GUARD-BANNER-5')" ]; then
    pass "the cached notice is byte-identical to the inline one"
else
    fail "the cached notice is byte-identical to the inline one" "differs from the inline probe"
fi

# 5. A cache that is not ours is not context. The file's contents go verbatim
#    into a <system-reminder>, so a cache this user does not own is an injection
#    channel. Ownership cannot be forged from a single-user suite, but the
#    symlink half of the same guard can be driven directly. MSYS `ln -s` copies
#    instead of linking unless winsymlinks is on, so the case skips where a real
#    symlink cannot be made rather than asserting against a copy.
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
printf 'HOSTILE-NOTICE\n' > "$SANDBOX/hostile.out"
if ln -s "$SANDBOX/hostile.out" "$CACHE" 2>/dev/null && [ -L "$CACHE" ]; then
    hasnt "a symlinked cache is not served into the session" "$(runc 0 '')" "HOSTILE-NOTICE"
else
    pass "symlinked-cache case SKIPPED (no real symlinks on this platform)"
fi

# 6. A cache DIR this user does not own disables the cache: the hook probes
#    inline rather than reading or writing a path someone else controls, and it
#    still speaks. Foreign ownership is not forgeable from a single-user suite;
#    a non-directory at that path trips the same guard and is.
printf 'not a directory\n' > "$SANDBOX/not-a-dir"
has "an untrusted cache dir falls back to an inline probe" \
    "$(runc 3 'GUARD-BANNER-3' QMD_STALENESS_CACHE_DIR="$SANDBOX/not-a-dir")" \
    "GUARD-BANNER-3"

# 7. Owning the cache is not enough — a cache another local user can WRITE is
#    the same injection channel without ever changing hands. MSYS derives the
#    mode from the ACL and ignores chmod, so the case skips where the condition
#    cannot be created (checked by reading the mode back, not by guessing the OS).
rm -rf "$CACHE_DIR"; mkdir -p "$CACHE_DIR"
printf 'WRITABLE-NOTICE\n' > "$CACHE"
chmod 666 "$CACHE" 2>/dev/null || true
cache_mode=$(stat -c %a "$CACHE" 2>/dev/null || stat -f %Lp "$CACHE" 2>/dev/null || echo "")
case "$cache_mode" in
    *[2367]) hasnt "a world-writable cache is not served" "$(runc 0 '')" "WRITABLE-NOTICE" ;;
    *)       pass "world-writable-cache case SKIPPED (chmod is a no-op here)" ;;
esac

# 8. A host with NO state dir at all still initializes the cache. Every fixture
#    above creates the dir first, which hid the case that matters most: a fresh
#    machine. Refusing a missing state dir instead of creating it would leave
#    such a machine on the slow inline probe in every session forever — the exact
#    outcome this ticket exists to remove.
rm -rf "$CACHE_STATE_DIR"
empty "a host with no state dir is silent for one session" "$(runc 3 'GUARD-BANNER-3')"
if wait_for_cache 'GUARD-BANNER-3'; then
    pass "and initializes the cache from cold"
else
    fail "and initializes the cache from cold" "no cache after the refresh"
fi

if [ "$FAILED" -gt 0 ]; then echo "FAIL: $FAILED case(s)"; exit 1; fi
echo "OK"; exit 0
