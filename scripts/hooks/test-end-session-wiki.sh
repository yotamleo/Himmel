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

# Crystallizer test seam (HIMMEL-576): point the backgrounded crystallizer at the
# claude STUB (no-op by default) so these tests NEVER spawn a real `claude` /
# bill the Max plan. Exported -> inherited by every `env ... bash "$HOOK"` run.
STUB="$(cd "$(dirname "$0")" && pwd)/testdata/bin/claude-stub.sh"
chmod +x "$STUB" 2>/dev/null || true
export CRYSTALLIZE_CLAUDE_BIN="$STUB"
export STUB_MODE="noop"
CRYSTALLIZE_PID_DIR="$(mktemp -d)"
export CRYSTALLIZE_PID_DIR

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
# Behavioural (HIMMEL-590 F7): the bare ~/Documents/luna default now requires a
# REAL vault (.obsidian marker). With NO such vault the hook must SKIP and not
# materialize a phantom vault; with the marker present it resolves + writes.
# F7a — no marker -> skip, no phantom vault dir created.
SB="$(make_sandbox)"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env -u LUNA_VAULT_PATH -u USERPROFILE OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ ! -d "$SB/home/Documents/luna/sessions" ]; then
    pass "F7: no configured luna vault -> hook skips, no phantom vault created"
else
    fail "F7: hook materialized a phantom vault with no .obsidian marker (rc: $RC)"
fi
rm -rf "$SB"
# F7b — with the .obsidian marker, the default resolves to $HOME/Documents/luna
# and writes, exercising the default-resolution line (not just its source text).
SB="$(make_sandbox)"
mkdir -p "$SB/home/Documents/luna/.obsidian"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env -u LUNA_VAULT_PATH -u USERPROFILE OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ -n "$(find "$SB/home/Documents/luna/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "default vault root resolves to \$HOME/Documents/luna (real vault)"
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

# --- Case 1d: a leading ~/ in config.vault_path expands to $HOME --------------
# A JSON config value can't rely on shell tilde expansion, so the hook expands a
# leading "~/" itself. HOME is pinned to a sandbox so the note must land under it.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/home"
printf '{"vault_path":"~/myvault"}\n' > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env -u LUNA_VAULT_PATH OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"
if [ -n "$(find "$SB/home/myvault/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "config.vault_path leading ~/ expands to \$HOME/myvault"
else
    fail "config.vault_path ~/ did not expand under \$HOME/myvault"
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
if [ -n "$NOTE" ] && grep -q '^session_id:' "$NOTE"; then
    pass "note carries session_id field"
else
    fail "note missing 'session_id' frontmatter field"
fi
if [ -n "$NOTE" ] && grep -q '^source: live$' "$NOTE"; then
    pass "note carries source: live"
else
    fail "note missing 'source: live' frontmatter field"
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

# --- Case 4: per-repo `vault` NAME routes via the ~/Documents/<name> convention
# (HIMMEL-403). A real vault needs an .obsidian/ marker; FS fallback then writes.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/home/Documents/medic/.obsidian"
printf '%s\n' '{"vault":"medic"}' > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env -u LUNA_VAULT_PATH -u USERPROFILE OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"
if [ -n "$(find "$SB/home/Documents/medic/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "vault NAME routes to ~/Documents/medic via convention"
else
    fail "vault NAME did not route to the convention vault"
fi
rm -rf "$SB"

# --- Case 5: an invalid `vault` NAME is fail-closed — skip, no write anywhere --
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/home"
printf '%s\n' '{"vault":"../evil"}' > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env -u LUNA_VAULT_PATH -u USERPROFILE OSTYPE="linux-gnu" OS="" HOME="$SB/home" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ "$RC" = "0" ]; then pass "invalid vault name still exits 0"; else fail "invalid vault name exit was $RC, expected 0"; fi
if [ -z "$(find "$SB/home" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "invalid vault name wrote no note anywhere"
else
    fail "invalid vault name unexpectedly wrote a note"
fi
if grep -q 'skipped: vault' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    pass "log records the fail-closed skip"
else
    fail "log does not record the vault skip"
fi
# I1 regression guard: the skip must NOT trip the EXIT trap's phantom FAILED line.
if grep -q 'FAILED' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    fail "skip path logged a phantom FAILED line (HOOK_OK not set)"
else
    pass "skip path leaves no phantom FAILED log line"
fi
rm -rf "$SB"

# --- Case 6: husk-skip — a contentless transcript writes NO note (HIMMEL-576) -
SB="$(make_sandbox)"
printf '%s\n' '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"hi"}}' > "$SB/transcript.jsonl"
RC="$(run_hook "$SB")"
if [ "$RC" = "0" ]; then pass "husk: hook exits 0"; else fail "husk: exit was $RC, expected 0"; fi
if [ -z "$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)" ]; then
    pass "husk: no note written for a contentless transcript"
else
    fail "husk: a note was written for a contentless transcript"
fi
if grep -q 'skipped: husk (no content)' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    pass "husk: log records the skip"
else
    fail "husk: log does not record the husk skip"
fi
rm -rf "$SB"

# --- Case 7: a thinking/tool-only session IS captured (not a husk) -----------
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"x"},{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}' > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE" ]; then pass "tool-only: note written (not a husk)"; else fail "tool-only: no note written"; fi
if [ -n "$NOTE" ] && grep -q 'Tool-only session' "$NOTE"; then
    pass "tool-only: Summary surfaces command activity (not 'Transcript unavailable')"
else
    fail "tool-only: Summary did not surface command activity"
fi
rm -rf "$SB"

# --- Case 8: hook spawns the crystallizer for a non-husk note (HIMMEL-576) ----
SB="$(make_sandbox)"
MARK="$SB/marker.txt"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="success" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
# Poll up to ~3s for the detached crystallizer to touch the marker.
i=0; while [ ! -s "$MARK" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$MARK" ]; then pass "crystallizer spawned for a non-husk note"; else fail "crystallizer was not spawned"; fi
rm -rf "$SB"

# --- Case 9: crystallize:false suppresses the spawn --------------------------
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude"
MARK="$SB/marker.txt"
printf '%s\n' '{"enabled":true,"crystallize":false}' > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="success" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
sleep 0.5
if [ ! -s "$MARK" ]; then pass "crystallize:false suppresses the spawn"; else fail "crystallize:false still spawned the crystallizer"; fi
rm -rf "$SB"

# --- Case 10: BSD/macOS `date +%s%3N` must not crash the REST-success path (GH#202)
# `%N` is a GNU extension. On BSD date, `+%s%3N` is NOT an error (exit 0, so the
# hook's `|| echo 0` guard never fires) — it yields a non-numeric string like
# `17514160003N`. Under `set +e` the failed `$((END_MS - START_MS))` leaves
# ELAPSED UNSET; the success-path log line `wrote ... (${ELAPSED}ms)` then
# referenced it under `set -u` -> "unbound variable" -> the hook aborted BEFORE
# its success log + crystallizer spawn (HIMMEL-576). Note delivered by the PUT,
# but crystallization silently never fired on macOS. On a GNU box `%3N` works,
# so reaching this needs a `date` shim emitting the BSD-shaped value for `%3N`
# (real date otherwise) — the GNU-host technique from test-compute-duration.sh
# (HIMMEL-653/GH#192) — plus a `curl` shim forcing HTTP 200 so the REST-success
# branch (the only ELAPSED reader) is actually exercised.
SB="$(make_sandbox)"
SHIMDIR="$SB/bin"; mkdir -p "$SHIMDIR"
REAL_DATE="$(command -v date)"
cat > "$SHIMDIR/date" <<EOF
#!/usr/bin/env bash
case "\$*" in
    *%3N*) printf '%sN\n' "\$('$REAL_DATE' +%s)"; exit 0 ;;
esac
exec '$REAL_DATE' "\$@"
EOF
chmod +x "$SHIMDIR/date"
# Stub curl to report HTTP 200 for the vault PUT (the hook's only curl call),
# so the hook takes the success path that reads ELAPSED.
cat > "$SHIMDIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '200'
EOF
chmod +x "$SHIMDIR/curl"
MARK="$SB/marker.txt"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" PATH="$SHIMDIR:$PATH" \
        LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="dummy-key" \
        STUB_MODE="success" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$SB/pids" \
        CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ "$RC" = "0" ]; then pass "GH#202: BSD-shaped %3N — hook still exits 0"; else fail "GH#202: exit was $RC, expected 0"; fi
if grep -q 'wrote ' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null \
   && ! grep -q 'unbound variable\|FAILED' "$SB/proj/.claude/end-session-wiki.log" 2>/dev/null; then
    pass "GH#202: REST-success log line survives a non-numeric %3N (no unbound-var crash)"
else
    fail "GH#202: non-numeric %3N crashed the success path before the 'wrote' log"
fi
# The crystallizer spawn is line 457 — reached only if line 456's ELAPSED
# reference didn't abort. Poll for the marker the same way as Case 8.
i=0; while [ ! -s "$MARK" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if [ -s "$MARK" ]; then
    pass "GH#202: crystallizer still spawns after a non-numeric %3N"
else
    fail "GH#202: %3N crash pre-empted the crystallizer spawn"
fi
rm -rf "$SB"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "SOME FAILED"
exit 1
