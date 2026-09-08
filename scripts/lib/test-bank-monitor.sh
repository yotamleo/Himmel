#!/usr/bin/env bash
# test-bank-monitor.sh — HIMMEL-2767. Deterministic one-shot tests for the
# 30-minute bank sample ring, burn projections, wake-up suppression, resets,
# missing data, and the claudex/codex bank input.
#
# PLATFORM GUARD: no .ps1 twin, by design. bank-monitor.sh is a POSIX/Git-Bash
# Bash 3.2 monitor consumed by the Linux console kit; this suite uses its
# explicit cache, clock, state, and command seams.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SUT="$HERE/bank-monitor.sh"
W="$(mktemp -d "${TMPDIR:-/tmp}/bank-monitor-test.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
fails=0

pass() { printf 'ok - %s\n' "$1"; }
fail() { printf 'FAIL - %s\n' "$1"; fails=$((fails + 1)); }
check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

mkdir -p "$W/bin" "$W/repo/scripts/lanes"
cat > "$W/bin/bun" <<'STUB'
#!/usr/bin/env bash
cat "$BANK_STUB_ROW_FILE"
STUB
chmod +x "$W/bin/bun"
printf '%s\n' 'claudex funded measured 5h used=10% free=90%; weekly used=20% free=80%' > "$W/codex-row"

export PATH="$W/bin:$PATH"
export BANK_CACHE_FILE="$W/cache.json"
export BANK_STATE_FILE="$W/state"
export BANK_STUB_ROW_FILE="$W/codex-row"
export REPO="$W/repo"

sample_revision=0
sample() {
    sample_revision=$((sample_revision + 1))
    printf '{"five_hour":{"utilization":%s},"seven_day":{"utilization":%s}}\n' "$1" "$2" > "$BANK_CACHE_FILE"
    touch -t "202001010000.$(printf '%02d' "$sample_revision")" "$BANK_CACHE_FILE"
}
run_at() {
    BANK_NOW_EPOCH="$1" BANK_NOW_HM="$2" bash "$SUT"
}

sample 10 20
out="$(run_at 1000 12:00)"; rc=$?
check 'first observation emits the initial state' 0 "$rc"
check 'first observation has unknown projections until a rate exists' \
  'BANK 12:00 rate five_hour=+0.0/h seven_day=+0.0/h ttc=?h state=headroom five_hour_ttc=?h seven_day_ttc=?h codex=5h10/wk20' "$out"

sample 20 25
out="$(run_at 2800 12:30)"; rc=$?
check '30-minute series exits successfully' 0 "$rc"
check 'exact rates and both projections are exposed; earliest projection is ttc' \
  'BANK 12:30 rate five_hour=+20.0/h seven_day=+10.0/h ttc=4.0h state=headroom five_hour_ttc=4.0h seven_day_ttc=7.5h codex=5h10/wk20' "$out"

sample 21 25.5
out="$(run_at 2980 12:33)"; rc=$?
check 'unchanged state while already below 24h is silent' '' "$out"
check 'silent observation still exits successfully' 0 "$rc"

sample 65 27
out="$(run_at 3100 12:35)"; rc=$?
case "$out" in *'state=park'*) pass 'five-hour threshold changes state to park' ;; *) fail "five-hour threshold changes state to park (out='$out')" ;; esac

sample 5 3
out="$(run_at 3400 12:40)"; rc=$?
check 'a usage reset discards the old rate and emits the state change' \
  'BANK 12:40 rate five_hour=+0.0/h seven_day=+0.0/h ttc=?h state=headroom five_hour_ttc=?h seven_day_ttc=?h codex=5h10/wk20' "$out"

before_samples="$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"
rm -f "$BANK_CACHE_FILE"
out="$(run_at 3700 12:45)"; rc=$?
after_samples="$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"
check 'missing cache is silent' '' "$out"
check 'missing cache is non-fatal' 0 "$rc"
check 'missing cache does not corrupt the sample ring' "$before_samples" "$after_samples"

sample 6 4
printf '%s\n' 'claudex spent measured 5h used=40% free=60%; weekly used=90% free=10%' > "$W/codex-row"
out="$(run_at 4000 12:50)"; rc=$?
case "$out" in *'state=WEEKLY-CEILING'*'codex=5h40/wk90'*) pass 'claudex weekly ceiling participates in state' ;; *) fail "claudex weekly ceiling participates in state (out='$out')" ;; esac

# Unchanged cache polls must preserve the measured rate, even past ring expiry.
printf '%s\n' 'claudex funded measured 5h used=10% free=90%; weekly used=20% free=80%' > "$W/codex-row"
export BANK_STATE_FILE="$W/stale-state"
sample 10 20
run_at 1000 12:00 >/dev/null
sample 20 25
run_at 2800 12:30 >/dev/null
before_samples="$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"
before_series="$(cat "$BANK_STATE_FILE.samples")"
out="$(run_at 3100 12:35)"
check 'unchanged cache leaves sample contents untouched' "$before_series" "$(cat "$BANK_STATE_FILE.samples")"
check 'unchanged cache emits stale with the last measured projections' \
  'BANK 12:35 rate five_hour=+20.0/h seven_day=+10.0/h ttc=4.0h state=stale five_hour_ttc=4.0h seven_day_ttc=7.5h codex=5h10/wk20' "$out"
check 'unchanged cache does not append a sample' "$before_samples" "$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"
out="$(run_at 7000 13:40)"
check 'repeated stale polls are silent' '' "$out"
check 'stale polls do not age out the last measured series' "$before_samples" "$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"
sample 22 26
out="$(run_at 7300 13:45)"
check 'refreshed cache resumes sampling and clears stale' \
  'BANK 13:45 rate five_hour=+0.0/h seven_day=+0.0/h ttc=?h state=headroom five_hour_ttc=?h seven_day_ttc=?h codex=5h10/wk20' "$out"
check 'resumed sampling ages out old measurements' 1 "$(wc -l < "$BANK_STATE_FILE.samples" | tr -d '[:space:]')"

# Only the resetting window loses history; the other keeps its full baseline.
export BANK_STATE_FILE="$W/five-reset-state"
sample 60 20
run_at 1000 12:00 >/dev/null
sample 65 25
run_at 1900 12:15 >/dev/null
sample 5 30
out="$(run_at 2800 12:30)"
check 'five-hour reset retains weekly rate and projection' \
  'BANK 12:30 rate five_hour=+0.0/h seven_day=+20.0/h ttc=3.5h state=headroom five_hour_ttc=?h seven_day_ttc=3.5h codex=5h10/wk20' "$out"
sample 10 35
out="$(run_at 3100 12:35)"
check 'post-reset sample keeps wake-up suppression' '' "$out"
out="$(run_at 3400 12:40)"
check 'five-hour rate restarts at its reset baseline' \
  'BANK 12:40 rate five_hour=+60.0/h seven_day=+30.0/h ttc=1.5h state=stale five_hour_ttc=1.5h seven_day_ttc=2.2h codex=5h10/wk20' "$out"

export BANK_STATE_FILE="$W/seven-reset-state"
sample 10 85
run_at 1000 12:00 >/dev/null
sample 15 90
run_at 1900 12:15 >/dev/null
sample 20 5
out="$(run_at 2800 12:30)"
check 'weekly reset retains five-hour rate and projection' \
  'BANK 12:30 rate five_hour=+20.0/h seven_day=+0.0/h ttc=4.0h state=headroom five_hour_ttc=4.0h seven_day_ttc=?h codex=5h10/wk20' "$out"

# oauth_checked_at may stay fixed while the stdin producer refreshes rates.
export BANK_STATE_FILE="$W/oauth-state"
sample 10 20
printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"oauth_checked_at":1000}\n' > "$BANK_CACHE_FILE"
touch -t 202001010001.00 "$BANK_CACHE_FILE"
run_at 1000 12:00 >/dev/null
out="$(run_at 1300 12:05)"
case "$out" in *'state=stale'*) pass 'unchanged OAuth cache is stale' ;; *) fail "unchanged OAuth cache is stale (out='$out')" ;; esac
touch -t 202001010002.00 "$BANK_CACHE_FILE"
out="$(run_at 1600 12:10)"
case "$out" in *'state=headroom'*) pass 'mtime refresh with unchanged OAuth stamp resumes sampling' ;; *) fail "mtime refresh with unchanged OAuth stamp resumes sampling (out='$out')" ;; esac
printf '{"five_hour":{"utilization":20},"seven_day":{"utilization":25},"oauth_checked_at":1900}\n' > "$BANK_CACHE_FILE"
touch -t 202001010002.00 "$BANK_CACHE_FILE"
out="$(run_at 1900 12:15)"
check 'OAuth refresh within the same mtime second resumes sampling' \
  'BANK 12:15 rate five_hour=+40.0/h seven_day=+20.0/h ttc=2.0h state=headroom five_hour_ttc=2.0h seven_day_ttc=3.8h codex=5h10/wk20' "$out"

if [ "$fails" -eq 0 ]; then
    printf '%s\n' 'PASS - test-bank-monitor.sh'
    exit 0
fi
printf 'FAIL - test-bank-monitor.sh (%s failure(s))\n' "$fails"
exit 1
