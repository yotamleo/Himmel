'use strict';
// scripts/himmelctl/lib/helpers.js — shared helpers extracted out of bin.js
// (HIMMEL-756 T1.2a). Pure refactor: same implementations, same call sites,
// same seam env vars (HIMMELCTL_CACHE_DIR) — bin.js now `require`s these
// instead of defining them inline.

const fs = require('fs');
const os = require('os');
const path = require('path');

// Resolve <tool> on PATH like `command -v` would, checking the bare name plus
// the Windows executable extensions so the same scan works on win32/posix.
// Uses path.delimiter, which is the separator Node actually sees in
// process.env.PATH (';' on win32, ':' on posix).
//
// CR fix (HIMMEL-1093 round 2, codex-2): optional `env` param, defaulting to
// process.env when omitted — preserves probeDep's documented exception
// (probes.js: which() reads process.env.PATH directly by design, a hermetic
// test controls it via the OUTER shell PATH, not ctx.env), while letting a
// caller that already threads a fully-controlled ctx.env (probeMcpRegistered's
// bin check) resolve PATH from THAT env instead of silently falling back to
// the real process env. The `env.Path` fallback mirrors scripts/lanes/
// resolve.mjs's pathHasFactory() — a manually-constructed env object built by
// spreading process.env can carry either casing on Windows.
//
// CR fix (HIMMEL-1093 round 5, codex-1): pick the first KEY PRESENT, not the
// first TRUTHY value. `e.PATH || e.Path || ''` treated a deliberately
// scrubbed `PATH: ''` as falsy and fell through to `e.Path` — so a hermetic
// caller that explicitly empties PATH (to prove "nothing resolves") silently
// resolved from an inherited Windows `Path` instead, defeating the scrub.
function which(tool, env) {
  const e = env || process.env;
  const exts = process.platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : [''];
  const rawPath = ('PATH' in e) ? e.PATH : (('Path' in e) ? e.Path : '');
  const dirs = String(rawPath || '').split(path.delimiter);
  for (const dir of dirs) {
    if (!dir) continue;
    for (const ext of exts) {
      try {
        if (fs.existsSync(path.join(dir, tool + ext))) return path.join(dir, tool + ext);
      } catch (_e) { /* unreadable dir — skip */ }
    }
  }
  return null;
}

// The interactive answers are cached so the same install can be replayed
// non-interactively via --from-profile. The cache dir defaults to
// ~/.claude/himmel/ but is overridable via HIMMELCTL_CACHE_DIR — same class of
// seam as HIMMELCTL_INTERACTIVE, and genuinely useful for CI (and essential
// for hermetic tests: under Git Bash, HOME does NOT propagate into node.exe
// children, so ~/.claude/himmel/ cannot be redirected via fake-HOME alone).
function cacheDir() {
  return process.env.HIMMELCTL_CACHE_DIR || path.join(os.homedir(), '.claude', 'himmel');
}

// T5a (locked Q4): map a vault mode to an adopt.sh profile.
//   none             → core
//   default-template → all (adopt.sh itself scaffolds the vault from
//                      templates/luna-second-brain — the wizard must NOT call
//                      luna-upgrade-all.sh or wire-luna-vault.sh here).
//   existing         → handled BEFORE this is reached (see the runPlan gate
//                       below) — T5b, STAMPED-only (see isStampedLunaVault).
function profileForVault(answers) {
  const mode = answers.vault && answers.vault.mode;
  return mode === 'default-template' ? 'all' : 'core';
}

module.exports = { cacheDir, profileForVault, which };
