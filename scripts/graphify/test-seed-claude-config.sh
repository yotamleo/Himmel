#!/usr/bin/env bash
# Hermetic tests for seed-claude-config.sh (HIMMEL-1902).
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$HERE/seed-claude-config.sh"
FAILS=0
pass() { echo "  ok: $1"; }
fail() { echo "  FAIL: $1"; FAILS=$((FAILS + 1)); }

WS="$(mktemp -d -t graphify-seed-config.XXXXXX)"
trap 'rm -rf "$WS"' EXIT

setup_home() {
  TEST_HOME="$1"
  mkdir -p "$TEST_HOME/.claude/plugins/marketplaces/himmel" "$TEST_HOME/.claude/hooks"
  printf 'subscription-auth-v1\n' > "$TEST_HOME/.claude/.credentials.json"
  cat > "$TEST_HOME/.claude/settings.json" <<'JSON'
{
  "model": "operator-default",
  "hooks": {"SessionEnd": [{"hooks": [{"type": "command", "command": "should-not-run"}]}]},
  "disableAllHooks": false,
  "env": {
    "ANTHROPIC_BASE_URL": "https://wrong.invalid",
    "Claude_Code_Use_Bedrock": "1",
    "CLAUDE_CODE_OAUTH_TOKEN": "wrong-billing-path",
    "KEEP_ME": "yes"
  },
  "enabledPlugins": {
    "unknown-fixture@tests": true
  }
}
JSON
  printf '{}\n' > "$TEST_HOME/.claude/plugins/installed_plugins.json"
  printf '{}\n' > "$TEST_HOME/.claude/plugins/known_marketplaces.json"
  printf 'marketplace fixture\n' > "$TEST_HOME/.claude/plugins/marketplaces/himmel/source.txt"
}

run_seed() {
  HOME="$TEST_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$TEST_HOME/.claude-graphify" bash "$HELPER"
}

SAME_DIR_HOME="$WS/same-dir-home"
setup_home "$SAME_DIR_HOME"
printf 'must survive\n' > "$SAME_DIR_HOME/.claude/hooks/SessionEnd"
same_dir_seed_rc=0
HOME="$SAME_DIR_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$SAME_DIR_HOME/.claude/../.claude/" \
bash "$HELPER" > "$WS/same-dir-seed.log" 2>&1 || same_dir_seed_rc=$?
if [ "$same_dir_seed_rc" -ne 0 ] \
   && grep -q 'resolve to the same directory' "$WS/same-dir-seed.log"; then
  pass "resolved source/config directory collision fails clearly"
else
  fail "source/config directory collision did not fail clearly (rc=$same_dir_seed_rc)"
fi
if [ -d "$SAME_DIR_HOME/.claude/hooks" ] \
   && grep -qx 'must survive' "$SAME_DIR_HOME/.claude/hooks/SessionEnd"; then
  pass "rejected same-directory seed preserves the source hooks tree"
else
  fail "same-directory guard ran after mutating the source hooks tree"
fi

PARENT_DIR_HOME="$WS/parent-dir-home"
setup_home "$PARENT_DIR_HOME"
printf 'must survive parent guard\n' > "$PARENT_DIR_HOME/.claude/hooks/SessionEnd"
parent_dir_seed_rc=0
HOME="$PARENT_DIR_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$PARENT_DIR_HOME" \
bash "$HELPER" > "$WS/parent-dir-seed.log" 2>&1 || parent_dir_seed_rc=$?
if [ "$parent_dir_seed_rc" -eq 4 ] \
   && grep -q 'resolved config directory.*contains resolved source directory' "$WS/parent-dir-seed.log"; then
  pass "config directory containing the source is rejected clearly"
else
  fail "config/source ancestor collision did not fail clearly (rc=$parent_dir_seed_rc)"
fi
if [ -d "$PARENT_DIR_HOME/.claude/hooks" ] \
   && grep -qx 'must survive parent guard' "$PARENT_DIR_HOME/.claude/hooks/SessionEnd"; then
  pass "rejected parent-directory seed preserves the source hooks tree"
else
  fail "parent-directory guard ran after mutating the source hooks tree"
fi

TEST_HOME="$WS/home"
setup_home "$TEST_HOME"
mkdir -p "$TEST_HOME/.claude-graphify/hooks"
printf 'stale hook\n' > "$TEST_HOME/.claude-graphify/hooks/SessionEnd"

if run_seed; then
  pass "first run seeds the graphify-dedicated Claude config"
else
  fail "first run should seed successfully"
fi

if cmp -s "$TEST_HOME/.claude/.credentials.json" "$TEST_HOME/.claude-graphify/.credentials.json"; then
  pass "subscription credentials are present byte-for-byte in the dedicated config"
else
  fail "subscription credentials were not copied"
fi

if [ ! -d "$TEST_HOME/.claude-graphify/hooks" ]; then
  pass "stale config-dir hooks are absent"
else
  fail "hooks directory survived the seed"
fi

if node - "$TEST_HOME/.claude-graphify/settings.json" <<'NODE'
const fs = require('fs');
const settings = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
if (settings.disableAllHooks !== true) throw new Error('disableAllHooks is not true');
if (Object.hasOwn(settings, 'hooks')) throw new Error('hooks key survived');
if (Object.hasOwn(settings, 'model')) throw new Error('model key survived');
for (const key of Object.keys(settings.env || {})) {
  const upper = key.toUpperCase();
  if (upper.startsWith('ANTHROPIC_') || upper.startsWith('CLAUDE_CODE_USE_') || upper === 'CLAUDE_CODE_OAUTH_TOKEN') throw new Error(`forbidden env key survived: ${key}`);
}
if ((settings.env || {}).KEEP_ME !== 'yes') throw new Error('unrelated env key was lost');
for (const id of ['handover@himmel', 'himmel-ops@himmel', 'qmd@himmel']) {
  if (settings.enabledPlugins[id] !== true) throw new Error(`bare floor plugin is not enabled: ${id}`);
}
if (settings.enabledPlugins['unknown-fixture@tests'] !== false) throw new Error('live unknown plugin was not denied');
for (const [id, enabled] of Object.entries(settings.enabledPlugins)) {
  if (!['handover@himmel', 'himmel-ops@himmel', 'qmd@himmel'].includes(id) && enabled !== false) {
    throw new Error(`non-floor plugin is enabled: ${id}`);
  }
}
NODE
then
  pass "settings strip hooks/reroutes and resolve to the validated bare floor"
else
  fail "seeded settings are not hook-free bare-profile settings"
fi

mkdir -p "$WS/mode-bin"
cat > "$WS/mode-bin/chmod" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 2 ] && [ "$1" = "600" ] && [ "$2" = "$MODE_CREDENTIAL_DEST" ]; then
  : > "$MODE_CHMOD_OBSERVED"
fi
exec "$REAL_CHMOD" "$@"
SH
chmod +x "$WS/mode-bin/chmod"
REAL_CHMOD="$(command -v chmod)"
MODE_CHMOD_OBSERVED="$WS/mode-chmod-observed"
chmod 666 "$TEST_HOME/.claude-graphify/.credentials.json"
credential_mode_before="$(stat -c %a "$TEST_HOME/.claude-graphify/.credentials.json" 2>/dev/null || stat -f %Lp "$TEST_HOME/.claude-graphify/.credentials.json" 2>/dev/null)"
printf 'subscription-auth-v2\n' > "$TEST_HOME/.claude/.credentials.json"
printf '{"marker":"reseeded"}\n' > "$TEST_HOME/.claude/settings.json"
touch -t 202001010000 "$TEST_HOME/.claude-graphify/.seeded"
if HOME="$TEST_HOME" \
   GRAPHIFY_CLAUDE_CONFIG_DIR="$TEST_HOME/.claude-graphify" \
   PATH="$WS/mode-bin:$PATH" \
   REAL_CHMOD="$REAL_CHMOD" \
   MODE_CREDENTIAL_DEST="$TEST_HOME/.claude-graphify/.credentials.json" \
   MODE_CHMOD_OBSERVED="$MODE_CHMOD_OBSERVED" \
   bash "$HELPER" \
   && grep -q 'subscription-auth-v2' "$TEST_HOME/.claude-graphify/.credentials.json" \
   && grep -q 'reseeded' "$TEST_HOME/.claude-graphify/settings.json"; then
  pass "stale source credentials/settings trigger an automatic reseed"
else
  fail "stale seed did not refresh credentials and settings"
fi
credential_mode_after="$(stat -c %a "$TEST_HOME/.claude-graphify/.credentials.json" 2>/dev/null || stat -f %Lp "$TEST_HOME/.claude-graphify/.credentials.json" 2>/dev/null)"
credential_mode_ok=0
if [ -e "$MODE_CHMOD_OBSERVED" ]; then
  if [ "$credential_mode_before" != "666" ] || [ "$credential_mode_after" = "600" ]; then
    credential_mode_ok=1
  fi
fi
if [ "$credential_mode_ok" -eq 1 ]; then
  pass "reseed explicitly restricts an existing credential destination to mode 600"
else
  fail "credential mode was not explicitly tightened to 600 (saw $credential_mode_before -> $credential_mode_after)"
fi

DELETED_SETTINGS_HOME="$WS/deleted-settings-home"
setup_home "$DELETED_SETTINGS_HOME"
HOME="$DELETED_SETTINGS_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$DELETED_SETTINGS_HOME/.claude-graphify" bash "$HELPER"
touch -t 203001010000 "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded"
deleted_settings_seed_before="$(stat -c %Y "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null || stat -f %m "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null)"
rm -f "$DELETED_SETTINGS_HOME/.claude/settings.json"
deleted_settings_reseed_rc=0
HOME="$DELETED_SETTINGS_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$DELETED_SETTINGS_HOME/.claude-graphify" bash "$HELPER" || deleted_settings_reseed_rc=$?
deleted_settings_seed_after="$(stat -c %Y "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null || stat -f %m "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null)"
if [ "$deleted_settings_reseed_rc" -eq 0 ] \
   && [ "$deleted_settings_seed_after" != "$deleted_settings_seed_before" ] \
   && [ ! -f "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded-from-settings" ]; then
  pass "deleting source settings.json triggers one reseed and clears its presence marker"
else
  fail "deleted source settings.json did not trigger a clean reseed (rc=$deleted_settings_reseed_rc mtime=$deleted_settings_seed_before->$deleted_settings_seed_after)"
fi
touch -t 203101010000 "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded"
deleted_settings_no_churn_before="$(stat -c %Y "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null || stat -f %m "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null)"
deleted_settings_third_rc=0
HOME="$DELETED_SETTINGS_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$DELETED_SETTINGS_HOME/.claude-graphify" bash "$HELPER" || deleted_settings_third_rc=$?
deleted_settings_no_churn_after="$(stat -c %Y "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null || stat -f %m "$DELETED_SETTINGS_HOME/.claude-graphify/.seeded" 2>/dev/null)"
if [ "$deleted_settings_third_rc" -eq 0 ] \
   && [ "$deleted_settings_no_churn_after" = "$deleted_settings_no_churn_before" ]; then
  pass "deleted source settings.json does not cause repeated reseed churn"
else
  fail "deleted source settings.json kept reseeding (rc=$deleted_settings_third_rc mtime=$deleted_settings_no_churn_before->$deleted_settings_no_churn_after)"
fi

ATOMIC_HOME="$WS/atomic-home"
setup_home "$ATOMIC_HOME"
mkdir -p "$ATOMIC_HOME/.claude-graphify" "$WS/atomic-bin"
ATOMIC_OLD_CREDENTIAL="old-credential-complete"
ATOMIC_OLD_SETTINGS='{"old":true}'
printf '%s\n' "$ATOMIC_OLD_CREDENTIAL" > "$ATOMIC_HOME/.claude-graphify/.credentials.json"
printf '%s\n' "$ATOMIC_OLD_SETTINGS" > "$ATOMIC_HOME/.claude-graphify/settings.json"
printf '0\n' > "$ATOMIC_HOME/.claude-graphify/.seeded"
cat > "$WS/atomic-bin/cp" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -eq 2 ] && [ "$1" = "$ATOMIC_CREDENTIAL_SOURCE" ]; then
  printf 'partial-credential' > "$2"
  if [ "$(cat "$ATOMIC_CREDENTIAL_DEST")" != "$ATOMIC_OLD_CREDENTIAL" ]; then
    : > "$ATOMIC_CREDENTIAL_OBSERVED"
  fi
fi
exec "$REAL_CP" "$@"
SH
cat > "$WS/atomic-bin/node" <<'SH'
#!/usr/bin/env bash
set -u
if [ "$#" -ge 5 ] && [ "$1" = "-e" ]; then
  printf '{"partial":' > "$5"
  if [ "$(cat "$ATOMIC_SETTINGS_DEST")" != "$ATOMIC_OLD_SETTINGS" ]; then
    : > "$ATOMIC_SETTINGS_OBSERVED"
  fi
fi
exec "$REAL_NODE" "$@"
SH
chmod +x "$WS/atomic-bin/cp" "$WS/atomic-bin/node"
REAL_CP="$(command -v cp)"
REAL_NODE="$(command -v node)"
ATOMIC_CREDENTIAL_OBSERVED="$WS/atomic-credential-observed"
ATOMIC_SETTINGS_OBSERVED="$WS/atomic-settings-observed"
atomic_seed_rc=0
HOME="$ATOMIC_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$ATOMIC_HOME/.claude-graphify" \
PATH="$WS/atomic-bin:$PATH" \
REAL_CP="$REAL_CP" \
REAL_NODE="$REAL_NODE" \
ATOMIC_CREDENTIAL_SOURCE="$ATOMIC_HOME/.claude/.credentials.json" \
ATOMIC_CREDENTIAL_DEST="$ATOMIC_HOME/.claude-graphify/.credentials.json" \
ATOMIC_OLD_CREDENTIAL="$ATOMIC_OLD_CREDENTIAL" \
ATOMIC_CREDENTIAL_OBSERVED="$ATOMIC_CREDENTIAL_OBSERVED" \
ATOMIC_SETTINGS_DEST="$ATOMIC_HOME/.claude-graphify/settings.json" \
ATOMIC_OLD_SETTINGS="$ATOMIC_OLD_SETTINGS" \
ATOMIC_SETTINGS_OBSERVED="$ATOMIC_SETTINGS_OBSERVED" \
bash "$HELPER" || atomic_seed_rc=$?
atomic_settings_rc=0
node -e 'const fs = require("fs"); const settings = JSON.parse(fs.readFileSync(process.argv[1], "utf8")); if (settings.disableAllHooks !== true) process.exit(1);' \
  "$ATOMIC_HOME/.claude-graphify/settings.json" || atomic_settings_rc=$?
atomic_temp_count=0
for artifact in "$ATOMIC_HOME/.claude-graphify"/.*.tmp.*; do
  [ -e "$artifact" ] && atomic_temp_count=$((atomic_temp_count + 1))
done
if [ "$atomic_seed_rc" -eq 0 ] \
   && [ "$atomic_settings_rc" -eq 0 ] \
   && cmp -s "$ATOMIC_HOME/.claude/.credentials.json" "$ATOMIC_HOME/.claude-graphify/.credentials.json" \
   && [ ! -e "$ATOMIC_CREDENTIAL_OBSERVED" ] \
   && [ ! -e "$ATOMIC_SETTINGS_OBSERVED" ] \
   && [ "$atomic_temp_count" -eq 0 ]; then
  pass "reseeding atomically replaces complete credentials/settings without leftover temp files"
else
  fail "reseeding exposed partial config or left temp files (seed=$atomic_seed_rc settings=$atomic_settings_rc temps=$atomic_temp_count)"
fi

MISSING_HOME="$WS/missing-home"
mkdir -p "$MISSING_HOME/.claude"
printf '{}\n' > "$MISSING_HOME/.claude/settings.json"
if HOME="$MISSING_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$MISSING_HOME/.claude-graphify" bash "$HELPER" >/dev/null 2>&1; then
  fail "missing subscription credentials should fail closed"
else
  if [ ! -f "$MISSING_HOME/.claude-graphify/.seeded" ]; then
    pass "missing subscription credentials fail closed without a sentinel"
  else
    fail "failed seed left a .seeded sentinel"
  fi
fi

LEADING_ZERO_LOCK_HOME="$WS/leading-zero-lock-home"
setup_home "$LEADING_ZERO_LOCK_HOME"
mkdir "$LEADING_ZERO_LOCK_HOME/.claude-graphify.seed-lock"
printf 'temporary-holder\n' > "$LEADING_ZERO_LOCK_HOME/.claude-graphify.seed-lock/owner"
( sleep 1
  rm -f "$LEADING_ZERO_LOCK_HOME/.claude-graphify.seed-lock/owner"
  rmdir "$LEADING_ZERO_LOCK_HOME/.claude-graphify.seed-lock" ) &
leading_zero_holder_pid=$!
leading_zero_lock_rc=0
HOME="$LEADING_ZERO_LOCK_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$LEADING_ZERO_LOCK_HOME/.claude-graphify" \
CLAUDE_LANE_SEED_LOCK_TIMEOUT=08 \
CLAUDE_LANE_SEED_LOCK_STALE=120 \
bash "$HELPER" > "$WS/leading-zero-lock.log" 2>&1 || leading_zero_lock_rc=$?
wait "$leading_zero_holder_pid"
if [ "$leading_zero_lock_rc" -eq 0 ] \
   && [ -f "$LEADING_ZERO_LOCK_HOME/.claude-graphify/.seeded" ] \
   && [ ! -d "$LEADING_ZERO_LOCK_HOME/.claude-graphify.seed-lock" ]; then
  pass "leading-zero seed-lock timeout is honored as base 10"
else
  fail "leading-zero seed-lock timeout did not wait and seed cleanly (rc=$leading_zero_lock_rc)"
fi

GARBAGE_TIMEOUT_HOME="$WS/garbage-timeout-home"
setup_home "$GARBAGE_TIMEOUT_HOME"
mkdir "$GARBAGE_TIMEOUT_HOME/.claude-graphify.seed-lock"
printf 'temporary-holder\n' > "$GARBAGE_TIMEOUT_HOME/.claude-graphify.seed-lock/owner"
( sleep 1
  rm -f "$GARBAGE_TIMEOUT_HOME/.claude-graphify.seed-lock/owner"
  rmdir "$GARBAGE_TIMEOUT_HOME/.claude-graphify.seed-lock" ) &
garbage_timeout_holder_pid=$!
garbage_timeout_rc=0
HOME="$GARBAGE_TIMEOUT_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$GARBAGE_TIMEOUT_HOME/.claude-graphify" \
CLAUDE_LANE_SEED_LOCK_TIMEOUT=garbage \
CLAUDE_LANE_SEED_LOCK_STALE=garbage \
bash "$HELPER" > "$WS/garbage-timeout.log" 2>&1 || garbage_timeout_rc=$?
wait "$garbage_timeout_holder_pid"
if [ "$garbage_timeout_rc" -eq 0 ] \
   && [ -f "$GARBAGE_TIMEOUT_HOME/.claude-graphify/.seeded" ] \
   && [ ! -d "$GARBAGE_TIMEOUT_HOME/.claude-graphify.seed-lock" ]; then
  pass "garbage seed-lock values fall back to documented defaults"
else
  fail "garbage seed-lock values did not fall back cleanly (rc=$garbage_timeout_rc)"
fi

MISMATCH_OWNER_HOME="$WS/mismatch-owner-home"
setup_home "$MISMATCH_OWNER_HOME"
cat > "$WS/slow-profile.mjs" <<'NODE'
setTimeout(() => process.stdout.write('{"enabledPlugins":{}}\n'), 500);
NODE
( while [ ! -f "$MISMATCH_OWNER_HOME/.claude-graphify.seed-lock/owner" ]; do sleep 0.01; done
  printf 'replacement-owner\n' > "$MISMATCH_OWNER_HOME/.claude-graphify.seed-lock/owner" ) &
mismatch_owner_writer_pid=$!
mismatch_owner_rc=0
HOME="$MISMATCH_OWNER_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$MISMATCH_OWNER_HOME/.claude-graphify" \
GRAPHIFY_PLUGIN_PROFILES_BIN="$WS/slow-profile.mjs" \
bash "$HELPER" > "$WS/mismatch-owner.log" 2>&1 || mismatch_owner_rc=$?
wait "$mismatch_owner_writer_pid"
if [ "$mismatch_owner_rc" -eq 0 ] \
   && [ -d "$MISMATCH_OWNER_HOME/.claude-graphify.seed-lock" ] \
   && grep -qx 'replacement-owner' "$MISMATCH_OWNER_HOME/.claude-graphify.seed-lock/owner" \
   && ! grep -q 'WARNING - failed to release seed lock' "$WS/mismatch-owner.log"; then
  pass "mismatched owner release leaves the replacement lock intact and silent"
else
  fail "mismatched owner release changed or warned about the replacement lock (rc=$mismatch_owner_rc)"
fi

FRESH_LOCK_HOME="$WS/fresh-lock-home"
setup_home "$FRESH_LOCK_HOME"
mkdir "$FRESH_LOCK_HOME/.claude-graphify.seed-lock"
printf 'foreign-fresh-owner\n' > "$FRESH_LOCK_HOME/.claude-graphify.seed-lock/owner"
fresh_lock_rc=0
HOME="$FRESH_LOCK_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$FRESH_LOCK_HOME/.claude-graphify" \
CLAUDE_LANE_SEED_LOCK_TIMEOUT=1 \
CLAUDE_LANE_SEED_LOCK_STALE=120 \
bash "$HELPER" > "$WS/fresh-lock.log" 2>&1 || fresh_lock_rc=$?
if [ "$fresh_lock_rc" -eq 4 ] \
   && [ -d "$FRESH_LOCK_HOME/.claude-graphify.seed-lock" ] \
   && grep -qx 'foreign-fresh-owner' "$FRESH_LOCK_HOME/.claude-graphify.seed-lock/owner"; then
  pass "fresh foreign-owned seed lock times out without being stolen"
else
  fail "fresh foreign-owned seed lock was changed or did not time out (rc=$fresh_lock_rc)"
fi

STALE_LOCK_HOME="$WS/stale-lock-home"
setup_home "$STALE_LOCK_HOME"
mkdir "$STALE_LOCK_HOME/.claude-graphify.seed-lock"
printf 'foreign-stale-owner\n' > "$STALE_LOCK_HOME/.claude-graphify.seed-lock/owner"
touch -t 202001010000 "$STALE_LOCK_HOME/.claude-graphify.seed-lock"
stale_lock_rc=0
HOME="$STALE_LOCK_HOME" \
GRAPHIFY_CLAUDE_CONFIG_DIR="$STALE_LOCK_HOME/.claude-graphify" \
CLAUDE_LANE_SEED_LOCK_TIMEOUT=2 \
CLAUDE_LANE_SEED_LOCK_STALE=1 \
bash "$HELPER" > "$WS/stale-lock.log" 2>&1 || stale_lock_rc=$?
stale_lock_orphan_count=0
for stale_lock_orphan in "$STALE_LOCK_HOME/.claude-graphify.seed-lock.stale."*; do
  [ -e "$stale_lock_orphan" ] && stale_lock_orphan_count=$((stale_lock_orphan_count + 1))
done
if [ "$stale_lock_rc" -eq 0 ] \
   && [ -f "$STALE_LOCK_HOME/.claude-graphify/.seeded" ] \
   && { [ ! -f "$STALE_LOCK_HOME/.claude-graphify.seed-lock/owner" ] \
        || ! grep -qx 'foreign-stale-owner' "$STALE_LOCK_HOME/.claude-graphify.seed-lock/owner"; } \
   && [ "$stale_lock_orphan_count" -eq 0 ]; then
  pass "stale foreign-owned seed lock is stolen and cleaned without orphan dirs"
else
  fail "stale foreign-owned seed lock did not recover cleanly (rc=$stale_lock_rc orphans=$stale_lock_orphan_count)"
fi

CONCURRENT_HOME="$WS/concurrent-home"
setup_home "$CONCURRENT_HOME"
HOME="$CONCURRENT_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$CONCURRENT_HOME/.claude-graphify" bash "$HELPER" > "$WS/concurrent-a.log" 2>&1 &
pid_a=$!
HOME="$CONCURRENT_HOME" GRAPHIFY_CLAUDE_CONFIG_DIR="$CONCURRENT_HOME/.claude-graphify" bash "$HELPER" > "$WS/concurrent-b.log" 2>&1 &
pid_b=$!
wait "$pid_a"; rc_a=$?
wait "$pid_b"; rc_b=$?
if [ "$rc_a" -eq 0 ] && [ "$rc_b" -eq 0 ] \
   && [ -f "$CONCURRENT_HOME/.claude-graphify/.seeded" ] \
   && [ ! -d "$CONCURRENT_HOME/.claude-graphify.seed-lock" ]; then
  pass "concurrent first seeds serialize and release the seed lock"
else
  fail "concurrent seeds did not compose (rc=$rc_a/$rc_b): $(cat "$WS/concurrent-a.log" "$WS/concurrent-b.log")"
fi

if [ "$FAILS" -ne 0 ]; then
  echo "$FAILS FAILURES"
  exit 1
fi
echo "ALL PASS"
