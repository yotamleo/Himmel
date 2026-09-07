#!/usr/bin/env bash
# Smoke test for scripts/hooks/check-oxlint-hardening.sh (HIMMEL-2163/2802).
# Hermetic stubs prove control-flow semantics; real pinned-oxlint fixtures prove
# clean and nested seeded-violation behavior. Only real bunx absence may skip.
set -uo pipefail

# grepq <text> [grep-args...] — no producer pipeline under pipefail.
grepq() { local _t="$1"; shift; grep -q "$@" <<< "$_t"; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GATE="$SCRIPT_DIR/check-oxlint-hardening.sh"
# shellcheck source=../lib/fixture-tempdir.sh
# shellcheck disable=SC1091
. "$SCRIPT_DIR/../lib/fixture-tempdir.sh"

BASH_ABS=$(command -v bash)
case "$BASH_ABS" in
    /*) ;;
    *) echo "FATAL: bash must resolve to an absolute path (got '$BASH_ABS')" >&2; exit 1 ;;
esac

FAILED=0
CLEANUP_PATHS=()
# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
    local path
    for path in ${CLEANUP_PATHS[@]+"${CLEANUP_PATHS[@]}"}; do rm -rf -- "$path"; done
}
trap cleanup EXIT

track_cleanup() {
    CLEANUP_PATHS+=("$1")
}

assert_eq() {
    local label="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     expected: $expected"
        echo "     actual:   $actual"
        FAILED=$((FAILED + 1))
    fi
}

assert_says() {
    local label="$1" needle="$2" text="$3"
    if grepq "$text" -- "$needle"; then
        echo "PASS $label"
    else
        echo "FAIL $label"
        echo "     output: $text"
        FAILED=$((FAILED + 1))
    fi
}

make_fixture() {
    local dir
    dir=$(fixture_mktemp_dir) || return 1
    mkdir -p "$dir/scripts/lanes" "$dir/bin"
    cat > "$dir/scripts/lanes/input.mjs" <<'EOF'
export function add(a, b) {
  return a + b;
}
EOF
    cat > "$dir/bin/bunx" <<EOF
#!$BASH_ABS
{
  printf 'cwd=%s\n' "\$PWD"
  printf 'arg=%s\n' "\$@"
} > "\${OXLINT_STUB_RECORD:?}"
case "\${OXLINT_STUB_MODE:-clean}" in
  clean)
    printf '%s\n' '{ "diagnostics": [], "number_of_files": 1, "number_of_rules": 23 }'
    exit 0
    ;;
  benign_stderr)
    printf '%s\n' 'bunx: package already cached' >&2
    printf '%s\n' '{ "diagnostics": [], "number_of_files": 1, "number_of_rules": 23 }'
    exit 0
    ;;
  finding)
    printf '%s\n' '{ "diagnostics": [{ "message": "seeded", "code": "eslint(no-self-compare)", "filename": "scripts/lanes/input.mjs" }], "number_of_files": 1, "number_of_rules": 23 }'
    exit 0
    ;;
  tool2)
    printf '%s\n' 'error: oxlint process failed before diagnostics' >&2
    exit 2
    ;;
  tool1)
    printf '%s\n' 'No files found to lint. Please check your paths and ignore patterns.' >&2
    exit 1
    ;;
  banner0)
    printf '%s\n' 'Error: package runner failed without findings JSON' >&2
    exit 0
    ;;
  no_diagnostics_key)
    printf '%s\n' '{ "number_of_files": 1, "number_of_rules": 23 }'
    exit 0
    ;;
  zero_files)
    printf '%s\n' '{ "diagnostics": [], "number_of_files": 0, "number_of_rules": 23 }'
    exit 0
    ;;
  missing_file_count)
    printf '%s\n' '{ "diagnostics": [], "number_of_rules": 23 }'
    exit 0
    ;;
  truncated)
    printf '%s\n' '{ "diagnostics": ['
    exit 0
    ;;
  error_plus_empty)
    printf '%s\n' 'error: runner failed' >&2
    printf '%s\n' '{ "diagnostics": [] }'
    exit 0
    ;;
esac
EOF
    chmod +x "$dir/bin/bunx"
    printf '%s' "$dir"
}

run_stub_case() {
    local dir="$1" mode="$2" record rc=0
    record="$dir/record.txt"
    STUB_RC=0
    STUB_OUT=$(cd "$dir" && PATH="$dir/bin:$PATH" \
      OXLINT_STUB_MODE="$mode" OXLINT_STUB_RECORD="$record" \
      "$BASH_ABS" "$GATE" 2>&1) || rc=$?
    STUB_RC=$rc
}

# Cleanup must treat every registered path literally. Spaces and glob syntax in
# an extracted worktree path must not split or expand into unrelated removals.
CLEANUP_SAFETY_ROOT=$(fixture_mktemp_dir) || exit 1
track_cleanup "$CLEANUP_SAFETY_ROOT"
CLEANUP_LITERAL="$CLEANUP_SAFETY_ROOT/literal * [x] path"
CLEANUP_SIBLING="$CLEANUP_SAFETY_ROOT/sibling must remain"
mkdir -p "$CLEANUP_LITERAL" "$CLEANUP_SIBLING"
(
    trap - EXIT
    CLEANUP_PATHS=("$CLEANUP_LITERAL")
    cleanup
)
if [ ! -e "$CLEANUP_LITERAL" ] && [ -d "$CLEANUP_SIBLING" ]; then
    echo "PASS cleanup removes a literal space/glob path without touching siblings"
else
    echo "FAIL cleanup must quote each registered space/glob path"
    FAILED=$((FAILED + 1))
fi

# The EXIT trap can fire before any track_cleanup call (e.g. an early
# fixture-creation failure). Bash 3.2 raises "unbound variable" under set -u
# for "${arr[@]}" on a still-empty array (fixed upstream in 4.4); this repo's
# hooks are pinned to 3.2 compatibility (scripts/hooks/CLAUDE.md), so cleanup
# must use the ${arr[@]+"${arr[@]}"} guard rather than a bare expansion.
if (
    trap - EXIT
    CLEANUP_PATHS=()
    cleanup
); then
    echo "PASS cleanup tolerates an empty CLEANUP_PATHS under set -u"
else
    echo "FAIL cleanup must tolerate an empty CLEANUP_PATHS under set -u"
    FAILED=$((FAILED + 1))
fi

# Source-level pin plus invocation-level proof from the stub record.
if grep -q '^OXLINT_VERSION=1\.81\.0$' "$GATE"; then
    echo "PASS gate pins OXLINT_VERSION=1.81.0"
else
    echo "FAIL gate must pin OXLINT_VERSION=1.81.0"
    FAILED=$((FAILED + 1))
fi

# --- clean JSON → pass, self-diagnose, invoke pinned package -----------------
CLEAN=$(make_fixture) || exit 1; track_cleanup "$CLEAN"
run_stub_case "$CLEAN" clean
assert_eq "clean findings JSON → gate passes" "0" "$STUB_RC"
assert_says "every run reports pinned version/root/cwd" \
  "check-oxlint-hardening: oxlint 1.81.0 root=$CLEAN cwd=$CLEAN" "$STUB_OUT"
assert_says "bunx invocation uses the pinned package" "arg=oxlint@1.81.0" "$(cat "$CLEAN/record.txt")"

BENIGN=$(make_fixture) || exit 1; track_cleanup "$BENIGN"
run_stub_case "$BENIGN" benign_stderr
assert_eq "clean findings JSON plus benign bunx stderr → gate passes" "0" "$STUB_RC"

# --- finding JSON → block ----------------------------------------------------
FINDING=$(make_fixture) || exit 1; track_cleanup "$FINDING"
run_stub_case "$FINDING" finding
assert_eq "finding JSON → gate blocks" "1" "$STUB_RC"
assert_says "finding → names offending rule" "no-self-compare" "$STUB_OUT"
assert_says "finding → names offending file" "scripts/lanes/input.mjs" "$STUB_OUT"

# --- every tool failure blocks loudly; bunx absence alone remains fail-open --
for mode in tool2 tool1 banner0 no_diagnostics_key zero_files missing_file_count truncated error_plus_empty; do
    TOOL=$(make_fixture) || exit 1; track_cleanup "$TOOL"
    run_stub_case "$TOOL" "$mode"
    assert_eq "$mode tool failure → gate blocks" "1" "$STUB_RC"
    assert_says "$mode tool failure → loud WARN" "WARN check-oxlint-hardening: oxlint" "$STUB_OUT"
done
assert_says "stderr tool failure → original diagnostic remains readable" "error: runner failed" "$STUB_OUT"

NOTOOL=$(make_fixture) || exit 1; track_cleanup "$NOTOOL"
EMPTY_PATH=$(fixture_mktemp_dir) || exit 1; track_cleanup "$EMPTY_PATH"
rc=0
out=$(cd "$NOTOOL" && PATH="$EMPTY_PATH" "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "bunx absent → sole fail-open case" "0" "$rc"
assert_says "bunx absent → loud WARN" "WARN check-oxlint-hardening: bunx not found" "$out"

NOJQ=$(make_fixture) || exit 1; track_cleanup "$NOJQ"
rc=0
out=$(cd "$NOJQ" && PATH="$NOJQ/bin" \
  OXLINT_STUB_MODE=clean OXLINT_STUB_RECORD="$NOJQ/record.txt" \
  "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "jq absent with bunx present → gate blocks" "1" "$rc"
assert_says "jq absent → loud WARN" "WARN check-oxlint-hardening: jq not found" "$out"

# --- plain fixture nested in a parent git repo → lint fixture, never parent --
# This reproduces the authenticated-console hypothesis deterministically: a bare
# git rev-parse from this directory resolves the worktree parent. The gate must
# instead select this repo-shaped fixture root (or refuse); this suite chooses
# and pins the useful behavior: lint it.
NESTED=$(mktemp -d "$SCRIPT_DIR/.oxlint-nested.XXXXXX") || exit 1
track_cleanup "$NESTED"
mkdir -p "$NESTED/scripts/lanes" "$NESTED/bin"
printf '%s\n' 'export const nestedFixture = true;' > "$NESTED/scripts/lanes/input.mjs"
cp "$CLEAN/bin/bunx" "$NESTED/bin/bunx"
run_stub_case "$NESTED" clean
assert_eq "nested plain fixture → gate lints fixture" "0" "$STUB_RC"
assert_says "nested plain fixture → resolved root is fixture, not parent repo" \
  "root=$NESTED cwd=$NESTED" "$STUB_OUT"
assert_says "nested plain fixture → bunx runs from fixture" "cwd=$NESTED" "$(cat "$NESTED/record.txt")"

# --- real pinned oxlint integration ------------------------------------------
# Stubs pin control flow; these cases prove the actual pinned package accepts a
# clean tree and catches the audited no-self-compare rule. Skip only when bunx
# itself is unavailable.
if command -v bunx >/dev/null 2>&1; then
    REAL_CLEAN=$(fixture_mktemp_dir) || exit 1
    track_cleanup "$REAL_CLEAN"
    mkdir -p "$REAL_CLEAN/scripts/lanes"
    printf '%s\n' 'export const cleanFixture = true;' > "$REAL_CLEAN/scripts/lanes/input.mjs"
    rc=0
    out=$(cd "$REAL_CLEAN" && "$BASH_ABS" "$GATE" 2>&1) || rc=$?
    assert_eq "real pinned oxlint → clean fixture passes" "0" "$rc"
    assert_says "real clean run → reports pinned version" "oxlint 1.81.0" "$out"

    REAL_IGNORED=$(fixture_mktemp_dir) || exit 1
    track_cleanup "$REAL_IGNORED"
    mkdir -p "$REAL_IGNORED/scripts/lanes/fixtures"
    printf '%s\n' 'export const ignoredFixture = true;' > "$REAL_IGNORED/scripts/lanes/fixtures/input.mjs"
    real_probe_rc=0
    real_probe_err="$REAL_IGNORED/probe.err"
    real_probe=$(cd "$REAL_IGNORED" && bunx oxlint@1.81.0 --format json \
      --ignore-pattern '**/fixtures/**' scripts/lanes 2>"$real_probe_err") || real_probe_rc=$?
    assert_eq "real pinned oxlint all-ignored probe → refuses instead of returning zero-file success" "1" "$real_probe_rc"
    assert_says "real pinned oxlint all-ignored probe → reports no files on stdout" \
      "No files found to lint" "$real_probe"
    assert_says "real pinned oxlint all-ignored probe → includes a zero-file JSON envelope" \
      '"number_of_files": 0' "$real_probe"
    assert_eq "real pinned oxlint all-ignored probe → emits no stderr" "" "$(cat "$real_probe_err")"
    rc=0
    out=$(cd "$REAL_IGNORED" && "$BASH_ABS" "$GATE" 2>&1) || rc=$?
    assert_eq "real pinned oxlint → all-ignored fixture blocks as unevaluated" "1" "$rc"

    REAL_NESTED=$(mktemp -d "$SCRIPT_DIR/.oxlint-real-nested.XXXXXX") || exit 1
    track_cleanup "$REAL_NESTED"
    mkdir -p "$REAL_NESTED/scripts/lanes"
    cat > "$REAL_NESTED/scripts/lanes/seeded.mjs" <<'EOF'
export function seededViolation(value) {
  return value === value;
}
EOF
    rc=0
    out=$(cd "$REAL_NESTED" && "$BASH_ABS" "$GATE" 2>&1) || rc=$?
    assert_eq "real pinned oxlint → nested seeded violation blocks" "1" "$rc"
    assert_says "real nested violation → gate selects fixture root" "root=$REAL_NESTED cwd=$REAL_NESTED" "$out"
    assert_says "real nested violation → names no-self-compare" "no-self-compare" "$out"
    assert_says "real nested violation → names seeded file" "scripts/lanes/seeded.mjs" "$out"
else
    echo "SKIP real pinned oxlint integration: bunx not on PATH"
fi

# --- inconsistent resolver result → refuse before invoking bunx --------------
OUTSIDE=$(make_fixture) || exit 1; track_cleanup "$OUTSIDE"
cat > "$OUTSIDE/bin/git" <<EOF
#!$BASH_ABS
if [ "\${1:-}" = rev-parse ]; then printf '%s\n' '$OUTSIDE/not-an-ancestor'; exit 0; fi
exit 1
EOF
chmod +x "$OUTSIDE/bin/git"
rc=0
out=$(cd "$OUTSIDE" && PATH="$OUTSIDE/bin:$PATH" \
  OXLINT_STUB_MODE=clean OXLINT_STUB_RECORD="$OUTSIDE/record.txt" \
  "$BASH_ABS" "$GATE" 2>&1) || rc=$?
assert_eq "cwd outside resolved root → gate refuses" "1" "$rc"
assert_says "cwd outside resolved root → loud diagnostic" "outside resolved root" "$out"
if [ ! -e "$OUTSIDE/record.txt" ]; then
    echo "PASS cwd/root refusal happens before bunx"
else
    echo "FAIL cwd/root refusal must happen before bunx"
    FAILED=$((FAILED + 1))
fi

echo ""
if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "$FAILED case(s) FAILED"
exit 1
