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
TRANSCRIPT_FIXTURES="$SCRIPT_DIR/../hooks/testdata/transcripts"
CLAUDE_STUB="$SCRIPT_DIR/../hooks/testdata/bin/claude-stub.sh"

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
    slug="$(printf '%s' "$p" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"

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
    slug="$(printf '%s' "$p" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"

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
    slug="$(printf '%s' "$p" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"

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

# F3 (HIMMEL-590): a real import prints the --reheal crystallization nudge.
assert_contains "F3: real import prints the --recrystallize nudge" "--recrystallize" "$out1"
# The imported note is mechanical (crystallized: false) until reheal runs.
if grep -q '^crystallized: false$' "$NOTE" 2>/dev/null; then
    pass "F3: imported note is mechanical (crystallized: false)"
else
    fail "F3: imported note not crystallized:false"
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

# Also assert --dry-run does not write but reports correct counts. The first run
# already wrote this session's note into the custom vault, so with a FRESH ledger
# (STATE7B) the vault scan (HIMMEL-662) now recognizes it as already-in-vault=1
# rather than re-counting it as a new import — this is the self-healing property
# (a lost ledger is rebuilt from the vault's own notes).
STATE7B="$SB/state7b.json"
out7b=$(LUNA_VAULT_PATH="$VAULT7_DEFAULT" bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT7" \
    --project "$REPO7" \
    --state-file "$STATE7B" \
    --vault-registry /dev/null \
    --dry-run \
    2>&1)
assert_contains "vault-resolve dry-run: already-in-vault=1 (fresh ledger, note already in vault)" "already-in-vault=1" "$out7b"
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
SLUG8="$(printf '%s' "$_p8" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"

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
# Case 9: husk-skip — a contentless transcript writes NO note (HIMMEL-576)
# ============================================================================
echo ""
echo "Case 9: husk-skip (contentless transcript)"

SB="$TMP_ROOT/case9"
VAULT9="$SB/vault"
REPO9="$SB/repo"
PROJ_ROOT9="$SB/projects"
STATE9="$SB/state.json"
mkdir -p "$VAULT9" "$REPO9" "$PROJ_ROOT9"

_p9="$REPO9"
if command -v cygpath >/dev/null 2>&1; then
    _p9="$(cygpath -w "$_p9" 2>/dev/null || printf '%s' "$_p9")"
fi
SLUG9="$(printf '%s' "$_p9" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"
PROJ_DIR9="$PROJ_ROOT9/$SLUG9"
mkdir -p "$PROJ_DIR9" "$REPO9/.claude"
printf '{"enabled":true,"vault_path":"%s"}\n' "$VAULT9" > "$REPO9/.claude/end-session-wiki.json"

# Contentless: user line only, no assistant content of any kind → HAS_CONTENT=0.
printf '%s\n' '{"timestamp":"2026-06-20T00:00:00Z","type":"user","message":{"role":"user","content":"hi"}}' \
    > "$PROJ_DIR9/test-session-husk-009.jsonl"

out9=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT9" \
    --project "$REPO9" \
    --state-file "$STATE9" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "husk-skip: husk count reported" "husk-skip=1" "$out9"
assert_contains "husk-skip: nothing counted as new" "new=0" "$out9"
if [ -z "$(find "$VAULT9/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "husk-skip: no note written for a contentless transcript"
else
    fail "husk-skip: a husk note was written"
fi

# ============================================================================
# Reheal helpers (HIMMEL-576 Phase 3)
# ============================================================================
# Write a husk note (crystallized unset/false + "_Transcript unavailable._" +
# Files Touched "_None._") at $1 with session_id $2.
write_husk_note() {
    local path="$1" sid="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
---
date: 2026-06-20T00:00:00Z
type: session
repo: testrepo
branch:
worktree: /tmp/testrepo
duration_minutes: 5
files_touched: 0
tags:
  - session
  - autocapture
ai-first: true
session_id: ${sid}
source: live
crystallized: false
crystallized_at:
---

Auto-captured session.

## Summary

_Transcript unavailable; auto-summary not generated._ (speculation)

## Decisions

_None._

## Files Touched

_None._

## Commands

\`\`\`bash
\`\`\`

## Follow-ups

_None._

## Raw Conversation

> [!note]- Raw conversation
> _Transcript unavailable._
EOF
}

# A CONTENT-bearing crystallized:false note (HIMMEL-620): real Raw Conversation
# (NOT "_Transcript unavailable._"), so it is NOT a husk — --reheal skips it,
# --recrystallize crystallizes it. This is the shape of an F1-affected live note
# and a backfilled prose-session note.
write_content_note() {
    local path="$1" sid="$2"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<EOF
---
date: 2026-06-20T00:00:00Z
type: session
repo: testrepo
branch:
worktree: /tmp/testrepo
duration_minutes: 5
files_touched: 0
tags:
  - session
  - autocapture
ai-first: true
session_id: ${sid}
source: live
crystallized: false
crystallized_at:
---

Auto-captured session.

## Summary

Did some real work here (mechanical first line).

## Decisions

_None._

## Files Touched

_None._

## Commands

\`\`\`bash
\`\`\`

## Follow-ups

_None._

## Raw Conversation

> [!note]- Raw conversation
> Real assistant prose turn — this note is NOT a husk.
EOF
}

# Drop a transcript fixture into a projects dir as <session_id>.jsonl so reheal
# can locate it (the project slug is irrelevant — reheal globs */<sid>.jsonl).
seed_named_transcript() {
    local proj_root="$1" sid="$2" fixture="$3"
    local pd="$proj_root/some-reheal-project"
    mkdir -p "$pd"
    cp "$fixture" "$pd/$sid.jsonl"
}

# Build a PATH that contains every tool backfill needs EXCEPT `claude`, so the
# mechanical-re-render branch is exercised without breaking jq/git/awk (which on
# Windows Git Bash live outside /usr/bin). Excludes claude's own directory.
_claudeless_path() {
    local claude_dir t d out=""
    claude_dir="$(command -v claude 2>/dev/null || true)"
    [ -n "$claude_dir" ] && claude_dir="$(dirname "$claude_dir")"
    for t in bash sh jq awk find sed grep git cat head tail tr wc \
             basename dirname sleep rm cp mv mkdir mktemp date \
             sha256sum shasum chmod paste; do
        d="$(command -v "$t" 2>/dev/null)" || continue
        [ -n "$d" ] || continue
        d="$(dirname "$d")"
        [ -n "$claude_dir" ] && [ "$d" = "$claude_dir" ] && continue
        case ":$out:" in *":$d:"*) ;; *) out="${out:+$out:}$d" ;; esac
    done
    printf '%s' "$out"
}

# ============================================================================
# Case 10: reheal with claude — husk overwritten, idempotent re-run
# ============================================================================
echo ""
echo "Case 10: reheal (claude available) heals a husk + is idempotent"

if [ ! -r "$CLAUDE_STUB" ]; then
    fail "reheal: claude-stub.sh not found at $CLAUDE_STUB"
else
    chmod +x "$CLAUDE_STUB" 2>/dev/null || true
    SB="$TMP_ROOT/case10"
    VAULT10="$SB/vault"
    PROJ_ROOT10="$SB/projects"
    STATE10="$SB/state.json"
    NOTE10="$VAULT10/sessions/2026/06/2026-06-20-0000-testrepo.md"
    mkdir -p "$VAULT10" "$PROJ_ROOT10"
    write_husk_note "$NOTE10" "reheal-sess-001"
    seed_named_transcript "$PROJ_ROOT10" "reheal-sess-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"

    out10=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
        CRYSTALLIZE_PID_DIR="$SB/pids" \
        bash "$BACKFILL" --reheal \
        --projects-dir "$PROJ_ROOT10" \
        --luna-vault-path "$VAULT10" \
        --state-file "$STATE10" \
        --vault-registry /dev/null \
        2>&1)

    assert_contains "reheal: healed count reported" "healed=1" "$out10"
    if grep -q '^crystallized: true$' "$NOTE10"; then
        pass "reheal: husk note crystallized: true after heal"
    else
        fail "reheal: husk note not crystallized" "$out10"
    fi
    if grep -q '_Crystallized by stub' "$NOTE10"; then
        pass "reheal: Summary section rewritten by crystallizer"
    else
        fail "reheal: Summary not rewritten"
    fi
    if grep -q '^session_id: reheal-sess-001$' "$NOTE10"; then
        pass "reheal: session_id preserved"
    else
        fail "reheal: session_id mutated"
    fi
    if [ -f "$NOTE10" ]; then
        pass "reheal: note path preserved (overwrite in place)"
    else
        fail "reheal: note path changed"
    fi

    # Re-run: already crystallized -> no-op (healed=0, bytes unchanged)
    SHA10="$(_file_sha256 "$NOTE10")"
    out10b=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
        CRYSTALLIZE_PID_DIR="$SB/pids" \
        bash "$BACKFILL" --reheal \
        --projects-dir "$PROJ_ROOT10" \
        --luna-vault-path "$VAULT10" \
        --state-file "$STATE10" \
        --vault-registry /dev/null \
        2>&1)
    assert_contains "reheal: re-run is a no-op (healed=0)" "healed=0" "$out10b"
    if [ "$SHA10" = "$(_file_sha256 "$NOTE10")" ]; then
        pass "reheal: re-run leaves healed note byte-unchanged"
    else
        fail "reheal: re-run mutated an already-healed note"
    fi
fi

# ============================================================================
# Case 11: reheal leaves a contentless husk as-is
# ============================================================================
echo ""
echo "Case 11: reheal leaves an inert (contentless) husk as-is"

SB="$TMP_ROOT/case11"
VAULT11="$SB/vault"
PROJ_ROOT11="$SB/projects"
STATE11="$SB/state.json"
NOTE11="$VAULT11/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT11" "$PROJ_ROOT11"
write_husk_note "$NOTE11" "reheal-sess-empty"
seed_named_transcript "$PROJ_ROOT11" "reheal-sess-empty" "$TRANSCRIPT_FIXTURES/contentless.jsonl"
SHA11="$(_file_sha256 "$NOTE11")"

out11=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --reheal \
    --projects-dir "$PROJ_ROOT11" \
    --luna-vault-path "$VAULT11" \
    --state-file "$STATE11" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "reheal: inert husk counted" "inert=1" "$out11"
if [ "$SHA11" = "$(_file_sha256 "$NOTE11")" ]; then
    pass "reheal: contentless husk left byte-unchanged"
else
    fail "reheal: contentless husk was modified" "$out11"
fi

# ============================================================================
# Case 12: reheal mechanical re-render when claude is absent
# ============================================================================
echo ""
echo "Case 12: reheal mechanical re-render (claude absent)"

SB="$TMP_ROOT/case12"
VAULT12="$SB/vault"
PROJ_ROOT12="$SB/projects"
STATE12="$SB/state.json"
NOTE12="$VAULT12/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT12" "$PROJ_ROOT12"
write_husk_note "$NOTE12" "reheal-sess-mech"
seed_named_transcript "$PROJ_ROOT12" "reheal-sess-mech" "$TRANSCRIPT_FIXTURES/normal.jsonl"

# No CRYSTALLIZE_CLAUDE_BIN and a claude-free PATH (real tools, no `claude`):
# reheal must mechanically re-render rather than leaving the husk.
CLP="$(_claudeless_path)"
if PATH="$CLP" command -v claude >/dev/null 2>&1; then
    fail "reheal(mech): test setup leaked a real claude into PATH (skipped to avoid billing)"
else
    out12=$(env -u CRYSTALLIZE_CLAUDE_BIN PATH="$CLP" \
        CRYSTALLIZE_PID_DIR="$SB/pids" \
        bash "$BACKFILL" --reheal \
        --projects-dir "$PROJ_ROOT12" \
        --luna-vault-path "$VAULT12" \
        --state-file "$STATE12" \
        --vault-registry /dev/null \
        2>&1)
    assert_contains "reheal(mech): healed count reported" "healed=1" "$out12"
    NOTE12_BODY="$(cat "$NOTE12" 2>/dev/null)"
    assert_contains "reheal(mech): real summary rendered" "Summary line one." "$NOTE12_BODY"
    assert_contains "reheal(mech): real command rendered" "git commit -m x" "$NOTE12_BODY"
    assert_not_contains "reheal(mech): no longer a husk (transcript marker gone)" \
        "_Transcript unavailable._" "$NOTE12_BODY"
    if grep -q '^crystallized: false$' "$NOTE12"; then
        pass "reheal(mech): stays crystallized: false (no LLM)"
    else
        fail "reheal(mech): crystallized flag wrong for mechanical render"
    fi
    if grep -q '^session_id: reheal-sess-mech$' "$NOTE12"; then
        pass "reheal(mech): session_id preserved"
    else
        fail "reheal(mech): session_id mutated"
    fi
fi

# ============================================================================
# Case 13: reheal mechanical on a tool-only transcript (no prose turn) is a
#          convergent no-op when claude is absent — a mechanical re-render can't
#          clear the husk predicate (Raw Conversation stays "_Transcript
#          unavailable._"), so the note must be LEFT AS-IS (idempotent), not
#          rewritten on every run.
# ============================================================================
echo ""
echo "Case 13: reheal tool-only transcript w/o claude is a convergent no-op"

SB="$TMP_ROOT/case13"
VAULT13="$SB/vault"
PROJ_ROOT13="$SB/projects"
STATE13="$SB/state.json"
NOTE13="$VAULT13/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT13" "$PROJ_ROOT13"
write_husk_note "$NOTE13" "reheal-sess-toolonly"
seed_named_transcript "$PROJ_ROOT13" "reheal-sess-toolonly" "$TRANSCRIPT_FIXTURES/thinking-tool-only.jsonl"
SHA13="$(_file_sha256 "$NOTE13")"

CLP13="$(_claudeless_path)"
if PATH="$CLP13" command -v claude >/dev/null 2>&1; then
    fail "reheal(tool-only): test setup leaked a real claude into PATH (skipped)"
else
    out13=$(env -u CRYSTALLIZE_CLAUDE_BIN PATH="$CLP13" \
        CRYSTALLIZE_PID_DIR="$SB/pids" \
        bash "$BACKFILL" --reheal \
        --projects-dir "$PROJ_ROOT13" \
        --luna-vault-path "$VAULT13" \
        --state-file "$STATE13" \
        --vault-registry /dev/null \
        2>&1)
    assert_contains "reheal(tool-only): counted inert, not healed" "healed=0" "$out13"
    assert_contains "reheal(tool-only): inert reported" "inert=1" "$out13"
    if [ "$SHA13" = "$(_file_sha256 "$NOTE13")" ]; then
        pass "reheal(tool-only): husk left byte-unchanged (idempotent, no rewrite loop)"
    else
        fail "reheal(tool-only): note was rewritten despite staying a husk" "$out13"
    fi
fi

# ============================================================================
# Case 14: reheal --dry-run counts a recoverable husk but writes nothing
# ============================================================================
echo ""
echo "Case 14: reheal --dry-run reports recoverable count, touches nothing"

SB="$TMP_ROOT/case14"
VAULT14="$SB/vault"
PROJ_ROOT14="$SB/projects"
STATE14="$SB/state.json"
NOTE14="$VAULT14/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT14" "$PROJ_ROOT14"
write_husk_note "$NOTE14" "reheal-sess-dry"
seed_named_transcript "$PROJ_ROOT14" "reheal-sess-dry" "$TRANSCRIPT_FIXTURES/normal.jsonl"
SHA14="$(_file_sha256 "$NOTE14")"

out14=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --reheal --dry-run \
    --projects-dir "$PROJ_ROOT14" \
    --luna-vault-path "$VAULT14" \
    --state-file "$STATE14" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "reheal(dry): recoverable husk counted" "healed=1" "$out14"
if [ "$SHA14" = "$(_file_sha256 "$NOTE14")" ]; then
    pass "reheal(dry): note byte-unchanged (no write under --dry-run)"
else
    fail "reheal(dry): --dry-run mutated the note" "$out14"
fi

# ============================================================================
# Case 15: claude available but the crystallizer FAILS -> note left as-is
#          (never mechanically overwritten after a claude attempt — guards
#          against clobbering a partial LLM edit), counted inert, idempotent.
# ============================================================================
echo ""
echo "Case 15: reheal with a FAILING crystallizer leaves the husk as-is"

SB="$TMP_ROOT/case15"
VAULT15="$SB/vault"
PROJ_ROOT15="$SB/projects"
STATE15="$SB/state.json"
NOTE15="$VAULT15/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT15" "$PROJ_ROOT15"
write_husk_note "$NOTE15" "reheal-sess-fail"
seed_named_transcript "$PROJ_ROOT15" "reheal-sess-fail" "$TRANSCRIPT_FIXTURES/normal.jsonl"
SHA15="$(_file_sha256 "$NOTE15")"

out15=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=fail \
    CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --reheal \
    --projects-dir "$PROJ_ROOT15" \
    --luna-vault-path "$VAULT15" \
    --state-file "$STATE15" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "reheal(fail): not counted healed" "healed=0" "$out15"
assert_contains "reheal(fail): counted inert" "inert=1" "$out15"
if [ "$SHA15" = "$(_file_sha256 "$NOTE15")" ]; then
    pass "reheal(fail): husk left byte-unchanged (no mechanical clobber after claude attempt)"
else
    fail "reheal(fail): note was overwritten despite the crystallizer failing" "$out15"
fi

# ============================================================================
# Case 16: path->slug FULL encoding — a repo path containing a char beyond
#          : \ / (here a dot AND an underscore) must resolve to Claude Code's
#          real project slug (every non-alphanumeric char -> '-'), not be
#          swallowed with a "no project dir" warning. Regression for the bug
#          where _path_to_slug mapped only : \ / so a dotted/underscored path
#          produced the wrong slug -> the whole project was silently skipped.
# ============================================================================
echo ""
echo "Case 16: path->slug full encoding (dotted/underscored repo not swallowed)"

SB="$TMP_ROOT/case16"
VAULT16="$SB/vault"
REPO16="$SB/repo.dotted_v2"     # dot AND underscore in the final path component
PROJ_ROOT16="$SB/projects"
STATE16="$SB/state.json"
mkdir -p "$VAULT16" "$REPO16" "$PROJ_ROOT16"

# Ground-truth slug = Claude Code's REAL encoding (verified empirically against
# ~/.claude/projects): Windows form via cygpath, then EVERY non-alphanumeric
# char -> '-', leading dashes stripped. This is deliberately NOT the old
# ':\/'-only mapping — that mismatch is the bug under test.
_p16="$REPO16"
if command -v cygpath >/dev/null 2>&1; then
    _p16="$(cygpath -w "$_p16" 2>/dev/null || printf '%s' "$_p16")"
fi
SLUG16="$(printf '%s' "$_p16" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"
PROJ_DIR16="$PROJ_ROOT16/$SLUG16"
mkdir -p "$PROJ_DIR16"

# Anchor to the real Claude Code contract with a LITERAL (not just a mirror of
# the production awk): the final path component "repo.dotted_v2" must encode to
# "repo-dotted-v2" (dot AND underscore -> '-'), and the raw dotted form must NOT
# survive in the slug. This catches a future divergence where production and the
# helper drift to the SAME wrong encoding (which a self-referential slug check
# would miss).
assert_contains "path-slug: dot+underscore both map to dash (literal anchor)" "repo-dotted-v2" "$SLUG16"
assert_not_contains "path-slug: raw 'repo.dotted_v2' absent from slug" "repo.dotted_v2" "$SLUG16"

mkdir -p "$REPO16/.claude"
printf '{"enabled":true,"vault_path":"%s"}\n' "$VAULT16" > "$REPO16/.claude/end-session-wiki.json"

_cwd_escaped16="$(printf '%s' "$REPO16" | sed 's|\\|\\\\|g; s|/|\\/|g')"
sed "s|__CWD_PLACEHOLDER__|$_cwd_escaped16|g" "$FIXTURE_DIR/fixture-normal.jsonl" \
    > "$PROJ_DIR16/session-dotted-001.jsonl"

out16=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT16" \
    --project "$REPO16" \
    --state-file "$STATE16" \
    --vault-registry /dev/null \
    2>&1)

assert_contains "path-slug: dotted/underscored repo imported (new=1)" "new=1" "$out16"
assert_not_contains "path-slug: no 'no project dir' swallow warning" "no project dir for" "$out16"
NOTE16="$(find "$VAULT16/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE16" ]; then
    pass "path-slug: note written for a dotted/underscored repo path"
else
    fail "path-slug: no note written (project was swallowed)" "$out16"
fi

# ============================================================================
# Case 17: full-scope --all routes TWO repos to TWO DIFFERENT vaults
#          (HIMMEL-590 F4). Each repo's per-repo config carries its own
#          vault_path, so a single `--all` pass must file each session into its
#          OWN vault — not pool both into one default. This locks the
#          per-session resolve_vault_root routing that makes multi-vault work.
# ============================================================================
echo ""
echo "Case 17: --all routes two repos to two different vaults (multi-vault)"

SB="$TMP_ROOT/case17"
VAULT_A="$SB/vaultA"
VAULT_B="$SB/vaultB"
REPO_A="$SB/repo-alpha"
REPO_B="$SB/repo-beta"
PROJ_ROOT17="$SB/projects"
STATE17="$SB/state.json"
mkdir -p "$VAULT_A" "$VAULT_B" "$REPO_A" "$REPO_B" "$PROJ_ROOT17"
setup_projects_dir "$PROJ_ROOT17" "$REPO_A" "$VAULT_A"
setup_projects_dir "$PROJ_ROOT17" "$REPO_B" "$VAULT_B"

out17=$(bash "$BACKFILL" \
    --all \
    --projects-dir "$PROJ_ROOT17" \
    --state-file "$STATE17" \
    --vault-registry /dev/null \
    2>&1)

NOTE_A="$(find "$VAULT_A/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
NOTE_B="$(find "$VAULT_B/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE_A" ]; then pass "multi-vault: repo-alpha session filed under vaultA"; else fail "multi-vault: no note under vaultA" "$out17"; fi
if [ -n "$NOTE_B" ]; then pass "multi-vault: repo-beta session filed under vaultB"; else fail "multi-vault: no note under vaultB" "$out17"; fi
# Cross-contamination guard: each vault holds exactly its own repo's note.
CNT_A="$(find "$VAULT_A/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
CNT_B="$(find "$VAULT_B/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CNT_A" = "1" ] && [ "$CNT_B" = "1" ]; then
    pass "multi-vault: no cross-contamination (one note per vault)"
else
    fail "multi-vault: cross-contamination (vaultA=$CNT_A vaultB=$CNT_B)" "$out17"
fi
if [ -n "$NOTE_A" ] && grep -q "repo: $(basename "$REPO_A")" "$NOTE_A" 2>/dev/null; then
    pass "multi-vault: vaultA note carries repo-alpha identity"
else
    fail "multi-vault: vaultA note has wrong repo identity" "$out17"
fi
if [ -n "$NOTE_B" ] && grep -q "repo: $(basename "$REPO_B")" "$NOTE_B" 2>/dev/null; then
    pass "multi-vault: vaultB note carries repo-beta identity (no swapped routing)"
else
    fail "multi-vault: vaultB note has wrong repo identity" "$out17"
fi

# ============================================================================
# Case 18: --recrystallize crystallizes a CONTENT-bearing note that --reheal
#          SKIPS (HIMMEL-620). The note is crystallized:false with a real Raw
#          Conversation (not a husk). --reheal must skip it (non-husk-skip);
#          --recrystallize must crystallize it (crystallized:true).
# ============================================================================
echo ""
echo "Case 18: --recrystallize crystallizes a content-note that --reheal skips"

SB="$TMP_ROOT/case18"
VAULT18="$SB/vault"
PROJ_ROOT18="$SB/projects"
STATE18="$SB/state.json"
NOTE18="$VAULT18/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT18" "$PROJ_ROOT18"
write_content_note "$NOTE18" "recrys-sess-001"
seed_named_transcript "$PROJ_ROOT18" "recrys-sess-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"

# 18a: --reheal SKIPS it (proves the gap — it's not a husk).
out18r=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --reheal \
    --projects-dir "$PROJ_ROOT18" --luna-vault-path "$VAULT18" \
    --state-file "$STATE18" --vault-registry /dev/null 2>&1)
assert_contains "recrys: --reheal skips the content-note (non-husk)" "non-husk-skip=1" "$out18r"
if grep -q '^crystallized: false$' "$NOTE18"; then pass "recrys: --reheal left it crystallized:false"; else fail "recrys: --reheal wrongly changed it" "$out18r"; fi

# 18b: --recrystallize crystallizes it.
out18=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-29T00:00:00Z" \
    bash "$BACKFILL" --recrystallize \
    --projects-dir "$PROJ_ROOT18" --luna-vault-path "$VAULT18" \
    --state-file "$STATE18" --vault-registry /dev/null 2>&1)
assert_contains "recrys: --recrystallize reports crystallized=1" "crystallized=1" "$out18"
if grep -q '^crystallized: true$' "$NOTE18"; then pass "recrys: content-note crystallized:true"; else fail "recrys: content-note not crystallized" "$out18"; fi

# 18c: idempotent — re-run skips the now-crystallized note.
out18b=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --recrystallize \
    --projects-dir "$PROJ_ROOT18" --luna-vault-path "$VAULT18" \
    --state-file "$STATE18" --vault-registry /dev/null 2>&1)
assert_contains "recrys: idempotent re-run crystallizes nothing" "crystallized=0" "$out18b"

# ============================================================================
# Case 19: --recrystallize --dry-run counts but writes nothing; --limit caps.
# ============================================================================
echo ""
echo "Case 19: --recrystallize --dry-run (no write) + --limit caps real runs"

SB="$TMP_ROOT/case19"
VAULT19="$SB/vault"
PROJ_ROOT19="$SB/projects"
STATE19="$SB/state.json"
N19A="$VAULT19/sessions/2026/06/2026-06-20-0000-a.md"
N19B="$VAULT19/sessions/2026/06/2026-06-20-0001-b.md"
mkdir -p "$VAULT19" "$PROJ_ROOT19"
write_content_note "$N19A" "recrys-a"; seed_named_transcript "$PROJ_ROOT19" "recrys-a" "$TRANSCRIPT_FIXTURES/normal.jsonl"
write_content_note "$N19B" "recrys-b"; seed_named_transcript "$PROJ_ROOT19" "recrys-b" "$TRANSCRIPT_FIXTURES/normal.jsonl"

# dry-run: counts both, writes nothing.
SHA19A="$(_file_sha256 "$N19A")"
out19d=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --recrystallize --dry-run \
    --projects-dir "$PROJ_ROOT19" --luna-vault-path "$VAULT19" \
    --state-file "$STATE19" --vault-registry /dev/null 2>&1)
assert_contains "recrys(dry): both content-notes counted" "crystallized=2" "$out19d"
if [ "$SHA19A" = "$(_file_sha256 "$N19A")" ]; then pass "recrys(dry): note byte-unchanged"; else fail "recrys(dry): --dry-run mutated a note" "$out19d"; fi

# --limit 1: only one crystallized this run.
out19l=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-29T00:00:00Z" \
    bash "$BACKFILL" --recrystallize --limit 1 \
    --projects-dir "$PROJ_ROOT19" --luna-vault-path "$VAULT19" \
    --state-file "$STATE19" --vault-registry /dev/null 2>&1)
assert_contains "recrys(limit): --limit 1 crystallizes exactly one" "crystallized=1" "$out19l"
_cryst_count=$(grep -l '^crystallized: true$' "$N19A" "$N19B" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_cryst_count" = "1" ]; then pass "recrys(limit): exactly one note crystallized on disk"; else fail "recrys(limit): $_cryst_count crystallized (expected 1)" "$out19l"; fi

# ============================================================================
# Case 20: progress logging (HIMMEL-627) — periodic heartbeat + per-note lines
#          appear on stderr for a multi-note recrystallize run; the stdout
#          summary line stays byte-stable; --limit chunk boundaries are
#          observable per-note.
# ============================================================================
echo ""
echo "Case 20: progress logging (heartbeat + per-note + summary byte-stable)"

SB="$TMP_ROOT/case20"
VAULT20="$SB/vault"
PROJ_ROOT20="$SB/projects"
STATE20="$SB/state.json"
N20A="$VAULT20/sessions/2026/06/2026-06-20-0000-a.md"
N20B="$VAULT20/sessions/2026/06/2026-06-20-0001-b.md"
N20C="$VAULT20/sessions/2026/06/2026-06-20-0002-c.md"
mkdir -p "$VAULT20" "$PROJ_ROOT20"
write_content_note "$N20A" "prog-a"; seed_named_transcript "$PROJ_ROOT20" "prog-a" "$TRANSCRIPT_FIXTURES/normal.jsonl"
write_content_note "$N20B" "prog-b"; seed_named_transcript "$PROJ_ROOT20" "prog-b" "$TRANSCRIPT_FIXTURES/normal.jsonl"
write_content_note "$N20C" "prog-c"; seed_named_transcript "$PROJ_ROOT20" "prog-c" "$TRANSCRIPT_FIXTURES/normal.jsonl"

# --limit 2 + a heartbeat every note (BACKFILL_PROGRESS_EVERY=1): two notes
# crystallize, one is capped. Capture stdout and stderr separately so the
# byte-stable summary check is not polluted by the progress stream.
ERR20="$SB/err.txt"
out20=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-29T00:00:00Z" \
    BACKFILL_PROGRESS_EVERY=1 \
    bash "$BACKFILL" --recrystallize --limit 2 \
    --projects-dir "$PROJ_ROOT20" --luna-vault-path "$VAULT20" \
    --state-file "$STATE20" --vault-registry /dev/null 2>"$ERR20")
err20="$(cat "$ERR20" 2>/dev/null)"

# Heartbeat fired on stderr (scanned X/total). All three notes are scanned even
# though only two are crystallized (the third is capped by --limit).
assert_contains "progress: heartbeat shows scanned 1/3" "scanned 1/3" "$err20"
assert_contains "progress: heartbeat shows final scanned 3/3" "scanned 3/3" "$err20"

# Per-note lines: exactly two crystallizations observed (one per --limit chunk).
PERNOTE20="$(printf '%s\n' "$err20" | grep -c 'recrystallize: crystallized .*\.md (' )"
if [ "$PERNOTE20" = "2" ]; then
    pass "progress: exactly two per-note crystallization lines (--limit 2 observable)"
else
    fail "progress: expected 2 per-note lines, got $PERNOTE20" "$err20"
fi

# Summary line on stdout is byte-stable (tests + scripts parse it).
SUMMARY20="$(printf '%s\n' "$out20" | grep '^recrystallize: crystallized=')"
if [ "$SUMMARY20" = "recrystallize: crystallized=2 skipped=1 (--limit 2)" ]; then
    pass "progress: stdout summary line byte-stable under --limit"
else
    fail "progress: summary line changed" "got: [$SUMMARY20]"
fi

# Progress goes to stderr only — the stdout stream carries no heartbeat noise.
assert_not_contains "progress: no heartbeat leaked onto stdout" "scanned " "$out20"

# ============================================================================
# Case 21: heartbeat is PERIODIC, not every-note (HIMMEL-627). With
#          BACKFILL_PROGRESS_EVERY=2 over 3 notes the heartbeat fires at note 2
#          only — "scanned 2/3" present, "scanned 1/3" and "scanned 3/3" absent.
#          (Case 20 used EVERY=1, which fires every note and so does NOT prove
#          the modulo gate.)
# ============================================================================
echo ""
echo "Case 21: heartbeat fires periodically (EVERY=2), not every note"

SB="$TMP_ROOT/case21"
VAULT21="$SB/vault"; PROJ_ROOT21="$SB/projects"; STATE21="$SB/state.json"
mkdir -p "$VAULT21" "$PROJ_ROOT21"
for n in a b c; do
    write_content_note "$VAULT21/sessions/2026/06/2026-06-20-000${n}-${n}.md" "per-$n"
    seed_named_transcript "$PROJ_ROOT21" "per-$n" "$TRANSCRIPT_FIXTURES/normal.jsonl"
done
ERR21="$SB/err.txt"
env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-29T00:00:00Z" \
    BACKFILL_PROGRESS_EVERY=2 \
    bash "$BACKFILL" --recrystallize \
    --projects-dir "$PROJ_ROOT21" --luna-vault-path "$VAULT21" \
    --state-file "$STATE21" --vault-registry /dev/null >/dev/null 2>"$ERR21"
err21="$(cat "$ERR21" 2>/dev/null)"
assert_contains "periodic: heartbeat fires at note 2 (scanned 2/3)" "scanned 2/3" "$err21"
assert_not_contains "periodic: no heartbeat at note 1 (every-2, not every-1)" "scanned 1/3" "$err21"
assert_not_contains "periodic: no heartbeat at note 3 (3 % 2 != 0)" "scanned 3/3" "$err21"

# ============================================================================
# Case 22: --reheal emits progress too (HIMMEL-627). The reheal arm has its own
#          per-note line + 5-field heartbeat, written independently of the
#          recrystallize arm — Case 20/21 cover only recrystallize.
# ============================================================================
echo ""
echo "Case 22: reheal mode emits heartbeat + per-note progress"

SB="$TMP_ROOT/case22"
VAULT22="$SB/vault"; PROJ_ROOT22="$SB/projects"; STATE22="$SB/state.json"
NOTE22="$VAULT22/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT22" "$PROJ_ROOT22"
write_husk_note "$NOTE22" "reheal-prog-001"
seed_named_transcript "$PROJ_ROOT22" "reheal-prog-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"
ERR22="$SB/err.txt"
out22=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" BACKFILL_PROGRESS_EVERY=1 \
    bash "$BACKFILL" --reheal \
    --projects-dir "$PROJ_ROOT22" --luna-vault-path "$VAULT22" \
    --state-file "$STATE22" --vault-registry /dev/null 2>"$ERR22")
err22="$(cat "$ERR22" 2>/dev/null)"
assert_contains "reheal-progress: heartbeat (reheal: scanned 1/1)" "reheal: scanned 1/1" "$err22"
assert_contains "reheal-progress: per-note healed line" "reheal: healed 2026-06-20-0000-testrepo.md" "$err22"
# Summary line on stdout unchanged + no progress leak.
assert_contains "reheal-progress: stdout summary intact (healed=1)" "healed=1" "$out22"
assert_not_contains "reheal-progress: no heartbeat leak onto stdout" "scanned " "$out22"

# Flip a crystallized:false note to crystallized:true with an OLD timestamp,
# in place (portable — no sed -i), so --refresh tests have an already-synthesized
# note to re-consolidate.
mark_crystallized() { # <note>
    awk '
        /^crystallized: false$/ { print "crystallized: true"; next }
        /^crystallized_at:$/ { print "crystallized_at: 2026-01-01T00:00:00Z"; next }
        { print }
    ' "$1" > "$1.tmp" && mv "$1.tmp" "$1"
}

# ============================================================================
# Case 23: --refresh without --recrystallize errors (guard).
# ============================================================================
echo ""
echo "Case 23: --refresh requires --recrystallize (errors otherwise)"

SB="$TMP_ROOT/case23"
VAULT23="$SB/vault"; PROJ_ROOT23="$SB/projects"; STATE23="$SB/state.json"
mkdir -p "$VAULT23" "$PROJ_ROOT23"
rc23=0
out23=$(bash "$BACKFILL" --refresh \
    --projects-dir "$PROJ_ROOT23" --luna-vault-path "$VAULT23" \
    --state-file "$STATE23" --vault-registry /dev/null 2>&1) || rc23=$?
if [ "$rc23" -ne 0 ]; then pass "refresh-guard: --refresh alone exits non-zero"; else fail "refresh-guard: --refresh alone did not error" "$out23"; fi
assert_contains "refresh-guard: error names the requirement" "requires --recrystallize" "$out23"

# ============================================================================
# Case 24: --recrystallize --refresh re-consolidates an already-crystallized note
#          (bypasses the crystallized:true skip), counts it, re-stamps
#          crystallized_at; plain --recrystallize (no --refresh) still skips it.
# ============================================================================
echo ""
echo "Case 24: --recrystallize --refresh re-runs an already-crystallized note"

SB="$TMP_ROOT/case24"
VAULT24="$SB/vault"; PROJ_ROOT24="$SB/projects"; STATE24="$SB/state.json"
NOTE24="$VAULT24/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT24" "$PROJ_ROOT24"
write_content_note "$NOTE24" "refresh-sess-001"
mark_crystallized "$NOTE24"
seed_named_transcript "$PROJ_ROOT24" "refresh-sess-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"

# Plain --recrystallize skips the already-crystallized note.
out24s=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --recrystallize \
    --projects-dir "$PROJ_ROOT24" --luna-vault-path "$VAULT24" \
    --state-file "$STATE24" --vault-registry /dev/null 2>&1)
assert_contains "refresh: plain --recrystallize skips already-crystallized" "crystallized=0 skipped=1" "$out24s"

# --refresh re-runs it (stub rewrites Summary -> content change -> counted).
out24=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T00:00:00Z" \
    bash "$BACKFILL" --recrystallize --refresh \
    --projects-dir "$PROJ_ROOT24" --luna-vault-path "$VAULT24" \
    --state-file "$STATE24" --vault-registry /dev/null 2>&1)
assert_contains "refresh: --refresh re-runs already-crystallized (crystallized=1)" "crystallized=1" "$out24"
assert_contains "refresh: summary line carries the (--refresh) token" "(--refresh)" "$out24"
if grep -q '^crystallized: true$' "$NOTE24"; then pass "refresh: note stays crystallized:true"; else fail "refresh: crystallized flag lost" "$out24"; fi
if grep -q '_Crystallized by stub' "$NOTE24"; then pass "refresh: Summary re-consolidated"; else fail "refresh: Summary not updated"; fi
if grep -q '^crystallized_at: 2026-06-30T00:00:00Z$' "$NOTE24"; then pass "refresh: crystallized_at re-stamped"; else fail "refresh: crystallized_at not re-stamped"; fi

# ============================================================================
# Case 25: --recrystallize --refresh --dry-run counts already-crystallized
#          eligible, writes nothing.
# ============================================================================
echo ""
echo "Case 25: --recrystallize --refresh --dry-run counts eligible incl. crystallized"

SB="$TMP_ROOT/case25"
VAULT25="$SB/vault"; PROJ_ROOT25="$SB/projects"; STATE25="$SB/state.json"
NOTE25="$VAULT25/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT25" "$PROJ_ROOT25"
write_content_note "$NOTE25" "refresh-dry-001"
mark_crystallized "$NOTE25"
seed_named_transcript "$PROJ_ROOT25" "refresh-dry-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"
SHA25="$(_file_sha256 "$NOTE25")"

out25=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success CRYSTALLIZE_PID_DIR="$SB/pids" \
    bash "$BACKFILL" --recrystallize --refresh --dry-run \
    --projects-dir "$PROJ_ROOT25" --luna-vault-path "$VAULT25" \
    --state-file "$STATE25" --vault-registry /dev/null 2>&1)
assert_contains "refresh(dry): already-crystallized note counted eligible" "crystallized=1" "$out25"
if [ "$SHA25" = "$(_file_sha256 "$NOTE25")" ]; then pass "refresh(dry): note byte-unchanged (no write)"; else fail "refresh(dry): --dry-run mutated the note" "$out25"; fi

# ============================================================================
# Case 26: --recrystallize --refresh --limit caps real refresh runs.
# ============================================================================
echo ""
echo "Case 26: --recrystallize --refresh --limit caps real runs"

SB="$TMP_ROOT/case26"
VAULT26="$SB/vault"; PROJ_ROOT26="$SB/projects"; STATE26="$SB/state.json"
N26A="$VAULT26/sessions/2026/06/2026-06-20-0000-a.md"
N26B="$VAULT26/sessions/2026/06/2026-06-20-0001-b.md"
mkdir -p "$VAULT26" "$PROJ_ROOT26"
write_content_note "$N26A" "refresh-cap-a"; mark_crystallized "$N26A"
write_content_note "$N26B" "refresh-cap-b"; mark_crystallized "$N26B"
seed_named_transcript "$PROJ_ROOT26" "refresh-cap-a" "$TRANSCRIPT_FIXTURES/normal.jsonl"
seed_named_transcript "$PROJ_ROOT26" "refresh-cap-b" "$TRANSCRIPT_FIXTURES/normal.jsonl"

out26=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T00:00:00Z" \
    bash "$BACKFILL" --recrystallize --refresh --limit 1 \
    --projects-dir "$PROJ_ROOT26" --luna-vault-path "$VAULT26" \
    --state-file "$STATE26" --vault-registry /dev/null 2>&1)
assert_contains "refresh(limit): --limit 1 refreshes exactly one" "crystallized=1" "$out26"
assert_contains "refresh(limit): summary carries both tokens" "(--limit 1) (--refresh)" "$out26"
_refreshed_count=$(grep -l '_Crystallized by stub' "$N26A" "$N26B" 2>/dev/null | wc -l | tr -d ' ')
if [ "$_refreshed_count" = "1" ]; then pass "refresh(limit): exactly one note re-consolidated on disk"; else fail "refresh(limit): $_refreshed_count re-consolidated (expected 1)" "$out26"; fi

# ============================================================================
# Case 27: --rules content reaches the crystallizer prompt (backfill); an
#          unreadable --rules file errors.
# ============================================================================
echo ""
echo "Case 27: --rules content reaches the crystallizer prompt (backfill)"

SB="$TMP_ROOT/case27"
VAULT27="$SB/vault"; PROJ_ROOT27="$SB/projects"; STATE27="$SB/state.json"
NOTE27="$VAULT27/sessions/2026/06/2026-06-20-0000-testrepo.md"
RULES27="$SB/rules.txt"; ARGVD27="$SB/argv.txt"
mkdir -p "$VAULT27" "$PROJ_ROOT27"
write_content_note "$NOTE27" "rules-sess-001"
seed_named_transcript "$PROJ_ROOT27" "rules-sess-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"
printf 'BACKFILL_RULES_MARKER\n' > "$RULES27"

out27=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD27" \
    bash "$BACKFILL" --recrystallize --rules "$RULES27" \
    --projects-dir "$PROJ_ROOT27" --luna-vault-path "$VAULT27" \
    --state-file "$STATE27" --vault-registry /dev/null 2>&1)
if grep -qF 'BACKFILL_RULES_MARKER' "$ARGVD27" 2>/dev/null; then pass "rules(backfill): --rules content reaches the crystallizer prompt"; else fail "rules(backfill): rules content not in prompt" "$out27"; fi

rc27=0
out27b=$(bash "$BACKFILL" --recrystallize --rules "$SB/nope.txt" \
    --projects-dir "$PROJ_ROOT27" --luna-vault-path "$VAULT27" \
    --state-file "$STATE27" --vault-registry /dev/null 2>&1) || rc27=$?
if [ "$rc27" -ne 0 ]; then pass "rules(backfill): unreadable --rules file errors"; else fail "rules(backfill): unreadable --rules did not error" "$out27b"; fi

# ============================================================================
# Case 28: a CORRUPTING refresh is rolled back and counted skipped, not
#          refreshed (loss-proofing, HIMMEL-663). The corrupt stub truncates the
#          note; the crystallizer restores the snapshot (byte-identical), so the
#          backfill hash-compare must record skipped=1 / crystallized=0.
# ============================================================================
echo ""
echo "Case 28: corrupted refresh rolled back + counted skipped"

SB="$TMP_ROOT/case28"
VAULT28="$SB/vault"; PROJ_ROOT28="$SB/projects"; STATE28="$SB/state.json"
NOTE28="$VAULT28/sessions/2026/06/2026-06-20-0000-testrepo.md"
mkdir -p "$VAULT28" "$PROJ_ROOT28"
write_content_note "$NOTE28" "refresh-corrupt-001"
mark_crystallized "$NOTE28"
seed_named_transcript "$PROJ_ROOT28" "refresh-corrupt-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"
SHA28="$(_file_sha256 "$NOTE28")"

out28=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=corrupt \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_NOW="2026-06-30T00:00:00Z" \
    bash "$BACKFILL" --recrystallize --refresh \
    --projects-dir "$PROJ_ROOT28" --luna-vault-path "$VAULT28" \
    --state-file "$STATE28" --vault-registry /dev/null 2>&1)
assert_contains "refresh(corrupt): counted skipped, not refreshed" "crystallized=0 skipped=1" "$out28"
if [ "$SHA28" = "$(_file_sha256 "$NOTE28")" ]; then pass "refresh(corrupt): note restored byte-identical (prior synthesis kept)"; else fail "refresh(corrupt): corrupted result persisted" "$out28"; fi

# ============================================================================
# Case 29: already-in-vault dedup (HIMMEL-662) — a session captured live by
#          end-session-wiki.sh already sits in the vault under a DIFFERENT
#          filename shape (end-time + repo-branch slug, source: live) and is
#          invisible to the (backfill-only) ledger. Plain backfill must scan the
#          vault, skip that session (already-in-vault=1), ledger it, and NOT
#          write a duplicate — while a genuinely-missing session still imports.
# ============================================================================
echo ""
echo "Case 29: already-in-vault dedup (live note invisible to ledger)"

SB="$TMP_ROOT/case29"
VAULT29="$SB/vault"
REPO29="$SB/repo"
PROJ_ROOT29="$SB/projects"
STATE29="$SB/state.json"
mkdir -p "$VAULT29" "$REPO29" "$PROJ_ROOT29"
setup_projects_dir "$PROJ_ROOT29" "$REPO29" "$VAULT29"   # writes test-session-normal-001.jsonl

# Live-captured note already in the vault: end-time + repo-branch filename shape
# (NOT backfill's start-time + repo-only slug), source: live, and a session_id
# that matches the transcript basename. Backfill must recognize it via the vault
# scan even though the ledger is blind to live notes.
LIVE29="$VAULT29/sessions/2026/06/2026-06-20-1830-repo-feat-branch.md"
write_content_note "$LIVE29" "test-session-normal-001"

# A genuinely-missing session (no live note in the vault) must still import.
_p29="$REPO29"
if command -v cygpath >/dev/null 2>&1; then
    _p29="$(cygpath -w "$_p29" 2>/dev/null || printf '%s' "$_p29")"
fi
SLUG29="$(printf '%s' "$_p29" | awk '{gsub(/[^a-zA-Z0-9]/, "-"); gsub(/^-+/, ""); print}')"
_cwd_escaped29="$(printf '%s' "$REPO29" | sed 's|\\|\\\\|g; s|/|\\/|g')"
sed "s|__CWD_PLACEHOLDER__|$_cwd_escaped29|g; s|test-session-normal-001|test-session-normal-777|g" \
    "$FIXTURE_DIR/fixture-normal.jsonl" > "$PROJ_ROOT29/$SLUG29/test-session-normal-777.jsonl"

out29=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT29" \
    --project "$REPO29" \
    --state-file "$STATE29" \
    --vault-registry /dev/null \
    2>&1)

assert_contains "in-vault: live-captured session skipped (already-in-vault=1)" "already-in-vault=1" "$out29"
assert_contains "in-vault: genuinely-missing session still imported (new=1)" "new=1" "$out29"

# Vault holds exactly 2 notes: the pre-existing live note + the one new import
# (no duplicate for the already-in-vault session).
NOTE29_COUNT="$(find "$VAULT29/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$NOTE29_COUNT" -eq 2 ]; then
    pass "in-vault: no duplicate written (live note + one import = 2 notes)"
else
    fail "in-vault: note count wrong (expected 2, got $NOTE29_COUNT)" "$out29"
fi

# Ledger gained the in-vault session (self-healing) AND the imported one.
if grep -q "test-session-normal-001" "$STATE29" 2>/dev/null; then
    pass "in-vault: already-in-vault session ledgered (self-healing)"
else
    fail "in-vault: already-in-vault session not added to ledger" "$out29"
fi
if grep -q "test-session-normal-777" "$STATE29" 2>/dev/null; then
    pass "in-vault: imported session ledgered"
else
    fail "in-vault: imported session not in ledger" "$out29"
fi

# Second run against the same populated vault + ledger: both sessions now take
# the cheap ledger path (already-in-ledger=2) and the scan path reports nothing
# (already-in-vault=0) — the consequence of the self-healing _ledger_add above.
out29b=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT29" \
    --project "$REPO29" \
    --state-file "$STATE29" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "in-vault(2nd run): both sessions on the cheap ledger path" "already-in-ledger=2" "$out29b"
assert_contains "in-vault(2nd run): scan path idle (already-in-vault=0)" "already-in-vault=0" "$out29b"
assert_contains "in-vault(2nd run): nothing re-imported (new=0)" "new=0" "$out29b"

# ============================================================================
# Case 30: --dry-run counts already-in-vault but does NOT write the ledger
#          (HIMMEL-662 — the scan is read-only so it runs in dry-run, but
#          _ledger_add stays dry-run-guarded).
# ============================================================================
echo ""
echo "Case 30: already-in-vault under --dry-run counts but does not ledger"

SB="$TMP_ROOT/case30"
VAULT30="$SB/vault"
REPO30="$SB/repo"
PROJ_ROOT30="$SB/projects"
STATE30="$SB/state.json"
mkdir -p "$VAULT30" "$REPO30" "$PROJ_ROOT30"
setup_projects_dir "$PROJ_ROOT30" "$REPO30" "$VAULT30"

LIVE30="$VAULT30/sessions/2026/06/2026-06-20-1830-repo-feat-branch.md"
write_content_note "$LIVE30" "test-session-normal-001"

out30=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT30" \
    --project "$REPO30" \
    --state-file "$STATE30" \
    --vault-registry /dev/null \
    --dry-run \
    2>&1)
assert_contains "in-vault(dry): already-in-vault counted" "already-in-vault=1" "$out30"
if [ ! -f "$STATE30" ] || ! grep -q "test-session-normal-001" "$STATE30" 2>/dev/null; then
    pass "in-vault(dry): ledger NOT written under --dry-run"
else
    fail "in-vault(dry): --dry-run wrote to the ledger" "$out30"
fi

# ============================================================================
# Case 31: broken-scan advisory (HIMMEL-662 CR round) — a vault whose sessions/
#          tree holds .md notes but yields ZERO session_id frontmatter means the
#          dedup is inactive; the scan must say so on stderr instead of silently
#          degrading to duplicate-possible behavior. A genuinely-new session
#          must still import (empty set never false-skips).
# ============================================================================
echo ""
echo "Case 31: empty scan of a non-empty vault warns (dedup inactive)"

SB="$TMP_ROOT/case31"
VAULT31="$SB/vault"
REPO31="$SB/repo"
PROJ_ROOT31="$SB/projects"
STATE31="$SB/state.json"
mkdir -p "$VAULT31/sessions/2026/06" "$REPO31" "$PROJ_ROOT31"
setup_projects_dir "$PROJ_ROOT31" "$REPO31" "$VAULT31"

# A note WITHOUT any session_id frontmatter (hand-authored / foreign shape).
printf -- '---\ntitle: stray note\n---\n\nNo session_id here.\n' \
    > "$VAULT31/sessions/2026/06/2026-06-01-0900-stray.md"

out31=$(bash "$BACKFILL" \
    --projects-dir "$PROJ_ROOT31" \
    --project "$REPO31" \
    --state-file "$STATE31" \
    --vault-registry /dev/null \
    2>&1)
assert_contains "broken-scan: stderr advisory emitted" "already-in-vault dedup inactive" "$out31"
assert_contains "broken-scan: new session still imports (no false-skip)" "new=1" "$out31"

# ============================================================================
# Case 32: --reheal --rules plumbs the rules file through to the crystallizer
#          (#800). The reheal loop shares the same exported CRYSTALLIZE_RULES_FILE
#          as --recrystallize (Case 27) but heals a husk instead — assert the
#          rules-file marker lands in the crystallizer's dumped argv.
# ============================================================================
echo ""
echo "Case 32: --reheal --rules reaches the crystallizer prompt"

SB="$TMP_ROOT/case32"
VAULT32="$SB/vault"; PROJ_ROOT32="$SB/projects"; STATE32="$SB/state.json"
NOTE32="$VAULT32/sessions/2026/06/2026-06-20-0000-testrepo.md"
RULES32="$SB/rules.txt"; ARGVD32="$SB/argv.txt"
mkdir -p "$VAULT32" "$PROJ_ROOT32"
write_husk_note "$NOTE32" "reheal-rules-001"
seed_named_transcript "$PROJ_ROOT32" "reheal-rules-001" "$TRANSCRIPT_FIXTURES/normal.jsonl"
printf 'REHEAL_RULES_MARKER\n' > "$RULES32"

out32=$(env CRYSTALLIZE_CLAUDE_BIN="$CLAUDE_STUB" STUB_MODE=success \
    CRYSTALLIZE_PID_DIR="$SB/pids" CRYSTALLIZE_ARGV_DUMP="$ARGVD32" \
    bash "$BACKFILL" --reheal --rules "$RULES32" \
    --projects-dir "$PROJ_ROOT32" --luna-vault-path "$VAULT32" \
    --state-file "$STATE32" --vault-registry /dev/null 2>&1)
if grep -qF 'REHEAL_RULES_MARKER' "$ARGVD32" 2>/dev/null; then pass "rules(reheal): --rules content reaches the crystallizer prompt"; else fail "rules(reheal): rules content not in prompt" "$out32"; fi

# Trailing --rules with no value: the guard must fail fast with a clean message,
# not a raw set -u "$1: unbound variable" abort.
rc32b=0
out32b=$(bash "$BACKFILL" --reheal --rules 2>&1) || rc32b=$?
if [ "$rc32b" -eq 1 ]; then pass "rules(guard): trailing --rules exits 1"; else fail "rules(guard): wrong exit $rc32b (want 1)" "$out32b"; fi
assert_contains "rules(guard): explicit needs-a-value message" "--rules needs a value" "$out32b"

# Trailing --limit with no value (HIMMEL-842): the guard must fail fast with a
# clean message, not a raw set -u "$1: unbound variable" abort. Uses the same
# safe expansion shape (${1:-}) as the --rules arm.
rc32c=0
out32c=$(bash "$BACKFILL" --recrystallize --limit 2>&1) || rc32c=$?
if [ "$rc32c" -eq 1 ]; then pass "limit(guard): trailing --limit exits 1"; else fail "limit(guard): wrong exit $rc32c (want 1)" "$out32c"; fi
assert_contains "limit(guard): explicit needs-a-number message" "--limit needs a number" "$out32c"

# ============================================================================
# Case 33: multi-vault --all already-in-vault dedup (#790) — two repos route to
#          two DIFFERENT vaults (mirror Case 17), each vault already holds a live
#          note for its repo's session. One --all pass must dedup BOTH via the
#          per-vault session_id set (already-in-vault=2) and import nothing; each
#          vault keeps exactly its one pre-existing note — no duplicate, no
#          cross-vault bleed.
# ============================================================================
echo ""
echo "Case 33: multi-vault --all already-in-vault dedup (per-vault set keying)"

SB="$TMP_ROOT/case33"
VAULT33A="$SB/vaultA"; VAULT33B="$SB/vaultB"
REPO33A="$SB/repo-alpha"; REPO33B="$SB/repo-beta"
PROJ_ROOT33="$SB/projects"; STATE33="$SB/state.json"
mkdir -p "$VAULT33A" "$VAULT33B" "$REPO33A" "$REPO33B" "$PROJ_ROOT33"
setup_projects_dir "$PROJ_ROOT33" "$REPO33A" "$VAULT33A"
setup_projects_dir "$PROJ_ROOT33" "$REPO33B" "$VAULT33B"

# Seed each vault with a live-captured note whose session_id matches that repo's
# transcript basename (setup_projects_dir names it test-session-normal-001), so
# backfill's per-vault scan recognizes it and skips a duplicate import — keyed by
# the resolved vault, so vaultA's note never dedups vaultB's session or vice-versa.
LIVE33A="$VAULT33A/sessions/2026/06/2026-06-20-1830-alpha-feat-branch.md"
LIVE33B="$VAULT33B/sessions/2026/06/2026-06-20-1830-beta-feat-branch.md"
write_content_note "$LIVE33A" "test-session-normal-001"
write_content_note "$LIVE33B" "test-session-normal-001"

out33=$(bash "$BACKFILL" \
    --all \
    --projects-dir "$PROJ_ROOT33" \
    --state-file "$STATE33" \
    --vault-registry /dev/null \
    2>&1)

assert_contains "multi-vault-dedup: both live sessions skipped (already-in-vault=2)" "already-in-vault=2" "$out33"
assert_contains "multi-vault-dedup: nothing re-imported (new=0)" "new=0" "$out33"

CNT33A="$(find "$VAULT33A/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
CNT33B="$(find "$VAULT33B/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CNT33A" = "1" ] && [ "$CNT33B" = "1" ]; then
    pass "multi-vault-dedup: each vault keeps exactly its one pre-existing note (no duplicate)"
else
    fail "multi-vault-dedup: wrong note counts (vaultA=$CNT33A vaultB=$CNT33B, expected 1/1)" "$out33"
fi

# ============================================================================
# Case 34: cross-vault bleed discriminator — both repos share the SAME session
#          id (setup_projects_dir hardcodes test-session-normal-001) but ONLY
#          vault A is pre-seeded with it. Per-vault set keying must import repo
#          B's session into vault B (already-in-vault=1, new=1); a buggy GLOBAL
#          set would see the id from vault A's scan and skip both (already=2,
#          new=0). Case 33 alone cannot tell those apart — this one can.
# ============================================================================
echo ""
echo "Case 34: cross-vault bleed discriminator (only vault A pre-seeded)"

SB="$TMP_ROOT/case34"
VAULT34A="$SB/vaultA"; VAULT34B="$SB/vaultB"
REPO34A="$SB/repo-alpha"; REPO34B="$SB/repo-beta"
PROJ_ROOT34="$SB/projects"; STATE34="$SB/state.json"
mkdir -p "$VAULT34A" "$VAULT34B" "$REPO34A" "$REPO34B" "$PROJ_ROOT34"
setup_projects_dir "$PROJ_ROOT34" "$REPO34A" "$VAULT34A"
setup_projects_dir "$PROJ_ROOT34" "$REPO34B" "$VAULT34B"

LIVE34A="$VAULT34A/sessions/2026/06/2026-06-20-1830-alpha-feat-branch.md"
write_content_note "$LIVE34A" "test-session-normal-001"

out34=$(bash "$BACKFILL" \
    --all \
    --projects-dir "$PROJ_ROOT34" \
    --state-file "$STATE34" \
    --vault-registry /dev/null \
    2>&1)

assert_contains "bleed-discriminator: only vault A's session skipped (already-in-vault=1)" "already-in-vault=1" "$out34"
assert_contains "bleed-discriminator: repo B's same-id session imports into vault B (new=1)" "new=1" "$out34"

CNT34A="$(find "$VAULT34A/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
CNT34B="$(find "$VAULT34B/sessions" -type f -name '*.md' 2>/dev/null | wc -l | tr -d ' ')"
if [ "$CNT34A" = "1" ] && [ "$CNT34B" = "1" ]; then
    pass "bleed-discriminator: vault A untouched, vault B gained exactly the import (no cross-vault bleed)"
else
    fail "bleed-discriminator: wrong note counts (vaultA=$CNT34A vaultB=$CNT34B, expected 1/1)" "$out34"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "===================================="
printf 'test summary: %d passed, %d failed\n' "$PASS" "$FAIL"
echo "===================================="

[ "$FAIL" -gt 0 ] && exit 1 || exit 0
