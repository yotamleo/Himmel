#!/usr/bin/env bash
# scripts/handover/test-leg-timeline.sh — HIMMEL-1485
#
# Hermetic suite for scripts/handover/leg-timeline.sh. Builds FIXTURE copies of
# each source (worker meta.json, CR ledger JSONL, chain-ledger md) under a temp
# dir and points the script at them via its env overrides — the LIVE sources are
# never touched. Covers: happy path, missing-source degradation, non-UTF8 ledger
# line tolerated, plus since-ts filtering + arg/parse edge cases.
#
# Idiom follows scripts/cr/test-cr-scores.sh: set -uo pipefail, mktemp + trap,
# check/contains/not_contains helpers, ALL PASS / <n> FAILED footer. Prints FULL
# output and an explicit SUITE-EXIT=<rc> line (never tail/head).
#
# bash 3.2-safe (no mapfile/associative arrays). jq + node required.
# shellcheck disable=SC2015  # A && B || C intentional in check()/contains()
set -uo pipefail

# grepq: a `grep -q` against a here-string with NO pipeline. printf|grep -q is a
# trap under `set -o pipefail` (grep -q exits on first match -> SIGPIPE -> the
# pipeline reports failed on a successful match). A here-string is not a pipeline
# so the status is grep's alone. (HIMMEL-1430.)
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

HERE="$(cd "$(dirname "$0")" && pwd)"
LT="$HERE/leg-timeline.sh"

fails=0
check()        { [ "$2" = "$3" ] && echo "ok - $1" || { echo "FAIL - $1: [$2]!=[$3]"; fails=$((fails+1)); }; }
contains()     { grepq "$2" -F "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not contain [$3]"; fails=$((fails+1)); }; }
matches()      { grepq "$2" -E "$3" && echo "ok - $1" || { echo "FAIL - $1: output does not match [$3]"; fails=$((fails+1)); }; }
not_contains() { grepq "$2" -F "$3" && { echo "FAIL - $1: output must NOT contain [$3]"; fails=$((fails+1)); } || echo "ok - $1"; }
ordered()      { case "$2" in *"$3"*"$4"*) echo "ok - $1" ;; *) echo "FAIL - $1: [$3] must precede [$4]"; fails=$((fails+1)) ;; esac; }

# Fixture root under node's os.tmpdir() (Windows-form path), backslashes folded
# to forward slashes so it is safe both in bash and in the script's node calls.
# mktemp(1) under Git Bash returns an MSYS '/tmp/...' path with no drive letter,
# which the script cannot normalize and Node fs rejects — hence node mkdtemp.
ROOT=$(node -e 'const os=require("os"),fs=require("fs"),p=require("path"); process.stdout.write(fs.mkdtempSync(p.join(os.tmpdir(),"legtl-")).replace(/\\/g,"/"))')
trap 'rm -rf "$ROOT"' EXIT
mkdir -p "$ROOT/glm-sessions/glm-fix-1" "$ROOT/glm-sessions/glm-fix-2" \
         "$ROOT/glm-sessions/glm-fix-4" "$ROOT/glm-sessions/glm-fix-0" \
         "$ROOT/claudex-sessions/claudex-fix-3" \
         "$ROOT/state/tester/himmel/specs/plan"

# set_mtime <file> <ISO-ts>: stamp a fixture file's mtime to an exact instant,
# independent of host TZ (node utimesSync takes epoch seconds). The script reads
# the exit/land stamp from meta.json's mtime, so deterministic mtimes make the
# dispatch->land durations assertable.
set_mtime() {
  node -e 'const fs=require("fs"); const t=Date.parse(process.argv[2])/1000; fs.utimesSync(process.argv[1], t, t)' "$1" "$2"
}

# ---------------------------------------------------------------------------
# Fixtures.
# ---------------------------------------------------------------------------

# worker glm-fix-1: done, dispatch 01:00:00Z, land 01:05:00Z -> 5m
cat > "$ROOT/glm-sessions/glm-fix-1/meta.json" <<'EOF'
{"status":"done","pid":111,"started_at":"2026-08-03T01:00:00Z","lane":"glm","task_name":"fix-1","exit_code":0,"timed_out":false}
EOF
set_mtime "$ROOT/glm-sessions/glm-fix-1/meta.json" "2026-08-03T01:05:00Z"

# worker glm-fix-2: running, dispatch 01:10:00Z (never lands -> "still running")
cat > "$ROOT/glm-sessions/glm-fix-2/meta.json" <<'EOF'
{"status":"running","pid":222,"started_at":"2026-08-03T01:10:00Z","lane":"glm","task_name":"fix-2","last_output_at":"2026-08-03T01:11:00Z"}
EOF

# worker glm-fix-0: done but started BEFORE the since-ts window -> must be filtered out
cat > "$ROOT/glm-sessions/glm-fix-0/meta.json" <<'EOF'
{"status":"done","pid":444,"started_at":"2026-08-02T23:00:00Z","lane":"glm","task_name":"fix-0-prewindow","exit_code":0,"timed_out":false}
EOF
set_mtime "$ROOT/glm-sessions/glm-fix-0/meta.json" "2026-08-02T23:02:00Z"

# worker claudex-fix-3: done, dispatch 02:00:00Z, land 02:08:00Z -> 8m, shared_branch
cat > "$ROOT/claudex-sessions/claudex-fix-3/meta.json" <<'EOF'
{"status":"done","pid":333,"started_at":"2026-08-03T02:00:00Z","lane":"codex","task_name":"claudex-fix-3","shared_branch":"claudex/fix-3","exit_code":0,"timed_out":false}
EOF
set_mtime "$ROOT/claudex-sessions/claudex-fix-3/meta.json" "2026-08-03T02:08:00Z"

# worker glm-fix-4: blocked (content-filter), dispatch 02:05:00Z, land 02:06:00Z.
# "blocked" is terminal in spawn-glm.ts finalMeta -> must produce a land row.
cat > "$ROOT/glm-sessions/glm-fix-4/meta.json" <<'EOF'
{"status":"blocked","pid":555,"started_at":"2026-08-03T02:05:00Z","lane":"glm","task_name":"fix-4","exit_code":0}
EOF
set_mtime "$ROOT/glm-sessions/glm-fix-4/meta.json" "2026-08-03T02:06:00Z"

# CR ledger: two rounds of avail+finding on branch claudex/fix-3 @ head ABC1234
cat > "$ROOT/cr-critic-scores.jsonl" <<'EOF'
{"kind":"avail","ts":"2026-08-03T02:01:00Z","branch":"claudex/fix-3","head":"ABC1234","model":"codex","status":"ok"}
{"kind":"avail","ts":"2026-08-03T02:01:30Z","branch":"claudex/fix-3","head":"ABC1234","model":"glm","status":"ok"}
{"kind":"finding","ts":"2026-08-03T02:02:00Z","branch":"claudex/fix-3","head":"ABC1234","model":"codex","finding_id":"c1","severity":"imp","file":"f","line":1,"verdict":"agreed"}
{"kind":"finding","ts":"2026-08-03T02:02:30Z"
{"kind":"usage","ts":"2026-08-03T02:03:00Z","branch":"claudex/fix-3","head":"ABC1234","model":"glm"}
EOF

# chain ledger: header, two timestamped lines, one no-timestamp line (skipped),
# then a line carrying a non-UTF8 byte (0xFF) in its prefix before the timestamp.
cat > "$ROOT/chain-ledger.md" <<'EOF'
# Chain ledger fixture
BASELINE abc123 2026-08-03T01:30:00Z init
NOTE this line has no timestamp and must be skipped
TIE_FIRST 2026-08-03T02:20:00Z stable-one
TIE_SECOND 2026-08-03T02:20:00Z stable-two
PHASE_START P1 2026-08-03T02:30:00Z running
EOF
node -e 'const fs=require("fs"); const b=Buffer.concat([Buffer.from("WEIRD "),Buffer.from([255]),Buffer.from(" tag 2026-08-03T01:45:00Z binary-tolerated\n")]); fs.appendFileSync(process.argv[1], b);' "$ROOT/chain-ledger.md"

cat > "$ROOT/state/tester/himmel/specs/plan/2026-07-28-chain-ledger.md" <<'EOF'
RESOLVED_ROOT 2026-08-03T01:35:00Z via-handover-root
EOF

# Common env override prefix for the script.
ENVOFF="LEG_TIMELINE_WORKER_GLM=$ROOT/glm-sessions LEG_TIMELINE_WORKER_CLAUDEX=$ROOT/claudex-sessions LEG_TIMELINE_CR_LEDGER=$ROOT/cr-critic-scores.jsonl LEG_TIMELINE_CHAIN_LEDGER=$ROOT/chain-ledger.md"

# run_lt: invoke leg-timeline.sh against the full-source fixtures. $ENVOFF is
# INTENTIONALLY word-split into env's VAR=val args — SC2086 disabled for that.
# shellcheck disable=SC2086
run_lt() { env $ENVOFF bash "$LT" "$@"; }

# ===========================================================================
# 1. Happy path — all three sources present, since 2026-08-03T00:00 (UTC).
# ===========================================================================
echo "--- 1. happy path ---"
out=$(run_lt 2026-08-03T00:00 2>&1); rc=$?
check "happy path exit 0" "$rc" "0"
contains "worker dispatch row"            "$out" "dispatch glm done"
contains "worker dispatch claudex(codex)" "$out" "dispatch codex done"
contains "worker land row"                "$out" "land done rc=0"
contains "blocked session gets a land row" "$out" "land blocked"
contains "gate avail row"                 "$out" "avail codex"
contains "gate finding row"               "$out" "finding codex imp"
contains "gate row after torn JSONL line"  "$out" "usage glm"
contains "reports torn CR ledger line"     "$out" "CR ledger malformed rows skipped: 1"
contains "ledger BASELINE event"          "$out" "BASELINE"
contains "ledger PHASE_START event"       "$out" "PHASE_START"
ordered "equal timestamp/source rows retain input order" "$out" "TIE_FIRST" "TIE_SECOND"
contains "summary total span"             "$out" "total span:"
contains "fix-1 dispatch->land = 5m00s"   "$out" "5m00s"
contains "fix-3 dispatch->land = 8m00s"   "$out" "8m00s"
contains "gate run per branch names fix-3" "$out" "claudex/fix-3"
# Bind the metric to the claudex/fix-3 branch on the SAME line: the duration-only
# forms would pass if ANY branch showed 2m00s/1m00s. The summary prints one line per
# branch ("<branch>... run=<d> wait-to-first=<d>"), so identity+metric co-occur there.
matches "gate run for fix-3 = 2m00s"           "$out" 'claudex/fix-3.*run=2m00s'
matches "gate wait-to-first for fix-3 = 1m00s" "$out" 'claudex/fix-3.*wait-to-first=1m00s'
contains "wall-clock summary line"        "$out" "wall-clock:"
contains "waiting percentage"             "$out" "waiting"
contains "running worker flagged never-landed" "$out" "(never landed"
# non-UTF8 ledger line was processed, not dropped/crashed:
contains "non-UTF8 ledger line produced an event (01:45)" "$out" "08-03 01:45"
# pre-window worker was filtered out by since-ts:
not_contains "pre-window worker filtered out" "$out" "fix-0"
# the no-timestamp ledger line did not become an event:
not_contains "no-ts ledger line not emitted"  "$out" "must be skipped"

# Resolve the default chain-ledger path through handover_root + USER_SLUG.
echo "--- 1b. handover-root chain ledger resolution ---"
out=$(env HANDOVER_DIR="$ROOT/state" USER_SLUG=tester \
          LEG_TIMELINE_WORKER_GLM="$ROOT/glm-sessions" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/claudex-sessions" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/cr-critic-scores.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "handover-root resolution exit 0" "$rc" "0"
contains "chain ledger resolved via handover_root" "$out" "RESOLVED_ROOT"

# A failed pure resolution is a reported source gap, not a fatal error.
echo "--- 1c. unresolved handover root degradation ---"
out=$(env HANDOVER_DIR="$ROOT/no-state" USER_SLUG=tester \
          LEG_TIMELINE_WORKER_GLM="$ROOT/glm-sessions" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/claudex-sessions" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/cr-critic-scores.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "unresolved handover root still exit 0" "$rc" "0"
contains "reports unresolved chain ledger" "$out" "chain ledger unresolved via handover_root"

# Re-dispatches onto one shared branch remain distinct dispatch→land sessions.
echo "--- 1d. same-branch re-dispatch pairing ---"
mkdir -p "$ROOT/redispatch-sessions/session-one" "$ROOT/redispatch-sessions/session-two"
cat > "$ROOT/redispatch-sessions/session-one/meta.json" <<'EOF'
{"status":"done","started_at":"2026-08-03T03:00:00Z","lane":"codex","task_name":"round-one","shared_branch":"fix/shared","exit_code":0}
EOF
set_mtime "$ROOT/redispatch-sessions/session-one/meta.json" "2026-08-03T03:03:00Z"
cat > "$ROOT/redispatch-sessions/session-two/meta.json" <<'EOF'
{"status":"done","started_at":"2026-08-03T04:00:00Z","lane":"codex","task_name":"round-two","shared_branch":"fix/shared","exit_code":0}
EOF
set_mtime "$ROOT/redispatch-sessions/session-two/meta.json" "2026-08-03T04:07:00Z"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/no-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/redispatch-sessions" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "same-branch re-dispatch exit 0" "$rc" "0"
matches "first session pairs with its own land" "$out" 'fix/shared \[session-one\] +3m00s'
matches "second session pairs with its own land" "$out" 'fix/shared \[session-two\] +7m00s'

# mktemp -d failure (TMPDIR at a non-existent parent) must be fatal, not silently
# continue with an empty $tmp into "/raw.tsv" (HIMMEL-1485 r4 #1). TMPDIR is the
# script's only mktemp input, so pointing it at a path whose parent does not
# exist is the cheap injection — no scaffolding required.
echo "--- 1e. mktemp failure is fatal ---"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/no-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
          TMPDIR="$ROOT/nonexistent-tmpdir" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
# Contract is "nonzero", not specifically 1 (the script's `exit 1` is incidental).
if [ "$rc" -ne 0 ]; then
  echo "ok - mktemp failure exits nonzero"
else
  echo "FAIL - mktemp failure exits nonzero: rc=$rc (expected nonzero)"; fails=$((fails+1))
fi
contains "mktemp failure error message" "$out" "mktemp -d failed"

# ===========================================================================
# 2. Missing-source degradation — CR ledger points at a nonexistent path.
#    The script must report the gap and still run over worker + ledger sources.
# ===========================================================================
echo "--- 2. missing-source degradation ---"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/glm-sessions" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/claudex-sessions" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/does-not-exist.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/chain-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "missing source still exit 0" "$rc" "0"
contains "reports missing CR ledger"   "$out" "CR ledger missing:"
contains "worker source still works"   "$out" "dispatch glm done"
contains "ledger source still works"   "$out" "BASELINE"
not_contains "gate source absent"      "$out" "avail codex"

# All three sources missing -> still exit 0, gap report lists all three, no crash.
echo "--- 2b. all sources missing ---"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/no-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "all-missing still exit 0" "$rc" "0"
contains "all-missing reports glm dir"    "$out" "worker(glm) dir missing"
contains "all-missing reports claudex dir" "$out" "worker(claudex) dir missing"
contains "all-missing reports CR ledger"  "$out" "CR ledger missing"
contains "all-missing reports chain ledger" "$out" "chain ledger missing"
contains "all-missing graceful empty msg" "$out" "no events in window"

# ===========================================================================
# 3. Non-UTF8 ledger line tolerated — a ledger whose ONLY timestamped line
#    carries a 0xFF byte right before the timestamp still yields its event.
# ===========================================================================
echo "--- 3. non-UTF8 ledger line tolerated ---"
mkdir -p "$ROOT/utf8-glm/u1"
cat > "$ROOT/utf8-glm/u1/meta.json" <<'EOF'
{"status":"done","pid":9,"started_at":"2026-08-03T01:40:00Z","lane":"glm","task_name":"u1","exit_code":0,"timed_out":false}
EOF
set_mtime "$ROOT/utf8-glm/u1/meta.json" "2026-08-03T01:41:00Z"
printf '# utf8 ledger fixture\n' > "$ROOT/utf8-ledger.md"
node -e 'const fs=require("fs"); const b=Buffer.concat([Buffer.from("ONLY "),Buffer.from([255,254]),Buffer.from(" line 2026-08-03T01:50:00Z survives\n")]); fs.appendFileSync(process.argv[1], b);' "$ROOT/utf8-ledger.md"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/utf8-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/utf8-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "non-utf8 ledger exit 0" "$rc" "0"
contains "non-utf8 ledger event survives" "$out" "08-03 01:50"
contains "non-utf8 ledger row content emitted" "$out" "ONLY �� line"

# ===========================================================================
# 4. Edge cases.
# ===========================================================================
echo "--- 4. edge cases ---"
# No since-ts arg -> usage, non-zero exit.
out=$(bash "$LT" 2>&1); rc=$?
check "no-arg non-zero exit" "$rc" "1"
contains "no-arg prints usage" "$out" "Usage:"
# Unparseable since-ts -> error, non-zero exit.
out=$(run_lt "not-a-date" 2>&1); rc=$?
check "bad since-ts non-zero exit" "$rc" "1"
contains "bad since-ts error" "$out" "could not parse"
# Date-only since-ts means UTC midnight, not an invalid YYYY-MM-DDZ timestamp.
out=$(run_lt 2026-08-03 2>&1); rc=$?
check "date-only since-ts exit 0" "$rc" "0"
contains "date-only since-ts includes post-midnight event" "$out" "fix-1"
# Offset-less since-ts read as UTC, not local: 2026-08-03T00:00 (no Z) must match
# the explicit-Z form (fix-1 @ 01:00:00Z is included in both; on a non-UTC host a
# local-misread would push 00:00 PAST 01:00Z and filter fix-1 out).
out_z=$(run_lt 2026-08-03T00:00Z 2>&1)
out_noz=$(run_lt 2026-08-03T00:00 2>&1)
if grepq "$out_z" -F "fix-1" && grepq "$out_noz" -F "fix-1"; then
  echo "ok - offset-less since-ts treated as UTC (fix-1 in both)"
else
  echo "FAIL - offset-less since-ts treated as UTC (fix-1 in both)"; fails=$((fails+1))
fi

# ===========================================================================
# 5. Pre-window dispatch pairing (HIMMEL-1485 r5 #1). A worker dispatched
#    BEFORE since-ts that LANDS inside the window must still appear in the
#    dispatch→land + worker-active summaries (marked "dispatched pre-window"),
#    while its pre-window dispatch row stays out of the displayed table.
# ===========================================================================
echo "--- 5. pre-window dispatch pairing ---"
mkdir -p "$ROOT/prewin-sessions/handed-over" "$ROOT/prewin-sessions/fresh"
# handed-over: dispatched 2026-08-02T23:00:00Z (pre-window), lands 00:20:00Z.
cat > "$ROOT/prewin-sessions/handed-over/meta.json" <<'EOF'
{"status":"done","started_at":"2026-08-02T23:00:00Z","lane":"glm","task_name":"handed","exit_code":0}
EOF
set_mtime "$ROOT/prewin-sessions/handed-over/meta.json" "2026-08-03T00:20:00Z"
# fresh: dispatched + landed fully in-window (bounds the window + baseline union).
cat > "$ROOT/prewin-sessions/fresh/meta.json" <<'EOF'
{"status":"done","started_at":"2026-08-03T01:00:00Z","lane":"glm","task_name":"fresh","exit_code":0}
EOF
set_mtime "$ROOT/prewin-sessions/fresh/meta.json" "2026-08-03T01:05:00Z"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/prewin-sessions" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "pre-window pairing exit 0" "$rc" "0"
contains "handed-over appears in dispatch->land" "$out" "handed-over"
contains "handed-over full duration 1h20m" "$out" "1h20m"
contains "handed-over marked dispatched pre-window" "$out" "(dispatched pre-window)"
not_contains "pre-window dispatch row absent from table" "$out" "08-02 23:00"
contains "handed-over in-window land shown in table" "$out" "08-03 00:20"
# worker-active = handed-over in-window [00:00,00:20]=20m + fresh [01:00,01:05]=5m
# = 25m. Without the fix handed-over is dropped entirely -> worker-active 5m00s.
contains "worker-active includes handed-over (25m00s)" "$out" "worker-active 25m00s"

# ===========================================================================
# 6. Lowercase-z timestamp normalization (HIMMEL-1485 r5 #2). An event row
#    whose ISO ts ends in a lowercase "z" must normalize to valid UTC, not be
#    re-suffixed into an invalid "zZ" that Date.parse drops.
# ===========================================================================
echo "--- 6. lowercase-z normalization ---"
mkdir -p "$ROOT/lowz-sessions/lowz-1"
# started_at ends in lowercase "z"; its dispatch row must survive normalization.
cat > "$ROOT/lowz-sessions/lowz-1/meta.json" <<'EOF'
{"status":"done","started_at":"2026-08-03T01:00:00z","lane":"glm","task_name":"lowz","exit_code":0}
EOF
set_mtime "$ROOT/lowz-sessions/lowz-1/meta.json" "2026-08-03T01:05:00Z"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/lowz-sessions" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "lowercase-z exit 0" "$rc" "0"
# The lowercase-z dispatch at 01:00:00z normalizes to 01:00:00Z and is shown
# (not dropped). Without the fix it became "...zZ" -> NaN -> the row vanished.
contains "lowercase-z dispatch row shown (not dropped)" "$out" "08-03 01:00:00"
# Pairing needs both dispatch + land; without the fix the dispatch dropped and
# no dispatch->land duration would be emitted.
# Bind the duration to the lowz worker identity + its land label on the SAME
# dispatch->land row ("<leg> [<session>]  <dur> (land <status>)"): the bare
# "5m00s" form would pass if ANY worker showed that duration.
matches "lowercase-z worker pairs lowz [lowz-1] land 5m00s" "$out" 'lowz \[lowz-1\] +5m00s \(land'

# ===========================================================================
# 7. Fractional-second + explicit offset in a chain-ledger stamp (HIMMEL-1485
#    r7 #1). A stamp like 2026-08-03T13:40:00.5+02:00 must keep its offset:
#    without the (?:\.\d+)? clause the capture truncates before ".5+02:00",
#    silently stripping the offset so r5 normalization misreads it as UTC.
#    +02:00 -> 13:40:00.5 local == 11:40:00Z. Ledger-only run (no workers).
# ===========================================================================
echo "--- 7. fractional-second offset honored ---"
printf '# fractional-second offset fixture\n' > "$ROOT/frac-ledger.md"
printf 'FRAC_OFFSET 2026-08-03T13:40:00.5+02:00 honors-offset\n' >> "$ROOT/frac-ledger.md"
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/no-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/no-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/frac-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "fractional-offset exit 0" "$rc" "0"
contains "fractional-offset event shown (prefix survives)" "$out" "FRAC_OFFSET"
# offset honored -> displayed at 11:40 UTC; stripped (bug) -> misread as 13:40 UTC.
contains "offset honored -> 11:40 UTC" "$out" "08-03 11:40:00"
not_contains "offset stripped misread as 13:40 UTC" "$out" "08-03 13:40:00"

# ===========================================================================
# 8. Gate branch containing '@' shown intact (HIMMEL-1485 r7 #2). The gate
#    label is <branch>@<head-7>; the per-branch summary extracts the branch by
#    splitting on the LAST '@' (the head suffix), so a branch name that itself
#    contains '@' survives. Splitting on the FIRST '@' truncated it.
# ===========================================================================
echo "--- 8. gate branch containing '@' shown intact ---"
cat > "$ROOT/at-cr.jsonl" <<'EOF'
{"kind":"avail","ts":"2026-08-03T02:01:00Z","branch":"feat/x@y","head":"ABC1234","model":"codex","status":"ok"}
{"kind":"finding","ts":"2026-08-03T02:02:00Z","branch":"feat/x@y","head":"ABC1234","model":"codex","finding_id":"c1","severity":"imp","file":"f","line":1,"verdict":"agreed"}
EOF
out=$(env LEG_TIMELINE_WORKER_GLM="$ROOT/no-glm" \
          LEG_TIMELINE_WORKER_CLAUDEX="$ROOT/no-claudex" \
          LEG_TIMELINE_CR_LEDGER="$ROOT/at-cr.jsonl" \
          LEG_TIMELINE_CHAIN_LEDGER="$ROOT/no-ledger.md" \
      bash "$LT" 2026-08-03T00:00 2>&1); rc=$?
check "'@'-branch exit 0" "$rc" "0"
contains "gate avail row for '@'-branch" "$out" "avail codex"
# gate-run line prints the extracted branch name; with the fix the full
# "feat/x@y" survives on the run= line (first-'@' split would truncate to "feat/x").
matches "'@'-branch shown intact in gate run" "$out" 'feat/x@y.*run='

# ===========================================================================
# Footer.
# ===========================================================================
rc=0
if [ "$fails" -eq 0 ]; then
  echo "ALL PASS"
else
  echo "$fails FAILED"
  rc=1
fi
echo "SUITE-EXIT=$rc"
exit "$rc"
