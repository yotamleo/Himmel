#!/usr/bin/env bash
# Smoke test for scripts/hooks/end-session-wiki.sh.
#
# Usage: bash scripts/hooks/test-end-session-wiki.sh
#
# Contract under test:
#   * The hook ALWAYS exits 0 (failure policy #27 — never block session end).
#   * Default vault root is $HOME/Documents/luna (NOT the historical
#     .../luna/luna double-segment, which was the bug that made every
#     SessionEnd fail to find the Obsidian REST API key).
#   * When no REST API key is available, the hook falls back to a direct
#     on-disk write into <vault>/sessions/YYYY/MM/ instead of giving up.
#   * Dry-run config renders to the log and writes no note file.
#
# Exit codes:
#   0 — all cases passed
#   1 — at least one case failed
set -uo pipefail

HOOK="$(cd "$(dirname "$0")" && pwd)/end-session-wiki.sh"
[ -r "$HOOK" ] || { echo "FAIL: hook not found at $HOOK"; exit 1; }

FAILED=0
pass() { printf 'PASS: %s\n' "$1"; }
fail() { printf 'FAIL: %s\n' "$1"; FAILED=1; }

# Build a throwaway vault + project + transcript, run the hook, echo nothing.
# Caller inspects the returned sandbox dir.
make_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/vault" "$sb/proj"
    # Old timestamp so the >=60s min-duration gate passes.
    printf '%s\n' '{"timestamp":"2026-06-17T00:00:00Z","message":{"role":"assistant","content":[{"type":"text","text":"line one\nline two"}]}}' > "$sb/transcript.jsonl"
    printf '%s' "$sb"
}

run_hook() {
    local sb="$1"
    local payload
    payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' \
        "$sb/transcript.jsonl" "$sb/proj")
    # OSTYPE/OS are forced to a non-Windows value so the .sh platform guard
    # (which makes this script a deliberate no-op on Windows, where the .ps1
    # twin runs) doesn't short-circuit the logic we're exercising. On a
    # Linux/macOS CI this is a no-op; on Windows Git Bash it lets the test run.
    printf '%s' "$payload" | \
        env OSTYPE="linux-gnu" OS="" \
            LUNA_VAULT_PATH="$sb/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$sb/proj" \
        bash "$HOOK"
    echo "$?"
}

run_hook_putfail() {
    # Like run_hook, but a key IS present so the hook attempts the REST PUT,
    # while OBSIDIAN_API_URL points at a closed loopback port so curl fails —
    # exercising the *PUT-failure* fallback branch (the common real-world case
    # where Obsidian is installed but not running), distinct from the no-key one.
    local sb="$1"
    local payload
    payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' \
        "$sb/transcript.jsonl" "$sb/proj")
    printf '%s' "$payload" | \
        env OSTYPE="linux-gnu" OS="" \
            LUNA_VAULT_PATH="$sb/vault" OBSIDIAN_API_KEY="dummy-key" \
            OBSIDIAN_API_URL="https://127.0.0.1:1" CLAUDE_PROJECT_DIR="$sb/proj" \
        bash "$HOOK"
    echo "$?"
}

# --- Case 1: default vault root is .../Documents/luna (regression guard) ------
if grep -q 'Documents/luna/luna' "$HOOK"; then
    fail "default vault root still contains the double-luna bug (Documents/luna/luna)"
else
    pass "default vault root no longer uses Documents/luna/luna"
fi
# Behavioural: with LUNA_VAULT_PATH unset (and USERPROFILE unset to skip the
# Windows fallback), the default resolves to $HOME/Documents/luna — exercising
# the changed default-resolution line, not just its source text.
SB="$(make_sandbox)"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env -u LUNA_VAULT_PATH -u USERPROFILE OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ -n "$(find "$SB/home/Documents/luna/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "default vault root resolves to \$HOME/Documents/luna"
else
    fail "default did not write under \$HOME/Documents/luna (last rc line: $RC)"
fi
rm -rf "$SB"

# --- Case 1c: config.vault_path overrides the LUNA_VAULT_PATH env (precedence) -
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/cfgvault" "$SB/envvault"
printf '{"vault_path":"%s"}\n' "$SB/cfgvault" > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" LUNA_VAULT_PATH="$SB/envvault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"
if [ -n "$(find "$SB/cfgvault/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "config.vault_path wins over LUNA_VAULT_PATH env"
else
    fail "config.vault_path did not take precedence (no note under cfgvault)"
fi
if [ -z "$(find "$SB/envvault/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "env-vault NOT written when config.vault_path is set"
else
    fail "note wrongly written to the env vault despite config.vault_path"
fi
rm -rf "$SB"

# --- Case 2: FS fallback writes a note when no API key is available ----------
SB="$(make_sandbox)"
RC="$(run_hook "$SB")"
if [ "$RC" = "0" ]; then pass "hook exits 0 (no-key fallback)"; else fail "hook exit was $RC, expected 0"; fi
NOTE="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE" ]; then
    pass "FS fallback wrote a note ($(basename "$NOTE"))"
else
    fail "FS fallback wrote no note under $SB/vault/sessions"
fi
if grep -q 'local fs' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    pass "log records the local-fs fallback"
else
    fail "log does not mention local-fs fallback"
fi
if [ -n "$NOTE" ] && grep -q 'type: session' "$NOTE"; then
    pass "note carries the session frontmatter"
else
    fail "note missing 'type: session' frontmatter"
fi
rm -rf "$SB"

# --- Case 2b: REST PUT failure falls back to an on-disk write ----------------
SB="$(make_sandbox)"
RC="$(run_hook_putfail "$SB")"
if [ "$RC" = "0" ]; then pass "hook exits 0 (PUT-failure fallback)"; else fail "PUT-failure exit was $RC, expected 0"; fi
NOTE="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE" ]; then
    pass "PUT-failure fallback wrote a note ($(basename "$NOTE"))"
else
    fail "PUT-failure fallback wrote no note under $SB/vault/sessions"
fi
if grep -q 'local fs fallback' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    pass "log records the PUT-failure local-fs fallback"
else
    fail "log does not mention the PUT-failure local-fs fallback"
fi
rm -rf "$SB"

# --- Case 3: dry-run writes no note file ------------------------------------
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude"
printf '%s\n' '{"enabled":true,"dry_run":true,"min_duration_seconds":60}' > "$SB/proj/.claude/end-session-wiki.json"
RC="$(run_hook "$SB")"
if [ "$RC" = "0" ]; then pass "hook exits 0 (dry-run)"; else fail "dry-run exit was $RC, expected 0"; fi
if [ -z "$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "dry-run wrote no note file"
else
    fail "dry-run unexpectedly wrote a note file"
fi
rm -rf "$SB"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "SOME FAILED"
exit 1
