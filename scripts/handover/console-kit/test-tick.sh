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
    case "$2" in *N61*|*-N1-*|*-N2-*|*-N191-*|*-leg192-*|*-legN194-*|*odd-name*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
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
  HIMMEL-555-N41-thing)
    printf 'leg-burn y.jsonl: calls=9 avg-ctx=90.0k first-turn=60.0k out=100 compactions=0 text-only=1\n' ;;
  *) printf 'leg-burn: no transcript found for session name: %s\n' "$1" >&2; exit 2 ;;
esac
STUB
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB

# Default primary-path table: pid 101 (a pinned sonnet leg, named in $LEGS
# below), 102 (a pinned opus leg belonging to a DIFFERENT console's --legs --
# HIMMEL-3145: procs=/models= now count only the sessions THIS console
# dispatched, so 102 is live but must not appear in procs=/models=, only in
# ceiling= which scans every session regardless of --legs), 103 (the console
# -- no --autocompact, exempt from drift).
mkcmdline 101 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-111-legN61 work
mkcmdline 102 claude --model claude-opus-5 --autocompact 200000 -n LUNA-222-legN9 work
mkcmdline 103 claude --model claude-sonnet-5 -n HIMMEL-next-console work
mk_pgrep_x "$W/bin" 101 102 103

cat > "$W/bin/atq" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' '1 Tue job' '2 Wed job'
STUB
# HIMMEL-3197: `gh api -i graphql` is the gql= budget probe (ghb_read). The stub
# logs each call to STUB_GH_API_LOG, and prints STUB_GQL_OUT (a printf %b string,
# default = a healthy header set) then exits STUB_GQL_RC (default 0).
cat > "$W/bin/gh" <<'STUB'
#!/usr/bin/env bash
if [ "${1:-}" = api ]; then
  [ -z "${STUB_GH_API_LOG:-}" ] || printf '%s\n' "$*" >> "$STUB_GH_API_LOG"
  printf '%b' "${STUB_GQL_OUT-HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4321\r\nX-Ratelimit-Reset: 1790000000\r\n\r\n}"
  exit "${STUB_GQL_RC:-0}"
fi
if [ "$PWD" != "$REPO" ]; then
  printf 'gh stub: expected cwd=%s, got %s\n' "$REPO" "$PWD" >&2
  exit 9
fi
printf '%s\n' 2247 2250
STUB
# HIMMEL-2761: orphans= reads `ps -eo pid=,ppid=,etime=,args=` (orphan-loops.sh).
# Answered from $PS_FIXTURE so the suite never reads the live process table;
# any other ps argv falls through to the real ps.
cat > "$W/bin/ps" <<'STUB'
#!/usr/bin/env bash
if [ "$*" = "-eo pid=,ppid=,etime=,args=" ]; then
  cat "$PS_FIXTURE"
  exit 0
fi
exec /bin/ps "$@"
STUB
printf '%s\n' '    1     0 40-00:00:01 /sbin/init' > "$W/ps-none.txt"
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

# HIMMEL-3167: fleet=/capacity= reuse bank-preflight.sh's FLEET line. This stub
# prints the same stderr line shape (STUB_FLEET_LINE overrides it) and records
# the env tick ran it under, so the suite can pin that tick never asks it for a
# ledger row or a launch refusal.
cat > "$W/repo/scripts/lib/bank-preflight.sh" <<'STUB'
#!/usr/bin/env bash
[ -z "${STUB_PF_SEEN:-}" ] || printf 'ledger=%s launch=%s\n' "${CADENCE_BANK_LEDGER:-unset}" "${CADENCE_BANK_LAUNCH:-unset}" > "$STUB_PF_SEEN"
printf '%s\n' "${STUB_FLEET_LINE-bank-preflight: FLEET native=1 claudex=0 reserved=0 total=1/8}" >&2
printf 'PROCEED\n'
STUB

chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/repo/scripts/lanes/leg-burn.sh" "$W/repo/scripts/lanes/ceiling-conformance.sh" "$W/repo/scripts/lib/bank-preflight.sh" "$W/bin/"*

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
export PS_FIXTURE="$W/ps-none.txt"
export TICK_BANK_CACHE_FILE="$W/bank.json"
export CLAUDE_SESSIONS_PROC="$W/proc"
# HIMMEL-3167: launch logs live in <work-dir>/<chain>/<name>.launch.log.
export TICK_LAUNCH_DIR="$W/console-work"
mkdir -p "$W/console-work/chain"

# The default stub reset epoch, rendered the way tick.sh renders it (local HH:MM).
gql_hm="$(date -d @1790000000 +%H:%M 2>/dev/null || date -r 1790000000 +%H:%M)"
out="$(bash "$SUT")"; rc=$?
expected='TICK 12:34 hb=ok legs=N61:FRESH,N65:FREE livestate=skip procs=1 models=sonnet:1 ceiling=ok atq=2 suites=1alive/0dead prs=#2247,#2250 bank=5h30/wk28/codex=5h12/wk34 fill=28 tails=N61:LIVE,N65:READY inbox=N61:10/4,N65:8/8 tick=UNKNOWN fleet=1/8 capacity=UNDERFILLED:7 gql=4321/'"$gql_hm"' orphans=none nonces=skip'
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
contains '--verbose labels leg models (HIMMEL-2976, HIMMEL-3145)' "$verbose" 'leg models: sonnet:1'

# --- HIMMEL-3130: a comma-separated --legs is equivalent to space-separated -
# `for leg in $LEGS` word-splits on IFS whitespace only, so a comma-joined
# value used to be one iteration over one nonexistent path -- the label was
# derived from the tail of the whole blob, and every leg but the last vanished
# from legs=/tails= while being reported as a single false MISSING. RED
# control (pre-fix tick.sh, this same two-leg fixture): the comma form printed
# 'legs=N61.md,N65:MISSING' (one collapsed entry) while the space form printed
# the correct 'legs=N61:FRESH,N65:FREE' -- confirmed manually against
# scripts/handover/console-kit/tick.sh@8fa186e5 before this fix.
comma_out="$(bash "$SUT" --legs 'HIMMEL-111-legN61,HIMMEL-222-legN65')"; comma_rc=$?
space_out="$(bash "$SUT" --legs 'HIMMEL-111-legN61 HIMMEL-222-legN65')"; space_rc=$?
if [ "$comma_rc" -eq 0 ] && [ "$space_rc" -eq 0 ] && [ "$comma_out" = "$space_out" ]; then
    pass 'a comma-separated --legs produces byte-identical output to space-separated (HIMMEL-3130)'
else
    fail "comma vs space --legs mismatch (comma='$comma_out' space='$space_out')"
fi
contains 'the comma-separated form resolves every leg, not just the last (HIMMEL-3130)' "$comma_out" 'legs=N61:FRESH,N65:FREE'

# HIMMEL-3130 (ticket DONE WHEN): legs= must never silently disagree with how
# many docs --legs named -- the original bug's contradiction was legs= naming
# ONE leg while procs= (a separately-scanned live table) reported more
# processes alive, with nothing reconciling the two. Assert the leg-entry
# count against the docs actually passed, independent of the process table.
legs_field="$(printf '%s\n' "$comma_out" | grep -oE 'legs=[^ ]+' | cut -d= -f2)"
legs_count="$(printf '%s\n' "$legs_field" | awk -F',' '{print NF}')"
if [ "$legs_count" = 2 ]; then
    pass 'legs= names exactly as many entries as --legs docs were passed (HIMMEL-3130)'
else
    fail "legs= entry count mismatch (legs_field='$legs_field' count=$legs_count, expected 2)"
fi

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

# --- HIMMEL-3254: nonces=<ok|RELAYED|UNCONFIRMED> -----------------------------
# A HELD leg whose Live-state nonce still carries a PREVIOUS console's letter
# prefix (nonce shape `<LETTER>-<leg>-<hex>`; the letter is the console doc's
# own, parsed from `<prefix>-nextleg-<date><LETTER>-<name>.md`) is not rotated.
# That is a VALID state -- a relay may keep the leg's token -- so the leg's own
# handover doc decides: a `SUCCESSION accepted:` Results bullet naming this
# console = RELAYED, none = UNCONFIRMED. Only N61 is held (stub above).
kdoc="$W/handover/HIMMEL-nextleg-2026-09-20K-console.md"
n61doc="$W/handover/HIMMEL-111-legN61.md"
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:J-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
unconfirmed_out="$(DOC="$kdoc" bash "$SUT")"; rc=$?
if [ "$rc" -eq 0 ]; then pass 'nonces=UNCONFIRMED run exits 0'; else fail "nonces=UNCONFIRMED run exits 0 (rc=$rc)"; fi
contains 'a held leg on the predecessor J prefix with no acceptance bullet is UNCONFIRMED under console K' "$unconfirmed_out" 'nonces=UNCONFIRMED:N61'
contains '--verbose labels the nonce census' "$(DOC="$kdoc" bash "$SUT" --verbose)" 'nonces: UNCONFIRMED:N61'
case "$unconfirmed_out" in
    *STRANDED*) fail 'the field never asserts STRANDED: it cannot observe that' ;;
    *) pass 'the field never asserts STRANDED: it cannot observe that' ;;
esac

# The state that occurs in practice: the outgoing console relayed the leg
# WITHOUT rotating its token, and the leg accepted and wrote its bullet. The
# Live-state nonce still carries J, and that is correct -- not an incident.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# leg' '- LIVE — working' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-console` replaces `HIMMEL-nextleg-2026-09-19J-console`' > "$n61doc"
relayed_out="$(DOC="$kdoc" bash "$SUT")"
contains 'an unrotated leg that accepted this console reads nonces=RELAYED (relay without rotation is valid)' "$relayed_out" 'nonces=RELAYED:N61'
case "$relayed_out" in
    *UNCONFIRMED*|*STRANDED*) fail 'an unrotated leg that accepted this console must not read as an incident' ;;
    *) pass 'an unrotated leg that accepted this console must not read as an incident' ;;
esac
contains 'the tails census is unchanged by the acceptance bullet' "$relayed_out" 'tails=N61:LIVE'

# A bullet that names ANOTHER console does not confirm THIS one.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# leg' '- LIVE — working' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-19J-console` replaces `HIMMEL-nextleg-2026-09-18I-console`' > "$n61doc"
contains 'an acceptance bullet naming a different console does not confirm this one' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# Only the INCOMING session counts: a leg that accepted a LATER console L (which
# replaces K) names K after `replaces`, and that must not confirm K.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# leg' '- LIVE — working' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20L-console` replaces `HIMMEL-nextleg-2026-09-20K-console`' > "$n61doc"
contains 'a stem after the word replaces is the OUTGOING console and confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# The LATEST acceptance wins: accepted K, then moved on to L -> not K's leg.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# leg' '- LIVE — working' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-console` replaces `HIMMEL-nextleg-2026-09-19J-console`' \
    '- 05:02 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20L-console` replaces `HIMMEL-nextleg-2026-09-20K-console`' > "$n61doc"
contains 'a later acceptance of another console supersedes an earlier one' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# A handover root whose path contains a space keeps its leg doc whole.
# shellcheck disable=SC2016  # backtick spans, literal fixture text
printf '%s\n' '# leg' '- LIVE — working' \
    '- 04:17 SUCCESSION accepted: `HIMMEL-nextleg-2026-09-20K-console` replaces `HIMMEL-nextleg-2026-09-19J-console`' > "$n61doc"
ln -s "$W/handover" "$W/hand over"
contains 'a leg doc path containing a space is read whole (RELAYED, not UNCONFIRMED)' "$(HANDOVER_DIR="$W/hand over" DOC="$kdoc" bash "$SUT")" 'nonces=RELAYED:N61'
rm -f "$W/hand over"

# Prose that merely mentions the phrase (not a Results bullet) confirms nothing.
printf '%s\n' '# leg' '- LIVE — working' \
    'note: SUCCESSION accepted: HIMMEL-nextleg-2026-09-20K-console replaces J (prose, not a bullet)' > "$n61doc"
contains 'a non-bullet line mentioning SUCCESSION accepted confirms nothing' "$(DOC="$kdoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'
printf '%s\n' '# leg' '- LIVE — working' > "$n61doc"

# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:K-N61-9f8e7d:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
rotated_out="$(DOC="$kdoc" bash "$SUT")"
contains 'a held leg rotated onto the K prefix reads nonces=ok' "$rotated_out" 'nonces=ok'
case "$rotated_out" in
    *UNCONFIRMED*|*RELAYED*|*STRANDED*) fail 'a rotated leg reports neither UNCONFIRMED nor RELAYED' ;;
    *) pass 'a rotated leg reports neither UNCONFIRMED nor RELAYED' ;;
esac

# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# K' '' '## Live state' '' \
    'legs: `N61:K-N61-9f8e7d:tok-61:111`, `N65:J-N65-aa11bb:tok-65:222`' 'queue: none' 'last GO: none' 'acked: none' > "$kdoc"
contains 'a wrapped (FREE-lock) leg on an old prefix is not flagged -- nothing to rotate' "$(DOC="$kdoc" bash "$SUT")" 'nonces=ok'

# `AA` must not read as a prefix of `A`: the boundary is the dash.
aadoc="$W/handover/HIMMEL-nextleg-2026-09-20AA-console.md"
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# AA' '' '## Live state' '' \
    'legs: `N61:A-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$aadoc"
contains 'letter A is not letter AA (prefix boundary is the dash)' "$(DOC="$aadoc" bash "$SUT")" 'nonces=UNCONFIRMED:N61'

# A doc whose name carries no console letter cannot be judged: unknown, never a guess.
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N61:J-N61-0a1b2c:tok-61:111`' 'queue: none' 'last GO: none' 'acked: none' > "$W/handover/console.md"
contains 'a console doc name with no parseable letter reads nonces=unknown' "$(bash "$SUT")" 'nonces=unknown'

rm -f "$W/handover/console.md" "$kdoc" "$aadoc"

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
contains 'the /proc-absent fallback still counts the dispatched leg (HIMMEL-3145)' "$lossy_out" 'procs=1'
contains 'the /proc-absent fallback flags the degraded read' "$lossy_out" 'models=sonnet:1(lossy)'
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
out="$(FILL_STALE=1 bash "$SUT" --legs 'HIMMEL-111-legN61 HIMMEL-333-legN66' 2>"$W/notfound-stderr.txt")"; rc=$?
if [ "$rc" -eq 0 ]; then
    pass 'missing leg document is tolerated'
else
    fail "missing leg document is tolerated (rc=$rc)"
fi
# HIMMEL-3130: an unresolvable --legs entry is NOTFOUND, never MISSING --
# MISSING is reserved for a lock that is genuinely gone, which a console
# reads as "reclaim this leg's lock". RED control (pre-fix tick.sh, same
# fixture): stdout printed 'legs=N61:FRESH,N66:MISSING' with an EMPTY stderr
# -- a bare, unwarned MISSING for a typo'd/unresolvable doc.
contains 'unresolvable leg has NOTFOUND, not MISSING, as its lock status' "$out" 'legs=N61:FRESH,N66:NOTFOUND'
contains 'unresolvable leg has an explicit tail status' "$out" 'tails=N61:LIVE,N66:?'
contains 'an unresolvable leg doc emits a named warning on stderr' "$(cat "$W/notfound-stderr.txt")" 'tick: no such leg doc:'
case "$out" in *MISSING*) fail 'an unresolvable leg doc never prints bare MISSING' ;; *) pass 'an unresolvable leg doc never prints bare MISSING' ;; esac
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

# --- HIMMEL-3145: current-convention leg names (<TICKET>-N<k>-<slug>, no
# "-leg" substring at all -- docs/handover/console-template.md:104 is the
# contract every console since HIMMEL-2975 writes) must resolve/count/compare
# identically to the legacy -legN<k> spelling. This fixture is the ticket's
# own RED control (console G, 2026-09-17, HIMMEL-3145 evidence): two live
# legs named this way used to report procs=0 models=none and an
# unconditional livestate=DRIFT naming every leg twice -- confirmed against
# scripts/handover/console-kit/tick.sh@6ac483e4 before this fix.
mkcmdline 110 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3144-N1-console-idle-guard work
mkcmdline 111 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3143-N2-merge-jira-optin work
mk_pgrep_x "$W/bin-conv" 110 111
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/HIMMEL-3144-N1-console-idle-guard.md"
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/HIMMEL-3143-N2-merge-jira-optin.md"
# shellcheck disable=SC2016  # backtick leg span, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N1:nonce1:tok1:110`, `N2:nonce2:tok2:111`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
conv_out="$(PATH="$W/bin-conv:$PATH" bash "$SUT" --legs 'HIMMEL-3144-N1-console-idle-guard HIMMEL-3143-N2-merge-jira-optin')"
contains 'a current-convention leg label resolves to N<k> (HIMMEL-3145)' "$conv_out" 'legs=N1:FRESH,N2:FRESH'
contains 'current-convention legs are counted in procs= (HIMMEL-3145)' "$conv_out" 'procs=2'
contains 'current-convention legs are bucketed in models= (HIMMEL-3145)' "$conv_out" 'models=sonnet:2'
contains 'current-convention legs compare like-with-like in livestate= (HIMMEL-3145)' "$conv_out" 'livestate=ok'
case "$conv_out" in
    *DRIFT*) fail 'a current-convention leg must not report livestate=DRIFT (HIMMEL-3145)' ;;
    *) pass 'a current-convention leg must not report livestate=DRIFT (HIMMEL-3145)' ;;
esac

# Legacy regression (ticket acceptance): an archived console doc named in the
# OLD -legN<k>- spelling still resolves to N<k> -- leg_label() must recognise
# both spellings in the same namespace, not just the new one.
legacy_out="$(bash "$SUT" --legs 'HIMMEL-3064-legN12-old-console-format' 2>/dev/null)"
contains 'a legacy -legN<k>- doc still resolves to N<k> (HIMMEL-3145 regression)' "$legacy_out" 'legs=N12:NOTFOUND'

# --- HIMMEL-3145 (ticket root cause 3 / acceptance): a field that cannot be
# computed must say so. A fatal census scan (pgrep itself failing, rc>1 and
# not the HIMMEL-3002 degraded-scan rc=3) discards the whole session table --
# procs=/models= must report "unknown", never a clean "0"/"none" that reads
# as "no legs are running" when the truth is "the scan itself broke".
mkdir -p "$W/bin-census-fail"
cat > "$W/bin-census-fail/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 2
STUB
chmod +x "$W/bin-census-fail/pgrep"
census_fail_out="$(PATH="$W/bin-census-fail:$PATH" bash "$SUT" --legs 'HIMMEL-111-legN61')"
contains 'a fatal census scan reports procs=unknown, not a false procs=0 (HIMMEL-3145)' "$census_fail_out" 'procs=unknown'
contains 'a fatal census scan reports models=unknown, not a false models=none (HIMMEL-3145)' "$census_fail_out" 'models=unknown'
case "$census_fail_out" in
    *'procs=0'*) fail 'a fatal census scan must not render procs=0' ;;
    *) pass 'a fatal census scan must not render procs=0' ;;
esac

# --- HIMMEL-3145 (console review, round 2): the same "cannot be computed
# must say so" rule applies to an EMPTY dispatch set, not just a broken
# census scan. --legs is optional (usage block, :23) -- with it absent,
# leg_names stays empty and leg_names_wrapped is ",,", so a matched-nothing
# filter would print a clean "0" (index(",,", ","name",") is always 0,
# since the needle is longer than the haystack) even while the default
# fixture's two legs are live in the session table. procs=0 is only true
# when there IS a dispatch set and it is empty of matches, never when there
# is no dispatch set to check against.
no_legs_out="$(LEGS='' bash "$SUT")"
contains 'no --legs reports procs=unknown, not a false procs=0 (HIMMEL-3145)' "$no_legs_out" 'procs=unknown'
contains 'no --legs reports models=unknown, not a false models=none (HIMMEL-3145)' "$no_legs_out" 'models=unknown'
case "$no_legs_out" in
    *'procs=0'*) fail 'no --legs must not render procs=0' ;;
    *) pass 'no --legs must not render procs=0' ;;
esac

# --- HIMMEL-3167: fleet=<live>/<cap> + capacity= ------------------------------
# fleet= is bank-preflight.sh's own census (its FLEET total=n/cap line), never a
# second count. capacity=UNDERFILLED:<slack> fires when live < cap AND no leg has
# launched for TICK_UNDERFILL_MIN (default 10) minutes, judged by the newest
# <name>.launch.log mtime under the console work dir.
launch_log="$W/console-work/chain/HIMMEL-9-N1-x.launch.log"
: > "$launch_log"; touch -d '2 hours ago' "$launch_log"
old_out="$(bash "$SUT")"
contains 'fleet=<live>/<cap> comes from the bank-preflight census (HIMMEL-3167)' "$old_out" 'fleet=1/8'
contains 'live < cap and an old last dispatch is UNDERFILLED:<slack> (HIMMEL-3167)' "$old_out" 'capacity=UNDERFILLED:7'
: > "$launch_log"
fresh_out="$(bash "$SUT")"
contains 'a fresh dispatch reads capacity=ok (HIMMEL-3167 control)' "$fresh_out" 'fleet=1/8 capacity=ok'
touch -d '2 hours ago' "$launch_log"
tuned_out="$(TICK_UNDERFILL_MIN=180 bash "$SUT")"
contains 'TICK_UNDERFILL_MIN moves the threshold (HIMMEL-3167)' "$tuned_out" 'capacity=ok'
bad_min_out="$(TICK_UNDERFILL_MIN=abc bash "$SUT")"
contains 'a non-numeric TICK_UNDERFILL_MIN falls back to 10 (HIMMEL-3167)' "$bad_min_out" 'capacity=UNDERFILLED:7'
full_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=8 claudex=0 reserved=0 total=8/8' bash "$SUT")"
contains 'live == cap is never underfilled (HIMMEL-3167)' "$full_out" 'fleet=8/8 capacity=ok'
res_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=6 claudex=1 reserved=1 total=8/8' bash "$SUT")"
contains 'native+claudex+reserved arrive as bank-preflight total (HIMMEL-3167)' "$res_out" 'fleet=8/8'
cap4_out="$(STUB_FLEET_LINE='bank-preflight: FLEET native=1 claudex=0 reserved=0 total=1/4' bash "$SUT")"
contains 'the cap is bank-preflight cap, not a tick constant (HIMMEL-3167)' "$cap4_out" 'fleet=1/4 capacity=UNDERFILLED:3'
fail_out="$(STUB_FLEET_LINE='bank-preflight: FLEET ?/8' bash "$SUT")"
contains 'a failed fleet census reports fleet=? (HIMMEL-3167)' "$fail_out" 'fleet=? capacity=unknown'
case "$fail_out" in
    *'capacity=ok'*|*UNDERFILLED*) fail 'a failed fleet census must not claim ok/UNDERFILLED (HIMMEL-3167)' ;;
    *) pass 'a failed fleet census must not claim ok/UNDERFILLED (HIMMEL-3167)' ;;
esac
mv "$W/repo/scripts/lib/bank-preflight.sh" "$W/bank-preflight.sh.away"
gone_out="$(bash "$SUT")"
contains 'a missing bank-preflight.sh reports fleet=? (HIMMEL-3167)' "$gone_out" 'fleet=? capacity=unknown'
mv "$W/bank-preflight.sh.away" "$W/repo/scripts/lib/bank-preflight.sh"
STUB_PF_SEEN="$W/pf-seen" bash "$SUT" >/dev/null
contains 'tick asks bank-preflight for no ledger row and no launch refusal (HIMMEL-3167)' "$(cat "$W/pf-seen" 2>/dev/null)" 'ledger=/dev/null launch=unset'
rm -f "$launch_log"
none_out="$(bash "$SUT")"
contains 'no launch log at all counts as no recent dispatch (HIMMEL-3167)' "$none_out" 'capacity=UNDERFILLED:7'
mkdir -p "$W/xdg/himmel-console/chain"
: > "$W/xdg/himmel-console/chain/HIMMEL-9-N1-x.launch.log"
xdg_out="$(env -u TICK_LAUNCH_DIR XDG_RUNTIME_DIR="$W/xdg" bash "$SUT")"
contains 'the default launch dir is XDG_RUNTIME_DIR/himmel-console (HIMMEL-3167)' "$xdg_out" 'capacity=ok'
verbose_cap="$(bash "$SUT" --verbose)"
contains '--verbose labels fleet (HIMMEL-3167)' "$verbose_cap" 'fleet: 1/8'
contains '--verbose labels capacity (HIMMEL-3167)' "$verbose_cap" 'capacity: UNDERFILLED:7'
burn_cap="$(bash "$SUT" --burn --legs 'HIMMEL-111-legN61')"
case "$burn_cap" in
    *' burn=N61:'*' fleet=1/8 capacity=UNDERFILLED:7 gql='*) pass 'fleet=/capacity= append after every existing field incl. burn= (HIMMEL-3167)' ;;
    *) fail "fleet=/capacity= not appended last under --burn (out='$burn_cap')" ;;
esac

# --- HIMMEL-3167 (3): procs=0 for a live headed leg. headed-arm-leg.sh names the
# session <TICKET>-N<k>-<slug> with NO date, while the leg DOC is
# <TICKET>-N<k>-<slug>-<YYYY-MM-DD>[-RESUME].md; the census filter matched the
# doc stem verbatim, so a live leg read procs=0 (reproduced on N41 itself).
mkcmdline 108 claude --settings /run/user/1000/himmel-console/x/HIMMEL-555-N41-thing.leg-settings.json \
    --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-555-N41-thing work
mk_pgrep_x "$W/bin-dated" 108
dated_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --legs 'HIMMEL-555-N41-thing-2026-09-18')"
contains 'a date-suffixed leg doc still counts its live session in procs= (HIMMEL-3167)' "$dated_out" 'procs=1'
contains 'a date-suffixed leg doc still buckets its model (HIMMEL-3167)' "$dated_out" 'models=sonnet:1'
dated_resume_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --legs 'HIMMEL-555-N41-thing-2026-09-18-RESUME')"
contains 'a date-suffixed -RESUME doc still counts its live session (HIMMEL-3167)' "$dated_resume_out" 'procs=1'
dated_burn_out="$(PATH="$W/bin-dated:$PATH" bash "$SUT" --burn --legs 'HIMMEL-555-N41-thing-2026-09-18')"
contains 'a date-suffixed leg doc still resolves its --burn transcript (HIMMEL-3167)' "$dated_burn_out" 'burn=N41:60.0k/90.0k'

# --- HIMMEL-3197: gql=<remaining>/<reset HH:MM> ----------------------------------
# The GitHub GraphQL budget is shared fleet-wide; a console needs to see exhaustion
# coming. Read by gh-graphql-budget.sh's ghb_read -- ONE real `gh api -i graphql`
# call (never `gh api rate_limit`, which reports the REST core bucket) -- and
# appended after capacity=, so every existing field keeps its position.
: > "$W/gh-api.log"
STUB_GH_API_LOG="$W/gh-api.log" bash "$SUT" >/dev/null
api_calls="$(wc -l < "$W/gh-api.log" | tr -d '[:space:]')"
if [ "$api_calls" = 1 ]; then
    pass 'a tick costs exactly one gh api call for gql= (HIMMEL-3197)'
else
    fail "gql= must cost exactly one gh api call per tick (calls=$api_calls)"
fi
contains 'the gql= probe is a real graphql call, not rate_limit (HIMMEL-3197)' "$(cat "$W/gh-api.log")" 'graphql'
gql_ex_out="$(STUB_GQL_OUT='HTTP/2.0 403 Forbidden\r\nX-Ratelimit-Remaining: 0\r\nX-Ratelimit-Reset: 1790000000\r\n\r\n' STUB_GQL_RC=1 bash "$SUT")"; gql_ex_rc=$?
if [ "$gql_ex_rc" -eq 0 ]; then
    contains 'an exhausted budget (gh exits 1, headers still printed) reads gql=0/<reset> (HIMMEL-3197)' "$gql_ex_out" "gql=0/$gql_hm"
else
    fail "an exhausted budget must not fail the tick (rc=$gql_ex_rc)"
fi
gql_bad_out="$(STUB_GQL_OUT='gh: connection refused\n' STUB_GQL_RC=1 bash "$SUT")"; gql_bad_rc=$?
if [ "$gql_bad_rc" -eq 0 ]; then
    contains 'unreadable headers read gql=? and never fail the tick (HIMMEL-3197)' "$gql_bad_out" ' capacity=UNDERFILLED:7 gql=?'
else
    fail "unreadable gql headers must not fail the tick (rc=$gql_bad_rc)"
fi
gql_nores_out="$(STUB_GQL_OUT='HTTP/2.0 200 OK\r\nX-Ratelimit-Remaining: 4321\r\n\r\n' bash "$SUT")"
contains 'a missing reset header reads gql=<remaining>/? (HIMMEL-3197)' "$gql_nores_out" 'gql=4321/?'
gql_verbose="$(bash "$SUT" --verbose)"
contains '--verbose labels the graphql budget (HIMMEL-3197)' "$gql_verbose" "gql: 4321/$gql_hm"
gql_burn="$(bash "$SUT" --burn --legs 'HIMMEL-111-legN61')"
case "$gql_burn" in
    *' burn=N61:'*" capacity=UNDERFILLED:7 gql=4321/$gql_hm orphans=none nonces="*) pass 'gql= keeps its slot under --burn, orphans= trails it, nonces= closes the line (HIMMEL-3197, HIMMEL-2761, HIMMEL-3254)' ;;
    *) fail "gql=/orphans= order under --burn (out='$gql_burn')" ;;
esac

# --- HIMMEL-2761: orphans=<owner>:<count>/<oldest>m ---------------------------
# A wrapper shell older than the floor under a live session is surfaced at the
# next tick, joined to that session's name (orphan-loops.sh; its own suite pins
# the walk/threshold rules). Appended last, after gql=, so no field moves.
cat > "$W/ps-orphan.txt" <<'FIX'
    1     0 40-00:00:01 /sbin/init
  101     1    05:00:00 claude --model claude-sonnet-5 -n HIMMEL-111-legN61 work
  201   101    02:10:05 /usr/bin/zsh -c source /home/u/.claude/shell-snapshots/snapshot-zsh-1-a.sh 2>/dev/null || true && eval 'until false; do sleep 10; done'
FIX
orph_out="$(PS_FIXTURE="$W/ps-orphan.txt" bash "$SUT")"; orph_rc=$?
if [ "$orph_rc" -eq 0 ]; then
    contains 'a stale wrapper under a live session surfaces as orphans=<name>:<n>/<m>m, last on the line (HIMMEL-2761)' "$orph_out" " gql=4321/$gql_hm orphans=HIMMEL-111-legN61:1/130m"
else
    fail "an orphan inventory must not fail the tick (rc=$orph_rc)"
fi
contains '--verbose labels the orphan inventory (HIMMEL-2761)' "$(PS_FIXTURE="$W/ps-orphan.txt" bash "$SUT" --verbose)" 'orphans: HIMMEL-111-legN61:1/130m'
: > "$W/ps-empty.txt"
contains 'an unreadable process table reads orphans=? and never fails the tick (HIMMEL-2761)' "$(PS_FIXTURE="$W/ps-empty.txt" bash "$SUT")" ' orphans=?'

# --- HIMMEL-3277: one leg identity, used by every tick consumer ---------------
# Names here are the ones the harness really produces, not ones invented to fit
# the parser. Doc = docs/handover/leg-brief-template.md's stated pattern; session
# = the <TICKET>-N<k>-<slug> the console passes headed-arm-leg.sh (this shift's
# own pair: HIMMEL-3269-N191-scorecard-discovery, HIMMEL-3273-N192-stop-queue-race).
# RED control (pre-fix tick.sh, this fixture): the old-template doc read
# legs=<full stem>:FRESH, procs=0 and livestate=DRIFT with two live, held legs.
l191='HIMMEL-3269-N191-scorecard-discovery-2026-09-20-RESUME'
l192='HIMMEL-3273-stop-queue-race-leg192-2026-09-20-RESUME'
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/$l191.md"
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/$l192.md"
mkcmdline 120 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3269-N191-scorecard-discovery work
mkcmdline 121 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3273-N192-stop-queue-race work
mk_pgrep_x "$W/bin-3277" 120 121
t3277() { PATH="$W/bin-3277:$PATH" bash "$SUT" --legs "$1"; }

# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
o3277="$(t3277 "$l191 $l192")"
contains 'a template-pattern doc and a canonical doc both resolve to N<k> (HIMMEL-3277)' "$o3277" 'legs=N191:FRESH,N192:FRESH'
contains 'both live legs are counted in procs= (HIMMEL-3277)' "$o3277" 'procs=2'
contains 'both live legs are bucketed in models= (HIMMEL-3277)' "$o3277" 'models=sonnet:2'
contains 'a legs: line written per console-template.md reports no drift (HIMMEL-3277)' "$o3277" 'livestate=ok'
case "$o3277" in
    *DRIFT*|*'procs=0'*) fail 'the shift-N pair must read neither DRIFT nor procs=0 (HIMMEL-3277)' ;;
    *) pass 'the shift-N pair must read neither DRIFT nor procs=0 (HIMMEL-3277)' ;;
esac
contains 'each doc counts only its own session (HIMMEL-3277)' "$(t3277 "$l192")" 'procs=1'

# The console's disproved workaround: hyphenated full-stem labels plus a trailing
# parenthetical of its own backticked tokens. The parser's label class used to
# stop at the first hyphen, so no such span ever parsed and DRIFT named the stems.
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/HIMMEL-9-odd-name-2026-09-20-RESUME.md"
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `HIMMEL-9-odd-name-2026-09-20-RESUME:n:t:1` (odd doc, see `HIMMEL-9-odd-name`)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a hyphenated label span parses, trailing backticked prose and all (HIMMEL-3277)' "$(t3277 'HIMMEL-9-odd-name-2026-09-20-RESUME')" 'livestate=ok'

# A genuinely stale Live state still fires: N199 is named but holds no lock, N192
# is held but unnamed. The fix must not make the check unable to fire.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a genuinely stale Live state still reports DRIFT (HIMMEL-3277)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192,N199'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `HIMMEL-9-odd-name-2026-09-20-RESUME:n:t:1`, `HIMMEL-8-gone-2026-09-20-RESUME:n:t:2`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a stale hyphenated label is still DRIFT, not silently dropped (HIMMEL-3277)' "$(t3277 'HIMMEL-9-odd-name-2026-09-20-RESUME')" 'livestate=DRIFT:HIMMEL-8-gone-2026-09-20-RESUME'

# --- HIMMEL-3280: the legs: line is read for ENTRIES, not for every backtick span.
# The console's own explanatory parenthetical named the token `legs:` in
# backticks; the span pattern only asked for "label chars, a colon, anything",
# so it matched and read as a phantom leg named "legs" (RED control, pre-fix
# tick.sh, first fixture below: livestate=DRIFT:legs on two real, held legs).
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (each entry is `<leg>:<nonce>:<lock-token>:<pid>`; the `legs:` key, see `HIMMEL-9`, and `see: this` are prose)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
o3280="$(t3277 "$l191 $l192")"
contains 'a backticked non-entry token on the legs: line is not a phantom leg (HIMMEL-3280)' "$o3280" 'livestate=ok'
case "$o3280" in
    *DRIFT*|*MALFORMED*) fail "prose tokens on the legs: line must read neither DRIFT nor MALFORMED (HIMMEL-3280) ($o3280)" ;;
    *) pass 'prose tokens on the legs: line must read neither DRIFT nor MALFORMED (HIMMEL-3280)' ;;
esac

# Consoles quote tick fields and leg names in notes on this line all the time:
# a colon-then-text span whose first field is NOT a leg label (`procs:2`,
# `livestate=DRIFT:N192`, `bank:5h30`) is prose, and so is a bare `N191`
# mention with no colon. Pre-fix, `procs:2` read as a phantom leg "procs".
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (last tick `procs:2`, `bank:5h30`, was `livestate=DRIFT:N192`; `N191` reported LIVE)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
q3280="$(t3277 "$l191 $l192")"
contains 'quoted tick fields on the legs: line are prose, not entries (HIMMEL-3280)' "$q3280" 'livestate=ok'
case "$q3280" in
    *DRIFT*|*MALFORMED*) fail "a non-label colon span must read neither DRIFT nor MALFORMED (HIMMEL-3280) ($q3280)" ;;
    *) pass 'a non-label colon span must read neither DRIFT nor MALFORMED (HIMMEL-3280)' ;;
esac

# A genuinely stale Live state still fires with the same prose on the line, and
# the drift names the stale legs only -- no `legs` phantom among them.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N199:J-N199-aaaaaa:tok-199:1` (the `legs:` key)' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a stale Live state with prose on the line is DRIFT naming only real legs (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192,N199 '

# A malformed-but-entry-shaped span must be REPORTED, never dropped: dropping it
# trades a phantom for a disappearance (HIMMEL-3277's failure facing the other
# way). Reported by label only -- the span carries a nonce and a lock token.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191`, `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
m3280="$(t3277 "$l191 $l192")"
contains 'a 3-field span reads MALFORMED naming its leg (HIMMEL-3280)' "$m3280" 'livestate=MALFORMED:N191 '
case "$m3280" in
    *'livestate=ok'*|*DRIFT*) fail "a malformed span must read neither ok nor DRIFT (HIMMEL-3280) ($m3280)" ;;
    *) pass 'a malformed span must read neither ok nor DRIFT (HIMMEL-3280)' ;;
esac
case "$m3280" in
    *J-N191-0a1b2c*|*tok-191*) fail 'MALFORMED must not print the span, which carries a nonce and lock token (HIMMEL-3280)' ;;
    *) pass 'MALFORMED must not print the span, which carries a nonce and lock token (HIMMEL-3280)' ;;
esac
# Every other wrong arity / empty field is the same signal.
for bad in 'N191:' 'N191:J-N191-0a1b2c' 'N191:J-N191-0a1b2c:tok-191:120:extra' 'N191::tok-191:120' 'N191:J-N191-0a1b2c::120' 'N191:J-N191-0a1b2c:tok-191:'; do
    printf '%s\n' '# console' '' '## Live state' '' \
        "legs: \`$bad\`, \`N192:J-N192-3d4e5f:tok-192:121\`" 'queue: none' 'last GO: none' 'acked: none' \
        > "$W/handover/console.md"
    contains "malformed span '$bad' reads MALFORMED, not ok (HIMMEL-3280)" "$(t3277 "$l191 $l192")" 'livestate=MALFORMED:N191 '
done
# Malformed AND stale both surface; the malformed leg is named, so it is not
# double-reported as a held-but-unnamed DRIFT.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191`, `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a malformed span and a stale leg both surface (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=MALFORMED:N191;DRIFT:N192,N199 '

# procs=/models= guard: a HELD leg that matches no census row cannot be told
# apart from a filter that cannot match, so it must read unknown, never 0/none.
mk_pgrep_x "$W/bin-3277-none" 103
g3277="$(PATH="$W/bin-3277-none:$PATH" bash "$SUT" --legs "$l191 $l192")"
contains 'held legs matching no census row read procs=unknown (HIMMEL-3277)' "$g3277" 'procs=unknown'
contains 'held legs matching no census row read models=unknown (HIMMEL-3277)' "$g3277" 'models=unknown'
case "$g3277" in
    *'procs=0'*|*'models=none'*) fail 'a matched-nothing filter must not render procs=0 / models=none (HIMMEL-3277)' ;;
    *) pass 'a matched-nothing filter must not render procs=0 / models=none (HIMMEL-3277)' ;;
esac
# Population-level, not per-leg (console ruling): when SOME held legs match, the
# derivation demonstrably works, so the ones that do not are genuinely not
# running -- count the live ones and NAME the unmatched. One dead leg must never
# blank the field for the live ones.
mk_pgrep_x "$W/bin-3277-half" 120
half3277="$(PATH="$W/bin-3277-half:$PATH" bash "$SUT" --legs "$l191 $l192")"
contains 'one live + one dead held leg reads a count plus the named unmatched leg (HIMMEL-3277)' "$half3277" 'procs=1,unmatched=N192 '
contains 'one live + one dead held leg still buckets the live model (HIMMEL-3277)' "$half3277" 'models=sonnet:1 '
# The legacy -legN<k>- spelling, with a slug that itself contains "-leg-" (N194's own doc).
l194='HIMMEL-3277-tick-leg-identity-legN194-2026-09-20-RESUME'
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/$l194.md"
mkcmdline 123 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3277-N194-tick-leg-identity work
mk_pgrep_x "$W/bin-3277-194" 123
o194="$(PATH="$W/bin-3277-194:$PATH" bash "$SUT" --legs "$l194")"
contains 'a -legN<k>- doc with -leg- in its slug resolves to N<k> and its session is counted (HIMMEL-3277)' "$o194" 'legs=N194:FRESH'
contains 'a -legN<k>- doc is counted in procs= against the <TICKET>-N<k>-<slug> session (HIMMEL-3277)' "$o194" 'procs=1 '
# A leg whose session is live under a name no derivation yields is the same case.
mkcmdline 122 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3269-worker-of-scorecard work
mk_pgrep_x "$W/bin-3277-odd" 122
contains 'a live session under an underivable name reads procs=unknown (HIMMEL-3277)' "$(PATH="$W/bin-3277-odd:$PATH" bash "$SUT" --legs "$l191")" 'procs=unknown'
# ...but a leg that is NOT held (wrapped) expects no process: 0 is a real count.
contains 'a wrapped (FREE) leg with no session is a real procs=0 (HIMMEL-3277)' "$(PATH="$W/bin-3277-none:$PATH" bash "$SUT" --legs 'HIMMEL-7-N77-wrapped-2026-09-20-RESUME' 2>/dev/null)" 'procs=0'

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick.sh'
    exit 0
fi
printf 'FAIL - test-tick.sh (%s failure(s))\n' "$fails"
exit 1
