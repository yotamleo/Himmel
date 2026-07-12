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
function which(tool) {
  const exts = process.platform === 'win32' ? ['', '.exe', '.cmd', '.bat'] : [''];
  const dirs = (process.env.PATH || '').split(path.delimiter);
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
