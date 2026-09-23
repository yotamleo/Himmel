'use strict';
// scripts/himmelctl/lib/standalone-bundle.js — writes the standalone
// uninstall bundle beside the provenance ledger (HIMMEL-3312 S13 item 3,
// design HIMMEL-3312-standalone-undo.md §3). himmelctl copies the uninstall
// closure into ${HIMMEL_PROVENANCE_DIR:-~/.himmel}/uninstall/ wherever it
// writes the PATH launcher, so the launcher can fall back to it once the
// clone is gone. BUNDLE_MARKER matches the bash constant in
// scripts/lib/provenance.sh (S12) byte for byte — this module can't
// `require` a .sh file, so the string is duplicated, not shared.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const provLib = require('./provenance.js');

const BUNDLE_MARKER = 'himmel-standalone-uninstaller/1';

// design §3.2's closure (15 files, ~347 KB) plus the S13 node entry.
const BUNDLE_FILES_POSIX = [
  'scripts/uninstall.sh',
  'scripts/install/uninstall-manifest.tsv',
  'scripts/lib/provenance-read.sh',
  'scripts/lib/provenance.sh',
  'scripts/lib/canon-path.sh',
  'scripts/lib/qmd-bin.sh',
  'scripts/lib/unwire-statusline.sh',
  'scripts/lib/unwire-himmel-repo.sh',
  'scripts/lib/unwire-luna-vault.sh',
  'scripts/lib/unwire-handover-dir.sh',
  'scripts/lib/unwire-pretooluse-hooks.sh',
  'scripts/lib/unwire-hud-config.sh',
  'scripts/lib/unwire-user-claude-md.sh',
  'scripts/machine-setup/uninstall-plugins.sh',
  'docs/setup/settings-template.json',
  'scripts/himmelctl/standalone.js',
  'scripts/himmelctl/lib/uninstall-wrapper.js',
  'scripts/himmelctl/lib/launcher.js',
  'scripts/himmelctl/lib/helpers.js',
  // lib/launcher.js `require`s provenance.js unconditionally (for ledgerDir()
  // et al) — not named by design §3.2's node-entry list, but a hard
  // transitive dependency: without it the bundle's own standalone.js dies on
  // MODULE_NOT_FOUND the same way bin.js does without the clone.
  'scripts/himmelctl/lib/provenance.js',
  'VERSION',
];

// design §8: the .ps1 twin's own closure (S14 extends this). Exported now
// per the plan so the list has one home, even though S13 never writes a
// win32 bundle (Q2: POSIX only).
const BUNDLE_FILES_WIN32 = [
  'scripts/uninstall.ps1',
  'scripts/machine-setup/uninstall-plugins.ps1',
  'docs/setup/settings-template.json',
  'scripts/himmelctl/standalone.js',
  'scripts/himmelctl/lib/uninstall-wrapper.js',
  'scripts/himmelctl/lib/launcher.js',
  'scripts/himmelctl/lib/helpers.js',
  'scripts/himmelctl/lib/provenance.js',
  'VERSION',
];

function bundleDir() {
  return path.join(provLib.ledgerDir(), 'uninstall');
}

// design §3.1's tree mirrors repo-relative paths EXCEPT scripts/himmelctl/,
// which mounts at the bundle root (so the copied standalone.js sits at
// <bundle>/standalone.js, matching the launcher's `path.join(bundleDir(),
// 'standalone.js')`, and its own `require('./lib/...')` calls resolve
// against <bundle>/lib/ unchanged).
const HIMMELCTL_PREFIX = 'scripts/himmelctl/';
function destRel(rel) {
  return rel.startsWith(HIMMELCTL_PREFIX) ? rel.slice(HIMMELCTL_PREFIX.length) : rel;
}

function warn(msg) {
  console.error(`himmelctl: WARN: ${msg}`);
}

function shimPlatform() {
  return process.env.HIMMELCTL_SHIM_PLATFORM || process.platform;
}

function readMarker(dir) {
  try {
    const raw = fs.readFileSync(path.join(dir, 'bundle.json'), 'utf8');
    return JSON.parse(raw);
  } catch (_e) {
    return null;
  }
}

// Semver compare (a, b are "x.y.z" strings): -1/0/1, matching Array.sort's
// comparator contract. No pre-release/build-metadata handling — himmel's own
// VERSION file has never carried either.
function semverCompare(a, b) {
  const pa = String(a || '0.0.0').split('.').map((n) => parseInt(n, 10) || 0);
  const pb = String(b || '0.0.0').split('.').map((n) => parseInt(n, 10) || 0);
  for (let i = 0; i < 3; i++) {
    if (pa[i] !== pb[i]) return pa[i] < pb[i] ? -1 : 1;
  }
  return 0;
}

function readVersion(repoRoot) {
  try {
    return fs.readFileSync(path.join(repoRoot, 'VERSION'), 'utf8').replace(/[ \r\n]/g, '');
  } catch (_e) {
    return '';
  }
}

function gitHead(repoRoot) {
  const g = spawnSync('git', ['-C', repoRoot, 'rev-parse', 'HEAD'], { encoding: 'utf8' });
  return (!g.error && g.status === 0) ? g.stdout.trim() : null;
}

// A marked sibling younger than this is assumed to be a concurrent write
// still between its bundle.json write and its swap rename, not an orphan
// from a crash -- sweeping it out from under that write would turn its
// rename(stage, dir) into an ENOENT. A few seconds covers the swap; minutes
// covers everything short of a genuinely stuck process, which the NEXT
// write's sweep will still catch once it ages past this window.
const STALE_SIBLING_MIN_AGE_MS = 5 * 60 * 1000;

// Best-effort removal of stale staging/backup siblings from a crashed prior
// write (design §3.3 step 5: "the next write sweeps any it finds that carry
// our marker"). A .uninstall.tmp-* that never reached the bundle.json write
// carries no marker and is left alone — it might be a concurrent write in
// flight, and this function is best-effort by design, never a hard failure.
function sweepStaleSiblings(parent, ownPid) {
  let entries;
  try {
    entries = fs.readdirSync(parent);
  } catch (_e) {
    return;
  }
  for (const name of entries) {
    const m = /^\.uninstall\.(tmp|old)-(\d+)$/.exec(name);
    if (!m || m[2] === String(ownPid)) continue;
    const full = path.join(parent, name);
    const meta = readMarker(full);
    if (!meta || meta.marker !== BUNDLE_MARKER) continue;
    try {
      const st = fs.statSync(full);
      if (Date.now() - st.mtimeMs < STALE_SIBLING_MIN_AGE_MS) continue;
    } catch (_e) {
      continue;
    }
    try {
      fs.rmSync(full, { recursive: true, force: true });
    } catch (e) {
      warn(`could not remove stale bundle sibling ${full} (${e.message})`);
    }
  }
}

// Copies the uninstall closure into bundleDir(), refreshed on every launcher
// write (design §3.3). Refuses to clobber anything not ours; refuses to
// downgrade; stages then atomically swaps; records exactly one `tree` row
// per call. Best-effort: returns false and WARNs on any failure, never
// throws — the launcher write must proceed regardless (design §3.3: "never
// fails install or update").
function writeStandaloneBundle(repoRoot) {
  const dir = bundleDir();
  const parent = path.dirname(dir);
  const platform = shimPlatform();
  const files = platform === 'win32' ? BUNDLE_FILES_WIN32 : BUNDLE_FILES_POSIX;

  // 1. Refuse to touch anything that isn't ours: a symlink, a dir owned by
  // someone else, or a dir without a matching bundle.json marker. Same rule
  // as writeMarkedLauncher (lib/launcher.js).
  let st = null;
  try {
    st = fs.lstatSync(dir);
  } catch (e) {
    if (e.code !== 'ENOENT') { warn(`cannot stat ${dir} (${e.message})`); return false; }
  }
  let oldMeta = null;
  if (st) {
    if (st.isSymbolicLink()) {
      warn(`refusing to write standalone uninstaller bundle: ${dir} is a symlink (remove it first if you want himmelctl to manage it)`);
      return false;
    }
    if (process.platform !== 'win32' && typeof process.getuid === 'function' && st.uid !== process.getuid()) {
      warn(`refusing to write standalone uninstaller bundle: ${dir} is not owned by the current user`);
      return false;
    }
    oldMeta = readMarker(dir);
    if (!oldMeta || oldMeta.marker !== BUNDLE_MARKER) {
      warn(`refusing to overwrite ${dir} (not a himmelctl-managed bundle — move it aside first)`);
      return false;
    }
  }

  // 2. Never downgrade (design §6): a higher bundle_format, or an equal
  // bundle_format with a higher semver VERSION, is left in place.
  const incomingVersion = readVersion(repoRoot);
  const incomingFormat = 1;
  if (oldMeta) {
    const oldFormat = oldMeta.bundle_format || 0;
    if (oldFormat > incomingFormat || (oldFormat === incomingFormat && semverCompare(oldMeta.version, incomingVersion) > 0)) {
      warn(`standalone uninstaller ${oldMeta.version} is newer than this checkout ${incomingVersion || '(unknown)'}; left in place`);
      try {
        provLib.provRecord(['noop', 'tree', dir, '--scope', 'user', '--class', 'state',
          '--row', 'standalone-uninstaller', '--post-file', path.join(dir, 'bundle.json')]);
      } catch (e) { warn(`provenance ledger not updated (${e.message})`); }
      return false;
    }
  }

  // 3. Stage into a sibling tmp dir; 0700/0600 explicit, not left to umask.
  // A listed file missing from repoRoot aborts the write; a partial bundle
  // is never installed.
  const stage = path.join(parent, `.uninstall.tmp-${process.pid}`);
  try {
    fs.rmSync(stage, { recursive: true, force: true });
    fs.mkdirSync(stage, { recursive: true, mode: 0o700 });
    fs.chmodSync(stage, 0o700);
    for (const rel of files) {
      const src = path.join(repoRoot, rel);
      const dest = path.join(stage, destRel(rel));
      fs.mkdirSync(path.dirname(dest), { recursive: true, mode: 0o700 });
      fs.copyFileSync(src, dest);
      fs.chmodSync(dest, 0o600);
    }
  } catch (e) {
    try { fs.rmSync(stage, { recursive: true, force: true }); } catch (_e) { /* best-effort */ }
    warn(`failed to stage standalone uninstaller bundle (${e.message})`);
    return false;
  }

  // 4. bundle.json written LAST, inside the stage.
  const meta = {
    marker: BUNDLE_MARKER,
    bundle_format: incomingFormat,
    version: incomingVersion,
    himmel_head: gitHead(repoRoot),
    himmel_root: repoRoot,
    platform,
    files,
    written: new Date().toISOString(),
  };
  const bundleJsonPath = path.join(stage, 'bundle.json');
  try {
    fs.writeFileSync(bundleJsonPath, JSON.stringify(meta, null, 2) + '\n', { mode: 0o600 });
    fs.chmodSync(bundleJsonPath, 0o600);
  } catch (e) {
    try { fs.rmSync(stage, { recursive: true, force: true }); } catch (_e) { /* best-effort */ }
    warn(`failed to write bundle.json (${e.message})`);
    return false;
  }

  // 5. Swap: rename(2) won't replace a non-empty dir, hence two renames.
  const oldDirBackup = path.join(parent, `.uninstall.old-${process.pid}`);
  let movedOldAside = false;
  try {
    if (st) { fs.renameSync(dir, oldDirBackup); movedOldAside = true; }
    fs.renameSync(stage, dir);
    if (st) fs.rmSync(oldDirBackup, { recursive: true, force: true });
  } catch (e) {
    // The stage->dir rename can fail after the old bundle was already moved
    // aside; restore it so the launcher fallback still has a bundle.
    if (movedOldAside) {
      try { fs.renameSync(oldDirBackup, dir); } catch (_e) { /* best-effort */ }
    }
    warn(`failed to install standalone uninstaller bundle (${e.message})`);
    return false;
  }
  sweepStaleSiblings(parent, process.pid);

  // 6. Exactly one `tree` row per writing session, never one per file.
  try {
    if (oldMeta) {
      provLib.provRecord(['replace', 'tree', dir, '--pre-text', JSON.stringify(oldMeta),
        '--post-file', bundleJsonPath.replace(stage, dir), '--scope', 'user', '--class', 'state',
        '--row', 'standalone-uninstaller']);
    } else {
      provLib.provRecord(['create', 'tree', dir, '--pre-absent',
        '--post-file', path.join(dir, 'bundle.json'), '--scope', 'user', '--class', 'state',
        '--row', 'standalone-uninstaller']);
    }
  } catch (e) { warn(`provenance ledger not updated (${e.message})`); }

  return true;
}

module.exports = {
  BUNDLE_MARKER,
  BUNDLE_FILES_POSIX,
  BUNDLE_FILES_WIN32,
  bundleDir,
  writeStandaloneBundle,
};
