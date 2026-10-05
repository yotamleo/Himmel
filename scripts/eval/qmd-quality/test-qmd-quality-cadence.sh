#!/usr/bin/env bash
# test-qmd-quality-cadence.sh - qmd-quality-cadence.sh (HIMMEL-4184): the weekly
# qmd-quality run, its metrics log, the MRR-drop alert and the cron arm/disarm.
# Hermetic: every state/alert/crontab/runner seam points into a mktemp dir, the
# eval is a stub, the Telegram sender is a stub. Never arms anything on the
# real station and never sends a message.
# Exit: 0 = all pass, 1 = a case failed.
# shellcheck disable=SC2015  # `A && pass || fail`: pass always succeeds
set -uo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
REAL_ROOT="$(cd "$DIR/../../.." && pwd)"
PASSED=0; FAILED=0
pass() { echo "PASS $1"; PASSED=$((PASSED + 1)); }
fail() { echo "FAIL $1"; FAILED=$((FAILED + 1)); }
# check <label> <expected> <actual>
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (want '$2', got '$3')"; fi; }
has() { if grep -qF -- "$2" "$3" 2>/dev/null; then pass "$1"; else fail "$1 (no '$2' in $3)"; fi; }

W="$(mktemp -d "${TMPDIR:-/tmp}/qmdqual-cad.XXXXXX")" || exit 1
trap 'rm -rf "$W"' EXIT
export HOME="$W/home"; mkdir -p "$HOME"

# A primary checkout carrying the script under test and the alert sink.
P="$W/primary"
mkdir -p "$P/scripts/eval/qmd-quality" "$P/scripts/luna"
git init -q "$P"
cp "$DIR/qmd-quality-cadence.sh" "$P/scripts/eval/qmd-quality/" 2>/dev/null || true
cp "$REAL_ROOT/scripts/luna/cadence-alert.sh" "$P/scripts/luna/"
git -C "$P" add -A
git -C "$P" -c user.name=t -c user.email=t@t commit -q -m fixture
CAD="$P/scripts/eval/qmd-quality/qmd-quality-cadence.sh"

# Stub eval: writes scores.tsv from $STUB_MRR ("<mode> <mrr>" per line), drops a
# dummy snapshot, exits $STUB_RC (default 0). STUB_NOALL drops the ALL rows.
cat > "$W/eval.sh" <<'SH'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do case "$1" in --out) out="$2"; shift 2 ;; *) shift ;; esac; done
mkdir -p "$out"; : > "$out/index.sqlite"
# STUB_KILL: SIGTERM the cadence run while the eval is in flight.
if [ -n "${STUB_KILL:-}" ]; then kill -TERM "$PPID"; exit 0; fi
rc="$(cat "$STUB_RC" 2>/dev/null || echo 0)"
[ "$rc" -eq 0 ] || { echo "boom" >&2; exit "$rc"; }
{
    printf 'mode\tcollection\tn\thit@1\thit@5\tmrr\tmissing\n'
    while read -r mode mrr; do
        if [ -z "${STUB_NOALL:-}" ]; then printf '%s\tALL\t10\t0.500\t0.800\t%s\t0\n' "$mode" "$mrr"; fi
        printf '%s\tluna\t10\t0.500\t0.800\t%s\t0\n' "$mode" "$mrr"
    done < "$STUB_MRR"
} > "$out/scores.tsv"
SH
chmod +x "$W/eval.sh"
SENT="$W/sent.log"; : > "$SENT"
cat > "$W/send.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$SENT"
SH
chmod +x "$W/send.sh"

STATE="$W/state"
export SENT STUB_RC="$W/rc" STUB_MRR="$W/mrr" QMD_QUALITY_EVAL_CMD="$W/eval.sh" \
    QMD_QUALITY_STATE_DIR="$STATE" CADENCE_ALERT_FILE="$W/alerts.log" \
    CADENCE_ALERT_DEDUPE_DIR="$W/dedupe" CADENCE_ALERT_SEND_CMD="$W/send.sh"
GOLD="$W/golden.jsonl"; IDX="$W/index.sqlite"; : > "$GOLD"; : > "$IDX"
sent_n() { wc -l < "$SENT" | tr -d ' '; }
n_runs() { local n=0 d; for d in "$STATE"/runs/*/; do [ -d "$d" ] && n=$((n + 1)); done; echo "$n"; }
run_cad() { QMD_QUALITY_TS="$1" bash "$CAD" run --golden "$GOLD" --index "$IDX" >/dev/null 2>&1; }
set_mrr() { printf 'lex %s\nhybrid %s\n' "$1" "$2" > "$STUB_MRR"; }

# 1. first run: header + one row per mode, no send, snapshot removed.
set_mrr 0.600 0.800
run_cad 20260101T000001Z; check "first run exits 0" 0 $?
check "metrics.tsv has header + 2 rows" 3 "$(wc -l < "$STATE/metrics.tsv" | tr -d ' ')"
check "metrics header" "$(printf 'ts\tmode\tn\thit@1\thit@5\tmrr')" "$(head -1 "$STATE/metrics.tsv")"
check "first run is a baseline (no send)" 0 "$(sent_n)"
[ ! -e "$STATE/runs/20260101T000001Z/index.sqlite" ] && pass "snapshot removed after success" || fail "snapshot removed after success"

# 2. a 0.10 drop in one mode alerts naming it.
set_mrr 0.500 0.800
run_cad 20260102T000001Z
check "mrr drop sends one alert" 1 "$(sent_n)"
has "alert names mode with prev->cur" "lex 0.600->0.500" "$SENT"
has "alert log has mrr-drop line" "qmd-quality mrr-drop" "$W/alerts.log"

# 3. a drop of exactly 0.05 does not alert.
set_mrr 0.450 0.800
run_cad 20260103T000001Z
check "drop of exactly 0.05 sends nothing" 1 "$(sent_n)"

# 4. eval failure: rc 1, eval-rc-2 alert, snapshot removed, metrics unchanged.
before="$(cat "$STATE/metrics.tsv")"
echo 2 > "$STUB_RC"
QMD_QUALITY_TS=20260104T000001Z bash "$CAD" run --golden "$GOLD" --index "$IDX" >/dev/null 2>&1; check "eval failure returns 1" 1 $?
has "eval-rc-2 alert logged" "qmd-quality eval-rc-2" "$W/alerts.log"
[ ! -e "$STATE/runs/20260104T000001Z/index.sqlite" ] && pass "snapshot removed after failure" || fail "snapshot removed after failure"
check "metrics.tsv unchanged on failure" "$before" "$(cat "$STATE/metrics.tsv")"
echo 0 > "$STUB_RC"

# 5. no ALL row.
STUB_NOALL=1 run_cad 20260105T000001Z
has "no-scores alert logged" "qmd-quality no-scores" "$W/alerts.log"

# 6. prune.
set_mrr 0.450 0.800
QMD_QUALITY_KEEP_RUNS=2 run_cad 20260106T000001Z
check "prune keeps 2 run dirs" 2 "$(n_runs)"
[ -d "$STATE/runs/20260106T000001Z" ] && pass "newest run dir kept" || fail "newest run dir kept"

# 7. run without golden / index -> 64.
bash "$CAD" run --index "$IDX" >/dev/null 2>&1; check "run without golden exits 64" 64 $?
bash "$CAD" run --golden "$GOLD" >/dev/null 2>&1; check "run without index exits 64" 64 $?
# a golden set gone since arm must not fail silently in a cron log.
bash "$CAD" run --golden "$W/gone.jsonl" --index "$IDX" >/dev/null 2>&1
has "missing golden alerts" "qmd-quality missing-input" "$W/alerts.log"

# 6b. failed runs are pruned too.
echo 2 > "$STUB_RC"
QMD_QUALITY_KEEP_RUNS=2 run_cad 20260107T000001Z
QMD_QUALITY_KEEP_RUNS=2 run_cad 20260108T000001Z
check "failed runs pruned to 2" 2 "$(n_runs)"
echo 0 > "$STUB_RC"

# 6b2. a run terminated mid-eval (cron kill, shutdown) still removes its snapshot.
STUB_KILL=1 run_cad 20260108T500001Z; check "terminated run exits 143" 143 $?
[ ! -e "$STATE/runs/20260108T500001Z/index.sqlite" ] && pass "snapshot removed after SIGTERM" || fail "snapshot removed after SIGTERM"

# 6c. an unwritable metrics.tsv must not pass silently.
chmod 444 "$STATE/metrics.tsv"
run_cad 20260109T000001Z; check "metrics write failure exits 2" 2 $?
has "metrics write failure alerts" "qmd-quality metrics-write" "$W/alerts.log"
chmod 644 "$STATE/metrics.tsv"

# 8. arm / status / disarm through a stub crontab.
cat > "$W/crontab" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-l" ]; then cat "$FAKE_CRON" 2>/dev/null || { echo "no crontab for t" >&2; exit 1; }
else cat > "$FAKE_CRON"; fi
SH
chmod +x "$W/crontab"
export FAKE_CRON="$W/cron.tab" QMDQUAL_CRONTAB="$W/crontab" QMDQUAL_RUNNER_DIR="$W/runner"
RUNNER="$W/runner/qmd-quality-cadence.sh"
out="$(bash "$CAD" arm --golden "$GOLD" --index "$IDX" --day 3 --time 07:15 --dry-run 2>&1)"
case "$out" in "DRY qmd-quality-cadence: would write $RUNNER and install: 15 07 * * 3 \"$RUNNER\" # HIMMEL-Qmd-Quality") pass "dry-run prints the entry" ;; *) fail "dry-run prints the entry ($out)" ;; esac
[ ! -e "$RUNNER" ] && [ ! -e "$FAKE_CRON" ] && pass "dry-run writes nothing" || fail "dry-run writes nothing"
if bash "$CAD" arm --index "$IDX" >/dev/null 2>&1; then fail "arm without golden refuses"; else pass "arm without golden refuses"; fi
if bash "$CAD" arm --golden "$GOLD" --index "$IDX" --time 25:00 >/dev/null 2>&1; then fail "bad --time refuses"; else pass "bad --time refuses"; fi
if bash "$CAD" arm --golden "$GOLD" --index "$IDX" --day 7 >/dev/null 2>&1; then fail "bad --day refuses"; else pass "bad --day refuses"; fi
bash "$CAD" arm --golden "$GOLD" --index "$IDX" >/dev/null 2>&1; check "arm exits 0" 0 $?
has "crontab carries the tag" "# HIMMEL-Qmd-Quality" "$FAKE_CRON"
has "default entry is Sunday 06:00" "00 06 * * 0 " "$FAKE_CRON"
has "runner holds the golden path" "$GOLD" "$RUNNER"
has "runner holds the index path" "$IDX" "$RUNNER"
bash "$CAD" arm --golden "$GOLD" --index "$IDX" >/dev/null 2>&1; check "re-arm without --force exits 3" 3 $?
st="$(bash "$CAD" status 2>&1)"
case "$st" in ARMED*) pass "status reports ARMED" ;; *) fail "status reports ARMED ($st)" ;; esac
case "$st" in *hybrid*) pass "status prints the last run's rows" ;; *) fail "status prints the last run's rows ($st)" ;; esac
bash "$CAD" disarm >/dev/null 2>&1; check "disarm exits 0" 0 $?
grep -q 'HIMMEL-Qmd-Quality' "$FAKE_CRON"; check "disarm removes the entry" 1 $?
[ ! -e "$RUNNER" ] && pass "disarm removes the runner" || fail "disarm removes the runner"

echo
echo "$PASSED passed, $FAILED failed"
[ "$FAILED" -eq 0 ]
