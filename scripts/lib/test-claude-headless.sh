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
# A bank read can prune dead reservations; never inspect the real slot root.
export HIMMEL_FLEET_SLOTS="$W/fleet-slots" HIMMEL_FLEET_CAP=4 CADENCE_BANK_LANE=native

# HIMMEL-1712: bank-preflight now distrusts a cache whose account doesn't
# match the current identity — synthesize one so mk_bank_cache's fixture
# still verdicts PROCEED.
export HOME="$W/home"; mkdir -p "$HOME"
printf '%s' '{"oauthAccount":{"accountUuid":"uuid-claude-headless-test"}}' > "$HOME/.claude.json"
# shellcheck source=usage-cache-identity.sh
# shellcheck disable=SC1091
. "$REPO/scripts/lib/usage-cache-identity.sh"
ACCT="$(current_account_hash)"

check() { if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected '$2' got '$3'"; fi; }
check_ne() { if [ "$2" != "$3" ]; then PASS=$((PASS+1)); echo "ok - $1";
  else FAIL=$((FAIL+1)); echo "FAIL - $1: expected NOT '$2'"; fi; }

# A fake bank-preflight cache that always verdicts PROCEED, hermetic (no
# network, no real usage cache). bank-preflight.sh reads primaries_refreshed_at
# freshly, so re-stamp it per-call via CADENCE_BANK_SKIP_REFRESH.
BANK_CACHE="$W/bank-cache.json"
mk_bank_cache() { printf '{"account":"%s","five_hour":{"utilization":10},"seven_day":{"utilization":20},"primaries_refreshed_at":%s}\n' "$ACCT" "$(date +%s)" > "$BANK_CACHE"; }
mk_bank_cache
export CADENCE_BANK_CACHE="$BANK_CACHE"
export CADENCE_BANK_SKIP_REFRESH=1
export CADENCE_BANK_LEDGER="$W/bank-ledger.jsonl"
# HIMMEL-2765: bank-preflight.sh now also counts live LEG sessions via a real
# `ps -eo args` by default - without this, every "happy path" case below
# would call the REAL fleet count against THIS machine's own ambient process
# table and could spuriously refuse (bank preflight refused dispatch:
# SKIPPED-FLEET) on a host that genuinely has >= HIMMEL_FLEET_CAP `-n
# HIMMEL-*` sessions running, unrelated to what these cases actually test.
FLEET_PS_STUB="$W/no-fleet-ps.sh"
printf '%s\n' '#!/usr/bin/env bash' 'true' > "$FLEET_PS_STUB"
chmod +x "$FLEET_PS_STUB"
export FLEET_PS_CMD="$FLEET_PS_STUB"

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
    --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" \
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
touch -t 200001010000 "$ART3B"
run_sut "$FAKE_NOARTIFACT" "$ART3B" >/dev/null 2>&1
RC3B=$?
ROW3B="$(ls "$LIVE_DIR"/*.json 2>/dev/null | head -1)"
check "stale pre-existing artifact: run exits nonzero" "1" "$RC3B"
check "stale pre-existing artifact: status is artifact-missing, not completed" "artifact-missing" "$(jq -r '.status' "$ROW3B" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 4: bypassPermissions is refused before anything is written ---
ART4="$W/artifact4.txt"
FAKE_ARTIFACT="$ART4" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART7" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
RC7=$?
check "bank-preflight refusal blocks dispatch (nonzero)" "1" "$RC7"
check "bank-preflight refusal: no registry row written" "0" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"
check "bank-preflight refusal: no fake claude invocation happened" "" "$([ -f "$ART7" ] && echo written)"
mk_bank_cache

# --- 7: --max-turns validation ---
ART8="$W/artifact8.txt"
FAKE_ARTIFACT="$ART8" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
touch -t 200001010000 "$ARTDIR/existing-file.txt" "$ARTDIR"
FAKE_DIR_UPDATE="$W/fake-claude-dir-update.sh"
cat > "$FAKE_DIR_UPDATE" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf 'updated content\n' > "$FAKE_ARTIFACT/existing-file.txt"
echo '{"is_error":false,"result":"done","session_id":"fake-dir","permission_denials":[],"num_turns":2}'
EOF
chmod +x "$FAKE_DIR_UPDATE"
FAKE_ARTIFACT="$ARTDIR" HIMMEL_CLAUDE_BIN="$FAKE_DIR_UPDATE" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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
touch -t 200001010000 "$ARTDIR2/subdir" "$ARTDIR2"
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

# --- 13b (HIMMEL-2196): two reclaimers that both saw the SAME stale lock must
# not both enter admission. Sequenced with the HIMMEL_HEADLESS_SEAM_DIR seam,
# not timers: both park after their stale verdict; A is released, reclaims and
# parks holding the fresh lock; B is then released with a verdict that is now
# out of date. B must not delete A's live lock, so only ONE admits.
SEAM="$W/seam13b"; mkdir -p "$SEAM"
mkdir -p "$LIVE_DIR/.admission.lock"
printf '999999999' > "$LIVE_DIR/.admission.lock/pid"
ART13B_A="$W/artifact13b-a.txt"; ART13B_B="$W/artifact13b-b.txt"
HIMMEL_HEADLESS_SEAM_DIR="$SEAM" run_sut "$FAKE_OK" "$ART13B_A" >/dev/null 2>&1 &
PID13B_A=$!
HIMMEL_HEADLESS_SEAM_DIR="$SEAM" run_sut "$FAKE_OK" "$ART13B_B" >/dev/null 2>&1 &
PID13B_B=$!
seam_wait() { # $1 = glob, $2 = count wanted, $3 = max tenths of a second
  local n=0
  # shellcheck disable=SC2086  # $1 is a glob, expanded on purpose
  while [ "$(ls $1 2>/dev/null | wc -l | tr -d ' ')" -lt "$2" ] && [ "$n" -lt "$3" ]; do
    n=$((n + 1)); sleep 0.1
  done
}
seam_wait "$SEAM/stale-verdict.*.arrived" 2 150
SV13B="$(ls "$SEAM"/stale-verdict.*.arrived 2>/dev/null | sed -e 's/.*stale-verdict\.//' -e 's/\.arrived$//' | sort -n)"
SV_A="$(printf '%s\n' "$SV13B" | sed -n 1p)"
SV_B="$(printf '%s\n' "$SV13B" | sed -n 2p)"
check "two reclaimers both reached their stale verdict" "2" "$(printf '%s\n' "$SV13B" | grep -c .)"
# 13b is about the stale verdict only; let both pass the reclaim-prerm seam
for P in $SV_A $SV_B; do : > "$SEAM/reclaim-prerm.$P.go"; done
: > "$SEAM/stale-verdict.$SV_A.go"
seam_wait "$SEAM/admitted.*.arrived" 1 100
: > "$SEAM/stale-verdict.$SV_B.go"
seam_wait "$SEAM/admitted.*.arrived" 2 30
check "only one of two stale-lock reclaimers enters admission" "1" "$(ls "$SEAM"/admitted.*.arrived 2>/dev/null | wc -l | tr -d ' ')"
for P in $SV_A $SV_B; do : > "$SEAM/admitted.$P.go"; done
wait "$PID13B_A" "$PID13B_B" 2>/dev/null
check "no reclaim-intent lock is left behind" "no" "$([ -e "$LIVE_DIR/.admission.lock.reclaim" ] && echo yes || echo no)"
rm -f "$LIVE_DIR"/*.json
rm -rf "$LIVE_DIR/.admission.lock" "$LIVE_DIR/.admission.lock.reclaim" 2>/dev/null || true

# --- 13c (HIMMEL-2196, judge j2259a C4): with flock(1) the reclaim-intent lock
# is a kernel lock, so a second reclaimer can never displace the first while it
# is between its staleness check and its delete. A parks holding the lock just
# before its delete; B is released then and must NOT get in (before the fix a
# steal could move a live marker, B took the slot and was admitted: 2 admitted).
if command -v flock >/dev/null 2>&1; then
SEAM="$W/seam13c"; mkdir -p "$SEAM"
mkdir -p "$LIVE_DIR/.admission.lock"
printf '999999999' > "$LIVE_DIR/.admission.lock/pid"
HIMMEL_HEADLESS_SEAM_DIR="$SEAM" run_sut "$FAKE_OK" "$W/artifact13c-a.txt" >/dev/null 2>&1 &
PID13C_A=$!
HIMMEL_HEADLESS_SEAM_DIR="$SEAM" run_sut "$FAKE_OK" "$W/artifact13c-b.txt" >/dev/null 2>&1 &
PID13C_B=$!
seam_wait "$SEAM/stale-verdict.*.arrived" 2 150
SV13C="$(ls "$SEAM"/stale-verdict.*.arrived 2>/dev/null | sed -e 's/.*stale-verdict\.//' -e 's/\.arrived$//' | sort -n)"
SVC_A="$(printf '%s\n' "$SV13C" | sed -n 1p)"
SVC_B="$(printf '%s\n' "$SV13C" | sed -n 2p)"
: > "$SEAM/stale-verdict.$SVC_A.go"
seam_wait "$SEAM/reclaim-prerm.*.arrived" 1 50
check "first reclaimer parks holding the reclaim lock before its delete" "1" "$(ls "$SEAM"/reclaim-prerm.*.arrived 2>/dev/null | wc -l | tr -d ' ')"
: > "$SEAM/stale-verdict.$SVC_B.go"
sleep 1
check "second reclaimer is not admitted while the first holds the lock" "0" "$(ls "$SEAM"/admitted.*.arrived 2>/dev/null | wc -l | tr -d ' ')"
: > "$SEAM/reclaim-prerm.$SVC_A.go"
seam_wait "$SEAM/admitted.*.arrived" 1 100
check "after the first finishes exactly one is admitted" "1" "$(ls "$SEAM"/admitted.*.arrived 2>/dev/null | wc -l | tr -d ' ')"
for P in $SVC_A $SVC_B; do : > "$SEAM/admitted.$P.go"; : > "$SEAM/reclaim-prerm.$P.go"; done
wait "$PID13C_A" "$PID13C_B" 2>/dev/null
rm -f "$LIVE_DIR"/*.json
rm -rf "$LIVE_DIR/.admission.lock" "$LIVE_DIR/.admission.lock.reclaim" "$LIVE_DIR/.admission.lock.flock" 2>/dev/null || true
else
  SKIP=$((SKIP+1)); echo "skip - 13c: flock(1) not available"
fi

# --- 13d/13e (HIMMEL-2196, judge j2259a C3): the dir-fallback reclaim marker
# must not outlive an INT/TERM that lands while it is held (the exit trap used
# to release only the admission lock, leaving a marker with a dead pid).
for SIG13 in TERM INT; do
  SEAM="$W/seam13-$SIG13"; mkdir -p "$SEAM"
  mkdir -p "$LIVE_DIR/.admission.lock"
  printf '999999999' > "$LIVE_DIR/.admission.lock/pid"
  set -m
  HIMMEL_HEADLESS_NO_FLOCK=1 HIMMEL_HEADLESS_SEAM_DIR="$SEAM" run_sut "$FAKE_OK" "$W/artifact13-$SIG13.txt" >/dev/null 2>&1 &
  PID13S=$!
  set +m
  seam_wait "$SEAM/stale-verdict.*.arrived" 1 150
  # the seam files carry the script's own pid ($! is the wrapper subshell's)
  SPID="$(ls "$SEAM"/stale-verdict.*.arrived 2>/dev/null | sed -e 's/.*stale-verdict\.//' -e 's/\.arrived$//' | head -1)"
  : > "$SEAM/stale-verdict.$SPID.go"
  seam_wait "$SEAM/reclaim-prerm.*.arrived" 1 150
  check "$SIG13: reclaimer holds the reclaim marker" "yes" "$([ -d "$LIVE_DIR/.admission.lock.reclaim" ] && echo yes || echo no)"
  kill -"$SIG13" "$SPID" 2>/dev/null
  wait "$PID13S" 2>/dev/null
  check "$SIG13: no reclaim marker is left behind" "no" "$([ -e "$LIVE_DIR/.admission.lock.reclaim" ] && echo yes || echo no)"
  rm -f "$LIVE_DIR"/*.json
  rm -rf "$LIVE_DIR/.admission.lock" "$LIVE_DIR/.admission.lock.reclaim" 2>/dev/null || true
done

# --- 14:--settings must reach the claude invocation in Windows-form, not
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
    --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" --cwd "$WORKTREE" \
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

# --- 16 (HIMMEL-3107): --system-prompt-file / --tools / --isolated reach the
# claude argv (the context-free CR floor reviewer depends on all three), and
# are ABSENT when not asked for.
FAKE_ARGV16="$W/fake-claude-argv16.sh"
cat > "$FAKE_ARGV16" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$@" > "$FAKE_ARGV_OUT"
echo "OK" > "$FAKE_ARTIFACT"
echo '{"is_error":false,"result":"done","session_id":"fake-argv16","permission_denials":[],"num_turns":2}'
EOF
chmod +x "$FAKE_ARGV16"
SYS16="$W/system16.md"; echo "you are a reviewer" > "$SYS16"
FAKE_ARGV_OUT="$W/argv16.txt" FAKE_ARTIFACT="$W/artifact16.txt" HIMMEL_CLAUDE_BIN="$FAKE_ARGV16" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-3107 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$W/artifact16.txt" --permission-mode acceptEdits --prompt-file "$PROMPT_FILE" \
  --system-prompt-file "$SYS16" --tools "Read,Grep" --isolated >/dev/null 2>&1
check "16 isolated run succeeds" "0" "$?"
check "16 --system-prompt-file passed" "1" "$(grep -c -x -- '--system-prompt-file' "$W/argv16.txt")"
check "16 --tools value passed" "Read,Grep" "$(grep -A1 -x -- '--tools' "$W/argv16.txt" | tail -1)"
check "16 --isolated -> --safe-mode --strict-mcp-config --no-session-persistence" "3" \
  "$(grep -c -x -E -- '--safe-mode|--strict-mcp-config|--no-session-persistence' "$W/argv16.txt")"
FAKE_ARGV_OUT="$W/argv16b.txt" FAKE_ARTIFACT="$W/artifact16b.txt" HIMMEL_CLAUDE_BIN="$FAKE_ARGV16" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-3107 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$W/artifact16b.txt" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
check "16 without the flags none of them is passed" "0" \
  "$(grep -c -x -E -- '--system-prompt-file|--tools|--safe-mode|--strict-mcp-config|--no-session-persistence' "$W/argv16b.txt")"
FAKE_ARGV_OUT="$W/argv16c.txt" FAKE_ARTIFACT="$W/artifact16c.txt" HIMMEL_CLAUDE_BIN="$FAKE_ARGV16" bash "$SUT" \
  --role test-role --model test-model --ticket HIMMEL-3107 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$W/artifact16c.txt" --permission-mode default --prompt-file "$PROMPT_FILE" \
  --system-prompt-file "$W/no-such-file.md" >/dev/null 2>&1
check_ne "16 unreadable --system-prompt-file refuses" "0" "$?"
rm -f "$LIVE_DIR"/*.json

# --- 17 (HIMMEL-4082): the HIMMEL_CLAUDE_LANE seam picks the launcher when
# HIMMEL_CLAUDE_BIN is unset. Mini tree: lib/ copied (REPO_ROOT = mini), the rest
# of scripts/ symlinked, the lane launchers replaced by argv-capturing stubs.
MINI="$W/mini"; mkdir -p "$MINI/scripts"
for e in "$REPO"/scripts/*; do
  n="$(basename "$e")"
  case "$n" in lib|claude-openrouter|claude-codex) ;; *) ln -s "$e" "$MINI/scripts/$n" ;; esac
done
cp -R "$REPO/scripts/lib" "$MINI/scripts/lib"
for l in claude-openrouter claude-codex; do
  {
    echo '#!/usr/bin/env bash'
    echo "echo $l > \"\$LANE_SEEN\""
    # shellcheck disable=SC2016  # stub body is written literally
    printf '%s\n' 'printf "%s\n" "$@" > "$FAKE_ARGV_OUT"'
    # shellcheck disable=SC2016  # stub body is written literally
    printf '%s\n' 'cat > /dev/null; echo OK > "$FAKE_ARTIFACT"'
    echo "echo '{\"is_error\":false,\"result\":\"done\",\"session_id\":\"s\",\"permission_denials\":[],\"num_turns\":1}'"
  } > "$MINI/scripts/$l"
  chmod +x "$MINI/scripts/$l"
done
# A native fallback must never reach a real binary: a fake `claude` first on PATH
# records itself and fails, so a regression is loud and the test asserts it never ran.
mkdir -p "$W/fakebin"
# shellcheck disable=SC2016  # stub body is written literally
printf '%s\n' '#!/usr/bin/env bash' 'echo invoked > "$NATIVE_SEEN"' 'exit 97' > "$W/fakebin/claude"
chmod +x "$W/fakebin/claude"
lane_run() { # <lane> <tag> -> rc; no HIMMEL_CLAUDE_BIN
  rm -f "$W/lane-seen-$2" "$W/native-seen"
  PATH="$W/fakebin:$PATH" NATIVE_SEEN="$W/native-seen" HIMMEL_CLAUDE_LANE="$1" LANE_SEEN="$W/lane-seen-$2" FAKE_ARGV_OUT="$W/lane-argv-$2" FAKE_ARTIFACT="$W/lane-art-$2" \
    bash "$MINI/scripts/lib/claude-headless.sh" --role test-role --model test-model --ticket HIMMEL-4082 --worktree "$WORKTREE" \
    --cwd "$WORKTREE" --artifact "$W/lane-art-$2" --permission-mode default --prompt-file "$PROMPT_FILE" >/dev/null 2>&1
}
lane_run openrouter or; check "17 openrouter lane exits 0" "0" "$?"
check "17 openrouter lane used its launcher" "claude-openrouter" "$(cat "$W/lane-seen-or" 2>/dev/null)"
lane_run claudex cx; check "17 claudex lane exits 0" "0" "$?"
check "17 claudex lane used its launcher" "claude-codex" "$(cat "$W/lane-seen-cx" 2>/dev/null)"
check "17 lane argv keeps the explicit permission mode" "default" \
  "$(awk 'p{print; exit} /^--permission-mode$/{p=1}' "$W/lane-argv-or")"
check "17 lane argv keeps -p and json output" "2" \
  "$(grep -c -x -E -- '-p|json' "$W/lane-argv-or")"
lane_run bogus bg; check_ne "17 unknown lane refuses" "0" "$?"
check "17 unknown lane launched nothing" "" "$(cat "$W/lane-seen-bg" 2>/dev/null)"
check "17 unknown lane never fell back to native claude" "" "$(cat "$W/native-seen" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# --- 18: HIMMEL-4459 the launch gate holds when the pin's own builtins are shadowed.
# A shadowed `unset`+`return` lets native_auth_pin_env fall through rc 0 with the
# proxy variables still set; the caller's keyword-only gate must refuse anyway.
# FAKE_OK writes its artifact only when launched, so "artifact absent" = REFUSED.
SH18="$W/shadow18"; mkdir -p "$SH18"
# The shadows come from the shell-startup file and are installed ONLY in
# claude-headless.sh itself ($0 test): bank-preflight.sh and the other children
# must stay intact, or the launch is refused for the wrong reason and the rows
# go vacuous. They arm from a DEBUG trap at the first command AFTER the
# HIMMEL-3914 seam guard (SCRIPT_DIR=...): a `return` shadow installed earlier
# breaks the guard itself, which then refuses (exit 96) before the gate is
# reached. SHADOW_MARK proves the trap fired.
# shellcheck disable=SC2016  # the startup file body is written literally
printf '%s\n' '[[ $0 = *claude-headless.sh ]] || return 0' > "$SH18/gate.sh"
arm18() { printf '%s\n' "trap '[[ \$BASH_COMMAND == SCRIPT_DIR=* ]] && { trap - DEBUG; $1; : > \"\${SHADOW_MARK:-/dev/null}\"; }' DEBUG"; }
{ cat "$SH18/gate.sh"; arm18 'unset(){ :; }; return(){ :; }'; } > "$SH18/funcs.sh"
{ cat "$SH18/gate.sh"; printf '%s\n' 'shopt -s expand_aliases'; arm18 'alias unset=: return=:'; } > "$SH18/alias.sh"
{ cat "$SH18/gate.sh"; printf '%s\n' 'readonly ANTHROPIC_BASE_URL'; arm18 'return(){ :; }'; } > "$SH18/ro.sh"
# shellcheck disable=SC2030  # exports are per-launch, scoped to the subshell on purpose
shadow_launch() { # <tag> <startup file or ''> -> prints launched|refused
  local art="$W/art18-$1"; rm -f "$art"
  ( [ "${3:-}" = noproxy ] || export ANTHROPIC_BASE_URL=https://evil.example ANTHROPIC_API_KEY=x
    [ -n "$2" ] && export BASH_ENV="$2" SHADOW_MARK="$W/mark18-$1"
    run_sut "$FAKE_OK" "$art" >/dev/null 2>&1 )
  [ -f "$art" ] && echo launched || echo refused
}
check "18 startup-file unset+return function shadows: launch refused" "refused" "$(shadow_launch env "$SH18/funcs.sh")"
check "18 startup-file unset+return alias shadows: launch refused" "refused" "$(shadow_launch ali "$SH18/alias.sh")"
check "18 readonly base URL + return shadow: launch refused" "refused" "$(shadow_launch ro "$SH18/ro.sh")"
check "18 shadows armed past the seam guard (env ali ro)" "yes yes yes" \
  "$(for t in env ali ro; do [ -f "$W/mark18-$t" ] && printf yes || printf no; [ $t = ro ] || printf ' '; done)"
check "18 control: no shadow, proxy vars stripped, launch happens" "launched" "$(shadow_launch ctl '')"
# Proxy-free controls WITH the shadows installed: the refusals above must come
# from the gate, not from the shadows breaking the launch path.
check "18 control: function shadows installed, no proxy: launch happens" "launched" "$(shadow_launch cf "$SH18/funcs.sh" noproxy)"
check "18 control: alias shadows installed, no proxy: launch happens" "launched" "$(shadow_launch ca "$SH18/alias.sh" noproxy)"
rm -f "$LIVE_DIR"/*.json

# --- 19: HIMMEL-4461 the loopback-mock seam gate keeps EXACT names only. With
# `unset`+`return` shadowed, a name built from the two kept ones
# (ANTHROPIC_BASE_URLANTHROPIC_API_KEY) must not vanish from the gate the way a
# substring strip lets it. Needs a loopback-only netns (unshare -rn).
# shellcheck disable=SC2030,SC2031  # per-launch subshell exports, as in shadow_launch
seam_launch() { # <tag> [extra variable name] [startup file] -> prints launched|refused
  local art="$W/art19-$1"; rm -f "$art"
  ( export NATIVE_AUTH_PIN_KEEP_LOOPBACK_MOCK=1 ANTHROPIC_BASE_URL=http://127.0.0.1:9 ANTHROPIC_API_KEY=k
    export BASH_ENV="${3:-$SH18/funcs.sh}" SHADOW_MARK="$W/mark19-$1"
    [ -n "${2:-}" ] && export "$2=x"
    FAKE_ARTIFACT="$art" HIMMEL_CLAUDE_BIN="$FAKE_OK" unshare -rn bash "$SUT" \
      --role test-role --model test-model --ticket HIMMEL-2178 --worktree "$WORKTREE" \
      --cwd "$WORKTREE" --artifact "$art" --permission-mode default \
      --prompt-file "$PROMPT_FILE" ) >/dev/null 2>"$W/err19-$1"
  [ -f "$art" ] && echo launched || echo refused
}
# A readonly gate loop variable (set before the gate, here by the startup file)
# makes `for _v` fail without discarding the line; the gate must refuse, not
# launch on an empty survivor list.
{ cat "$SH18/gate.sh"; arm18 'unset(){ :; }; return(){ :; }; readonly _v='; } > "$SH18/ro19.sh"
if ! unshare -rn true 2>/dev/null; then
  SKIP=$((SKIP+1)); echo "skip - 19 (no unshare -rn)"
else
  r19=$(seam_launch ctl)
  if grep -q "cannot read the claude session's cwd" "$W/err19-ctl"; then
    # Same limit as test-claude-mock-turn.sh case H: from inside a Claude Code
    # session, bank-preflight's seam guard (HIMMEL-3914) cannot read the
    # session's cwd across the user namespace. CI has no claude ancestor.
    SKIP=$((SKIP+1)); echo "skip - 19 run from inside a Claude Code session (seam guard refuses across the netns)"
  else
    check "19 control: seam keeps exactly base URL + key, launch happens" "launched" "$r19"
    check "19 concatenated kept names under the seam: launch refused" "refused" "$(seam_launch cat ANTHROPIC_BASE_URLANTHROPIC_API_KEY)"
    check "19 readonly loop variable under the seam: launch refused" "refused" "$(seam_launch rov ANTHROPIC_MODEL "$SH18/ro19.sh")"
    check "19 shadows armed past the seam guard (ctl cat rov)" "yes yes yes" \
      "$([ -f "$W/mark19-ctl" ] && printf yes || printf no) $([ -f "$W/mark19-cat" ] && printf yes || printf no) $([ -f "$W/mark19-rov" ] && printf yes || printf no)"
  fi
fi
rm -f "$LIVE_DIR"/*.json

# --- 20 (HIMMEL-2198): --model is required at the chokepoint; a dispatch that
# omits it would burn the scarcer default quota. Refused before any row exists.
ART20="$W/artifact20.txt"
OUT20="$(FAKE_ARTIFACT="$ART20" HIMMEL_CLAUDE_BIN="$FAKE_OK" bash "$SUT" \
  --role test-role --ticket HIMMEL-2198 --worktree "$WORKTREE" --cwd "$WORKTREE" \
  --artifact "$ART20" --permission-mode default --prompt-file "$PROMPT_FILE" 2>&1)"
RC20=$?
check "20 missing --model refused (nonzero)" "1" "$RC20"
check "20 missing --model: usage error names the flag" "1" "$(printf '%s' "$OUT20" | grep -c -- '--model is required' || true)"
check "20 missing --model: no registry row written" "0" "$(ls "$LIVE_DIR"/*.json 2>/dev/null | wc -l | tr -d ' ')"

# --- 21-23 (HIMMEL-2197): a dispatched row whose wrapper died without
# finalize_on_exit (SIGKILL, host death) must stop counting against the cap.
# The row records the wrapper pid and its start time; the next admission reaps a
# row whose pid is gone, or alive with a different start time (pid reuse).
proc_start() { TZ=UTC LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null | tr -s ' ' | sed 's/^ //; s/ $//'; }
cap1_run() { HIMMEL_DISPATCH_MAX_CONCURRENT=1 run_sut "$FAKE_OK" "$1" >/dev/null 2>&1; }
( : ) & DEAD_PID=$!; wait "$DEAD_PID" 2>/dev/null
jq -n --arg p "$DEAD_PID" '{id:"dead", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:"Thu Jan 1 00:00:00 1970"}' > "$LIVE_DIR/dead.json"
cap1_run "$W/artifact21.txt"; RC21=$?
check "21 SIGKILLed holder reaped: next admission succeeds at cap 1" "0" "$RC21"
check "21 reaped row is marked interrupted" "interrupted" "$(jq -r '.status' "$LIVE_DIR/dead.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

sleep 60 & LIVE_PID=$!
jq -n --arg p "$LIVE_PID" --arg s "$(proc_start "$LIVE_PID")" '{id:"live", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:$s}' > "$LIVE_DIR/live.json"
cap1_run "$W/artifact22.txt"; RC22=$?
check "22 live holder is never reaped: cap still refuses" "1" "$RC22"
check "22 live holder row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/live.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

jq -n --arg p "$LIVE_PID" '{id:"reuse", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:"Thu Jan 1 00:00:00 1970"}' > "$LIVE_DIR/reuse.json"
cap1_run "$W/artifact23.txt"; RC23=$?
check "23 pid reused with a different start time is reaped" "0" "$RC23"
check "23 reused-pid row is marked interrupted" "interrupted" "$(jq -r '.status' "$LIVE_DIR/reuse.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# 24: the wrapper is dead but the claude worker it launched survived (SIGKILL of
# the wrapper alone). The slot stays held while the worker lives; once it is gone
# too, the row is reaped.
jq -n --arg d "$DEAD_PID" --arg w "$LIVE_PID" --arg s "$(proc_start "$LIVE_PID")" '{id:"orphan", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($d|tonumber), pid_start:"Thu Jan 1 00:00:00 1970", worker_pid:($w|tonumber), worker_start:$s}' > "$LIVE_DIR/orphan.json"
cap1_run "$W/artifact24.txt"; RC24=$?
check "24 dead wrapper, live worker: slot still held (cap refuses)" "1" "$RC24"
check "24 dead wrapper, live worker: row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/orphan.json" 2>/dev/null)"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
cap1_run "$W/artifact24b.txt"; RC24B=$?
check "24 wrapper and worker both gone: reaped, admission succeeds" "0" "$RC24B"
check "24 both-gone row is marked interrupted" "interrupted" "$(jq -r '.status' "$LIVE_DIR/orphan.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# 25: a real dispatch records the launched worker's pid on its row.
run_sut "$FAKE_OK" "$W/artifact25.txt" >/dev/null 2>&1
check "25 dispatch row records the worker pid" "number" "$(jq -r '.worker_pid | type' "$LIVE_DIR"/*.json 2>/dev/null | head -n1)"
rm -f "$LIVE_DIR"/*.json

# 26: wrapper dead, row marked launching but no worker pid persisted yet (killed
# between the fork and the worker_pid write): the worker may be alive, keep the slot.
jq -n --arg d "$DEAD_PID" '{id:"launching", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($d|tonumber), pid_start:"Thu Jan 1 00:00:00 1970", launching:true}' > "$LIVE_DIR/launching.json"
cap1_run "$W/artifact26.txt"; RC26=$?
check "26 dead wrapper, launching row without worker pid: slot kept" "1" "$RC26"
check "26 launching row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/launching.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# 27: lstart prints in the caller's TZ. The row was recorded under UTC (the
# wrapper pins it); a contender running under another TZ must still see the live
# holder as live, or two dispatches run at cap 1.
sleep 60 & LIVE_PID=$!
jq -n --arg p "$LIVE_PID" --arg s "$(proc_start "$LIVE_PID")" '{id:"tz", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:$s}' > "$LIVE_DIR/tz.json"
TZ=XXX-9 cap1_run "$W/artifact27.txt"; RC27=$?
check "27 live holder read under another TZ is not reaped: cap refuses" "1" "$RC27"
check "27 cross-TZ live holder row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/tz.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json

# 28: an empty recorded start is unknown, never proof of death.
jq -n --arg p "$LIVE_PID" '{id:"nostart", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:""}' > "$LIVE_DIR/nostart.json"
cap1_run "$W/artifact28.txt"; RC28=$?
check "28 live holder with empty recorded start is not reaped" "1" "$RC28"
rm -f "$LIVE_DIR"/*.json

# 29-31: ps yields no start time (unavailable, or a pid namespace boundary). Only
# kill -0 ESRCH proves a holder gone: a live pid, and an EPERM pid (1, init), keep
# their slot; a truly dead pid is still reaped.
FAKEPS="$W/fakeps"; mkdir -p "$FAKEPS"
REAL_PS="$(command -v ps)"
# shellcheck disable=SC2016
printf '#!/bin/sh\nfor a in "$@"; do [ "$a" = "lstart=" ] && exit 1; done\n%s "$@"\n' "$REAL_PS" > "$FAKEPS/ps"
chmod +x "$FAKEPS/ps"
jq -n --arg p "$LIVE_PID" '{id:"psnone", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:"Thu Jan 1 00:00:00 1970"}' > "$LIVE_DIR/psnone.json"
PATH="$FAKEPS:$PATH" cap1_run "$W/artifact29.txt"; RC29=$?
check "29 ps empty, pid alive (kill -0 ok): slot kept" "1" "$RC29"
rm -f "$LIVE_DIR"/*.json
jq -n '{id:"eperm", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:1, pid_start:"Thu Jan 1 00:00:00 1970"}' > "$LIVE_DIR/eperm.json"
PATH="$FAKEPS:$PATH" cap1_run "$W/artifact30.txt"; RC30=$?
check "30 ps empty, pid 1 (EPERM or alive): unknown keeps the slot" "1" "$RC30"
check "30 pid 1 row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/eperm.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json
jq -n --arg p "$DEAD_PID" '{id:"psdead", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:"Thu Jan 1 00:00:00 1970"}' > "$LIVE_DIR/psdead.json"
PATH="$FAKEPS:$PATH" cap1_run "$W/artifact31.txt"; RC31=$?
check "31 ps empty, pid confirmed gone (ESRCH): reaped" "0" "$RC31"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null
rm -f "$LIVE_DIR"/*.json

# 32-35 (HIMMEL-5119): a row carries a heartbeat; the next admission reaps a row
# whose heartbeat is older than HIMMEL_DISPATCH_ROW_TTL_SECS even when its pids
# are alive (wedged worker) or the launch never persisted a worker pid.
run_sut "$FAKE_OK" "$W/artifact32.txt" >/dev/null 2>&1
check "32 dispatch row records a heartbeat" "number" "$(jq -r '.heartbeat | type' "$LIVE_DIR"/*.json 2>/dev/null | head -n1)"
rm -f "$LIVE_DIR"/*.json
NOW32="$(date +%s)"
sleep 60 & LIVE_PID=$!
sleep 60 & WORKER_PID=$!
mk_hb_row() { # <name> <heartbeat epoch>
  jq -n --arg p "$LIVE_PID" --arg s "$(proc_start "$LIVE_PID")" --arg w "$WORKER_PID" --arg ws "$(proc_start "$WORKER_PID")" --argjson hb "$2" \
    '{id:"hb", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($p|tonumber), pid_start:$s,
      worker_pid:($w|tonumber), worker_start:$ws, heartbeat:$hb}' > "$LIVE_DIR/$1.json"
}
mk_hb_row fresh "$NOW32"
HIMMEL_DISPATCH_ROW_TTL_SECS=3600 cap1_run "$W/artifact33.txt"; RC33=$?
check "33 live pids with a fresh heartbeat: slot kept" "1" "$RC33"
check "33 fresh-heartbeat row stays dispatched" "dispatched" "$(jq -r '.status' "$LIVE_DIR/fresh.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json
mk_hb_row stale "$((NOW32 - 7200))"
HIMMEL_DISPATCH_ROW_TTL_SECS=3600 cap1_run "$W/artifact34.txt"; RC34=$?
check "34 live pids with a stale heartbeat: reaped, admission succeeds" "0" "$RC34"
check "34 stale-heartbeat row is marked interrupted" "interrupted" "$(jq -r '.status' "$LIVE_DIR/stale.json" 2>/dev/null)"
check "34 the wedged worker was killed (start time matched)" "gone" "$(kill -0 "$WORKER_PID" 2>/dev/null && echo alive || echo gone)"
check "34 the wrapper pid is left alone" "alive" "$(kill -0 "$LIVE_PID" 2>/dev/null && echo alive || echo gone)"
rm -f "$LIVE_DIR"/*.json
# 35: dead wrapper, launching mark, no worker pid persisted: kept while the
# heartbeat is fresh (fail closed), reaped once it is past the TTL.
jq -n --arg d "$DEAD_PID" --argjson hb "$NOW32" '{id:"lfresh", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($d|tonumber), pid_start:"Thu Jan 1 00:00:00 1970", launching:true, heartbeat:$hb}' > "$LIVE_DIR/lfresh.json"
HIMMEL_DISPATCH_ROW_TTL_SECS=3600 cap1_run "$W/artifact35.txt"; RC35=$?
check "35 launching row without worker pid, fresh heartbeat: slot kept" "1" "$RC35"
rm -f "$LIVE_DIR"/*.json
jq -n --arg d "$DEAD_PID" --argjson hb "$((NOW32 - 7200))" '{id:"lstale", role:"r", worktree:"w", ticket:"t", status:"dispatched", pid:($d|tonumber), pid_start:"Thu Jan 1 00:00:00 1970", launching:true, heartbeat:$hb}' > "$LIVE_DIR/lstale.json"
HIMMEL_DISPATCH_ROW_TTL_SECS=3600 cap1_run "$W/artifact35b.txt"; RC35B=$?
check "35 launching row without worker pid past the TTL: reaped" "0" "$RC35B"
check "35 stale launching row is marked interrupted" "interrupted" "$(jq -r '.status' "$LIVE_DIR/lstale.json" 2>/dev/null)"
rm -f "$LIVE_DIR"/*.json
kill "$LIVE_PID" "$WORKER_PID" 2>/dev/null; wait "$LIVE_PID" "$WORKER_PID" 2>/dev/null

# 36 (HIMMEL-5107): the dir-fallback steal restores a displaced LIVE reclaimer's
# marker atomically. Drives steal_stale_reclaim_lock itself (extracted from the
# SUT) with a seam stub, so the race is sequenced, not timed: the marker is
# replaced by a live owner between the pid read and the rename (steal-seen), and a
# third reclaimer takes the emptied slot after the mismatch is seen (steal-restore).
STEAL_FN="$W/steal-fn.sh"
sed -n '/^steal_stale_reclaim_lock() {/,/^}/p' "$SUT" > "$STEAL_FN"
check "36 steal function extracted" "1" "$(grep -c '^steal_stale_reclaim_lock' "$STEAL_FN")"
sleep 60 & OWNER_PID=$!
sleep 60 & THIRD_PID=$!
steal_run() { # <tag> <third|none>
  (
    RECLAIM_LOCK="$W/reclaim36-$1"
    STEAL_MODE="$2"
    mkdir "$RECLAIM_LOCK"; printf '%s' "$DEAD_PID" > "$RECLAIM_LOCK/pid"
    # shellcheck disable=SC2329  # invoked by the sourced steal function
    seam() {
      case "$1" in
        steal-seen) printf '%s' "$OWNER_PID" > "$RECLAIM_LOCK/pid" ;;
        steal-restore)
          if [ "$STEAL_MODE" = third ]; then mkdir "$RECLAIM_LOCK"; printf '%s' "$THIRD_PID" > "$RECLAIM_LOCK/pid"; fi ;;
      esac
    }
    # shellcheck disable=SC1090
    . "$STEAL_FN"
    steal_stale_reclaim_lock
  ) >/dev/null 2>&1
}
steal_run empty none
check "36 displaced live marker is restored into the empty slot" "$OWNER_PID" "$(cat "$W/reclaim36-empty/pid" 2>/dev/null)"
check "36 no .dead leftover after restore" "0" "$(ls -d "$W"/reclaim36-empty.dead.* 2>/dev/null | wc -l | tr -d ' ')"
steal_run taken third
check "36 third reclaimer's marker survives the restore race" "$THIRD_PID" "$(cat "$W/reclaim36-taken/pid" 2>/dev/null)"
check "36 no marker nested inside the third reclaimer's slot" "1" "$(ls -A "$W/reclaim36-taken" 2>/dev/null | wc -l | tr -d ' ')"
check "36 no .dead leftover after losing the race" "0" "$(ls -d "$W"/reclaim36-taken.dead.* 2>/dev/null | wc -l | tr -d ' ')"
kill "$OWNER_PID" "$THIRD_PID" 2>/dev/null; wait "$OWNER_PID" "$THIRD_PID" 2>/dev/null

echo "---$PASS passed, $FAIL failed, $SKIP skipped ---"
[ "$FAIL" -eq 0 ]
