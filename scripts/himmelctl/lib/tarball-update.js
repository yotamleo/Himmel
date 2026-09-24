'use strict';
// tarball-update.js — the release tarball's versioned layout and its update
// (HIMMEL-3059 S4; design HIMMEL-3059-linux-packaging.md §1.4).
//
// Layout: every release is extracted into <base>/<version>/ and
// <base>/current is a relative symlink to the live one. Wiring (env.HIMMEL_REPO,
// hook commands, the PATH launcher) names <base>/current, so an update is one
// atomic link swap: a file the new release deleted cannot survive, rollback is
// repointing the link, and removal is one directory.
//
// Update: release lookup (scripts/lib/release-check.sh — the same fixed URL,
// grammar check and version compare the session nudge uses) -> download the
// tarball + .sha256 into a staging dir under <base> -> verify the sha256 (and,
// when `gh` is present and authenticated, the build attestation) -> extract ->
// check the top dir is himmel-<version>/ -> rename into <base>/<version> ->
// swap <base>/current. Any failure before the swap leaves current untouched and
// removes the staging dir; nothing is extracted into <base> until the verify
// has passed. A git clone never reaches this file: versionedLayout() is null
// for any root with a .git.
//
// ponytail: previous version dirs are kept, never pruned — rollback needs the
// last one and nothing here can tell which older ones the operator still wants;
// the update prints the rm line. Upgrade path: prune all but current + previous
// once an operator asks for it.

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');
const { spawnSync } = require('child_process');

// Fixed, never read from the environment (release-check.sh's integrity note).
const RELEASE_DOWNLOAD_BASE = 'https://github.com/yotamleo/Himmel/releases/download';
const RELEASE_REPO = 'yotamleo/Himmel';
// release-check.sh release_tag_parts' grammar, without the leading v.
const VERSION_RE = /^[0-9]{1,9}\.[0-9]{1,9}\.[0-9]{1,9}(-pre\.[0-9]{1,9})?$/;

// { base, current, dir } when <root> is a release tree in the versioned layout
// (no .git, and <root>/../current is a symlink to the same directory), else
// null. Accepts either spelling of the root: the versioned dir (Node realpaths
// a main module's __dirname) or the current link itself.
function versionedLayout(root) {
  if (fs.existsSync(path.join(root, '.git'))) return null;
  const base = path.dirname(root);
  const current = path.join(base, 'current');
  try {
    if (!fs.lstatSync(current).isSymbolicLink()) return null;
    const a = fs.statSync(current);
    const b = fs.statSync(root);
    if (a.dev !== b.dev || a.ino !== b.ino) return null;
    return { base, current, dir: fs.realpathSync(current) };
  } catch (_e) {
    return null;
  }
}

// The live version: the name of the dir current points at (the release tag's
// version — a -pre.N tarball's VERSION file carries only X.Y.Z), else VERSION.
function installedVersion(layout) {
  const name = path.basename(layout.dir);
  if (VERSION_RE.test(name)) return name;
  try {
    const v = fs.readFileSync(path.join(layout.dir, 'VERSION'), 'utf8').split('\n')[0].trim().replace(/^v/, '');
    return VERSION_RE.test(v) ? v : null;
  } catch (_e) {
    return null;
  }
}

// One release lookup + compare through release-check.sh. Returns
// { state: 'newer'|'current'|'none'|'failed', tag, reason }.
function lookupLatest(bash, releaseCheck, installed) {
  const script = [
    '. "$1" || exit 9',
    'rc=0; release_fetch_latest || rc=$?',
    'if [ "$rc" -ne 0 ]; then printf "%s\\n" "${RELEASE_FAIL_REASON:-}"; exit "$rc"; fi',
    'printf "%s\\n" "$RELEASE_LATEST_TAG"',
    'if release_is_older "$2" "$RELEASE_LATEST_TAG"; then exit 0; fi',
    'exit 4',
  ].join('\n');
  const r = spawnSync(bash, ['-c', script, 'release-check', releaseCheck, installed], { encoding: 'utf8' });
  const line = (r.stdout || '').split('\n')[0].trim();
  if (r.error) return { state: 'failed', reason: r.error.message };
  if (r.status === 0 || r.status === 4) {
    if (!VERSION_RE.test(line.replace(/^v/, ''))) return { state: 'failed', reason: 'bad-response' };
    return { state: r.status === 0 ? 'newer' : 'current', tag: line };
  }
  if (r.status === 3) return { state: 'none' };
  if (r.status === 9) return { state: 'failed', reason: `${releaseCheck} could not be loaded` };
  return { state: 'failed', reason: line || `release lookup exited ${r.status}` };
}

function download(url, dest) {
  // -q first: no ~/.curlrc (release-check.sh). https pinned across redirects.
  const r = spawnSync('curl', ['-q', '-fsSL', '--proto', '=https', '--proto-redir', '=https',
    '--max-redirs', '5', '--max-time', '600', '-o', dest, url], { stdio: ['ignore', 'ignore', 'inherit'] });
  if (r.error) throw new Error(`curl: ${r.error.code === 'ENOENT' ? 'not installed' : r.error.message}`);
  if (r.status !== 0) throw new Error(`download of ${url} failed (curl exit ${r.status})`);
}

// Throws unless <tarball> matches the one sha256sum-format line in <shaFile>
// naming <name>.
function verifySha256(tarball, shaFile, name) {
  const m = /^([0-9a-f]{64}) [ *](\S+)\s*$/.exec(fs.readFileSync(shaFile, 'utf8').split('\n')[0]);
  if (!m || m[2] !== name) throw new Error(`checksum file does not name ${name}`);
  const actual = crypto.createHash('sha256').update(fs.readFileSync(tarball)).digest('hex');
  if (actual !== m[1]) throw new Error(`checksum mismatch for ${name}: published ${m[1]}, downloaded ${actual}`);
}

// 'verified' | 'skipped (<why>)'; throws when gh ran the check and it failed.
function verifyAttestation(tarball) {
  const auth = spawnSync('gh', ['auth', 'status'], { stdio: 'ignore' });
  if (auth.error) return 'skipped (gh not installed)';
  if (auth.status !== 0) return 'skipped (gh not authenticated)';
  const r = spawnSync('gh', ['attestation', 'verify', tarball, '-R', RELEASE_REPO], { stdio: ['ignore', 'ignore', 'inherit'] });
  if (r.error || r.status !== 0) throw new Error(`gh attestation verify failed for ${path.basename(tarball)}`);
  return 'verified';
}

// Download, verify, extract and swap. <opts>: { bash, releaseCheck, log, err }.
// Returns the exit code.
function updateVersioned(layout, opts) {
  const { log, err } = opts;
  const installed = installedVersion(layout);
  if (!installed) {
    err(`himmelctl: update: cannot tell which release ${layout.dir} is (neither its directory name nor its VERSION file is a release version) — nothing was changed`);
    return 1;
  }
  log(`install:  ${layout.base} (versioned; current -> ${path.basename(layout.dir)})`);
  const latest = lookupLatest(opts.bash, opts.releaseCheck, installed);
  if (latest.state === 'none') { log('status:   no release has been published yet — nothing to update to'); return 0; }
  if (latest.state === 'failed') {
    err(`himmelctl: update: could not check for a newer release (${latest.reason}) — nothing was changed`);
    return 1;
  }
  if (latest.state === 'current') { log(`status:   up to date (${installed}; latest release ${latest.tag})`); return 0; }

  const version = latest.tag.replace(/^v/, '');
  const target = path.join(layout.base, version);
  if (fs.existsSync(target) || isSymlink(target)) {
    err(`himmelctl: update: ${target} already exists but current points at ${path.basename(layout.dir)} — nothing was changed.`);
    err(`  To switch to it: ln -sfn ${version} ${layout.current}   To re-download it: remove ${target} and re-run.`);
    return 1;
  }
  const name = `himmel-${version}-linux.tar.gz`;
  const url = `${RELEASE_DOWNLOAD_BASE}/${latest.tag}/${name}`;
  log(`update:   ${installed} -> ${version}`);
  let stage;
  try {
    // Staged under <base> so the final rename stays on one filesystem.
    stage = fs.mkdtempSync(path.join(layout.base, '.update-'));
    const tarball = path.join(stage, name);
    download(url, tarball);
    download(`${url}.sha256`, `${tarball}.sha256`);
    verifySha256(tarball, `${tarball}.sha256`, name);
    log('verify:   sha256 ok');
    log(`verify:   attestation ${verifyAttestation(tarball)}`);
    const x = path.join(stage, 'x');
    fs.mkdirSync(x);
    const t = spawnSync('tar', ['-xzf', tarball, '-C', x], { stdio: ['ignore', 'ignore', 'inherit'] });
    if (t.error || t.status !== 0) throw new Error(`extracting ${name} failed`);
    const top = fs.readdirSync(x);
    const tree = path.join(x, `himmel-${version}`);
    if (top.length !== 1 || top[0] !== `himmel-${version}` || !fs.existsSync(path.join(tree, 'scripts', 'himmelctl', 'bin.js'))) {
      throw new Error(`${name} is not a himmel release tree (top level: ${top.join(', ') || 'empty'})`);
    }
    fs.renameSync(tree, target);
    try {
      swapCurrent(layout, version);
    } catch (e) {
      fs.rmSync(target, { recursive: true, force: true });
      throw e;
    }
  } catch (e) {
    err(`himmelctl: update: ${e.message} — nothing was extracted into ${layout.base}; current still points at ${path.basename(layout.dir)}`);
    return 1;
  } finally {
    if (stage) fs.rmSync(stage, { recursive: true, force: true });
  }
  const prev = path.basename(layout.dir);
  log(`updated:  current -> ${version}`);
  log(`          ${path.join(layout.base, prev)} is kept for rollback: ln -sfn ${prev} ${layout.current}`);
  log(`          once you no longer need it: rm -rf ${path.join(layout.base, prev)}`);
  log('          re-run `himmelctl install` to apply any wiring the new release adds');
  return 0;
}

function isSymlink(p) {
  try { return fs.lstatSync(p).isSymbolicLink(); } catch (_e) { return false; }
}

// Atomic repoint: a new relative link beside current, renamed over it
// (rename(2) replaces a symlink atomically).
function swapCurrent(layout, version) {
  const tmp = path.join(layout.base, `.current.${process.pid}.tmp`);
  try { fs.unlinkSync(tmp); } catch (_e) { /* absent */ }
  fs.symlinkSync(version, tmp);
  try {
    fs.renameSync(tmp, layout.current);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* best-effort */ }
    throw e;
  }
}

module.exports = { versionedLayout, installedVersion, updateVersioned };
