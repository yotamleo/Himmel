#!/usr/bin/env bash
# test-tick.sh — HIMMEL-2767. Hermetic public-CLI tests for the batched console
# tick: exact one-line output, verbose human output, stale fill, and a missing
# leg document. No live queue, process, scheduler, GitHub, or bank operations.
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

mkdir -p "$W/repo/scripts/handover" "$W/repo/scripts/lib" "$W/handover/inbox/.cursor" "$W/bin" "$W/himmel-shell-suite-test.lock"

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
cat > "$W/bin/date" <<'STUB'
#!/usr/bin/env bash
case "$1" in +%H:%M) printf '%s\n' 12:34 ;; *) /bin/date "$@" ;; esac
STUB
cat > "$W/bin/pgrep" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' \
  '101 claude --model x -n HIMMEL-111-legN61 work' \
  '102 claude --model x -n LUNA-222-legN9 work' \
  '103 claude --model x -n HIMMEL-next-console work'
STUB
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
chmod +x "$W/repo/scripts/handover/queue-lock.sh" "$W/repo/scripts/context-fill.sh" "$W/bin/"*

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

out="$(bash "$SUT")"; rc=$?
expected='TICK 12:34 hb=ok legs=N61:FRESH,N65:FREE procs=2 atq=2 suites=1alive/0dead prs=#2247,#2250 bank=5h30/wk28/codex=5h12/wk34 fill=28 tails=N61:LIVE,N65:READY inbox=N61:10/4,N65:8/8'
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

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-tick.sh'
    exit 0
fi
printf 'FAIL - test-tick.sh (%s failure(s))\n' "$fails"
exit 1
