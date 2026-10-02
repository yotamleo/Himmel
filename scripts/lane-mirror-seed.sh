#!/usr/bin/env bash
# Shared lane mirror/lock (HIMMEL-4091), sourced by the three launchers.
# bash 3.2-safe. Caller supplies CONFIG_DIR, HOME, seed_fail, sanitize_settings,
# and optional seed_stamp / seed_after_leaves / seed_after_mirror callbacks.
seed_stamp() { :; }
seed_after_leaves() { :; }
seed_after_mirror() { :; }

lane_seed_fingerprint() {
  node -e '
const fs=require("fs"), path=require("path"), crypto=require("crypto");
const root=process.argv[1], only=process.argv[2], destination=process.argv[3], hash=crypto.createHash("sha256"), strict=crypto.createHash("sha256");
// Completion tolerates settings/marketplace writes; freshness still hashes all bytes.
function record(rel,data) {
  hash.update(data);
  const portable=rel.split(path.sep).join("/");
  if(portable!=="settings.json" && portable!=="plugins/marketplaces" && !portable.startsWith("plugins/marketplaces/")) strict.update(data);
}
function skip(rel,reason) {
  record(rel,"skipped\n"); console.error("lane mirror: skipping "+rel+" ("+reason+")");
}
function walk(rel,ancestors=new Set(),dst) {
  const p=path.join(root,rel);
  record(rel,JSON.stringify(rel)+"\n");
  let s, link, real, names, data;
  try {
    s=fs.lstatSync(p);
    if(s.isSymbolicLink()) {
      link=fs.readlinkSync(p);
      // POSIX copies preserve links; win32 retains dereferencing to avoid symlink privilege requirements.
      if(dst && process.platform!=="win32") { fs.symlinkSync(link,dst); return; }
      s=fs.statSync(p);
    }
    if(s.isDirectory()) {
      real=fs.realpathSync(p);
      if(ancestors.has(real)) { skip(rel,"symlink cycle"); return; }
      names=fs.readdirSync(p).sort();
    } else if(s.isFile()) { data=fs.readFileSync(p); }
    else { skip(rel,"special file"); return; }
  } catch(e) {
    if(dst && link!==undefined && process.platform!=="win32") throw e;
    if(["ENOENT","ENOTDIR","EACCES","EPERM","ELOOP"].includes(e.code)) {
      if(e.code==="ENOENT" && !link) { record(rel,"absent\n"); return; }
      skip(rel,e.code); return;
    }
    throw e;
  }
  if(link!==undefined) record(rel,"link\n"+JSON.stringify(link)+"\n");
  if(s.isDirectory()) {
    const next=new Set(ancestors); next.add(real);
    record(rel,"dir\n");
    if(dst) fs.mkdirSync(dst,{recursive:true,mode:0o700});
    for(const name of names) walk(path.join(rel,name),next,dst&&path.join(dst,name));
    if(dst) fs.chmodSync(dst,s.mode&0o777);
  } else {
    record(rel,"file\n"+s.mode+"\n"+data.length+"\n"); record(rel,data);
    if(dst) fs.writeFileSync(dst,data,{mode:s.mode&0o777});
  }
}
try {
  if(only) walk(only,new Set(),destination);
  else for(const rel of ["settings.json","CLAUDE.md","RTK.md","commands","skills","hooks","agents","plugins/installed_plugins.json","plugins/known_marketplaces.json","plugins/marketplaces","plugins/claude-hud/config.json","claude-hud.json"]) walk(rel);
  process.stdout.write(hash.digest("hex")+":"+strict.digest("hex"));
} catch(e) { console.error("lane mirror fingerprint/copy: "+e.message); process.exit(4); }
' "${HOME}/.claude" "${1:-}" "${2:-}"
}

lane_seed_make_writable() {
  # Only mirrored directories need write permission for removal; never follow links.
  node -e '
const fs=require("fs"), path=require("path");
// ponytail: pathname lstat-then-chmod walk can race a concurrent non-cooperating replacement (Node has no portable fd-relative traversal), revisit under HIMMEL-4096 if mirror dirs become shared-writer.
function walk(p) {
  let s;
  try { s=fs.lstatSync(p); } catch(e) { if(e.code==="ENOENT") return; throw e; }
  if(!s.isDirectory()) return;
  fs.chmodSync(p,(s.mode&0o777)|0o200);
  for(const name of fs.readdirSync(p)) walk(path.join(p,name));
}
try { walk(process.argv[1]); }
catch(e) { console.error("lane mirror permissions: "+e.message); process.exit(4); }
' "$1"
}

seed_config_dir() {
  # Remove the completion marker FIRST; fingerprint and sentinel are written LAST.
  rm -f "${CONFIG_DIR:?}/.seeded" || seed_fail "clear the stale .seeded sentinel"
  SRC="${HOME}/.claude"
  seed_fingerprint="$(lane_seed_fingerprint)" || seed_fail "fingerprint the seed source"
  mkdir -p "$CONFIG_DIR/plugins" || seed_fail "create $CONFIG_DIR/plugins"
  if [ -f "$SRC/settings.json" ]; then
    sanitize_settings "$SRC/settings.json" "$CONFIG_DIR/settings.json" || seed_fail "sanitize settings.json (node missing/broken?)"
  else
    rm -f "${CONFIG_DIR:?}/settings.json" || seed_fail "remove stale settings.json"
  fi
  for f in CLAUDE.md RTK.md; do
    if [ -f "$SRC/$f" ]; then
      cp "$SRC/$f" "$CONFIG_DIR/$f" || seed_fail "copy $f"
    else
      rm -f "${CONFIG_DIR:?}/$f" || seed_fail "remove stale $f"
    fi
  done
  seed_after_leaves
  for d in commands skills hooks agents; do
    lane_seed_make_writable "${CONFIG_DIR:?}/$d" || seed_fail "make stale $d directories writable"
    rm -rf "${CONFIG_DIR:?}/$d" || seed_fail "clear stale $d"
    [ ! -d "$SRC/$d" ] || lane_seed_fingerprint "$d" "$CONFIG_DIR/$d" > /dev/null || seed_fail "copy $d"
  done
  for p in installed_plugins.json known_marketplaces.json; do
    if [ -f "$SRC/plugins/$p" ]; then
      cp "$SRC/plugins/$p" "$CONFIG_DIR/plugins/$p" || seed_fail "copy plugins/$p"
    else
      rm -f "${CONFIG_DIR:?}/plugins/$p" || seed_fail "remove stale plugins/$p"
    fi
  done
  lane_seed_make_writable "${CONFIG_DIR:?}/plugins/marketplaces" || seed_fail "make stale plugins/marketplaces directories writable"
  rm -rf "${CONFIG_DIR:?}/plugins/marketplaces" || seed_fail "clear stale plugins/marketplaces"
  [ ! -d "$SRC/plugins/marketplaces" ] || lane_seed_fingerprint plugins/marketplaces "$CONFIG_DIR/plugins/marketplaces" > /dev/null || seed_fail "copy plugins/marketplaces"
  if [ -f "$SRC/plugins/claude-hud/config.json" ]; then
    mkdir -p "$CONFIG_DIR/plugins/claude-hud" || seed_fail "create $CONFIG_DIR/plugins/claude-hud"
    cp "$SRC/plugins/claude-hud/config.json" "$CONFIG_DIR/plugins/claude-hud/config.json" || seed_fail "copy plugins/claude-hud/config.json"
  else
    rm -f "${CONFIG_DIR:?}/plugins/claude-hud/config.json" || seed_fail "remove stale plugins/claude-hud/config.json"
  fi
  if [ -f "$SRC/claude-hud.json" ]; then
    cp "$SRC/claude-hud.json" "$CONFIG_DIR/claude-hud.json" || seed_fail "copy claude-hud.json"
  else
    rm -f "${CONFIG_DIR:?}/claude-hud.json" || seed_fail "remove stale claude-hud.json"
  fi
  current_seed_fingerprint="$(lane_seed_fingerprint)" || seed_fail "fingerprint the copied source"
  [ "${current_seed_fingerprint#*:}" = "${seed_fingerprint#*:}" ] || seed_fail "mirror a source that changed during seeding; re-run"
  printf '%s\n' "$seed_fingerprint" > "$CONFIG_DIR/.seed-fingerprint" || seed_fail "write the seed fingerprint"
  seed_stamp > "$CONFIG_DIR/.seeded" || seed_fail "write the .seeded sentinel"
}

config_seed_stale() {
  # Codex generation/model migrations still precede the freshness opt-out.
  if [ "${SEED_STAMP_REQUIRED:-0}" = 1 ]; then
    [ "$(cat "$CONFIG_DIR/.seeded" 2>/dev/null)" = "$(seed_stamp)" ] || return 0
  fi
  [ "${CLAUDE_LANE_AUTO_RESEED:-1}" = 0 ] && return 1
  for s in settings.json CLAUDE.md RTK.md plugins/installed_plugins.json plugins/known_marketplaces.json plugins/claude-hud/config.json claude-hud.json; do
    if [ -f "${HOME}/.claude/$s" ]; then
      [ ! "${HOME}/.claude/$s" -nt "$CONFIG_DIR/.seeded" ] || return 0
    elif [ -f "$CONFIG_DIR/$s" ]; then
      return 0
    fi
  done
  for d in commands skills hooks agents plugins/marketplaces; do
    if [ -d "${HOME}/.claude/$d" ]; then
      [ -d "$CONFIG_DIR/$d" ] || return 0
    elif [ -d "$CONFIG_DIR/$d" ]; then
      return 0
    fi
  done
  current_seed_fingerprint="$(lane_seed_fingerprint)" || return 0
  [ "$current_seed_fingerprint" = "$(cat "$CONFIG_DIR/.seed-fingerprint" 2>/dev/null)" ] || return 0
  return 1
}

seed_process_start() {
  # /proc start ticks survive PID reuse; ps lstart is the macOS fallback.
  local process_stat process_start
  if [ -r "/proc/$1/stat" ]; then
    IFS= read -r process_stat < "/proc/$1/stat" || return 1
    process_stat="${process_stat##*) }"
    # shellcheck disable=SC2086 # Split the numeric /proc fields after removing the command name.
    set -- $process_stat
    [ "$#" -ge 20 ] || return 1
    shift 19
    printf 'linux:%s' "$1"
  else
    process_start="$(ps -p "$1" -o lstart= 2>/dev/null)" || return 1
    [ -n "$process_start" ] || return 1
    printf 'ps:%s' "$process_start"
  fi
}

seed_legacy_lock_stale() {
  echo "${SEED_LANE}: reclaiming legacy/unreadable seed lock $LOCK (age ${1}s)." >&2
}

lane_seed_lock_identity() {
  node -e '
const fs=require("fs");
try {
  const s=fs.lstatSync(process.argv[1],{bigint:true});
  if(!s.isDirectory() || s.ino===0n) process.exit(1);
  process.stdout.write(s.dev+":"+s.ino);
} catch(e) { process.exit(1); }
' "$LOCK"
}

lane_seed_retire_lock() {
  # Keep a non-empty destination named for the checked inode. Two contenders
  # delayed even after rechecking target the SAME destination; only one rename
  # can succeed. No pre-rename reservation can strand a lock after a crash.
  node -e '
const fs=require("fs"), path=require("path"), lock=process.argv[1], identity=process.argv[2];
try {
  if(!/^[0-9]+:[1-9][0-9]*$/.test(identity)) process.exit(1);
  const retired=lock+".stale."+identity.replace(":",".");
  const s=fs.lstatSync(lock,{bigint:true});
  if(!s.isDirectory() || s.dev+":"+s.ino!==identity) process.exit(1);
  // Populate empty legacy locks without overwriting a published owner.
  const owner=path.join(lock,"owner"); let planted;
  try {
    const fd=fs.openSync(owner,"wx");
    try { fs.writeFileSync(fd,"retired legacy seed lock\n"); planted=fs.fstatSync(fd,{bigint:true}); }
    finally { fs.closeSync(fd); }
  } catch(e) { if(e.code!=="EEXIST") throw e; }
  const checked=fs.lstatSync(lock,{bigint:true});
  if(!checked.isDirectory() || checked.dev+":"+checked.ino!==identity) {
    if(planted) {
      const current=fs.lstatSync(owner,{bigint:true});
      // ponytail: path-based lstat-then-unlink window (Node has no unlinkat); upgrade via HIMMEL-4093.
      if(current.dev===planted.dev && current.ino===planted.ino) fs.unlinkSync(owner);
    }
    process.exit(1);
  }
  fs.renameSync(lock,retired);
} catch(e) { process.exit(1); }
' "$LOCK" "$SEED_LOCK_IDENTITY"
}

seed_lock_is_stale() {
  SEED_LOCK_IDENTITY="$(lane_seed_lock_identity)" || return 1
  [ -d "$LOCK" ] || return 1
  local lock_mt lock_age owner_pid='' owner_start='' live_start
  lock_mt="$(stat -c %Y "$LOCK" 2>/dev/null || stat -f %m "$LOCK" 2>/dev/null)"
  [ -n "$lock_mt" ] || return 1
  lock_age=$(( $(date +%s) - lock_mt ))
  [ "$lock_age" -ge "$SEED_LOCK_STALE" ] || return 1
  # New locks publish ownership atomically; retain age-based legacy recovery.
  if [ ! -r "$LOCK/owner" ] || ! { IFS= read -r owner_pid; IFS= read -r owner_start; } 2>/dev/null < "$LOCK/owner"; then
    seed_legacy_lock_stale "$lock_age"
  else
    case "$owner_pid" in ''|*[!0-9]*|0) owner_pid='' ;; esac
    case "$owner_start" in linux:[0-9]*|ps:?*) ;; *) owner_pid='' ;; esac
    if [ -z "$owner_pid" ]; then
      seed_legacy_lock_stale "$lock_age"
    elif kill -0 "$owner_pid" 2>/dev/null; then
      live_start="$(seed_process_start "$owner_pid")" || return 1
      [ "$live_start" != "$owner_start" ] || return 1
    fi
  fi
  [ "$(lane_seed_lock_identity)" = "$SEED_LOCK_IDENTITY" ]
}

seed_release_lock() {
  [ "$(cat "$LOCK/owner" 2>/dev/null)" = "$SEED_LOCK_OWNER" ] || return 0
  rm -f "$LOCK/owner" || return 1
  rmdir "$LOCK"
}

lane_seed_publish_lock() {
  # Publish a populated directory atomically, never mv's directory nesting.
  node -e '
const fs=require("fs"), candidate=process.argv[1], lock=process.argv[2];
try {
  try { fs.lstatSync(lock); process.exit(1); } catch(e) { if(e.code!=="ENOENT") throw e; }
  fs.renameSync(candidate,lock);
} catch(e) { console.error("lane seed-lock publish: "+e.message); process.exit(1); }
' "$1" "$2"
}

seed_lock_cleanup() {
  seed_release_lock 2>/dev/null || true
  rm -f "$SEED_LOCK_CANDIDATE/owner" 2>/dev/null || true
  rmdir "$SEED_LOCK_CANDIDATE" 2>/dev/null || true
}

seed_with_lock() {
  local seed_lock_ticks seed_lock_max mkdir_err own_start
  own_start="$(seed_process_start "$$")" || seed_fail "read the seed-lock owner start time"
  SEED_LOCK_OWNER="$(printf '%s\n%s' "$$" "$own_start")"
  SEED_LOCK_CANDIDATE="$LOCK.pending.$$.$RANDOM.$RANDOM"
  trap 'seed_lock_cleanup' EXIT
  mkdir "$SEED_LOCK_CANDIDATE" || seed_fail "create the seed-lock candidate"
  printf '%s\n' "$SEED_LOCK_OWNER" > "$SEED_LOCK_CANDIDATE/owner" || seed_fail "record seed-lock ownership"
  seed_lock_ticks=0
  seed_lock_max=$(( SEED_LOCK_TIMEOUT * 2 ))
  while ! mkdir_err="$(lane_seed_publish_lock "$SEED_LOCK_CANDIDATE" "$LOCK" 2>&1)"; do
    if seed_lock_is_stale && lane_seed_retire_lock; then
      continue
    fi
    if [ "$seed_lock_ticks" -ge "$seed_lock_max" ]; then
      seed_fail "acquire config-dir seed lock ($LOCK): timed out after ${SEED_LOCK_TIMEOUT}s; last mkdir error: $mkdir_err"
    fi
    sleep 0.5
    seed_lock_ticks=$(( seed_lock_ticks + 1 ))
  done
  # The public lock already contains its owner; no mkdir/write crash window.
  if [ "$RESEED" -eq 1 ] || [ ! -f "$CONFIG_DIR/.seeded" ] || config_seed_stale; then
    seed_config_dir
  fi
  seed_after_mirror
  if ! seed_release_lock 2>/dev/null; then
    if [ "${SEED_LOCK_RELEASE_FATAL:-0}" = 1 ]; then seed_fail "release seed lock"; fi
    echo "${SEED_LANE}: WARNING - failed to release seed lock $LOCK (not empty or busy)." >&2
  fi
  trap - EXIT
}
