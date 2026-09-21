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
    case "$2" in *N61*|*-N1-*|*-N2-*|*-N191-*|*-leg192-*|*-legN194-*|*odd-name*|*-N301-*|*-N302-*|*-N303-*) printf '%s\n' 'status: FRESH'; exit 11 ;; *) printf '%s\n' free; exit 0 ;; esac ;;
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
expected='TICK 12:34 hb=ok legs=N61:FRESH,N65:FREE livestate=skip procs=1,unwatched=N9 models=sonnet:1 ceiling=ok atq=2 suites=1alive/0dead prs=#2247,#2250 bank=5h30/wk28/codex=5h12/wk34 fill=28 tails=N61:LIVE,N65:READY inbox=N61:10/4,N65:8/8 tick=UNKNOWN fleet=1/8 capacity=UNDERFILLED:7 gql=4321/'"$gql_hm"' orphans=none nonces=skip legset=skip board=skip'
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

# A genuinely stale Live state still fires: N192 is held but unnamed (DRIFT). N199
# is named but the arm does not cover it, so it reads legset=unarmed (HIMMEL-3293),
# not DRIFT -- the tick has no lock for it. The fix must not make the check unable to fire.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'a genuinely stale Live state still reports DRIFT (HIMMEL-3277)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192 '
contains 'a Live-state leg the arm omits reads legset=unarmed, not DRIFT (HIMMEL-3293)' "$(t3277 "$l191 $l192")" 'legset=STALE:unarmed=N199'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `HIMMEL-9-odd-name-2026-09-20-RESUME:n:t:1`, `HIMMEL-8-gone-2026-09-20-RESUME:n:t:2`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
# The stale leg is ARMED here (HIMMEL-3293: an unarmed one is legset=, not DRIFT): a
# doc with no lock, so its lock is gone while Live state still names it.
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/HIMMEL-8-gone-2026-09-20-RESUME.md"
contains 'a stale hyphenated label is still DRIFT, not silently dropped (HIMMEL-3277)' "$(t3277 'HIMMEL-9-odd-name-2026-09-20-RESUME HIMMEL-8-gone-2026-09-20-RESUME')" 'livestate=DRIFT:HIMMEL-8-gone-2026-09-20-RESUME'

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
contains 'a stale Live state with prose on the line is DRIFT naming only real legs (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=DRIFT:N192 '
contains 'the unarmed leg is named, with no phantom leg beside it (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'legset=STALE:unarmed=N199'

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
contains 'a malformed span and a stale leg both surface (HIMMEL-3280)' "$(t3277 "$l191 $l192")" 'livestate=MALFORMED:N191;DRIFT:N192 '

# --- HIMMEL-3281: the legs: BLOCK is read, not just its first line ------------
# The block is the legs: line(s) plus lines wrapped directly under them, up to
# the first blank line or the next `field:` line. RED control (pre-fix tick.sh,
# first fixture below): both legs' locks held (legs=N191:FRESH,N192:FRESH, same
# output line) and livestate=DRIFT:N192 -- the second line was never parsed.
# The precondition is asserted on every fixture: a "DRIFT" from a lock that was
# never held would be a vacuous control.
wrap_case() {  # wrap_case <desc> <expected livestate=...> <console doc line>...
    local desc="$1" want="$2" out
    shift 2
    printf '%s\n' '# console' '' '## Live state' '' "$@" > "$W/handover/console.md"
    out="$(t3277 "$l191 $l192")"
    contains "$desc: both locks are held (precondition)" "$out" 'legs=N191:FRESH,N192:FRESH'
    contains "$desc (HIMMEL-3281)" "$out" "$want"
}
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a second legs: line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    'legs: `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'an indented continuation line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'an unindented continuation line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`,' \
    '`N192:J-N192-3d4e5f:tok-192:121` (wrapped by hand)' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a wrapped block ended by a blank line is read' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192:121`' '' 'queue: none' 'last GO: none' 'acked: none'
# A wrapped span is judged like any other: malformed reads MALFORMED (by label),
# a leg named but not held reads DRIFT.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a malformed span on a continuation line reads MALFORMED' 'livestate=MALFORMED:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    '  `N192:J-N192-3d4e5f:tok-192`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a leg on a continuation line the arm omits reads legset=unarmed' 'legset=STALE:unarmed=N199' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' \
    '  `N199:J-N199-aaaaaa:tok-199:1`' 'queue: none' 'last GO: none' 'acked: none'
# The block has an END, and that end reads loudly, not silently: a held leg whose
# span sits past the blank line (a per-leg detail bullet) or on another field's
# line is not named BY the block, so it is DRIFT -- the console's own record was
# never in the legs block.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a span after the blank line is not an entry (detail bullets may quote one)' 'livestate=DRIFT:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' '' \
    '- N192 detail: `N192:J-N192-3d4e5f:tok-192:121`' 'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a span on the next field: line is not an entry' 'livestate=DRIFT:N192 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
    'queue: HIMMEL-1 (`N192:J-N192-3d4e5f:tok-192:121`)' 'last GO: none' 'acked: none'
# A bullet written IMMEDIATELY under the legs: line (no blank between) ends the
# block at the list marker, so its backtick spans never reach the classifier.
# Realistic detail-bullet spans -- a file:line cite, a worktree path, a bare sha,
# a tick.sh:line cite -- must not become entries or MALFORMED labels. This pins
# the block terminator, not the classifier (the same cite on the legs: line
# itself is pinned in the HIMMEL-3284 cases below).
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'prose bullets directly under legs: (no blank line) are not entries or MALFORMED' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`' \
    '- **N192** BLOCKED — see `stuck-playbook.md:408`, `tick.sh:234`, worktree `.claude/worktrees/fix+himmel-3273-stop-queue-race`, head `798a4bda26487e04140d0b7aee715be51c7e7247`' \
    'queue: none' 'last GO: none' 'acked: none'
# --- HIMMEL-3284: a `<name>.md:<line>` cite ON the legs: line is prose. RED
# control (pre-fix tick.sh, first fixture below): both locks held
# (legs=N191:FRESH,N192:FRESH, asserted by wrap_case) and
# livestate=MALFORMED:stuck-playbook.md -- leg_label reduces the doc stem
# `stuck-playbook.md` to `stuck-playbook`, so the cite read as a label-shaped
# first field with a colon, an invented leg. The four shapes N199 pinned; only
# the .md cite leaked.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a .md:line cite on the legs: line is prose, not a malformed leg' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `stuck-playbook.md:408`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a .sh:line cite on the legs: line is prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `tick.sh:234`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a worktree path and a bare sha on the legs: line are prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (worktree `.claude/worktrees/fix+himmel-3273-stop-queue-race`, head `798a4bda26487e04140d0b7aee715be51c7e7247`)' \
    'queue: none' 'last GO: none' 'acked: none'
# A leg doc cited by its file name is the same shape (a stem that reduces to N<k>).
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a leg-doc .md:line cite on the legs: line is prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (see `HIMMEL-3273-N192-stop-queue-race-2026-09-20-RESUME.md:12`)' \
    'queue: none' 'last GO: none' 'acked: none'
# All four cite shapes together, one line -- a console's real explanatory note.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'all four cite shapes together on the legs: line are prose' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (`stuck-playbook.md:408`, `tick.sh:234`, `.claude/worktrees/fix+himmel-3273-stop-queue-race`, `798a4bda26487e04140d0b7aee715be51c7e7247`)' \
    'queue: none' 'last GO: none' 'acked: none'
# NEGATIVE CONTROL, and the point of the ticket: the real signal survives. A
# truncated entry (three fields) under a real leg label still reads MALFORMED by
# label -- with the cites on the same line, and without them. Quieting the false
# positive by quieting the label test would read this `ok` (a leg that vanishes).
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a truncated entry under a real label still reads MALFORMED beside a .md cite' 'livestate=MALFORMED:N199 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N199:O-N199-9a03e6f1:120` (see `stuck-playbook.md:408`)' \
    'queue: none' 'last GO: none' 'acked: none'
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a truncated entry under a real label reads MALFORMED with no cite on the line' 'livestate=MALFORMED:N199 ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N199:O-N199-9a03e6f1:120`' \
    'queue: none' 'last GO: none' 'acked: none'
# Every leg-label spelling that reads MALFORMED today still does, .md in the line or not.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a truncated entry under a lettered successor label still reads MALFORMED' 'livestate=MALFORMED:N38b ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121`, `N38b:O-N38b-9a03e6f1:120` (see `console-template.md:105`)' \
    'queue: none' 'last GO: none' 'acked: none'
# Every list-marker spelling ends the block: a leg span in the bullet is not an
# entry, so the held leg it names reads DRIFT (loud), never absent-and-quiet.
for marker in '- ' '* ' '+ ' '1. ' '  - ' '> ' '# '; do
    # shellcheck disable=SC2016  # backtick leg spans, literal fixture text
    wrap_case "a '$marker' line ends the block" 'livestate=DRIFT:N192 ' \
        'legs: `N191:J-N191-0a1b2c:tok-191:120`' \
        "${marker}N192 detail: \`N192:J-N192-3d4e5f:tok-192:121\`" 'queue: none' 'last GO: none' 'acked: none'
done
# One-line behaviour is untouched: prose, MALFORMED and DRIFT read as HIMMEL-3280 left them.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
wrap_case 'a one-line block with prose still reads ok' 'livestate=ok ' \
    'legs: `N191:J-N191-0a1b2c:tok-191:120`, `N192:J-N192-3d4e5f:tok-192:121` (the `legs:` key)' 'queue: none' 'last GO: none' 'acked: none'

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

# --- HIMMEL-3287: the console template's own legs: placeholder must not parse.
# The doc under test is the REAL docs/handover/console-template.md, not a fixture
# copy of its line: the template shipped `legs: <none dispatched yet, or
# `N1:<nonce>:<lock-token>:<pid>`, `N2:…`>`, whose two backtick spans are exactly
# the entry shape HIMMEL-3280/3281/3284 taught the parser to read. RED control
# (pre-fix template, this fixture, a console that has dispatched nothing):
#   livestate=MALFORMED:N2;DRIFT:N1
tpl3287="$HERE/../../../docs/handover/console-template.md"
awk '/^## Live state$/ { keep = 1 } /^## Compact instructions$/ { keep = 0 } keep' "$tpl3287" > "$W/handover/console.md"
contains 'the template Live state section was extracted (HIMMEL-3287 precondition)' "$(cat "$W/handover/console.md")" 'legs: '
o3287="$(bash "$SUT" --legs '')"
contains 'the console template'"'"'s own legs: placeholder reads livestate=ok on a console with no legs (HIMMEL-3287)' "$o3287" 'livestate=ok '
case "$o3287" in
    *MALFORMED*|*DRIFT*) fail "the template placeholder must read neither MALFORMED nor DRIFT (HIMMEL-3287) ($o3287)" ;;
    *) pass 'the template placeholder must read neither MALFORMED nor DRIFT (HIMMEL-3287)' ;;
esac
# The template's other three defects, pinned against its own text. (b) the
# Monitor tool caps timeout_ms at 1800000 (30 min) and silently clamps; (c) a
# bare --legs name resolves against the handover ROOT and reads NOTFOUND; (d)
# an unquoted --model {{MODEL}} is a zsh glob (claude-opus-5[1m]).
tick3287="$(grep -F '| tick |' "$tpl3287")"
step3287="$(awk '/^10\. \*\*Arm the `tick` monitor now/ { keep = 1 } /^## Live state$/ { keep = 0 } keep' "$tpl3287")"
contains 'the tick row states the 30 min Monitor cap (HIMMEL-3287)' "$tick3287" '| tick | 30 min |'
contains 'the tick row names the 1800000 ms cap and the silent clamp (HIMMEL-3287)' "$tick3287" 'silently clamps anything larger'
contains 'the tick row says to re-arm on each expiry notice (HIMMEL-3287)' "$tick3287" 're-arms on each expiry notice'
contains 'ACTION ZERO step 10 states the same 30 min cap (HIMMEL-3287)' "$step3287" 'silently clamps anything larger'
case "$tick3287$step3287" in
    *'60 min'*) fail 'neither the tick row nor step 10 may still say 60 min (HIMMEL-3287)' ;;
    *) pass 'neither the tick row nor step 10 may still say 60 min (HIMMEL-3287)' ;;
esac
contains 'the --legs example uses absolute paths (HIMMEL-3287)' "$tick3287" '--legs "{{STATE_DIR}}/<leg1>.md {{STATE_DIR}}/<leg2>.md"'
contains 'the row says why bare leg doc names fail (HIMMEL-3287)' "$tick3287" 'resolves against the handover ROOT'
# A leg doc lives in the console's bucket, one level under the handover root:
# the absolute path resolves, the bare name the template used to show does not.
mkdir -p "$W/handover/bucket3287"
l3287='HIMMEL-3287-N287-bucketed-2026-09-20-RESUME.md'
printf '%s\n' '# leg' '- LIVE — working' > "$W/handover/bucket3287/$l3287"
contains 'an absolute --legs path to a bucketed leg doc resolves, not NOTFOUND (HIMMEL-3287)' "$(bash "$SUT" --legs "$W/handover/bucket3287/$l3287")" 'legs=N287:FREE'
contains 'a bare --legs name of a bucketed leg doc reads NOTFOUND (HIMMEL-3287)' "$(bash "$SUT" --legs "$l3287" 2>/dev/null)" 'legs=N287:NOTFOUND'
next3287="$(grep -F '/console next --arm' "$tpl3287")"
contains "the /console next line quotes --model (HIMMEL-3287)" "$next3287" "--model '{{MODEL}}'"
case "$next3287" in
    *'--model {{MODEL}}'*) fail 'the /console next line must not carry an unquoted --model {{MODEL}} (HIMMEL-3287)' ;;
    *) pass 'the /console next line must not carry an unquoted --model {{MODEL}} (HIMMEL-3287)' ;;
esac

# --- HIMMEL-3293: one leg set -- a stale --legs arm is an INPUT problem, never
# leg drift. The ticket's own fixture: a Live state naming THREE legs, a --legs
# naming TWO, one of them wrapped. N301 is held and armed; N302 and N303 are held
# and live but were dispatched after the arm (not in --legs); N300 is wrapped (its
# lock released, its last bullet WRAPPED) and is armed but already gone from Live
# state. RED control (pre-fix tick.sh, this fixture) read:
#   legs=N300:FREE,N301:FRESH livestate=DRIFT:N302,N303 procs=1 models=sonnet:1
# -- a false DRIFT on two healthy legs, procs=1 beside three live legs, N302/N303
# absent from legs=, and the wrapped leg indistinguishable from a lost lock.
w3293="HIMMEL-3300-N300-wrapped-2026-09-20-RESUME"
a3293="HIMMEL-3301-N301-alpha-2026-09-20-RESUME"
printf '%s\n' '# leg' '- 12:00 LIVE — working' '- 12:30 WRAPPED — released' > "$W/handover/$w3293.md"
printf '%s\n' '# leg' '- 12:00 LIVE — working' > "$W/handover/$a3293.md"
mkcmdline 130 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3301-N301-alpha work
mkcmdline 131 claude --model claude-opus-5 --autocompact 200000 -n HIMMEL-3302-N302-beta work
mkcmdline 132 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3303-N303-gamma work
mkcmdline 133 claude --model claude-opus-5 -n HIMMEL-nextleg-2026-09-20R-console work
mk_pgrep_x "$W/bin-3293" 130 131 132 133
t3293() { PATH="$W/bin-3293:$PATH" bash "$SUT" --legs "$1"; }
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`, `N302:J-N302-3d4e5f:tok-302:131`, `N303:J-N303-6a7b8c:tok-303:132`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
o3293="$(t3293 "$W/handover/$w3293.md $W/handover/$a3293.md")"
contains 'a leg dispatched after the arm is not livestate=DRIFT (HIMMEL-3293)' "$o3293" 'livestate=ok '
case "$o3293" in
    *DRIFT*) fail "a stale arm must not read as leg DRIFT (HIMMEL-3293) ($o3293)" ;;
    *) pass 'a stale arm must not read as leg DRIFT (HIMMEL-3293)' ;;
esac
contains 'the disagreement is reported as an input problem, both directions (HIMMEL-3293)' "$o3293" 'legset=STALE:unarmed=N302+N303;unlisted=N300'
contains 'live legs outside the arm are surfaced in procs=, not dropped (HIMMEL-3293)' "$o3293" 'procs=1,unwatched=N302+N303 '
contains 'a wrapped leg reads WRAPPED, distinct from a lost lock (HIMMEL-3293)' "$o3293" 'legs=N300:WRAPPED,N301:FRESH '
p3293="$(printf '%s\n' "$o3293" | sed -E 's/.* procs=([^ ]*) .*/\1/')"
case "$p3293" in
    *N301*|*N300*|*nextleg*|*console*) fail "the armed leg and the console must not read unwatched (HIMMEL-3293) ($p3293)" ;;
    *) pass 'the armed leg and the console session are not unwatched (HIMMEL-3293)' ;;
esac
# The check must still fire on real drift: an ARMED leg whose lock is gone but
# that Live state still names (N300, wrapped), and a HELD leg Live state omits.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N300:J-N300-aaaaaa:tok-300:1`, `N302:J-N302-3d4e5f:tok-302:131`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
d3293="$(t3293 "$W/handover/$w3293.md $W/handover/$a3293.md")"
contains 'an armed wrapped leg Live state still names is DRIFT (HIMMEL-3293)' "$d3293" 'livestate=DRIFT:N300,N301 '
contains 'a Live-state leg outside the arm is unarmed, not drift, beside real drift (HIMMEL-3293)' "$d3293" 'legset=STALE:unarmed=N302'
# A tick armed with no --legs at all (the Monitors row's own example) can see no
# lock: every Live-state leg is unarmed, none is drift, and every live leg surfaces.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`, `N302:J-N302-3d4e5f:tok-302:131`, `N303:J-N303-6a7b8c:tok-303:132`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
n3293="$(PATH="$W/bin-3293:$PATH" bash "$SUT" --legs '')"
contains 'no --legs: every Live-state leg is unarmed, none is DRIFT (HIMMEL-3293)' "$n3293" 'livestate=ok '
contains 'no --legs: legset names all three as unarmed (HIMMEL-3293)' "$n3293" 'legset=STALE:unarmed=N301+N302+N303'
contains 'no --legs: procs=unknown still surfaces the live legs (HIMMEL-3293)' "$n3293" 'procs=unknown,unwatched=N301+N302+N303 '
# An arm that agrees with Live state reports legset=ok; no Live state section is unknown.
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
printf '%s\n' '# console' '' '## Live state' '' \
    'legs: `N301:J-N301-0a1b2c:tok-301:130`' 'queue: none' 'last GO: none' 'acked: none' \
    > "$W/handover/console.md"
contains 'an arm that agrees with Live state reads legset=ok (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'legset=ok'
contains 'an agreeing arm still surfaces the live legs outside it (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'procs=1,unwatched=N302+N303 '
printf '%s\n' '# console' '' 'no Live state section in this doc at all' > "$W/handover/console.md"
contains 'a console doc with no Live state section reads legset=unknown (HIMMEL-3293)' "$(t3293 "$W/handover/$a3293.md")" 'legset=unknown'

# --- HIMMEL-3305: a resolved FINDING must read differently from an open one.
# The ticket's case (leg N219, 2026-09-20): a leg raised a FINDING, the console
# accepted it the same minute, and tails= kept reading FINDING for the 23 minutes
# the leg spent doing the authorised work. The vocabulary had no word to retire a
# finding with, and the derivation took the FIRST marker on the last marker-bearing
# line, so word order decided the status. RED control (pre-fix tick.sh, the
# `resolved` case below): tails=N305:FINDING -- for a bullet that says the finding
# is settled. Fix: RESOLVED joins the vocabulary and the bullet's status is its
# highest-precedence marker (WRAPPED > READY > RESOLVED > BLOCKED > HALTED >
# FINDING > LIVE), matched as a whole word.
d3305="$W/handover/HIMMEL-3305-N305-resolved-2026-09-20-RESUME.md"
tail3305() {  # tail3305 <bullet>... -- the tails= entry of a leg doc holding these bullets
    printf '%s\n' '# leg' '- 19:40 LIVE — working' "$@" > "$d3305"
    bash "$SUT" --legs "$d3305" 2>/dev/null | sed -E 's/.* tails=([^ ]*) .*/\1/'
}
open3305='- 19:51 FINDING premises refuted (the console has not answered yet)'
res3305='- 19:52 RESOLVED — FINDING accepted by the console, back to work'
contains 'an open FINDING still reads FINDING (HIMMEL-3305)' "$(tail3305 "$open3305")" 'N305:FINDING'
contains 'a resolved FINDING reads RESOLVED, not FINDING (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305")" 'N305:RESOLVED'
# The newest marker-bearing bullet still wins: work after the ruling reads as work,
# and a new finding after a resolved one reads as open again.
contains 'a LIVE bullet after the resolution reads LIVE (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305" '- 20:05 LIVE — PR open, CI running')" 'N305:LIVE'
contains 'a second FINDING after a resolved one reads FINDING (HIMMEL-3305)' "$(tail3305 "$open3305" "$res3305" '- 20:20 FINDING the base moved under the diff')" 'N305:FINDING'
# Word order must not decide the status (the ticket's two bullets, with the marker
# that retires the finding). Each permutation reads the same.
contains 'RESOLVED before FINDING and LIVE reads RESOLVED (HIMMEL-3305)' "$(tail3305 '- 20:10 RESOLVED FINDING, back to LIVE')" 'N305:RESOLVED'
contains 'RESOLVED after FINDING and LIVE reads RESOLVED (HIMMEL-3305)' "$(tail3305 '- 20:10 LIVE again, FINDING RESOLVED')" 'N305:RESOLVED'
contains 'READY beats a BLOCKED it mentions, marker first (HIMMEL-3305)' "$(tail3305 '- 20:30 READY 999 abc GREEN (was BLOCKED)')" 'N305:READY'
contains 'READY beats a BLOCKED it mentions, marker last (HIMMEL-3305)' "$(tail3305 '- 20:30 BLOCKED cleared, now READY 999 abc GREEN')" 'N305:READY'
contains 'WRAPPED beats the READY it mentions (HIMMEL-3305)' "$(tail3305 '- 21:00 WRAPPED — merged after READY and GO')" 'N305:WRAPPED'
# A marker is a whole word: UNRESOLVED (a routine CR-thread count) is not RESOLVED.
contains 'UNRESOLVED is not the RESOLVED marker (HIMMEL-3305)' "$(tail3305 '- 20:00 LIVE — 2 UNRESOLVED threads')" 'N305:LIVE'
# SHIPPED and MERGED stay OUT of the vocabulary: a bullet carrying only a coined
# word has no marker, so the tick reads the last real one. leg-preface.md tells a
# leg between GREEN and READY to report LIVE for exactly this reason.
contains 'a coined SHIPPED bullet is invisible to the tick (HIMMEL-3305)' "$(tail3305 "$open3305" '- 20:05 SHIPPED to PR 999')" 'N305:FINDING'
contains 'a LIVE bullet is how a leg between GREEN and READY reports (HIMMEL-3305)' "$(tail3305 "$open3305" '- 20:05 LIVE — SHIPPED to PR 999, watching CI')" 'N305:LIVE'
# The tick's regex and the documented vocabulary change TOGETHER: a marker legs
# are not told to write is not a fix, and one the tick does not parse is worse.
repo3305="$(cd "$HERE/../../.." && pwd)"
for pref3305 in leg-preface.md leg-preface-claudex.md; do
    # shellcheck disable=SC2016  # backtick-quoted marker, literal doc text
    contains "$pref3305 tells a leg to report RESOLVED (HIMMEL-3305)" "$(cat "$repo3305/docs/handover/$pref3305")" '`RESOLVED`'
done
# shellcheck disable=SC2016  # backtick-quoted markers, literal doc text
contains 'leg-preface.md says SHIPPED and MERGED are not markers (HIMMEL-3305)' "$(cat "$repo3305/docs/handover/leg-preface.md")" '`SHIPPED` and `MERGED` are deliberately not in the'

# --- HIMMEL-3361: board=<ok|STALE:<age>|MISSING|skip> -- the console's progress
# board (console-board.html, written by board.mjs next to the console doc) must be
# structurally checked, not remembered. RED control (pre-fix tick.sh): the line
# carries no board= field at all, so a console that never rendered one, or whose
# board is days old, is invisible to its own tick. The freshness reference is a
# fingerprint of the state a board shows (legs, tails, open PRs, queue, last GO),
# embedded in the board by board.mjs and recomputed here -- not the doc's mtime,
# which every Results bullet bumps and would read STALE all day.
b3361="HIMMEL-3361-N361-board-2026-09-21-RESUME"
printf '%s\n' '# leg' '- 12:00 LIVE — working' > "$W/handover/$b3361.md"
mkcmdline 361 claude --model claude-sonnet-5 --autocompact 200000 -n HIMMEL-3361-N361-board work
mk_pgrep_x "$W/bin-3361" 361
board3361="$W/handover/console-board.html"
rm -f "$board3361"
# shellcheck disable=SC2016  # backtick leg spans, literal fixture text
write_console3361() {  # write_console3361 <last GO value> [extra Results bullet]
    printf '%s\n' '# console' '' '## Live state' '' \
        'legs: `N361:J-N361-0a1b2c9d:cachyos-x8664-pid361:361`' 'queue: N361 (3361)' "last GO: $1" 'acked: none' ${3:+"$3"} '' \
        '## Results (newest at the bottom)' '- 12:00 DISPATCH N361' ${2:+"$2"} \
        > "$W/handover/console.md"
}
t3361() { PATH="$W/bin-3361:$PATH" bash "$SUT" --legs "$W/handover/$b3361.md" "$@"; }
write_console3361 none
contains 'a console with no board file reads board=MISSING (HIMMEL-3361)' "$(t3361)" ' board=MISSING'
# The default fixture has no console doc at all: nothing to check, like legset=skip.
contains 'no console doc reads board=skip (HIMMEL-3361)' "$out" ' board=skip'
contains '--verbose labels the board (HIMMEL-3361)' "$(t3361 --verbose)" 'board: MISSING'
# --emit-fp is the seam board.mjs reads: the tick line, then the fingerprint.
fp3361="$(t3361 --emit-fp | sed -n '2p')"
case "$fp3361" in
    board-fp=[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) pass '--emit-fp prints the fingerprint on line 2 (HIMMEL-3361)' ;;
    *) fail "--emit-fp line 2 is not board-fp=<16 hex> ('$fp3361')" ;;
esac
# A board whose fingerprint is not the current one is STALE, aged by its mtime.
printf '%s\n' '<meta name="console-board-fp" content="0000000000000000">' > "$board3361"
touch -d '3 hours ago' "$board3361"  # gnu-ok: console kit is Linux-only
contains 'a board with another fingerprint reads board=STALE:<age> (HIMMEL-3361)' "$(t3361)" ' board=STALE:3h'
touch -d '12 minutes ago' "$board3361"  # gnu-ok: console kit is Linux-only
contains 'a young stale board ages in minutes (HIMMEL-3361)' "$(t3361)" ' board=STALE:12m'
# The real generator's output is fresh under the real tick: one derivation. The
# stubs on PATH answer gh/bank/atq for both, so the two runs see the same state.
if command -v node >/dev/null 2>&1; then
    bpath3361="$(PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/console.md" --legs "$W/handover/$b3361.md" --repo "$REPO" 2>&1)"
    if [ "$bpath3361" = "$board3361" ] && [ -f "$board3361" ]; then
        pass 'board.mjs writes console-board.html next to the console doc (HIMMEL-3361)'
    else
        fail "board.mjs did not write the board ($bpath3361)"
    fi
    contains 'a board rendered from the current state reads board=ok (HIMMEL-3361)' "$(t3361)" ' board=ok'
    # A Results bullet is not a state change: the board stays ok.
    write_console3361 none '- 12:05 RULING nothing about state'
    contains 'a Results bullet does not stale the board (HIMMEL-3361)' "$(t3361)" ' board=ok'
    # A GO is: republish.
    # shellcheck disable=SC2016  # backtick span, literal fixture text
    write_console3361 '`1023:abc`'
    contains 'a new last GO stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    # The epics: and decisions: lines are rendered panels: editing them is a republish.
    write_console3361 none '' 'epics: HIMMEL-3332=5'
    contains 'a new epics: line stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    write_console3361 none '' 'decisions: widen the fleet cap?'
    contains 'a new decisions: line stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    write_console3361 none
    # A leg tail change (READY) is a phase change: republish.
    printf '%s\n' '- 12:30 READY 1023 abc GREEN' >> "$W/handover/$b3361.md"
    contains 'a leg phase change stales the board (HIMMEL-3361)' "$(t3361)" ' board=STALE:'
    # --- HIMMEL-3366: one Live-state block, read by tick.sh and by board.mjs, names
    # the same legs. RED control (pre-fix board.mjs): its own parser accepted a
    # three-field span (N4), an empty-field span (N5), a span in a `>` line (N8) and
    # a detail bullet (N6), and rejected a label with _ . - (N3_x.y-z). The tick
    # reads no --legs here, so every Live-state entry is `unarmed=` and the board,
    # given no leg docs, lists exactly its Live-state labels.
    # shellcheck disable=SC2016  # backtick leg spans, literal fixture text
    printf '%s\n' '# console' '' '## Live state' '' \
        'legs: `N1:J-N1-0a1b2c9d:cachyos-x8664-pid1001:1001` a note `procs:2` `N2b:J-N2b-0a1b2c9d:cachyos-x8664-pid1002:1002`' \
        '  `N3_x.y-z:J-N3-0a1b2c9d:cachyos-x8664-pid1003:1003` `N4:J-N4-0a1b2c9d:cachyos-x8664-pid1004` `N5::J-N5-0a1b2c9d:1005`' \
        '> quoted `N8:J-N8-0a1b2c9d:cachyos-x8664-pid1008:1008` after a > terminator' \
        'legs: `N7:J-N7-0a1b2c9d:cachyos-x8664-pid1007:1007`' \
        '- detail `N6:J-N6-0a1b2c9d:cachyos-x8664-pid1006:1006` under the block' \
        'queue: none' 'last GO: none' 'acked: none' '' '## Results' '- 12:00 DISPATCH' \
        > "$W/handover/console.md"
    tickset3366="$(PATH="$W/bin-3361:$PATH" bash "$SUT" --doc "$W/handover/console.md" | sed -n 's/.* legset=STALE:unarmed=\([^ ;]*\).*/\1/p' | tr '+' '\n' | sort)"
    PATH="$W/bin-3361:$PATH" BOARD_TICK="$SUT" node "$HERE/board.mjs" --doc "$W/handover/console.md" --repo "$REPO" >/dev/null 2>&1
    boardset3366="$(grep -o 'data-label="[^"]*"' "$W/handover/console-board.html" | sed 's/^data-label="//; s/"$//' | sort)"
    contains 'the tick reads a label with _ . - as a leg (HIMMEL-3366)' "$tickset3366" 'N3_x.y-z'
    if [ -n "$tickset3366" ] && [ "$tickset3366" = "$boardset3366" ]; then
        pass 'tick.sh and board.mjs read one Live-state block as the same leg set (HIMMEL-3366)'
    else
        fail "tick.sh and board.mjs read different leg sets (tick: $(printf '%s' "$tickset3366" | tr '\n' ' ') board: $(printf '%s' "$boardset3366" | tr '\n' ' '))"
    fi
else
    printf 'SKIP - board round-trip (node not installed)\n'
fi

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick.sh'
    exit 0
fi
printf 'FAIL - test-tick.sh (%s failure(s))\n' "$fails"
exit 1
