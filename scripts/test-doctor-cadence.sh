#!/usr/bin/env bash
# test-doctor-cadence.sh — scripts/doctor-cadence.sh: the daily
# himmel-doctor run, its Telegram alert on a FAIL or a NEW WARN, and the
# statusline segment that reads its state file. Hermetic: sandboxed HOME, a
# stubbed doctor, a stubbed Telegram sender, a stubbed crontab. Never touches
# the real station, never arms anything, never sends a message.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_ROOT="$(cd "$DIR/.." && pwd)"
# shellcheck source=lib/timeout-bin.sh
. "$DIR/lib/timeout-bin.sh"
FAILED=0
pass() { echo "PASS $1"; }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
# check <label> <expected> <actual>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }

W="$(mktemp -d)" || exit 1
# the script under test reports physical paths; macOS's $TMPDIR sits behind the /var symlink
W="$(cd "$W" && pwd -P)" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"
unset HIMMEL_DOCTOR_STATE_DIR CADENCE_ALERT_FILE CADENCE_ALERT_DEDUPE_DIR

# A primary checkout with a linked worktree; both carry the script under test.
P="$W/primary"; WT="$W/wt"
mkdir -p "$P/scripts/luna" "$P/scripts/lib"
git init -q "$P"
cp "$REAL_ROOT/scripts/lib/prim.sh" "$REAL_ROOT/scripts/lib/canon-path.sh" "$P/scripts/lib/"
cp "$DIR/doctor-cadence.sh" "$P/scripts/doctor-cadence.sh" 2>/dev/null || true
cp "$DIR/doctor-counts.sh" "$P/scripts/doctor-counts.sh" 2>/dev/null || true
cp "$REAL_ROOT/scripts/luna/cadence-alert.sh" "$P/scripts/luna/cadence-alert.sh"
# The stub doctor: prints $STUB_OUT, records where it ran.
cat > "$P/scripts/himmel-doctor.sh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s|%s\n' "$PWD" "$0" "$*" >> "$STUB_WHERE"
if [ -n "${STUB_GATE:-}" ]; then
    i=0
    while [ ! -f "$STUB_GATE" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    [ -f "$STUB_GATE" ] || exit 1
fi
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
# run_cad_ok <what>: one run that must exit 0, so a sent alert is not read off a run that then failed.
run_cad_ok() { run_cad; check "$1 exits 0" 0 "$?"; }
kill_cad() { # Kill only an isolated fixture group, then await descriptor closure.
    local pid pgid rc i=0 live
    : > "$STUB_WHERE"
    export STUB_GATE="$W/killed.release"
    set -m
    run_cad & pid=$!
    set +m
    while [ ! -s "$STUB_WHERE" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
    pgid="$(ps -o pgid= -p "$pid" | tr -d ' ')"
    if [ "$pgid" != "$pid" ] || [ ! -s "$STUB_WHERE" ]; then
        touch "$STUB_GATE"; wait "$pid"; unset STUB_GATE
        return 2
    fi
    kill -KILL -- "-$pid"
    wait "$pid" 2>/dev/null; rc=$?
    unset STUB_GATE
    i=0
    while [ "$i" -lt 100 ]; do
        live="$(ps -eo pgid=,stat= | awk -v g="$pid" '$1 == g && $2 !~ /^Z/ {n++} END {print n+0}')" || return 2
        [ "$live" -eq 0 ] && return "$rc"
        sleep 0.05; i=$((i + 1))
    done
    return 2
}
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

# 5b. an ad-hoc doctor run that introduces a new finding must not
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
last_alert="$(tail -1 "$SENT")"
case "$last_alert" in *C77-adhoc*) pass "that alert names the ad-hoc finding" ;; *) fail "that alert names the ad-hoc finding" ;; esac
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

# 8a. the alert is plain: each new finding carries its check's text, a WARN that follows from a failing
# graph cadence says so, and the message ends in the next step and the log. The WARN lines are the doctor's own.
rm -rf "$STATE" "$HOME/.himmel/state/cadence-alert-sent"; : > "$SENT"
doctor_out "" "C99-base"; run_cad_ok "the 3-WARN baseline run"
mkdir -p "$HOME/.himmel/state/cadence-alert-sent"; : > "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel.x"
cat > "$STUB_OUT" <<'OUT'
himmel-doctor — Linux

WARN C15-plugins: 3 plugin(s) enabled beyond the lean floor (context cost at session start): a, b, c
       → trim enabledPlugins to the lean set   # or run /profile
WARN C23-unlanded: 2 aged unlanded local branch(es) (of 5 unlanded, 121 landed-elsewhere, 32 stale) — work committed but never opened as a PR, sitting past the age threshold
       → bash scripts/unlanded-work.sh   # review, then open PRs or drop
WARN C33-graph-stale: graph stale: 12 commits behind main / last cadence run 5h ago FAILED
       → bash scripts/graphify/graph-cadence.sh
OK   C99-fine: fine

Summary: 0 FAIL  3 WARN  0 INFO
OUT
run_cad_ok "the 3-WARN run"
plain="$(tail -1 "$SENT")"
case "$plain" in "himmel-doctor: 3 new findings: "*) pass "doctor alert opens with the plain count" ;; *) fail "doctor alert opens with the plain count (got: $plain)" ;; esac
case "$plain" in *"WARN C23-unlanded: 2 aged unlanded local branch(es)"*) pass "doctor alert carries the check's text" ;; *) fail "doctor alert carries the check's text (got: $plain)" ;; esac
case "$plain" in *"WARN C15-plugins: 3 plugin(s) enabled beyond the lean floor"*) pass "doctor alert carries every new WARN's text" ;; *) fail "doctor alert carries every new WARN's text (got: $plain)" ;; esac
case "$plain" in *"Cause: C33-graph-stale follows from the failing graph cadence"*) pass "doctor alert names the knock-on cause" ;; *) fail "doctor alert names the knock-on cause (got: $plain)" ;; esac
case "$plain" in *". Do: trim enabledPlugins to the lean set. Log: $STATE/last-run.log") pass "doctor alert ends in the next step and the log" ;; *) fail "doctor alert ends in the next step and the log (got: $plain)" ;; esac
rm -f "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel.x"
# a standing backoff alert alone does not explain a stale graph, so C33 keeps its own message.
rm -rf "$STATE" "$HOME/.himmel/state/cadence-alert-sent"; : > "$SENT"
doctor_out "" "C99-base"; run_cad_ok "the backoff baseline run"
mkdir -p "$HOME/.himmel/state/cadence-alert-sent"; : > "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel-backoff.x"
cat > "$STUB_OUT" <<'OUT'
himmel-doctor — Linux

WARN C33-graph-stale: graph stale: 12 commits behind main / last cadence run 5h ago
       → bash scripts/graphify/graph-cadence.sh
OK   C99-fine: fine

Summary: 0 FAIL  1 WARN  0 INFO
OUT
run_cad_ok "the backoff-only run"
plain="$(tail -1 "$SENT")"
case "$plain" in *"follows from the failing graph cadence"*) fail "a backoff-only sentinel is not a knock-on cause (got: $plain)" ;; *"WARN C33-graph-stale: graph stale"*"Do: bash scripts/graphify/graph-cadence.sh"*) pass "a backoff-only sentinel is not a knock-on cause" ;; *) fail "a backoff-only sentinel keeps C33's own step (got: $plain)" ;; esac
rm -f "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel-backoff.x"
# C33 alone, with a failing graph cadence: the knock-on cause shows and the step is still C33's own remedy.
rm -rf "$STATE" "$HOME/.himmel/state/cadence-alert-sent"; : > "$SENT"
doctor_out "" "C99-base"; run_cad_ok "the knock-on baseline run"
mkdir -p "$HOME/.himmel/state/cadence-alert-sent"; : > "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel.x"
cat > "$STUB_OUT" <<'OUT'
himmel-doctor — Linux

WARN C33-graph-stale: graph stale: 12 commits behind main / last cadence run 5h ago FAILED
       → bash scripts/graphify/graph-cadence.sh
OK   C99-fine: fine

Summary: 0 FAIL  1 WARN  0 INFO
OUT
run_cad_ok "the knock-on run"
plain="$(tail -1 "$SENT")"
case "$plain" in *"Cause: C33-graph-stale follows from the failing graph cadence"*". Do: bash scripts/graphify/graph-cadence.sh. Log: "*) pass "a knock-on C33 alone still gives C33's own step" ;; *) fail "a knock-on C33 alone still gives C33's own step (got: $plain)" ;; esac
rm -f "$HOME/.himmel/state/cadence-alert-sent/graph-semantic-himmel.x"

# 8b. a WARN seen in 2 consecutive runs files ONE deduplicated
# Jira ticket (a stubbed jira CLI records every call; nothing leaves the box).
cat > "$W/jira" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$JIRA_LOG"
case "$1" in
    list) cat "$JIRA_LIST_OUT" 2>/dev/null ;;
    create)
        for heading in '## Impact' '## What' '## Why' '## Plan' '## DoD' '## Agent detail'; do
            case "$*" in *"$heading"*) ;; *) exit 1 ;; esac
        done
        echo "HIMMEL-9001" ;;
esac
exit 0
SH
chmod +x "$W/jira"
export JIRA_LOG="$W/jira.log" JIRA_LIST_OUT="$W/jira-list.out" DOCTORCAD_JIRA_CMD="$W/jira"
jira_n() { grep -c "^$1" "$JIRA_LOG" 2>/dev/null || true; }
rm -rf "$STATE"; : > "$JIRA_LOG"; : > "$JIRA_LIST_OUT"
doctor_out "" "C77-stuck"
run_cad
check "a first-seen WARN files no ticket" 0 "$(jira_n create)"
run_cad
check "the same WARN in a 2nd consecutive run files one ticket" 1 "$(jira_n create)"
grep '^create.*C77-stuck' "$JIRA_LOG" >/dev/null && pass "the ticket names the check id" || fail "the ticket names the check id"
grep -e '--sector Visibility --backlog' "$JIRA_LOG" >/dev/null && pass "the ticket is placed in the backlog" || fail "the ticket is placed in the backlog"
run_cad
check "a 3rd run does not file a second ticket" 1 "$(jira_n create)"
# an existing open ticket for the id is extended, not re-filed
rm -rf "$STATE"; : > "$JIRA_LOG"; printf 'HIMMEL-123\tTask\tTo Do\t[doctor] C78-old persists\n' > "$JIRA_LIST_OUT"
doctor_out "" "C78-old"
run_cad; run_cad
check "an existing ticket is not re-filed" 0 "$(jira_n create)"
grep -q '^comment HIMMEL-123' "$JIRA_LOG" && pass "the existing ticket gets a comment" || fail "the existing ticket gets a comment"
# Mirror candidates are searched before the live summary fallback.
export DOCTORCAD_MIRROR_DIR="$W/mirror"
mkdir -p "$DOCTORCAD_MIRROR_DIR"
printf '%s\n' '---' 'statusCategory: "In Progress"' '---' '# HIMMEL-123: Existing tool health work' 'C78-old' > "$DOCTORCAD_MIRROR_DIR/HIMMEL-123.md"
rm -rf "$STATE"; : > "$JIRA_LOG"
run_cad; run_cad
if grep -F 'key = HIMMEL-123' "$JIRA_LOG" >/dev/null; then pass "mirror candidate checked before filing"; else fail "mirror candidate checked before filing"; fi
unset DOCTORCAD_MIRROR_DIR
# a FAIL never files a ticket; a WARN that leaves and returns is not 2 consecutive
rm -rf "$STATE"; : > "$JIRA_LOG"; : > "$JIRA_LIST_OUT"
doctor_out "C16-hooks" ""; run_cad; run_cad
check "a FAIL never files a ticket" 0 "$(jira_n create)"
doctor_out "" "C79-flap"; run_cad
doctor_out "" ""; run_cad
doctor_out "" "C79-flap"; run_cad
check "a WARN that left in between files no ticket" 0 "$(jira_n create)"
# 8c. Hold the first doctor open: an overlapping run must exit cleanly without
# invoking another doctor or filing the same persisting WARN twice.
# A PATH without flock exercises the real Perl/kernel fallback, not a fake lock.
mkdir -p "$W/no-flock-bin"
for tool in awk bash cat date dirname git grep head mkdir mktemp mv perl ps rm sed sleep sort stat touch tr; do
    ln -s "$(command -v "$tool")" "$W/no-flock-bin/$tool"
done
rm -rf "$STATE"; : > "$JIRA_LOG"; : > "$JIRA_LIST_OUT"
doctor_out "" "C80-overlap"; run_cad
: > "$STUB_WHERE"
export STUB_GATE="$W/doctor.release"
PATH="$W/no-flock-bin" run_cad & first_pid=$!
i=0
while [ ! -s "$STUB_WHERE" ] && [ "$i" -lt 100 ]; do sleep 0.05; i=$((i + 1)); done
[ -s "$STUB_WHERE" ] && pass "first concurrent doctor started" || fail "first concurrent doctor started"
# Without timeout, the stub's gate still releases after five seconds.
${_TIMEOUT_BIN:+"$_TIMEOUT_BIN" 3} bash "$P/scripts/doctor-cadence.sh" run >/dev/null 2>&1; overlap_rc=$?
check "overlapping cadence exits cleanly" 0 "$overlap_rc"
check "overlapping cadence does not start a second doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
PATH="$W/no-flock-bin" run_cad; check "Perl flock fallback exits cleanly on overlap" 0 $?
check "Perl flock fallback does not start a second doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
touch "$STUB_GATE"
wait "$first_pid"; check "first concurrent cadence completes" 0 $?
unset STUB_GATE
check "overlapping cadence files one persisting WARN ticket" 1 "$(jira_n create)"
: > "$STUB_WHERE"
run_cad; check "cadence releases its lock after completion" 0 $?
check "subsequent cadence actually invokes the doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
check "subsequent cadence does not re-file the ticket" 1 "$(jira_n create)"
# A dead holder must not silently disable all later daily passes.
kill_cad; check "killed cadence exits with SIGKILL status" 137 $?
: > "$STUB_WHERE"
run_cad; check "cadence can run after a killed holder" 0 $?
check "cadence after a killed holder invokes the doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
: > "$STUB_WHERE"
PATH="$W/no-flock-bin" run_cad; check "Perl flock fallback completes a cadence pass" 0 $?
check "Perl flock fallback actually invokes the doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
PATH="$W/no-flock-bin" kill_cad; check "killed Perl-lock holder exits with SIGKILL status" 137 $?
: > "$STUB_WHERE"
run_cad; check "cadence can run after a killed Perl-lock holder" 0 $?
check "cadence after a killed Perl-lock holder invokes the doctor" 1 "$(wc -l < "$STUB_WHERE" | tr -d ' ')"
unset DOCTORCAD_JIRA_CMD

# 9. statusline segment: renders from a fixture, silent when absent / clean.
SEG_STATE="$W/segstate"; mkdir -p "$SEG_STATE"
seg() { HIMMEL_DOCTOR_STATE_DIR="$SEG_STATE" HIMMEL_WHERE_ARE_WE=off HIMMEL_STATUSLINE_ECON=off \
        bash "$REAL_ROOT/scripts/statusline/hud-custom-lines.sh" </dev/null 2>/dev/null; }
check "segment prints nothing when the state file is absent" "" "$(seg)"
echo "fail=2 warn=5" > "$SEG_STATE/counts"
check "segment renders the FAIL/WARN counts" "himmel-doctor  2 FAIL  5 WARN" "$(seg)"
echo "fail=0 warn=0" > "$SEG_STATE/counts"
check "segment prints nothing when the doctor is clean" "" "$(seg)"
echo "garbage" > "$SEG_STATE/counts"
check "segment prints nothing on a malformed state file" "" "$(seg)"

# 9b. a counts file older than 24 h shows its age; a fresh one does not.
echo "fail=1 warn=12" > "$SEG_STATE/counts"
check "fresh counts show no age" "himmel-doctor  1 FAIL  12 WARN" "$(seg)"
age_file() { perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1]' "$(($(date +%s) - $1))" "$2"; }
age_file 259200 "$SEG_STATE/counts"
check "counts over 24h old show the age in days" "himmel-doctor  1 FAIL  12 WARN (3d old)" "$(seg)"
age_file 108000 "$SEG_STATE/counts"
check "counts 30h old show the age in hours" "himmel-doctor  1 FAIL  12 WARN (30h old)" "$(seg)"
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

# 10b. BSD stat/date accept -f %m and -r <epoch>, not GNU's forms.
REAL_STAT="$(command -v stat)"; REAL_DATE="$(command -v date)"
export REAL_STAT REAL_DATE
mkdir -p "$W/bsd-bin"
cat > "$W/bsd-bin/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -c) exit 1 ;;
    -f) [ "$2" = %m ] || exit 1
        "$REAL_STAT" -c %Y "$3" 2>/dev/null || "$REAL_STAT" -f %m "$3" ;;
    *) exit 1 ;;
esac
SH
cat > "$W/bsd-bin/date" <<'SH'
#!/usr/bin/env bash
case "$1" in
    -d) exit 1 ;;
    -r) case "$2" in ''|*[!0-9]*) exit 1 ;; esac
        "$REAL_DATE" -d "@$2" "$3" 2>/dev/null || "$REAL_DATE" -r "$2" "$3" ;;
    *) "$REAL_DATE" "$@" ;;
esac
SH
chmod +x "$W/bsd-bin/stat" "$W/bsd-bin/date"
perl -e 'utime 172800, 172800, $ARGV[0]' "$STATE/counts"
st="$(TZ=UTC bash "$P/scripts/doctor-cadence.sh" status 2>&1)"
case "$st" in *'(1970-01-03 00:00)'*) pass "native status renders counts mtime" ;; *) fail "native status renders counts mtime ($st)" ;; esac
st="$(PATH="$W/bsd-bin:$PATH" TZ=UTC bash "$P/scripts/doctor-cadence.sh" status 2>&1)"
case "$st" in *'(1970-01-03 00:00)'*) pass "BSD status renders counts mtime" ;; *) fail "BSD status renders counts mtime ($st)" ;; esac
check "BSD stat keeps the HUD counts age" "himmel-doctor  1 FAIL  12 WARN (30h old)" "$(PATH="$W/bsd-bin:$PATH" seg)"

# 11. hardening: a dangling --time fails fast instead of looping;
# a runner dir with a space is quoted in the crontab line; an unreadable
# crontab is never mistaken for an empty one.
if [ -n "$_TIMEOUT_BIN" ]; then
    "$_TIMEOUT_BIN" 5 bash "$P/scripts/doctor-cadence.sh" arm --time >/dev/null 2>&1; rc=$?
    check "arm --time with no value fails fast (no hang)" 1 "$rc"
else
    echo "SKIP arm --time hang guard: no GNU timeout/gtimeout"
fi
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
grep -q 'HIMMEL-Doctor' "$FAKE_CRON"; grep_rc=$?
if [ "$rc" -ne 0 ] && [ "$grep_rc" -eq 1 ]; then pass "an unwritable runner dir fails arm without installing the crontab"; else fail "an unwritable runner dir fails arm without installing the crontab (rc=$rc, grep=$grep_rc)"; fi
DOCTORCAD_RUNNER_DIR="$W/runner2" bash "$P/scripts/doctor-cadence.sh" arm >/dev/null 2>&1
head -1 "$W/runner2/doctor-cadence.sh" | grep -qx '#!/usr/bin/env bash' && pass "the runner uses a bash shebang" || fail "the runner uses a bash shebang"

# a % in the runner path is escaped: cron reads an unescaped % as a newline.
PCT="$W/100%/run"
DOCTORCAD_RUNNER_DIR="$PCT" bash "$P/scripts/doctor-cadence.sh" arm --force >/dev/null 2>&1
grep -qF "\"$W/100\\%/run/doctor-cadence.sh\"" "$FAKE_CRON" && pass "a % in the runner path is escaped in the crontab line" || fail "a % in the runner path is escaped in the crontab line"
DOCTORCAD_RUNNER_DIR="$PCT" bash "$P/scripts/doctor-cadence.sh" disarm >/dev/null 2>&1

# A grep error at the negative assertion must fail the real suite, not count
# as absence. Run it once with that grep call fault-injected (no recursion).
if [ "${DOCTORCAD_TEST_GREP_ERROR:-0}" = 0 ]; then
    REAL_GREP="$(command -v grep)"
    export REAL_GREP
    mkdir -p "$W/grep-bin"
    cat > "$W/grep-bin/grep" <<'SH'
#!/usr/bin/env bash
if [ "$#" -eq 3 ] && [ "$1" = -q ] && [ "$2" = HIMMEL-Doctor ] && [ "$3" = "${FAKE_CRON:-}" ] &&
   "$REAL_GREP" -qx '0 1 \* \* \* keepme' "$3"; then
    exit 2
fi
exec "$REAL_GREP" "$@"
SH
    chmod +x "$W/grep-bin/grep"
    PATH="$W/grep-bin:$PATH" DOCTORCAD_TEST_GREP_ERROR=1 bash "$DIR/test-doctor-cadence.sh" > "$W/grep-error.log" 2>&1; rc=$?
    check "a grep error makes the suite fail" 1 "$rc"
    grep -q '^FAIL an unwritable runner dir fails arm without installing the crontab' "$W/grep-error.log" &&
        pass "a grep error fails the negative assertion" || fail "a grep error fails the negative assertion"
fi

echo
if [ "$FAILED" -eq 0 ]; then echo "test-doctor-cadence: all passed"; exit 0; fi
echo "test-doctor-cadence: $FAILED failed"; exit 1
