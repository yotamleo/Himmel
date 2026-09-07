#!/usr/bin/env bash
# test-wizard-luna-config.sh — hermetic tests for
# scripts/himmelctl/lib/luna-config.js (HIMMEL-2176 externalization Stage 1
# PR-B): the adopter's shared config document at ~/.himmel/config.json.
# Mirrors sibling test-wizard-*.sh suites: node launched by absolute path,
# winpath for node.exe's MSYS-path blindness, HIMMEL_LUNA_CONFIG_PATH
# (luna-config.js's own env-override seam, mirroring HIMMELCTL_CACHE_DIR in
# lib/state.js) so nothing ever touches the real ~/.himmel/config.json.
#
# Covers design §7 V7 (all four mandatory) + the console's validator ruling:
#   A. round-trip — save() then load() returns an equivalent document.
#   B. atomic-write interruption — a deterministic fs.renameSync failure
#      (monkey-patched, NOT a real signal) between the temp write and the
#      rename leaves the ORIGINAL file byte-identical, exactly ONE .bak
#      present, and (HIMMEL-2176 CR fix, codex-5) NO leftover .tmp-* file.
#   B2. atomic-write interruption, the WRITE itself — a deterministic
#      fs.writeFileSync failure (HIMMEL-2176 CR round 3, retask
#      stage1-build-6d2e: the write sat outside the cleanup handling B
#      landed) proves the same three properties for a failed write, not just
#      a failed rename.
#   B3. PARTIAL write interruption (HIMMEL-2176 CR round 9, retask
#      stage1-build-6d2e): writeFileSync actually CREATES the tmp file (a
#      real O_CREAT|O_EXCL success) and only then throws — distinct from B2,
#      whose stub throws before anything lands on disk. The old cleanup
#      flag was set true only after writeFileSync returned, so this exact
#      shape leaked the tmp file.
#   C. version:99 refusal — load() throws loudly naming the version, and the
#      file is byte-identical afterwards (load() never writes on any path).
#   D. malformed JSON refusal — the thrown error names the offending file
#      path.
#   E. validator: a valid fixture passes (zero errors); a deliberately
#      invalid fixture is rejected with a message naming the offending field.
#   F. symlink guard (HIMMEL-2176 CR round 5, retask stage1-build-6d2e): a
#      pre-existing symlink at the predictable `.tmp-<pid>` path must NOT be
#      followed — save() refuses, the original config and the symlink's
#      target both stay untouched. SKIPS with an explicit message (never a
#      silent pass) if this host can't create filesystem symlinks (observed:
#      EPERM on this Windows checkout without Developer Mode / the
#      SeCreateSymbolicLinkPrivilege).
#   G. stale temp file recovery (HIMMEL-2176 CR round 5, retask
#      stage1-build-6d2e): a plain leftover regular file already sitting at
#      the tmp path (simulating a previous crashed save() run, e.g. a reused
#      pid) must NOT permanently wedge save() with EEXIST — it is cleared and
#      the write retried once.
#   H. backup-before-prune (HIMMEL-2176 CR round 7, retask stage1-build-6d2e):
#      a deterministic fs.copyFileSync failure while backupExisting() is
#      taking the fresh backup must leave the PREVIOUS .bak intact and the
#      original config untouched — backupExisting() now creates the new .bak
#      before pruning older ones, so a failed copy can never destroy the last
#      good backup.
#   I. exactly ONE .bak survives a successful save (the steady-state case H's
#      failure path is contrasted against).
#   J. non-object parsed JSON (null, an array, a bare scalar) — all valid
#      JSON, none a valid config document — must produce this module's named,
#      file-identifying schema error from migrate(), not a raw TypeError.
#   K. backup-path symlink guard (HIMMEL-2176 CR round 11, retask
#      stage1-build-6d2e): a pre-existing symlink at the predictable backup
#      path (freshPath in backupExisting()) must NOT be followed — mirrors
#      case F, but for the backup path rather than the temp path. SKIPS with
#      an explicit message if this host can't create filesystem symlinks.
#   L. same-timestamp backup collision (HIMMEL-2176 CR round 11, retask
#      stage1-build-6d2e): two saves whose backup stamp collides against a
#      PLAIN regular file (not a symlink) must refresh that backup to the
#      pre-collision snapshot rather than erroring or silently keeping the
#      stale one — and must never leave zero (or more than one) .bak file.
#   M. same-timestamp collision whose REPLACEMENT copy fails (HIMMEL-2176 CR
#      round 12, retask stage1-build-6d2e): round 11's collision handling
#      unlinked the stale backup before retrying the copy at the same name —
#      if that retry failed, the adopter was left with ZERO backups. Proves
#      the round-12 fix (stage-then-rename) never reaches that state: the
#      pre-collision backup must survive a failed replacement copy intact.

set -euo pipefail

repo_root=$(git rev-parse --show-toplevel)
lib="$repo_root/scripts/himmelctl/lib/luna-config.js"
[ -f "$lib" ] || { echo "FAIL: $lib not found" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "FAIL: node required" >&2; exit 1; }

fail() { echo "FAIL: $1" >&2; exit 1; }

node_bin=$(command -v node)

# Templated mktemp with failure capture (HIMMEL-2176 brief / known-findings
# gate): a bare `mktemp -d` that fails leaves an empty var, and a later
# `rm -rf "$empty/..."` then targets the filesystem root.
work=$(mktemp -d "${TMPDIR:-/tmp}/luna-config-test.XXXXXX") || fail "mktemp -d failed"
cleanup() { rm -rf "$work"; }
trap cleanup EXIT
. "$repo_root/scripts/himmelctl/test/_hermetic-home.sh"  # HIMMEL-2350: shared winpath() -- dies loud on empty input/output instead of silently falling through to the operator's real home

lib_w="$(winpath "$lib")"

# ── Case A: round-trip — save() then load() returns an equivalent doc ──────
caseA_dir="$work/caseA"; mkdir -p "$caseA_dir"
cfgA="$caseA_dir/config.json"
cfgA_w="$(winpath "$cfgA")"

outA=$(HIMMEL_LUNA_CONFIG_PATH="$cfgA_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);
const d = lc.defaultConfig();
d.luna.vaultPath = '/example/vault';
d.bridge.enabled = true;
lc.save(d);
const loaded = lc.load();
console.log(JSON.stringify({ same: JSON.stringify(loaded) === JSON.stringify(d) }));
")
echo "$outA" | grep -q '"same":true' || fail "caseA: save()->load() should round-trip an equivalent document (got: $outA)"
[ -f "$cfgA" ] || fail "caseA: config.json should exist after save() (got: missing at $cfgA)"
echo "ok: caseA save()->load() round-trips an equivalent document"

# ── Case B: atomic-write interruption — deterministic renameSync failure ──
# Simulated by monkey-patching fs.renameSync (same require-cache singleton
# luna-config.js itself uses) to throw BEFORE it ever runs — deterministic,
# no reliance on real signal timing. Proves: (1) the ORIGINAL file survives
# byte-identical, (2) EXACTLY ONE .bak of the pre-interruption content is
# present, (3) (HIMMEL-2176 CR fix, codex-5) no PID-named .tmp-* file is left
# behind — renameSync used to sit OUTSIDE the cleanup handling, so a failed
# rename leaked the temp file.
caseB_dir="$work/caseB"; mkdir -p "$caseB_dir"
cfgB="$caseB_dir/config.json"
cfgB_w="$(winpath "$cfgB")"

outB=$(HIMMEL_LUNA_CONFIG_PATH="$cfgB_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

// Seed an original file (this is what must survive the interrupted save).
const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);
const before = fs.readFileSync(lc.configPath(), 'utf8');

// Interrupt: renameSync throws before the new content ever becomes visible
// at the real path — simulates a process kill in the temp-write->rename
// window without relying on real signal timing.
const origRename = fs.renameSync;
fs.renameSync = () => { throw new Error('simulated interruption (HIMMEL-2176 test)'); };
let threw = false;
try {
  const changed = lc.defaultConfig();
  changed.luna.vaultPath = '/should-not-land';
  lc.save(changed);
} catch (e) {
  threw = true;
}
fs.renameSync = origRename;

const after = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakCount = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).length;
const hasBak = bakCount > 0;
const hasTmp = fs.readdirSync(dir).some((f) => f.startsWith(base + '.tmp-'));

console.log(JSON.stringify({ threw, originalIntact: before === after, hasBak, bakCount, hasTmp }));
")
echo "$outB" | grep -q '"threw":true' || fail "caseB: interrupted save() should throw (got: $outB)"
echo "$outB" | grep -q '"originalIntact":true' || fail "caseB: the ORIGINAL file must survive byte-identical across an interrupted save (got: $outB)"
echo "$outB" | grep -q '"hasBak":true' || fail "caseB: a .bak must be present after an interrupted save (got: $outB)"
echo "$outB" | grep -q '"bakCount":1' || fail "caseB: exactly ONE .bak must remain after an interrupted save (got: $outB)"
echo "$outB" | grep -q '"hasTmp":false' || fail "caseB (HIMMEL-2176 CR fix, codex-5): a failed rename must not leave a PID-named .tmp-* file behind (got: $outB)"
echo "ok: caseB interrupted save() leaves the original intact with a .bak present"

# ── Case B2: atomic-write interruption — deterministic writeFileSync failure ─
# CR round 3 fix (HIMMEL-2176, retask stage1-build-6d2e): round 1 wrapped the
# RENAME in cleanup handling (case B above) but left the temp-file WRITE
# itself outside it — a failure mid-write (ENOSPC, permission-denied) still
# left a partial .tmp-<pid> file behind, contradicting save()'s own "cleaned
# up on any failure" contract. Same structure as case B, but monkey-patches
# fs.writeFileSync (not fs.renameSync) to throw BEFORE it ever writes a byte —
# deterministic, no reliance on real disk-full timing.
caseB2_dir="$work/caseB2"; mkdir -p "$caseB2_dir"
cfgB2="$caseB2_dir/config.json"
cfgB2_w="$(winpath "$cfgB2")"

outB2=$(HIMMEL_LUNA_CONFIG_PATH="$cfgB2_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

// Seed an original file (this is what must survive the interrupted save).
const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);
const before = fs.readFileSync(lc.configPath(), 'utf8');

// Interrupt: writeFileSync throws before the temp file is ever created —
// simulates ENOSPC/permission-denied mid-write.
const origWrite = fs.writeFileSync;
fs.writeFileSync = () => { throw new Error('simulated write failure (HIMMEL-2176 test)'); };
let threw = false;
try {
  const changed = lc.defaultConfig();
  changed.luna.vaultPath = '/should-not-land';
  lc.save(changed);
} catch (e) {
  threw = true;
}
fs.writeFileSync = origWrite;

const after = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakCount = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).length;
const hasBak = bakCount > 0;
const hasTmp = fs.readdirSync(dir).some((f) => f.startsWith(base + '.tmp-'));

console.log(JSON.stringify({ threw, originalIntact: before === after, hasBak, bakCount, hasTmp }));
")
echo "$outB2" | grep -q '"threw":true' || fail "caseB2: interrupted (write-failure) save() should throw (got: $outB2)"
echo "$outB2" | grep -q '"originalIntact":true' || fail "caseB2: the ORIGINAL file must survive byte-identical across an interrupted write (got: $outB2)"
echo "$outB2" | grep -q '"hasBak":true' || fail "caseB2: a .bak must be present after an interrupted write (got: $outB2)"
echo "$outB2" | grep -q '"bakCount":1' || fail "caseB2: exactly ONE .bak must remain after an interrupted write (got: $outB2)"
echo "$outB2" | grep -q '"hasTmp":false' || fail "caseB2 (HIMMEL-2176 CR round 3 fix): a failed WRITE must not leave a PID-named .tmp-* file behind (got: $outB2)"
echo "ok: caseB2 interrupted (write-failure) save() leaves the original intact with a .bak present, no leftover .tmp-*"

# ── Case B3: PARTIAL write interruption — writeFileSync creates the tmp file
# then throws (HIMMEL-2176 CR round 9, retask stage1-build-6d2e). Distinct
# from B2: B2's stub throws BEFORE anything is created (e.g. EACCES on the
# directory); this stub calls through to the REAL writeFileSync first (so the
# temp file genuinely exists on disk, mirroring O_CREAT|O_EXCL succeeding)
# and only then throws — the exact shape of an ENOSPC/I/O error mid-flush.
# save()'s old `tmpIsOurs` flag was set true only AFTER writeFileSync
# returned, so this shape slipped past the cleanup guard and leaked the tmp
# file; this case is RED against that code and GREEN after the round-9 fix.
caseB3_dir="$work/caseB3"; mkdir -p "$caseB3_dir"
cfgB3="$caseB3_dir/config.json"
cfgB3_w="$(winpath "$cfgB3")"

outB3=$(HIMMEL_LUNA_CONFIG_PATH="$cfgB3_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

// Seed an original file (this is what must survive the interrupted save).
const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);
const before = fs.readFileSync(lc.configPath(), 'utf8');

// Interrupt: the FIRST writeFileSync call actually creates the target file
// (a real, partial write landing on disk) and THEN throws — never reachable
// by a stub that throws pre-creation. Only the first call is intercepted so
// a save() that legitimately retries after clearing a stale file is not
// itself broken by this stub.
const origWrite = fs.writeFileSync;
let calls = 0;
fs.writeFileSync = (filePath, data, opts) => {
  calls += 1;
  if (calls === 1) {
    origWrite(filePath, 'PARTIAL-CONTENT-FROM-AN-INTERRUPTED-FLUSH', { flag: 'wx' });
    throw new Error('simulated partial write — ENOSPC mid-flush (HIMMEL-2176 test)');
  }
  return origWrite(filePath, data, opts);
};
let threw = false;
try {
  const changed = lc.defaultConfig();
  changed.luna.vaultPath = '/should-not-land';
  lc.save(changed);
} catch (e) {
  threw = true;
}
fs.writeFileSync = origWrite;

const after = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakCount = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).length;
const hasBak = bakCount > 0;
const hasTmp = fs.readdirSync(dir).some((f) => f.startsWith(base + '.tmp-'));

console.log(JSON.stringify({ threw, originalIntact: before === after, hasBak, bakCount, hasTmp }));
")
echo "$outB3" | grep -q '"threw":true' || fail "caseB3: interrupted (partial-write) save() should throw (got: $outB3)"
echo "$outB3" | grep -q '"originalIntact":true' || fail "caseB3: the ORIGINAL file must survive byte-identical across a partial write (got: $outB3)"
echo "$outB3" | grep -q '"hasBak":true' || fail "caseB3: a .bak must be present after a partial write (got: $outB3)"
echo "$outB3" | grep -q '"bakCount":1' || fail "caseB3: exactly ONE .bak must remain after a partial write (got: $outB3)"
echo "$outB3" | grep -q '"hasTmp":false' || fail "caseB3 (HIMMEL-2176 CR round 9 fix): a write that CREATES the tmp file then throws must not leak it — the old tmpIsOurs-gated cleanup missed exactly this case (got: $outB3)"
echo "ok: caseB3 a write that creates the tmp file and then throws (partial write) leaves the original intact, no leftover .tmp-*"

# ── Case C: version:99 refusal — loud throw, no write ──────────────────────
caseC_dir="$work/caseC"; mkdir -p "$caseC_dir"
cfgC="$caseC_dir/config.json"
cfgC_w="$(winpath "$cfgC")"
printf '{"version":99}' > "$cfgC"
before_hash=$(cksum "$cfgC")

outC=$(HIMMEL_LUNA_CONFIG_PATH="$cfgC_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);
try {
  lc.load();
  console.log(JSON.stringify({ threw: false }));
} catch (e) {
  console.log(JSON.stringify({ threw: true, message: e.message }));
}
")
echo "$outC" | grep -q '"threw":true' || fail "caseC: load() on version:99 should throw (got: $outC)"
echo "$outC" | grep -q '99' || fail "caseC: thrown error should name the offending version (got: $outC)"
after_hash=$(cksum "$cfgC")
[ "$before_hash" = "$after_hash" ] || fail "caseC: config.json must be byte-identical after a version:99 refusal"
echo "ok: caseC version:99 refuses loudly and writes nothing"

# ── Case D: malformed JSON refusal — error names the file path ────────────
caseD_dir="$work/caseD"; mkdir -p "$caseD_dir"
cfgD="$caseD_dir/config.json"
cfgD_w="$(winpath "$cfgD")"
printf '{not valid json' > "$cfgD"

outD=$(HIMMEL_LUNA_CONFIG_PATH="$cfgD_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);
try {
  lc.load();
  console.log(JSON.stringify({ threw: false }));
} catch (e) {
  console.log(JSON.stringify({ threw: true, namesPath: e.message.includes(lc.configPath()) }));
}
")
echo "$outD" | grep -q '"threw":true' || fail "caseD: load() on malformed JSON should throw (got: $outD)"
echo "$outD" | grep -q '"namesPath":true' || fail "caseD: thrown error should name the offending file path (got: $outD)"
echo "ok: caseD malformed JSON refusal names the offending file path"

# ── Case E: validator — valid fixture passes, invalid fixture names field ──
outE=$(HIMMEL_LUNA_CONFIG_PATH="$(winpath "$work/caseE-unused.json")" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const valid = lc.defaultConfig();
const validErrors = lc.validateConfig(valid);

const invalid = lc.defaultConfig();
invalid.luna.cadence.enabled = 'not-a-boolean';
const invalidErrors = lc.validateConfig(invalid);

console.log(JSON.stringify({
  validCount: validErrors.length,
  invalidCount: invalidErrors.length,
  namesField: invalidErrors.some((e) => e.includes('luna.cadence.enabled')),
}));
")
echo "$outE" | grep -q '"validCount":0' || fail "caseE: a valid fixture should validate with zero errors (got: $outE)"
echo "$outE" | grep -q '"invalidCount":0' && fail "caseE: a deliberately-invalid fixture should produce at least one error (got: $outE)"
echo "$outE" | grep -q '"namesField":true' || fail "caseE: the invalid-fixture error should name the offending field 'luna.cadence.enabled' (got: $outE)"
echo "ok: caseE validator passes a valid fixture and names the offending field on an invalid one"

# ── Case F: symlink guard — a pre-existing symlink at the tmp path must NOT
# be followed (HIMMEL-2176 CR round 5, retask stage1-build-6d2e). Skips
# loudly (not a silent pass) if this host can't create symlinks at all.
caseF_dir="$work/caseF"; mkdir -p "$caseF_dir"
cfgF="$caseF_dir/config.json"
cfgF_w="$(winpath "$cfgF")"

outF=$(HIMMEL_LUNA_CONFIG_PATH="$cfgF_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);
const beforeCfg = fs.readFileSync(lc.configPath(), 'utf8');

// A victim file elsewhere in the same dir — what a symlink at the
// predictable tmp path could redirect this write into.
const victim = path.join(path.dirname(lc.configPath()), 'victim.json');
fs.writeFileSync(victim, 'VICTIM-UNTOUCHED');

const tmpPath = lc.configPath() + '.tmp-' + process.pid;
let symlinkAvailable = true;
let symlinkErrCode = null;
try {
  fs.symlinkSync(victim, tmpPath, 'file');
} catch (e) {
  symlinkAvailable = false;
  symlinkErrCode = e.code;
}

if (!symlinkAvailable) {
  console.log(JSON.stringify({ skip: true, reason: symlinkErrCode }));
} else {
  let threw = false;
  try {
    const changed = lc.defaultConfig();
    changed.luna.vaultPath = '/should-not-land-via-symlink';
    lc.save(changed);
  } catch (e) {
    threw = true;
  }
  const afterCfg = fs.readFileSync(lc.configPath(), 'utf8');
  const victimContent = fs.readFileSync(victim, 'utf8');
  console.log(JSON.stringify({
    skip: false,
    threw,
    originalIntact: beforeCfg === afterCfg,
    victimUntouched: victimContent === 'VICTIM-UNTOUCHED',
  }));
}
")
if echo "$outF" | grep -q '"skip":true'; then
  echo "SKIP: caseF symlink guard — symlink creation unavailable on this host (got: $outF); cannot exercise the pre-existing-symlink-at-tmp-path guard"
else
  echo "$outF" | grep -q '"threw":true' || fail "caseF: save() must refuse to write through a pre-existing symlink at the tmp path (got: $outF)"
  echo "$outF" | grep -q '"originalIntact":true' || fail "caseF: the ORIGINAL config must survive untouched when the tmp path is a symlink (got: $outF)"
  echo "$outF" | grep -q '"victimUntouched":true' || fail "caseF: the symlink's target must NOT be overwritten — save() must not follow it (got: $outF)"
  echo "ok: caseF save() refuses a pre-existing symlink at the predictable tmp path rather than writing through it"
fi

# ── Case G: stale temp file recovery — a plain leftover regular file at the
# tmp path (simulating a previous crashed save() run) must not permanently
# wedge save() (HIMMEL-2176 CR round 5, retask stage1-build-6d2e). ─────────
caseG_dir="$work/caseG"; mkdir -p "$caseG_dir"
cfgG="$caseG_dir/config.json"
cfgG_w="$(winpath "$cfgG")"

outG=$(HIMMEL_LUNA_CONFIG_PATH="$cfgG_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);

// Simulate a leftover PID-named tmp file from a previous crashed save()
// (e.g. a reused pid) — a plain regular file, not a symlink.
const tmpPath = lc.configPath() + '.tmp-' + process.pid;
fs.writeFileSync(tmpPath, 'STALE-LEFTOVER-FROM-A-CRASHED-RUN');

let threw = false;
try {
  const changed = lc.defaultConfig();
  changed.luna.vaultPath = '/recovered-after-stale-tmp';
  lc.save(changed);
} catch (e) {
  threw = true;
}

const loaded = threw ? null : lc.load();
console.log(JSON.stringify({
  threw,
  recoveredVaultPath: loaded ? loaded.luna.vaultPath : null,
  tmpLeftBehind: fs.existsSync(tmpPath),
}));
")
echo "$outG" | grep -q '"threw":false' || fail "caseG: a stale regular tmp file from a previous crash must NOT permanently wedge save() (got: $outG)"
echo "$outG" | grep -q '"recoveredVaultPath":"/recovered-after-stale-tmp"' || fail "caseG: save() should succeed and the new value should land after clearing the stale tmp file (got: $outG)"
echo "$outG" | grep -q '"tmpLeftBehind":false' || fail "caseG: the stale tmp file must not be left behind after a successful recovery save() (got: $outG)"
echo "ok: caseG a stale regular leftover at the tmp path is cleared and retried, not a permanent wedge"

# ── Case H: backup-before-prune — a failed fs.copyFileSync during
# backupExisting() must leave the PREVIOUS .bak intact and the original
# config untouched (HIMMEL-2176 CR round 7, retask stage1-build-6d2e). ─────
caseH_dir="$work/caseH"; mkdir -p "$caseH_dir"
cfgH="$caseH_dir/config.json"
cfgH_w="$(winpath "$cfgH")"

outH=$(HIMMEL_LUNA_CONFIG_PATH="$cfgH_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

// First save creates config.json only (no prior file to back up yet).
const first = lc.defaultConfig();
first.luna.vaultPath = '/first/vault';
lc.save(first);

// Second save creates the first real .bak — this is the backup that must
// survive a copyFileSync failure on the NEXT save.
const second = lc.defaultConfig();
second.luna.vaultPath = '/second/vault';
lc.save(second);
const beforeCfg = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakNameBefore = fs.readdirSync(dir).find((f) => f.startsWith(base + '.bak-'));
const bakContentBefore = fs.readFileSync(path.join(dir, bakNameBefore), 'utf8');

// Interrupt: copyFileSync throws before the fresh backup is ever written —
// simulates ENOSPC/permission-denied/a locked file during backupExisting().
const origCopy = fs.copyFileSync;
fs.copyFileSync = () => { throw new Error('simulated backup failure (HIMMEL-2176 test)'); };
let threw = false;
try {
  const third = lc.defaultConfig();
  third.luna.vaultPath = '/should-not-land';
  lc.save(third);
} catch (e) {
  threw = true;
}
fs.copyFileSync = origCopy;

const afterCfg = fs.readFileSync(lc.configPath(), 'utf8');
const bakNameAfter = fs.readdirSync(dir).find((f) => f.startsWith(base + '.bak-'));
const bakContentAfter = bakNameAfter ? fs.readFileSync(path.join(dir, bakNameAfter), 'utf8') : null;
const bakCountAfter = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).length;

console.log(JSON.stringify({
  threw,
  originalIntact: beforeCfg === afterCfg,
  previousBakSurvived: bakContentBefore === bakContentAfter,
  bakCountAfter,
}));
")
echo "$outH" | grep -q '"threw":true' || fail "caseH: a failed backup copy should make save() throw (got: $outH)"
echo "$outH" | grep -q '"originalIntact":true' || fail "caseH: the config file must be untouched when backupExisting() fails (got: $outH)"
echo "$outH" | grep -q '"previousBakSurvived":true' || fail "caseH (HIMMEL-2176 CR round 7): a failed fs.copyFileSync during backup must NOT destroy the previous .bak (got: $outH)"
echo "$outH" | grep -q '"bakCountAfter":1' || fail "caseH: exactly ONE .bak (the previous one) must remain after a failed backup attempt (got: $outH)"
echo "ok: caseH a failed backup copy leaves the previous .bak and the original config intact"

# ── Case I: exactly ONE .bak survives a successful save (steady state) ─────
caseI_dir="$work/caseI"; mkdir -p "$caseI_dir"
cfgI="$caseI_dir/config.json"
cfgI_w="$(winpath "$cfgI")"

outI=$(HIMMEL_LUNA_CONFIG_PATH="$cfgI_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

lc.save(lc.defaultConfig());
const second = lc.defaultConfig();
second.luna.vaultPath = '/second/vault';
lc.save(second);
const third = lc.defaultConfig();
third.luna.vaultPath = '/third/vault';
lc.save(third);

const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakCount = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-')).length;
console.log(JSON.stringify({ bakCount }));
")
echo "$outI" | grep -q '"bakCount":1' || fail "caseI: exactly ONE .bak should remain after repeated successful saves (got: $outI)"
echo "ok: caseI exactly one .bak survives repeated successful saves"

# ── Case J: non-object parsed JSON — null, an array, a bare scalar — must
# raise this module's named schema error, not a raw TypeError (HIMMEL-2176
# CR round 7, retask stage1-build-6d2e). ────────────────────────────────────
for shape in null array scalar; do
  caseJ_dir="$work/caseJ-$shape"; mkdir -p "$caseJ_dir"
  cfgJ="$caseJ_dir/config.json"
  cfgJ_w="$(winpath "$cfgJ")"
  case "$shape" in
    null) printf 'null' > "$cfgJ" ;;
    array) printf '[1,2,3]' > "$cfgJ" ;;
    scalar) printf '42' > "$cfgJ" ;;
  esac

  outJ=$(HIMMEL_LUNA_CONFIG_PATH="$cfgJ_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);
try {
  lc.load();
  console.log(JSON.stringify({ threw: false }));
} catch (e) {
  console.log(JSON.stringify({
    threw: true,
    isTypeError: e instanceof TypeError,
    namesPath: e.message.includes(lc.configPath()),
  }));
}
")
  echo "$outJ" | grep -q '"threw":true' || fail "caseJ ($shape): load() on a non-object document should throw (got: $outJ)"
  echo "$outJ" | grep -q '"isTypeError":false' || fail "caseJ ($shape): the error must be this module's named schema error, not a raw TypeError (got: $outJ)"
  echo "$outJ" | grep -q '"namesPath":true' || fail "caseJ ($shape): thrown error should name the offending file path (got: $outJ)"
done
echo "ok: caseJ null/array/scalar JSON documents raise the module's named schema error, not a TypeError"

# ── Case K: backup-path symlink guard — a pre-existing symlink at the
# predictable backup path must NOT be followed (HIMMEL-2176 CR round 11,
# retask stage1-build-6d2e). Mirrors case F, but for backupExisting()'s
# freshPath rather than save()'s tmp path. The clock is frozen so the test
# knows the exact freshPath backupExisting() will compute, ahead of calling
# it, in order to plant the symlink there first. Skips loudly (never a
# silent pass) if this host can't create symlinks at all.
caseK_dir="$work/caseK"; mkdir -p "$caseK_dir"
cfgK="$caseK_dir/config.json"
cfgK_w="$(winpath "$cfgK")"

outK=$(HIMMEL_LUNA_CONFIG_PATH="$cfgK_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const RealDate = Date;
const FIXED_MS = 1700000000123;
global.Date = class extends RealDate {
  constructor() {
    if (arguments.length) { super(...arguments); } else { super(FIXED_MS); }
  }
  static now() { return FIXED_MS; }
};

const original = lc.defaultConfig();
original.luna.vaultPath = '/original/vault';
lc.save(original);
const beforeCfg = fs.readFileSync(lc.configPath(), 'utf8');

const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());

// A victim file elsewhere in the same dir — what a symlink at the
// predictable backup path could redirect backupExisting()'s copy into.
const victim = path.join(dir, 'victim.json');
fs.writeFileSync(victim, 'VICTIM-UNTOUCHED');

const stamp = new RealDate(FIXED_MS).toISOString().replace(/[:.]/g, '-');
const freshPath = path.join(dir, base + '.bak-' + stamp);

let symlinkAvailable = true;
let symlinkErrCode = null;
try {
  fs.symlinkSync(victim, freshPath, 'file');
} catch (e) {
  symlinkAvailable = false;
  symlinkErrCode = e.code;
}

if (!symlinkAvailable) {
  console.log(JSON.stringify({ skip: true, reason: symlinkErrCode }));
} else {
  let threw = false;
  try {
    const changed = lc.defaultConfig();
    changed.luna.vaultPath = '/should-not-land-via-backup-symlink';
    lc.save(changed);
  } catch (e) {
    threw = true;
  }
  const afterCfg = fs.readFileSync(lc.configPath(), 'utf8');
  const victimContent = fs.readFileSync(victim, 'utf8');
  console.log(JSON.stringify({
    skip: false,
    threw,
    originalIntact: beforeCfg === afterCfg,
    victimUntouched: victimContent === 'VICTIM-UNTOUCHED',
  }));
}
")
if echo "$outK" | grep -q '"skip":true'; then
  echo "SKIP: caseK backup symlink guard — symlink creation unavailable on this host (got: $outK); cannot exercise the pre-existing-symlink-at-backup-path guard"
else
  echo "$outK" | grep -q '"threw":true' || fail "caseK: save() must refuse to back up through a pre-existing symlink at the backup path (got: $outK)"
  echo "$outK" | grep -q '"originalIntact":true' || fail "caseK: the ORIGINAL config must survive untouched when the backup path is a symlink (got: $outK)"
  echo "$outK" | grep -q '"victimUntouched":true' || fail "caseK: the symlink's target must NOT be overwritten — backupExisting() must not follow it (got: $outK)"
  echo "ok: caseK save() refuses a pre-existing symlink at the predictable backup path rather than backing up through it"
fi

# ── Case L: same-timestamp backup collision — two saves whose backup stamp
# collides against a PLAIN regular file, not a symlink (HIMMEL-2176 CR round
# 11, retask stage1-build-6d2e). Now that backupExisting() refuses to
# overwrite via COPYFILE_EXCL, this collision must still resolve: the stale
# file at that name is removed and the copy retried, so the single surviving
# .bak is refreshed to the pre-collision snapshot rather than left stale,
# erroring, or (worst case) deleted with nothing put back. Clock frozen so
# both saves compute the identical stamp deterministically.
caseL_dir="$work/caseL"; mkdir -p "$caseL_dir"
cfgL="$caseL_dir/config.json"
cfgL_w="$(winpath "$cfgL")"

outL=$(HIMMEL_LUNA_CONFIG_PATH="$cfgL_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const RealDate = Date;
const FIXED_MS = 1700000000456;
global.Date = class extends RealDate {
  constructor() {
    if (arguments.length) { super(...arguments); } else { super(FIXED_MS); }
  }
  static now() { return FIXED_MS; }
};

// First save with the clock already frozen: no prior file exists yet, so
// backupExisting() is not invoked and no .bak is created.
const first = lc.defaultConfig();
first.luna.vaultPath = '/first/vault';
lc.save(first);

// Second save: p now holds the first save's content, so backupExisting()
// runs and creates the ONLY backup, at this frozen stamp, containing a copy
// of the first save's content.
const second = lc.defaultConfig();
second.luna.vaultPath = '/second/vault';
lc.save(second);

const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakNameMid = fs.readdirSync(dir).find((f) => f.startsWith(base + '.bak-'));

// Third save: STILL the same frozen stamp — backupExisting() now hits the
// exact freshPath a plain regular file (the previous backup, not a symlink)
// already occupies. p currently holds the second save's content, so a
// correctly-resolved collision refreshes that backup to the second save's
// content rather than leaving the stale first-save copy in place.
const third = lc.defaultConfig();
third.luna.vaultPath = '/third/vault';
lc.save(third);

const bakNamesAfter = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-'));
const afterDoc = JSON.parse(fs.readFileSync(path.join(dir, bakNamesAfter[0]), 'utf8'));

console.log(JSON.stringify({
  bakCount: bakNamesAfter.length,
  sameName: bakNamesAfter[0] === bakNameMid,
  refreshedToSecond: afterDoc.luna.vaultPath === '/second/vault',
}));
")
echo "$outL" | grep -q '"bakCount":1' || fail "caseL: a same-timestamp backup collision must never leave zero (or more than one) .bak file (got: $outL)"
echo "$outL" | grep -q '"sameName":true' || fail "caseL: the collided backup keeps the same predictable name (got: $outL)"
echo "$outL" | grep -q '"refreshedToSecond":true' || fail "caseL: a same-timestamp collision against a plain file must refresh the backup to the pre-collision snapshot, not silently keep the stale one (got: $outL)"
echo "ok: caseL a same-timestamp backup collision refreshes the single .bak rather than erroring or leaving zero backups"

# ── Case M: same-timestamp collision whose REPLACEMENT copy fails —
# HIMMEL-2176 CR round 12, retask stage1-build-6d2e. Round 11's collision
# handling unlinked the stale backup at freshPath BEFORE retrying the copy at
# that same name; if the retry then failed (ENOSPC, permissions, a transient
# I/O error), the adopter was left with ZERO backups — the exact defect round
# 7 already closed one layer up, reintroduced inside the EEXIST branch. Clock
# frozen so the mid-save backup and the failing third save compute the
# identical stamp deterministically, exactly like case L. The mock lets the
# FIRST copyFileSync call in the failing backupExisting() invocation run for
# real (so the collision's initial EEXIST occurs naturally against the real
# freshPath) and only fails the SECOND call — the collision-retry copy,
# wherever it targets — so the same test body reproduces the round-11 defect
# unmodified (RED) and proves the round-12 fix (GREEN) without hardcoding
# either version's staging-path naming.
caseM_dir="$work/caseM"; mkdir -p "$caseM_dir"
cfgM="$caseM_dir/config.json"
cfgM_w="$(winpath "$cfgM")"

outM=$(HIMMEL_LUNA_CONFIG_PATH="$cfgM_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const RealDate = Date;
const FIXED_MS = 1700000000789;
global.Date = class extends RealDate {
  constructor() {
    if (arguments.length) { super(...arguments); } else { super(FIXED_MS); }
  }
  static now() { return FIXED_MS; }
};

// First save: no prior file, backupExisting() not invoked.
const first = lc.defaultConfig();
first.luna.vaultPath = '/first/vault';
lc.save(first);

// Second save: creates the ONLY backup, at the frozen stamp, holding a copy
// of the first save's content — this is the backup that must survive a
// failed collision-retry copy on the NEXT save.
const second = lc.defaultConfig();
second.luna.vaultPath = '/second/vault';
lc.save(second);
const beforeCfg = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakNameBefore = fs.readdirSync(dir).find((f) => f.startsWith(base + '.bak-'));
const bakContentBefore = fs.readFileSync(path.join(dir, bakNameBefore), 'utf8');

// Third save: same frozen stamp, so backupExisting() hits the same-timestamp
// collision at freshPath. The first copyFileSync call is left alone (real
// EEXIST occurs naturally); the second call — the collision-retry copy — is
// made to fail regardless of its destination.
const origCopy = fs.copyFileSync;
let copyCalls = 0;
fs.copyFileSync = (src, dest, flags) => {
  copyCalls += 1;
  if (copyCalls === 2) {
    throw new Error('simulated replacement-copy failure (HIMMEL-2176 test)');
  }
  return origCopy(src, dest, flags);
};
let threw = false;
try {
  const third = lc.defaultConfig();
  third.luna.vaultPath = '/should-not-land';
  lc.save(third);
} catch (e) {
  threw = true;
}
fs.copyFileSync = origCopy;

const afterCfg = fs.readFileSync(lc.configPath(), 'utf8');
const bakNamesAfter = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-'));
const bakContentAfter = bakNamesAfter.length === 1 ? fs.readFileSync(path.join(dir, bakNamesAfter[0]), 'utf8') : null;

console.log(JSON.stringify({
  threw,
  originalIntact: beforeCfg === afterCfg,
  bakCountAfter: bakNamesAfter.length,
  previousBakSurvived: bakContentBefore === bakContentAfter,
}));
")
echo "$outM" | grep -q '"threw":true' || fail "caseM: a failed collision-retry copy should make save() throw (got: $outM)"
echo "$outM" | grep -q '"originalIntact":true' || fail "caseM: the config file must be untouched when the collision-retry copy fails (got: $outM)"
echo "$outM" | grep -q '"bakCountAfter":1' || fail "caseM (HIMMEL-2176 CR round 12): a failed collision-retry copy must NEVER leave zero backups (got: $outM)"
echo "$outM" | grep -q '"previousBakSurvived":true' || fail "caseM: the pre-collision backup must survive a failed collision-retry copy untouched (got: $outM)"
echo "ok: caseM a same-timestamp collision whose replacement copy fails leaves the pre-collision backup intact, never zero"

# ── Case N: staged-rename failure — deterministic renameSync failure during
# the collision-handling staged rename (HIMMEL-2176, retask stage1-build-6d2e).
# After the staged copy succeeds, backupExisting() renames the stage file to
# freshPath. If that rename fails (locked destination, permissions, transient
# I/O), the staging file must be cleaned up — never left behind — while the
# pre-existing backup must survive intact. The mock intercepts the RENAME
# (distinct from M's copyFileSync interception) to fail deterministically on
# the second renameSync call — the first one being save()'s own temp->real
# rename, which we allow to succeed so the test focus stays on the backup's
# staged rename.
caseN_dir="$work/caseN"; mkdir -p "$caseN_dir"
cfgN="$caseN_dir/config.json"
cfgN_w="$(winpath "$cfgN")"

outN=$(HIMMEL_LUNA_CONFIG_PATH="$cfgN_w" HIMMEL_LUNA_CONFIG_LIB="$lib_w" "$node_bin" -e "
const fs = require('fs');
const path = require('path');
const lc = require(process.env.HIMMEL_LUNA_CONFIG_LIB);

const RealDate = Date;
const FIXED_MS = 1700000001000;
global.Date = class extends RealDate {
  constructor() {
    if (arguments.length) { super(...arguments); } else { super(FIXED_MS); }
  }
  static now() { return FIXED_MS; }
};

// First save: no prior file, backupExisting() not invoked.
const first = lc.defaultConfig();
first.luna.vaultPath = '/first/vault';
lc.save(first);

// Second save: creates the ONLY backup, at the frozen stamp, holding a copy
// of the first save's content — this is the backup that must survive a
// failed staged rename on the NEXT save.
const second = lc.defaultConfig();
second.luna.vaultPath = '/second/vault';
lc.save(second);
const beforeCfg = fs.readFileSync(lc.configPath(), 'utf8');
const dir = path.dirname(lc.configPath());
const base = path.basename(lc.configPath());
const bakNameBefore = fs.readdirSync(dir).find((f) => f.startsWith(base + '.bak-'));
const bakContentBefore = fs.readFileSync(path.join(dir, bakNameBefore), 'utf8');

// Third save: same frozen stamp, so backupExisting() hits the same-timestamp
// collision at freshPath. The staged copy will succeed, but the staged rename
// from stagePath to freshPath is made to fail. We identify it by checking if
// src contains '.stage-' to avoid interfering with save()'s own temp-to-real
// rename (which also uses renameSync).
const origRename = fs.renameSync;
fs.renameSync = (src, dest) => {
  if (src.includes('.stage-')) {
    throw new Error('simulated staged-rename failure (HIMMEL-2176 test)');
  }
  return origRename(src, dest);
};
let threw = false;
try {
  const third = lc.defaultConfig();
  third.luna.vaultPath = '/should-not-land';
  lc.save(third);
} catch (e) {
  threw = true;
}
fs.renameSync = origRename;

const afterCfg = fs.readFileSync(lc.configPath(), 'utf8');
const stageFiles = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-') && f.includes('.stage-'));
const bakNamesAfter = fs.readdirSync(dir).filter((f) => f.startsWith(base + '.bak-') && !f.includes('.stage-'));
const bakContentAfter = bakNamesAfter.length === 1 ? fs.readFileSync(path.join(dir, bakNamesAfter[0]), 'utf8') : null;

console.log(JSON.stringify({
  threw,
  originalIntact: beforeCfg === afterCfg,
  stageFilesLeft: stageFiles.length,
  bakCountAfter: bakNamesAfter.length,
  previousBakSurvived: bakContentBefore === bakContentAfter,
}));
")
echo "$outN" | grep -q '"threw":true' || fail "caseN: a failed staged rename should make save() throw (got: $outN)"
echo "$outN" | grep -q '"originalIntact":true' || fail "caseN: the config file must be untouched when the staged rename fails (got: $outN)"
echo "$outN" | grep -q '"stageFilesLeft":0' || fail "caseN (HIMMEL-2176, retask stage1-build-6d2e): a failed staged rename must not leave a .stage-* file behind (got: $outN)"
echo "$outN" | grep -q '"bakCountAfter":1' || fail "caseN: exactly ONE .bak must remain after a failed staged rename (got: $outN)"
echo "$outN" | grep -q '"previousBakSurvived":true' || fail "caseN: the pre-collision backup must survive a failed staged rename untouched (got: $outN)"
echo "ok: caseN a failed staged-rename during backup collision cleanup leaves no .stage-* artifact and the pre-existing backup intact"

echo "PASS"
