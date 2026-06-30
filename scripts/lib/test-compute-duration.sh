#!/usr/bin/env bash
# shellcheck disable=SC2015
# test-compute-duration.sh -- HIMMEL-653 / GH#192. compute_duration() in
# session-transcript.sh must work on macOS/BSD date, which has no `-d` flag. On a
# GNU box the `-d` branch always wins, so the BSD fallback can't be exercised
# naturally -- this is exactly why the bug shipped (GNU CI stayed green while every
# macOS session silently skipped the end-session-wiki hook). So we shim `date` with
# a BSD-like stub (rejects `-d`; on `-j -f` records the timestamp it received and
# emits a fixed epoch) and assert: (a) the fallback fires, (b) its epoch flows into
# the duration, (c) normalization strips fractional secs AND a trailing Z for BOTH
# `...:SS.sssZ` and `...:SSZ` shapes (no double-Z). bash 3.2-safe.
#
# GNU-HOST TEST: runs on Linux CI + Windows Git Bash (GNU date), where the shim is
# the only way to reach the BSD branch. NOT a macOS-native runner — the real-date
# GNU case + the harness use GNU-only date; on real BSD the fallback is exercised
# natively instead. (HIMMEL-653 CR.)
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=/dev/null
. "$HERE/session-transcript.sh"
command -v compute_duration >/dev/null 2>&1 || { echo "FATAL: compute_duration not defined"; exit 2; }

fails=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; fails=$((fails + 1)); }
check() { [ "$2" = "$3" ] && pass "$1" || { fail "$1: [$2] != [$3]"; }; }

# --- GNU path (real date) still works -----------------------------------------
# Derive `now` from date itself (no brittle epoch constant); +300s -> 5 min. If the
# GNU `-d` branch regressed to empty, start would be huge -> delta clamps 0 -> fails.
gnu_start="$(date -u -d "2026-06-30T16:00:00Z" +%s)"
compute_duration "2026-06-30T16:00:00Z" "$(( gnu_start + 300 ))"
check "GNU path: DURATION_SECONDS" "300" "$DURATION_SECONDS"
check "GNU path: DURATION_MINUTES" "5"   "$DURATION_MINUTES"

# --- BSD path via a date shim that rejects -d (like macOS) --------------------
td="$(mktemp -d)"; trap 'rm -rf "$td"' EXIT
cap="$td/ts"
# The shim reads its capture path from $TS_CAP (env) rather than a sed-patched
# placeholder — `sed -i` differs between GNU and BSD and would be a fresh portability
# trap in a portability fix. (HIMMEL-653 CR.)
cat > "$td/date" <<'SHIM'
#!/usr/bin/env bash
# BSD-like date stub: no -d; on -j -f, record the timestamp arg (-> $TS_CAP) + emit
# a fixed epoch. Single-quoted heredoc: $TS_CAP/$ts/$prev resolve at shim runtime.
prev=""; ts=""
for a in "$@"; do
  [ "$a" = "-d" ] && { echo "date: illegal option -- d" >&2; exit 1; }
  [ "$a" = "+%s" ] && ts="$prev"
  prev="$a"
done
printf '%s' "$ts" > "$TS_CAP"
echo 1782403200   # fixed arbitrary epoch returned for any valid parse
SHIM
chmod +x "$td/date"

# (i) fractional-seconds + Z input -> fallback fires, duration correct, ts normalized.
: > "$cap"
TS_CAP="$cap" PATH="$td:$PATH" compute_duration "2026-06-30T16:00:00.123Z" "1782403500"
check "BSD path (.sssZ): DURATION_SECONDS" "300" "$DURATION_SECONDS"
check "BSD path (.sssZ): normalized ts (no frac, no Z)" "2026-06-30T16:00:00" "$(cat "$cap")"

# (ii) bare-Z input (no fractional) -> normalization must NOT leave a double Z.
: > "$cap"
TS_CAP="$cap" PATH="$td:$PATH" compute_duration "2026-06-30T16:00:00Z" "1782403500"
check "BSD path (bare Z): DURATION_SECONDS" "300" "$DURATION_SECONDS"
check "BSD path (bare Z): normalized ts (single, no Z)" "2026-06-30T16:00:00" "$(cat "$cap")"

# --- Unparseable timestamp under BSD stub -> honest 0 (gate skips, no crash) ---
# Stub marks ($REACHED) that it got PAST the -d rejection (i.e. the -j -f call ran),
# then fails the parse -- so case 3 proves the fallback RAN and honestly failed, not
# that -d short-circuited. Matches the marker rigor of cases i/ii. (HIMMEL-653 CR.)
reached="$td/reached"; : > "$reached"
cat > "$td/date" <<'SHIM2'
#!/usr/bin/env bash
for a in "$@"; do [ "$a" = "-d" ] && exit 1; done
printf 'reached' > "$REACHED"   # past -d -> this is the -j -f fallback call
exit 1                          # garbage input: BSD -j -f parse fails
SHIM2
chmod +x "$td/date"
REACHED="$reached" PATH="$td:$PATH" compute_duration "not-a-timestamp" "1782403500"
check "BSD path (unparseable): DURATION_SECONDS falls back to 0" "0" "$DURATION_SECONDS"
check "BSD path (unparseable): -j -f fallback branch was reached" "reached" "$(cat "$reached")"

if [ "$fails" -eq 0 ]; then echo "ALL PASS"; exit 0; fi
echo "SOME FAILED"; exit 1
