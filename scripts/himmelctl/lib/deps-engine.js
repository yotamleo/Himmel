'use strict';
// scripts/himmelctl/lib/deps-engine.js — the engine behind `himmelctl deps
// status|ensure|upgrade` (HIMMEL-759, sub-ticket C of epic HIMMEL-755).
//
// deps.json (scripts/install/deps.json) is a SEPARATE, flat, version-aware
// toolchain declaration -- NOT the manifest's presence-only kind:"dep"
// items (scripts/install/manifest.json). The two coexist by design
// (operator-locked, 2026-07-17): manifest.json drives the wizard's
// install/ensure WIRING reconcile (per-target enabled flags, dependency
// ordering, coalescing — see install-engine.js); deps.json is a standalone
// toolchain-version view with no per-target state and no dependency graph
// ("a flat declared set is enough" — do not add one). This file never
// touches state.json or the install-profile cache.
//
// Absorbs scripts/setup/ensure-tools.sh's per-OS recipe logic for the tools
// it already knows how to install (git/jq/python3 via apt/dnf/brew identity
// package names, bun via its official curl installer) by SHELLING OUT to it
// (manager:"ensure-tools" below) rather than re-implementing it — the
// script stays the single source of truth for that recipe; this file only
// orchestrates + reports (mirrors the locked bootstrap-shim boundary: a
// node process cannot bootstrap node itself, so every recipe here — even
// the ones that could technically run inline — ends in a bash spawn, never
// inline Node install logic).
//
// Pure/reporting functions (loadDeps, depStatus, versionGte) never spawn a
// MUTATING process — depStatus's spawns are read-only version/presence
// probes. buildDepEntry/qmdPullModelsEntry only BUILD a {cmd,args} plan
// entry; they never spawn. Actual execution is the caller's job (bin.js's
// cmdDeps), via install-engine.js's already-hardened runInstall() (timeout,
// tree-kill, env-scrubbed spawn) — this file never calls spawnSync for a
// mutating command itself.

const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');
const { which } = require('./helpers.js');
const { resolveSudoPassword } = require('./install-engine.js');

// Read scripts/install/deps.json under repoRoot and return its deps array.
// CR fix: a MISSING deps.json (fs ENOENT) is distinguished from a MALFORMED
// one — only ENOENT is caught, converted to a clear "deps.json not found"
// Error (surfaced via main()'s top-level catch, same as loadProfile's own
// "missing/unreadable file -> throw -> exit 1" convention in bin.js). A
// JSON.parse failure on a present-but-malformed file is left to propagate
// as-is (its own SyntaxError) rather than being swallowed into the same
// "missing" bucket — the two are different failure classes and callers need
// to tell them apart.
function loadDeps(repoRoot) {
  const depsPath = path.join(repoRoot, 'scripts', 'install', 'deps.json');
  let raw;
  try {
    raw = fs.readFileSync(depsPath, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') throw new Error(`deps.json not found: ${depsPath}`);
    throw e;
  }
  const parsed = JSON.parse(raw);
  // CR fix: validate the top-level shape — a deps.json whose `deps` is
  // missing or not an array is a corrupt declaration, not an empty one.
  // Returning [] (the old fallback) would silently make `deps status` report
  // a healthy empty toolchain and `deps ensure` converge nothing, masking the
  // breakage. Throw an explicit Error (surfaced via main()'s top-level catch,
  // same exit-1 convention as the ENOENT branch above and bin.js's own
  // loadProfile). `!parsed` guards a JSON `null`/non-object root before the
  // .deps access; a malformed file still propagates JSON.parse's own
  // SyntaxError unchanged (different failure class, not swallowed here).
  if (!parsed || !Array.isArray(parsed.deps)) {
    throw new Error("deps.json: 'deps' must be an array");
  }
  return parsed.deps;
}

// True iff dotted version string `actual` >= `min` (both like "1.2.3" or
// "1.2"; missing trailing components read as 0). `actual` may carry a
// leading/trailing non-numeric prefix (e.g. "v24.3.0") — the first
// x.y(.z) run is extracted. Mirrors scripts/lib/qmd-bin.sh's own
// _qmd_version_ge, ported to JS (this file has no bash to source).
function versionGte(actual, min) {
  const m = String(actual).match(/\d+(?:\.\d+){0,2}/);
  if (!m) return false;
  const pa = m[0].split('.').map(Number);
  const pb = String(min).split('.').map(Number);
  for (let i = 0; i < Math.max(pa.length, pb.length); i++) {
    const x = pa[i] || 0;
    const y = pb[i] || 0;
    if (x > y) return true;
    if (x < y) return false;
  }
  return true;
}

// osKey(platform) -> "linux" | "macos" | "win32", the three keys every
// dep.install object carries.
function osKey(platform) {
  if (platform === 'win32') return 'win32';
  if (platform === 'darwin') return 'macos';
  return 'linux';
}

// Read-only presence probe. qmd (the one dep declaring `resolver`) is not a
// bare PATH-resolvable binary — it's served via a bun-global link qmd-bin.sh
// resolves (mirrors probes.js's cmd:has_qmd probe type, for the SAME
// reason) — so its presence check sources the resolver and calls has_qmd
// instead of which(cmd). Every other dep is a plain `which()` PATH check.
// CR fix (MAJOR, codex panel + CodeRabbit): resolverPath used to be
// interpolated straight into the -c script text (`` `. "${resolverPath}" &&
// has_qmd` ``) — breaks on a repoRoot containing spaces (e.g. a Windows
// "C:\Users\My Name\...", the common case) and, were repoRoot ever to carry
// shell metacharacters, could execute unintended commands. Passed as a
// POSITIONAL arg ($1) instead, mirroring qmdPullModelsEntry's own `. "$1"
// && has_qmd && qmd_cmd pull` shape and install-engine.js's buildEntry()
// winget/brew/apt-dep cases — no value is ever interpolated into the -c
// string.
// isExecutableFile(p) -> bool. CR fix (CodeRabbit MAJOR): a PATH entry which()
// resolved must be a regular file the caller can actually EXECUTE before it
// counts as present — a DIRECTORY named like the tool, or a present-but-non-
// executable file (POSIX mode 0644), used to read as present (probePresence
// returned true for any which() hit, and which() only checks existence). isFile()
// rejects dirs / dir-symlinks / devices on every platform. The execute-permission
// check (X_OK) is meaningful only on POSIX — Windows has no POSIX exec bit, so
// executability there is conveyed by the PATHEXT extensions which() already
// resolved (.exe/.cmd/.bat); X_OK is skipped on win32, where libuv's access() is
// not a reliable exec check and would false-negative on a real .exe.
function isExecutableFile(p) {
  let st;
  try {
    st = fs.statSync(p);
  } catch (_e) {
    return false;
  }
  if (!st.isFile()) return false;
  if (process.platform === 'win32') return true;
  try {
    fs.accessSync(p, fs.constants.X_OK);
  } catch (_e) {
    return false;
  }
  return true;
}

function probePresence(dep, ctx) {
  if (dep.resolver) {
    const resolverPath = path.join(ctx.repoRoot, dep.resolver);
    const r = spawnSync('bash', ['-c', '. "$1" && has_qmd', 'himmel-dep', resolverPath], { encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL' });
    return !r.error && r.status === 0;
  }
  const resolved = which(dep.cmd);
  return Boolean(resolved) && isExecutableFile(resolved);
}

// Read-only version probe: runs the dep's versionProbe.args (default
// ["--version"]) and extracts the first x.y(.z) token from stdout+stderr.
// Returns null when the tool can't be run, exits nonzero (e.g. an
// unrecognized flag prints usage instead of a version and exits 1 — that
// output is never parsed for a version-shaped token, it's just discarded),
// or no version-shaped token is found (e.g. a corrupt install) — callers
// treat null as "can't verify", never as a crash. A present-but-degraded
// tool (version probe fails) still reports severity:"degraded" in
// depStatus, not a crash. Always routed through `bash -c` (never a raw
// spawnSync(dep.cmd, ...)) — same reason bin.js's detectRole()/
// installMissing()/runPluginEnable() all do the same: Node's non-shell
// spawnSync does its own PATH resolution on win32 and can silently prefer
// an unrelated same-named binary, or simply fail to launch a .cmd/.bat/
// shebang-script tool at all (CreateProcess requires bash's own
// interpreter-aware exec for those), whereas bash's PATH search resolves
// the right one regardless of extension.
// CR fix (MAJOR, codex panel + CodeRabbit): resolverPath/dep.cmd/versionArgs
// used to be string-interpolated into the -c line (same class of bug as
// probePresence above — breaks on a spacey repoRoot, unhardened against
// metacharacters). Every value is now a POSITIONAL arg; the script
// references them via "$1"/"${@:2}" (never re-interpolated), same
// convention as probePresence and install-engine.js's buildEntry() cases.
function probeVersion(dep, ctx) {
  const versionArgs = (dep.versionProbe && dep.versionProbe.args) || ['--version'];
  let r;
  if (dep.resolver) {
    const resolverPath = path.join(ctx.repoRoot, dep.resolver);
    r = spawnSync('bash', ['-c', '. "$1" && qmd_cmd "${@:2}"', 'himmel-dep', resolverPath, ...versionArgs], { encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL' });
  } else {
    r = spawnSync('bash', ['-c', '"$1" "${@:2}"', 'himmel-dep', dep.cmd, ...versionArgs], { encoding: 'utf8', timeout: 10000, killSignal: 'SIGKILL' });
  }
  if (r.error || r.status !== 0) return null;
  const out = `${r.stdout || ''}\n${r.stderr || ''}`;
  const m = out.match(/\d+\.\d+(?:\.\d+)?/);
  return m ? m[0] : null;
}

// depStatus(dep, ctx) -> {id, cmd, present, version, severity, detail}
// severity: "red" (absent), "degraded" (present but version UNVERIFIABLE —
// the probe ran but produced no parseable x.y(.z) token — OR a declared
// minVersion floor is not met), "green" (present with a known version, and
// version-ok whenever a minVersion is declared). Note the asymmetry the
// CodeRabbit fix calls out: a present binary whose version can't be
// verified is degraded (an unverifiable install is not a healthy one, and
// must not be reported green), REGARDLESS of whether a minVersion floor is
// declared — so the version-unverifiable check fires BEFORE the
// no-minVersion branch. "version simply isn't compared" (version known,
// no floor) is fine/green; "version probe failed" is degraded. Every dep
// in deps.json today has minVersion:null, yet degraded-for-version can
// still fire when a real install is present but its --version probe fails.
function depStatus(dep, ctx) {
  const present = probePresence(dep, ctx);
  if (!present) {
    const detail = dep.resolver ? `'${dep.cmd}' not detected via ${dep.resolver}` : `'${dep.cmd}' not found on PATH`;
    return { id: dep.id, cmd: dep.cmd, present: false, version: null, severity: 'red', detail };
  }
  const version = probeVersion(dep, ctx);
  // Present but the version probe failed (ran but no parseable x.y(.z)
  // token, or nonzero/error) -> degraded, NOT green, even when no minVersion
  // floor is declared. MUST precede the no-minVersion branch: a version-known
  // dep with no floor is green (its version simply isn't compared), but a
  // version-unverifiable one is degraded regardless.
  if (!version) {
    const detail = dep.minVersion
      ? `present but version could not be determined (required >= ${dep.minVersion})`
      : 'present but version could not be determined';
    return { id: dep.id, cmd: dep.cmd, present: true, version: null, severity: 'degraded', detail };
  }
  if (!dep.minVersion) {
    return { id: dep.id, cmd: dep.cmd, present: true, version, severity: 'green', detail: `present (${version})` };
  }
  const ok = versionGte(version, dep.minVersion);
  return {
    id: dep.id,
    cmd: dep.cmd,
    present: true,
    version,
    severity: ok ? 'green' : 'degraded',
    detail: ok ? `present (${version})` : `present (${version}) — below required ${dep.minVersion}`,
  };
}

// The apt/dnf/brew package-manager detection ensure-tools.sh's own
// _ensure_detect_pm uses, duplicated here ONLY for the upgrade verb: unlike
// `ensure_tools()` (which SKIPS an already-present tool by design — it's an
// "ensure present" primitive, not an upgrade one), upgrading git/jq/python3
// needs to re-run the package manager's install command even when the tool
// is already there.
// CR fix (SECURITY, MAJOR): `sudo` used to be invoked bare here, ignoring
// the configured HIMMELCTL_SUDO_PASSWORD entirely — a non-interactive
// `deps upgrade --yes` on linux would either prompt (hanging with no tty
// until sudo's own timeout) or just fail, instead of using the SAME
// hardened credential path install-engine.js's own linux 'dep' buildEntry()
// case already uses. Two variants now exist: the _SUDO_PASSWORD one reads
// the password via `sudo -S -p ''` from stdin (routed through
// runHardenedSpawn's `needsSudoPassword` marker, below); the
// _NO_SUDO_PASSWORD one uses `sudo -n` (fails fast rather than hanging).
// Both keep the brew branch (macOS, no sudo involved) and the
// "no supported package manager" branch unchanged. buildDepEntry (below)
// picks between them based on whether resolveSudoPassword(ctx.repoRoot)
// finds a configured value — never on which branch the bash snippet will
// actually take at runtime (that's decided by `command -v`, not knowable
// here).
const UPGRADE_APT_DNF_BREW_SUDO_PASSWORD_SNIPPET = 'if command -v apt-get >/dev/null 2>&1; then '
  + 'sudo -S -p \'\' sh -c \'apt-get update >/dev/null 2>&1 || true; apt-get install -y "$1"\' himmel-dep "$1"; '
  + 'elif command -v dnf >/dev/null 2>&1; then sudo -S -p \'\' dnf install -y "$1"; '
  // CR fix (SECURITY, MAJOR — CR #1191): brew needs no sudo, so redirect its
  // stdin from /dev/null. runHardenedSpawn pipes the sudo password to this
  // bash's stdin for the apt/dnf `sudo -S` branches, but the branch is chosen
  // at runtime by `command -v`; without this redirect the brew branch (and any
  // descendant it spawns) would inherit the credential-bearing stdin.
  + 'elif command -v brew >/dev/null 2>&1; then { brew upgrade "$1" 2>/dev/null || brew install "$1"; } </dev/null; '
  + 'else echo "no supported package manager for upgrade of $1" >&2; exit 1; fi';
const UPGRADE_APT_DNF_BREW_NO_SUDO_PASSWORD_SNIPPET = 'if command -v apt-get >/dev/null 2>&1; then '
  + 'sudo -n sh -c \'apt-get update >/dev/null 2>&1 || true; apt-get install -y "$1"\' himmel-dep "$1"; '
  + 'elif command -v dnf >/dev/null 2>&1; then sudo -n dnf install -y "$1"; '
  + 'elif command -v brew >/dev/null 2>&1; then brew upgrade "$1" 2>/dev/null || brew install "$1"; '
  + 'else echo "no supported package manager for upgrade of $1" >&2; exit 1; fi';

// buildDepEntry(dep, ctx, opts) -> {id, type:'dep', cmd, args} | {id, type:'dep', unrunnable}
// The install-time (ensure) or upgrade-time (opts.upgrade:true) plan entry
// for one dep on the CURRENT platform (ctx.platform override for tests).
// Every branch shells out via `bash -c` with the variable part passed as a
// POSITIONAL arg ($1), never interpolated into the -c string — the same
// injection-hardening convention install-engine.js's buildEntry() already
// uses for its own winget/brew/apt-dep cases. Returned entries are handed
// straight to install-engine.js's runInstall() — this function never spawns.
function buildDepEntry(dep, ctx, opts) {
  const upgrade = Boolean(opts && opts.upgrade);
  const key = osKey((ctx && ctx.platform) || process.platform);
  const recipe = dep.install && dep.install[key];
  if (!recipe) {
    return { id: dep.id, type: 'dep', unrunnable: `no install recipe declared for '${dep.id}' on ${key}` };
  }
  switch (recipe.manager) {
    case 'ensure-tools': {
      const ensureToolsPath = path.join(ctx.repoRoot, 'scripts', 'setup', 'ensure-tools.sh');
      if (dep.id === 'bun') {
        // bun has no ensure_tools() dispatch by cmd name (it's special-cased
        // inside that function) — its own upgrade path is simply re-running
        // the official installer, which always fetches latest and overwrites
        // the existing install in place.
        const line = upgrade ? '. "$1" && _ensure_install_bun' : '. "$1" && ensure_tools bun';
        return { id: dep.id, type: 'dep', cmd: 'bash', args: ['-c', line, 'himmel-dep', ensureToolsPath] };
      }
      if (!upgrade) {
        return { id: dep.id, type: 'dep', cmd: 'bash', args: ['-c', '. "$1" && ensure_tools "$2"', 'himmel-dep', ensureToolsPath, dep.cmd] };
      }
      // CR fix (SECURITY, MAJOR): route through the SAME hardened sudo
      // credential path install-engine.js's own linux 'dep' buildEntry()
      // case uses — see the snippet constants' own header above.
      if (resolveSudoPassword(ctx.repoRoot)) {
        return {
          id: dep.id,
          type: 'dep',
          cmd: 'bash',
          args: ['-c', UPGRADE_APT_DNF_BREW_SUDO_PASSWORD_SNIPPET, 'himmel-dep', dep.cmd],
          needsSudoPassword: true,
          repoRoot: ctx.repoRoot,
        };
      }
      return { id: dep.id, type: 'dep', cmd: 'bash', args: ['-c', UPGRADE_APT_DNF_BREW_NO_SUDO_PASSWORD_SNIPPET, 'himmel-dep', dep.cmd] };
    }
    case 'brew': {
      const line = upgrade ? 'brew upgrade "$1" 2>/dev/null || brew install "$1"' : 'brew install "$1"';
      return { id: dep.id, type: 'dep', cmd: 'bash', args: ['-c', line, 'himmel-dep', recipe.pkg] };
    }
    case 'winget': {
      const verb = upgrade ? 'upgrade' : 'install';
      return {
        id: dep.id, type: 'dep', cmd: 'bash',
        args: ['-c', `winget ${verb} --id "$1" -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements`, 'himmel-dep', recipe.id],
      };
    }
    case 'pip': {
      const line = upgrade ? 'python3 -m pip install --user --upgrade "$1"' : 'python3 -m pip install --user "$1"';
      return { id: dep.id, type: 'dep', cmd: 'bash', args: ['-c', line, 'himmel-dep', recipe.pkg] };
    }
    case 'script': {
      // Idempotent/converging by construction (qmd_install re-checks
      // qmd_fork_served) — the same recipe serves both ensure and upgrade.
      const script = path.join(ctx.repoRoot, recipe.script);
      return { id: dep.id, type: 'dep', cmd: 'bash', args: [script, ...(recipe.args || [])] };
    }
    case 'hint':
      return { id: dep.id, type: 'dep', unrunnable: recipe.detail || `no automated install for '${dep.id}' on ${key} — install it manually` };
    default:
      return { id: dep.id, type: 'dep', unrunnable: `unknown install manager '${recipe.manager}'` };
  }
}

// The qmd model-pull plan entry (~2.1 GB embedding/rerank models — see
// adopt.sh's wire_qmd_core, the same `qmd pull` primitive). Separate from
// buildDepEntry's qmd 'script' case (which only installs the BINARY) —
// callers (cmdDeps upgrade) gate this behind an explicit prompt/--with-models
// before ever building it, matching adopt.sh's own size-caveat-first posture.
// Takes the qmd dep object (not a hardcoded path) so it resolves via the
// SAME dep.resolver every other qmd probe/install already uses — keeps a
// hermetic test's fixture resolver authoritative for every qmd code path,
// not just presence/version.
function qmdPullModelsEntry(dep, ctx) {
  const resolverPath = path.join(ctx.repoRoot, dep.resolver);
  return { id: 'qmd-models', type: 'dep', cmd: 'bash', args: ['-c', '. "$1" && has_qmd && qmd_cmd pull', 'himmel-dep', resolverPath] };
}

module.exports = { loadDeps, depStatus, versionGte, buildDepEntry, qmdPullModelsEntry };
