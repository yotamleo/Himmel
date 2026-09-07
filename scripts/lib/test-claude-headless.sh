#!/usr/bin/env bash
# test-claude-headless.sh — HIMMEL-2178. Hermetic: no live `claude` call.
# Injects a fake HIMMEL_CLAUDE_BIN so the registry-row / artifact-check /
# concurrency / bank-preflight-refusal logic can be verified without
# spending bank.
# shellcheck disable=SC2012  # registry ids are UUIDs; ls-over-glob is fine here
set -uo pipefail
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
SUT="$REPO/scripts/lib/claude-headless.sh"
PASS=0; FAIL=0; SKIP=0
W="$(mktemp -d -t claude-headless-test.XXXXXX)"; trap 'rm -rf "$W"' EXIT

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
check_ne() { if [ "$2" != "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected NOT '$2'"; fi; }

# A fake bank-preflight cache that always verdicts PROCEED, hermetic (no
# network, no real usage cache). bank-preflight.sh reads primaries_refreshed_at
# freshly, so re-stamp it per-call via CADENCE_BANK_SKIP_REFRESH.
BANK_CACHE="$W/bank-cache.json"
mk_bank_cache() { printf '{"five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$(date +%s)" > "$BANK_CACHE"; }
mk_bank_cache
export CADENCE_BANK_CACHE="$BANK_CACHE"
export CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"

REGISTRY_DIR="$W/registry"
export HIMMEL_REGISTRY_DIR="$REGISTRY_DIR"
LIVE_DIR="$REGISTRY_DIR/live"

# --- fake claude binaries ---
FAKE_OK="$W/fake-claude-ok.sh"
cat > "$FAKE_OK" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "OK" > "$FAKE_ARTIFACT"
echo '{"is_error":false,"result":"done","session_id":"fake-session","permission_denials":[],"num_turns":2}'
EOF
chmod +x "$FAKE_OK"

FAKE_NOARTIFACT="$W/fake-claude-noartifact.sh"
cat > "$FAKE_NOARTIFACT" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo '{"is_error":false,"result":"done, but forgot the artifact","session_id":"fake-session-2","permission_denials":[],"num_turns":1}'
EOF
chmod +x "$FAKE_NOARTIFACT"

FAKE_DENIED="$W/fake-claude-denied.sh"
cat > "$FAKE_DENIED" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo '{"is_error":true,"result":null,"session_id":"fake-session-3","permission_denials":[{"tool_name":"Write","reason":"not allowlisted"}],"num_turns":1}'
exit 1
EOF
chmod +x "$FAKE_DENIED"

WORKTREE="$W/worktree"; mkdir -p "$WORKTREE"
PROMPT_FILE="$W/prompt.txt"; echo "write the file" > "$PROMPT_FILE"

run_sut() {
  # $1 = fake bin, $2 = artifact path, extra args follow
  local bin="$1" artifact="$2"; shift 2
  FAKE_ARTIFACT="$artifact" HIMMEL_CLAUDE_BIN="$bin" bash "$SUT" \
    --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" \
    --cwd "$WORKTREE" --artifact "$artifact" --permission-mode default \
    --prompt-file "$PROMPT_FILE" "$@"
}

# --- 1: pass path -> registry row status=completed, artifact_check=pass ---
ART1="$W/artifact1.txt"
run_sut "$FAKE_OK" "$ART1" >/dev/null 2>&1
RC1=$?
ROW1="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "artifact-present run exits 0" "0" "$RC1"
check "artifact-present row status" "completed" "$(jq -r '.status' "$ROW1" 2>/dev/null)"
check "artifact-present artifact_check.verdict" "pass" "$(jq -r '.artifact_check.verdict' "$ROW1" 2>/dev/null)"
check "artifact-present row ticket field" "HIMMEL-2178" "$(jq -r '.ticket' "$ROW1" 2>/dev/null)"
check "artifact-present row role field" "test-role" "$(jq -r '.role' "$ROW1" 2>/dev/null)"
check_ne "artifact-present row has terminal_at" "null" "$(jq -r '.terminal_at' "$ROW1" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 2: artifact never created -> status=artifact-missing, nonzero exit ---
ART2="$W/artifact2-never-written.txt"
run_sut "$FAKE_NOARTIFACT" "$ART2" >/dev/null 2>&1
RC2=$?
ROW2="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "missing-artifact run exits nonzero" "1" "$RC2"
check "missing-artifact row status" "artifact-missing" "$(jq -r '.status' "$ROW2" 2>/dev/null)"
check "missing-artifact artifact_check.verdict" "fail" "$(jq -r '.artifact_check.verdict' "$ROW2" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 3: permission_denials survive into outcome even though rc=1 (P0: rc is noise) ---
ART3="$W/artifact3-never-written.txt"
run_sut "$FAKE_DENIED" "$ART3" >/dev/null 2>&1
ROW3="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "denied run: permission_denials recorded" "not allowlisted" "$(jq -r '.outcome.permission_denials[0].reason' "$ROW3" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 3b: a stale PRE-EXISTING artifact must not trivially pass (codex-1) —
# only an artifact whose mtime advances DURING this dispatch counts.
ART3B="$W/artifact3b-preexisting.txt"
printf 'stale leftover from an earlier run\n' > "$ART3B"
touch -d '2000-01-01' "$ART3B"
run_sut "$FAKE_NOARTIFACT" "$ART3B" >/dev/null 2>&1
RC3B=$?
ROW3B="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "stale pre-existing artifact: run exits nonzero" "1" "$RC3B"
check "stale pre-existing artifact: status is artifact-missing, not completed" "artifact-missing" "$(jq -r '.status' "$ROW3B" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 4: bypassPermissions is refused before anything is written ---
ART4="$W/artifact4.txt"
FAKE_ARTIFACT="$ART4" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART4" --permission-mode bypassPermissions --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
RC4=$?
check "bypassPermissions refused (nonzero)" "1" "$RC4"
check "bypassPermissions: no registry row written" "0" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"

# --- 5: concurrency guard refuses past the cap ---
mkdir -p "$LIVE_DIR"
jq -n '{id:"a", role:"r", worktree:"w", ticket:"t", status:"dispatched"}' > "$LIVE_DIR/a.json"
jq -n '{id:"b", role:"r", worktree:"w", ticket:"t", status:"running"}' > "$LIVE_DIR/b.json"
ART5="$W/artifact5.txt"
OUT5="$(HIMMEL_DISPATCH_MAX_CONCURRENT=2 FAKE_ARTIFACT="$ART5" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART5" --permission-mode default --prompt-file "$PROMPT_FILE" 2>&1)"
RC5=$?
check "concurrency cap refused (nonzero)" "1" "$RC5"
check "concurrency cap message mentions cap" "1" "$(printf '%s' "$OUT5" | grep -c 'concurrency cap' || true)"
check "concurrency cap: no third row written" "2" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$LIVE_DIR"/*.json

# A terminal-state row (completed) must NOT count against the cap.
jq -n '{id:"c", role:"r", worktree:"w", ticket:"t", status:"completed"}' > "$LIVE_DIR/c.json"
ART6="$W/artifact6.txt"
run_sut "$FAKE_OK" "$ART6" >/dev/null 2>&1
RC6=$?
check "terminal-state row does not block dispatch" "0" "$RC6"
rm -f "$LIVE_DIR"/*.json

# --- 6: bank preflight refusal blocks dispatch, no registry row written ---
printf '{"five_hour":{"utilization":95},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$(date +%s)" > "$BANK_CACHE"
ART7="$W/artifact7.txt"
FAKE_ARTIFACT="$ART7" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART7" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
RC7=$?
check "bank-preflight refusal blocks dispatch (nonzero)" "1" "$RC7"
check "bank-preflight refusal: no registry row written" "0" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
check "bank-preflight refusal: no fake claude invocation happened" "" "$([ -f "$ART7" ] && echo written)"
mk_bank_cache

# --- 7: --max-turns validation ---
ART8="$W/artifact8.txt"
FAKE_ARTIFACT="$ART8" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART8" --permission-mode default --prompt-file "$PROMPT_FILE" --max-turns 1 >/dev/null 2>&1
RC8=$?
check "max-turns 1 rejected" "1" "$RC8"

# --- 8: a malformed HIMMEL_DISPATCH_MAX_CONCURRENT falls back to the
# default cap (3) rather than fail-opening it (codex-3). 3 pre-existing
# "dispatched" rows must still refuse a 4th dispatch.
jq -n '{id:"d1", status:"dispatched"}' > "$LIVE_DIR/d1.json"
jq -n '{id:"d2", status:"dispatched"}' > "$LIVE_DIR/d2.json"
jq -n '{id:"d3", status:"dispatched"}' > "$LIVE_DIR/d3.json"
ART9="$W/artifact9.txt"
HIMMEL_DISPATCH_MAX_CONCURRENT=notanumber FAKE_ARTIFACT="$ART9" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART9" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
RC9=$?
check "malformed cap falls back to default, does not fail open" "1" "$RC9"
check "malformed cap: no 4th row written" "3" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
rm -f "$LIVE_DIR"/*.json

# --- 9: a stale admission lock (owner pid dead) is reclaimed, not a
# permanent deadlock (codex-4).
mkdir -p "$LIVE_DIR/.admission.lock"
printf '999999999' > "$LIVE_DIR/.admission.lock/pid"
ART10="$W/artifact10.txt"
run_sut "$FAKE_OK" "$ART10" >/dev/null 2>&1
RC10=$?
check "stale admission lock is reclaimed (dispatch succeeds)" "0" "$RC10"
rm -f "$LIVE_DIR"/*.json
rm -rf "$LIVE_DIR/.admission.lock" 2>/dev/null || true

# --- 10: stdin-mode (no --prompt-file) must still deliver the prompt to
# the backgrounded invocation, not /dev/null (codex-1 round 3). The fake
# bin only writes the artifact if it actually received non-empty stdin.
FAKE_STDIN_CHECK="$W/fake-claude-stdin-check.sh"
cat > "$FAKE_STDIN_CHECK" <<'EOF'
#!/usr/bin/env bash
input="$(cat)"
if [ -n "$input" ]; then
  echo "OK" > "$FAKE_ARTIFACT"
  echo '{"is_error":false,"result":"done","session_id":"fake-stdin","permission_denials":[],"num_turns":2}'
else
  echo '{"is_error":false,"result":"empty prompt, did nothing","session_id":"fake-stdin-empty","permission_denials":[],"num_turns":1}'
fi
EOF
chmod +x "$FAKE_STDIN_CHECK"
ART11="$W/artifact11.txt"
printf 'write it\n' | FAKE_ARTIFACT="$ART11" HIMMEL_CLAUDE_BIN="$FAKE_STDIN_CHECK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART11" --permission-mode default >/dev/null 2>&1
RC11=$?
check "stdin-mode prompt reaches the backgrounded invocation" "0" "$RC11"
rm -f "$LIVE_DIR"/*.json

# --- 11: a directory artifact's freshness must reflect FILES inside it, not
# the directory's own mtime — rewriting an existing file's content does not
# advance the parent directory's mtime on most filesystems (codex-2 round 3).
ARTDIR="$W/artifact-dir"
mkdir -p "$ARTDIR"
printf 'old content\n' > "$ARTDIR/existing-file.txt"
touch -d '2000-01-01' "$ARTDIR/existing-file.txt" "$ARTDIR"
FAKE_DIR_UPDATE="$W/fake-claude-dir-update.sh"
cat > "$FAKE_DIR_UPDATE" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf 'updated content\n' > "$FAKE_ARTIFACT/existing-file.txt"
echo '{"is_error":false,"result":"done","session_id":"fake-dir","permission_denials":[],"num_turns":2}'
EOF
chmod +x "$FAKE_DIR_UPDATE"
FAKE_ARTIFACT="$ARTDIR" HIMMEL_CLAUDE_BIN="$FAKE_DIR_UPDATE" bash "$SUT" \
  --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ARTDIR" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
RC12=$?
ROW12="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "directory artifact: content-only update inside pre-existing dir exits 0" "0" "$RC12"
check "directory artifact: status completed" "completed" "$(jq -r '.status' "$ROW12" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 12: a pre-existing directory containing ONLY subdirectories (no files
# anywhere in its tree) must not trivially pass when untouched — an empty
# `find -type f` scan used to read as "no baseline" and skip the freshness
# check entirely (codex-1 round 4).
ARTDIR2="$W/artifact-dir-onlysubdirs"
mkdir -p "$ARTDIR2/subdir"
touch -d '2000-01-01' "$ARTDIR2/subdir" "$ARTDIR2"
run_sut "$FAKE_NOARTIFACT" "$ARTDIR2" >/dev/null 2>&1
RC13=$?
ROW13="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "only-subdirs dir, untouched: run exits nonzero" "1" "$RC13"
check "only-subdirs dir, untouched: status is artifact-missing" "artifact-missing" "$(jq -r '.status' "$ROW13" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 13: an admission lock with no readable pid file at all (the write
# itself failed, or the holder crashed before writing it) must also be
# reclaimed, not permanently block admission (codex-3 round 4).
mkdir -p "$LIVE_DIR/.admission.lock"
ART14="$W/artifact14.txt"
run_sut "$FAKE_OK" "$ART14" >/dev/null 2>&1
RC14=$?
check "admission lock with no pid file is reclaimed (dispatch succeeds)" "0" "$RC14"
rm -f "$LIVE_DIR"/*.json
rm -rf "$LIVE_DIR/.admission.lock" 2>/dev/null || true

# --- 14: --settings must reach the claude invocation in Windows-form, not
# the bare POSIX path a caller naturally builds from $W (RETASK gV2t9-4478 /
# same MSYS_NO_PATHCONV=1-affects-every-argv-element class as the --settings
# fix above). A fake bin that dumps its own argv lets us assert on what the
# wrapper actually handed it, independent of whether the fake bin itself
# (an MSYS shell script) would have been affected by real path mangling.
if command -v cygpath >/dev/null 2>&1; then
  FAKE_ARGV_DUMP="$W/fake-claude-argv-dump.sh"
  cat > "$FAKE_ARGV_DUMP" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$@" > "$FAKE_ARGV_OUT"
echo "OK" > "$FAKE_ARTIFACT"
echo '{"is_error":false,"result":"done","session_id":"fake-argv","permission_denials":[],"num_turns":2}'
EOF
  chmod +x "$FAKE_ARGV_DUMP"
  SETTINGS_FILE="$W/settings15.json"
  echo '{}' > "$SETTINGS_FILE"
  ART15="$W/artifact15.txt"
  ARGV_OUT="$W/argv-dump15.txt"
  FAKE_ARGV_OUT="$ARGV_OUT" FAKE_ARTIFACT="$ART15" HIMMEL_CLAUDE_BIN="$FAKE_ARGV_DUMP" bash "$SUT" \
    --role test-role --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
    --artifact "$ART15" --permission-mode default --prompt-file "$PROMPT_FILE" \
    --settings "$SETTINGS_FILE" >/dev/null 2>&1
  RC15=$?
  RECEIVED_SETTINGS="$(grep -A1 '^--settings$' "$ARGV_OUT" 2>/dev/null | tail -1)"
  FORM="posix"
  case "$RECEIVED_SETTINGS" in /*) : ;; *) FORM="converted" ;; esac
  check "settings path conversion: run succeeds" "0" "$RC15"
  check "settings path conversion: received --settings is not a bare POSIX path" "converted" "$FORM"
  rm -f "$LIVE_DIR"/*.json
else
  echo "SKIP - settings path conversion: SKIPPED (no cygpath on this host)"
  SKIP=$((SKIP+1))
fi

echo "--- $PASS passed, $FAIL failed, $SKIP skipped ---"
[ "$FAIL" -eq 0 ]
