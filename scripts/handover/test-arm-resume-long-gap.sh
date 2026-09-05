#!/usr/bin/env bash
# HIMMEL-1475 long-gap guard twin for scripts/handover/arm-resume.sh.
#
# arm-resume now REFUSES (rc=9) an explicit --time HH:MM more than 60 min out
# unless --long-gap sanctions the park (the ALWAYS-CONTINUE directive: an
# orchestrator leg arms <=30-60 min out while work remains). This twin covers
# the gap arithmetic (incl. the midnight wrap), the refusal path, the
# --long-gap pass-through, the <=60 min silent path, the ARM_RESUME_SAFETY_ARM=1
# safety-arm exemption (auto-arm-on-cap.sh's stale-cache escalation + spawn-glm
# cap-respawn arm at a multi-hour cap reset and cannot pass --long-gap;
# --dedup-any alone does NOT exempt — LG5b), the raw-seconds gap floor (LG7),
# and the long_gap audit field.
#
# Kept SEPARATE from the (large) test-arm-resume.sh, same rationale as the
# identity/proxy/queue-lock twins. Uses --dry-run throughout so no real
# scheduler jobs are created, EXCEPT the audit-field cases (LG6a/LG6b) which
# need a real (stubbed) arm so the telemetry "armed" record is emitted.
set -uo pipefail

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic shields — same set test-arm-resume.sh uses so the assertions below
# are not skewed by the operator's shell.
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
unset ARM_NAME_TEMPLATE 2>/dev/null || true
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
# Temp-target shield (HIMMEL-1365/1622): fixtures live under $TMP, the exact
# shape arm-resume now refuses (exit 12). Scheduler is stubbed — no real task
# is ever created. Same declared opt-out as test-arm-resume.sh; missing it
# cost 7 failures first caught by the public wave-2k CI.
export ARM_TEMP_CWD_OK=1

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
assert_rc() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label — expected rc=$expected, got rc=$actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label — output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}

assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label — output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

FAILED=0

# ---------------------------------------------------------------------------
# Fixture setup (mirrors test-arm-resume.sh)
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

make_handover() {
    local cwd_val="${1:-}"
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        [ -n "$cwd_val" ] && printf 'resume_cwd: %s\n' "$cwd_val"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# Empty-scheduler stub (the SCHED_STUB_T17 pattern): every backend exits 0
# with no jobs, so list_existing / dedup never blocks and the guard is the
# only thing under test.
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
# HIMMEL-1879: /create must actually register something. A stub that reports
# success and then answers every /query with an empty scheduler is internally
# inconsistent, and the post-arm existence verify reads it (correctly) as "the
# create armed nothing" -> rc 2, so the telemetry cases below never see an arm.
# The verify asks the SAME oracle the pre-arm dedup asks, so a stub honest
# enough for dedup is honest enough for it. Real `/create /f` overwrite-in-place
# semantics; state starts empty.
cat > "$SCHED_STUB/schtasks" <<EOF
#!/usr/bin/env bash
db="$TMP/sched-stub.tasks"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create|/delete)
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        [ "\$cmd" = /create ] && printf '%s\\n' "\$tn" >> "\$db"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$SCHED_STUB/atq" <<EOF
#!/usr/bin/env bash
d="$TMP/sched-stub.atdir"; [ -d "\$d" ] || exit 0
for f in "\$d"/job-*; do
    [ -f "\$f" ] || continue
    printf '%s\\tThu Jun 11 09:00:00 2026 a user\\n' "\${f##*/job-}"
done
exit 0
EOF
cat > "$SCHED_STUB/at" <<EOF
#!/usr/bin/env bash
d="$TMP/sched-stub.atdir"; mkdir -p "\$d"
case "\${1:-}" in
    -c) cat "\$d/job-\${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=\$(cat "\$d/.counter" 2>/dev/null || echo 0); n=\$((n + 1))
        printf '%s' "\$n" > "\$d/.counter"
        cat > "\$d/job-\$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$SCHED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SCHED_STUB/schtasks" "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/powershell"

# Armed stub (the ARMED_STUB pattern): a non-dry-run arm completes on any
# platform without touching the real scheduler, so the "armed" telemetry
# record is emitted. TMPDIR pinned so a windows .bat lands under $TMP.
# HIMMEL-1879: /create must REGISTER what it was given -- a stub that reports
# success and then answers every /query empty is internally inconsistent, and
# the post-arm existence verify reads that (correctly) as an arm that armed
# nothing (rc 2), so no "armed" telemetry line is ever written. Own state file,
# separate from $SCHED_STUB's, so the two stubs cannot see each other's tasks.
ARMED_STUB="$TMP/armed-stub"
mkdir -p "$ARMED_STUB"
cat > "$ARMED_STUB/schtasks" <<EOF
#!/usr/bin/env bash
db="$TMP/armed-stub.tasks"
cmd="\${1:-}"; shift || true
tn=""
while [ \$# -gt 0 ]; do
    case "\$1" in
        /tn)   tn="\${2:-}"; shift 2 ;;
        /tn=*) tn="\${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "\$cmd" in
    /query)
        [ -f "\$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "\$t" ] && printf '"\\\\%s","2026-01-01","Ready"\\n' "\$t"
        done < "\$db"
        exit 0 ;;
    /create|/delete)
        if [ -f "\$db" ]; then
            grep -vFx "\$tn" "\$db" > "\$db.tmp" 2>/dev/null || : > "\$db.tmp"
            mv "\$db.tmp" "\$db"
        fi
        [ "\$cmd" = /create ] && printf '%s\\n' "\$tn" >> "\$db"
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/atq" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; [ -d "\$d" ] || exit 0
for f in "\$d"/job-*; do
    [ -f "\$f" ] || continue
    printf '%s\\tThu Jun 11 09:00:00 2026 a user\\n' "\${f##*/job-}"
done
exit 0
EOF
cat > "$ARMED_STUB/at" <<EOF
#!/usr/bin/env bash
d="$TMP/armed-stub.atdir"; mkdir -p "\$d"
case "\${1:-}" in
    -c) cat "\$d/job-\${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=\$(cat "\$d/.counter" 2>/dev/null || echo 0); n=\$((n + 1))
        printf '%s' "\$n" > "\$d/.counter"
        cat > "\$d/job-\$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$ARMED_STUB/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$ARMED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$ARMED_STUB/schtasks" "$ARMED_STUB/atq" "$ARMED_STUB/at" "$ARMED_STUB/claude" "$ARMED_STUB/powershell"

# Gap fixtures, computed relative to real now (the guard's `now` is captured
# a fraction of a second later, so the gaps below hold for this fast twin):
#   FAR    ~3h out  -> gap ~180 min  (>60 -> refused without --long-gap)
#   NEAR   ~5m out  -> gap ~5 min    (<=60 -> silent)
#   WRAP   ~10m AGO -> rolls to tomorrow -> gap ~1430 min (midnight wrap, MUST
#                     be a large POSITIVE gap, never negative: a broken wrap
#                     would yield ~-10 min -> <=60 -> not refused -> LG4 fails)
FAR_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(hours=3)).strftime("%H:%M"))')
# NEAR is a FUNCTION, not a captured value, and its lead is 20 min, not 5
# (HIMMEL-1879 / HIMMEL-1756). Both halves answer the same failure: a captured
# +5 min target expires long before the last use, then reads as past-for-today,
# rolls to TOMORROW, lands >60 min out, and is refused rc=9 by the very guard
# the case is trying to show STAYING SILENT (LG6b, 3x on unmodified main under
# box load, 2026-08-12; again 2026-08-20). Recomputing per use keeps "near"
# actually near however long the run took to get here, and 20 minutes absorbs
# the slow part that recomputation alone cannot: arm-resume runs the live-worker
# census BEFORE it parses --time, so on a loaded box that preamble by itself can
# outlast a 5-minute target between the call and its consumption. 20 min is
# still comfortably inside the 60-minute ceiling, so long_gap=0 is unchanged.
# FAR/WRAP are deliberately still captured once -- their whole point is a fixed
# distance. LG-fix below pins both halves so this cannot silently regress.
near_hhmm() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=20)).strftime("%H:%M"))'; }
WRAP_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()-datetime.timedelta(minutes=10)).strftime("%H:%M"))')

# ---------------------------------------------------------------------------
# LG1: gap > 60 min, no --long-gap -> REFUSED (rc 9) + the loud WARN.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$FAR_HHMM" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "LG1 far HH:MM refused without --long-gap (rc 9)" 9 "$rc"
assert_contains "LG1 WARN asks if the queue is empty" "is the queue actually empty" "$out"
assert_contains "LG1 WARN cites the ALWAYS-CONTINUE directive" "ALWAYS-CONTINUE" "$out"
assert_contains "LG1 WARN names the --long-gap escape" "--long-gap" "$out"
assert_contains "LG1 WARN reports the gap as NhMm out" "m out" "$out"
assert_contains "LG1 WARN names the requested time" "out ($FAR_HHMM)" "$out"

# ---------------------------------------------------------------------------
# LG2: gap <= 60 min -> SILENT, unchanged behavior (rc 0, no WARN).
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$(near_hhmm)" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "LG2 near HH:MM proceeds silently (rc 0)" 0 "$rc"
assert_not_contains "LG2 no long-gap WARN on a near arm" "is the queue actually empty" "$out"
assert_not_contains "LG2 no rc-9 refusal text on a near arm" "rc=9" "$out"

# ---------------------------------------------------------------------------
# LG3: --long-gap sanctions a far park -> proceeds (rc 0, no WARN).
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$FAR_HHMM" --handover "$HO" --long-gap --dry-run 2>&1)
rc=$?
assert_rc "LG3 far HH:MM + --long-gap proceeds (rc 0)" 0 "$rc"
assert_not_contains "LG3 no refusal under --long-gap" "is the queue actually empty" "$out"
assert_not_contains "LG3 no rc-9 refusal text under --long-gap" "rc=9" "$out"

# ---------------------------------------------------------------------------
# LG4: midnight wrap — a time ~10 min AGO rolls to tomorrow, so the gap is a
#      large POSITIVE value (~1430 min) and the arm is REFUSED. A broken wrap
#      (no +1 day) would compute a ~-10 min gap -> <=60 -> NOT refused, failing
#      this case. This is the "550 min, not negative" correctness guard.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$WRAP_HHMM" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "LG4 past-time wrap refused (positive gap, rc 9)" 9 "$rc"
assert_contains "LG4 wrap refusal still cites the directive" "ALWAYS-CONTINUE" "$out"
# HIMMEL-2247: the rolled path must carry BOTH messages. The ALWAYS-CONTINUE
# WARN is the guardrail citation; the HIMMEL-2147 "already past for today" ERR
# line is the up-front rollover context. A regression that drops either one
# (e.g. re-making them an if/else) fails here.
assert_contains "LG4 wrap refusal still asks if the queue is empty" "is the queue actually empty" "$out"
assert_contains "LG4 wrap refusal names the rollover up front" "already past for today" "$out"
# HIMMEL-2247 (CR round 1): ORDER is the contract, not just presence. The
# HIMMEL-2147 rollover line must come UP FRONT, PREFIXING the WARN — the
# regression was exactly a swap of prefix for replace. This pattern also
# pins the FULL citation text, which a bare "ALWAYS-CONTINUE" match does not.
case "$out" in
    *"already past for today"*"ALWAYS-CONTINUE directive says arm <=30-60 min while work remains"*)
        lg4_order="ROLLOVER-FIRST" ;;
    *) lg4_order="WARN-FIRST-OR-MISSING" ;;
esac
assert_contains "LG4 rollover context precedes the full ALWAYS-CONTINUE citation" "ROLLOVER-FIRST" "$lg4_order"

# ---------------------------------------------------------------------------
# LG5: ARM_RESUME_SAFETY_ARM=1 (automated safety arm) is EXEMPT — a far HH:MM
#      proceeds without --long-gap. auto-arm-on-cap.sh's stale-cache escalation
#      and spawn-glm's cap-respawn arm at a multi-hour cap reset under this env
#      var and cannot pass --long-gap, so the guard must not block it.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" ARM_RESUME_SAFETY_ARM=1 bash "$ARM" --time "$FAR_HHMM" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "LG5 ARM_RESUME_SAFETY_ARM=1 far arm exempt from the guard (rc 0)" 0 "$rc"
assert_not_contains "LG5 no refusal on a safety-arm env" "is the queue actually empty" "$out"

# ---------------------------------------------------------------------------
# LG5b: --dedup-any ALONE (no ARM_RESUME_SAFETY_ARM) does NOT bypass the guard
#       (HIMMEL-1475 CR-fix): --dedup-any is a public dedup-scope flag any
#       caller can add, not a provenance signal. A far arm with only
#       --dedup-any is REFUSED just like a bare far arm.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$FAR_HHMM" --handover "$HO" --dedup-any --dry-run 2>&1)
rc=$?
assert_rc "LG5b --dedup-any alone no longer bypasses the guard (rc 9)" 9 "$rc"
assert_contains "LG5b refusal still cites the directive" "ALWAYS-CONTINUE" "$out"

# ---------------------------------------------------------------------------
# LG7: the gap compares RAW SECONDS (>3600), not floored minutes. A time ~61
#      min out lands the true gap in [3601, 3660]s — ALWAYS over 3600 (refused),
#      yet the old `//60` floor rounded 3601-3659s down to 60 min and let it
#      pass.
# ---------------------------------------------------------------------------
# Rollover-safe edge (HIMMEL-1475 CR-fix): EDGE_HHMM is computed here in a
# SEPARATE process from arm-resume's own now-capture. The gap arm-resume sees
# is 3660 - now.seconds - lag (lag = the wall time between this capture and
# arm-resume's). The prior comment's "no flaky split across the 3600 boundary"
# was wrong: when this fixture lands in the last few seconds of a minute,
# now.seconds + lag crosses 60, the gap dips to <= 3600, and the expected rc=9
# flakes. Wait past the minute boundary whenever now is within a few seconds of
# rolling over so now.seconds is small and the gap stays in (3600, 3660) with
# margin for the cross-process lag.
_now_sec=$(python3 -c 'import datetime; print(datetime.datetime.now().second)')
if [ "$_now_sec" -ge 55 ]; then
    sleep $((61 - _now_sec))
fi
HO=$(make_handover "$WORK_REPO")
EDGE_HHMM=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=61)).strftime("%H:%M"))')
unset _now_sec
out=$(PATH="$SCHED_STUB:$PATH" bash "$ARM" --time "$EDGE_HHMM" --handover "$HO" --dry-run 2>&1)
rc=$?
assert_rc "LG7 ~61 min out ([3601,3660]s) refused under raw-seconds floor (rc 9)" 9 "$rc"

# ---------------------------------------------------------------------------
# LG6a: the long_gap audit field — a far arm WITH --long-gap records the
#       explicit choice in the "armed" telemetry line (long_gap=1).
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
TELE_LG6A="$TMP/tel-lg6a"
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELE_LG6A" \
    bash "$ARM" --time "$FAR_HHMM" --handover "$HO" --long-gap 2>&1)
rc=$?
assert_rc "LG6a far arm + --long-gap arms (rc 0)" 0 "$rc"
TLOG="$TELE_LG6A/skill-usage.jsonl"
if [ -f "$TLOG" ] && [ "$(wc -l < "$TLOG" | tr -d ' ')" = "1" ]; then
    echo "PASS LG6a exactly one telemetry record"
else
    echo "FAIL LG6a expected exactly one telemetry line ($TLOG)"
    FAILED=$((FAILED + 1))
fi
tline=$(tail -1 "$TLOG" 2>/dev/null || true)
assert_contains "LG6a record names the event" '"event":"armed"' "$tline"
assert_contains "LG6a record marks the explicit long-gap choice" '"long_gap":"1"' "$tline"

# ---------------------------------------------------------------------------
# LG-fix (HIMMEL-1756): the fixture self-check, run HERE — immediately before
#       the case that broke, i.e. after everything slow in this suite has
#       already happened. That placement is the slow-path simulation: no sleep
#       is injected, the run's own elapsed time is the load. A regression to a
#       suite-start capture makes the second assertion red as soon as the run
#       takes longer than 5 minutes, naming the fixture instead of leaving
#       LG6b to report rc=9 as if arm-resume had refused a legitimate near arm.
# ---------------------------------------------------------------------------
if declare -F near_hhmm >/dev/null 2>&1; then
    echo "PASS LG-fix near_hhmm is a function (recomputed per use, not captured once)"
else
    echo "FAIL LG-fix near_hhmm is not a function -- a captured NEAR_HHMM goes stale mid-run and LG6b fails rc=9 for a fixture reason"
    FAILED=$((FAILED + 1))
fi
_near_lead=$(python3 -c '
import datetime, sys
hh, mm = (int(x) for x in sys.argv[1].split(":"))
now = datetime.datetime.now().astimezone()
cand = now.replace(hour=hh, minute=mm, second=0, microsecond=0)
if cand <= now:
    cand += datetime.timedelta(days=1)
print(int((cand - now).total_seconds()))
' "$(near_hhmm)")
# 20 min minus the HH:MM truncation is 1140-1200s; anything under 900 means the
# value went stale, anything over 1200 means the lead was widened past what the
# comment above claims (and toward the 3600s long-gap ceiling).
if [ "$_near_lead" -ge 900 ] && [ "$_near_lead" -le 1200 ]; then
    echo "PASS LG-fix near_hhmm is still genuinely near this late in the run (${_near_lead}s out)"
else
    echo "FAIL LG-fix near_hhmm lead is ${_near_lead}s, outside the 900-1200s window -- LG2/LG6b are about to fail for a fixture reason, not a product one"
    FAILED=$((FAILED + 1))
fi

# ---------------------------------------------------------------------------
# LG6b: a NEAR arm (no --long-gap) records long_gap=0 — the ledger
#       distinguishes an explicit long park from a normal near arm.
# ---------------------------------------------------------------------------
HO=$(make_handover "$WORK_REPO")
TELE_LG6B="$TMP/tel-lg6b"
out=$(TMPDIR="$TMP" PATH="$ARMED_STUB:$PATH" SKILL_TELEMETRY_DIR="$TELE_LG6B" \
    bash "$ARM" --time "$(near_hhmm)" --handover "$HO" 2>&1)
rc=$?
assert_rc "LG6b near arm arms (rc 0)" 0 "$rc"
TLOG="$TELE_LG6B/skill-usage.jsonl"
tline=$(tail -1 "$TLOG" 2>/dev/null || true)
assert_contains "LG6b record names the event" '"event":"armed"' "$tline"
assert_contains "LG6b near arm records long_gap=0" '"long_gap":"0"' "$tline"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
if [ "$FAILED" -gt 0 ]; then
    echo "---"
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "---"
echo "PASS all cases"
exit 0
