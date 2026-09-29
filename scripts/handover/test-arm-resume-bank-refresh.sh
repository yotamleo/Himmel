#!/usr/bin/env bash
# test-arm-resume-bank-refresh.sh -- HIMMEL-3846 regression: a REAL (non-dry-run)
# arm with an explicit HH:MM must not run the usage-cache producer refresh;
# --time auto / smart-on-the-live-cache keep it (the slot lookup reads the cache).
#
# arm-resume.sh calls scripts/lib/bank-preflight.sh only to enforce the
# fleet-size cap and discards every verdict but SKIPPED-FLEET. bank-preflight's
# own producer refresh (USAGE_OAUTH_TTL=0, session-less) rewrites the shared
# usage cache and stamps it with whatever identity the caller's environment
# resolves -- so a test suite arming for real under a fixture
# CLAUDE_ACCOUNT_CONFIG stamped the LIVE /tmp/claude cache with the fixture's
# hash (233bed9c03b5c4f2 = sha256(uuid-arm-resume-test)) and every later bank
# read on the host came back BANK-UNKNOWN.
#
# Fully hermetic: the producer is a marker stub (CADENCE_BANK_PRODUCER) and the
# cache path is scratch, so this suite can neither run the real producer nor
# touch /tmp/claude/statusline-usage-cache.json.
#
# Usage: bash scripts/handover/test-arm-resume-bank-refresh.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
PREFLIGHT="$SCRIPT_DIR/../lib/bank-preflight.sh"

TMP=$(mktemp -d) || { echo "FAIL: mktemp -d failed; refusing to run without a scratch dir" >&2; exit 1; }
trap 'rm -rf "$TMP"' EXIT

FAILED=0
check() { # label, condition-rc
    if [ "$2" -eq 0 ]; then echo "PASS $1"; else echo "FAIL $1"; FAILED=$((FAILED + 1)); fi
}

# --- hermetic shields (same set test-arm-resume-queue-lock.sh carries) ----------
FLEET_PS_STUB="$TMP/no-fleet-ps.sh"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FLEET_PS_STUB"
chmod +x "$FLEET_PS_STUB"
export FLEET_PS_CMD="$FLEET_PS_STUB"
export FLEET_CAP_OK=1
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR
XDG_RUNTIME_DIR="$TMP/xdg"
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"
export XDG_RUNTIME_DIR
# shellcheck source=../lib/fleet-slots-shield.sh
. "$SCRIPT_DIR/../lib/fleet-slots-shield.sh"
fleet_slots_shield "$TMP" || exit 1
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS ARM_DUP_OK 2>/dev/null || true
export ARM_TEMP_CWD_OK=1 ARM_SPLIT_LEG_OK=1 ARM_SHIPPED_OK=1 ARM_TICKET_DUP_OK=1
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
export ARM_RESUME_LOG_DIR="$TMP/arm-logs" ARM_RUNNER_DIR="$TMP/arm-runners"

# Scheduler stubs: an `at`/crontab pair that record instead of scheduling.
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
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
cat > "$SCHED_STUB/crontab" <<EOF
#!/usr/bin/env bash
store="$TMP/sched-stub.crontab"
case "\${1:-}" in
    -l) [ -s "\$store" ] && { cat "\$store"; exit 0; }; exit 1 ;;
    -)  sed 's/^[0-9][0-9]* [0-9][0-9]* /00 09 /' > "\$store" ;;
    *)  exit 0 ;;
esac
EOF
# schtasks: on msys/MINGW arm-resume registers through it, so a real one would
# create a real HIMMEL-Resume-* task. /create registers the name (the post-arm
# existence verify reads /query), same shape as test-arm-resume-queue-lock.sh.
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
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$SCHED_STUB/claude"
chmod +x "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/crontab" "$SCHED_STUB/schtasks" "$SCHED_STUB/claude"
export PATH="$SCHED_STUB:$PATH"

# The producer under test is a marker stub; the cache is scratch. Either alone
# would keep the live cache safe, both make a leak impossible even if one is wrong.
MARKER="$TMP/producer-ran"
PRODUCER_STUB="$TMP/producer-stub.sh"
printf '%s\n' '#!/usr/bin/env bash' "printf 'ran\n' >> \"$MARKER\"" > "$PRODUCER_STUB"
chmod +x "$PRODUCER_STUB"
export CADENCE_BANK_PRODUCER="$PRODUCER_STUB"
export CADENCE_BANK_CACHE="$TMP/bank-cache.json"
export CADENCE_BANK_LEDGER="$TMP/bank-ledger.jsonl"
unset CADENCE_BANK_SKIP_REFRESH CLAUDE_USAGE_CACHE RESUME_SLOT_CACHE 2>/dev/null || true

# --- control: bank-preflight itself DOES run the producer refresh ---------------
# Without this the stub wiring could be dead and the arm assertion below would
# pass vacuously.
rm -f "$MARKER"
bash "$PREFLIGHT" </dev/null >/dev/null 2>&1
if [ -f "$MARKER" ]; then ctl=0; else ctl=1; fi
check "control: bank-preflight.sh (no skip) invokes the producer stub" "$ctl"

# --- a real arm must NOT ---------------------------------------------------------
future_time() { python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))'; }
HO="$HANDOVER_DIR/HIMMEL-3846-test/next-session-1.md"
mkdir -p "$(dirname "$HO")"
printf -- '---\nsession_kind: test\n---\n# HIMMEL-3846 test handover\n' > "$HO"

rm -f "$MARKER"
out=$(bash "$ARM" --time "$(future_time)" --handover "$HO" 2>&1)
rc=$?
if [ "$rc" -ne 0 ]; then
    printf '%s\n' "$out" | sed 's/^/    | /' >&2
fi
[ "$rc" -eq 0 ]
check "real arm against the stubbed scheduler succeeds (rc=$rc)" $?
case "$out" in *"dry-run complete"*) rc_dry=1 ;; *) rc_dry=0 ;; esac
check "the arm was a real one, not a dry-run" "$rc_dry"
if [ ! -f "$MARKER" ]; then ran=0; else ran=1; fi
check "real arm did NOT run the usage-cache producer refresh (HIMMEL-3846)" "$ran"

# --- --time auto / smart (live cache) READ the cache by mtime, so the refresh stays ---
# (adversarial review of PR 1437: skipping it there left an old cache stale and
# made the slot lookup fail). The result of the arm itself is not asserted -- the
# slot lookup reads whatever cache the host has -- only that the refresh ran.
rm -f "$MARKER"
bash "$ARM" --time auto --handover "$HO" >/dev/null 2>&1
if [ -f "$MARKER" ]; then ran_auto=0; else ran_auto=1; fi
check "--time auto keeps the producer refresh (the slot lookup reads the cache)" "$ran_auto"

rm -f "$MARKER"
bash "$ARM" --time smart --handover "$HO" >/dev/null 2>&1
if [ -f "$MARKER" ]; then ran_smart=0; else ran_smart=1; fi
check "--time smart on the live cache keeps the producer refresh" "$ran_smart"

if [ "$FAILED" -eq 0 ]; then
    echo "OK: all cases passed"
    exit 0
fi
echo "FAIL: $FAILED case(s) failed"
exit 1
