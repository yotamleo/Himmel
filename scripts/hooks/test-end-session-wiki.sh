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

# Log/marker relocated per-machine, OUTSIDE any repo (HIMMEL-1215): mirrors the
# hook's own PROJECT_SLUG derivation exactly (path separators/colon -> "-") so
# tests can compute the expected log/marker path for a given (HOME, proj) pair.
esw_slug() { printf '%s' "$1" | sed 's/[\/\\:]/-/g'; }
log_path_for() { printf '%s/.claude/logs/end-session-wiki/%s.log' "$1" "$(esw_slug "$2")"; }
marker_path_for() { printf '%s/.claude/logs/end-session-wiki/%s.degraded' "$1" "$(esw_slug "$2")"; }

# Build a throwaway vault + project + transcript, run the hook, echo nothing.
# Caller inspects the returned sandbox dir.
make_sandbox() {
    local sb; sb="$(mktemp -d)"
    mkdir -p "$sb/vault" "$sb/proj" "$sb/home"
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
    # HOME is sandboxed so the relocated per-machine log (HIMMEL-1215) never
    # touches the real ~/.claude/logs/end-session-wiki on the dev machine.
    printf '%s' "$payload" | \
        env OSTYPE="linux-gnu" OS="" HOME="$sb/home" \
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
        env OSTYPE="linux-gnu" OS="" HOME="$sb/home" \
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
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" LUNA_VAULT_PATH="$SB/envvault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"
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
if grep -q 'local fs' "$(log_path_for "$SB/home" "$SB/proj")" 2>/dev/null; then
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
if grep -q 'local fs fallback' "$(log_path_for "$SB/home" "$SB/proj")" 2>/dev/null; then
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
LOG5="$(log_path_for "$SB/home" "$SB/proj")"
if grep -q 'skipped: vault' "$LOG5" 2>/dev/null; then
    pass "log records the fail-closed skip"
else
    fail "log does not record the vault skip"
fi
# I1 regression guard: the skip must NOT trip the EXIT trap's phantom FAILED line.
if grep -q 'FAILED' "$LOG5" 2>/dev/null; then
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
if grep -q 'skipped: husk (no content)' "$(log_path_for "$SB/home" "$SB/proj")" 2>/dev/null; then
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
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
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
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
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
RC="$(printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" PATH="$SHIMDIR:$PATH" \
        LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="dummy-key" \
        STUB_MODE="success" CRYSTALLIZE_MARKER="$MARK" CRYSTALLIZE_PID_DIR="$SB/pids" \
        CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
if [ "$RC" = "0" ]; then pass "GH#202: BSD-shaped %3N — hook still exits 0"; else fail "GH#202: exit was $RC, expected 0"; fi
LOG10="$(log_path_for "$SB/home" "$SB/proj")"
if grep -q 'wrote ' "$LOG10" 2>/dev/null \
   && ! grep -Eq 'unbound variable|FAILED' "$LOG10" 2>/dev/null; then
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

# --- Case 11: unreadable crystallize_rules logs a warning (HIMMEL-663) --------
# Fail-open but not invisible: the spawn still happens, but the hook logs the
# expanded path so the operator can see the misconfiguration.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/home"
printf '%s\n' '{"enabled":true,"crystallize_rules":"~/missing-rules.md"}' > "$SB/proj/.claude/end-session-wiki.json"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" \
    LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="noop" CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
LOG11="$(log_path_for "$SB/home" "$SB/proj")"
if grep -q 'crystallize_rules not readable' "$LOG11" 2>/dev/null; then
    pass "rules(hook): unreadable crystallize_rules logged"
else
    fail "rules(hook): unreadable crystallize_rules NOT logged"
fi
if grep -qF "$SB/home/missing-rules.md" "$LOG11" 2>/dev/null; then
    pass "rules(hook): log carries the tilde-EXPANDED path"
else
    fail "rules(hook): log missing the expanded path"
fi
rm -rf "$SB"

# --- Case 12: crystallize_rules plumbs through to the spawned crystallizer -----
# Proves the whole chain: jq field-6 parse -> ~/ expansion -> export -> across
# the detach boundary -> the crystallizer reads the file and injects its content
# into the claude prompt (argv). Same stubbing pattern as Case 8.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude" "$SB/home"
printf 'HOOK_RULES_MARKER\n' > "$SB/home/rules-marker.md"
printf '%s\n' '{"enabled":true,"crystallize_rules":"~/rules-marker.md"}' > "$SB/proj/.claude/end-session-wiki.json"
ENVD12="$SB/envdump.txt"; ARGVD12="$SB/argv.txt"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env OSTYPE="linux-gnu" OS="" HOME="$SB/home" \
    LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="success" CRYSTALLIZE_ENV_DUMP="$ENVD12" CRYSTALLIZE_ARGV_DUMP="$ARGVD12" \
    CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
# Poll up to ~3s for the detached crystallizer to dump its env (like Case 8).
i=0; while [ ! -s "$ENVD12" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if grep -qF "CRYSTALLIZE_RULES_FILE=$SB/home/rules-marker.md" "$ENVD12" 2>/dev/null; then
    pass "rules(hook): stub saw CRYSTALLIZE_RULES_FILE at the expanded absolute path"
else
    fail "rules(hook): CRYSTALLIZE_RULES_FILE did not reach the spawned crystallizer expanded"
fi
if grep -qF 'HOOK_RULES_MARKER' "$ARGVD12" 2>/dev/null; then
    pass "rules(hook): rules content reached the claude prompt across the detach boundary"
else
    fail "rules(hook): rules content missing from the spawned prompt"
fi
rm -rf "$SB"

# --- Case 13: crystallize_model precedence (HIMMEL-672) ------------------------
# Config supplies the DEFAULT model; a CRYSTALLIZE_MODEL already set in the
# launching shell must WIN over the config (per-session operator switch).
# 13a — config only (env unset) -> the config model reaches claude's argv.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude"
printf '%s\n' '{"enabled":true,"crystallize_model":"cfg-pin-model"}' > "$SB/proj/.claude/end-session-wiki.json"
ARGVD13="$SB/argv.txt"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env -u CRYSTALLIZE_MODEL OSTYPE="linux-gnu" OS="" HOME="$SB/home" \
    LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="success" CRYSTALLIZE_ARGV_DUMP="$ARGVD13" \
    CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
i=0; while [ ! -s "$ARGVD13" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if grep -qxF 'arg=cfg-pin-model' "$ARGVD13" 2>/dev/null; then
    pass "model(hook): config crystallize_model reaches claude argv when env is unset"
else
    fail "model(hook): config crystallize_model did NOT reach claude argv"
fi
rm -rf "$SB"
# 13b — env set in the launching shell -> env wins over the config model.
SB="$(make_sandbox)"
mkdir -p "$SB/proj/.claude"
printf '%s\n' '{"enabled":true,"crystallize_model":"cfg-pin-model"}' > "$SB/proj/.claude/end-session-wiki.json"
ARGVD13="$SB/argv.txt"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env CRYSTALLIZE_MODEL="env-switch-model" OSTYPE="linux-gnu" OS="" HOME="$SB/home" \
    LUNA_VAULT_PATH="$SB/vault" OBSIDIAN_API_KEY="" CLAUDE_PROJECT_DIR="$SB/proj" \
    STUB_MODE="success" CRYSTALLIZE_ARGV_DUMP="$ARGVD13" \
    CRYSTALLIZE_PID_DIR="$SB/pids" bash "$HOOK"
i=0; while [ ! -s "$ARGVD13" ] && [ "$i" -lt 30 ]; do sleep 0.1; i=$((i + 1)); done
if grep -qxF 'arg=env-switch-model' "$ARGVD13" 2>/dev/null; then
    pass "model(hook): launching-shell CRYSTALLIZE_MODEL wins over config"
else
    fail "model(hook): env CRYSTALLIZE_MODEL did not override the config model"
fi
if grep -qxF 'arg=cfg-pin-model' "$ARGVD13" 2>/dev/null; then
    fail "model(hook): config model leaked into argv despite env override"
else
    pass "model(hook): config model correctly absent when env override is set"
fi
rm -rf "$SB"

# --- Case 14: a 401 from the target key retries with a sibling vault's key -----
# (HIMMEL-711) Multi-vault: when a DIFFERENT vault owns port 27124, the target
# key gets 401. The hook must discover the operator's other vault keys and retry;
# the sibling whose server is bound accepts its own key. `curl` is PATH-shimmed to
# emit 200 ONLY for the OK key (else 401) — no real network, no real Obsidian.
# HOME is sandboxed so only the two fake vaults are discovered.
SB="$(make_sandbox)"
mkdir -p "$SB/home/Documents/vaultA/.obsidian/plugins/obsidian-local-rest-api" \
         "$SB/home/Documents/vaultB/.obsidian/plugins/obsidian-local-rest-api"
printf '{"apiKey":"primary-key-A"}\n' > "$SB/home/Documents/vaultA/.obsidian/plugins/obsidian-local-rest-api/data.json"
printf '{"apiKey":"sibling-key-B"}\n' > "$SB/home/Documents/vaultB/.obsidian/plugins/obsidian-local-rest-api/data.json"
SHIMDIR="$SB/bin"; mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/curl" <<'EOF'
#!/usr/bin/env bash
key=""; prev=""
for a in "$@"; do
    if [ "$prev" = "-H" ]; then
        case "$a" in "Authorization: Bearer "*) key="${a#Authorization: Bearer }" ;; esac
    fi
    prev="$a"
done
if [ "$key" = "$ESW_STUB_OK_KEY" ]; then printf '200'; else printf '401'; fi
EOF
chmod +x "$SHIMDIR/curl"
# Seed a STALE degradation marker: a healthy recovery PUT must clear it (the
# self-healing half of the loud flag — an unbroken clear prevents a permanent
# false "DEGRADED" banner after a single bad session).
MARKER14="$(marker_path_for "$SB/home" "$SB/proj")"
mkdir -p "$(dirname "$MARKER14")"; printf 'stale DEGRADED marker from a prior session\n' > "$MARKER14"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
RC="$(printf '%s' "$payload" | env -u USERPROFILE OSTYPE="linux-gnu" OS="" PATH="$SHIMDIR:$PATH" \
        HOME="$SB/home" LUNA_VAULT_PATH="$SB/home/Documents/vaultA" OBSIDIAN_API_KEY="" \
        ESW_STUB_OK_KEY="sibling-key-B" STUB_MODE="noop" CRYSTALLIZE_PID_DIR="$SB/pids" \
        CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"; echo $?)"
LOG14="$(log_path_for "$SB/home" "$SB/proj")"
if [ "$RC" = "0" ]; then pass "401-retry: hook exits 0"; else fail "401-retry: exit was $RC, expected 0"; fi
if grep -q 'recovered with a sibling vault key' "$LOG14" 2>/dev/null; then
    pass "401-retry: recovered via a sibling vault key"
else
    fail "401-retry: did not recover via a sibling key"
fi
if grep -q 'wrote sessions/' "$LOG14" 2>/dev/null && ! grep -q 'local fs fallback' "$LOG14" 2>/dev/null; then
    pass "401-retry: took the REST success path (no disk fallback)"
else
    fail "401-retry: fell back to disk instead of recovering"
fi
if [ ! -f "$MARKER14" ]; then
    pass "401-retry: healthy recovery PUT cleared the stale degradation marker"
else
    fail "401-retry: stale degradation marker survived a healthy recovery PUT"
fi
# Redaction (hard requirement): no apiKey value may reach the log.
if grep -q 'sibling-key-B\|primary-key-A' "$LOG14" 2>/dev/null; then
    fail "401-retry: an apiKey value leaked into the log"
else
    pass "401-retry: no apiKey value in the log (redaction holds)"
fi
rm -rf "$SB"

# --- Case 14b: every candidate vault key 401s -> on-disk fallback preserved ----
SB="$(make_sandbox)"
mkdir -p "$SB/home/Documents/vaultA/.obsidian/plugins/obsidian-local-rest-api"
printf '{"apiKey":"primary-key-A"}\n' > "$SB/home/Documents/vaultA/.obsidian/plugins/obsidian-local-rest-api/data.json"
SHIMDIR="$SB/bin"; mkdir -p "$SHIMDIR"
cat > "$SHIMDIR/curl" <<'EOF'
#!/usr/bin/env bash
printf '401'
EOF
chmod +x "$SHIMDIR/curl"
payload=$(printf '{"transcript_path":"%s","cwd":"%s","session_id":"t","reason":"other"}' "$SB/transcript.jsonl" "$SB/proj")
printf '%s' "$payload" | env -u USERPROFILE OSTYPE="linux-gnu" OS="" PATH="$SHIMDIR:$PATH" \
    HOME="$SB/home" LUNA_VAULT_PATH="$SB/home/Documents/vaultA" OBSIDIAN_API_KEY="" \
    STUB_MODE="noop" CRYSTALLIZE_PID_DIR="$SB/pids" CLAUDE_PROJECT_DIR="$SB/proj" bash "$HOOK"
LOG14B="$(log_path_for "$SB/home" "$SB/proj")"
NOTE="$(find "$SB/home/Documents/vaultA/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if grep -q 'local fs fallback' "$LOG14B" 2>/dev/null && [ -n "$NOTE" ]; then
    pass "401-retry: all keys 401 -> on-disk fallback preserved"
else
    fail "401-retry: all-keys-401 did not fall back to disk"
fi
# The loud degradation flag (HIMMEL-711): a persisted marker must be written so a
# SessionStart / where-are-we surface can pick up the silent-disk fallback.
MARKER14B="$(marker_path_for "$SB/home" "$SB/proj")"
if [ -f "$MARKER14B" ] && grep -q 'DEGRADED' "$MARKER14B" 2>/dev/null; then
    pass "401-retry: degradation marker persisted on disk-only fallback"
else
    fail "401-retry: no degradation marker written on disk-only fallback"
fi
# Redaction (hard requirement): no apiKey value in the log OR the marker.
if grep -q 'primary-key-A' "$LOG14B" "$MARKER14B" 2>/dev/null; then
    fail "401-retry: an apiKey value leaked into the log/marker on fallback"
else
    pass "401-retry: no apiKey value in the log or marker (redaction holds)"
fi
rm -rf "$SB"

# --- Case 15: a high-entropy operand is elided; surrounding text survives ----
# (HIMMEL-1345) The exact real-world shape that wedged the vault autosync: a
# GitHub GraphQL global node ID copied verbatim into a session note tripped
# gitleaks' generic-api-key rule. Command/subcommand/flags/paths must remain
# readable; only the opaque threadId value is replaced.
#
# The three secret-shaped fixture values below are assembled from concatenated
# chunks at runtime, rather than written as single contiguous literals, so no
# realistic-looking secret sits in tracked source (this repo's own gitleaks
# pre-commit gate already passes on these fixtures as plain literals — this is
# hygiene/futureproofing against EXTERNAL scanners, e.g. GitHub push
# protection or a downstream/adopter gitleaks config, not a fix for a live
# leak). The same variables are reused in the negative assertions below so the
# fixture and the assertion can never drift apart.
TOK_GQL="PRRT_k""wDOS8W""KNM6UP""mnU"
TOK_KEY="api-Live_8""JxQ2mN7pR4""vT9yW6cK1h""F5dG0zB3uE"
TOK_B64="AbCdEfGhIj""KlMnOpQrSt""UvWxYz0123""456789+/=="
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"resolved the thread"},{"type":"tool_use","name":"Bash","input":{"command":"gh api graphql -F threadId=\"'"$TOK_GQL"'\" -F body=@\"C:/Users/op/note.md\""}},{"type":"tool_use","name":"Bash","input":{"command":"client --api-key '"$TOK_KEY"'"}},{"type":"tool_use","name":"Bash","input":{"command":"client --blob='"$TOK_B64"'"}},{"type":"tool_use","name":"Bash","input":{"command":"git status"}}]}}' \
  > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE15="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE15" ] && grep -q '<elided>' "$NOTE15"; then
    pass "HIMMEL-1345: high-entropy operand elided"
else
    fail "HIMMEL-1345: high-entropy operand was NOT elided"
fi
if [ -n "$NOTE15" ] && ! grep -qF "$TOK_GQL" "$NOTE15"; then
    pass "HIMMEL-1345: the raw high-entropy token does not appear in the note"
else
    fail "HIMMEL-1345: the raw high-entropy token leaked into the note"
fi
if [ -n "$NOTE15" ] && grep -qF 'gh api graphql -F threadId="<elided>"' "$NOTE15"; then
    pass "HIMMEL-1345: program/subcommand/flag text survives around the elision"
else
    fail "HIMMEL-1345: surrounding command text did not survive the scrub"
fi
if [ -n "$NOTE15" ] && grep -qF 'client --api-key <elided>' "$NOTE15" && ! grep -qF "$TOK_KEY" "$NOTE15"; then
    pass "HIMMEL-1345: API key containing a hyphen is elided"
else
    fail "HIMMEL-1345: API key containing a hyphen leaked or lost surrounding text"
fi
if [ -n "$NOTE15" ] && grep -qF 'client --blob=<elided>' "$NOTE15" && ! grep -qF "$TOK_B64" "$NOTE15"; then
    pass "HIMMEL-1345: base64 blob containing +, /, and = padding is elided"
else
    fail "HIMMEL-1345: base64 blob containing +, /, and = padding leaked or lost surrounding text"
fi
if [ -n "$NOTE15" ] && grep -q 'git status' "$NOTE15"; then
    pass "HIMMEL-1345: an unrelated ordinary command in the same session is untouched"
else
    fail "HIMMEL-1345: an ordinary command in the same session was altered"
fi
rm -rf "$SB"

# --- Case 16: an ordinary command with no high-entropy operand is unchanged --
# Negative case: proves the scrubber is not over-aggressive (a scrubber that
# elides everything would still pass Case 15 alone). Uses a command with
# REPEATED internal spaces and a spacing-sensitive quoted argument — a
# scrubber that unconditionally splits-on-whitespace-and-rejoins-with-a-
# single-space (rather than only rewriting a line that actually had a token
# elided) would silently collapse both, passing this case vacuously.
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"checked history"},{"type":"tool_use","name":"Bash","input":{"command":"git   log --oneline"}},{"type":"tool_use","name":"Bash","input":{"command":"git commit -m \"a  b\""}},{"type":"tool_use","name":"Bash","input":{"command":"deploy --dry-run --date 2026-07-29 /tmp/releases/2026-07-29/artifact https://example.com/releases/2026-07-29"}}]}}' \
  > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE16="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE16" ] && ! grep -q '<elided>' "$NOTE16"; then
    pass "HIMMEL-1345: ordinary commands pass through with no elision"
else
    fail "HIMMEL-1345: an ordinary command was unexpectedly elided"
fi
if [ -n "$NOTE16" ] && grep -qF 'git   log --oneline' "$NOTE16" && grep -qF 'git commit -m "a  b"' "$NOTE16" && grep -qF 'deploy --dry-run --date 2026-07-29 /tmp/releases/2026-07-29/artifact https://example.com/releases/2026-07-29' "$NOTE16"; then
    pass "HIMMEL-1345: ordinary commands are byte-for-byte unchanged (spacing, dates, paths, URLs, and flags survive)"
else
    fail "HIMMEL-1345: an ordinary command's text was altered"
fi
rm -rf "$SB"

# --- Case 17: single-case high-entropy tokens are NOT elided (mixed-case gate)
# Negative coverage for the mixed-case requirement inside is_opaque(): a
# token can clear length (>=20), charset ([A-Za-z0-9_./+=-]), and entropy
# (>=3.8) and STILL survive if it is single-case. Two shapes, excluded for
# different stated reasons:
#   - all-lowercase (the hex-SHA shape) — hex SHAs must stay readable.
#   - ALL-UPPERCASE / SCREAMING_SNAKE — env-var/identifier-style tokens must
#     stay readable.
# Each fixture below was verified offline against the awk is_opaque() gate
# to fail ONLY the mixed-case check (length/charset/entropy all pass) — so
# the ONLY reason either survives is the mixed-case rule; a fixture that
# failed some other gate too would prove nothing.
# This is the regression guard for the PS1 twin's `-notmatch` -> `-cnotmatch`
# fix: case-insensitive `-notmatch` never enforced mixed case at all, and no
# suite had a negative case here to catch it shipping, or to catch it
# regressing back.
#
# Built from concatenated chunks at runtime (see Case 15's TOK_GQL/TOK_KEY/
# TOK_B64 above) so no secret-shaped literal sits in tracked source. The
# SAME variables are reused in the fixture and the assertion so they cannot
# drift apart.
TOK_HEX_LOWER="f3a9c81b4e""72d0f6a1c8""9b3e5d7a02""c4f81b6e93"
TOK_SCREAM_UPPER="API_TOKEN_""9XQ2M7B4RT""6PLW3ZN8H5""JC1FYD"
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"checked hashes"},{"type":"tool_use","name":"Bash","input":{"command":"client --sha '"$TOK_HEX_LOWER"'"}},{"type":"tool_use","name":"Bash","input":{"command":"client --env '"$TOK_SCREAM_UPPER"'"}}]}}' \
  > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE17="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE17" ] && grep -qF "client --sha $TOK_HEX_LOWER" "$NOTE17"; then
    pass "HIMMEL-1345: all-lowercase high-entropy token (hex-SHA shape) is NOT elided"
else
    fail "HIMMEL-1345: all-lowercase high-entropy token was elided or altered"
fi
if [ -n "$NOTE17" ] && grep -qF "client --env $TOK_SCREAM_UPPER" "$NOTE17"; then
    pass "HIMMEL-1345: ALL-UPPERCASE/SCREAMING_SNAKE high-entropy token is NOT elided"
else
    fail "HIMMEL-1345: ALL-UPPERCASE/SCREAMING_SNAKE high-entropy token was elided or altered"
fi
rm -rf "$SB"

# --- Case 18: a STANDALONE padded base64 operand (no key= prefix) is elided --
# Regression guard for the scrub_word() key=value mis-split bug: the function
# used to find the FIRST "=" in a token and treat everything before it as a
# "key=" prefix, testing ONLY the suffix for opacity. A standalone padded
# base64 token's first "=" is its own PADDING, so the tested suffix collapsed
# to "="/"==" — too short to ever clear the length gate — and the secret
# leaked verbatim. Every pre-existing fixture (TOK_B64 above) carries a
# genuine "--blob=" prefix, which hid this. This case has NO key= prefix at
# all: the token appears bare as a positional argument.
#
# Built from concatenated chunks (twin pattern of TOK_GQL/TOK_KEY/TOK_B64
# above) so no secret-shaped literal sits in tracked source.
TOK_B64_STANDALONE="QwErTyUiOp""AsDfGhJkLz""XcVbNm2468""013579+/=="
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"pushed the blob"},{"type":"tool_use","name":"Bash","input":{"command":"client push '"$TOK_B64_STANDALONE"'"}},{"type":"tool_use","name":"Bash","input":{"command":"git config env=prod"}}]}}' \
  > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE18="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE18" ] && grep -qF 'client push <elided>' "$NOTE18" && ! grep -qF "$TOK_B64_STANDALONE" "$NOTE18"; then
    pass "HIMMEL-1345: standalone padded base64 operand (no key= prefix) is elided"
else
    fail "HIMMEL-1345: standalone padded base64 operand leaked verbatim"
fi
if [ -n "$NOTE18" ] && grep -qF 'git config env=prod' "$NOTE18"; then
    pass "HIMMEL-1345: an ordinary short key=value word is untouched"
else
    fail "HIMMEL-1345: an ordinary short key=value word was altered"
fi
rm -rf "$SB"

# --- Case 19: a MIXED-CASE opaque prefix before a non-padding "=" is elided
# whole (CodeRabbit finding, HIMMEL-1345 second round). Case 18's charset-only
# keypart gate is not enough on its own: it accepts ANY alphanumeric prefix,
# so a standalone opaque token whose "=" sits partway through on a
# non-padding boundary — e.g. "AbCdEfGhIjKlMnOpQrStUvWxYz=tail" — is misread
# as key="AbCdEfGhIjKlMnOpQrStUvWxYz" value="tail"; the short suffix again
# never clears the length gate and the whole secret leaks. The fix reuses
# is_opaque() on the keypart itself: a real key/flag/field name is always too
# short to independently clear its own length gate (even a camelCase one
# like the GraphQL "threadId" field, preserved by the existing Case 15
# fixture), so only a keypart that is itself opaque — like this mixed-case,
# high-entropy one — is rejected as a key, and the WHOLE token is tested for
# opacity instead.
#
# Built from concatenated chunks (twin pattern of TOK_GQL/TOK_KEY/TOK_B64
# above) so no secret-shaped literal sits in tracked source.
TOK_MIXED_PREFIX="AbCdEfGhIj""KlMnOpQrSt""UvWxYz"
TOK_POC="${TOK_MIXED_PREFIX}=tail"
SB="$(make_sandbox)"
printf '%s\n' \
  '{"timestamp":"2026-06-17T00:00:00Z","type":"user","message":{"role":"user","content":"go"}}' \
  '{"timestamp":"2026-06-17T00:00:05Z","type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"synced"},{"type":"tool_use","name":"Bash","input":{"command":"client sync '"$TOK_POC"'"}}]}}' \
  > "$SB/transcript.jsonl"
run_hook "$SB" >/dev/null
NOTE19="$(find "$SB/vault/sessions" -type f -name '*.md' 2>/dev/null | head -1)"
if [ -n "$NOTE19" ] && grep -qF 'client sync <elided>' "$NOTE19" && ! grep -qF '<elided>=tail' "$NOTE19" && ! grep -qF "$TOK_POC" "$NOTE19" && ! grep -qF "$TOK_MIXED_PREFIX" "$NOTE19"; then
    pass "HIMMEL-1345: mixed-case opaque prefix before a non-padding = is elided whole"
else
    fail "HIMMEL-1345: mixed-case opaque prefix before a non-padding = leaked verbatim"
fi
rm -rf "$SB"

if [ "$FAILED" -eq 0 ]; then
    echo "ALL PASS"
    exit 0
fi
echo "SOME FAILED"
exit 1
