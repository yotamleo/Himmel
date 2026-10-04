#!/usr/bin/env bash
# test-doctor-cadence.sh — scripts/doctor-cadence.sh (HIMMEL-4251): the daily
# himmel-doctor run, its Telegram alert on a FAIL or a NEW WARN, and the
# statusline segment that reads its state file. Hermetic: sandboxed HOME, a
# stubbed doctor, a stubbed Telegram sender, a stubbed crontab. Never touches
# the real station, never arms anything, never sends a message.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_ROOT="$(cd "$DIR/.." && pwd)"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
# check <label> <expected> <actual>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

W="$(mktemp -d)" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
unset HIMMEL_DOCTOR_STATE_DIR CADENCE_ALERT_FILE CADENCE_ALERT_DEDUPE_DIR

# A primary checkout with a linked worktree; both carry the script under test.
P="$W/primary"; WT="$W/wt"
mkdir -p "$P/scripts/luna"
git init -q "$P"
cp "$DIR/doctor-cadence.sh" "$P/scripts/doctor-cadence.sh" 2>/dev/null || true
cp "$DIR/doctor-counts.sh" "$P/scripts/doctor-counts.sh" 2>/dev/null || true
cp "$REAL_ROOT/scripts/luna/cadence-alert.sh" "$P/scripts/luna/cadence-alert.sh"
# The stub doctor: prints $STUB_OUT, records where it ran.
cat > "$P/scripts/himmel-doctor.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$PWD" "$0" "$*" >> "$STUB_WHERE"
cat "$STUB_OUT"
SH
git -C "$P" add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -q -m fixture
git -C "$P" worktree add -q "$WT" -b wt-branch

SENT="$W/sent.log"; : > "$SENT"
cat > "$W/send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SENT"
SH
chmod +x "$W/send.sh"
export SENT STUB_OUT="$W/doctor.out" STUB_WHERE="$W/where.log" CADENCE_ALERT_SEND_CMD="$W/send.sh"
STATE="$HOME/.himmel/state/doctor-cadence"

doctor_out() { # <fail-ids> <warn-ids>  (space separated)
    { echo "himmel-doctor — Linux"; echo
      local i nf=0 nw=0
      for i in $1; do echo "FAIL $i: broken"; echo "       → fix it"; nf=$((nf+1)); done
      for i in $2; do echo "WARN $i: iffy"; nw=$((nw+1)); done
      echo "OK   C99-fine: fine"
      echo; echo "Summary: $nf FAIL  $nw WARN  0 INFO"; } > "$STUB_OUT"
}
run_cad() { bash "${1:-$P}/scripts/doctor-cadence.sh" run >/dev/null 2>&1; }
sent_n() { wc -l < "$SENT" | tr -d ' '; }

# 1. first run with a FAIL → exactly one alert naming it.
doctor_out "C16-hooks" ""
run_cad
check "first run with a FAIL sends one alert" 1 "$(sent_n)"
grep -q 'C16-hooks' "$SENT" && pass "alert names the FAIL id" || fail "alert names the FAIL id"

# 2. identical second run → no new alert.
run_cad
check "identical second run sends no alert" 1 "$(sent_n)"

# 3. a new WARN id → one more alert.
doctor_out "C16-hooks" "C3-new"
run_cad
check "a new WARN id sends an alert" 2 "$(sent_n)"
tail -1 "$SENT" | grep -q 'C3-new' && pass "alert names the new WARN" || fail "alert names the new WARN"

# 4. a WARN that disappears → no alert.
doctor_out "C16-hooks" ""
run_cad
check "a WARN that disappears sends no alert" 2 "$(sent_n)"

# 5. state: counts file + previous run kept for diffing.
check "counts file reflects the last run" "fail=1 warn=0" "$(cat "$STATE/counts" 2>/dev/null)"
[ -s "$STATE/alerted.tsv" ] && pass "alert baseline kept" || fail "alert baseline kept"
check "last.tsv and counts come from the same run" "FAIL C16-hooks" "$(cat "$STATE/last.tsv" 2>/dev/null)"

# 5b. HIMMEL-4382: an ad-hoc doctor run that introduces a new finding must not
# swallow the cadence alert (the baseline is the cadence's own, not last.tsv).
: > "$SENT"; doctor_out "C16-hooks" ""; run_cad
n0="$(sent_n)"
# shellcheck source=doctor-counts.sh
. "$DIR/doctor-counts.sh" 2>/dev/null
printf 'FAIL C16-hooks\nFAIL C77-adhoc\n' > "$W/adhoc.keys"
doctor_state_publish "$STATE" "$W/adhoc.keys" 2 0
check "doctor_state_publish writes last.tsv and counts together" "fail=2 warn=0" "$(cat "$STATE/counts")"
doctor_out "C16-hooks C77-adhoc" ""; run_cad
check "a finding first seen by an ad-hoc run still alerts the cadence once" "$((n0 + 1))" "$(sent_n)"
tail -1 "$SENT" | grep -q 'C77-adhoc' && pass "that alert names the ad-hoc finding" || fail "that alert names the ad-hoc finding"
run_cad
check "the next identical cadence run does not alert again" "$((n0 + 1))" "$(sent_n)"

# 6. a first-ever run with only WARNs is a baseline: no alert.
rm -rf "$STATE"; : > "$SENT"
doctor_out "" "C3-old C4-old"
run_cad
check "first run with only WARNs is a baseline (no alert)" 0 "$(sent_n)"

# 7. run from a worktree resolves the primary checkout.
: > "$STUB_WHERE"
run_cad "$WT"
grep -q "^$P|$P/scripts/himmel-doctor.sh|" "$STUB_WHERE" && pass "worktree run executes the PRIMARY's doctor from the primary" \
    || fail "worktree run executes the PRIMARY's doctor (saw: $(cat "$STUB_WHERE"))"

# 8. a doctor that crashes (no Summary line) alerts and leaves state alone.
: > "$SENT"; before="$(cat "$STATE/counts")"
echo "boom" > "$STUB_OUT"
run_cad
check "crashed doctor sends one alert" 1 "$(sent_n)"
check "crashed doctor leaves the counts file alone" "$before" "$(cat "$STATE/counts")"

# 9. statusline segment: renders from a fixture, silent when absent / clean.
SEG_STATE="$W/segstate"; mkdir -p "$SEG_STATE"
seg() { HIMMEL_DOCTOR_STATE_DIR="$SEG_STATE" HIMMEL_WHERE_ARE_WE=off HIMMEL_STATUSLINE_ECON=off \
        bash "$REAL_ROOT/scripts/statusline/hud-custom-lines.sh" </dev/null 2>/dev/null; }
check "segment prints nothing when the state file is absent" "" "$(seg)"
echo "fail=2 warn=5" > "$SEG_STATE/counts"
check "segment renders the FAIL/WARN counts" "doctor  2 FAIL  5 WARN" "$(seg)"
echo "fail=0 warn=0" > "$SEG_STATE/counts"
check "segment prints nothing when the doctor is clean" "" "$(seg)"
echo "garbage" > "$SEG_STATE/counts"
check "segment prints nothing on a malformed state file" "" "$(seg)"

# 9b. HIMMEL-4363: a counts file older than 24 h shows its age; a fresh one does not.
echo "fail=1 warn=12" > "$SEG_STATE/counts"
check "fresh counts show no age" "doctor  1 FAIL  12 WARN" "$(seg)"
age_file() { perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$(($(date +%s) - $1))" "$2"; }
age_file 259200 "$SEG_STATE/counts"
check "counts over 24h old show the age in days" "doctor  1 FAIL  12 WARN (3d old)" "$(seg)"
age_file 108000 "$SEG_STATE/counts"
check "counts 30h old show the age in hours" "doctor  1 FAIL  12 WARN (30h old)" "$(seg)"
# the shared writer: atomic (no tmp left behind), creates the dir, exact format.
# shellcheck source=doctor-counts.sh
. "$DIR/doctor-counts.sh" 2>/dev/null
WSTATE="$W/wstate/nested"
doctor_counts_write "$WSTATE" 4 7 2>/dev/null
check "shared writer writes fail=/warn=" "fail=4 warn=7" "$(cat "$WSTATE/counts" 2>/dev/null)"
check "shared writer leaves no tmp file" "counts" "$(ls "$WSTATE" 2>/dev/null)"

# 10. cron arm / status / disarm through a stub crontab; never the real one.
cat > "$W/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$FAKE_CRON" 2>/dev/null || { echo "no crontab for t" >&2; exit 1; }
else cat > "$FAKE_CRON"; fi
SH
chmod +x "$W/crontab"
export FAKE_CRON="$W/cron.tab" DOCTORCAD_CRONTAB="$W/crontab" DOCTORCAD_RUNNER_DIR="$W/runner"
bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1; check "arm exits 0" 0 $?
grep -c 'HIMMEL-Doctor' "$FAKE_CRON" | grep -qx 1 && pass "arm writes one crontab entry" || fail "arm writes one crontab entry"
bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1; check "re-arm without --force is refused (rc 3)" 3 $?
st="$(bash "$P/scripts/doctor-cadence.sh" status 2>&1)"
case "$st" in ARMED*) pass "status reports ARMED" ;; *) fail "status reports ARMED ($st)" ;; esac
bash "$P/scripts/doctor-cadence.sh" disarm >/dev/null 2>&1; check "disarm exits 0" 0 $?
grep -q 'HIMMEL-Doctor' "$FAKE_CRON"; rc=$?
check "disarm removes the entry (grep: 1 = absent from a readable file)" 1 "$rc"

# 11. hardening (CR round 1): a dangling --time fails fast instead of looping;
# a runner dir with a space is quoted in the crontab line; an unreadable
# crontab is never mistaken for an empty one.
timeout 5 bash "$P/scripts/doctor-cadence.sh" arm --time >/dev/null 2>&1; rc=$?
check "arm --time with no value fails fast (no hang)" 1 "$rc"
SP="$W/run ner"
DOCTORCAD_RUNNER_DIR="$SP" bash "$P/scripts/doctor-cadence.sh" arm --force >/dev/null 2>&1
grep -qF "\"$SP/doctor-cadence.sh\"" "$FAKE_CRON" && pass "runner path with a space is quoted in the crontab line" || fail "runner path with a space is quoted in the crontab line"
DOCTORCAD_RUNNER_DIR="$SP" bash "$P/scripts/doctor-cadence.sh" disarm >/dev/null 2>&1
printf '0 1 * * * keepme\n' > "$FAKE_CRON"
cat > "$W/crontab-broken" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then echo "crontab: temporary read failure" >&2; exit 1; fi
cat > "$FAKE_CRON"
SH
chmod +x "$W/crontab-broken"
DOCTORCAD_CRONTAB="$W/crontab-broken" bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && grep -q keepme "$FAKE_CRON"; then pass "a failed crontab read does not overwrite existing jobs"; else fail "a failed crontab read does not overwrite existing jobs (rc=$rc)"; fi

# an unwritable runner dir must fail arm BEFORE any crontab is installed.
printf '0 1 * * * keepme\n' > "$FAKE_CRON"
: > "$W/notadir"
DOCTORCAD_RUNNER_DIR="$W/notadir/sub" bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1; rc=$?
if [ "$rc" -ne 0 ] && ! grep -q 'HIMMEL-Doctor' "$FAKE_CRON"; then pass "an unwritable runner dir fails arm without installing the crontab"; else fail "an unwritable runner dir fails arm without installing the crontab (rc=$rc)"; fi
DOCTORCAD_RUNNER_DIR="$W/runner2" bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1
head -1 "$W/runner2/doctor-cadence.sh" | grep -qx '#!/usr/bin/env bash' && pass "the runner uses a bash shebang" || fail "the runner uses a bash shebang"

echo
if [ "$FAILED" -eq 0 ]; then echo "test-doctor-cadence: all passed"; exit 0; fi
echo "test-doctor-cadence: $FAILED failed"; exit 1
