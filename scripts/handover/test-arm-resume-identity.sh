#!/usr/bin/env bash
# test-arm-resume-identity.sh -- HIMMEL-1304 regression suite for the two
# pre-existing, verified defects in scripts/handover/arm-resume.sh:
#
#   Defect A -- the dedup identity is a lossy, uncanonicalized transform.
#     _path_suffix (arm-resume.sh ~:1025) is derived straight from
#     $HANDOVER_PATH as typed:
#         tr '/\\' '__' | tr -cd '[:alnum:]_-'
#     Two directions of breakage:
#       * false-negative (aliasing): the SAME handover reached as ./x.md vs an
#         absolute path vs through a symlink vs a Windows case variant produces
#         DIFFERENT identities => two slots armed for one handover.
#       * false-positive (collision): tr -cd DELETES out-of-class characters,
#         so a+b.md and ab.md both reduce to the same suffix => a spurious rc 3
#         refusal, and --force replaces the OTHER handover's slot.
#
#   Defect B -- --force replace is non-transactional. Deletion of the matched
#     job(s) happens early (~:1508), but the rc 7 (FRESH queue lock) and rc 8
#     (pending arm on another host) refusals run LATER (~:1861/:1891), and the
#     new job is only registered inside schedule_arm (~:2678). So an arm that
#     deletes and then exits 7/8 -- or fails inside schedule_arm -- leaves the
#     previous slot(s) destroyed with no replacement and no rollback.
#
# This suite is written BLACK-BOX (it arms via arm-resume.sh and observes the
# scheduler slot count / exit code) so it is valid regardless of how the parent
# session implements the fix. It is TDD: every assertion below is expected to
# FAIL against current main -- that is the deliverable, not a defect.
#
# ----------------------------------------------------------------------------
# EXPECTED FAILURE SHAPE ON PRE-FIX main. The list below was written from the
# defect analysis, NOT transcribed from a completed run — the authoring session
# could not finish one (MSYS fork exhaustion on a loaded Windows host), so treat
# the individual rc/count values as predicted rather than measured. What IS
# measured, on the fixed tree, is the PASS line each case prints today.
#
# One prediction below was wrong in an instructive way and has been corrected in
# the assertions: the Group 1 alias arms were expected to exit rc 0. They do
# not, and should not — once the identity is canonical, the second (alias) arm
# is the SAME handover, so the dedup guard correctly REFUSES it rc 3. That
# refusal IS the proof the alias was recognised; pre-fix it returned rc 0 and
# armed a second slot. The assertions therefore expect rc 3 + exactly one slot.
#
#   Group 1 -- aliasing must collapse to ONE slot (defect A, false-negative):
#     G1.1 ./x.md  vs absolute      -> pre-fix: 2 slots, alias arm rc=0
#     G1.2 redundant `..` segment   -> pre-fix: 2 slots, alias arm rc=0
#     G1.3 symlink alias            -> pre-fix: 2 slots (SKIPs where a real
#                                       symlink cannot be created -- MSYS ln -s
#                                       copies, and a copy is a DIFFERENT file,
#                                       so 2 slots would be correct there)
#     G1.4 case variant             -> pre-fix: 2 slots  [case-insensitive FS]
#   Group 2 -- sanitization collisions must stay TWO slots (defect A, false-+):
#     G2.1 a+b.md vs ab.md          -> FAIL  arm2 rc=3 ("already scheduled"),
#                                              1 slot
#     G2.2 v1.2.md vs v12.md        -> FAIL  arm2 rc=3, 1 slot
#   Group 3 -- --force replace must be transactional (defect B):
#     G3.1 force fails at rc 7      -> FAIL  pre-existing slot DESTROYED (0)
#     G3.2 force fails at rc 8      -> FAIL  pre-existing slot DESTROYED (0)
#     G3.3 force fails in schedule_arm -> FAIL  slot DESTROYED (0); arm rc=4
#     G3.4 --dedup-any --force worst case -> FAIL  UNRELATED victim slot wiped (0)
#
# On a fixed arm-resume.sh every line above turns PASS (or SKIP for the
# platform-gated G1.3/G1.4 cases). If an assertion already PASSES on main it
# means the defect does not manifest that way or the test does not exercise it;
# both are reported below, never silently omitted.
# ----------------------------------------------------------------------------
#
# Usage: bash scripts/handover/test-arm-resume-identity.sh
# Exit:  0 = all pass, 1 = one or more failures.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ARM="$SCRIPT_DIR/arm-resume.sh"
QL="$SCRIPT_DIR/queue-lock.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# Hermetic: fresh handover root, no real scheduler, no real telemetry/trust
# writes (same shields test-arm-resume.sh / test-arm-resume-queue-lock.sh use).
HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
export HANDOVER_DIR
export SKILL_TELEMETRY_DIR="$TMP/telemetry"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export WORKER_BRIDGE_ROOT="$TMP/bridge"
mkdir -p "$WORKER_BRIDGE_ROOT/glm-sessions" "$WORKER_BRIDGE_ROOT/claudex-sessions"
unset QUEUE_LOCK_TAKEOVER QUEUE_LOCK_TTL_SECONDS ARM_DUP_OK SCHED_CREATE_FAIL 2>/dev/null || true

# A real git repo to pin resume_cwd against (so RESUME_CWD is deterministic
# regardless of the test process cwd, and schedule_arm's cygpath/.bat path
# resolves to a real directory).
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

# HIMMEL-1543: FUTURE_TIME is captured ONCE (every alias/dedup pair in Groups 1-2
# must share ONE target time, else two arms for the same handover park at
# different minutes and the aliasing assertions lose their meaning). But this
# suite runs 40+ min, so by Group 3 the wall clock has passed FUTURE_TIME,
# arm-resume.sh resolves it to ~tomorrow (>60 min out), and the HIMMEL-1475
# long-gap guard refuses rc=9 before the injected condition is ever reached.
# So EVERY arm below carries --long-gap: this suite's subject is identity,
# dedup and transactionality, NOT the long-gap guard, and --long-gap is a no-op
# for an arm already inside the 60-min window (so it cannot regress a fast run).
# The guard itself stays covered by the dedicated Group 4 case. FUTURE_TIME is a
# near-future value only so the asserted rc/slot shape is realistic.
FUTURE_TIME=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(minutes=30)).strftime("%H:%M"))')
FAILED=0

# --- assertions -------------------------------------------------------------
# assert_rc <label> <expected> <actual> [captured-output]
# On a mismatch the captured arm output is dumped -- a bare "expected rc=0,
# got rc=2" hides the cause (learned the hard way by the sibling suites).
assert_rc() {
    local label="$1" expected="$2" actual="$3" cap="${4:-}"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- expected rc=$expected, got rc=$actual"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}
assert_ne_rc() {  # <label> <not-this-rc> <actual> [captured]
    local label="$1" bad="$2" actual="$3" cap="${4:-}"
    if [ "$actual" != "$bad" ]; then
        echo "PASS $label (rc=$actual)"
    else
        echo "FAIL $label -- must NOT exit rc=$bad (got exactly that)"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "PASS $label" ;;
        *) echo "FAIL $label -- output missing: $needle"; FAILED=$((FAILED + 1)) ;;
    esac
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    case "$haystack" in
        *"$needle"*) echo "FAIL $label -- output unexpectedly contains: $needle"; FAILED=$((FAILED + 1)) ;;
        *) echo "PASS $label" ;;
    esac
}

# Count armed slots in the platform's state location.
#   $1 = SCHED_DB file (windows); $2 = SCHED_DB_DIR dir (posix)
count_slots() {
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            if [ -f "$1" ]; then local c; c=$(grep -c . "$1" 2>/dev/null); echo "${c:-0}"; else echo 0; fi ;;
        darwin*)
            # macOS uses crontab ONLY (arm-resume.sh PLATFORM=macos), whose stub
            # store is $dir/crontab.fixture -- NOT $db (schtasks) or job-*
            # (at). Counting either of those here would always read 0 on Darwin
            # and make every slot-survival assertion vacuously pass.
            if [ -f "$2/crontab.fixture" ]; then local c; c=$(grep -c . "$2/crontab.fixture" 2>/dev/null); echo "${c:-0}"; else echo 0; fi ;;
        *)
            find "$2" -maxdepth 1 -name 'job-*' 2>/dev/null | wc -l | tr -d ' ' ;;
    esac
}
# assert_slots <label> <expected> <db> <dir> [captured]
assert_slots() {
    local label="$1" expected="$2" db="$3" dir="$4" cap="${5:-}"
    local got; got=$(count_slots "$db" "$dir")
    if [ "$got" = "$expected" ]; then
        echo "PASS $label (slots=$got)"
    else
        echo "FAIL $label -- expected $expected slot(s), got $got"
        [ -n "$cap" ] && { echo "----- captured arm output -----"; printf '%s\n' "$cap"; echo "-------------------------------"; }
        FAILED=$((FAILED + 1))
    fi
}

# Write a minimal handover at the given path (resume_cwd pinned for determinism).
mk_ho() {
    local p="$1" d
    d=$(dirname "$p"); mkdir -p "$d"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        printf -- '---\n'
        printf '# HIMMEL-1304 test handover\n'
    } > "$p"
}

# ---------------------------------------------------------------------------
# Scheduler stub. Same hermetic conventions as test-arm-resume.sh's
# make_stateful_sched, with TWO additions the identity/transactional suite
# needs:
#   (1) a STATEFUL schtasks: /create records the task name, /query lists what
#       was recorded, /delete removes one -- so ONE-vs-TWO slot assertions are
#       real (an empty stub can't model a growing job set).
#   (2) SCHED_CREATE_FAIL=1 makes /create exit nonzero while /query + /delete
#       keep working -- the failure-injection seam for defect B's "fails inside
#       schedule_arm" case.
# Plus the two stubs test-arm-resume.sh does NOT carry but this suite MUST:
#   * powershell -> exit 1 (probe "unavailable" => arm-resume's HIMMEL-938
#     post-arm verify fail-OPENS, WARN + arm stands).
#   * reg -> emit a parseable US short-date pattern (M/d/yyyy) so locale
#     detection is HEALTHY. Without it, a degraded locale + the dead powershell
#     probe is the deliberate DUAL-failure refuse (rc 2 + delete-the-task) and
#     every non-dry-run arm dies, cascading every downstream assertion.
#   * claude -> exit 0 (schedule_arm requires `command -v claude`).
# ---------------------------------------------------------------------------
make_stub() {
    local dir="$1"
    mkdir -p "$dir"
    cat > "$dir/schtasks" <<'EOF'
#!/usr/bin/env bash
# Stateful schtasks stub. State = $SCHED_DB (flat file, one task name/line).
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
    /create)
        # Failure injection (HIMMEL-1304 defect B): when SCHED_CREATE_FAIL=1,
        # /create exits nonzero so schedule_arm fails AFTER --force already
        # deleted the prior slot -- the non-transactional delete this suite
        # must catch.
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then
            echo "stub: schtasks /create deliberately failing (SCHED_CREATE_FAIL=1)" >&2
            exit 9
        fi
        printf '%s\n' "$tn" >> "$db"; exit 0 ;;
    /delete)
        if [ -f "$db" ]; then
            grep -vFx "$tn" "$db" > "$db.tmp" 2>/dev/null || : > "$db.tmp"
            mv "$db.tmp" "$db"
        fi
        exit 0 ;;
    *) exit 0 ;;
esac
EOF
    cat > "$dir/at" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
case "${1:-}" in
    -c) cat "$d/job-${2:-}" 2>/dev/null; exit 0 ;;
    -t)
        n=$(cat "$d/.counter" 2>/dev/null || echo 0); n=$((n + 1))
        printf '%s' "$n" > "$d/.counter"
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
        cat > "$d/job-$n"
        exit 0 ;;
    *) cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    cat > "$dir/atq" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; [ -d "$d" ] || exit 0
for f in "$d"/job-*; do
    [ -f "$f" ] || continue
    printf '%s\tThu Jun 11 09:00:00 2026 a user\n' "${f##*/job-}"
done
exit 0
EOF
    cat > "$dir/atrm" <<'EOF'
#!/usr/bin/env bash
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; rm -f "$d/job-${1:-}" 2>/dev/null || true
exit 0
EOF
    cat > "$dir/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    cat > "$dir/powershell" <<'EOF'
#!/usr/bin/env bash
# Probe "unavailable" -> arm-resume's HIMMEL-938 post-arm verify fail-opens
# (WARN, arm stands). Faking a NextRunTime would need the TARGET_EPOCH this
# stub can't know; the fail-open path is the honest fake for tests that
# exercise identity/dedup/transactionality, not the verify feature itself.
exit 1
EOF
    cat > "$dir/reg" <<'EOF'
#!/usr/bin/env bash
# Locale probe stub: emit a parseable US short-date pattern so arm-resume's
# _win_short_date_pattern SUCCEEDS (locale HEALTHY -> _locale_degraded=0) and
# the dead powershell probe above fail-OPENS instead of tripping the rc-2 +
# delete-the-task dual-failure refuse. Args are ignored.
echo 'HKEY_CURRENT_USER\Control Panel\International'
echo '    sShortDate    REG_SZ    M/d/yyyy'
exit 0
EOF
    cat > "$dir/crontab" <<'EOF'
#!/usr/bin/env bash
# Stateful crontab stub (HIMMEL-1567). arm-resume.sh routes macOS (Darwin)
# through crontab ONLY -- list_existing()'s macos arm calls _crontab_list, which
# is `crontab -l | grep`, and _crontab_schedule/_crontab_delete rewrite via
# `| crontab -` (arm-resume.sh ~:1415-1629). Without a stub here, a local
# Darwin run resolves the REAL crontab binary and reads -- and via
# _crontab_delete's rewrite, WRITES -- the operator's machine-wide crontab
# outside this suite's fixture. That is a fixture escape; this stub closes it.
# State lives in a fixture file inside $SCHED_DB_DIR -- `:?` so an unset var is
# a LOUD failure, never a silent fall-through to the real binary (mirrors the
# at/atq/atrm guard). PATH="$STUB:$PATH" puts this ahead of any real crontab,
# and the `:?` is the belt-and-suspenders: there is no code path where an unset
# var degrades into touching $HOME's crontab.
d="${SCHED_DB_DIR:?SCHED_DB_DIR unset}"; mkdir -p "$d"
db="$d/crontab.fixture"
case "${1:-}" in
    -l)
        # Real `crontab -l` exits 1 ("no crontab for user"), no output, when the
        # crontab is empty. _crontab_list/_crontab_delete/_crontab_schedule all
        # guard that (`2>/dev/null || true` / `if ! crontab -l; then : > snap`),
        # so model it honestly rather than always exiting 0.
        if [ -s "$db" ]; then cat "$db"; exit 0; else exit 1; fi ;;
    -)
        # Install from stdin (REPLACE the whole fixture) -- the verb both
        # _crontab_schedule (append entry) and _crontab_delete (drop one line)
        # rewrite through. SCHED_CREATE_FAIL=1 makes the install path exit
        # nonzero so G3.3/G3.4's "fails inside schedule_arm" failure injection
        # works on Darwin exactly as schtasks /create and `at -t` do on the
        # other two platforms. Fail BEFORE writing so the fixture is untouched.
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then
            echo "stub: crontab install deliberately failing (SCHED_CREATE_FAIL=1)" >&2
            exit 9
        fi
        cat > "$db"; exit 0 ;;
    -r)
        : > "$db"; exit 0 ;;
    "")
        # Piped stdin with no flag = replace (some call sites `printf ... | crontab`).
        if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
        cat > "$db"; exit 0 ;;
    -*)
        # Unknown flag (-e editor, -u user): NEVER touch real state. Drain any
        # piped stdin so a writer does not see a spurious SIGPIPE, exit 0 so a
        # probe-by-existence sees a present binary.
        cat > /dev/null 2>&1 || true; exit 0 ;;
    *)
        # A bare file arg = install from that file (real `crontab <file>`).
        if [ -f "$1" ]; then
            if [ "${SCHED_CREATE_FAIL:-0}" = "1" ]; then exit 9; fi
            cat "$1" > "$db"; exit 0
        fi
        cat > /dev/null 2>&1 || true; exit 0 ;;
esac
EOF
    chmod +x "$dir/schtasks" "$dir/at" "$dir/atq" "$dir/atrm" "$dir/claude" "$dir/powershell" "$dir/reg" "$dir/crontab"
}

STUB="$TMP/stub-bin"
make_stub "$STUB"

# Per-test fresh scheduler state. $1 -> SCHED_DB; SCHED_DB_DIR alongside.
new_db() {
    local db="$1" dir
    dir="${db}.atdir"; mkdir -p "$dir"; : > "$db"
    printf '%s' "$db"
}

echo "== Group 1: aliasing must collapse to ONE slot (defect A false-negative) =="

# --- G1.1: relative (./x.md) vs absolute -----------------------------------
# Same file, two spellings. On main _path_suffix derives from the raw string,
# so the two produce DIFFERENT task names => two slots armed for one handover.
G1A_DIR="$HANDOVER_DIR/g1a"
HO_ABS="$G1A_DIR/x.md"; mk_ho "$HO_ABS"
DB1=$(new_db "$TMP/db1.tasks")
out=$(SCHED_DB="$DB1" SCHED_DB_DIR="${DB1}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_ABS" 2>&1)
rc=$?
assert_rc "G1.1a canonical absolute arm succeeds" 0 "$rc" "$out"
# Run the alias arm from INSIDE the handover dir so ./x.md resolves to the file
# (cd runs in the command-substitution subshell; env prefixes apply to bash).
out=$( cd "$G1A_DIR" && SCHED_DB="$DB1" SCHED_DB_DIR="${DB1}.atdir" PATH="$STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover ./x.md 2>&1 )
rc=$?
assert_rc "G1.1b alias ./x.md is RECOGNIZED as the same handover (rc 3)" 3 "$rc" "$out"
assert_slots "G1.1c ONE slot for ./x.md == absolute" 1 "$DB1" "${DB1}.atdir" "$out"

# --- G1.2: redundant `..` segment ------------------------------------------
# $dir/x.md vs $dir/sub/../x.md resolve to the SAME file. On main the raw
# strings differ, so the suffixes differ => two slots.
G1B_DIR="$HANDOVER_DIR/g1b"; mkdir -p "$G1B_DIR/sub"
HO_DOT="$G1B_DIR/x.md"; mk_ho "$HO_DOT"
HO_DOT_ALIAS="$G1B_DIR/sub/../x.md"
DB2=$(new_db "$TMP/db2.tasks")
out=$(SCHED_DB="$DB2" SCHED_DB_DIR="${DB2}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_DOT" 2>&1)
rc=$?
assert_rc "G1.2a canonical arm succeeds" 0 "$rc" "$out"
out=$(SCHED_DB="$DB2" SCHED_DB_DIR="${DB2}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_DOT_ALIAS" 2>&1)
rc=$?
assert_rc "G1.2b redundant-.. alias is RECOGNIZED as the same handover (rc 3)" 3 "$rc" "$out"
assert_slots "G1.2c ONE slot for x.md == sub/../x.md" 1 "$DB2" "${DB2}.atdir" "$out"

# --- G1.3: through a symlink ------------------------------------------------
# A symlink to the handover is a third spelling of the same file. SKIP (not
# FAIL) if symlink creation is unavailable on this host (Windows w/o privilege
# or a copy-style `ln`). Skip too if the link does not resolve to the target
# (ln made a copy => a genuinely different file, not an alias).
G1C_DIR="$HANDOVER_DIR/g1c"; mkdir -p "$G1C_DIR"
HO_REAL="$G1C_DIR/real.md"; mk_ho "$HO_REAL"
HO_REAL_ABS=$(realpath "$HO_REAL" 2>/dev/null || printf '%s' "$HO_REAL")
HO_LINK="$G1C_DIR/link.md"
if MSYS=winsymlinks:nativestrict ln -s "$HO_REAL" "$HO_LINK" 2>/dev/null \
    && [ "$(realpath "$HO_LINK" 2>/dev/null)" = "$HO_REAL_ABS" ]; then
    DB3=$(new_db "$TMP/db3.tasks")
    out=$(SCHED_DB="$DB3" SCHED_DB_DIR="${DB3}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_REAL" 2>&1)
    rc=$?
    assert_rc "G1.3a canonical (real path) arm succeeds" 0 "$rc" "$out"
    out=$(SCHED_DB="$DB3" SCHED_DB_DIR="${DB3}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_LINK" 2>&1)
    rc=$?
    assert_rc "G1.3b symlink alias is RECOGNIZED as the same handover (rc 3)" 3 "$rc" "$out"
    assert_slots "G1.3c ONE slot for real.md == symlink link.md" 1 "$DB3" "${DB3}.atdir" "$out"
else
    echo "SKIP G1.3 symlink aliasing -- ln -s unavailable or non-resolving on this host"
fi

# --- G1.4: a case variant of the directory (case-insensitive FS only) ------
# On a case-insensitive FS (Windows/macOS) HandoverCase.md and handovercase.md
# are the same file; on Linux they are genuinely two files. Detect + SKIP on a
# case-sensitive FS so the assertion never fires where two cases ARE two files.
G1D_DIR="$HANDOVER_DIR/g1d"; mkdir -p "$G1D_DIR"
HO_CC="$G1D_DIR/HandoverCase.md"; mk_ho "$HO_CC"
if [ -f "$G1D_DIR/handovercase.md" ]; then
    HO_CC_ALIAS="$G1D_DIR/handovercase.md"
    DB4=$(new_db "$TMP/db4.tasks")
    out=$(SCHED_DB="$DB4" SCHED_DB_DIR="${DB4}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_CC" 2>&1)
    rc=$?
    assert_rc "G1.4a canonical (mixed-case) arm succeeds" 0 "$rc" "$out"
    out=$(SCHED_DB="$DB4" SCHED_DB_DIR="${DB4}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$HO_CC_ALIAS" 2>&1)
    rc=$?
    assert_rc "G1.4b lower-case variant is RECOGNIZED as the same handover (rc 3)" 3 "$rc" "$out"
    assert_slots "G1.4c ONE slot for HandoverCase.md == handovercase.md" 1 "$DB4" "${DB4}.atdir" "$out"
else
    echo "SKIP G1.4 case-variant aliasing -- FS is case-sensitive (two cases are genuinely two files)"
fi

echo
echo "== Group 2: sanitization collisions must stay TWO slots (defect A false-positive) =="

# Two DISTINCT files whose names tr -cd collapses to the same suffix. On main
# they map to the SAME derived task name, so arming the second is refused rc 3
# (a dedup block for a DIFFERENT handover) and --force would replace the other
# handover's slot. The pair on the left collapses via `+`/`.` deletion; the
# pair on the right collapses via `.` deletion alone.
test_collision_pair() {
    local label="$1" name_a="$2" name_b="$3" db="$4"
    mk_ho "$HANDOVER_DIR/g2/$label/$name_a"
    mk_ho "$HANDOVER_DIR/g2/$label/$name_b"
    out=$(SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap \
        --handover "$HANDOVER_DIR/g2/$label/$name_a" 2>&1)
    rc=$?
    assert_rc "$label a: first distinct handover arms" 0 "$rc" "$out"
    out=$(SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap \
        --handover "$HANDOVER_DIR/g2/$label/$name_b" 2>&1)
    rc=$?
    assert_ne_rc "$label b: second DISTINCT handover is NOT a dedup block (rc!=3)" 3 "$rc" "$out"
    assert_not_contains "$label b: no 'already scheduled' refusal" "already scheduled" "$out"
    assert_slots "$label c: TWO distinct slots coexist" 2 "$db" "${db}.atdir" "$out"
}

DB5=$(new_db "$TMP/db5.tasks")
test_collision_pair "G2.1" "a+b.md" "ab.md" "$DB5"
DB6=$(new_db "$TMP/db6.tasks")
test_collision_pair "G2.2" "v1.2.md" "v12.md" "$DB6"

echo
echo "== Group 3: --force replace must be transactional (defect B) =="

# For each later failure stage, seed a queued sibling slot, force an arm that
# FAILS there, and assert the pre-existing slot SURVIVES. On main the --force
# delete (arm-resume.sh ~:1508) runs BEFORE rc 7 (~:1861), rc 8 (~:1891), and
# schedule_arm (~:2678), so a delete-then-fail leaves NO arm and NO rollback.

# G3.1 -- fails at rc 7 (a FRESH queue lock on the SAME handover).
SEED_OUT=""
seed_slot() {  # <handover-path> <sched-db>   -- one clean real arm
    local ho="$1" db="$2"
    SEED_OUT=$(SCHED_DB="$db" SCHED_DB_DIR="${db}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$ho" 2>&1)
}
# assert_seeded <label> <db> <dir> -- exactly 1 slot after a seed arm (a failed
# seed makes every downstream slot-survival assertion meaningless, so it is its
# own FAIL with the seed output dumped, not a silent pass-through).
assert_seeded() {
    local label="$1" db="$2" dir="$3" got
    got=$(count_slots "$db" "$dir")
    if [ "$got" = "1" ]; then
        echo "PASS $label (seeded 1 slot)"
    else
        echo "FAIL $label -- seed arm left $got slot(s) (expected 1); downstream assertions are meaningless"
        echo "----- captured seed arm output -----"; printf '%s\n' "$SEED_OUT"; echo "-----------------------------------"
        FAILED=$((FAILED + 1))
    fi
}

G3A="$HANDOVER_DIR/g3/t1.md"; mk_ho "$G3A"
DB7=$(new_db "$TMP/db7.tasks")
seed_slot "$G3A" "$DB7"
assert_seeded "G3.1 seed: pre-existing slot armed" "$DB7" "${DB7}.atdir"
bash "$QL" acquire "$G3A" "live-session-7" >/dev/null 2>&1
out=$(SCHED_DB="$DB7" SCHED_DB_DIR="${DB7}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$G3A" --force 2>&1)
rc=$?
assert_rc "G3.1 failing arm exits rc=7 (FRESH queue lock)" 7 "$rc" "$out"
assert_slots "G3.1 pre-existing slot SURVIVES a force that fails at rc 7" 1 "$DB7" "${DB7}.atdir" "$out"
bash "$QL" release "$G3A" "live-session-7" >/dev/null 2>&1 || true
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# G3.2 -- fails at rc 8 (a pending arm for the SAME handover on ANOTHER host).
G3B="$HANDOVER_DIR/g3/t2.md"; mk_ho "$G3B"
DB8=$(new_db "$TMP/db8.tasks")
seed_slot "$G3B" "$DB8"
assert_seeded "G3.2 seed: pre-existing slot armed" "$DB8" "${DB8}.atdir"
mkdir -p "$HANDOVER_DIR/.locks"
# CR round: fire-at must be a genuinely PENDING (future) arm, not a fixed
# past date -- verified the gating in _arm_registry_foreign_hits (arm-resume.sh)
# does NOT compare fire-at to "now" (it only checks host + the "fired" flag),
# so this case was not actually vacuous even hard-coded in the past; still,
# a stale literal misrepresents the scenario and would silently start
# passing for the wrong reason if that gating logic ever gains a staleness
# check. now+2h keeps the fixture honest without depending on wall-clock
# drift across a slow run.
G3B_FIRE_AT="$(date -d '+2 hours' +%Y%m%d%H%M 2>/dev/null || date -v+2H +%Y%m%d%H%M)"
printf '{"host":"other-host","handover":"%s","fire-at":"%s","task-name":"HIMMEL-Resume-g3b-other"}\n' \
    "$G3B" "$G3B_FIRE_AT" > "$HANDOVER_DIR/.locks/arms.jsonl"
out=$(SCHED_DB="$DB8" SCHED_DB_DIR="${DB8}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$G3B" --force 2>&1)
rc=$?
assert_rc "G3.2 failing arm exits rc=8 (pending arm on another host)" 8 "$rc" "$out"
assert_slots "G3.2 pre-existing slot SURVIVES a force that fails at rc 8" 1 "$DB8" "${DB8}.atdir" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# G3.3 -- fails inside schedule_arm (the scheduler's create verb fails). The
# stub's /create exits nonzero under SCHED_CREATE_FAIL=1 while /query + /delete
# keep working, so --force deletes the prior slot and then schedule_arm dies.
G3C="$HANDOVER_DIR/g3/t3.md"; mk_ho "$G3C"
DB9=$(new_db "$TMP/db9.tasks")
seed_slot "$G3C" "$DB9"
assert_seeded "G3.3 seed: pre-existing slot armed" "$DB9" "${DB9}.atdir"
out=$(SCHED_CREATE_FAIL=1 SCHED_DB="$DB9" SCHED_DB_DIR="${DB9}.atdir" PATH="$STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$G3C" --force 2>&1)
rc=$?
assert_rc "G3.3 failing arm exits rc=4 (schedule_arm create failed)" 4 "$rc" "$out"
assert_contains "G3.3 reaches transactional replacement path" "replacing existing job(s) AFTER the new one is registered" "$out"
assert_slots "G3.3 pre-existing slot SURVIVES a force that fails in schedule_arm" 1 "$DB9" "${DB9}.atdir" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

# G3.4 -- worst case: --dedup-any --force. Scope = EVERY HIMMEL-Resume-* job,
# so a single failed arm can wipe every queued relaunch on the machine. Seed an
# UNRELATED victim slot, force-arm X with a failing create,
# and assert the victim is NOT destroyed. The victim is fixture scaffolding,
# not an arm-resume behavior under test, so write the stateful scheduler stub's
# successful-arm shape directly. Invoking the real arm here makes the fixture
# depend on the machine-wide live-worker guard and turns unrelated lane work
# into a false failure (HIMMEL-1543).
seed_unrelated_victim() {  # <sched-db> <sched-dir>
    local db="$1" dir="$2" marker="HIMMEL-Resume-G3-4-unrelated-victim"
    case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
        msys*|cygwin*|win32*|MINGW*)
            printf '%s\n' "$marker" >> "$db" ;;
        darwin*)
            # macOS: seed the victim as a crontab LINE in _crontab_schedule's
            # own shape -- a command line with a trailing `# <TASK_NAME>` marker
            # (arm-resume.sh ~:2423: "<mm> <hh> * * * ... # $TASK_NAME"), which
            # is exactly what _crontab_list greps back. NOT $db or job-N: the
            # Darwin path writes neither store.
            mkdir -p "$dir"
            printf '0 9 * * * cd /nonexistent && claude fixture # %s\n' "$marker" > "$dir/crontab.fixture" ;;
        *)
            mkdir -p "$dir"
            printf '1' > "$dir/.counter"
            printf '# %s\nexit 0\n' "$marker" > "$dir/job-1" ;;
    esac
    SEED_OUT="direct scheduler fixture: $marker"
}
G3X="$HANDOVER_DIR/g3/t4x.md"; mk_ho "$G3X"
DB10=$(new_db "$TMP/db10.tasks")
seed_unrelated_victim "$DB10" "${DB10}.atdir"
assert_seeded "G3.4 seed: unrelated victim slot armed" "$DB10" "${DB10}.atdir"
out=$(SCHED_CREATE_FAIL=1 SCHED_DB="$DB10" SCHED_DB_DIR="${DB10}.atdir" PATH="$STUB:$PATH" \
    bash "$ARM" --time "$FUTURE_TIME" --long-gap --handover "$G3X" --dedup-any --force 2>&1)
rc=$?
assert_rc "G3.4 failing arm exits rc=4 (schedule_arm create failed)" 4 "$rc" "$out"
# Platform-appropriate reachability evidence (HIMMEL-1567). The --force path
# echoes each marker from list_existing() into stderr (arm-resume.sh ~:1936-1939),
# which $out captures -- but WHAT that marker is differs by platform:
#   windows -- list_existing returns the self-descriptive schtasks task NAME
#     (`HIMMEL-Resume-...`), so the marker text reaches $out directly.
#   darwin  -- list_existing's macos arm calls _crontab_list (arm-resume.sh
#     ~:1415-1434), which `grep`s `crontab -l` and returns the FULL crontab
#     LINE -- and _crontab_schedule (~:2423) writes that line with a trailing
#     `# $TASK_NAME`. So, unlike the at path below, the marker text IS echoed
#     back on Darwin. Verified by reading the code, not by guessing: assert the
#     SAME `HIMMEL-Resume-G3-4-unrelated-victim` text as on Windows.
#   linux/other -- list_existing inspects each at-job's body and returns an
#     OPAQUE `at-job-<id>` (arm-resume.sh ~:1536/1540); the marker text in the
#     job body never reaches the --force log. The seeded victim is the ONLY job
#     in this test's fresh queue, so it is always id 1 -- "at-job-1" is exactly
#     as specific a proof that THIS job was found as the marker-text check is
#     on the other two platforms.
case "${OSTYPE:-$(uname -s 2>/dev/null)}" in
    msys*|cygwin*|win32*|MINGW*)
        assert_contains "G3.4 reaches unrelated victim replacement path" "HIMMEL-Resume-G3-4-unrelated-victim" "$out" ;;
    darwin*)
        assert_contains "G3.4 reaches unrelated victim replacement path" "HIMMEL-Resume-G3-4-unrelated-victim" "$out" ;;
    *)
        assert_contains "G3.4 reaches unrelated victim replacement path" "at-job-1" "$out" ;;
esac
assert_slots "G3.4 UNRELATED victim slot is NOT destroyed by a failed --dedup-any --force" 1 "$DB10" "${DB10}.atdir" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

echo
echo "== Group 4: HIMMEL-1475 long-gap guard still fires (regression coverage) =="
# Every other arm in this suite carries --long-gap (HIMMEL-1543), so the guard is
# deliberately bypassed there. This group is the dedicated coverage that it STILL
# fires: an explicit --time HH:MM more than 60 min out must REFUSE rc=9 without
# --long-gap, and --long-gap must sanction it. FAR_TIME is computed HERE, not the
# once-captured FUTURE_TIME, so it is genuinely >60 min out however long the run
# took to get here -- a single arm, so no aliasing/shared-time constraint.
G4_DIR="$HANDOVER_DIR/g4"; HO_FAR="$G4_DIR/far.md"; mk_ho "$HO_FAR"
FAR_TIME=$(python3 -c 'import datetime; print((datetime.datetime.now()+datetime.timedelta(hours=2)).strftime("%H:%M"))')
DB11=$(new_db "$TMP/db11.tasks")
out=$(SCHED_DB="$DB11" SCHED_DB_DIR="${DB11}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FAR_TIME" --handover "$HO_FAR" 2>&1)
rc=$?
assert_rc "G4.1 long-gap guard REFUSES a >60min arm without --long-gap (rc=9)" 9 "$rc" "$out"
assert_contains "G4.1 refused by the long-gap guard specifically (not another rc=9 path)" "Refusing without --long-gap" "$out"
assert_slots "G4.1 refused arm armed NO slot" 0 "$DB11" "${DB11}.atdir" "$out"
out=$(SCHED_DB="$DB11" SCHED_DB_DIR="${DB11}.atdir" PATH="$STUB:$PATH" bash "$ARM" --time "$FAR_TIME" --long-gap --handover "$HO_FAR" 2>&1)
rc=$?
assert_rc "G4.2 --long-gap SANCTIONS the >60min arm (rc=0)" 0 "$rc" "$out"
assert_slots "G4.2 sanctioned far arm armed ONE slot" 1 "$DB11" "${DB11}.atdir" "$out"
rm -f "$HANDOVER_DIR/.locks/arms.jsonl"

echo "---"
echo "FAILED=$FAILED"
[ "$FAILED" -eq 0 ]
