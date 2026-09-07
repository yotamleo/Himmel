#!/usr/bin/env bash
# test-arm-resume-probe.sh -- HIMMEL-2125 timing probe for arm-resume.sh.
#
# WHY THIS EXISTS: test-arm-resume-identity.sh is the correctness suite and
# runs ~40+ minutes -- unusable as an iteration loop for a latency change.
# This probe splices that suite's hermetic setup (fresh HANDOVER_DIR, the
# stateful schtasks/at/claude/powershell/reg stubs, the temp-target +
# shipped-work shields) around ONE arm and reports:
#
#   * wall-clock seconds for a --dry-run arm and for a real (stubbed) arm
#   * the ARM_PROFILE=1 per-phase line
#   * how many python3 interpreters the arm actually spawned, and what each
#     one was for -- via a PATH shim ahead of the real python3 that appends
#     one line per invocation to $PY_SPAWN_LOG before exec'ing through.
#
# The spawn count is the number the HIMMEL-2125 consolidation work moves;
# wall-clock on a loaded Windows host is noisy enough that the count is the
# more honest signal. Run it before and after a change and diff both.
#
# Usage: bash scripts/handover/test-arm-resume-probe.sh [--repeat N]
# Exit:  0 on a completed run (this is a measurement tool, not an assertion
#        suite -- a nonzero arm rc is reported inline, not surfaced as a
#        probe failure); 1 on bad arguments.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# PROBE_ARM lets a baseline run point at a pristine copy of arm-resume.sh
# dropped alongside this script (e.g. `git show HEAD:...`), so before/after
# numbers can be taken without reverting the working tree. It MUST live in
# this same directory -- arm-resume.sh resolves queue-lock.sh and friends
# relative to its own location.
ARM="${PROBE_ARM:-$SCRIPT_DIR/arm-resume.sh}"

REPEAT=1
TRACE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --repeat) [ $# -ge 2 ] || { echo "usage: $0 [--repeat N] [--trace]" >&2; exit 1; }
                  case "$2" in ''|*[!0-9]*) echo "usage: $0 [--repeat N] [--trace]  (N must be a positive integer)" >&2; exit 1 ;; esac
                  [ "$2" -gt 0 ] || { echo "usage: $0 [--repeat N] [--trace]  (N must be a positive integer)" >&2; exit 1; }
                  REPEAT="$2"; shift 2 ;;
        --trace)  TRACE=1; shift ;;
        *) echo "usage: $0 [--repeat N] [--trace]" >&2; exit 1 ;;
    esac
done

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-probe.XXXXXX")
trap 'rm -rf "$TMP"' EXIT

# --- hermetic environment (mirrors test-arm-resume-identity.sh) -------------
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export WORKER_BRIDGE_ROOT="$TMP/bridge"
export ARM_TEMP_CWD_OK=1     # every fixture lives under $TMP (scheduler stubbed)
export ARM_SHIPPED_OK=1      # this probe is not the shipped-work gate's subject
mkdir -p "$WORKER_BRIDGE_ROOT/glm-sessions" "$WORKER_BRIDGE_ROOT/claudex-sessions"
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS ARM_DUP_OK SCHED_CREATE_FAIL 2>/dev/null || true

WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

# --- stubs ------------------------------------------------------------------
# Only the binaries an arm actually reaches. Stateful schtasks (flat file, one
# task name per line) so a real arm registers exactly as the identity suite
# models it; powershell exits 1 so the HIMMEL-938 post-arm verify fail-OPENS;
# reg emits a parseable US short-date so the locale probe stays HEALTHY (a
# degraded locale + a dead verify is the deliberate rc-2 dual-failure refuse,
# which would cut the arm short and make the timing meaningless).
STUB="$TMP/stub-bin"
mkdir -p "$STUB"
cat > "$STUB/schtasks" <<'EOF'
#!/usr/bin/env bash
db="${SCHED_DB:?SCHED_DB unset}"
cmd="${1:-}"; shift || true
tn=""
while [ $# -gt 0 ]; do
    case "$1" in
        /tn)   tn="${2:-}"; shift 2 ;;
        /tn=*) tn="${1#/tn=}"; shift ;;
        *)     shift ;;
    esac
done
case "$cmd" in
    /query)
        [ -f "$db" ] || exit 0
        while IFS= read -r t; do
            [ -n "$t" ] && printf '"\\%s","2026-01-01","Ready"\n' "$t"
        done < "$db"
        exit 0 ;;
    /create) printf '%s\n' "$tn" >> "$db"; exit 0 ;;
    /delete)
        if [ -f "$db" ]; then
            grep -vFx "$tn" "$db" > "$db.tmp" 2>/dev/null || : > "$db.tmp"
            mv "$db.tmp" "$db"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
cat > "$STUB/at" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
case "${1:-}" in
    -c) cat "$d/job-${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=$(cat "$d/.counter" 2>/dev/null || echo 0); n=$((n + 1))
        printf '%s' "$n" > "$d/.counter"; cat > "$d/job-$n"; exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
cat > "$STUB/atq" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; [ -d "$d" ] || exit 0
for f in "$d"/job-*; do
    [ -f "$f" ] || continue
    printf '%s\tThu Jun 11 09:00:00 2026 a user\n' "${f##*/job-}"
done
exit 0
EOF
cat > "$STUB/atrm" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; rm -f "$d/job-${1:-}" 2>/dev/null || true
exit 0
EOF
cat > "$STUB/crontab" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"; db="$d/crontab.fixture"
case "${1:-}" in
    -l) if [ -s "$db" ]; then cat "$db"; exit 0; else exit 1; fi ;;
    -|"") cat > "$db"; exit 0 ;;
    -r) : > "$db"; exit 0 ;;
    -*) cat > /dev/null 2>&1 || true; exit 0 ;;
    *)  if [ -f "$1" ]; then cat "$1" > "$db"; exit 0; fi
        cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
printf '#!/usr/bin/env bash\nexit 0\n' > "$STUB/claude"
printf '#!/usr/bin/env bash\nexit 1\n' > "$STUB/powershell"
cat > "$STUB/reg" <<'EOF'
#!/usr/bin/env bash
echo 'HKEY_CURRENT_USER\Control Panel\International'
echo '    sShortDate    REG_SZ    M/d/yyyy'
exit 0
EOF

# python3 counting shim. Appends one line per interpreter spawn -- the first
# ~70 chars of the program text, enough to identify the call SITE -- then
# execs the real interpreter so behaviour is unchanged. Resolved by absolute
# path so the shim cannot find itself.
REAL_PY3="$(command -v python3 2>/dev/null || true)"
cat > "$STUB/python3" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$(printf '%s ' "\$@" | tr '\n' ' ' | cut -c1-70)" >> "\$PY_SPAWN_LOG" 2>/dev/null || true
exec "$REAL_PY3" "\$@"
EOF
chmod +x "$STUB"/*

if [ -z "$REAL_PY3" ]; then
    echo "SKIP probe: no python3 on PATH -- nothing to measure" >&2
    exit 0
fi

mk_ho() {
    local p="$1" d
    d=$(dirname "$p"); mkdir -p "$d"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '# HIMMEL-2125 probe handover\n'
    } > "$p"
}

# 8h out, same reason the identity suite uses that offset: far enough that no
# arm here races the minute boundary. --long-gap sanctions the distance.
FUTURE_TIME=$("$REAL_PY3" -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(hours=8)).strftime("%H:%M"))')

# run_arm <label> <extra-arm-args...> -- times one arm, reports seconds, rc,
# python3 spawn count and the ARM_PROFILE line.
run_arm() {
    local label="$1"; shift
    local ho="$HANDOVER_DIR/probe-$label/h.md"
    mk_ho "$ho"
    local db="$TMP/db-$label.tasks"
    mkdir -p "${db}.atdir"; : > "$db"
    local spawnlog="$TMP/pyspawn-$label.log"; : > "$spawnlog"
    local t0 t1 rc out
    # --trace: xtrace with an EPOCHREALTIME stamp per command, so the post-run
    # gap analysis below can name the SLOWEST individual step. ARM_PROFILE's
    # phase list only covers the five explicitly-instrumented phases; when
    # those all read ~0s and the arm still takes tens of seconds, the cost is
    # somewhere they do not reach and only the trace finds it.
    local tracelog=""
    if [ "$TRACE" = "1" ]; then
        tracelog="$TMP/trace-$label.log"
        t0=$(date +%s)
        SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PY_SPAWN_LOG="$spawnlog" \
            ARM_PROFILE=1 PATH="$STUB:$PATH" PS4='+$EPOCHREALTIME:$LINENO:' \
            bash -x "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$ho" "$@" \
            >/dev/null 2>"$tracelog"
        rc=$?
        t1=$(date +%s)
        out=""
    else
        t0=$(date +%s)
        out=$(SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PY_SPAWN_LOG="$spawnlog" \
            ARM_PROFILE=1 PATH="$STUB:$PATH" \
            bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$ho" "$@" 2>&1)
        rc=$?
        t1=$(date +%s)
    fi
    local n; n=$(grep -c . "$spawnlog" 2>/dev/null) || n=0
    echo "--- $label: $((t1 - t0))s  rc=$rc  python3-spawns=$n"
    printf '%s\n' "$out" | grep '^PROFILE ' || echo "    (no PROFILE line)"
    if [ "$n" -gt 0 ]; then
        echo "    python3 spawn sites:"
        sort "$spawnlog" | uniq -c | sort -rn | sed 's/^/      /'
    fi
    if [ "$rc" -ne 0 ]; then
        echo "    !! nonzero rc -- arm did not complete; timing is NOT comparable"
        printf '%s\n' "$out" | grep -E '^(ERR|WARN) ' | head -5 | sed 's/^/      /'
    fi
    if [ -n "$tracelog" ]; then
        echo "    slowest traced steps (gap-seconds : line : command):"
        awk -F: '
            /^\+[0-9]/ {
                split($0, p, ":")
                ts = substr(p[1], 2) + 0
                ln = p[2]
                if (prev > 0) {
                    gap = ts - prev
                    if (gap > 0.2) printf "%8.2f  L%-6s %s\n", gap, prevln, prevcmd
                }
                prev = ts; prevln = ln
                prevcmd = substr($0, index($0, ":" p[2] ":") + length(p[2]) + 2)
            }
        ' "$tracelog" | sort -rn | head -25 | sed 's/^/      /'
    fi
}

echo "== arm-resume timing probe (repeat=$REPEAT) =="
echo "   python3: $REAL_PY3"
i=1
while [ "$i" -le "$REPEAT" ]; do
    [ "$REPEAT" -gt 1 ] && echo "-- iteration $i --"
    run_arm "dryrun$i" --dry-run
    run_arm "real$i"
    i=$((i + 1))
done
exit 0
