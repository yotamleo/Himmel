#!/usr/bin/env bash
# seed-claude-config.sh — build the hook-free native-auth Claude profile used by
# refresh-graph-map.sh's claude-cli backend (HIMMEL-1902). bash 3.2-safe.
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$HERE/../.." && pwd)"
CONFIG_DIR="${GRAPHIFY_CLAUDE_CONFIG_DIR:-${HOME}/.claude-graphify}"
SOURCE_DIR="${GRAPHIFY_CLAUDE_SOURCE_CONFIG_DIR:-${HOME}/.claude}"
PROFILE_RESOLVER="${GRAPHIFY_PLUGIN_PROFILES_BIN:-$REPO_ROOT/scripts/lanes/plugin-profiles.mjs}"
SEED_VERSION="2"
LOCK="$CONFIG_DIR.seed-lock"
SEED_LOCK_TOKEN="$$@$(hostname 2>/dev/null || echo unknown)-$RANDOM"
SEED_LOCK_TIMEOUT="${CLAUDE_LANE_SEED_LOCK_TIMEOUT:-60}"
case "$SEED_LOCK_TIMEOUT" in ''|*[!0-9]*) SEED_LOCK_TIMEOUT=60 ;; esac
[ "$SEED_LOCK_TIMEOUT" -gt 0 ] 2>/dev/null || SEED_LOCK_TIMEOUT=60
SEED_LOCK_TIMEOUT=$(( 10#$SEED_LOCK_TIMEOUT ))
SEED_LOCK_STALE="${CLAUDE_LANE_SEED_LOCK_STALE:-120}"
case "$SEED_LOCK_STALE" in ''|*[!0-9]*) SEED_LOCK_STALE=120 ;; esac
[ "$SEED_LOCK_STALE" -gt 0 ] 2>/dev/null || SEED_LOCK_STALE=120
SEED_LOCK_STALE=$(( 10#$SEED_LOCK_STALE ))
PROFILE_TMP=""
CREDENTIALS_TMP=""
SETTINGS_TMP=""
CONFIG_DIR_VALIDATED=0

seed_fail() { # $1 = failing-operation detail
  [ -n "$PROFILE_TMP" ] && rm -f "$PROFILE_TMP" 2>/dev/null
  [ -n "$CREDENTIALS_TMP" ] && rm -f "$CREDENTIALS_TMP" 2>/dev/null
  [ -n "$SETTINGS_TMP" ] && rm -f "$SETTINGS_TMP" 2>/dev/null
  [ "$CONFIG_DIR_VALIDATED" -eq 1 ] && rm -f "$CONFIG_DIR/.seeded" 2>/dev/null
  echo "seed-claude-config: FAILED to $1. Refusing to run graphify with an unseeded Claude config dir ($CONFIG_DIR)." >&2
  exit 4
}

resolve_seed_path() { # $1 = path; resolves symlinks in the nearest existing prefix
  node -e '
const fs = require("fs");
const path = require("path");
let current = process.argv[1];
const missing = [];
if (!path.isAbsolute(current)) current = path.join(process.cwd(), current);
for (;;) {
  let exists = true;
  try {
    fs.lstatSync(current);
  } catch (error) {
    if (error.code !== "ENOENT" && error.code !== "ENOTDIR") throw error;
    exists = false;
  }
  if (exists) {
    process.stdout.write(path.join(fs.realpathSync(current), ...missing));
    break;
  }
  const parent = path.dirname(current);
  if (parent === current) process.exit(1);
  missing.unshift(path.basename(current));
  current = parent;
}
' "$1"
}

sanitize_settings() { # $1 source settings, $2 bare profile, $3 destination
  node -e '
const fs = require("fs");
const source = process.argv[1];
const profile = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const settings = fs.existsSync(source) ? JSON.parse(fs.readFileSync(source, "utf8")) : {};
if (!profile || !profile.enabledPlugins || Array.isArray(profile.enabledPlugins)) process.exit(2);
delete settings.model;
delete settings.hooks;
if (settings.env) for (const key of Object.keys(settings.env)) {
  const upper = key.toUpperCase();
  if (upper.indexOf("ANTHROPIC_") === 0 || upper.indexOf("CLAUDE_CODE_USE_") === 0 || upper === "CLAUDE_CODE_OAUTH_TOKEN") delete settings.env[key];
}
settings.disableAllHooks = true;
settings.enabledPlugins = profile.enabledPlugins;
fs.writeFileSync(process.argv[3], JSON.stringify(settings, null, 2) + "\n");
' "$1" "$2" "$3"
}

seed_config_dir() {
  local resolved_config_dir resolved_source_dir
  resolved_config_dir="$(resolve_seed_path "$CONFIG_DIR")" \
    || seed_fail "resolve GRAPHIFY_CLAUDE_CONFIG_DIR ($CONFIG_DIR) before seeding"
  resolved_source_dir="$(resolve_seed_path "$SOURCE_DIR")" \
    || seed_fail "resolve GRAPHIFY_CLAUDE_SOURCE_CONFIG_DIR ($SOURCE_DIR) before seeding"
  if [ "$resolved_config_dir" = "$resolved_source_dir" ]; then
    seed_fail "seed the graphify Claude config because GRAPHIFY_CLAUDE_CONFIG_DIR and GRAPHIFY_CLAUDE_SOURCE_CONFIG_DIR resolve to the same directory ($resolved_config_dir)"
  fi
  case "$resolved_source_dir" in
    "$resolved_config_dir"[\\/]*)
      seed_fail "seed the graphify Claude config because resolved config directory $resolved_config_dir contains resolved source directory $resolved_source_dir" ;;
  esac
  case "$resolved_config_dir" in
    "$resolved_source_dir"[\\/]*)
      seed_fail "seed the graphify Claude config because resolved source directory $resolved_source_dir contains resolved config directory $resolved_config_dir" ;;
  esac
  CONFIG_DIR_VALIDATED=1

  # Transactional sentinel: clear it first and write it only after credentials,
  # hook policy, and the bare plugin profile have all landed successfully.
  rm -f "$CONFIG_DIR/.seeded" || seed_fail "clear the stale .seeded sentinel"
  mkdir -p "$CONFIG_DIR/plugins" || seed_fail "create $CONFIG_DIR/plugins"
  [ -f "$SOURCE_DIR/.credentials.json" ] \
    || seed_fail "find subscription credentials at $SOURCE_DIR/.credentials.json"

  umask 077
  # A same-directory mv is atomic on POSIX. MSYS cannot promise the same
  # guarantee, but replacing a complete temp file still avoids truncating the
  # live credentials or settings file in place.
  CREDENTIALS_TMP="$(mktemp "$CONFIG_DIR/.credentials.json.tmp.XXXXXX")" \
    || seed_fail "create a subscription credentials temp file"
  cp "$SOURCE_DIR/.credentials.json" "$CREDENTIALS_TMP" \
    || seed_fail "stage subscription credentials"
  chmod 600 "$CREDENTIALS_TMP" \
    || seed_fail "restrict staged subscription credentials"
  mv -f "$CREDENTIALS_TMP" "$CONFIG_DIR/.credentials.json" \
    || seed_fail "replace subscription credentials"
  CREDENTIALS_TMP=""
  chmod 600 "$CONFIG_DIR/.credentials.json" \
    || seed_fail "restrict subscription credentials"

  PROFILE_TMP="$CONFIG_DIR/.bare-profile.$$"
  CLAUDE_CONFIG_DIR="$SOURCE_DIR" node "$PROFILE_RESOLVER" bare > "$PROFILE_TMP" \
    || seed_fail "resolve the validated bare plugin profile"
  SETTINGS_TMP="$(mktemp "$CONFIG_DIR/.settings.json.tmp.XXXXXX")" \
    || seed_fail "create a settings.json temp file"
  sanitize_settings "$SOURCE_DIR/settings.json" "$PROFILE_TMP" "$SETTINGS_TMP" \
    || seed_fail "sanitize settings.json and apply the bare plugin profile"
  mv -f "$SETTINGS_TMP" "$CONFIG_DIR/settings.json" \
    || seed_fail "replace settings.json"
  SETTINGS_TMP=""
  rm -f "$PROFILE_TMP" || seed_fail "remove the temporary bare plugin profile"
  PROFILE_TMP=""
  if [ -f "$SOURCE_DIR/settings.json" ]; then
    : > "$CONFIG_DIR/.seeded-from-settings" \
      || seed_fail "record that settings.json was seeded from the source config"
  else
    rm -f "$CONFIG_DIR/.seeded-from-settings" \
      || seed_fail "clear the source settings.json presence marker"
  fi

  # Hooks can also be installed as a config-dir subtree. The settings-level
  # disableAllHooks=true suppresses settings and plugin hooks at runtime; this
  # deletion prevents a stale dedicated-profile hook tree from lingering too.
  rm -rf "${CONFIG_DIR:?}/hooks" || seed_fail "clear stale hooks"

  for manifest in installed_plugins.json known_marketplaces.json; do
    if [ -f "$SOURCE_DIR/plugins/$manifest" ]; then
      cp "$SOURCE_DIR/plugins/$manifest" "$CONFIG_DIR/plugins/$manifest" \
        || seed_fail "copy plugins/$manifest"
    else
      rm -f "$CONFIG_DIR/plugins/$manifest" \
        || seed_fail "remove stale plugins/$manifest"
    fi
  done
  rm -rf "${CONFIG_DIR:?}/plugins/marketplaces" \
    || seed_fail "clear stale plugins/marketplaces"
  if [ -d "$SOURCE_DIR/plugins/marketplaces" ]; then
    cp -R "$SOURCE_DIR/plugins/marketplaces" "$CONFIG_DIR/plugins/" \
      || seed_fail "copy plugins/marketplaces"
  fi

  printf '%s\n' "$SEED_VERSION" > "$CONFIG_DIR/.seeded" \
    || seed_fail "write the .seeded sentinel"
}

config_seed_stale() { # rc=0 when the dedicated profile must be rebuilt
  [ "$(cat "$CONFIG_DIR/.seeded" 2>/dev/null)" = "$SEED_VERSION" ] || return 0
  [ -f "$CONFIG_DIR/.credentials.json" ] || return 0
  [ -f "$CONFIG_DIR/settings.json" ] || return 0
  [ ! -d "$CONFIG_DIR/hooks" ] || return 0

  [ -f "$SOURCE_DIR/.credentials.json" ] || return 0
  [ "$SOURCE_DIR/.credentials.json" -nt "$CONFIG_DIR/.seeded" ] && return 0
  if [ -f "$SOURCE_DIR/settings.json" ] \
     && [ "$SOURCE_DIR/settings.json" -nt "$CONFIG_DIR/.seeded" ]; then
    return 0
  fi
  if [ ! -f "$SOURCE_DIR/settings.json" ] \
     && [ -f "$CONFIG_DIR/.seeded-from-settings" ]; then
    return 0
  fi
  for source in plugins/installed_plugins.json plugins/known_marketplaces.json; do
    if [ -f "$SOURCE_DIR/$source" ]; then
      [ "$SOURCE_DIR/$source" -nt "$CONFIG_DIR/.seeded" ] && return 0
    elif [ -f "$CONFIG_DIR/$source" ]; then
      return 0
    fi
  done
  if [ -d "$SOURCE_DIR/plugins/marketplaces" ]; then
    [ -d "$CONFIG_DIR/plugins/marketplaces" ] || return 0
    [ "$SOURCE_DIR/plugins/marketplaces" -nt "$CONFIG_DIR/.seeded" ] && return 0
  elif [ -d "$CONFIG_DIR/plugins/marketplaces" ]; then
    return 0
  fi
  [ "$PROFILE_RESOLVER" -nt "$CONFIG_DIR/.seeded" ] && return 0
  [ "$REPO_ROOT/scripts/lanes/plugin-profiles.json" -nt "$CONFIG_DIR/.seeded" ] && return 0
  return 1
}

seed_lock_is_stale() {
  local lock_mtime now
  [ -d "$LOCK" ] || return 1
  lock_mtime="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)"
  case "$lock_mtime" in ''|*[!0-9]*) return 1 ;; esac
  now="$(date +%s)"
  [ "$(( now - lock_mtime ))" -ge "$SEED_LOCK_STALE" ]
}

seed_lock_release() { # $1 = 1 to warn when our owned lock cannot be removed
  local warn="$1" owner
  owner="$(cat "$LOCK/owner" 2>/dev/null)"
  [ "$owner" = "$SEED_LOCK_TOKEN" ] || return 0
  rm -f "$LOCK/owner" 2>/dev/null
  if ! rmdir "$LOCK" 2>/dev/null && [ "$warn" -eq 1 ]; then
    echo "seed-claude-config: WARNING - failed to release seed lock $LOCK; it becomes stealable after ${SEED_LOCK_STALE}s." >&2
  fi
}

seed_with_lock() {
  local ticks=0 max_ticks=$(( SEED_LOCK_TIMEOUT * 2 )) mkdir_error=""
  while :; do
    if mkdir_error="$(mkdir "$LOCK" 2>&1)"; then
      printf '%s\n' "$SEED_LOCK_TOKEN" > "$LOCK/owner" \
        || { rm -rf "$LOCK"; seed_fail "record seed-lock ownership"; }
      break
    fi
    if seed_lock_is_stale && mv "$LOCK" "$LOCK.stale.$$" 2>/dev/null; then
      rm -rf "$LOCK.stale.$$"
      continue
    fi
    if [ "$ticks" -ge "$max_ticks" ]; then
      echo "seed-claude-config: timed out after ${SEED_LOCK_TIMEOUT}s waiting for $LOCK; last mkdir error: $mkdir_error" >&2
      exit 4
    fi
    sleep 0.5
    ticks=$(( ticks + 1 ))
  done

  trap 'seed_lock_release 0' EXIT
  if [ ! -f "$CONFIG_DIR/.seeded" ] || config_seed_stale; then
    seed_config_dir
  fi
  trap - EXIT
  seed_lock_release 1
}

if [ ! -f "$CONFIG_DIR/.seeded" ] || config_seed_stale; then
  seed_with_lock
fi
