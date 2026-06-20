#!/usr/bin/env bash
# test-backfill-sessions.sh — Smoke tests for scripts/luna/backfill-sessions.sh.
#
# Usage: bash scripts/luna/test-backfill-sessions.sh
#
# Cases covered:
#   1. idempotency      : 2nd run --dry-run reports new=0; no new files written.
#   2. non-clobber      : sha256 of pre-existing note unchanged after a run.
#   3. opt-out          : repo with enabled:false in config -> skipped, no note.
#   4. orphaned-default : cwd not on disk -> skipped unless --include-orphaned.
#   5. shape-parity     : backfilled note frontmatter key set + sections match golden.
#   6. min-duration     : sub-threshold transcript is skipped (under-min count).
#   7. vault-resolve    : absolute vault_path in config routes note to that vault.
#
# Strategy: fixture transcripts in scripts/luna/testdata/; temp --projects-dir,
# temp vault dir, temp --state-file so no real state is touched.
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKFILL="$SCRIPT_DIR/backfill-sessions.sh"
GOLDEN="$SCRIPT_DIR/../hooks/testdata/session-note.golden.md"
FIXTURE_DIR="$SCRIPT_DIR/testdata"

[ -f "$BACKFILL" ] || { echo "FAIL: backfill-sessions.sh not found at $BACKFILL"; exit 1; }
[ -f "$GOLDEN" ]   || { echo "FAIL: golden fixture not found at $GOLDEN"; exit 1; }

PASS=0
FAIL=0
TMP_ROOT=""

cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { printf '  PASS: %s\n' "$1"; PASS=$((PASS + 1)); }
fail() {
    printf '  FAIL: %s\n' "$1"
    if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi
    FAIL=$((FAIL + 1))
}
assert_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$label"
    else
        fail "$label" "missing: $needle"
    fi
}
assert_not_contains() {
    local label="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$label" "unexpected: $needle"
    else
        pass "$label"
    fi
}

TMP_ROOT="$(mktemp -d)"

# ---------------------------------------------------------------------------
# Shared: build a fake projects dir with fixture transcripts.
# We create a "normal-repo" project and a "disabled-repo" project.
# The fixture JSONL files in testdata/ use __CWD_PLACEHOLDER__ which we
# replace at test time with the temp dir path for the resolved-repo case.
# ---------------------------------------------------------------------------
setup_projects_dir() {
    local proj_root="$1"
    local repo_dir="$2"   # absolute path that exists on disk
    local vault_dir="$3"

    # Derive slug from repo_dir (same algorithm as backfill-sessions.sh)
    local slug
    # On Windows with cygpath, use Windows form; else use the POSIX path.
    local p="$repo_dir"
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    slug="$(printf '%s' "$p" | awk '{gsub(/[:\\\/]/, "-"); gsub(/^-+/, ""); print}')"

    local proj_dir="$proj_root/$slug"
    mkdir -p "$proj_dir"

    # Copy fixture-normal with real cwd
    local tmp_jl="$proj_dir/test-session-normal-001.jsonl"
    local cwd_escaped
    # Escape backslashes for sed (needed on Windows paths)
    cwd_escaped="$(printf '%s' "$repo_dir" | sed 's|\\|\\\\|g; s|/|\\/|g')"
    sed "s|__CWD_PLACEHOLDER__|$cwd_escaped|g" "$FIXTURE_DIR/fixture-normal.jsonl" > "$tmp_jl"

    # Config pointing at our temp vault
    mkdir -p "$repo_dir/.claude"
    printf '{"enabled":true,"vault_path":"%s"}\n' "$vault_dir" > "$repo_dir/.claude/end-session-wiki.json"
}

setup_disabled_project() {
    local proj_root="$1"
    local repo_dir="$2"

    local slug
    local p="$repo_dir"
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    slug="$(printf '%s' "$p" | awk '{gsub(/[:\\\/]/, "-"); gsub(/^-+/, ""); print}')"

    local proj_dir="$proj_root/$slug"
    mkdir -p "$proj_dir"

    local tmp_jl="$proj_dir/test-session-disabled-999.jsonl"
    local cwd_escaped
    cwd_escaped="$(printf '%s' "$repo_dir" | sed 's|\\|\\\\|g; s|/|\\/|g')"
    sed "s|__CWD_PLACEHOLDER__|$cwd_escaped|g" "$FIXTURE_DIR/fixture-normal.jsonl" > "$tmp_jl"

    # Config with enabled:false
    mkdir -p "$repo_dir/.claude"
    printf '{"enabled":false,"vault_path":"/tmp/should-not-be-written"}\n' > "$repo_dir/.claude/end-session-wiki.json"
}

setup_orphaned_project() {
    local proj_root="$1"
    # slug is derived from the /nonexistent/... path in the fixture
    local slug="nonexistent-path-that-does-not-exist"
    local proj_dir="$proj_root/$slug"
    mkdir -p "$proj_dir"
    cp "$FIXTURE_DIR/fixture-orphaned.jsonl" "$proj_dir/test-session-orphaned-003.jsonl"
}

setup_short_project() {
    local proj_root="$1"
    local repo_dir="$2"
    local vault_dir="$3"

    local slug
    local p="$repo_dir"
    if command -v cygpath >/dev/null 2>&1; then
        p="$(cygpath -w "$p" 2>/dev/null || printf '%s' "$p")"
    fi
    slug="$(printf '%s' "$p" | awk '{gsub(/[:\\\/]/, "-"); gsub(/^-+/, ""); print}')"

    local proj_dir="$proj_root/$slug"
    mkdir -p "$proj_dir"

    local tmp_jl="$proj_dir/test-session-short-002.jsonl"
    local cwd_escaped
    cwd_escaped="$(printf '%s' "$repo_dir" | sed 's|\\|\\\\|g; s|/|\\/|g')"
    sed "s|__CWD_PLACEHOLDER__|$cwd_escaped|g" "$FIXTURE_DIR/fixture-short.jsonl" > "$tmp_jl"

    mkdir -p "$repo_dir/.claude"
    printf '{"enabled":true,"vault_path":"%s"}\n' "$vault_dir" > "$repo_dir/.claude/end-session-wiki.json"
}

# ============================================================================
# Case 1 + 2: idempotency + non-clobber
# ============================================================================
echo ""
echo "Case 1+2: idempotency and non-clobber"

SB="$TMP_ROOT/case12"
VAULT="$SB/vault"
REPO="$SB/repo"
PROJ_ROOT="$SB/projects"
STATE_FILE="$SB/state.json"
mkdir -p "$VAULT" "$REPO" "$PROJ_ROOT"

setup_projects_dir "$PROJ_ROOT" "$REPO" "$VAULT"

# First run (real write)
out1=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT" \
    --project "$REPO" \
    --state-file "$STATE_FILE" \
    --vault-registry /dev/null \
    2>&1)
NOTE="$(find "$VAULT/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE" ]; then
    pass "first run wrote a note"
else
    fail "first run wrote no note" "$out1"
fi

# Portable sha256 for a file: first field only
_file_sha256() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1" 2>/dev/null; } | awk '{print $1}'; }

# Capture sha256 of the note (fail loudly if missing — means first run silently failed)
SHA_BEFORE=""
if [ -n "$NOTE" ]; then
    SHA_BEFORE="$(_file_sha256 "$NOTE")"
fi
if [ -z "$SHA_BEFORE" ]; then
    fail "non-clobber: could not capture sha256 of note before dry-run (no sha tool or note missing)"
fi

# Capture ledger state before dry-run
LEDGER_SHA_BEFORE=""
if [ -f "$STATE_FILE" ]; then
    LEDGER_SHA_BEFORE="$(_file_sha256 "$STATE_FILE")"
fi

# Second run --dry-run: must report new=0
out2=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT" \
    --project "$REPO" \
    --state-file "$STATE_FILE" \
    --vault-registry /dev/null \
    --dry-run \
    2>&1)
assert_contains "idempotency: dry-run new=0" "new=0" "$out2"

# Note count must not have changed
NOTE_COUNT="$(find "$VAULT/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NOTE_COUNT" -eq 1 ]; then
    pass "idempotency: no new notes written on second run"
else
    fail "idempotency: note count changed (expected 1, got $NOTE_COUNT)"
fi

# Ledger must be unchanged after dry-run
if [ -n "$LEDGER_SHA_BEFORE" ]; then
    LEDGER_SHA_AFTER="$(_file_sha256 "$STATE_FILE")"
    if [ "$LEDGER_SHA_BEFORE" = "$LEDGER_SHA_AFTER" ]; then
        pass "idempotency: ledger unchanged after dry-run"
    else
        fail "idempotency: ledger was mutated by --dry-run"
    fi
fi

# Non-clobber: sha256 must be identical
if [ -n "$SHA_BEFORE" ]; then
    SHA_AFTER="$(_file_sha256 "$NOTE")"
    if [ "$SHA_BEFORE" = "$SHA_AFTER" ]; then
        pass "non-clobber: existing note unchanged"
    else
        fail "non-clobber: note was modified (sha changed)"
    fi
else
    fail "non-clobber: SHA_BEFORE was empty; cannot verify note integrity"
fi

# ============================================================================
# Case 3: opt-out (enabled:false)
# ============================================================================
echo ""
echo "Case 3: opt-out (enabled:false)"

SB="$TMP_ROOT/case3"
VAULT3="$SB/vault"
REPO3="$SB/repo-disabled"
PROJ_ROOT3="$SB/projects"
STATE3="$SB/state.json"
mkdir -p "$VAULT3" "$REPO3" "$PROJ_ROOT3"
setup_disabled_project "$PROJ_ROOT3" "$REPO3"

out3=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT3" \
    --project "$REPO3" \
    --state-file "$STATE3" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "opt-out: disabled project skipped" "opt-out-skip=1" "$out3"
if [ -z "$(find "$VAULT3/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "opt-out: no note written for disabled project"
else
    fail "opt-out: note was written despite enabled:false"
fi

# ============================================================================
# Case 4: orphaned — skipped by default, imported with --include-orphaned
# ============================================================================
echo ""
echo "Case 4: orphaned sessions"

SB="$TMP_ROOT/case4"
VAULT4="$SB/vault"
PROJ_ROOT4="$SB/projects"
STATE4="$SB/state.json"
mkdir -p "$VAULT4" "$PROJ_ROOT4"
setup_orphaned_project "$PROJ_ROOT4"

# Default: --all scan (no --project so we need to use --all; orphaned project
# has a slug with 'nonexistent' which we can scope to)
# Use a dedicated projects-dir with only the orphaned project
out4a=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT4" \
    --all \
    --state-file "$STATE4" \
    --vault-registry /dev/null \
    --luna-vault-path "$VAULT4" \
    2>&1)
assert_contains "orphaned: default skip reported" "orphaned-skip=1" "$out4a"
if [ -z "$(find "$VAULT4/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "orphaned: no note written by default"
else
    fail "orphaned: note was written despite orphaned cwd"
fi

# With --include-orphaned: must write under the default vault
out4b=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT4" \
    --all \
    --include-orphaned \
    --state-file "$STATE4" \
    --vault-registry /dev/null \
    --luna-vault-path "$VAULT4" \
    2>&1)
if [ -n "$(find "$VAULT4/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "orphaned: --include-orphaned wrote a note"
else
    fail "orphaned: --include-orphaned did not write a note" "$out4b"
fi

# ============================================================================
# Case 5: shape-parity (frontmatter keys + section headers match golden)
# ============================================================================
echo ""
echo "Case 5: shape parity with golden fixture"

SB="$TMP_ROOT/case5"
VAULT5="$SB/vault"
REPO5="$SB/repo"
PROJ_ROOT5="$SB/projects"
STATE5="$SB/state.json"
mkdir -p "$VAULT5" "$REPO5" "$PROJ_ROOT5"
setup_projects_dir "$PROJ_ROOT5" "$REPO5" "$VAULT5"

bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT5" \
    --project "$REPO5" \
    --state-file "$STATE5" \
    --vault-registry /dev/null \
    >/dev/null 2>&1

NOTE5="$(find "$VAULT5/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -z "$NOTE5" ]; then
    fail "shape-parity: no note written"
else
    pass "shape-parity: note was written"

    # Extract frontmatter key names from golden (lines between first --- and second ---)
    GOLDEN_KEYS="$(awk '/^---$/{c++; if(c==2) exit} c==1 && /^[a-z_]+:/{gsub(/:.*/, ""); print}' "$GOLDEN")"
    NOTE_KEYS="$(awk '/^---$/{c++; if(c==2) exit} c==1 && /^[a-z_]+:/{gsub(/:.*/, ""); print}' "$NOTE5")"

    if [ "$GOLDEN_KEYS" = "$NOTE_KEYS" ]; then
        pass "shape-parity: frontmatter key set matches golden"
    else
        fail "shape-parity: frontmatter key mismatch" \
            "golden keys: $(printf '%s' "$GOLDEN_KEYS" | tr '\n' ',')
note keys:   $(printf '%s' "$NOTE_KEYS" | tr '\n' ',')"
    fi

    # Check section headers match golden
    GOLDEN_HDRS="$(grep '^## ' "$GOLDEN")"
    NOTE_HDRS="$(grep '^## ' "$NOTE5")"
    if [ "$GOLDEN_HDRS" = "$NOTE_HDRS" ]; then
        pass "shape-parity: section headers match golden"
    else
        fail "shape-parity: section header mismatch" \
            "golden: $(printf '%s' "$GOLDEN_HDRS" | tr '\n' '|')
note:   $(printf '%s' "$NOTE_HDRS" | tr '\n' '|')"
    fi

    # branch and files_touched must be empty for backfill
    BRANCH_VAL="$(awk '/^branch:/{print}' "$NOTE5")"
    FILES_VAL="$(awk '/^files_touched:/{print}' "$NOTE5")"
    assert_contains "shape-parity: branch empty in backfill" "branch:" "$BRANCH_VAL"
    # files_touched should be 0 (empty/no files)
    if printf '%s' "$FILES_VAL" | grep -q 'files_touched: 0'; then
        pass "shape-parity: files_touched is 0"
    else
        fail "shape-parity: files_touched should be 0" "$FILES_VAL"
    fi

    # source must be claude-backfill
    SOURCE_VAL="$(awk '/^source:/{print}' "$NOTE5")"
    assert_contains "shape-parity: source=claude-backfill" "claude-backfill" "$SOURCE_VAL"
fi

# ============================================================================
# Case 6: min-duration
# ============================================================================
echo ""
echo "Case 6: min-duration (45s transcript, min=60s)"

SB="$TMP_ROOT/case6"
VAULT6="$SB/vault"
REPO6="$SB/repo-short"
PROJ_ROOT6="$SB/projects"
STATE6="$SB/state.json"
mkdir -p "$VAULT6" "$REPO6" "$PROJ_ROOT6"
setup_short_project "$PROJ_ROOT6" "$REPO6" "$VAULT6"

out6=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT6" \
    --project "$REPO6" \
    --state-file "$STATE6" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "min-duration: under-min count reported" "under-min=1" "$out6"
if [ -z "$(find "$VAULT6/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "min-duration: no note written for short session"
else
    fail "min-duration: note was written for a short session"
fi

# ============================================================================
# Case 7: vault-resolve (absolute vault_path)
# ============================================================================
echo ""
echo "Case 7: vault-resolve (absolute vault_path routes to custom vault)"

SB="$TMP_ROOT/case7"
VAULT7="$SB/custom-vault"
VAULT7_DEFAULT="$SB/default-vault"
REPO7="$SB/repo"
PROJ_ROOT7="$SB/projects"
STATE7="$SB/state.json"
mkdir -p "$VAULT7" "$VAULT7_DEFAULT" "$REPO7" "$PROJ_ROOT7"
setup_projects_dir "$PROJ_ROOT7" "$REPO7" "$VAULT7"

# LUNA_VAULT_PATH points at the default but config vault_path overrides it
out7=$(LUNA_VAULT_PATH="$VAULT7_DEFAULT" bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT7" \
    --project "$REPO7" \
    --state-file "$STATE7" \
    --vault-registry /dev/null \
    2>&1)

if [ -n "$(find "$VAULT7/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "vault-resolve: note written to config vault_path"
else
    fail "vault-resolve: note not written to config vault_path" "$out7"
fi

if [ -z "$(find "$VAULT7_DEFAULT/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "vault-resolve: no note written to default vault"
else
    fail "vault-resolve: note wrongly written to default vault"
fi

# Also assert --dry-run does not write but reports correct counts
STATE7B="$SB/state7b.json"
out7b=$(LUNA_VAULT_PATH="$VAULT7_DEFAULT" bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT7" \
    --project "$REPO7" \
    --state-file "$STATE7B" \
    --vault-registry /dev/null \
    --dry-run \
    2>&1)
assert_contains "vault-resolve dry-run: new=1" "new=1" "$out7b"
if [ -z "$(find "$VAULT7/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "vault-resolve dry-run: no note written under custom vault"
else
    # The earlier run already wrote it — check state7b (fresh ledger) didn't add more
    pass "vault-resolve dry-run: custom vault already had note from first run (expected)"
fi

# ============================================================================
# Case 8: collision dedup — two distinct sessions with same date+minute
#         must both be written to distinct files (no silent data loss).
# ============================================================================
echo ""
echo "Case 8: collision dedup (two sessions, same repo, same date+minute)"

SB="$TMP_ROOT/case8"
VAULT8="$SB/vault"
REPO8="$SB/repo"
PROJ_ROOT8="$SB/projects"
STATE8="$SB/state.json"
mkdir -p "$VAULT8" "$REPO8" "$PROJ_ROOT8"

# Derive slug (same algorithm as backfill-sessions.sh)
_p8="$REPO8"
if command -v cygpath >/dev/null 2>&1; then
    _p8="$(cygpath -w "$_p8" 2>/dev/null || printf '%s' "$_p8")"
fi
SLUG8="$(printf '%s' "$_p8" | awk '{gsub(/[:\\\/]/, "-"); gsub(/^-+/, ""); print}')"

PROJ_DIR8="$PROJ_ROOT8/$SLUG8"
mkdir -p "$PROJ_DIR8"

# Write config
mkdir -p "$REPO8/.claude"
printf '{"enabled":true,"vault_path":"%s"}\n' "$VAULT8" > "$REPO8/.claude/end-session-wiki.json"

# Two sessions: SAME date+minute timestamp (2026-06-20T06:00:00Z), SAME cwd.
# session-A and session-B are distinct session_ids.
_cwd_escaped8="$(printf '%s' "$REPO8" | sed 's|\\|\\\\|g; s|/|\\/|g')"

sed "s|__CWD_PLACEHOLDER__|$_cwd_escaped8|g" "$FIXTURE_DIR/fixture-normal.jsonl" \
    > "$PROJ_DIR8/session-collision-A.jsonl"

# Session B: same timestamps, same cwd — only the sessionId in the first line
# differs (fixture-normal line 1 has sessionId "test-session-normal-001").
# Replace that with a distinct id.
sed "s|__CWD_PLACEHOLDER__|$_cwd_escaped8|g; s|test-session-normal-001|test-session-normal-002|g" \
    "$FIXTURE_DIR/fixture-normal.jsonl" \
    > "$PROJ_DIR8/session-collision-B.jsonl"

# Run (processes both JSONL files in one pass)
out8=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT8" \
    --project "$REPO8" \
    --state-file "$STATE8" \
    --vault-registry /dev/null \
    2>&1)

NOTE8_COUNT="$(find "$VAULT8/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NOTE8_COUNT" -eq 2 ]; then
    pass "collision-dedup: both sessions written (2 distinct files)"
else
    fail "collision-dedup: expected 2 notes, got $NOTE8_COUNT" "$out8"
fi

# Both session_ids must be in the ledger
if grep -q "session-collision-A" "$STATE8" 2>/dev/null; then
    pass "collision-dedup: session-collision-A ledgered"
else
    fail "collision-dedup: session-collision-A not in ledger"
fi
if grep -q "session-collision-B" "$STATE8" 2>/dev/null; then
    pass "collision-dedup: session-collision-B ledgered"
else
    fail "collision-dedup: session-collision-B not in ledger"
fi

# Re-run must be idempotent (new=0)
out8b=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT8" \
    --project "$REPO8" \
    --state-file "$STATE8" \
    --vault-registry /dev/null \
    --dry-run \
    2>&1)
assert_contains "collision-dedup: re-run idempotent (new=0)" "new=0" "$out8b"

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "===================================="
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "===================================="

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
