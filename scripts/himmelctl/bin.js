#!/usr/bin/env node
'use strict';
// scripts/himmelctl/bin.js — himmelctl: thin install wizard (HIMMEL-887).
//
// A deliberately thin entry point that walks an adopter through installing
// himmel: arg parsing + usage banner (T0), a preflight-first gate (T1), the
// question engine (T2), the answer-schema cache + --from-profile replay (T3),
// and the derived-command derivation + shell-out (T4) with the vault-profile
// mapping (T5a), the existing-vault STAMPED gate (T5b), and handover/
// pluginSet consumption (T4.5). Also provides the `uninstall` subcommand, a
// thin wrapper that derives + confirms + shells out to uninstall.sh/.ps1.
//
// ZERO npm dependencies — the question engine uses Node's built-in `readline`
// only. No third-party prompts library, no package.json changes.
//
// Usage:
//   node scripts/himmelctl/bin.js --help
//   node scripts/himmelctl/bin.js install [--dry-run] [--from-profile <path>] [--advanced]
//   node scripts/himmelctl/bin.js uninstall [--dry-run]

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');

// Tools every himmel adopter needs before any question makes sense — mirrors
// adopt.sh require_tools (bash/git/jq/python3) PLUS at least one JS package
// manager (npm or bun). npm is the recommended install when both are absent.
const HARD_GATE_TOOLS = ['bash', 'git', 'jq', 'python3'];

const USAGE = `usage: himmelctl <command> [options]

commands:
  install                install himmel into this project or your user scope
  uninstall               offboard himmel from this machine (thin wrapper)

options:
  --from-profile <path>  install non-interactively from a saved profile cache
  --advanced             reserved: surface advanced options (parsed, not yet honored)
  --dry-run              print the derived install plan without executing
  -h, --help             show this help`;

// Parse the CLI args into a plain object. Unknown args are a hard error (exit
// 2) so a typo doesn't silently fall through to a no-op install. A second
// subcommand (even a repeat) is the same class of hard error — previously
// `himmelctl install uninstall` silently ran uninstall (the later token won).
function parseArgs(argv) {
  const args = {
    subcommand: null,
    fromProfile: null, // reserved (T0: parse only)
    advanced: false,   // reserved (T0: parse only)
    dryRun: false,
  };
  const setSubcommand = (name) => {
    if (args.subcommand !== null) {
      console.error(`himmelctl: multiple subcommands given ('${args.subcommand}' and '${name}')`);
      console.error("Run 'himmelctl --help' for usage.");
      process.exit(2);
    }
    args.subcommand = name;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case 'install':
        setSubcommand('install');
        break;
      case 'uninstall':
        setSubcommand('uninstall');
        break;
      case '--from-profile':
        args.fromProfile = argv[++i];
        if (args.fromProfile === undefined) {
          console.error('himmelctl: --from-profile requires a path argument');
          process.exit(2);
        }
        break;
      case '--advanced':
        args.advanced = true;
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      default:
        console.error(`himmelctl: unknown argument: ${a}`);
        console.error("Run 'himmelctl --help' for usage.");
        process.exit(2);
    }
  }
  return args;
}

// Absolute himmel repo root (this file lives at scripts/himmelctl/bin.js).
function himmelRoot() {
  return path.resolve(__dirname, '..', '..');
}

// Root used to locate setup.sh/setup.ps1/adopt.sh and scripts/handover/
// set-handover-dir.sh (T4/T4.5/T5a). Overridable via HIMMELCTL_REPO_ROOT —
// same seam class as HIMMELCTL_CACHE_DIR — so a hermetic test can point the
// derivation + shell-out at STUB fixtures in a temp dir instead of the real
// himmel clone. Defaults to the real clone root.
function repoRoot() {
  return process.env.HIMMELCTL_REPO_ROOT || himmelRoot();
}

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

// Return the missing hard-gate tools: any of bash/git/jq/python3 absent, plus
// 'npm' when neither npm nor bun is present (matches adopt.sh require_tools
// semantics, plus the JS package-manager requirement).
function hardGateCheck() {
  const missing = HARD_GATE_TOOLS.filter((t) => !which(t));
  if (!which('npm') && !which('bun')) missing.push('npm');
  return missing;
}

// Run scripts/preflight-adopter.sh, printing its advisories VERBATIM (stdio is
// inherited, so the runner's own WARN lines reach the terminal unchanged) and
// capturing its rc. The runner is advisory (exits 0 unless --strict), so a non-
// zero rc is informational only. bash is itself a hard-gate tool; if it is
// somehow absent the spawn errors and the advisory is simply skipped (the
// missing-handler below reports bash).
function runPreflight() {
  const script = path.join(__dirname, '..', 'preflight-adopter.sh');
  const r = spawnSync('bash', [script], { stdio: 'inherit' });
  return { ran: !r.error, rc: r.status };
}

function printRemediation() {
  const doc = path.join(himmelRoot(), 'docs', 'setup', 'new-machine.md');
  console.error(`  see ${doc} (Required environment)`);
}

// Interactive iff stdin is a TTY and --dry-run was not passed. The
// HIMMELCTL_INTERACTIVE env var (1/0) forces a side for automation/CI and for
// hermetic tests that cannot allocate a real PTY; when unset, TTY detection
// decides.
function isInteractive(args) {
  if (args.dryRun) return false;
  const v = process.env.HIMMELCTL_INTERACTIVE;
  if (v === '1') return true;
  if (v === '0') return false;
  return Boolean(process.stdin.isTTY);
}

// win32: winget takes ONE exact package id per invocation — `winget install
// jq python3 npm` is a single search QUERY, not multiple packages, and bare
// tool names are not winget ids. Map each hard-gate tool to its documented
// id (mirrors scripts/machine-setup/win11.ps1's per-tool installs). bash is
// never installed through this map (self-install paradox, special-cased
// below); it ships with Git.Git anyway.
const WINGET_IDS = {
  git: 'Git.Git',
  jq: 'jqlang.jq',
  python3: 'Python.Python.3.12',
  node: 'OpenJS.NodeJS.LTS',
  npm: 'OpenJS.NodeJS.LTS',
};

// Run one package-manager line via `bash -c` (bash is guaranteed present at
// every call site — the bash-missing paradox is special-cased before this is
// reached) and log a launch failure or nonzero exit instead of swallowing it.
// The bash-wrap keeps the call testable with an extensionless stub on every
// OS. Every line is assembled from fixed vocabulary — never user input — so
// interpolating into a shell line carries no injection risk.
function runInstallerLine(line) {
  console.error(`himmelctl: running: ${line}`);
  const r = spawnSync('bash', ['-c', line], { stdio: 'inherit' });
  if (r.error) console.error(`himmelctl: failed to launch installer: ${r.error.message}`);
  if (typeof r.status === 'number' && r.status !== 0) console.error(`himmelctl: installer exited ${r.status}`);
}

// Install the missing hard-gate tools via the platform package manager.
// darwin/linux: ONE brew/apt invocation for the whole list. win32: one
// `winget install --id <ID> -e` per tool (see WINGET_IDS); a tool with no
// mapped id gets a manual-install pointer instead of a doomed bare-name
// query. bash CAN itself be the missing tool, and shelling out via `bash -c`
// to install bash is a paradox (nothing to shell out THROUGH) — that case
// prints a platform-appropriate pointer and skips the spawn entirely.
function installMissing(missing) {
  if (missing.indexOf('bash') !== -1) {
    console.error('himmelctl: bash itself is missing and cannot be self-installed via a bash shell-out.');
    console.error(process.platform === 'win32'
      ? '  install Git for Windows (Git Bash) or enable WSL, then re-run himmelctl.'
      : '  install bash via your platform package manager, then re-run himmelctl.');
    return;
  }
  if (process.platform === 'win32') {
    for (const tool of missing) {
      const id = WINGET_IDS[tool];
      if (!id) {
        console.error(`himmelctl: no winget id known for '${tool}' — install it manually, then re-run himmelctl.`);
        continue;
      }
      runInstallerLine(`winget install --id ${id} -e`);
    }
    return;
  }
  // darwin: Homebrew has no npm formula — npm ships with the node formula
  // (apt DOES have a real npm package, so linux keeps the verbatim name).
  const names = process.platform === 'darwin'
    ? missing.map((t) => (t === 'npm' ? 'node' : t))
    : missing;
  const pkgs = names.filter((t, i) => names.indexOf(t) === i).join(' ');
  runInstallerLine(process.platform === 'darwin'
    ? `brew install ${pkgs}`
    : `sudo apt-get install -y ${pkgs}`);
}

// Handle a non-empty missing list. Interactive + not --dry-run: offer to install
// via the platform manager, then re-check. Otherwise (non-interactive or
// --dry-run): print the missing list + remediation and bail. Resolves true when
// the caller may proceed (all tools now present), false to exit non-zero.
// Uses askConfirmSafe (not a bare rl.question) so a stdin that hits EOF
// before answering resolves to a decline instead of hanging forever.
async function handleMissing(missing, args) {
  console.error(`ERROR: missing required tools: ${missing.join(' ')}`);
  if (!isInteractive(args)) {
    printRemediation();
    return false;
  }
  const ans = await askConfirmSafe('Install missing tools now? [y/N] ');
  if (/^\s*y/i.test(ans)) {
    installMissing(missing);
    const stillMissing = hardGateCheck();
    if (stillMissing.length > 0) {
      console.error(`ERROR: still missing after install: ${stillMissing.join(' ')}`);
      printRemediation();
      return false;
    }
    console.error('himmelctl: missing tools installed; continuing.');
    return true;
  }
  printRemediation();
  return false;
}

// ── T2: question engine ──────────────────────────────────────────────────────
//
// After the preflight gate passes we walk the adopter through (up to) 5
// questions, each validated against its enum with a re-prompt on invalid input.
// raw `readline` only — zero npm deps. Order:
//   1. role        adopter|contributor (default via the git-origin heuristic)
//   2. scope       project|user — adopter ONLY (contributor is always user)
//   3. vault       none|default-template|existing (+path for the last two)
//   4. handover    inline|external (+path for external)
//   5. pluginSet   lean|full
// Lanes / always-on are NOT asked (P3 scope); derivation + shell-out is T4.

// Determine the default role from the current dir's `git remote get-url
// origin`. A himmel-named origin alone is NOT a contributor signal (CR r5):
// both machine-setup shims deliberately launch the wizard from the freshly
// cloned OFFICIAL himmel repo (CR r4's cwd fix), so ordinary adopters land
// on a himmel-suffixed origin too — defaulting them to contributor would
// run setup.sh and silently ignore their scope/vault answers. The explicit
// contributor signal is the repo root's `.himmel-dev` marker (the same
// himmel-dev signal the pre-commit gates key on): present in a contributor
// dev checkout, never in a fresh adopter clone. Any git failure (absent
// git, no origin, no toplevel) resolves to adopter. Always returns a
// one-line reasoning string so the operator sees WHY the default was
// picked — and the question still lets a contributor answer 'contributor'
// explicitly; this only shapes the DEFAULT.
//
// Routed through `bash -c` (not `spawnSync('git', …)` directly) so a hermetic
// test can stub `git` with a plain bash script on the stub PATH — direct
// spawnSync can't exec an extensionless script stub on win32. Mirrors
// installMissing's bash-wrap pattern. Both git lines are fixed strings,
// never user input, so the shell lines carry no injection risk.
function detectRole() {
  const r = spawnSync('bash', ['-c', 'git remote get-url origin'], { encoding: 'utf8' });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { role: 'adopter', reason: 'no origin remote -> default adopter' };
  }
  const url = r.stdout.trim();
  if (/himmel(\.git)?$/i.test(url)) {
    const t = spawnSync('bash', ['-c', 'git rev-parse --show-toplevel'], { encoding: 'utf8' });
    const top = (!t.error && t.status === 0 && t.stdout) ? t.stdout.trim() : '';
    if (top && fs.existsSync(path.join(top, '.himmel-dev'))) {
      return { role: 'contributor', reason: `origin = ${url} + .himmel-dev marker -> default contributor` };
    }
    return { role: 'adopter', reason: `origin = ${url} without a .himmel-dev marker -> default adopter` };
  }
  return { role: 'adopter', reason: `origin = ${url} -> default adopter` };
}

// Serialize the answer object to a stable string (2-space indent, insertion-
// order keys). Used for BOTH the cache write (T3) and the T4 stdout summary so
// a saved cache round-trips byte-for-byte through --from-profile.
function serialize(answers) {
  return JSON.stringify(answers, null, 2);
}

// Build the Draft-A answer object. tier/lanes/alwaysOn are schema placeholders
// never asked in P1 (they reserve the row for the future-755 profile work).
function buildAnswers(role, scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet) {
  return {
    role: role,
    tier: 'standard',
    scope: scope,
    vault: { mode: vaultMode, path: vaultPath },
    handover: { mode: handoverMode, path: handoverPath },
    pluginSet: pluginSet,
    lanes: [],
    alwaysOn: false,
  };
}

// Should we prompt the user with the question engine? --from-profile skips it
// (answers come from the file — T3); HIMMELCTL_INTERACTIVE forces a side for CI
// / hermetic tests that cannot allocate a real PTY; otherwise stdin being a TTY
// decides.
function shouldPrompt(args) {
  if (args.fromProfile) return false;
  const v = process.env.HIMMELCTL_INTERACTIVE;
  if (v === '1') return true;
  if (v === '0') return false;
  return Boolean(process.stdin.isTTY);
}

// Wrap a readline interface in an ask(prompt) that is robust to BATCHED piped
// input AND to EOF. rl.question consumes only one line and lets the rest fire
// as unhandled 'line' events (lost), so a hermetic test that pipes all answers
// in one chunk would see every question after the first get an empty default.
// Instead we own a one-listener line buffer: 'line' events either resolve the
// single pending asker or queue into `buffered`; ask() pulls from `buffered`
// first, else waits. On 'close' (stdin exhausted) the pending asker resolves ''
// and `closed` makes every later ask return '' immediately — so an EOF mid-flow
// accepts defaults instead of hanging. The prompt is written by us (not
// rl.question) so nothing races the 'line' listener. A separating newline is
// emitted on non-TTY output so piped prompts each land on their own line.
function makeAsk(rl) {
  const buffered = [];
  let pending = null;
  let closed = false;
  rl.on('line', (line) => {
    if (pending) { const cb = pending; pending = null; cb(line); }
    else buffered.push(line);
  });
  rl.on('close', () => {
    closed = true;
    if (pending) { const cb = pending; pending = null; cb(''); }
  });
  return function ask(q) {
    process.stdout.write(q);
    if (closed) return Promise.resolve('');
    if (buffered.length > 0) {
      const line = buffered.shift();
      if (!process.stdout.isTTY) process.stdout.write('\n');
      return Promise.resolve(line);
    }
    return new Promise((resolve) => {
      pending = (line) => {
        if (!process.stdout.isTTY) process.stdout.write('\n');
        resolve(line);
      };
    });
  };
}

// Ask one enum question, re-prompting (same header marker) until the answer is
// empty (accept default) or a member of opts.
async function askEnum(ask, prompt, opts, defaultVal) {
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    if (t === '') return defaultVal;
    if (opts.indexOf(t) !== -1) return t;
    // invalid — loop re-emits the prompt header so the re-prompt is visible
  }
}

// Ask one free-form path; empty answer accepts the default.
async function askPath(ask, prompt, defaultVal) {
  const ans = await ask(prompt);
  const t = (ans || '').trim();
  return t === '' ? defaultVal : t;
}

// Walk all questions interactively and return the answer object.
async function askQuestions() {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
  const ask = makeAsk(rl);

  // 1. role (default from the git-origin heuristic + a printed reasoning line).
  const det = detectRole();
  console.log(`detected: ${det.reason}`);
  const role = await askEnum(ask, `? role [adopter|contributor] (default: ${det.role})\n> `, ['adopter', 'contributor'], det.role);

  // 2. scope — adopter only. Contributor never asks (setup.sh is user-scope).
  let scope = 'project';
  if (role === 'adopter') {
    scope = await askEnum(ask, '? scope [project|user] (default: project)\n> ', ['project', 'user'], 'project');
  }

  // 3. vault. T2 collects mode+path only (non-luna->luna conversion is O1,
  //    deferred out of P1).
  const vaultMode = await askEnum(ask, '? vault [none|default-template|existing] (default: none)\n> ', ['none', 'default-template', 'existing'], 'none');
  let vaultPath = '';
  if (vaultMode !== 'none') {
    vaultPath = await askPath(ask, '? vault path (default: ~/Documents/luna)\n> ', '~/Documents/luna');
  }

  // 4. handover. T2 collects only; the write is T4.5.
  const handoverMode = await askEnum(ask, '? handover [inline|external] (default: inline)\n> ', ['inline', 'external'], 'inline');
  let handoverPath = '';
  if (handoverMode === 'external') {
    const hd = process.env.HANDOVER_DIR || '~/.claude/handover-state';
    handoverPath = await askPath(ask, `? handover path (default: ${hd})\n> `, hd);
  }

  // 5. pluginSet.
  const pluginSet = await askEnum(ask, '? pluginSet [lean|full] (default: lean)\n> ', ['lean', 'full'], 'lean');

  rl.close();
  return buildAnswers(role, role === 'contributor' ? 'user' : scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet);
}

// All-default answers (no prompts) for --dry-run previews. Still prints the
// role reasoning line so the preview shows what would happen.
function defaultAnswers() {
  const det = detectRole();
  console.log(`detected: ${det.reason}`);
  return buildAnswers(det.role, det.role === 'contributor' ? 'user' : 'project', 'none', '', 'inline', '', 'lean');
}

// ── T3: answer schema + cache ────────────────────────────────────────────────
//
// The interactive answers are cached so the same install can be replayed
// non-interactively via --from-profile. The cache dir defaults to
// ~/.claude/himmel/ but is overridable via HIMMELCTL_CACHE_DIR — same class of
// seam as HIMMELCTL_INTERACTIVE, and genuinely useful for CI (and essential
// for hermetic tests: under Git Bash, HOME does NOT propagate into node.exe
// children, so ~/.claude/himmel/ cannot be redirected via fake-HOME alone).

function cacheDir() {
  return process.env.HIMMELCTL_CACHE_DIR || path.join(os.homedir(), '.claude', 'himmel');
}

function cachePath() {
  return path.join(cacheDir(), 'install-profile.json');
}

// Persist the answer object as the on-disk profile. serialize()+newline so the
// T4 stdout summary and the cache file stay byte-for-byte identical (a saved
// cache round-trips through --from-profile unchanged). recursive mkdir so a
// fresh HOME/cache dir just works.
function writeCache(answers) {
  fs.mkdirSync(cacheDir(), { recursive: true });
  fs.writeFileSync(cachePath(), serialize(answers) + '\n');
}

// Hard-error exit for a profile that fails schema validation: clear stderr
// naming the bad field, exit 2 (the same posture parseArgs takes for a bad
// arg line — the operator handed us an explicit input and it is wrong).
function profileError(p, msg) {
  console.error(`himmelctl: invalid profile ${p}: ${msg}`);
  process.exit(2);
}

// Load + validate a profile file for --from-profile. Returns the parsed object
// AS-IS (no default-filling) so serialize() reproduces the file byte-stably.
// CR r5: --from-profile is explicit UNATTENDED-execution consent, so the FULL
// Draft-A schema is validated up front — a truncated/hand-edited/version-
// skewed profile must fail loud (exit 2, naming the bad field) BEFORE any
// side effect, never complete with silently reinterpreted answers (the old
// role-only check let e.g. a bogus vault.mode fall back to --profile core
// and a missing scope fall back to project). A missing/unreadable/non-JSON
// file surfaces as a normal error (throw -> main()'s catch, exit 1).
function loadProfile(p) {
  const raw = fs.readFileSync(p, 'utf8');
  let obj;
  try {
    obj = JSON.parse(raw);
  } catch (_e) {
    throw new Error(`profile is not valid JSON: ${p}`);
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error(`profile is not a JSON object: ${p}`);
  }
  const checkEnum = (field, value, allowed) => {
    if (allowed.indexOf(value) === -1) {
      profileError(p, `field '${field}' must be one of ${allowed.join('|')} (got ${JSON.stringify(value)})`);
    }
  };
  checkEnum('role', obj.role, ['adopter', 'contributor']);
  checkEnum('scope', obj.scope, ['project', 'user']);
  checkEnum('pluginSet', obj.pluginSet, ['lean', 'full']);
  if (!obj.vault || typeof obj.vault !== 'object' || Array.isArray(obj.vault)) {
    profileError(p, "field 'vault' must be an object");
  }
  checkEnum('vault.mode', obj.vault.mode, ['none', 'default-template', 'existing']);
  if (obj.vault.mode !== 'none' && (typeof obj.vault.path !== 'string' || obj.vault.path === '')) {
    profileError(p, `field 'vault.path' is required when vault.mode=${obj.vault.mode}`);
  }
  if (!obj.handover || typeof obj.handover !== 'object' || Array.isArray(obj.handover)) {
    profileError(p, "field 'handover' must be an object");
  }
  checkEnum('handover.mode', obj.handover.mode, ['inline', 'external']);
  if (obj.handover.mode === 'external' && (typeof obj.handover.path !== 'string' || obj.handover.path === '')) {
    profileError(p, "field 'handover.path' is required when handover.mode=external");
  }
  return obj;
}

// ── T4/T5a/T4.5: derivation, vault profile, handover/pluginSet, shell-out ────
//
// The answer object maps to ONE derived command (T4):
//   contributor → bash scripts/setup.sh (powershell -File scripts\setup.ps1
//                 on win32 — matches README's documented Windows invocation).
//                 setup.sh has NO --scope flag (hardcoded user scope), so the
//                 wizard derives no extra flags for it.
//   adopter     → bash scripts/adopt.sh --profile <core|all> --scope
//                 <project|user> [--luna-target <path>] — profile from the
//                 T5a vault mapping below. adopt.sh is bash-native and bash
//                 is a hard-gate tool on every platform (incl. Windows via
//                 Git Bash), so, unlike setup.sh, no win32 branch is needed.
// --dry-run prints the plan (+ T4.5 side effects) and exits 0 WITHOUT
// executing. Otherwise ONE confirm (`Proceed? [Y/n]`), then the T4.5
// handover-write, the verbatim shell-out (stdio inherit, rc propagated), and
// (on success) the T4.5 plugin-enable step.

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

// T5b: is <vaultPath> a STAMPED luna-second-brain vault? Reuses the EXACT
// signal scripts/luna-upgrade-all.sh's classify_vault() treats as
// "luna-family" — <vault>/.vault-template.json whose `template` field is
// "luna-second-brain" — rather than inventing a second heuristic. A pure fs
// read (never a shell-out), so the UNSTAMPED refusal path in runPlan stays
// truly zero-shell-outs. Any read/parse failure (missing file, bad JSON,
// vault dir absent) resolves to "not stamped" — refuse, don't guess.
function isStampedLunaVault(vaultPath) {
  const stampFile = path.join(vaultPath, '.vault-template.json');
  let raw;
  try {
    raw = fs.readFileSync(stampFile, 'utf8');
  } catch (_e) {
    return false;
  }
  try {
    const obj = JSON.parse(raw);
    return Boolean(obj) && obj.template === 'luna-second-brain';
  } catch (_e) {
    return false;
  }
}

// T5b: the settings.json wire-luna-vault.sh should target, mirroring
// adopt.sh's wire_luna_vault_path() exactly — project scope -> this process's
// cwd (adopt.sh's own --target default is $PWD, so this is byte-for-byte the
// same resolution), user scope -> ~/.claude/settings.json. Honors $HOME first
// (tests fake it — same convention as expandHome), else os.homedir().
function settingsPathForScope(scope) {
  if (scope === 'user') return path.join(process.env.HOME || os.homedir(), '.claude', 'settings.json');
  return path.join(process.cwd(), '.claude', 'settings.json');
}

// T5b STAMPED plan (locked O1): wire env.LUNA_VAULT_PATH into the
// scope-appropriate settings.json, THEN run luna-upgrade-all.sh apply against
// the vault. Backup is built into apply itself (its own BACKUP\t<path> line,
// surfaced verbatim by runSpawn's inherited stdio below — restore stays one
// command away). The unstamped-override flag is never derived here: apply is
// only ever reached once isStampedLunaVault has already confirmed the
// luna-family stamp.
function deriveExistingVaultPlan(answers) {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  const vaultPath = expandHome(answers.vault.path);
  const settings = settingsPathForScope(answers.scope);
  return {
    wire: { argv: ['bash', path.join(scriptsDir, 'lib', 'wire-luna-vault.sh'), settings, vaultPath] },
    apply: { argv: ['bash', path.join(scriptsDir, 'luna-upgrade-all.sh'), 'apply', '--vault', vaultPath] },
  };
}

// Expand a leading `~` to an absolute home path (adopt.sh/set-handover-dir.sh
// receive an already-expanded path — a literal `~` would never expand inside
// a quoted spawn arg). Honors $HOME first (tests fake it), else os.homedir().
function expandHome(p) {
  if (typeof p !== 'string' || p === '') return p;
  const home = process.env.HOME || os.homedir();
  if (p === '~') return home;
  if (p.slice(0, 2) === '~/') return path.join(home, p.slice(2));
  return p;
}

// Derive { argv } for the answer object. argv[0] is the launcher, the rest
// are its args, sized for spawnSync.
function deriveCommand(answers) {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  if (answers.role === 'contributor') {
    if (process.platform === 'win32') {
      return { argv: ['powershell', '-ExecutionPolicy', 'Bypass', '-File', path.join(scriptsDir, 'setup.ps1')] };
    }
    return { argv: ['bash', path.join(scriptsDir, 'setup.sh')] };
  }
  const argv = ['bash', path.join(scriptsDir, 'adopt.sh')];
  const profile = profileForVault(answers);
  argv.push('--profile', profile, '--scope', answers.scope || 'project');
  if (profile === 'all' && answers.vault && answers.vault.path) {
    argv.push('--luna-target', expandHome(answers.vault.path));
  }
  return { argv };
}

// Shell-quote one arg for DISPLAY only (the spawn below uses argv directly,
// no shell — this only affects the printed `derived:` line).
function shellQuote(a) {
  return /\s/.test(a) ? `'${String(a).replace(/'/g, "'\\''")}'` : a;
}

function displayCommand(cmd) {
  return cmd.argv.map(shellQuote).join(' ');
}

// uninstall §5.5 (locked): the one footer line pointing at the uninstall
// entry point. Printed after ANY successful non-dry-run install completion
// (the main adopt.sh/setup.sh path AND the T5b existing-vault path) — never
// after a declined confirm or a failed shell-out (both return before this
// is reached).
function printUninstallFooter() {
  console.log('To uninstall later: node scripts/himmelctl/bin.js uninstall');
}

// Spawn the derived command VERBATIM (stdio inherit) and propagate its exit
// code. A launch failure (e.g. the launcher missing) warns and returns 1
// rather than throwing.
function runSpawn(cmd) {
  const r = spawnSync(cmd.argv[0], cmd.argv.slice(1), { stdio: 'inherit' });
  if (r.error) {
    console.error(`himmelctl: failed to launch ${cmd.argv[0]}: ${r.error.message}`);
    return 1;
  }
  return typeof r.status === 'number' ? r.status : 1;
}

// T4.5 handover.mode=external (locked O3). Reuses the CANONICAL
// scripts/handover/set-handover-dir.sh (the same script /handover-setup
// shells out to — see scripts/lib/handover-path.sh's deployment-guidance
// comment) rather than reimplementing its .env upsert logic here, so the
// wizard's write matches /handover-setup exactly. mkdir -p's the target
// first: set-handover-dir.sh is fail-closed on a not-yet-existing dir, and a
// freshly-chosen external state-repo path legitimately doesn't exist yet.
// --env-file pins the target .env explicitly (repoRoot(), honoring the
// HIMMELCTL_REPO_ROOT test seam) instead of letting the script's own git
// discovery resolve the real repo's .env under test. Output is captured
// (not inherited) so only the wizard's own ONE confirmable summary line
// prints, per the brief's exact format — not also the script's own "OK ..."
// line.
function writeHandoverDir(p) {
  const target = expandHome(p);
  const envFile = path.join(repoRoot(), '.env');
  const script = path.join(repoRoot(), 'scripts', 'handover', 'set-handover-dir.sh');
  try {
    fs.mkdirSync(target, { recursive: true });
  } catch (e) {
    console.error(`himmelctl: failed to create handover dir ${target}: ${e.message}`);
    return false;
  }
  const r = spawnSync('bash', [script, target, '--env-file', envFile], { encoding: 'utf8' });
  if (r.error || r.status !== 0) {
    const detail = (r.stderr || (r.error && r.error.message) || '').trim();
    console.error(`himmelctl: failed to write HANDOVER_DIR via ${script}${detail ? `: ${detail}` : ''}`);
    return false;
  }
  console.log(`HANDOVER_DIR -> ${target} (written to ${envFile})`);
  return true;
}

// T4.5 pluginSet=full: the DOCUMENTED per-plugin enable table (HIMMEL-816,
// docs/setup/new-machine.md § "Claude Code Plugins" — "Turn any of these
// back on with one command"). Hardcoded to match that table EXACTLY rather
// than derived from docs/setup/settings-template.json's `enabledPlugins`:
// the JSON additionally disables `qmd@qmd` (the served fork is `qmd@himmel`;
// enabling the upstream registration too would duplicate/conflict with it),
// which the doc's curated table deliberately omits — so "every false entry"
// is not the same set as "the documented enable path." Every install is
// --scope user, matching the doc literally (this is independent of the
// adopter's own --scope answer, which only applies to adopt.sh's core
// profile).
const FULL_PLUGIN_ENABLE = [
  { spec: 'github@claude-plugins-official' },
  { spec: 'feature-dev@claude-plugins-official' },
  { spec: 'plugin-dev@claude-plugins-official' },
  { spec: 'code-review@claude-plugins-official' },
  { spec: 'ralph-loop@claude-plugins-official' },
  { spec: 'pyright-lsp@claude-plugins-official' },
  { spec: 'agent-sdk-dev@claude-plugins-official' },
  { spec: 'claude-code-setup@claude-plugins-official' },
  { spec: 'code-simplifier@claude-plugins-official' },
  { spec: 'commit-commands@claude-plugins-official' },
  { spec: 'playground@claude-plugins-official' },
  { spec: 'skill-creator@claude-plugins-official' },
  { spec: 'obsidian@obsidian-skills', marketplaceAdd: 'kepano/obsidian-skills' },
  { spec: 'caveman@caveman', marketplaceAdd: 'JuliusBrussee/caveman' },
];

function fullPluginEnableCommands() {
  const cmds = [];
  for (const p of FULL_PLUGIN_ENABLE) {
    if (p.marketplaceAdd) cmds.push(['claude', 'plugin', 'marketplace', 'add', p.marketplaceAdd]);
    cmds.push(['claude', 'plugin', 'install', p.spec, '--scope', 'user']);
  }
  return cmds;
}

// Run the pluginSet=full enable step after the core install succeeded. Each
// enable is `claude plugin ...` with stdio inherit; a launch failure or a
// nonzero exit warns but does not abort the loop (each command is
// independently idempotent — a re-run retries only what failed). Routed
// through `bash -c` (not spawnSync('claude', ...) directly) for the same
// reason detectRole()/installMissing() are: Node's non-shell spawnSync does
// its own PATH resolution on win32 and can silently prefer an unrelated
// same-named binary earlier on PATH over a .cmd/.bat shim (npm-installed
// CLIs commonly ship one), whereas bash's PATH search finds the correct one
// regardless of extension — and it's what makes this hermetically testable
// with a plain script stub, mirroring every other tool-stub in this file.
// Returns the list of commands that failed (launch error OR nonzero exit)
// so the caller can surface a summary instead of the failure being silent.
function runPluginEnable() {
  const failed = [];
  for (const argv of fullPluginEnableCommands()) {
    const line = argv.map(shellQuote).join(' ');
    console.log(`himmelctl: ${line}`);
    const r = spawnSync('bash', ['-c', line], { stdio: 'inherit' });
    if (r.error) {
      console.error(`himmelctl: failed to launch: ${r.error.message}`);
      failed.push(line);
    } else if (r.status !== 0) {
      console.error(`himmelctl: command exited ${r.status}: ${line}`);
      failed.push(line);
    }
  }
  return failed;
}

// A confirm that behaves safely across the three ways runPlan reaches it:
//   - a real interactive TTY: waits for a real answer; a blank Enter (an
//     explicit 'line' with no text) resolves '' — the [Y/n] default, proceed.
//   - the tail of an interactive session whose stdin already ran out (e.g.
//     the T2 question engine hit EOF mid-flow under a forced
//     HIMMELCTL_INTERACTIVE=1): the stream 'close's with NO 'line' for this
//     question — that is not the same signal as an explicit blank-Enter, so
//     it resolves 'n' (decline) rather than silently treating a dropped
//     session as consent to run an installer.
//   - a fresh stdin with a real "y"/"n" line queued (the T4 hermetic tests
//     that exercise the confirm via --from-profile + a piped answer): the
//     first 'line' event resolves normally.
function askConfirmSafe(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
    let answered = false;
    rl.question(prompt, (ans) => {
      answered = true;
      rl.close();
      resolve(ans || '');
    });
    rl.on('close', () => {
      if (!answered) resolve('n');
    });
  });
}

// T4.5 helper: --dry-run DRY-line preview for handover.mode=external and
// pluginSet=full. Shared by the main adopter/contributor dry-run preview and
// the T5b existing-vault dry-run preview (FIX 5) so both branches honor the
// same two answers identically instead of only the main path previewing them.
function previewHandoverAndPlugins(answers) {
  if (answers.handover && answers.handover.mode === 'external') {
    const envFile = path.join(repoRoot(), '.env');
    console.log(`DRY: HANDOVER_DIR -> ${expandHome(answers.handover.path)} (would write to ${envFile})`);
  }
  if (answers.pluginSet === 'full') {
    for (const c of fullPluginEnableCommands()) console.log(`DRY: ${c.join(' ')}`);
  }
}

// T4.5 helper: handover.mode=external write, fail-closed (FIX 3 semantics).
// inline → no-op. Returns true if the caller may proceed, false if the
// caller must abort with rc=1 (writeHandoverDir already printed the error).
// Shared by the main path and the T5b existing-vault path (FIX 5).
function applyHandoverStep(answers) {
  if (answers.handover && answers.handover.mode === 'external') {
    return writeHandoverDir(answers.handover.path);
  }
  return true;
}

// T4.5 helper: pluginSet=full enable step + WARN failure summary (FIX 4
// semantics). lean → no-op. Returns 0 normally, 1 if any plugin command
// failed (the core install already succeeded, so the caller still prints the
// uninstall footer). Shared by the main path and the T5b existing-vault path
// (FIX 5).
function applyPluginStep(answers) {
  if (answers.pluginSet !== 'full') return 0;
  const failed = runPluginEnable();
  if (failed.length === 0) return 0;
  const total = fullPluginEnableCommands().length;
  console.error(`himmelctl: WARN: ${failed.length} of ${total} plugin command(s) failed — re-run install to retry (idempotent)`);
  return 1;
}

// T4/T4.5/T5a/T5b plan: derivation, vault gate, handover/pluginSet, shell-out.
async function runPlan(answers, args) {
  // T5b (locked O1): adopter + vault.mode=existing is handled here, STAMPED
  // vaults only — non-luna→luna conversion stays deferred. Only the adopter
  // path's profile depends on vault mode (contributor's setup.sh takes no
  // vault-related flag at all), so the gate is scoped to role=adopter.
  if (answers.role === 'adopter' && answers.vault && answers.vault.mode === 'existing') {
    process.stdout.write(serialize(answers) + '\n');
    const vaultPath = expandHome(answers.vault.path);
    if (!isStampedLunaVault(vaultPath)) {
      // UNSTAMPED: refuse. Derive nothing, shell out to nothing (the stamp
      // check above is a pure fs read); exit non-zero in non-dry-run mode
      // (never silently pretend the flow ran). --dry-run prints the same
      // would-be refusal and exits 0, matching every other dry-run preview.
      console.log('himmelctl: non-luna→luna conversion is deferred; see HIMMEL-862 §5.3/§5.8.');
      return args.dryRun ? 0 : 1;
    }
    // STAMPED: derive the two-command plan (wire THEN apply) and print it.
    const plan = deriveExistingVaultPlan(answers);
    console.log(`derived: ${displayCommand(plan.wire)}`);
    console.log(`derived: ${displayCommand(plan.apply)}`);
    // FIX 5: this branch honors handover/pluginSet exactly like the main
    // path below — dry-run preview, the fail-closed handover write, and the
    // plugin-enable step were previously dropped here entirely.
    if (args.dryRun) {
      previewHandoverAndPlugins(answers);
      return 0;
    }
    if (isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log('himmelctl: declined; nothing run.');
        return 0;
      }
    }
    if (!applyHandoverStep(answers)) return 1;
    const wireRc = runSpawn(plan.wire);
    if (wireRc !== 0) return wireRc;
    const applyRc = runSpawn(plan.apply);
    if (applyRc !== 0) return applyRc;
    const pluginRc = applyPluginStep(answers);
    printUninstallFooter();
    return pluginRc;
  }

  const cmd = deriveCommand(answers);
  process.stdout.write(serialize(answers) + '\n');
  console.log(`derived: ${displayCommand(cmd)}`);

  // --dry-run prints the plan (+ T4.5 side effects) and exits WITHOUT
  // executing or mutating anything.
  if (args.dryRun) {
    previewHandoverAndPlugins(answers);
    return 0;
  }

  // The confirm is only meaningful when someone is actually there to answer
  // it. Non-interactive is only reachable here via --from-profile (cmdInstall
  // refuses non-interactive without one) — that IS the explicit unattended-
  // execution consent, so skip the prompt entirely rather than block on (or
  // mis-resolve) a stream with nobody to answer it.
  if (isInteractive(args)) {
    const ans = await askConfirmSafe('Proceed? [Y/n] ');
    if (/^\s*n/i.test(ans)) {
      console.log('himmelctl: declined; nothing run.');
      return 0;
    }
  }

  // T4.5: handover.mode=external → persist HANDOVER_DIR before the install.
  // inline → no-op (adopt.sh's/setup.sh's own inline handovers/ default).
  // Fail-closed: a failed write must abort BEFORE the core install shell-out
  // rather than silently proceed with an unwired handover destination.
  if (!applyHandoverStep(answers)) return 1;

  // T4: execute the derived command VERBATIM; propagate its rc (skip the
  // post-install enable step if the core install itself failed).
  const rc = runSpawn(cmd);
  if (rc !== 0) return rc;

  // T4.5: pluginSet=full → the documented per-plugin enable step. lean → no-op
  // (adopt.sh's/setup.sh's settings-template default, HIMMEL-816).
  const pluginRc = applyPluginStep(answers);
  printUninstallFooter();
  return pluginRc;
}

// `install` subcommand handler. T1: the preflight-first gate runs BEFORE any
// question (the question engine is T2).
async function cmdInstall(args) {
  // 0. --from-profile: load + validate the FULL schema BEFORE any side
  //    effect (CR r6) — previously the missing-tool install offer (step 3,
  //    which can run package-manager installs after a y/N) preceded profile
  //    validation, so a malformed profile could still trigger installs
  //    before being rejected. loadProfile is a pure read+validate: invalid
  //    schema exits 2 naming the field; unreadable/non-JSON throws to
  //    main()'s catch (exit 1). No stdin wait either way.
  let profileAnswers = null;
  if (args.fromProfile) profileAnswers = loadProfile(args.fromProfile);

  // 1. Hard-gate tool check.
  let missing = hardGateCheck();
  // 2. Run preflight-adopter.sh; its advisories print verbatim.
  runPreflight();
  // 3. Missing tools → install-if-missing offer (interactive) or remediation.
  if (missing.length > 0) {
    const ok = await handleMissing(missing, args);
    if (!ok) return 1;
    missing = [];
  }
  // 4. All present.
  console.log('preflight OK');

  // 5. T2/T3: gather answers. --from-profile was already loaded + validated
  //    at step 0 (CR r5 full-schema validation, CR r6 validate-before-side-
  //    effects ordering); otherwise the question engine prompts interactively
  //    (and caches the result); --dry-run previews all defaults.
  //    Non-interactive with no profile refuses cleanly — it NEVER blocks on
  //    stdin.
  let answers;
  if (profileAnswers) {
    answers = profileAnswers;
  } else if (shouldPrompt(args)) {
    answers = await askQuestions();
    writeCache(answers);
  } else if (args.dryRun) {
    answers = defaultAnswers();
  } else {
    console.error('himmelctl: non-interactive install requires --from-profile <path>');
    console.error('  (or set HIMMELCTL_INTERACTIVE=1 to answer prompts interactively)');
    return 1;
  }

  // T4/T4.5/T5a: derivation, vault gate, handover/pluginSet, shell-out.
  return await runPlan(answers, args);
}

// ── uninstall (§5.5 locked decision, operator 2026-07-11) ───────────────────
//
// A THIN wrapper: summary + one confirm (same blank-Enter/EOF semantics as
// runPlan's `Proceed?`), then exec the platform uninstall script verbatim
// (win32: uninstall.ps1 via the same interpreter selection T4 uses for
// setup.ps1). Passes through NOTHING speculative from the cached install
// profile — uninstall.sh/.ps1's own scope flags (--skip-plugins etc.) have
// no analog in the Draft-A answer schema and this subcommand does not even
// read a profile. The one flag ALWAYS added is --yes/-Yes: the wizard's own
// confirm above IS the one confirm, so the delegate script must not ask
// again (asking again would also hit an already-drained/closed stdin and
// fail-closed-abort the underlying script even after the operator said yes).

// Derive { argv } for the uninstall command, honoring the same
// HIMMELCTL_REPO_ROOT seam as deriveCommand.
function deriveUninstallCommand() {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  if (process.platform === 'win32') {
    return { argv: ['powershell', '-ExecutionPolicy', 'Bypass', '-File', path.join(scriptsDir, 'uninstall.ps1'), '-Yes'] };
  }
  return { argv: ['bash', path.join(scriptsDir, 'uninstall.sh'), '--yes'] };
}

async function cmdUninstall(args) {
  const cmd = deriveUninstallCommand();
  console.log('himmelctl: this will offboard himmel from this machine —');
  console.log('  plugins, scheduled jobs, git hooks, and settings.json wiring.');
  console.log(`derived: ${displayCommand(cmd)}`);

  // --dry-run prints the plan and exits WITHOUT asking or executing anything.
  if (args.dryRun) return 0;

  // ALWAYS ask (no --from-profile-style bypass exists for uninstall): a real
  // TTY answer resolves normally; a closed/empty stdin (piped, non-interactive)
  // declines via askConfirmSafe's EOF handling — never a silent unattended
  // uninstall.
  const ans = await askConfirmSafe('Proceed? [Y/n] ');
  if (/^\s*n/i.test(ans)) {
    console.log('himmelctl: declined; nothing run.');
    return 0;
  }
  return runSpawn(cmd);
}

async function main() {
  const argv = process.argv.slice(2);
  // --help / -h (anywhere) or no args → usage banner, exit 0.
  if (argv.length === 0 || argv.indexOf('-h') !== -1 || argv.indexOf('--help') !== -1) {
    console.log(USAGE);
    return 0;
  }
  const args = parseArgs(argv);
  if (args.subcommand === null) {
    // Flags but no subcommand → print the usage banner (matches --help).
    console.log(USAGE);
    return 0;
  }
  if (args.subcommand === 'install') {
    return await cmdInstall(args);
  }
  if (args.subcommand === 'uninstall') {
    return await cmdUninstall(args);
  }
  // parseArgs already rejected unknown subcommands, so this is unreachable.
  console.error(`himmelctl: unknown command: ${args.subcommand}`);
  return 2;
}

main()
  .then((code) => process.exit(typeof code === 'number' ? code : 0))
  .catch((err) => {
    console.error(`himmelctl: ${err && err.message ? err.message : err}`);
    process.exit(1);
  });
