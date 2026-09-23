'use strict';
// scripts/himmelctl/lib/uninstall-wrapper.js — the uninstall confirm/spawn
// wrapper extracted out of bin.js's cmdUninstall (HIMMEL-3312 S13 item 2).
// Pure refactor: same TTY/`--yes` fail-closed rule (rc 2), same default-No
// confirm (rc 3), same wet spawn with HIMMEL_UNINSTALL_REAL_HOME=1, same
// launcher removal on rc 0 — bin.js now delegates to runUninstallWrapper()
// instead of doing all of this inline. Deliberately takes an injected
// { bashPath, repoRoot, header, afterRun } rather than resolving those
// itself: bin.js passes resolveBash()/repoRoot() and its own manifest-driven
// header/completeness-check closures, while the not-yet-in-clone
// scripts/himmelctl/standalone.js (S13 item 4) passes 'bash'/the bundle dir
// and a header that says it is skipping the offboard plan + completeness
// check instead — same wrapper, two callers, no behaviour duplicated.
//
// displayCommand/runSpawn/askConfirmSafe are used by OTHER bin.js commands
// too (install/update previews and prompts), so they stay defined there;
// this module duplicates its own copies (same bodies) rather than requiring
// bin.js back, which would be circular (bin.js requires this module).

const { spawnSync } = require('child_process');
const path = require('path');
const readline = require('readline');
const helpersLib = require('./helpers.js');
const launcherLib = require('./launcher.js');

function displayCommand(cmd) {
  return cmd.argv.map(helpersLib.shellQuote).join(' ');
}

function runSpawn(cmd, opts = {}) {
  const spawnOpts = { stdio: 'inherit' };
  if (opts.env) spawnOpts.env = opts.env;
  const r = spawnSync(cmd.argv[0], cmd.argv.slice(1), spawnOpts);
  if (r.error) {
    console.error(`himmelctl: failed to launch ${cmd.argv[0]}: ${r.error.message}`);
    return 1;
  }
  return typeof r.status === 'number' ? r.status : 1;
}

function askConfirmSafe(prompt, eofValue = 'n') {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
    let answered = false;
    rl.question(prompt, (ans) => {
      answered = true;
      rl.close();
      resolve(ans || '');
    });
    rl.on('close', () => {
      if (!answered) resolve(eofValue);
    });
  });
}

// Same shape as bin.js's former deriveUninstallCommand, parameterized on the
// caller's own repoRoot/bashPath instead of calling repoRoot()/resolveBash()
// itself — repoRoot is the bundle dir for standalone.js, the clone root for
// bin.js. The win32 branch is unchanged (resolvePowershell(), uninstall.ps1);
// it is unused by standalone.js (POSIX-only per S13 Q2) but kept so this
// module stays a complete, platform-symmetric replacement of the original.
function deriveUninstallCommand(repoRoot, bashPath, args = {}) {
  const scriptsDir = path.join(repoRoot, 'scripts');
  if (process.platform === 'win32') {
    const argv = [helpersLib.resolvePowershell(), '-ExecutionPolicy', 'Bypass', '-File', path.join(scriptsDir, 'uninstall.ps1')];
    argv.push(args.dryRun ? '-DryRun' : '-Yes');
    if (args.purgeState) argv.push('-PurgeState');
    return { argv };
  }
  const argv = [bashPath, path.join(scriptsDir, 'uninstall.sh').replace(/\\/g, '/'), args.dryRun ? '--dry-run' : '--yes'];
  if (args.purgeState) argv.push('--purge-state');
  return { argv };
}

// The confirm/spawn wrapper itself. `header(purgeState)` prints whatever
// pre-derived-command context the caller owns (bin.js: the offboard banner +
// manifest plan; standalone.js: a one-line "skipping ..." notice) — called
// BEFORE the `derived: ...` line, same as bin.js's original order for the
// banner/state lines (the manifest offboard plan printed after `derived:` in
// the pre-extraction code; no test asserts that relative order, so folding
// it into one header() call ahead of `derived:` is not a behaviour change
// any caller observes). `afterRun(rc)` runs after a wet spawn AND after the
// (also-common) rc===0 launcher removal, so bin.js can run its
// checkUninstallCompleteness there while standalone.js's afterRun is a no-op.
async function runUninstallWrapper(args, { bashPath, repoRoot, header, afterRun }) {
  const cmd = deriveUninstallCommand(repoRoot, bashPath, args);
  header(args.purgeState);
  console.log(`derived: ${displayCommand(cmd)}`);

  // --dry-run asks nothing and removes nothing: it runs the executor in its
  // own --dry-run, which prints every path/plugin/hook/settings key it WOULD
  // touch (HIMMEL-3058). No HIMMEL_UNINSTALL_REAL_HOME here — the wet-run
  // fence is for wet runs; a dry run is never fenced. No launcher removal or
  // afterRun either: nothing was torn down.
  if (args.dryRun) return runSpawn(cmd);

  // HIMMEL-2755: EOF and an explicit "n" are DIFFERENT facts. A closed/non-tty
  // stdin without --yes is a REFUSAL (rc=2, fail-closed, same code and same
  // remedy as uninstall.sh's own non-interactive abort), not a decline.
  if (!args.yes) {
    // WHY (HIMMEL-2755): a pipe cannot consent AND must not be able to stall
    // a teardown; uninstall.sh:676's [ -t 0 ] && [ -t 1 ] is the twin.
    if (!process.stdin.isTTY || !process.stdout.isTTY) {
      console.error('himmelctl: ERROR: non-interactive run without --yes — aborting (fail-closed).');
      console.error('  Re-run with --yes to confirm, or --dry-run to preview.');
      return 2;
    }
    const EOF = '\u0000himmelctl-eof';
    const ans = await askConfirmSafe('Proceed? [y/N] ', EOF);
    if (ans === EOF) {
      console.error('himmelctl: ERROR: non-interactive run without --yes — aborting (fail-closed).');
      console.error('  Re-run with --yes to confirm, or --dry-run to preview.');
      return 2;
    }
    // Default-No (HIMMEL-3328): a bare Enter or anything but y/yes declines.
    if (!/^\s*(y|yes)\s*$/i.test(ans)) {
      console.log('himmelctl: declined; nothing run.');
      return 3;
    }
  }
  // HIMMEL-2505: this is the ONE spawn that runs uninstall.sh/.ps1 WET, after
  // the human's own confirm above — tell it so its own live-operator-HOME
  // fence doesn't refuse the very machine the operator just confirmed
  // offboarding. The dry-run/plan path above never reaches here.
  const rc = runSpawn(cmd, { env: { ...process.env, HIMMEL_UNINSTALL_REAL_HOME: '1' } });
  // HIMMEL-1446 r4 (codex-1/codex-adv converged blocker): strip the managed
  // PATH launchers ONLY when the teardown succeeded. A failed teardown
  // (rc!=0) leaves the machine in a partial state and the user will likely
  // retry, so removing the launchers now would strand the machine with no
  // working `himmelctl` for the retry. Preserve them and WARN naming the
  // failure.
  if (rc === 0) {
    launcherLib.removeHimmelctlLaunchers();
  } else {
    console.error(`himmelctl: WARN: uninstall teardown exited ${rc} — PATH launchers left in place; fix the failure and re-run \`himmelctl uninstall\`.`);
  }
  afterRun(rc);
  return rc;
}

module.exports = {
  deriveUninstallCommand,
  runUninstallWrapper,
};
