#!/usr/bin/env bash
# test-tick.sh — HIMMEL-2767. Hermetic public-CLI tests for the batched console
# tick: exact one-line output, verbose human output, stale fill, and a missing
# leg document. No live queue, process, scheduler, GitHub, or bank operations.
#
# HIMMEL-2999: the primary-path scenarios below drive claude_sessions() via a
# fake /proc root (CLAUDE_SESSIONS_PROC) with real NUL-separated
# <pid>/cmdline files, not a flattened `pgrep -af` line. The ORIGINAL `pgrep
# -af` stub is kept verbatim (see "lossy fallback" below) as the dedicated
# regression test for the no-/proc degraded path.
#
# PLATFORM GUARD: no .ps1 twin, by design. The console kit is Linux-only
# (pgrep, atq, /tmp suite locks, and claudex/konsole); this Bash 3.2 suite
# exercises that platform-specific script.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/tick.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/tick-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
contains() {
    case "$2" in *"$3"*) pass "$1" ;; *) fail "$1 (missing '$3' in '$2')" ;; esac
}

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/repo/scripts/lanes/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/proc" "$W/himmel-shell-suite-test.lock"

# mkcmdline <pid> <argv...> - a real NUL-separated cmdline file for a fake
# /proc/<pid>. printf writes the NULs straight to the file; a bash string
# variable cannot hold an embedded NUL, so this must not build the payload
# in a variable first.
mkcmdline() {
    local pid="$1"; shift
    mkdir -p "$W/proc/$pid"
    printf '%s\0' "$@" > "$W/proc/$pid/cmdline"
}

# mk_pgrep_x <dir> <pid...> - a `pgrep -x claude` stub returning these bare
# pids, written into <dir>/pgrep.
mk_pgrep_x() {
    local dir="$1"; shift
    mkdir -p "$dir"
    {
        printf '#!/usr/bin/env bash\n'
        # shellcheck disable=SC2016  # single quotes are deliberate: $1 must
        # reach the generated stub file literally, not expand here.
        printf 'if [ "$1" = "-x" ]; then printf "%%s\\n" %s; exit 0; fi\n' "$*"
        printf 'exit 1\n'
    } > "$dir/pgrep"
    chmod +x "$dir/pgrep"
}

cat > "$W/repo/scripts/handover/queue-lock.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  heartbeat) exit 0 ;;
  status)
    case "$2" in *N61*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
esac
exit 2
STUB
cat > "$W/repo/scripts/context-fill.sh" <<'STUB'
#!/usr/bin/env bash
[ "${FILL_STALE:-0}" -eq 0 ] || exit 3
printf '%s\n' 28
STUB
# HIMMEL-2830: --burn shells out to the real leg-burn.sh. Stub it so the suite
# never touches ~/.claude/projects: N61 has a transcript, N66 does not.
cat > "$W/repo/scripts/lanes/leg-burn.sh" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  HIMMEL-111-legN61)
    printf 'leg-burn x.jsonl: calls=4 avg-ctx=128.1k first-turn=74.3k out=185 compactions=2 text-only=2\n' ;;
  *) printf 'leg-burn: no transcript found for session name: %s\n' "$1" >&2; exit 2 ;;
esac
STUB
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB

# Default primary-path table: pid 101 (a pinned sonnet leg), 102 (a pinned
# opus leg), 103 (the console -- no --autocompact, exempt from drift).
mkcmdline 101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61 work
mkcmdline 102 claude --model claude-opus-5 --autocompact 200000 -n LUNA-222-legN9 work
mkcmdline 103 claude --model claude-sonnet-5 -n HIMMEL-next-console work
mk_pgrep_x "$W/bin" 101 102 103

cat > "$W/bin/atq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '1 Tue job' '2 Wed job'
STUB
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "$PWD" != "$REPO" ]; then
  printf 'gh stub: expected cwd=%s, got %s\n' "$REPO" "$PWD" >&2
  exit 9
fi
printf '%s\n' 2247 2250
STUB
cat > "$W/bin/bun" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' 'claudex funded measured 5h used=12% free=88%; weekly used=34% free=66%'
STUB
# HIMMEL-2974: the real ceiling-conformance.sh, not a re-implemented stub --
# it reads the same claude_sessions() table this suite already builds, so a
# leg row here is one source of truth for procs=/models=/ceiling= alike.
cp "$HERE/../../lanes/ceiling-conformance.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh"
# HIMMEL-2999: the shared helper both ceiling-conformance.sh and tick.sh
# source by $REPO-relative path.
cp "$HERE/../../lanes/lib/claude-sessions.sh" "$W/repo/scripts/lanes/lib/claude-sessions.sh"

chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/leg-burn.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/bin/"*

printf '%s\n' '{"five_hour":{"utilization":30},"seven_day":{"utilization":28}}' > "$W/bank.json"
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/HIMMEL-111-legN61.md"
printf '%s\n' '# leg' '- READY — done' > "$W/handover/HIMMEL-222-legN65.md"
printf '%s' 1234567890 > "$W/handover/inbox/N61.md"
printf '%s' 12345678 > "$W/handover/inbox/N65.md"
printf '%s\n' 4 > "$W/handover/inbox/.cursor/N61"
printf '%s\n' 8 > "$W/handover/inbox/.cursor/N65"
printf 'pid=%s\n' "$$" > "$W/himmel-shell-suite-test.lock/owner"

export PATH="$W/bin:$PATH"
export DOC="$W/handover/console.md"
export TOKEN=test-token
export LEGS='HIMMEL-111-legN61 HIMMEL-222-legN65'
export HANDOVER_DIR="$W/handover"
export REPO="$W/repo"
export TICK_TMPDIR="$W"
export TICK_BANK_CACHE_FILE="$W/bank.json"
export CLAUDE_SESSIONS_PROC="$W/proc"

out="$(bash "$SUT")"; rc=$?
expected='TICK 12:34 hb=ok legs=N61:FRESH,N65:FREE livestate=skip procs=2 models=sonnet:1,opus:1 ceiling=ok atq=2 suites=1alive/0dead prs=#2247,#2250 bank=5h30/wk28/codex=5h12/wk34 fill=28 tails=N61:LIVE,N65:READY inbox=N61:10/4,N65:8/8'
lines="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ "$lines" = 1 ] && [ "$out" = "$expected" ]; then
    pass 'default run emits exactly the expected one batched line'
else
    fail "default run exact line (rc=$rc lines=$lines out='$out')"
fi

verbose="$(bash "$SUT" --verbose)"; rc=$?
verbose_lines="$(printf '%s\n' "$verbose" | wc -l | tr -d '[:space:]')"
if [ "$rc" -eq 0 ] && [ "$verbose_lines" -gt 1 ]; then
    pass '--verbose emits a multi-line human form'
else
    fail "--verbose emits multiple lines (rc=$rc lines=$verbose_lines)"
fi
contains '--verbose labels leg locks' "$verbose" 'leg locks: N61:FRESH,N65:FREE'
contains '--verbose labels context fill' "$verbose" 'fill: 28'
contains '--verbose labels leg models (HIMMEL-2976)' "$verbose" 'leg models: sonnet:1,opus:1'

# --- HIMMEL-2973 S1: livestate= drift field --------------------------------
# legs=N61:FRESH,N65:FREE above -- only N61 is actually held (the stub
# queue-lock only reports FRESH for a doc path containing "N61"). Each
# sub-case below rewrites $W/handover/console.md's `## Live state` section
# and re-runs the same --legs pair, so only the doc content changes between
# assertions.
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N61:nonce-ok:tok-ok:111`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
ok_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=ok run exits 0'; else fail "livestate=ok run exits 0 (rc=$rc)"; fi
contains 'Live state agreeing with held locks reports ok' "$ok_out" 'livestate=ok'

# Naming ONLY N65 here also makes N61 (the actually held lock) go unnamed --
# both directions of the mismatch fire at once, so the drift list is BOTH
# legs, sorted, not N65 alone.
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N65:nonce-stale:tok-stale:222`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
named_not_held_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=DRIFT (named, not held) run exits 0'; else fail "livestate=DRIFT (named, not held) run exits 0 (rc=$rc)"; fi
contains 'Live state naming a leg with no held lock is DRIFT' "$named_not_held_out" 'livestate=DRIFT:N61,N65'

printf '%s\n' '# console' '' '## Live state' '' \
    'legs: none' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
held_not_named_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=DRIFT (held, not named) run exits 0'; else fail "livestate=DRIFT (held, not named) run exits 0 (rc=$rc)"; fi
contains 'a held lock absent from Live state is DRIFT' "$held_not_named_out" 'livestate=DRIFT:N61'

printf '%s\n' '# console' '' 'no Live state section in this doc at all' > "$W/handover/console.md"
no_section_out="$(bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'livestate=unknown run exits 0'; else fail "livestate=unknown run exits 0 (rc=$rc)"; fi
contains 'a doc with no Live state section reports unknown, not ok' "$no_section_out" 'livestate=unknown'

rm -f "$W/handover/console.md"

# HIMMEL-2999: /proc absent (CLAUDE_SESSIONS_PROC pointing nowhere) falls back
# to the old flattened `pgrep -af` parse, kept byte-identical, plus a
# `(lossy)` suffix on models= flagging the degraded read.
mkdir -p "$W/bin-lossy"
cat > "$W/bin-lossy/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61 work' \
  '102 claude --model claude-opus-5 --autocompact 200000 -n LUNA-222-legN9 work' \
  '103 claude --model claude-sonnet-5 -n HIMMEL-next-console work'
STUB
chmod +x "$W/bin-lossy/pgrep"
lossy_out="$(CLAUDE_SESSIONS_PROC="$W/no-such-proc" PATH="$W/bin-lossy:$PATH" bash "$SUT")"
contains 'the /proc-absent fallback still counts the same two legs' "$lossy_out" 'procs=2'
contains 'the /proc-absent fallback flags the degraded read' "$lossy_out" 'models=sonnet:1,opus:1(lossy)'
contains 'the /proc-absent fallback still reports ceiling=ok' "$lossy_out" 'ceiling=ok'

# codex-2 (HIMMEL-2976 round 1 CR): a leg process matched by the leg filter
# but with no --model token at all must still show up (an "unknown" bucket),
# never silently fall out of every bucket while still counted in procs=.
mkcmdline 104 claude -n HIMMEL-444-legN70 work
mk_pgrep_x "$W/bin-nomodel" 101 104
nomodel_out="$(PATH="$W/bin-nomodel:$PATH" bash "$SUT" --legs 'HIMMEL-111-legN61 HIMMEL-444-legN70')"
contains 'a leg with no --model token buckets as unknown, not dropped' "$nomodel_out" 'models=sonnet:1,unknown:1'

# HIMMEL-2998: a --profile leg's argv carries `--settings
# /run/user/1000/himmel-console/<slug>/<name>.leg-settings.json` — the path
# segment "himmel-console" contains the substring "-console", which the old
# `!/-console/` exclusion matched against the WHOLE line rather than just the
# console's own `-n <name>` token, silently dropping every --profile leg from
# both procs= and models=. Real argv boundaries make this a non-issue by
# construction: NAME comes only from the token immediately after "-n".
mkcmdline 105 claude --settings /run/user/1000/himmel-console/x/y.leg-settings.json \
    --append-system-prompt-file /run/user/1000/himmel-console/x/leg-preface.md \
    --model claude-sonnet-5 -n HIMMEL-333-foo-legN7-2026-01-01 work
mk_pgrep_x "$W/bin-profile" 103 105
profile_out="$(PATH="$W/bin-profile:$PATH" bash "$SUT" --legs 'HIMMEL-333-foo-legN7-2026-01-01')"
contains 'a --profile leg is counted in procs= (HIMMEL-2998)' "$profile_out" 'procs=1'
contains 'a --profile leg is bucketed in models= (HIMMEL-2998)' "$profile_out" 'models=sonnet:1'

# HIMMEL-2974: a leg whose --autocompact drifted from 200000 surfaces in
# ceiling= without disturbing procs=/models=.
mkcmdline 106 claude --model claude-sonnet-5 --autocompact auto -n HIMMEL-111-legN61 work
mk_pgrep_x "$W/bin-drift" 106
drift_out="$(PATH="$W/bin-drift:$PATH" bash "$SUT" --legs 'HIMMEL-111-legN61')"
contains 'a drifted leg surfaces in ceiling= (HIMMEL-2974)' "$drift_out" 'ceiling=DRIFT:HIMMEL-111-legN61'

# HIMMEL-2999 (ticket acceptance b): a single real console session whose
# free-text -p value contains an embedded newline plus the literal word
# "claude" and a fake "-n HIMMEL-999-fake-legN1-2026-01-01" must NOT be
# counted. Pre-fix, `pgrep -af` prints this one process's argv across two
# text lines (the embedded newline survives byte-for-byte); awk then
# evaluates the four procs= conditions per LINE, so the fake fragment lands
# in a second "record" that independently satisfies all four -- the real
# session's own "-n ...-console" flag, sitting in the FIRST record, never
# gets a chance to veto it. Real argv has no such record boundary: the whole
# -p value is one NUL-delimited element, so "-n" from the free text is never
# an isolated token equal to the literal flag.
mkcmdline 107 claude --model claude-sonnet-5 --autocompact auto \
    -n HIMMEL-nextleg-2026-09-13Z-console \
    -p "$(printf 'spoof\nclaude -n HIMMEL-999-fake-legN1-2026-01-01 more work')"
mk_pgrep_x "$W/bin-spoof" 107
spoof_out="$(PATH="$W/bin-spoof:$PATH" bash "$SUT" --legs 'HIMMEL-999-fake-legN1-2026-01-01')"
contains 'a spoofed -n inside free-text argv is not counted (HIMMEL-2999)' "$spoof_out" 'procs=0'
contains 'a spoofed -n inside free-text argv does not bucket a model (HIMMEL-2999)' "$spoof_out" 'models=none'

# HIMMEL-3002: a pid pgrep reports that has already vanished by the time
# claude_sessions() reads it (no /proc/<pid> dir at all) is "not a tracked
# session" -- no row, no effect on procs=/ceiling= -- pinning the pre-fix
# behaviour for a genuinely gone process.
mk_pgrep_x "$W/bin-vanished" 101 999
vanished_out="$(PATH="$W/bin-vanished:$PATH" bash "$SUT" --legs 'HIMMEL-111-legN61')"
contains 'a vanished pid (no /proc dir) does not affect procs=' "$vanished_out" 'procs=1'
case "$vanished_out" in
    *unreadable*) fail 'a vanished pid does not report unreadable=' ;;
    *) pass 'a vanished pid does not report unreadable=' ;;
esac

# HIMMEL-3002: an alive pid whose /proc/<pid> dir exists but whose cmdline is
# unreadable (a permission boundary, e.g. hidepid) must not be silently
# treated as vanished -- tick.sh surfaces it as unreadable=<n> appended to
# procs= so the console sees the scan is degraded, not a clean complete count.
if [ "$(id -u)" = "0" ]; then
    printf 'SKIP - unreadable-cmdline case cannot be simulated as root (chmod 000 is still readable to root)\n'
else
    mkcmdline 199 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-888-legN102 work
    chmod 000 "$W/proc/199/cmdline"
    if [ -r "$W/proc/199/cmdline" ]; then
        printf 'SKIP - unreadable-cmdline case: chmod 000 did not remove read access here\n'
        chmod 700 "$W/proc/199/cmdline"
    else
        mk_pgrep_x "$W/bin-unreadable" 101 199
        unreadable_out="$(PATH="$W/bin-unreadable:$PATH" bash "$SUT" --legs 'HIMMEL-111-legN61')"
        contains 'an unreadable cmdline is surfaced as unreadable= in procs= (HIMMEL-3002)' "$unreadable_out" 'procs=1,unreadable=1'
        chmod 700 "$W/proc/199/cmdline"
    fi
fi

rm -f "$W/handover/HIMMEL-222-legN65.md"
out="$(FILL_STALE=1 bash "$SUT" --legs 'HIMMEL-111-legN61 HIMMEL-333-legN66')"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass 'missing leg document is tolerated'
else
    fail "missing leg document is tolerated (rc=$rc)"
fi
contains 'missing leg has an explicit lock status' "$out" 'legs=N61:FRESH,N66:MISSING'
contains 'missing leg has an explicit tail status' "$out" 'tails=N61:LIVE,N66:?'
contains 'context-fill rc=3 becomes unknown' "$out" 'fill=?'
case "$out" in *FILL_RC*) fail 'context-fill failure does not print FILL_RC chatter' ;; *) pass 'context-fill failure does not print FILL_RC chatter' ;; esac
missing_lines="$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')"
if [ "$missing_lines" = 1 ]; then pass 'degraded run still emits one line'; else fail "degraded run emitted $missing_lines lines"; fi

# --- HIMMEL-2830: --burn is opt-in and additive --------------------------
# The whole point of the flag is that consoles which already parse the tick
# line keep parsing it, so the no-flag case above is the real assertion and
# these three only pin what --burn adds.
burn_out="$(bash "$SUT" --burn --legs 'HIMMEL-111-legN61 HIMMEL-333-legN66')"; rc=$?
if [ "$rc" -eq 0 ]; then pass '--burn exits 0'; else fail "--burn exits 0 (rc=$rc)"; fi
contains '--burn appends first-turn/avg-ctx per leg' "$burn_out" 'burn=N61:74.3k/128.1k,N66:?'
burn_lines="$(printf '%s\n' "$burn_out" | wc -l | tr -d '[:space:]')"
if [ "$burn_lines" = 1 ]; then pass '--burn still emits one line'; else fail "--burn emitted $burn_lines lines"; fi

# A leg with no transcript must degrade to "?", never abort the tick: an armed
# leg that has not spoken yet is the normal case on the first tick after arming.
case "$burn_out" in *'no transcript found'*) fail '--burn leaks leg-burn stderr into the tick line' ;; *) pass '--burn keeps leg-burn stderr out of the line' ;; esac

# And without the flag the field is absent entirely, not empty.
noburn_out="$(bash "$SUT" --legs 'HIMMEL-111-legN61')"
case "$noburn_out" in *burn=*) fail 'burn= appears without --burn' ;; *) pass 'burn= is absent without --burn' ;; esac
contains '--verbose --burn labels the burn line' "$(bash "$SUT" --verbose --burn --legs 'HIMMEL-111-legN61')" 'leg burn (first-turn/avg-ctx): N61:74.3k/128.1k'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick.sh'
    exit 0
fi
printf 'FAIL - test-tick.sh (%s failure(s))\n' "$fails"
exit 1
