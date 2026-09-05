#!/usr/bin/env bash
# test-arm-resume-base.sh — HIMMEL-2383 base verification arm guard.
#
# Console ruling 66: a leg must not be armed on a fence whose merged PRs
# still have a pending or red after-report. arm-resume.sh reads the
# handover's own `fence:` frontmatter key and, when present, shells out to
# scripts/console/base-status.sh (through the REAL production script — it
# has its own GH_CMD test seam, so this suite stubs `gh` via GH_CMD rather
# than copying the script tree the way test-arm-resume-tier.sh's sibling
# fable-tier guard does not need to).
#
# Uses --dry-run throughout so no real scheduler job is ever created. Harness
# shields, helpers, and the scheduler stub are copied from
# scripts/handover/test-arm-resume-tier.sh (do not invent a new hermetic
# pattern).
set -uo pipefail

ARM="$(cd "$(dirname "$0")" && pwd)/arm-resume.sh"
[ -x "$ARM" ] || chmod +x "$ARM"

TMP=$(mktemp -d "${TMPDIR:-/tmp}/arm-resume-base.XXXXXX") || {
    echo "ERR test-arm-resume-base: mktemp -d failed" >&2
    exit 1
}
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Hermetic shields — copied verbatim from test-arm-resume-tier.sh.
# ---------------------------------------------------------------------------
export SKILL_TELEMETRY_DIR="$TMP/telemetry-default"
unset SKILL_TELEMETRY_DISABLE 2>/dev/null || true
unset ARM_NAME_TEMPLATE 2>/dev/null || true
unset RESUME_SLOT_THRESHOLD 2>/dev/null || true
unset CR_REQUIRE_CROSS_MODEL CR_FLOOR_FALLBACK 2>/dev/null || true
export WORKER_BRIDGE_ROOT="$TMP/worker-bridge-shield"
export WORKSPACE_TRUST_CONFIG="$TMP/claude-trust.json"
export HIMMEL_FLOW_RUNS_LEDGER="$TMP/flow-runs.jsonl"
export ARM_TEMP_CWD_OK=1
export ARM_RESUME_DOTENV_ROOT="$TMP/dotenv-shield"
mkdir -p "$ARM_RESUME_DOTENV_ROOT"
unset ARMAUTOMERGE CR_MERGE_GATE_OK 2>/dev/null || true

# ---------------------------------------------------------------------------
# Helpers — same idiom as test-arm-resume-tier.sh
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
# Fixtures
# ---------------------------------------------------------------------------
WORK_REPO="$TMP/work-repo"
mkdir -p "$WORK_REPO"
git init -q "$WORK_REPO"

HANDOVER_DIR="$TMP/statedocs/handovers"
mkdir -p "$HANDOVER_DIR"
git init -q "$TMP/statedocs"

_FT_FILE="$TMP/future-time.cache"
future_time() {
    local _now _target _value
    _now=$(date +%s)
    _target=0; _value=""
    [ -s "$_FT_FILE" ] && read -r _target _value < "$_FT_FILE"
    if [ -z "$_value" ] || [ "$(( _target - _now ))" -lt 600 ]; then
        _target=$(( _now + 1800 ))
        _value=$(python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1])).strftime('%H:%M'))" "$_target")
        printf '%s %s\n' "$_target" "$_value" > "$_FT_FILE"
    fi
    printf '%s' "$_value"
}

# make_handover [fence-line] — a minimal valid handover; fence-line, if
# given, is written verbatim as a 'fence: ...' frontmatter key.
make_handover() {
    local fence="${1:-}"
    local path="$HANDOVER_DIR/handover-$RANDOM.md"
    {
        printf -- '---\n'
        printf 'session_kind: test\n'
        printf 'resume_cwd: %s\n' "$WORK_REPO"
        [ -n "$fence" ] && printf 'fence: %s\n' "$fence"
        printf -- '---\n'
        printf '# Test handover\n'
    } > "$path"
    printf '%s' "$path"
}

# ---------------------------------------------------------------------------
# Scheduler stub — identical to test-arm-resume-tier.sh's SCHED_STUB_T17.
# ---------------------------------------------------------------------------
SCHED_STUB="$TMP/sched-stub"
mkdir -p "$SCHED_STUB"
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
cat > "$SCHED_STUB/atq" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/at" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$SCHED_STUB/powershell" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SCHED_STUB/schtasks" "$SCHED_STUB/atq" "$SCHED_STUB/at" "$SCHED_STUB/powershell"

# ---------------------------------------------------------------------------
# gh stub — base-status.sh (the REAL production script, called by
# arm-resume.sh's SCRIPT_DIR-relative path) honors GH_CMD, so this drives it
# without copying arm-resume.sh or base-status.sh anywhere.
# ---------------------------------------------------------------------------
# gh_stub <default-branch> <merged-prs-json> <comments-json-by-pr...>
# comments args are "NUM:json" pairs, e.g. "77:{\"comments\":[...]}"
make_gh_stub() {
    local path="$1" default_branch="$2" prs_json="$3"; shift 3
    {
        echo '#!/usr/bin/env bash'
        echo 'case "$* " in'
        printf '    *"repo view"*defaultBranchRef*) echo %q ;;\n' "$default_branch"
        printf '    *"pr list"*"state merged"*) cat <<'"'"'JSON'"'"'\n%s\nJSON\n        ;;\n' "$prs_json"
        for pair in "$@"; do
            local num="${pair%%:*}" json="${pair#*:}"
            printf '    *"pr view %s"*"comments"*) echo %q ;;\n' "$num" "$json"
        done
        echo '    *) echo "gh stub: unhandled: $*" >&2; exit 99 ;;'
        echo 'esac'
    } > "$path"
    chmod +x "$path"
}

GH_STUB_DIR="$TMP/gh-stub"
mkdir -p "$GH_STUB_DIR"

run_arm() {
    SCHTASKS_CMD="$SCHED_STUB/schtasks" PATH="$SCHED_STUB:$PATH" bash "$ARM" "$@"
}

# ---------------------------------------------------------------------------
# (a) no fence: key at all -> base-status.sh never invoked (a gh call would
#     hit the "unhandled" stub and exit 99, which would surface as a WARN,
#     not a silent pass — so a clean rc=0 here IS the proof it was skipped).
# ---------------------------------------------------------------------------
GH_NOFENCE="$GH_STUB_DIR/gh-nofence"
cat > "$GH_NOFENCE" <<'EOF'
#!/usr/bin/env bash
echo "gh stub: should not be called when no fence: key is present" >&2
exit 99
EOF
chmod +x "$GH_NOFENCE"
HO_A=$(make_handover)
out=$(GH_CMD="$GH_NOFENCE" run_arm --time "$(future_time)" --handover "$HO_A" --dry-run 2>&1)
rc=$?
assert_rc "a: no fence: key -> arm proceeds, base-status never called" 0 "$rc"
assert_not_contains "a: no WARN about base-status" "base-status.sh" "$out"

# ---------------------------------------------------------------------------
# (b) fence declared, merged PR touching it, NO after-report comment yet
#     -> PENDING -> refused, rc=21.
# ---------------------------------------------------------------------------
GH_PENDING="$GH_STUB_DIR/gh-pending"
make_gh_stub "$GH_PENDING" main \
    '[{"number":501,"headRefOid":"sha501","files":[{"path":"scripts/hooks/foo.sh"}]}]' \
    '501:{"comments":[{"body":"@coderabbitai review"}]}'
HO_B=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_PENDING" run_arm --time "$(future_time)" --handover "$HO_B" --dry-run 2>&1)
rc=$?
assert_rc "b: pending after-report -> refused" 21 "$rc"
assert_contains "b: refusal names the fence" "fence 'scripts/hooks'" "$out"
assert_contains "b: refusal shows the PENDING line" "PENDING PR 501" "$out"
assert_contains "b: refusal names the escape hatch" "--provisional-base-ok" "$out"

# ---------------------------------------------------------------------------
# (c) same fixture, --provisional-base-ok -> WARNS, arms anyway (rc=0).
# ---------------------------------------------------------------------------
HO_C=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_PENDING" run_arm --time "$(future_time)" --handover "$HO_C" --dry-run --provisional-base-ok 2>&1)
rc=$?
assert_rc "c: --provisional-base-ok arms despite pending" 0 "$rc"
assert_contains "c: warns loudly" "WARN arm-resume: arming on a PROVISIONAL base" "$out"
assert_contains "c: warning carries ruling 66" "ruling 66" "$out"
assert_contains "c: warning shows the PENDING line" "PENDING PR 501" "$out"

# ---------------------------------------------------------------------------
# (d) a RED after-report (FAIL > 0) -> refused, rc=21, without
#     --provisional-base-ok.
# ---------------------------------------------------------------------------
GH_RED="$GH_STUB_DIR/gh-red"
make_gh_stub "$GH_RED" main \
    '[{"number":502,"headRefOid":"sha502","files":[{"path":"scripts/hooks/bar.sh"}]}]' \
    '502:{"comments":[{"body":"== Summary ==\n head: sha502\n scope: scripts/hooks\n PASS: 3\n FAIL: 2\n"}]}'
HO_D=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_RED" run_arm --time "$(future_time)" --handover "$HO_D" --dry-run 2>&1)
rc=$?
assert_rc "d: red after-report -> refused" 21 "$rc"
assert_contains "d: refusal shows the RED line" "RED PR 502" "$out"

# ---------------------------------------------------------------------------
# (e) a CLEAN after-report (no pending/red PRs) -> arm proceeds silently.
# ---------------------------------------------------------------------------
GH_CLEAN="$GH_STUB_DIR/gh-clean"
make_gh_stub "$GH_CLEAN" main \
    '[{"number":503,"headRefOid":"sha503","files":[{"path":"scripts/hooks/baz.sh"}]}]' \
    '503:{"comments":[{"body":"== Summary ==\n head: sha503\n scope: scripts/hooks\n PASS: 9\n FAIL: 0\n"}]}'
HO_E=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_CLEAN" run_arm --time "$(future_time)" --handover "$HO_E" --dry-run 2>&1)
rc=$?
assert_rc "e: clean fence -> arm proceeds" 0 "$rc"
assert_not_contains "e: no refusal text" "refusing to arm" "$out"
assert_not_contains "e: no provisional warning" "PROVISIONAL base" "$out"

# ---------------------------------------------------------------------------
# (f) HIMMEL-2383 CR finding codex-1: when base-status.sh ITSELF cannot
#     certify the fence (a gh query error — not a clean/pending/red read),
#     that refuses exactly like a certified-dirty fence, never a silent
#     unchecked proceed. --provisional-base-ok covers this case too.
# ---------------------------------------------------------------------------
GH_QUERYFAIL="$GH_STUB_DIR/gh-queryfail"
cat > "$GH_QUERYFAIL" <<'EOF'
#!/usr/bin/env bash
case "$* " in
    *"repo view"*defaultBranchRef*) echo "gh: rate limited" >&2; exit 1 ;;
    *) echo "gh stub: unhandled: $*" >&2; exit 99 ;;
esac
EOF
chmod +x "$GH_QUERYFAIL"
HO_F=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_QUERYFAIL" run_arm --time "$(future_time)" --handover "$HO_F" --dry-run 2>&1)
rc=$?
assert_rc "f: base-status.sh query error -> refused, not silently proceeded" 21 "$rc"
assert_contains "f: refusal names the fence" "fence 'scripts/hooks'" "$out"

HO_G=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_QUERYFAIL" run_arm --time "$(future_time)" --handover "$HO_G" --dry-run --provisional-base-ok 2>&1)
rc=$?
assert_rc "g: --provisional-base-ok also covers a query error" 0 "$rc"
assert_contains "g: warns loudly on the query error" "WARN arm-resume: arming on a PROVISIONAL base" "$out"

# ---------------------------------------------------------------------------
# (h) HIMMEL-2383 CR finding codex-2 (round 2): base-status.sh must run FROM
#     the resolved work repo (RESUME_CWD / resume_cwd:), not the launching
#     session's own cwd — a cross-repo handover would otherwise certify the
#     WRONG repo's fence. The gh stub itself asserts its cwd.
# ---------------------------------------------------------------------------
GH_CWDCHECK="$GH_STUB_DIR/gh-cwdcheck"
WORK_REPO_NORM=$(cd "$WORK_REPO" && pwd)
cat > "$GH_CWDCHECK" <<EOF
#!/usr/bin/env bash
if [ "\$(pwd)" != "$WORK_REPO_NORM" ]; then
    echo "gh stub: invoked from wrong cwd '\$(pwd)', expected '$WORK_REPO_NORM'" >&2
    exit 95
fi
case "\$* " in
    *"repo view"*defaultBranchRef*) echo "main" ;;
    *"pr list"*"state merged"*) echo "[]" ;;
    *) echo "gh stub: unhandled: \$*" >&2; exit 99 ;;
esac
EOF
chmod +x "$GH_CWDCHECK"
HO_H=$(make_handover "scripts/hooks")
out=$(GH_CMD="$GH_CWDCHECK" run_arm --time "$(future_time)" --handover "$HO_H" --dry-run 2>&1)
rc=$?
assert_rc "h: base-status.sh runs from the resolved work repo, not the launch cwd" 0 "$rc"
assert_not_contains "h: gh stub never saw the wrong-cwd refusal" "invoked from wrong cwd" "$out"

echo "---"
if [ "$FAILED" -gt 0 ]; then
    echo "FAIL $FAILED case(s)"
    exit 1
fi
echo "PASS all cases"
exit 0
