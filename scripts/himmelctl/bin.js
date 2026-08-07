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
//   node scripts/himmelctl/bin.js update [--dry-run]
//   node scripts/himmelctl/bin.js status [--items <a,b>] [--json]

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');
const { cacheDir, profileForVault, which } = require('./lib/helpers.js');
const stateLib = require('./lib/state.js');
const statusReportLib = require('./lib/status-report.js');
const installEngineLib = require('./lib/install-engine.js');
const probesLib = require('./lib/probes.js');
const depsEngineLib = require('./lib/deps-engine.js');
const adopterProfileLib = require('./lib/adopter-profile.js');
const contributorProfileLib = require('./lib/contributor-profile.js');

// Tools every himmel adopter needs before any question makes sense — mirrors
// adopt.sh require_tools (bash/git/jq/python3) PLUS at least one JS package
// manager (npm or bun). npm is the recommended install when both are absent.
const HARD_GATE_TOOLS = ['bash', 'git', 'jq', 'python3'];

const USAGE = `usage: himmelctl <command> [options]

commands:
  install                install himmel into this project or your user scope
  uninstall               offboard himmel from this machine (thin wrapper)
  update                  update this himmel checkout — thin wrapper around
                          scripts/himmel-update.sh (same engine as
                          /himmel-update): full dependency-chain check/update
                          with per-item status + abort-on-first-failure
  status                  read-only severity diff of installed vs desired items;
                          run from the adopted project's root for project scope,
                          or from the himmel checkout for user scope
  ensure                  converge this target toward its desired manifest state:
                          installs/wires whatever status reports red/degraded,
                          AND unwires/disables removable items that are no longer
                          desired — so a reconcile can REMOVE wiring, not only add
                          it (notably under --yes, which skips the confirmation);
                          run from the same location the corresponding install
                          was run from, same as status
  config                  interactive TUI to toggle himmel capabilities (initiative
                          legs, delegation lanes, opt-in hooks) without hand-editing
                          files; or non-interactively:
                            config set <path> <value>   (value is on|off)
                            config get <path>
                          get/set paths: initiative.<leg>, lanes.<id>
                          set-only: hooks.plugin.<name> (runs claude plugin
                            enable/disable). hooks.improveOnSubmit is a
                            launching-shell env var, not settable here; config
                            get does not report hook state (rc 2)
  scope                   switch the install's scope, or read it:
                          'scope get' / 'scope status' print the current scope;
                          'scope set <project|user>' re-projects the install to
                          the target scope — wires the target scope AND unwires
                          the old scope (interactive confirm; --yes skips it;
                          --dry-run prints the plan); refuses to leave any item
                          wired in BOTH scopes (fail-closed)
  trust on|off|status     wire, unwire, or report the trust shadow ledger's hook
                          entries in this project's .claude/settings.json
                          (HIMMEL-1551; recorder HIMMEL-1529/1539/1547).
                          Idempotent, and 'off' removes only
                          what it added — the recorder's whole claim is that
                          adding it and removing it are both zero behaviour
                          change. (Exactly byte-for-byte for any file with
                          existing hooks; an event array that was EMPTY and then
                          wired into normalizes to absent, which is invisible to
                          every consumer.) Hooks take effect on the next matching
                          event — no restart needed (measured, HIMMEL-1561).
                          Confirm with
                          'node scripts/trust/shadow-ledger.mjs report':
                          it must show non-zero rows AND a PROVEN collection
                          line. "It is wired" is a different claim from "it is
                          recording", and both are different from "the rate can
                          be trusted"
  deps status             read-only version/presence check of the declared
                          toolchain (scripts/install/deps.json)
  deps ensure             install MISSING declared toolchain deps via their
                          per-OS recipe
  deps upgrade            bump present declared toolchain deps toward latest;
                          qmd's model pull (~2.1 GB) is gated behind a prompt
                          or --with-models

options:
  --from-profile <path>  install non-interactively from a saved profile cache
  --default-scope <s>    install question default: project|user (answer remains confirmable)
  --lanes <csv>          install (adopter): the delegation lanes to select —
                          ${adopterProfileLib.SELECTABLE_LANE_IDS.join('|')}, or 'none'
                          (default: ${adopterProfileLib.DEFAULT_LANE_IDS.join(',')}). Skips the lanes question.
  --with-codex           install (adopter): additionally select the codex lane (opt-in)
  --with-hermes          install (adopter): additionally select the hermes lane (opt-in)
                          Selecting a lane records the choice, probes it, and on an
                          applied adopter install persists a resolver allowlist.
                          Selected lanes still have to pass their real probes; the
                          allowlist only suppresses non-selected optional lanes.
                          It does NOT install a lane CLI or force a lane present.
  --advanced             reserved: surface advanced options (parsed, not yet honored)
  --dry-run              print the derived plan/actions without executing
  --items <a,b>          status/ensure: scope the run to these item ids (comma list)
  --json                 status/deps status: emit stable machine-readable JSON instead of text
  --profile <p>          ensure: reconcile the target to this profile first (core|luna|all)
  --yes                  ensure/deps ensure/deps upgrade: skip the confirmation
  --with-models          deps upgrade: pull qmd's embedding/rerank models
                          (~2.1 GB) non-interactively, without the prompt
  -h, --help             show this help`;

// Per-subcommand option whitelists, keyed by the SAME property names
// parseArgs sets on `args` — used by parseArgs's own trailing validation
// pass below. Kept beside parseArgs (not inline in the function) so the
// three tables stay visually paired: which options a subcommand allows,
// what flag text to name in an error, and what "not passed" looks like for
// each option (so passing the DEFAULT value explicitly is never flagged —
// only a genuinely-set option outside the whitelist is).
const ALLOWED_OPTIONS = {
  install: ['fromProfile', 'defaultScope', 'advanced', 'dryRun', 'lanes', 'withCodex', 'withHermes'],
  uninstall: ['dryRun'],
  update: ['dryRun'],
  status: ['items', 'json'],
  ensure: ['items', 'profile', 'yes', 'dryRun'],
  // `scope` takes its OWN positional verbs/targets (set|get|status, then
  // project|user for set) — parsed in parseArgs's scope cases, not as --flags.
  // --yes/--dry-run apply to `scope set` (get/status are pure reads that
  // ignore them); the option-validation pass keys on the subcommand only, so
  // both are admitted here and cmdScope ignores them on the read verbs.
  scope: ['yes', 'dryRun'],
  // 'deps' itself is validated per-VERB, not from this table — see
  // DEPS_VERB_ALLOWED_OPTIONS below (CR fix: CodeRabbit wanted `deps status
  // --with-models`/`deps ensure --json`/etc rejected, not silently accepted
  // the way a single shared set would). No entry needed here; the
  // validation pass below branches on args.subcommand === 'deps' before
  // ever consulting this table.
};
// deps' per-verb option whitelists — one level deeper than ALLOWED_OPTIONS
// (keyed by args.depsVerb, not args.subcommand): status only reads json;
// ensure only reads dryRun/yes; upgrade reads dryRun/yes/withModels. Same
// table shape/lookup pattern as ALLOWED_OPTIONS, just keyed by verb for
// this one subcommand — `deps status --with-models` or `deps ensure --json`
// now gets the SAME "not valid with" rejection every other subcommand's
// mismatched flag already gets, instead of silently parsing fine and never
// being consulted.
const DEPS_VERB_ALLOWED_OPTIONS = {
  status: ['json'],
  ensure: ['dryRun', 'yes'],
  upgrade: ['dryRun', 'yes', 'withModels'],
};
const OPTION_FLAGS = {
  fromProfile: '--from-profile', defaultScope: '--default-scope', advanced: '--advanced', dryRun: '--dry-run',
  items: '--items', json: '--json', profile: '--profile', yes: '--yes',
  withModels: '--with-models',
  lanes: '--lanes', withCodex: '--with-codex', withHermes: '--with-hermes',
};
const OPTION_DEFAULTS = {
  fromProfile: null, defaultScope: null, advanced: false, dryRun: false, items: null, json: false, profile: null, yes: false,
  withModels: false,
  lanes: null, withCodex: false, withHermes: false,
};

// Parse the CLI args into a plain object. Unknown args are a hard error (exit
// 2) so a typo doesn't silently fall through to a no-op install. A second
// subcommand (even a repeat) is the same class of hard error — previously
// `himmelctl install uninstall` silently ran uninstall (the later token won).
function parseArgs(argv) {
  const args = {
    subcommand: null,
    fromProfile: null, // reserved (T0: parse only)
    defaultScope: null, // install question default: project|user (null = project)
    advanced: false,   // reserved (T0: parse only)
    dryRun: false,
    items: null,       // status/ensure: --items comma list (null = no filter)
    json: false,       // status: --json
    profile: null,     // ensure: --profile (null = keep the target's stored profile)
    yes: false,        // ensure/scope/deps ensure/deps upgrade: --yes
    scopeVerb: null,   // scope: 'set' | 'get' | 'status' (null = none given)
    trustVerb: null,   // trust: 'on' | 'off' | 'status' (null = none given, HIMMEL-1551)
    targetScope: null, // scope set: 'project' | 'user' (null = none given)
    depsVerb: null,    // deps: status|ensure|upgrade (consumed positionally, see the 'deps' case)
    withModels: false, // deps upgrade: --with-models
    lanes: null,       // install: --lanes csv (null = ask, or take the default)
    withCodex: false,  // install: --with-codex (opt-in lane)
    withHermes: false, // install: --with-hermes (opt-in lane)
  };
  // CR fix (CodeRabbit round 17, item 4): the last process.exit(2) sites in
  // this parser, converted to the process.exitCode + return pattern the
  // --profile/unknown-arg paths below already document (process.exit()
  // terminates synchronously and can truncate a still-buffered
  // console.error() -- piped stderr, e.g. every hermetic test's $(...)
  // capture, is especially exposed on Windows). setSubcommand can't `return
  // args` from parseArgs itself (it's a nested closure), so it reports
  // failure to its caller instead and each call site returns.
  const setSubcommand = (name) => {
    if (args.subcommand !== null) {
      console.error(`himmelctl: multiple subcommands given ('${args.subcommand}' and '${name}')`);
      console.error("Run 'himmelctl --help' for usage.");
      process.exitCode = 2;
      return false;
    }
    args.subcommand = name;
    return true;
  };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    switch (a) {
      case 'install':
        if (!setSubcommand('install')) return args;
        break;
      case 'uninstall':
        if (!setSubcommand('uninstall')) return args;
        break;
      case 'update':
        if (!setSubcommand('update')) return args;
        break;
      case 'status':
        // `status` is ALSO a `scope` verb (scope get/status). Under `scope`
        // it is a positional, not a subcommand; only otherwise is it the
        // read-only status subcommand.
        if (args.subcommand === 'scope') {
          if (args.scopeVerb !== null) {
            console.error(`himmelctl: scope takes exactly one verb (set|get|status) — saw '${args.scopeVerb}' and 'status'`);
            console.error("Run 'himmelctl --help' for usage.");
            process.exitCode = 2;
            return args;
          }
          args.scopeVerb = 'status';
          break;
        }
        // Same shape under `trust` (HIMMEL-1551): a positional verb, not the
        // read-only `status` subcommand.
        if (args.subcommand === 'trust') {
          if (args.trustVerb !== null) {
            console.error(`himmelctl: trust takes exactly one verb (on|off|status) — saw '${args.trustVerb}' and 'status'`);
            console.error("Run 'himmelctl --help' for usage.");
            process.exitCode = 2;
            return args;
          }
          args.trustVerb = 'status';
          break;
        }
        if (!setSubcommand('status')) return args;
        break;
      case 'ensure':
        if (!setSubcommand('ensure')) return args;
        break;
      case 'scope':
        if (!setSubcommand('scope')) return args;
        break;
      // HIMMEL-1551: the trust ledger's hook wiring. It exists as a command
      // because the recorder previously shipped behind a manual paste of six
      // JSON blocks, and three consecutive chain legs measured zero rows as a
      // result. A capability behind a manual paste is a capability that does
      // not ship.
      case 'trust':
        if (!setSubcommand('trust')) return args;
        break;
      case 'on':
      case 'off':
        // ONLY meaningful under `trust`; anywhere else these fall through to
        // the unknown-argument error, exactly as `set`/`get` do under `scope`.
        if (args.subcommand !== 'trust') {
          console.error(`himmelctl: unknown argument: ${a}`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        if (args.trustVerb !== null) {
          console.error(`himmelctl: trust takes exactly one verb (on|off|status) — saw '${args.trustVerb}' and '${a}'`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        args.trustVerb = a;
        break;
      // `scope` positionals (verb then, for set, target). These tokens are
      // ONLY meaningful under `scope`; under any other (or no) subcommand
      // they fall through to the unknown-argument error at the bottom of
      // this block, preserving the prior rejection of e.g. `himmelctl set`.
      case 'set':
      case 'get':
        if (args.subcommand !== 'scope') {
          console.error(`himmelctl: unknown argument: ${a}`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        if (args.scopeVerb !== null) {
          console.error(`himmelctl: scope takes exactly one verb (set|get|status) — saw '${args.scopeVerb}' and '${a}'`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        args.scopeVerb = a;
        break;
      case 'project':
      case 'user':
        if (args.subcommand !== 'scope' || args.scopeVerb !== 'set') {
          console.error(`himmelctl: '${a}' is only valid as 'himmelctl scope set <project|user>'`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        if (args.targetScope !== null) {
          console.error(`himmelctl: scope set takes exactly one target (project|user) — saw '${args.targetScope}' and '${a}'`);
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        args.targetScope = a;
        break;
      case 'deps': {
        // Consumes its verb (status|ensure|upgrade) as part of THIS case —
        // 'status'/'ensure' are already top-level subcommand tokens above,
        // so advancing `i` here (rather than letting the loop see the verb
        // as its own token) is what avoids `deps status` colliding with the
        // bare `status` subcommand's own case.
        if (!setSubcommand('deps')) return args;
        const verb = argv[++i];
        if (verb === undefined || ['status', 'ensure', 'upgrade'].indexOf(verb) === -1) {
          console.error("himmelctl: 'deps' requires a verb: status|ensure|upgrade");
          console.error("Run 'himmelctl --help' for usage.");
          process.exitCode = 2;
          return args;
        }
        args.depsVerb = verb;
        break;
      }
      case '--with-models':
        args.withModels = true;
        break;
      case '--items': {
        const raw = argv[++i];
        if (raw === undefined) {
          console.error('himmelctl: --items requires a comma-separated id list');
          process.exitCode = 2;
          return args;
        }
        args.items = raw.split(',').map((s) => s.trim()).filter(Boolean);
        if (args.items.length === 0) {
          console.error('himmelctl: --items requires at least one non-empty id');
          process.exitCode = 2;
          return args;
        }
        break;
      }
      case '--json':
        args.json = true;
        break;
      case '--from-profile':
        args.fromProfile = argv[++i];
        if (args.fromProfile === undefined) {
          console.error('himmelctl: --from-profile requires a path argument');
          process.exitCode = 2;
          return args;
        }
        break;
      case '--default-scope':
        args.defaultScope = argv[++i];
        if (['project', 'user'].indexOf(args.defaultScope) === -1) {
          console.error(`himmelctl: --default-scope must be one of project|user (got ${args.defaultScope})`);
          process.exitCode = 2;
          return args;
        }
        break;
      case '--advanced':
        args.advanced = true;
        break;
      // HIMMEL-862: the v1 adopter lane subset. Validated HERE (not at use
      // time) so a typo'd lane id is rejected before the preflight ever runs
      // a package-manager install — same posture as --default-scope above.
      case '--lanes': {
        const v = argv[++i];
        if (v === undefined) {
          console.error(`himmelctl: --lanes requires a value (${adopterProfileLib.SELECTABLE_LANE_IDS.join('|')}, comma-separated, or 'none')`);
          process.exitCode = 2;
          return args;
        }
        const parsed = adopterProfileLib.parseLaneList(v);
        if (!parsed.ok) {
          console.error(`himmelctl: --lanes: ${parsed.error}`);
          process.exitCode = 2;
          return args;
        }
        args.lanes = parsed.lanes;
        break;
      }
      case '--with-codex':
        args.withCodex = true;
        break;
      case '--with-hermes':
        args.withHermes = true;
        break;
      case '--dry-run':
        args.dryRun = true;
        break;
      case '--profile':
        args.profile = argv[++i];
        if (args.profile === undefined) {
          console.error('himmelctl: --profile requires a value (core|luna|all)');
          // CR fix: process.exitCode (not process.exit()) — the latter
          // terminates synchronously and can truncate a console.error()
          // write that's still buffered (stdout/stderr piped rather than a
          // TTY, e.g. every hermetic test's `$(...)` capture, is
          // particularly exposed on Windows). Setting exitCode + returning
          // lets the event loop drain naturally so the diagnostic flushes
          // before the process actually exits; main() below checks for
          // this and stops dispatching to a subcommand.
          process.exitCode = 2;
          return args;
        }
        if (['core', 'luna', 'all'].indexOf(args.profile) === -1) {
          console.error(`himmelctl: --profile must be one of core|luna|all (got ${args.profile})`);
          process.exitCode = 2;
          return args;
        }
        break;
      case '--yes':
        args.yes = true;
        break;
      default:
        console.error(`himmelctl: unknown argument: ${a}`);
        console.error("Run 'himmelctl --help' for usage.");
        // CR fix: process.exitCode (not process.exit()) — same flush hazard
        // already fixed for --profile validation above: process.exit()
        // terminates synchronously and can truncate a still-buffered
        // console.error() write (piped stdout/stderr, e.g. every hermetic
        // test's `$(...)` capture, is particularly exposed on Windows).
        // Setting exitCode + returning lets both diagnostics flush before
        // the process actually exits; main() already checks for this.
        process.exitCode = 2;
        return args;
    }
  }
  // CR fix: per-subcommand option validation. Every flag above is parsed
  // GLOBALLY (order-independent — a flag can appear before or after its
  // subcommand token), but each subcommand only READS a specific subset of
  // them (see cmdInstall/cmdUninstall/cmdStatus/cmdEnsure's own args.*
  // reads). Before this, a misdirected combo like `status --profile core`
  // or `ensure --json` was silently ACCEPTED — the extra flag was parsed
  // fine, just never consulted, with no signal to the caller that they'd
  // typo'd or misunderstood which command takes it. Checked once here,
  // after the full parse loop (so it sees every flag regardless of where
  // it appeared), against every option NOT valid for the parsed
  // subcommand. Skipped entirely when no subcommand was given — main()'s
  // own no-subcommand branch just prints the usage banner regardless of
  // flags, unchanged.
  if (args.subcommand !== null) {
    // 'deps' validates against its VERB's whitelist (DEPS_VERB_ALLOWED_OPTIONS,
    // keyed by args.depsVerb) instead of ALLOWED_OPTIONS[args.subcommand] —
    // see that table's own comment for why a single shared set isn't precise
    // enough. Every other subcommand is unaffected.
    const isDeps = args.subcommand === 'deps';
    const allowed = isDeps ? (DEPS_VERB_ALLOWED_OPTIONS[args.depsVerb] || []) : (ALLOWED_OPTIONS[args.subcommand] || []);
    const label = isDeps ? `deps ${args.depsVerb}` : args.subcommand;
    for (const key of Object.keys(OPTION_DEFAULTS)) {
      if (allowed.indexOf(key) !== -1) continue;
      if (args[key] !== OPTION_DEFAULTS[key]) {
        console.error(`himmelctl: ${OPTION_FLAGS[key]} is not valid with '${label}'`);
        console.error("Run 'himmelctl --help' for usage.");
        // Same exitCode-not-exit() pattern as the --profile validation
        // above — see its own comment for why.
        process.exitCode = 2;
        return args;
      }
    }
    // HIMMEL-862: a saved profile already CARRIES its lane selection, and
    // --from-profile is explicit unattended-execution consent to replay that
    // file verbatim. Silently letting a lane flag override one field of it
    // would make the replayed install differ from the profile it names, so
    // the combination is refused outright rather than resolved by precedence.
    if (args.subcommand === 'install' && args.fromProfile !== null) {
      for (const key of ['lanes', 'withCodex', 'withHermes']) {
        if (args[key] !== OPTION_DEFAULTS[key]) {
          console.error(`himmelctl: ${OPTION_FLAGS[key]} cannot be combined with --from-profile`);
          console.error('  (the profile already carries its lane selection — edit the profile, or drop --from-profile)');
          process.exitCode = 2;
          return args;
        }
      }
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

// which()/cacheDir()/profileForVault() live in lib/helpers.js (HIMMEL-756
// T1.2a extraction) — required above.

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
  const r = spawnSync(resolveBash(), [toBashPath(script)], { stdio: 'inherit' });
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
// id (mirrors scripts/machine-setup/win11.ps1's per-tool installs). Git.Git
// supplies both git and Git Bash, so a clean Windows machine can install bash
// through cmd without the old bash self-install paradox.
const WINGET_IDS = {
  bash: 'Git.Git',
  git: 'Git.Git',
  jq: 'jqlang.jq',
  python3: 'Python.Python.3.12',
  node: 'OpenJS.NodeJS.LTS',
  npm: 'OpenJS.NodeJS.LTS',
};

// Run one package-manager line and log a launch failure or nonzero exit
// instead of swallowing it. Windows uses cmd directly so the clean-machine
// winget path does not depend on Git Bash already being installed; posix keeps
// bash -c. Every line is fixed vocabulary — never user input.
function runInstallerLine(line) {
  console.error(`himmelctl: running: ${line}`);
  const r = process.platform === 'win32'
    ? spawnSync(process.env.ComSpec || 'cmd.exe', ['/d', '/s', '/c', line], { stdio: 'inherit' })
    : spawnSync(resolveBash(), ['-c', line], { stdio: 'inherit' });
  if (r.error) console.error(`himmelctl: failed to launch installer: ${r.error.message}`);
  if (typeof r.status === 'number' && r.status !== 0) console.error(`himmelctl: installer exited ${r.status}`);
}

// Install the missing hard-gate tools via the platform package manager.
// darwin/linux: ONE brew/apt invocation for the whole list. win32: one
// `winget install --id <ID> -e` per tool (see WINGET_IDS); a tool with no
// mapped id gets a manual-install pointer instead of a doomed bare-name
// query. On posix, bash cannot shell out to install itself; Windows avoids
// that paradox by running winget through cmd and mapping bash to Git.Git.
function installMissing(missing) {
  if (process.platform !== 'win32' && missing.indexOf('bash') !== -1) {
    console.error('himmelctl: bash itself is missing and cannot be self-installed via a bash shell-out.');
    console.error('  install bash via your platform package manager, then re-run himmelctl.');
    return;
  }
  if (process.platform === 'win32') {
    const installedIds = [];
    for (const tool of missing) {
      const id = WINGET_IDS[tool];
      if (!id) {
        console.error(`himmelctl: no winget id known for '${tool}' — install it manually, then re-run himmelctl.`);
        continue;
      }
      if (installedIds.indexOf(id) !== -1) continue;
      installedIds.push(id);
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
  const r = spawnSync(resolveBash(), ['-c', 'git remote get-url origin'], { encoding: 'utf8' });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { role: 'adopter', reason: 'no origin remote -> default adopter' };
  }
  const url = r.stdout.trim();
  if (/himmel(\.git)?$/i.test(url)) {
    const t = spawnSync(resolveBash(), ['-c', 'git rev-parse --show-toplevel'], { encoding: 'utf8' });
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

// Build the Draft-A answer object. `tier` is still a schema placeholder;
// `lanes`/`alwaysOn` were placeholders too until HIMMEL-862 filled them with
// the v1 adopter-user profile (contributor installs leave both at their empty
// defaults — the contributor-dev profile is HIMMEL-1423, not this ticket).
// Key ORDER is load-bearing: serialize() is the cache format AND the printed
// summary, and both must round-trip byte-for-byte through --from-profile.
function buildAnswers(role, scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet, lanes, alwaysOn) {
  return {
    role: role,
    tier: 'standard',
    scope: scope,
    vault: { mode: vaultMode, path: vaultPath },
    handover: { mode: handoverMode, path: handoverPath },
    pluginSet: pluginSet,
    lanes: lanes || [],
    lanesMeaningful: true,
    alwaysOn: Boolean(alwaysOn),
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

// HIMMEL-862: ask the lane subset. Free-form CSV (not askEnum — the answer is
// a SET, not one value), re-prompting on an invalid id the same way askEnum
// re-emits its header. Empty accepts the default; 'none' selects nothing.
async function askLanes(ask, defaultLanes) {
  const opts = adopterProfileLib.SELECTABLE_LANE_IDS.join(',');
  const prompt = `? lanes [${opts}|none] (default: ${defaultLanes.join(',') || 'none'})\n> `;
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    if (t === '') return defaultLanes.slice();
    const parsed = adopterProfileLib.parseLaneList(t);
    if (parsed.ok) return parsed.lanes;
    // CR round 1 [glm-2]: say WHY before re-prompting. parseLaneList already
    // distinguishes "unknown lane" from "that one is opt-in, use --with-<id>";
    // discarding that left a bare re-prompt that looks like the input was
    // ignored rather than rejected. The reason goes to stderr so it can never
    // be mistaken for one of the `? ...` question headers on stdout.
    console.error(`  ! ${parsed.error}`);
  }
}

// Walk all questions interactively and return the answer object.
// `laneOpts` = { lanes, withCodex, withHermes } from the CLI flags: a given
// --lanes SKIPS the lanes question entirely (the operator already answered
// it), while --with-codex/--with-hermes append to whatever the base selection
// turns out to be. Both opt-in lanes stay flag-only — the lanes question
// never offers them, so there is exactly ONE door to each.
async function askQuestions(defaultScope, laneOpts) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
  const ask = makeAsk(rl);

  // 1. role (default from the git-origin heuristic + a printed reasoning line).
  const det = detectRole();
  console.log(`detected: ${det.reason}`);
  const role = await askEnum(ask, `? role [adopter|contributor] (default: ${det.role})\n> `, ['adopter', 'contributor'], det.role);

  // 2. scope — adopter only. Contributor never asks (setup.sh is user-scope).
  const scopeDefault = defaultScope || 'project';
  let scope = scopeDefault;
  if (role === 'adopter') {
    scope = await askEnum(ask, `? scope [project|user] (default: ${scopeDefault})\n> `, ['project', 'user'], scopeDefault);
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

  // 6/7 (HIMMEL-862). ADOPTER ONLY — the contributor-dev profile is
  // HIMMEL-1423, so a contributor run asks neither and keeps the empty
  // defaults, leaving its existing 4-question flow byte-identical.
  const opts = laneOpts || {};
  let lanes = [];
  let alwaysOn = false;
  if (role === 'adopter') {
    // 6. lanes. --lanes already answered it; otherwise prompt.
    const base = opts.lanes !== null && opts.lanes !== undefined
      ? opts.lanes
      : await askLanes(ask, adopterProfileLib.DEFAULT_LANE_IDS);
    lanes = adopterProfileLib.applyOptIns(base, opts);
    // 7. alwaysOn. Decides checklist-vs-pointer only — NOTHING is executed
    //    either way (rescope: hardening is printed, never run).
    const ao = await askEnum(ask, '? always-on machine (unattended/scheduled runs) [yes|no] (default: no)\n> ', ['yes', 'no'], 'no');
    alwaysOn = ao === 'yes';
  }

  rl.close();
  return buildAnswers(role, role === 'contributor' ? 'user' : scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet, lanes, alwaysOn);
}

// All-default answers (no prompts) for --dry-run previews. Still prints the
// role reasoning line so the preview shows what would happen.
function defaultAnswers(defaultScope, laneOpts) {
  const det = detectRole();
  console.log(`detected: ${det.reason}`);
  const opts = laneOpts || {};
  // The lane rows honor the flags even in an all-defaults preview, so
  // `--dry-run --with-codex` actually previews the codex lane.
  const lanes = det.role === 'adopter'
    ? adopterProfileLib.applyOptIns(
      (opts.lanes !== null && opts.lanes !== undefined) ? opts.lanes : adopterProfileLib.DEFAULT_LANE_IDS,
      opts,
    )
    : [];
  return buildAnswers(det.role, det.role === 'contributor' ? 'user' : (defaultScope || 'project'), 'none', '', 'inline', '', 'lean', lanes, false);
}

// ── T3: answer schema + cache ────────────────────────────────────────────────
//
// The interactive answers are cached so the same install can be replayed
// non-interactively via --from-profile. The cache dir defaults to
// ~/.claude/himmel/ but is overridable via HIMMELCTL_CACHE_DIR — same class of
// seam as HIMMELCTL_INTERACTIVE, and genuinely useful for CI (and essential
// for hermetic tests: under Git Bash, HOME does NOT propagate into node.exe
// children, so ~/.claude/himmel/ cannot be redirected via fake-HOME alone).
// (cacheDir() itself lives in lib/helpers.js — required above.)

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
  // HIMMEL-862: lanes/alwaysOn join the strictly-validated set for the same
  // reason every other field is in it — --from-profile is unattended-execution
  // consent, so a skewed field must fail loud BEFORE any side effect rather
  // than be silently reinterpreted. Note the OPT-IN lanes ARE accepted here: a
  // profile is an explicit, hand-reviewed artifact, so naming codex/hermes in
  // it IS the consent that --with-codex/--with-hermes provides on the command
  // line.
  if (!Array.isArray(obj.lanes)) {
    profileError(p, `field 'lanes' must be an array (got ${JSON.stringify(obj.lanes)})`);
  }
  for (const l of obj.lanes) {
    if (adopterProfileLib.ALL_LANE_IDS.indexOf(l) === -1) {
      profileError(p, `field 'lanes' contains unknown lane ${JSON.stringify(l)} (known: ${adopterProfileLib.ALL_LANE_IDS.join(', ')})`);
    }
  }
  // Pre-HIMMEL-862 caches carried lanes:[] only as a schema placeholder. A new
  // profile marks the field meaningful so [] can safely mean explicit none;
  // legacy profiles that name lanes explicitly remain unambiguous and valid.
  if (obj.lanesMeaningful !== undefined && obj.lanesMeaningful !== true) {
    profileError(p, `field 'lanesMeaningful' must be true when present (got ${JSON.stringify(obj.lanesMeaningful)})`);
  }
  // HIMMEL-1470: the lanes question is adopter-only — buildAnswers gives a
  // contributor lanes:[] and applyLaneProfileStep short-circuits non-adopter —
  // so the legacy-placeholder refusal must NOT fire for a contributor. A
  // pre-HIMMEL-862 contributor cache (lanes:[] with no lanesMeaningful) used
  // to be wrongly exit-2'd over a field the role never answers; gating on
  // adopter keeps the caseD2 refusal where lanes is meaningful and lets the
  // contributor profile through (its [] is a harmless placeholder).
  if (obj.role === 'adopter' && obj.lanes.length === 0 && obj.lanesMeaningful !== true) {
    profileError(p, "legacy profile has lanes:[] without lanesMeaningful=true; re-run the installer and reconfirm lane selection (use 'none' for an explicit empty allowlist)");
  }
  if (typeof obj.alwaysOn !== 'boolean') {
    profileError(p, `field 'alwaysOn' must be a boolean (got ${JSON.stringify(obj.alwaysOn)})`);
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
// (profileForVault() itself lives in lib/helpers.js — required above.)

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

// Fail before the install/wire/plugin steps when their target settings file
// cannot be written. Existing files are checked directly; for a not-yet-created
// file, check the nearest existing parent that would need to create it.
function settingsTargetsWritable(answers) {
  const targets = [settingsPathForScope(answers.scope)];
  if (answers.pluginSet === 'full') targets.push(settingsPathForScope('user'));
  for (const target of targets.filter((p, i, all) => all.indexOf(p) === i)) {
    let probe = target;
    while (!fs.existsSync(probe)) {
      const parent = path.dirname(probe);
      if (parent === probe) break;
      probe = parent;
    }
    try {
      if (probe === target && !fs.statSync(probe).isFile()) throw new Error('target is not a regular file');
      if (probe !== target && !fs.statSync(probe).isDirectory()) throw new Error('parent is not a directory');
      fs.accessSync(probe, fs.constants.W_OK);
    } catch (e) {
      const code = e && e.code ? ` (${e.code})` : '';
      console.error(`himmelctl: target settings.json is not writable: ${target}${code}`);
      return false;
    }
  }
  return true;
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
    wire: { argv: [resolveBash(), toBashPath(path.join(scriptsDir, 'lib', 'wire-luna-vault.sh')), toBashPath(settings), toBashPath(vaultPath)] },
    apply: { argv: [resolveBash(), toBashPath(path.join(scriptsDir, 'luna-upgrade-all.sh')), 'apply', '--vault', toBashPath(vaultPath)] },
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
    return { argv: [resolveBash(), toBashPath(path.join(scriptsDir, 'setup.sh'))] };
  }
  const argv = [resolveBash(), toBashPath(path.join(scriptsDir, 'adopt.sh'))];
  const profile = profileForVault(answers);
  argv.push('--profile', profile, '--scope', answers.scope || 'project');
  if (profile === 'all' && answers.vault && answers.vault.path) {
    argv.push('--luna-target', toBashPath(expandHome(answers.vault.path)));
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
  const r = spawnSync(resolveBash(), [toBashPath(script), target, '--env-file', toBashPath(envFile)], { encoding: 'utf8' });
  if (r.error || r.status !== 0) {
    const detail = (r.stderr || (r.error && r.error.message) || '').trim();
    console.error(`himmelctl: failed to write HANDOVER_DIR via ${script}${detail ? `: ${detail}` : ''}`);
    return false;
  }
  console.log(`HANDOVER_DIR -> ${target} (written to ${envFile})`);
  return true;
}

// T4.5 pluginSet=full: load the canonical documented enable table from data,
// rather than keeping a second inline copy that can drift. This is deliberately
// separate from settings-template.json's broader enabledPlugins map: qmd@qmd
// must stay excluded because himmel serves qmd@himmel instead. Every install is
// --scope user, independent of the adopter's core-install scope answer.
let fullPluginEnableCache = null;
function fullPluginEnable() {
  if (fullPluginEnableCache !== null) return fullPluginEnableCache;
  const dataPath = path.join(repoRoot(), 'scripts', 'machine-setup', 'full-plugin-enable.json');
  const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
  if (!Array.isArray(data.plugins)) throw new Error(`invalid full plugin data: ${dataPath}`);
  fullPluginEnableCache = data.plugins;
  return fullPluginEnableCache;
}

function fullPluginEnableCommands() {
  const cmds = [];
  for (const p of fullPluginEnable()) {
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
    const r = spawnSync(resolveBash(), ['-c', line], { stdio: 'inherit' });
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

// HIMMEL-862: the adopter-user epilogue — lane probe report, the always-on
// hardening CHECKLIST, and the final honest summary. Printed at the END of
// every adopter run, dry-run included: every part of it is a READ — it mutates
// nothing — so it is equally truthful before and after the install shell-out,
// and a --dry-run preview is worth exactly as much. (Corrected in CR round 5:
// this used to claim "probeLane never spawns", which is false — buildCtx shells
// out to `git`, and the manifest-backed readiness probes may run a tool to
// check it. Probing under --dry-run is fine; documenting a guarantee we do not
// provide is not.)
//
// Contributor runs print nothing here — the contributor-dev profile is
// HIMMEL-1423, and inventing half of it now would be the speculative
// machinery this v1 is explicitly scoped away from.
// `dryRun` is threaded in (not re-derived from args) so the summary's
// installed-vs-planned bucket can never drift from what the caller actually
// did — CR round 1 [codex-1]: the summary used to claim `installed:` under
// --dry-run, when nothing had run at all.
// `pluginResult` is the {rc, failed, total} applyPluginStep returned, or null
// when the step never ran (dry-run, lean plugin set, or the T5b branch's own
// ordering) — CR round 1 [codex-adv-2]: without it the summary claimed the
// full plugin set was enabled even when its commands had failed.
//
// async because the lane probe now loads the CANONICAL ESM resolver rather
// than re-implementing its semantics; every call site is already inside the
// async runPlan.
async function printContributorProfile(answers, derived, dryRun) {
  if (answers.role !== 'contributor') return;
  // HIMMEL-1466: the contributor profile runs AFTER the core install already
  // succeeded (dry-run path ~1474; applied path ~1550, right after runSpawn and
  // the PATH-launcher write). It is reporting, not gating, so a failure in the
  // report build — a missing/malformed scripts/install/manifest.json (the
  // #1530 regression), a missing deps.json, or any probe throw — must never
  // abort the install. Pre-fix, loadManifest()'s throw escaped here to main()'s
  // catch and turned a green install into exit 1. Mirror the cmdUninstall guard
  // (~1756): WARN via console.error naming the error, skip ONLY the profile
  // report, leave the install rc untouched.
  let report;
  try {
    report = await contributorProfileLib.buildReport({
      repoRoot: repoRoot(),
      env: process.env,
      platform: process.platform,
    });
  } catch (e) {
    // HIMMEL-1466 made this non-gating; HIMMEL-1468 hardens the catch itself:
    // buildReport() is third-party-shaped and could reject with null/undefined
    // (a non-Error rejection), in which case reading e.message would itself
    // throw and re-escape as exit 1 — the exact abort the guard exists to prevent.
    // HIMMEL-1476: stringifying the rejection is the last throw site — coercing
    // a {message: Symbol()} or Object.create(null) (no toString) rejection would
    // throw, re-escaping as exit 1. Build the detail via a template inside its
    // own try/catch (a template always yields a string when it doesn't throw, so
    // the console.error below can never throw); fall back to a constant.
    let detail;
    try {
      detail = `${e?.message ?? String(e)}`;
    } catch (_e) {
      detail = 'unformattable error';
    }
    console.error(`himmelctl: WARN: contributor dev profile unavailable (${detail}) — profile report skipped; install is unaffected`);
    return;
  }
  for (const line of contributorProfileLib.reportLines(report, { dryRun, derived })) {
    console.log(line);
  }
}

async function printAdopterEpilogue(answers, derived, dryRun, pluginResult, vaultScaffolded) {
  if (answers.role !== 'adopter') return;
  const laneProbe = await adopterProfileLib.loadLaneProbe(repoRoot(), process.env);
  const ctx = { repoRoot: repoRoot(), env: process.env, platform: process.platform, laneProbe: laneProbe };
  const rows = adopterProfileLib.probeSelection(answers.lanes || [], ctx);

  console.log('');
  console.log('── delegation lanes (PROBED — himmelctl does not install lane CLIs in v1) ──');
  for (const row of rows) {
    if (!row.selected) {
      const why = row.optIn ? `not selected (opt in with --with-${row.id})` : 'not selected';
      console.log(`  .  ${row.id.padEnd(9)} ${why}`);
    } else if (row.state === 'present' && row.setupState === 'ready') {
      console.log(`  ok ${row.id.padEnd(9)} ready — ${row.detail}; ${row.setupDetail}`);
    } else if (row.state === 'present') {
      // Deliberately NOT "available": the probe saw a binary, not a working
      // lane (CR round 4 [codex-adv-r3-2]). The remaining step is named in
      // the summary's `still manual` section.
      const why = row.setupState === 'incomplete' ? `setup INCOMPLETE — ${row.setupDetail}` : 'setup not verified';
      console.log(`  ~  ${row.id.padEnd(9)} binary present — ${row.detail}; ${why}`);
    } else if (row.state === 'disabled') {
      console.log(`  -- ${row.id.padEnd(9)} DISABLED — ${row.detail}`);
    } else if (row.state === 'misconfigured') {
      console.log(`  XX ${row.id.padEnd(9)} MISCONFIGURED — ${row.detail}`);
    } else if (row.state === 'absent') {
      console.log(`  !! ${row.id.padEnd(9)} MISSING — ${row.detail}`);
    } else {
      console.log(`  ?? ${row.id.padEnd(9)} UNKNOWN — ${row.detail}`);
    }
  }

  const hardening = answers.alwaysOn
    ? adopterProfileLib.hardeningChecklistLines(process.platform)
    : adopterProfileLib.hardeningPointerLines();
  for (const line of hardening) console.log(line);

  const summary = adopterProfileLib.buildSummary(answers, rows, {
    derived: derived,
    dryRun: Boolean(dryRun),
    pluginFailures: pluginResult ? pluginResult.failed : null,
    vaultScaffolded: vaultScaffolded !== false,
    pluginTotal: pluginResult ? pluginResult.total : 0,
    vaultPath: answers.vault && answers.vault.path ? expandHome(answers.vault.path) : '',
    handoverPath: answers.handover && answers.handover.path ? expandHome(answers.handover.path) : '',
  });
  for (const line of adopterProfileLib.summaryLines(summary)) console.log(line);
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

// Validate predictable profile-persistence failures before any installer,
// handover or vault mutation. The post-install write stays authoritative and
// repeats these checks to catch changes during the core install.
async function preflightLaneProfileStep(answers) {
  if (answers.role !== 'adopter') return true;
  try {
    await adopterProfileLib.preflightProfileLaneAllowlist(repoRoot());
    return true;
  } catch (e) {
    console.error(`himmelctl: lane profile preflight failed: ${e && e.message ? e.message : e}`);
    return false;
  }
}

// HIMMEL-1428: persist an APPLIED adopter install's selected optional lanes as
// the resolver's narrowing profile allowlist. This runs only after the core
// install succeeds; dry-run and contributor paths never write it. Failure is
// fatal because silently leaving every detected backend routable would violate
// the consent boundary the profile selection now represents.
async function applyLaneProfileStep(answers) {
  if (answers.role !== 'adopter') return true;
  try {
    const { ids, preservedLegacyGlobal } = await adopterProfileLib.persistProfileLaneAllowlist(answers.lanes || [], repoRoot());
    console.log(`lane profile: allowlisted ${ids.length > 0 ? ids.join(', ') : '(none)'}; unselected adopter-profile lanes are suppressed-by-profile`);
    if (preservedLegacyGlobal) console.log('lane profile: preserved legacy global allowlist semantics');
    return true;
  } catch (e) {
    console.error(`himmelctl: could not persist the lane profile allowlist: ${e && e.message ? e.message : e}`);
    return false;
  }
}

// T4.5 helper: pluginSet=full enable step + WARN failure summary (FIX 4
// semantics). lean → no-op. Returns 0 normally, 1 if any plugin command
// failed (the core install already succeeded, so the caller still prints the
// uninstall footer). Shared by the main path and the T5b existing-vault path
// (FIX 5).
// CR round 1 [codex-adv-2]: returns {rc, failed, total} rather than a bare rc.
// The failed-command list used to die here (only a WARN line survived), so the
// adopter epilogue had no way to know the step had partially failed and went
// on to claim the full set was enabled while the process exited nonzero.
function applyPluginStep(answers) {
  // The lean early-return stays BEFORE fullPluginEnableCommands(): that call
  // reads the enable table off disk and throws when it is absent, so hoisting
  // it made a lean install fail on any checkout without the table.
  if (answers.pluginSet !== 'full') return { rc: 0, failed: [], total: 0 };
  const total = fullPluginEnableCommands().length;
  const failed = runPluginEnable();
  if (failed.length === 0) return { rc: 0, failed: [], total: total };
  console.error(`himmelctl: WARN: ${failed.length} of ${total} plugin command(s) failed — re-run install to retry (idempotent)`);
  return { rc: 1, failed: failed, total: total };
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
      applyHimmelctlPathShim(args);
      await printAdopterEpilogue(answers, displayCommand(plan.apply), args.dryRun, null);
      return 0;
    }
    if (isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log('himmelctl: declined; nothing run.');
        return 0;
      }
    }
    if (!await preflightLaneProfileStep(answers)) return 1;
    if (!settingsTargetsWritable(answers)) return 1;
    if (!applyHandoverStep(answers)) return 1;
    const wireRc = runSpawn(plan.wire);
    if (wireRc !== 0) return wireRc;
    const applyRc = runSpawn(plan.apply);
    if (applyRc !== 0) return applyRc;
    if (!await applyLaneProfileStep(answers)) return 1;
    const pluginResult = applyPluginStep(answers);
    const shimOk = applyHimmelctlPathShim(args);
    await printAdopterEpilogue(answers, displayCommand(plan.apply), args.dryRun, pluginResult);
    printUninstallFooter();
    return pluginResult.rc || (shimOk ? 0 : 1);
  }

  // CR round 8 [codex-adv-r7-3]: vault.mode=default-template hands adopt.sh a
  // --luna-target, and adopt.sh's do_luna() SKIPS the template copy whenever
  // the destination already EXISTS (`[[ -e "$dest" ]]`), printing a notice and
  // continuing with rc 0. So pointing default-template at an occupied,
  // unrelated directory quietly promoted that directory to "your vault" — the
  // run succeeded and the summary claimed it had been scaffolded.
  //
  // Fail closed on exactly the case that is unsafe: destination exists and is
  // NOT a stamped luna vault. A stamped one is fine (that is a re-run; the
  // copy is correctly skipped and the summary now says so). Checked BEFORE the
  // shell-out, and isStampedLunaVault is a pure fs read, so the refusal path
  // runs nothing at all. --dry-run reports the same refusal and exits 0, the
  // same posture the T5b unstamped refusal above already takes.
  let vaultScaffolded = true;
  if (answers.role === 'adopter' && answers.vault && answers.vault.mode === 'default-template' && answers.vault.path) {
    const dest = expandHome(answers.vault.path);
    if (fs.existsSync(dest)) {
      if (!isStampedLunaVault(dest)) {
        console.error(`himmelctl: refusing to adopt ${dest} as a luna vault — it already exists and carries no luna-second-brain stamp (.vault-template.json).`);
        console.error('  adopt.sh would SKIP the template copy and silently treat this directory as your vault.');
        console.error('  Move/remove it, pick another --luna-target, or answer vault=existing if it really is a luna vault.');
        return args.dryRun ? 0 : 1;
      }
      // Stamped: the copy will be skipped, which is correct for a re-run —
      // but the summary must not then claim anything was scaffolded.
      vaultScaffolded = false;
      console.log(`note: ${dest} is an existing stamped luna vault — adopt.sh will skip the template copy.`);
    }
  }

  const cmd = deriveCommand(answers);
  process.stdout.write(serialize(answers) + '\n');
  console.log(`derived: ${displayCommand(cmd)}`);

  // --dry-run prints the plan (+ T4.5 side effects) and exits WITHOUT
  // executing or mutating anything.
  if (args.dryRun) {
    previewHandoverAndPlugins(answers);
    applyHimmelctlPathShim(args);
    await printContributorProfile(answers, displayCommand(cmd), args.dryRun);
    await printAdopterEpilogue(answers, displayCommand(cmd), args.dryRun, null, vaultScaffolded);
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

  // Fail before any installer/wire/plugin mutation when lane-profile
  // persistence or the relevant target settings.json cannot be written, so a
  // predictable consent-boundary failure never lands after the core install.
  if (!await preflightLaneProfileStep(answers)) return 1;
  if (!settingsTargetsWritable(answers)) return 1;

  // T4.5: handover.mode=external → persist HANDOVER_DIR before the install.
  // inline → no-op (adopt.sh's/setup.sh's own inline handovers/ default).
  // Fail-closed: a failed write must abort BEFORE the core install shell-out
  // rather than silently proceed with an unwired handover destination.
  if (!applyHandoverStep(answers)) return 1;

  // CR round 11 [codex-adv-r10-2], NARROWED. The occupied-vault gate above
  // runs before the plan print, the confirm and the handover write, so minutes
  // can pass before adopt.sh actually looks at the destination — long enough
  // for a cloud-sync client to create it. Re-evaluate here, at the last
  // instruction before the spawn, so both the refusal and the summary reflect
  // the state adopt.sh is about to see.
  //
  // The summary flag is derived from `fs.existsSync(dest)` rather than by
  // parsing adopt.sh's skip notice out of its output, for two reasons: this is
  // the SAME predicate adopt.sh's do_luna() branches on (`[[ -e "$dest" ]]`),
  // so it is the fact itself rather than a report of it; and capturing stdout
  // to grep for prose would both couple us to that message's wording and cost
  // the operator live output from a long install (spawnSync cannot stream and
  // capture at once).
  //
  // RESIDUAL WINDOW, stated honestly: a directory created between this line
  // and adopt.sh's own check still slips through, and adopt.sh would then skip
  // the copy while the summary says it scaffolded. Closing that entirely
  // requires adopt.sh to make the decision atomically and report it — its
  // owner's scope, not this wrapper's.
  if (answers.role === 'adopter' && answers.vault && answers.vault.mode === 'default-template' && answers.vault.path) {
    const dest = expandHome(answers.vault.path);
    const existsNow = fs.existsSync(dest);
    if (existsNow && !isStampedLunaVault(dest)) {
      console.error(`himmelctl: ${dest} appeared (or changed) since the preflight check and is not a luna vault — aborting before adopt.sh runs.`);
      if (answers.handover && answers.handover.mode === 'external') {
        console.error('  The handover wiring was already applied (applyHandoverStep persisted HANDOVER_DIR to .env) — review or remove that entry if you re-run with a different vault path.');
      }
      return 1;
    }
    if (existsNow !== !vaultScaffolded) {
      console.log(`note: ${dest} ${existsNow ? 'now exists' : 'no longer exists'} — adopt.sh will ${existsNow ? 'skip' : 'perform'} the template copy.`);
    }
    vaultScaffolded = !existsNow;
  }

  // T4: execute the derived command VERBATIM; propagate its rc (skip the
  // post-install enable step if the core install itself failed).
  const rc = runSpawn(cmd);
  if (rc !== 0) return rc;
  if (!await applyLaneProfileStep(answers)) return 1;

  // T4.5: pluginSet=full → the documented per-plugin enable step. lean → no-op
  // (adopt.sh's/setup.sh's settings-template default, HIMMEL-816).
  const pluginResult = applyPluginStep(answers);
  const shimOk = applyHimmelctlPathShim(args);
  await printContributorProfile(answers, displayCommand(cmd), args.dryRun);
  await printAdopterEpilogue(answers, displayCommand(cmd), args.dryRun, pluginResult, vaultScaffolded);
  printUninstallFooter();
  return pluginResult.rc || (shimOk ? 0 : 1);
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
  //    HIMMEL-862: the lane flags shape the interactive + dry-run paths only.
  //    The --from-profile branch never sees them — parseArgs already refused
  //    that combination, so the profile stays the single authority there.
  const laneOpts = { lanes: args.lanes, withCodex: args.withCodex, withHermes: args.withHermes };
  let answers;
  if (profileAnswers) {
    answers = profileAnswers;
  } else if (shouldPrompt(args)) {
    answers = await askQuestions(args.defaultScope, laneOpts);
    writeCache(answers);
  } else if (args.dryRun) {
    answers = defaultAnswers(args.defaultScope, laneOpts);
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
  return { argv: [resolveBash(), toBashPath(path.join(scriptsDir, 'uninstall.sh')), '--yes'] };
}

// HIMMEL-755 sub-ticket E (uninstall-completeness, operator LOCKED
// 2026-07-17): uninstall.sh/.ps1 already tears down himmel's OWN wiring
// symmetrically — that stays untouched (§ header above: "Keep uninstall.sh
// as the executor"). What was missing is that cmdUninstall was manifest-
// BLIND: it never told the operator what SHARED items (toolchain, global
// tools, plugins other projects may use) himmel installs/requires, and never
// verified its own teardown actually converged. partitionOffboard() splits
// the manifest's 32 items by their `offboard` field (manifest-lint.mjs
// validates the vocabulary): 'unwire' (default when absent) — himmel-owned,
// uninstall.sh's job; 'advise' — a shared dep/tool/plugin, NEVER auto-
// removed (removing a shared dep can break another project — only listed);
// 'keep' — the operator's own content (the vault), never removed OR advised
// removing.
function partitionOffboard(manifest) {
  const unwireItems = [];
  const adviseItems = [];
  const keepItems = [];
  for (const item of manifest.items) {
    const offboard = item.offboard || 'unwire';
    if (offboard === 'advise') adviseItems.push(item);
    else if (offboard === 'keep') keepItems.push(item);
    else unwireItems.push(item);
  }
  return { unwireItems, adviseItems, keepItems };
}

// Print the manifest-driven plan: what uninstall.sh is about to tear down
// (himmel-owned), the shared-item ADVISORY (never removed — the operator
// decides), and the keep set (left untouched, one line). Printed BEFORE the
// confirm gate (and unconditionally under --dry-run) so the operator sees
// the full picture before consenting to anything.
//
// unwireItems is NOT a "these N items are each individually torn down" list
// — per checkUninstallCompleteness's comment above, only the couple of items
// that carry an actual `unwire` descriptor (wiring-pretooluse,
// wiring-statusline) are machine-level wiring uninstall.sh's [1/6]-[6/6]
// steps actually reverse. The rest of the offboard:'unwire' set
// (jira-cli-dist-build, guardrail-scope, doc-guard-map, hermes-lanes,
// telegram-bridge, ...) are repo-local files/artifacts uninstall.sh
// deliberately leaves in place (its own "NOT touched" footer: "the himmel
// clone itself") — they go away when the clone itself is deleted, not
// because uninstall.sh removed them one by one. The header below must not
// claim otherwise; it states what uninstall.sh's machine-level steps do
// and lets the repo-local disposition apply to everything else in the list.
function printOffboardPlan(unwireItems, adviseItems, keepItems) {
  console.log(`himmel-owned wiring & repo-local artifacts (${unwireItems.length}) — uninstall.sh removes himmel's machine-level wiring (settings.json hooks/statusline, scheduled jobs, plugins, git hooks, telegram bridge); repo-local files/artifacts in this list go away when the clone is deleted: ${unwireItems.map((i) => i.id).join(', ')}`);
  console.log("Shared tools himmel installed or requires (NOT removed — remove any you don't use elsewhere):");
  console.log(`  ${adviseItems.map((i) => i.id).join(', ')}`);
  console.log(`left untouched (your data): ${keepItems.map((i) => i.id).join(', ')}`);
}

// Post-teardown completeness check (the manifest-driven "converge" value-
// add): probes the himmel-owned unwire set and WARN-lists anything still
// present. Scoped to items that carry an actual `unwire` descriptor —
// NOT every offboard:unwire item — because most of the other unwire-
// classified items (jira-cli-dist-build, guardrail-scope, doc-guard-map,
// hermes-lanes, telegram-bridge, ...) probe REPO-OWNED files/artifacts that
// uninstall.sh deliberately leaves in place (its own "NOT touched" footer:
// "the himmel clone itself, .env, and worktrees") or machine state outside
// its 6 documented steps (jira-env-keys' .env, qmd-index, tokensave-mcp,
// graphify-mcp, handover-wiring, scheduler-backend's tool-presence probe).
// Probing those would read 'present' on EVERY run regardless of whether
// uninstall actually converged anything — noise, not signal. The two items
// that currently carry an `unwire` descriptor (wiring-pretooluse,
// wiring-statusline) are exactly the ones uninstall.sh's [6/6] step
// symmetrically reverses, and BOTH declare `scopes: ["project", "user"]` —
// uninstall.sh reverses the wiring at whichever settings.json it wired, and
// for a machine offboard that's this himmel checkout's OWN project-scope
// .claude/settings.json as well as the operator's user-scope one. Probing
// only 'user' (as an earlier version of this check did) let project-scope
// residue in the repo's own .claude/settings.json pass unnoticed. So each
// convergeable item is now probed once per entry in its own `item.scopes`
// (not a hardcoded single scope): 'user' -> ctx.scope='user' (probes.js's
// resolveConfigFile ignores targetPath for user scope and resolves against
// $HOME, matching uninstall.sh's own USER_SETTINGS default); 'project' ->
// ctx.scope='project' with ctx.targetPath=repoRoot() (matching
// settingsPath()'s project-scope convention in install-engine.js — for a
// machine offboard the "project" target IS this himmel checkout, the same
// REPO_ROOT-relative base uninstall.sh's own git-hooks step operates on).
// Non-fatal: never changes cmdUninstall's own exit code — that stays the
// teardown's rc.
function checkUninstallCompleteness(unwireItems) {
  const convergeable = unwireItems.filter((item) => item.unwire);
  const root = repoRoot();
  // CR fix (codex-1): the "never changes cmdUninstall's exit code" guarantee
  // above must be STRUCTURAL, not merely incidental to today's probes. This
  // runs between the teardown's `const rc = runSpawn(cmd)` and `return rc`, so
  // any throw here would propagate and mask the real rc. The current two
  // probes (settings-hooks/settings-key) don't throw, but a per-item guard
  // (now per item+scope) keeps that true for any future probe: a throw is
  // caught, WARN-noted, and never allowed to escape.
  const residue = [];
  for (const item of convergeable) {
    const scopes = item.scopes && item.scopes.length > 0 ? item.scopes : ['user'];
    for (const scope of scopes) {
      const ctx = { repoRoot: root, targetPath: root, scope, env: process.env };
      try {
        const probe = probesLib.runProbe(item, ctx);
        if (probe.actual !== 'absent') residue.push(`${item.id} (${probe.actual}, ${scope})`);
      } catch (e) {
        console.error(`himmelctl: WARN: completeness probe for ${item.id} (${scope}) errored (${e.message}) — skipping`);
      }
    }
  }
  if (residue.length > 0) {
    console.error(`himmelctl: WARN: ${residue.length} himmel-owned item(s) still present after uninstall: ${residue.join(', ')}`);
  }
}

async function cmdUninstall(args) {
  const cmd = deriveUninstallCommand();
  console.log('himmelctl: this will offboard himmel from this machine —');
  console.log('  plugins, scheduled jobs, git hooks, and settings.json wiring.');
  console.log(`derived: ${displayCommand(cmd)}`);

  // Guard the manifest load: uninstall is the "thin wrapper, always works,
  // last resort" escape hatch (see the design comment above cmdUninstall) —
  // a missing/malformed scripts/install/manifest.json must never abort the
  // whole uninstall (loadManifest()/partitionOffboard() throw uncaught
  // otherwise, which main()'s catch turns into a hard exit(1), even under
  // --dry-run). On failure, WARN and skip ONLY the manifest-driven advisory
  // plan + completeness check; the derive->confirm->spawn teardown below
  // still runs unconditionally, same as before this sub-ticket existed.
  let offboard = null;
  try {
    const manifest = loadManifest();
    offboard = partitionOffboard(manifest);
    printOffboardPlan(offboard.unwireItems, offboard.adviseItems, offboard.keepItems);
  } catch (e) {
    console.error(`himmelctl: WARN: could not read manifest.json (${e.message}) — skipping offboard plan/completeness check`);
  }

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
  const rc = runSpawn(cmd);
  if (offboard) checkUninstallCompleteness(offboard.unwireItems);
  // HIMMEL-1446 r4 (codex-1/codex-adv converged blocker): strip the managed
  // PATH launchers ONLY when the teardown succeeded. A failed teardown (rc!=0)
  // leaves the machine in a partial state and the user will likely retry, so
  // removing the launchers now would strand the machine with no working
  // `himmelctl` for the retry. Preserve them and WARN naming the failure.
  if (rc === 0) {
    removeHimmelctlLaunchers();
  } else {
    console.error(`himmelctl: WARN: uninstall teardown exited ${rc} — PATH launchers left in place; fix the failure and re-run \`himmelctl uninstall\`.`);
  }
  return rc;
}

// ── PATH launcher (HIMMEL-1446) ──────────────────────────────────────────
//
// setup.sh already treats ~/.local/bin as himmel's shared user-bin directory
// (uv, jira, pre-commit). Reuse it rather than inventing another PATH surface.
// HIMMELCTL_BIN_DIR / HIMMELCTL_SHIM_PLATFORM are hermetic-test seams; normal
// runs always use ~/.local/bin and the real process platform.
function himmelctlBinDir() {
  if (process.env.HIMMELCTL_BIN_DIR) return path.resolve(process.env.HIMMELCTL_BIN_DIR);
  return path.join(process.platform === 'win32' ? os.homedir() : (process.env.HOME || os.homedir()), '.local', 'bin');
}

function himmelctlShimPlatform() {
  return process.env.HIMMELCTL_SHIM_PLATFORM || process.platform;
}

function pathContainsDir(dir, platform) {
  const raw = process.env.PATH || process.env.Path || '';
  const delimiter = platform === 'win32' ? ';' : path.delimiter;
  const key = (p) => {
    let resolved = path.resolve(String(p).replace(/^"|"$/g, ''));
    if (platform === 'win32') resolved = resolved.replace(/\//g, '\\').toLowerCase();
    return resolved;
  };
  const wanted = key(dir);
  return raw.split(delimiter).some((entry) => entry && key(entry) === wanted);
}

function printHimmelctlPathInstruction(binDir, platform) {
  if (pathContainsDir(binDir, platform)) return;
  if (platform === 'win32') {
    const quoted = binDir.replace(/'/g, "''");
    // Idempotent (HIMMEL-1446 r4 glm-3): the printed snippet prepends binDir
    // only when it is not already an element of the persisted User PATH, so
    // re-running `himmelctl update` before opening a new shell — and pasting the
    // line a second time — cannot duplicate the entry. pathContainsDir above
    // checks the PROCESS Path, but this mutates the PERSISTED User Path, so the
    // guard lives in the printed snippet itself.
    console.log(`himmelctl: ${binDir} is not on PATH; run this in PowerShell (safe to repeat — it adds the entry only once), then open a new shell: $p=[Environment]::GetEnvironmentVariable('Path','User'); if(-not(($p -split ';') -contains '${quoted}')){[Environment]::SetEnvironmentVariable('Path','${quoted};'+$p,'User')}`);
    return;
  }
  const quoted = `'${binDir.replace(/'/g, "'\\''")}'`;
  console.log(`himmelctl: ${binDir} is not on PATH; add this line to your shell profile, then open a new shell: export PATH=${quoted}:"$PATH"`);
}

// Write a tiny relative wrapper plus a JS target loader. The wrapper never
// embeds the checkout path: Windows uses %~dp0 and POSIX uses its own
// directory, so paths with spaces stay quoted. Re-running install/update
// rewrites only the loader's absolute target, which re-points a moved checkout.
//
// HIMMEL-1446 r2 (codex adversarial review, 3 agreed blockers):
//  • The loader target is the PRIMARY checkout, not repoRoot() — a launcher
//    written from a linked feature worktree must not bind to the disposable
//    worktree (see primaryCheckoutRoot).
//  • Every generated file carries SHIM_MARKER; an existing destination is
//    overwritten ONLY if it already carries the marker (writeMarkedLauncher).
//    A third-party `himmelctl`, an operator's hand-written launcher, or a
//    symlink is refused, never clobbered. Writes go via a sibling tmp + atomic
//    rename so a partial write can never leave a broken launcher.
//  • No himmelctl.ps1 is written: PowerShell command precedence resolves a .ps1
//    before the .cmd of the same basename, and a clean Windows client defaults
//    to ExecutionPolicy=Restricted → bare `himmelctl` throws PSSecurityException.
//    Letting PowerShell resolve the .cmd avoids that. A stale marked .ps1 from a
//    prior install is removed (removeMarkedLauncher).
const SHIM_MARKER = 'generated by himmelctl (HIMMEL-1446)';

// Resolve the PRIMARY checkout root — the parent of `git rev-parse
// --git-common-dir` — so a launcher written from a linked feature worktree
// targets the stable primary checkout, not the disposable worktree (which after
// pruning leaves a MODULE_NOT_FOUND launcher `himmelctl update` can't
// self-repair). Same primary-checkout convention scripts/lib/load-dotenv.sh
// uses. When repoRoot() is already the primary, or git is absent (tarball
// install), behavior is unchanged: returns repoRoot(). (codex-adv-2.)
//
// The parent resolution runs INSIDE bash (`cd "$d/.." && pwd`): on win32 node,
// `git rev-parse --git-common-dir` via Git-Bash returns a POSIX-form (/c/...)
// path that node's win32 path.resolve would misresolve, so resolving the parent
// in bash (and `pwd -W` for the Windows form on MSYS, plain `pwd` elsewhere)
// hands node a path in the form it expects.
function primaryCheckoutRoot() {
  const root = repoRoot();
  const r = spawnSync(resolveBash(),
    ['-c', 'd=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$d/.." && { pwd -W 2>/dev/null || pwd; }'],
    { cwd: root, encoding: 'utf8' });
  if (r.error || r.status !== 0 || !r.stdout) return root;
  const resolved = r.stdout.trim();
  return resolved ? path.resolve(resolved) : root;
}

// True iff <filePath> exists and its contents carry our ownership marker. An
// absent file is "not marked" (ENOENT -> false); any other read error throws.
function fileCarriesMarker(filePath) {
  let content;
  try {
    content = fs.readFileSync(filePath, 'utf8');
  } catch (e) {
    if (e && e.code === 'ENOENT') return false;
    throw e;
  }
  return content.includes(SHIM_MARKER);
}

// Write <contents> to <dest> (optional <mode> for chmod), but ONLY when dest is
// absent OR already carries our ownership marker. A third-party file, an
// operator's hand-written launcher, or a symlink (lstat, never followed) is
// refused with a clear message — never clobbered. Writes go via a sibling tmp +
// atomic rename, so a crash mid-write or a failed write can never leave a
// partial launcher at dest (the orphaned tmp is a hidden dotfile). Returns true
// on success, false on a refused collision. Throws on I/O error. (codex-adv-3.)
function writeMarkedLauncher(dest, contents, mode) {
  // Existence is probed with lstatSync, NOT fs.existsSync (HIMMEL-1446 r4 glm-2):
  // existsSync FOLLOWS symlinks, so a BROKEN (dangling) symlink at dest returns
  // false, skipping the symlink/ownership check and letting renameSync clobber
  // the link — violating the never-clobber-a-symlink contract. lstatSync never
  // follows, so ANY symlink (broken included) reaches the isSymbolicLink()
  // refusal. ENOENT (truly absent) is the only skip-to-write case.
  let st = null;
  try {
    st = fs.lstatSync(dest);
  } catch (e) {
    if (e && e.code !== 'ENOENT') throw e; // ENOENT -> st stays null: absent, safe to write
  }
  if (st) {
    if (st.isSymbolicLink()) {
      console.error(`himmelctl: refusing to overwrite symlink ${dest} (remove it first if you want himmelctl to manage it)`);
      return false;
    }
    if (!fileCarriesMarker(dest)) {
      console.error(`himmelctl: refusing to overwrite ${dest} (not a himmelctl-managed file — move it aside first)`);
      return false;
    }
  }
  const tmp = path.join(path.dirname(dest), `.${path.basename(dest)}.${process.pid}.tmp`);
  try {
    fs.writeFileSync(tmp, contents, 'utf8');
    if (mode !== undefined) fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, dest);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* best-effort tmp cleanup */ }
    throw e;
  }
  return true;
}

// Remove <filePath> only if it carries our ownership marker; an unmarked file
// (a third-party `himmelctl`) or a symlink is left untouched. Absent file is a
// no-op. Used by the shim (stale .ps1 cleanup) and cmdUninstall.
function removeMarkedLauncher(filePath) {
  let st;
  try {
    st = fs.lstatSync(filePath);
  } catch (e) {
    if (e && e.code === 'ENOENT') return;
    throw e;
  }
  if (st.isSymbolicLink()) return; // never follow/remove an unowned symlink
  if (!fileCarriesMarker(filePath)) return; // never remove an unmarked file
  fs.unlinkSync(filePath);
}

function applyHimmelctlPathShim(args) {
  const binDir = himmelctlBinDir();
  const platform = himmelctlShimPlatform();
  const target = path.join(primaryCheckoutRoot(), 'scripts', 'himmelctl', 'bin.js');
  if (args.dryRun) {
    console.log(`DRY: himmelctl launcher -> ${target} (would write to ${binDir})`);
    printHimmelctlPathInstruction(binDir, platform);
    return true;
  }

  try {
    fs.mkdirSync(binDir, { recursive: true });
    const jsBody = `'use strict';\n// ${SHIM_MARKER}\nrequire(${JSON.stringify(target)});\n`;
    if (!writeMarkedLauncher(path.join(binDir, 'himmelctl.js'), jsBody)) return false;
    if (platform === 'win32') {
      const cmdBody = `@echo off\r\nREM ${SHIM_MARKER}\r\nnode "%~dp0himmelctl.js" %*\r\n`;
      if (!writeMarkedLauncher(path.join(binDir, 'himmelctl.cmd'), cmdBody)) return false;
      // No himmelctl.ps1 (codex-adv-1): a stale marked .ps1 from a prior install
      // is removed; an unmarked/symlinked one is left untouched. Removal is a
      // best-effort cleanup of a LEGACY artifact, not part of writing the PATH
      // launcher, so its I/O errors WARN here with an accurate message and never
      // fail the shim write (HIMMEL-1446 r4 glm-4: previously caught by the
      // surrounding try/catch and misreported as "failed to write PATH launcher").
      try {
        removeMarkedLauncher(path.join(binDir, 'himmelctl.ps1'));
      } catch (e) {
        console.error(`himmelctl: WARN: could not remove stale launcher ${path.join(binDir, 'himmelctl.ps1')} (${e.message}) — the PATH launcher was written; remove the stale file manually if needed`);
      }
    } else {
      const launcher = path.join(binDir, 'himmelctl');
      const shBody = `#!/usr/bin/env sh\n# ${SHIM_MARKER}\nexec node "$(dirname "$0")/himmelctl.js" "$@"\n`;
      if (!writeMarkedLauncher(launcher, shBody, 0o755)) return false;
    }
  } catch (e) {
    console.error(`himmelctl: failed to write PATH launcher in ${binDir}: ${e.message}`);
    return false;
  }

  console.log(`himmelctl: launcher -> ${target} (written to ${binDir})`);
  printHimmelctlPathInstruction(binDir, platform);
  return true;
}

// HIMMEL-1446 r2 (glm-1): uninstall.sh/.ps1 tears down himmel's machine wiring
// but does not know about the PATH launchers install/update wrote into binDir
// (~/.local/bin), so they'd go stale (dangling once the clone is deleted).
// Remove each known launcher name that carries our ownership marker; never
// touch an unmarked or symlinked file. Best-effort: WARNs on errors and never
// changes cmdUninstall's exit code.
function removeHimmelctlLaunchers() {
  const binDir = himmelctlBinDir();
  for (const name of ['himmelctl.js', 'himmelctl', 'himmelctl.cmd', 'himmelctl.ps1']) {
    try {
      removeMarkedLauncher(path.join(binDir, name));
    } catch (e) {
      console.error(`himmelctl: WARN: could not remove launcher ${path.join(binDir, name)} (${e.message}) — skipping`);
    }
  }
}

// ── update (HIMMEL-893) ──────────────────────────────────────────────────
//
// A THIN wrapper, same shape as cmdUninstall above: derive the command and
// runSpawn it verbatim. The full dependency-chain check/update (git pull,
// marketplace re-sync, jira CLI dist rebuild, qmd fork, hermes, luna
// template — per-item status + abort-on-first-failure) lives ENTIRELY in
// scripts/himmel-update.sh, so `himmelctl update` and the `/himmel-update`
// skill run the SAME engine and never drift apart. No confirm prompt (unlike
// uninstall): matches /himmel-update's own established no-confirm behavior —
// an update is not the destructive, one-way action uninstall is. --dry-run
// prints the derived plan and executes nothing, same contract as
// install/uninstall's own --dry-run.

function deriveUpdateCommand() {
  // HIMMEL-1192 (two-part Windows fix, BOTH parts required):
  //  1. resolveBash() picks a Windows-native Git Bash — bare `bash` from a
  //     PowerShell PATH is System32\bash.exe (WSL), which cannot run a
  //     Windows-path script AT ALL (backslashes eaten; C:/... absent from the
  //     WSL rootfs). This is the reopened root cause the s2 fix missed.
  //  2. toBashPath() forward-slashes the script path so the Git Bash chosen in
  //     (1) doesn't itself MSYS-mangle the backslashes (\U->U, \D->D ...) into
  //     a nonexistent C:Users...himmel-update.sh -> "No such file or directory".
  const script = toBashPath(path.join(repoRoot(), 'scripts', 'himmel-update.sh'));
  return { argv: [resolveBash(), script] };
}

async function cmdUpdate(args) {
  const cmd = deriveUpdateCommand();
  console.log(`derived: ${displayCommand(cmd)}`);
  if (args.dryRun) {
    applyHimmelctlPathShim(args);
    return 0;
  }
  const rc = runSpawn(cmd);
  if (rc !== 0) return rc;
  // The PATH launcher is a best-effort rider on a successful update
  // (HIMMEL-1446 r4 glm-5): applyHimmelctlPathShim has already printed the
  // specific refusal/error. A failed launcher write must NOT mask the update's
  // success in this exit code (automation keys off rc 0/!=0), so surface a LOUD
  // warning and keep rc 0 — the launcher is best-effort, never a hard dependency.
  if (!applyHimmelctlPathShim(args)) {
    console.error('himmelctl: WARN: update succeeded, but the PATH launcher could not be written (see above); the update is complete — the launcher is best-effort');
  }
  return 0;
}

// ── status (HIMMEL-756 T1.5/T1.6) ────────────────────────────────────────
//
// A read-only severity diff: desired = the target's manifest-derived
// `enabled` flags (lib/state.js), actual = a fresh probe run (lib/probes.js)
// for every desired-enabled item. NEVER prompts (no readline anywhere in
// this section) and NEVER mutates on its own — the ONLY sanctioned write is
// deriving a target's FIRST entry when the install-profile cache exists but
// state.json has no entry yet for this target (ensureTarget's own
// documented derive-if-missing path); that derived entry is persisted here
// via state.save() so it doesn't need re-deriving on every future run. An
// already-present target entry is read as-is with zero writes.
//
// Target resolution mirrors adopt.sh / state.js's own targetKeyForScope
// (not exported — replicated here as the same one-line formula its module
// header documents): project scope keys off path.resolve(process.cwd()),
// user scope is the literal "user" key. `status` must therefore be run from
// the same location the corresponding `install` was run from — the
// adopted project's root for project scope, or the himmel checkout for
// user scope (review carry-forward #1).

function loadManifest() {
  return JSON.parse(fs.readFileSync(path.join(repoRoot(), 'scripts', 'install', 'manifest.json'), 'utf8'));
}

// cmdStatus is now a thin caller (HIMMEL-755 A2): it resolves scope/target
// and performs the ONE sanctioned state.json write (deriving + persisting a
// target's FIRST entry, unchanged from before the extraction) exactly as
// before, then delegates the desired-vs-actual results loop to the
// parameterized statusReportLib.statusReport() (lib/status-report.js) and
// only renders/emits its output.
async function cmdStatus(args) {
  const manifest = loadManifest();

  const profilePath = cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const cachedAnswers = loadProfile(profilePath);

  if (args.items) {
    const known = new Set(manifest.items.map((i) => i.id));
    for (const id of args.items) {
      if (!known.has(id)) {
        console.error(`himmelctl: unknown --items id: ${id}`);
        return 2;
      }
    }
  }

  const scope = cachedAnswers.scope;
  const targetKey = scope === 'user' ? 'user' : path.resolve(process.cwd());
  const baseTargetPath = scope === 'user' ? repoRoot() : path.resolve(process.cwd());

  const state = stateLib.load();
  const existedBefore = Boolean(state.targets[targetKey]);
  const itemCountBefore = existedBefore ? Object.keys(state.targets[targetKey].items).length : 0;
  const target = stateLib.ensureTarget(state, manifest, cachedAnswers);
  // HIMMEL-1017: persist not only a brand-new derive but also a migration —
  // ensureTarget() now backfills manifest items an EXISTING target was
  // missing (a manifest update since the target was last derived). Without
  // this, the migrated items would live only in-memory for this one run and
  // never make it into state.json, so the very next `status` invocation
  // would silently re-migrate them (harmless, but the on-disk artifact would
  // never catch up).
  if (!existedBefore || Object.keys(target.items).length !== itemCountBefore) stateLib.save(state);

  const report = statusReportLib.statusReport({
    manifest, scope, targetPath: baseTargetPath, answers: cachedAnswers, itemIds: args.items,
  });

  if (args.json) {
    process.stdout.write(JSON.stringify(report) + '\n');
    return 0;
  }

  const groupOrder = { red: 0, degraded: 1, green: 2, 'n/a': 3 };
  const printed = report.items.slice().sort((a, b) => {
    const byGroup = groupOrder[a.severity] - groupOrder[b.severity];
    return byGroup !== 0 ? byGroup : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  });
  for (const r of printed) console.log(`${r.severity}  ${r.id}  ${r.detail}`);
  console.log(`${report.summary.red} red, ${report.summary.degraded} degraded, ${report.summary.green} green, ${report.summary.na} n/a`);
  return 0;
}

// ── ensure (HIMMEL-755 A5/A5b) ───────────────────────────────────────────
//
// Converge this target toward its desired manifest state: pre-check via
// statusReport, build a work list from red/degraded desired-true items that
// carry a RUNNABLE install descriptor (excluding config-type/no-install
// items as HINTS — never dispatched, never fail-closing), planInstall +
// runInstall the toward-enabled work, dispatch the toward-disabled work
// (A5b — an enabled item the operator no longer wants: removable:per-item
// runs its unwire primitive, full-offboard-only ERRORS naming
// `himmelctl uninstall`), post-check, fail-closed on anything still not
// converged that DID have a runnable descriptor.
//
// Bookkeeping writes (the sanctioned derive-if-missing entry, same as
// status's own; a --profile reconcile) are gated behind `!args.dryRun` —
// the global "--dry-run makes ZERO mutations" constraint covers every
// state.json write, not only primitive execution (planInstall/runInstall/
// unwireCommand's spawnSync calls, which are ALSO gated). Skipping the save
// under --dry-run does NOT mean the preview loses the reconcile: the
// in-memory (possibly unsaved) `state` object is passed explicitly into
// BOTH statusReport calls below (pre-check and post-check) — statusReport's
// own independent stateLib.load() would otherwise read the STALE on-disk
// entry for an EXISTING target reconciled-but-not-yet-saved (its no-entry
// fallback only happens to agree for the FIRST-derive case, not a reconcile
// of an already-persisted entry — this bit ensure once, HIMMEL-755 CR fix).
async function cmdEnsure(args) {
  const manifest = loadManifest();

  const profilePath = cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const cachedAnswers = loadProfile(profilePath);

  if (args.items) {
    const known = new Set(manifest.items.map((i) => i.id));
    for (const id of args.items) {
      if (!known.has(id)) {
        console.error(`himmelctl: unknown --items id: ${id}`);
        return 2;
      }
    }
  }

  const scope = cachedAnswers.scope;
  const targetKey = scope === 'user' ? 'user' : path.resolve(process.cwd());
  const baseTargetPath = scope === 'user' ? repoRoot() : path.resolve(process.cwd());

  // Bookkeeping writes (the sanctioned derive-if-missing entry, a --profile
  // reconcile) are gated behind !args.dryRun — the global "--dry-run makes
  // ZERO mutations" constraint covers ALL writes, not only primitive
  // execution. Skipping the save under dry-run is safe: statusReport's own
  // no-persisted-entry fallback (a pure, unsaved deriveTarget() call) gives
  // the SAME desired flags an unsaved derive/reconcile here would have
  // produced, for every case this verb is exercised against.
  //
  // CR fix (Critical, round 2): the save itself is DEFERRED past the
  // consent gate below (`stateChanged` tracks whether ensureTarget/
  // reconcileTarget actually mutated `state`) — an operator who declines
  // the confirm, or a non-interactive run refused for lacking --yes, must
  // leave state.json byte-untouched. The ONE exception is the "nothing to
  // converge" early return further down: nothing is being consented to
  // there (no install/unwire is about to run), so persisting the derived/
  // reconciled bookkeeping immediately is correct and intentionally kept.
  const state = stateLib.load();
  const existedBefore = Boolean(state.targets[targetKey]);
  const itemCountBefore = existedBefore ? Object.keys(state.targets[targetKey].items).length : 0;
  let target = stateLib.ensureTarget(state, manifest, cachedAnswers);
  // HIMMEL-1017: ensureTarget() can now also MIGRATE an existing target (add
  // manifest items it was missing) — count that as a state change too, same
  // as a brand-new derive, so the migrated items get persisted rather than
  // silently staying in-memory-only for this one run.
  let stateChanged = !existedBefore || Object.keys(target.items).length !== itemCountBefore;

  // Step 0: reconcile FIRST whenever --profile is explicitly supplied —
  // CR fix: NOT only when it differs from the target's stored profile. A
  // target's PER-ITEM `enabled` flags can go stale even when the profile
  // NAME itself is unchanged (a hand-edited state.json, or a manifest that
  // gained new items for the same profile since the target was last
  // derived/reconciled) — an explicit `--profile core` against an
  // already-'core' target must still re-derive membership, not silently
  // skip reconcile because the profile string happens to match. Without
  // this, the pre-check work list would be computed against a possibly-
  // stale target and ensure would false-no-op on exactly the items the
  // operator asked to reconcile.
  // CR fix (CodeRabbit round 18): pass the AUTHORITATIVE invocation `scope`
  // (cachedAnswers.scope, the same value targetKey/baseTargetPath and the
  // statusReport call below are computed from), NOT `target.scope`.
  //
  // ensureTarget() returns the entry at targetKeyForScope(cachedAnswers.scope),
  // but `target.scope` is that entry's PERSISTED field, which can drift from
  // the key it lives under (a hand-edited state.json, an entry predating a
  // schema change — the same malformed-state class as the `overrides` /
  // `lastEnsured` normalizations in state.js). reconcileTarget() recomputes
  // its OWN key via targetKeyForScope(scope), so a stale `target.scope` made
  // it write to a DIFFERENT entry than the one being ensured: a project-scope
  // `ensure --profile core` in /foo whose persisted entry claimed
  // scope:'user' would reconcile the USER target, overwrite it with
  // project-derived answers, and leave /foo's entry stale — while
  // statusReport (which already uses the authoritative `scope`) kept reading
  // /foo. Net effect: a silent false-no-op on exactly the items the operator
  // asked to reconcile, plus collateral damage to the other scope's entry.
  // It also fed the wrong scope into reconcile's own
  // `item.scopes.includes(scope)` membership test.
  if (args.profile) {
    target = stateLib.reconcileTarget(state, manifest, cachedAnswers, { profile: args.profile, scope });
    stateChanged = true;
  }

  // Step 1: pre-check. Passes the IN-MEMORY `state` (reflecting any
  // just-computed reconcile, even when --dry-run left it unsaved) so the
  // preview matches the reconcile rather than reading the stale on-disk
  // entry — statusReport's own independent load() would otherwise never
  // see an unsaved reconcile of an EXISTING target entry (unlike the
  // derive-if-missing case, where its no-entry fallback happens to agree).
  const byId = new Map(manifest.items.map((i) => [i.id, i]));
  const pre = statusReportLib.statusReport({
    manifest, scope, targetPath: baseTargetPath, answers: cachedAnswers, itemIds: args.items, state,
  });

  // Step 2: build the toward-enabled work list (desired:true, red/degraded)
  // and the toward-disabled work list, splitting off items with NO runnable
  // install descriptor as hints — the general hint-only exemption
  // (config-type items pre-sub-ticket-D, MCP items with no converging
  // install type, or any future item lacking one) never lands in the work
  // list and never fail-closes ensure.
  const towardEnabled = [];
  const hints = [];
  for (const r of pre.items) {
    const item = byId.get(r.id);
    if (!item || !r.desired || (r.severity !== 'red' && r.severity !== 'degraded')) continue;
    const install = item.install;
    if (install && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(install.type) !== -1) {
      towardEnabled.push(item);
    } else {
      hints.push(item.id);
    }
  }

  // Toward-disabled candidates: statusReport NEVER probes a desired:false
  // item (its own results loop short-circuits to actual:null for those —
  // "not enabled for this target" is a legitimate state needing no
  // diagnosis for status's own read-only use case), so an enabled item the
  // operator no longer wants can't be detected from `pre` alone. Directly
  // probe every `removable`-carrying item that ISN'T desired under the
  // (possibly just-reconciled) target — mirrors statusReportLib's own
  // ctxForItem (minus the luna-vault-scaffold special case; not relevant to
  // any removable item authored so far).
  const towardDisabled = [];
  const desiredIds = new Set(pre.items.filter((r) => r.desired).map((r) => r.id));
  for (const item of manifest.items) {
    // CR fix: also require item.scopes.includes(scope) — without it, a
    // project-scope run processed user-only removable items and vice versa
    // (scope bleed). Mirrors the SAME membership check deriveTarget()/
    // reconcileTarget() apply for the toward-ENABLED side.
    if (!item.removable || !item.scopes.includes(scope) || desiredIds.has(item.id)) continue;
    if (args.items && args.items.indexOf(item.id) === -1) continue;
    const ctx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
    const probe = probesLib.runProbe(item, ctx);
    // CR fix: a degraded (not just fully present) removable item is STILL
    // physically there and still needs converging toward disabled — only a
    // clean 'absent' probe means there's genuinely nothing to remove.
    if (probe.actual !== 'absent') towardDisabled.push(item);
  }

  // CR fix (MAJOR): --items breaks dependency closure. planInstall's DFS
  // (and reverseDependencyOrder, its toward-disabled counterpart)
  // deliberately treats a dep OUTSIDE the given item set as
  // already-satisfied — valid for a FULL run (anything excluded from the
  // work list is green) but FALSE under --items, where a red/desired
  // prerequisite (toward-enabled) or a still-desired dependent
  // (toward-disabled) can be excluded by the filter alone, and neither
  // ordering helper ever notices the excluded edge. Validated in BOTH
  // directions here, BEFORE any dispatch or mutation — fail-closed with a
  // message naming the offending edge + a corrected --items list, rather
  // than silently auto-expanding the operator's own selection (which could
  // install/unwire something they never asked for).
  // fullById: the UNFILTERED status map both closure checks key on. --items
  // filters `pre` (statusReport's own itemIds param), so `pre` alone can't
  // tell whether an EXCLUDED item is itself desired+red/degraded — a second,
  // unfiltered statusReport call (same read-only, zero-mutation contract as
  // every other statusReport call here) gives the full picture. An UNFILTERED
  // run already has that picture in `pre`, so it reuses `pre` rather than
  // paying for a redundant second statusReport.
  const fullById = args.items
    ? new Map(statusReportLib.statusReport({
        manifest, scope, targetPath: baseTargetPath, answers: cachedAnswers, state,
      }).items.map((r) => [r.id, r]))
    : new Map(pre.items.map((r) => [r.id, r]));

  if (args.items) {
    // WHY THIS LOOP IS GATED ON --items — not an oversight (re-confirmed
    // CodeRabbit round 22, re-raised as a duplicate; adjudicated "by design").
    // Unfiltered, the only deps that are desired + red/degraded AND absent
    // from towardEnabled are the HINT-ONLY ones (config-type/MCP items with
    // no runnable install descriptor): a runnable desired+red dep converges
    // on an unfiltered run, so it is never absent. Spec section 4.5 / plan
    // section 4.1 DELIBERATELY exempt hint-only prerequisites from fail-closing
    // ensure (they surface a hint, not an error); ungating would fail-close
    // every unfiltered `ensure --yes` that carries one — contradicting the
    // spec. KNOWN, ACCEPTED downside: a runnable dependent CAN install atop a
    // still-red hint-only prereq — ensure surfaces the hint instead of
    // blocking. That is the spec's trade, not a bug; narrowing it is a SPEC
    // change (sub-ticket D), not a CR fix. Re-open only with a concrete case
    // where hinting — not blocking — a hint-only prereq is the wrong call,
    // not the theoretical "a dependent installed anyway".

    // CR fix (codex round 4, Suggestion): the `itemsSet` --items-membership
    // Set that used to live here is gone — the closure checks route their
    // messages purely on what actually converges (runnability /
    // desired-ness), never on whether an id happens to be NAMED in --items,
    // since membership alone was proven insufficient on both sides this round
    // and messages that branched on it were handing out remediation advice
    // that didn't work.

    // Toward-enabled direction: every item actually being installed
    // (towardEnabled — the SAME filtered set planInstall/runInstall
    // consume) must carry its full dep closure, or a red/desired
    // prerequisite gets silently skipped (planInstall's DFS treats a dep
    // outside the item set as already-satisfied). A dep that's already
    // green, or not desired at all, is legitimately fine to leave out —
    // that's exactly the case the "excluded == already satisfied"
    // assumption covers correctly, so it must NOT be rejected.
    //
    // CR fix (MAJOR): `itemsSet.has(depId)` is NOT sufficient to skip —
    // being NAMED in --items doesn't mean the dep will actually be
    // installed this run. The only thing that proves it WILL converge is
    // membership in towardEnabled itself (the same filtered set
    // planInstall/runInstall consume). A dep that's desired+red/degraded
    // but hint-only (no runnable install descriptor — e.g. a config-type
    // item, or pre-commit-hooks) never lands in towardEnabled even when
    // it's named in --items, so the dependent would still install on top
    // of a genuinely-missing prerequisite. `--items` membership is never
    // sufficient on either side (enabled or disabled) — only ACTUAL
    // convergence this run is.
    const towardEnabledIds = new Set(towardEnabled.map((i) => i.id));
    // CR fix (CodeRabbit round 23, MAJOR): this is now a TRANSITIVE
    // prerequisite walk, not a direct-edge scan. The prior loop inspected
    // only item.deps[], so a red/desired ANCESTOR hidden behind a GREEN
    // middle node (A red <- B green <- C) was never reached: B is green so
    // the old `severity !== red` guard skipped it, and A (in B's deps, not
    // C's) was never examined at all, so C installed while A — a desired+red
    // prerequisite — stayed missing. Walk the WHOLE dep closure from each
    // towardEnabled item via byId and reject the first desired red/degraded
    // ANCESTOR absent from towardEnabled. Semantics preserved exactly: a dep
    // already green is PRESENT so its OWN prereqs still matter — descend
    // through it; a dep converging this run (in towardEnabled) is covered by
    // its own pass below, so it is not re-walked here; a dep not desired at
    // all is legitimately fine to leave out — never rejected. `visited`
    // guards cycles (manifest-lint already rejects them — defense-in-depth,
    // same as planInstall's DFS).
    for (const item of towardEnabled) {
      const visited = new Set();
      const stack = [...(item.deps || [])];
      let missingDepId = null;
      while (stack.length > 0) {
        const depId = stack.pop();
        if (visited.has(depId)) continue; // cycle guard
        visited.add(depId);
        if (towardEnabledIds.has(depId)) continue; // converging this run — its own pass checks its deps
        const depStatus = fullById.get(depId);
        if (!depStatus || !depStatus.desired) continue; // not desired — legitimately fine to leave out
        if (depStatus.severity === 'red' || depStatus.severity === 'degraded') {
          missingDepId = depId; // desired + red/degraded + not converging — MISSING prerequisite
          break;
        }
        // Already green — present, so its OWN prereqs still matter: descend.
        const depNode = byId.get(depId);
        if (depNode && depNode.deps) {
          for (const d of depNode.deps) stack.push(d);
        }
      }
      if (missingDepId === null) continue;
      const depStatus = fullById.get(missingDepId);
      // CR fix (codex round 4, Suggestion): route the remediation message on
      // RUNNABILITY (the SAME predicate the towardEnabled/hints split above
      // uses), never on --items membership — being NAMED in --items is no
      // proof a dep will converge (a hint-only dep never lands in
      // towardEnabled even when named), so a membership-branched message
      // handed out remediation that didn't work. The hint-only branch names
      // the manual-converge fix; the runnable branch names the corrected
      // --items list.
      const depItem = byId.get(missingDepId);
      const depRunnable = Boolean(depItem && depItem.install
        && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(depItem.install.type) !== -1);
      if (!depRunnable) {
        // Hint-only/non-runnable — will NEVER be dispatched this run (or
        // any run) automatically, whether or not it's named in --items.
        console.error(`himmelctl: --items ${item.id} requires prerequisite ${missingDepId} (also ${depStatus.severity}), but ${missingDepId} has no automated install path (hint-only) — converge it manually first, then re-run`);
      } else {
        const corrected = [missingDepId, ...args.items].join(',');
        console.error(`himmelctl: --items ${item.id} requires prerequisite ${missingDepId} (also ${depStatus.severity}) — add it: --items ${corrected}`);
      }
      return 2;
    }
  }

  // Toward-disabled direction (CR fix, CodeRabbit round 19 — UNGATED: runs
  // on EVERY ensure, filtered or not): the inverse hazard — unwiring an
  // item while a still-desired DEPENDENT would leave that dependent broken.
  // Checked against every in-scope manifest item (a dependent need not
  // itself be `removable` to be broken by a missing prerequisite). This
  // check NEVER reads args.items — it keys purely on desired-ness, so it
  // was wrong to trap it inside the `if (args.items)` block above: an
  // UNFILTERED `ensure --profile core --yes` used to skip it entirely and
  // silently unwire a prerequisite a still-desired dependent needs. desired
  // is computed with NO dependency propagation (status-report.js:
  // `desired = Boolean(entry && entry.enabled)`), so a target holding
  // A.enabled=false while B.enabled=true and B.deps=[A] puts A in
  // towardDisabled (not-desired + removable + present) and breaks B the
  // moment A unwires. Drifted persisted entries are real here — the stale-
  // scope defect fixed in 7222492 on this same PR was exactly that.
  //
  // CR fix (MAJOR, cross-model convergence — codex + CodeRabbit
  // independently found the SAME bug): the previous `itemsSet.has(item.id)`
  // skip was backwards — being INCLUDED in --items does not mean the
  // dependent is being disabled; it only means it's in scope. `--items
  // prereq,dependent` used to pass this check and unwire `prereq` while
  // `dependent` stayed desired/enabled, breaking it. The only thing that
  // matters is whether the dependent is ACTUALLY being unwired this run
  // (i.e. NOT desired — a dependent that's also in towardDisabled is
  // exactly that, and is legitimately fine: reverseDependencyOrder
  // already unwinds it BEFORE the prerequisite). So: reject whenever the
  // dependent is still desired, regardless of --items membership.
  //
  // CR fix (codex round 4, Suggestion): the message used to branch on
  // --items membership and, for the EXCLUDED case, advise "add it:
  // --items prereq,dependent" — advice that doesn't work: merely NAMING
  // dependent in --items was just proven above to be insufficient on its
  // own (that's the whole bug this round fixed), so following it walks
  // straight into the "also selected" rejection instead of resolving
  // anything. Neither branch's remedy actually depends on --items
  // membership at all — the dependent's DESIRED-ness is what blocks it,
  // and that's unaffected by whether it's named. Unified into one message
  // naming both working remediations regardless of membership — and, the
  // check now being ungated, the message no longer claims --items on an
  // unfiltered run either.
  const disabledIds = new Set(towardDisabled.map((i) => i.id));
  // CR fix (CodeRabbit round 23, MAJOR): this is now a TRANSITIVE reverse
  // closure, not a direct-edge scan. The prior loop checked each item's OWN
  // deps[] for a disabled id, so a still-desired DEPENDENT hidden behind an
  // UNDESIRED-but-present middle node (desired C -> undesired-present B ->
  // disabled A) was never reached: B's deps DO include A, but B is undesired
  // so its iteration `continue`s, and C's deps hold B (not A), so C was
  // never examined and A unwired under it. Build the REVERSE graph
  // (depId -> in-scope dependents) and walk it from each disabled id;
  // descend through a dependent that is undesired (it stays PRESENT, so ITS
  // dependents still break when the prerequisite goes), but REJECT the first
  // still-desired dependent reached that is not itself being disabled. A
  // dependent in towardDisabled is legitimately fine
  // (reverseDependencyOrder unwinds it BEFORE the prerequisite); `visited`
  // guards cycles. (This check stays UNGATED — round 19 — so it fires on an
  // unfiltered run too; the message therefore never claims --items.)
  const dependentsOf = new Map();
  for (const item of manifest.items) {
    if (!item.scopes.includes(scope)) continue;
    for (const depId of item.deps || []) {
      if (!dependentsOf.has(depId)) dependentsOf.set(depId, []);
      dependentsOf.get(depId).push(item.id);
    }
  }
  // CR fix (CodeRabbit round 23 follow-on, MAJOR): descend THROUGH an
  // undesired intermediate ONLY when it is actually PRESENT. statusReport
  // deliberately leaves an undesired item's actual state UNPROBED
  // (fullById.get(B).actual === null for a desired:false B — status-report.js
  // short-circuits those), so the walk cannot infer B's presence from
  // fullById. Assuming presence is a FALSE rejection: for A(present) ->
  // B(absent+undesired) -> C(desired), the physical chain is ALREADY broken
  // at the absent B, so unwiring A cannot newly break C — blocking it is
  // wrong. Probe the intermediate's presence (memoized; read-only, same probe
  // the toward-disabled scan above already ran) and recurse only when it is
  // not 'absent'. Still-DESIRED dependents are rejected regardless of their
  // own presence (a desired-but-red dependent whose prerequisite is unwired
  // can never converge), so that branch is unchanged — this gate is on the
  // descend-through-UNDESIRED step only. Pre-seed from towardDisabled (all
  // present by construction — line ~1376 only admits actual !== 'absent') so
  // a removable intermediate is never re-probed.
  const presenceCache = new Map();
  for (const it of towardDisabled) presenceCache.set(it.id, true);
  const isPresent = (id) => {
    if (presenceCache.has(id)) return presenceCache.get(id);
    const node = byId.get(id);
    if (!node) { presenceCache.set(id, false); return false; }
    const ctx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
    const present = probesLib.runProbe(node, ctx).actual !== 'absent';
    presenceCache.set(id, present);
    return present;
  };
  for (const disabledId of disabledIds) {
    const visited = new Set([disabledId]);
    // Each stack entry carries its reverse-walk PATH (disabledId -> ... ->
    // dependent) so a TRANSITIVE break can name the whole chain
    // (C -> B -> A in dep notation), not just the endpoints — clearer than
    // "C depends on A" when C does not depend on A directly. path runs
    // disabledId-first; reverse it for the dep-notation render below.
    const stack = (dependentsOf.get(disabledId) || []).map((dependentId) => ({
      id: dependentId, path: [disabledId, dependentId],
    }));
    while (stack.length > 0) {
      const entry = stack.pop();
      const dependentId = entry.id;
      if (visited.has(dependentId)) continue; // cycle guard
      visited.add(dependentId);
      if (disabledIds.has(dependentId)) continue; // being unwound too — fine
      const dependentStatus = fullById.get(dependentId);
      if (dependentStatus && dependentStatus.desired) {
        // still-desired + not being disabled + (transitively) depends on a
        // disabled id -> REJECT. Name the chain only when genuinely
        // transitive (path > 2 nodes); the direct case keeps the original
        // message verbatim.
        const chain = entry.path.slice().reverse().join(' -> ');
        const chainNote = entry.path.length > 2 ? ` (transitive chain: ${chain})` : '';
        console.error(`himmelctl: would disable ${disabledId}, but ${dependentId} (still desired) depends on it${chainNote} — reconcile ${dependentId} toward undesired too (e.g. via --profile) so both unwire together (reverse-dependency order unwinds ${dependentId} first), or drop ${disabledId} from this run`);
        return 2;
      }
      // Undesired intermediate — its dependents still break when the
      // prerequisite unwires, but ONLY if it is itself still PRESENT: an
      // ABSENT intermediate has already broken the chain, so descending
      // through it and rejecting on a dependent behind it is a false
      // rejection (see the presence note above). Probe (memoized) and
      // descend only when present.
      if (!isPresent(dependentId)) continue;
      for (const subId of dependentsOf.get(dependentId) || []) {
        stack.push({ id: subId, path: [...entry.path, subId] });
      }
    }
  }

  // CR fix: hints must be surfaced on EVERY path, not only the "nothing to
  // converge" early return below — a run that ALSO does real work was
  // dropping them silently. Printed once, unconditionally, right after
  // they're known.
  if (hints.length > 0) {
    console.log(`himmelctl: ${hints.length} item(s) need manual convergence (no automated install path yet): ${hints.join(', ')}`);
  }

  if (towardEnabled.length === 0 && towardDisabled.length === 0) {
    // Nothing is about to be consented to — no install/unwire will run, so
    // it's correct (and the one intentional exception to the deferred-save
    // rule below) to persist the derive/reconcile bookkeeping right here.
    if (stateChanged && !args.dryRun) stateLib.save(state);
    // CR fix: "already at the desired state" is FALSE when hints remain —
    // those items still need manual convergence. Say so instead.
    console.log(hints.length > 0
      ? 'himmelctl: nothing can be converged automatically — manual convergence is still required.'
      : 'himmelctl: nothing to converge — already at the desired state.');
    return 0;
  }

  // CR fix (Critical): a NON-interactive run (piped/automation — exactly how
  // himmelctl runs outside a Claude session) with neither --yes nor
  // --dry-run must NOT silently proceed with no consent. Checked AFTER the
  // no-work early return (nothing to consent to there) and BEFORE the offer/
  // confirm block and any install/unwire dispatch. state.json is untouched
  // (the save is deferred past this point — see the header comment above).
  if (!args.yes && !args.dryRun && !isInteractive(args)) {
    console.error('himmelctl: non-interactive ensure requires --yes');
    return 2;
  }

  // Step 3: consolidated offer, printed ONCE up front — never a mid-run,
  // per-item prompt (HIMMEL-842 bar). --yes skips both the offer print and
  // the confirm attempt entirely.
  if (!args.yes) {
    const parts = [];
    if (towardEnabled.length > 0) parts.push(`converge ${towardEnabled.length} item(s): ${towardEnabled.map((i) => i.id).join(', ')}`);
    if (towardDisabled.length > 0) parts.push(`disable ${towardDisabled.length} item(s): ${towardDisabled.map((i) => i.id).join(', ')}`);
    console.log(`himmelctl: about to ${parts.join('; ')}`);
    if (!args.dryRun && isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log('himmelctl: declined; nothing run.');
        return 0;
      }
    }
  }

  // Consent granted (--yes, an interactive confirm, or --dry-run — which
  // needs none). Persist the derive/reconcile bookkeeping NOW, not before —
  // an operator who declined above, or was refused above for lacking --yes
  // non-interactively, must never have reached this line. Still gated
  // behind !args.dryRun (dry-run's zero-mutation guarantee is unconditional).
  if (stateChanged && !args.dryRun) stateLib.save(state);

  // Step 4: toward-disabled dispatch (A5b) — per-item `removable` check.
  // CR fix: dispatched in REVERSE dependency order (a dependent, B deps on
  // A, unwires BEFORE its prerequisite A) — the inverse of install-time
  // ordering, not manifest declaration order.
  const disableErrors = [];
  // CR fix: tracks successful unwires (unwire ran AND the re-probe
  // confirmed 'absent') — the final "N converged" summary must include
  // these alongside the toward-enabled installs (towardEnabled.length), so a
  // run that ALSO successfully disabled items doesn't silently under-report
  // its own result.
  const disabled = [];
  // CR fix (CodeRabbit round 16, MAJOR — fail-closed): a REAL (non-dry-run)
  // disable failure used to just record the error and keep going, unwiring
  // every remaining item regardless — compounding a broken state (e.g.
  // unwiring a prerequisite right after its dependent's OWN unwire already
  // failed, leaving neither side coherent). `--dry-run` is deliberately
  // EXEMPT: it still enumerates every blocker in one pass (existing case d
  // behavior — the whole point of a preview is seeing everything wrong
  // before doing anything), so `disableAborted` only ever becomes true on
  // a real run, and only for a failure the operator couldn't have
  // dry-run-previewed away.
  let disableAborted = false;
  for (const item of installEngineLib.reverseDependencyOrder(towardDisabled)) {
    if (item.removable === 'per-item' && item.unwire) {
      // CR fix: build the spec and check spec.unrunnable BEFORE the
      // dry-run branch — under the shipped-then-buggy order, a dry-run
      // printed "DRY: unwire <id>" and returned success for an item whose
      // unwire descriptor is genuinely unrunnable, since unwireCommand()
      // was never even called under --dry-run. The dry-run's
      // no-execution guarantee is preserved: unwireCommand() itself never
      // spawns anything, it's a pure descriptor-to-argv builder.
      const spec = installEngineLib.unwireCommand(item, { repoRoot: repoRoot(), scope, targetPath: baseTargetPath, env: process.env });
      if (spec.unrunnable) {
        disableErrors.push(`${item.id}: ${spec.unrunnable}`);
        if (args.dryRun) continue;
        disableAborted = true;
        break;
      }
      if (args.dryRun) {
        console.log(`DRY: unwire ${item.id}`);
        continue;
      }
      // CR fix: routed through installEngineLib.runUnwire() — the SAME
      // hardened spawn path runInstall's own installs already use
      // (env-scrubbed HIMMELCTL_SUDO_PASSWORD, INSTALL_TIMEOUT_SECS timeout
      // + tree-kill on timeout, signal/ETIMEDOUT classification). A raw
      // spawnSync(spec.cmd, spec.args, {stdio:'inherit'}) here — the
      // shipped-then-buggy shape — got NEITHER hardening even after both
      // landed on the install path: a cross-model review caught this drift
      // after ~10 CodeRabbit rounds. See runHardenedSpawn()'s own header
      // for the full rationale.
      const result = installEngineLib.runUnwire(spec);
      if (!result.ok) {
        // CR fix: the reason (e.g. "timed out after Ns") is now appended —
        // a NEW failure mode (timeout) the unwire path never had before
        // routing through the shared hardened spawn, so there's no prior
        // message shape to preserve for it; every OTHER disableErrors
        // message (spec.unrunnable, the reprobe-still-present case,
        // full-offboard-only) is unchanged.
        disableErrors.push(`${item.id}: unwire failed (${result.reason})`);
        disableAborted = true;
        break;
      }
      // CR fix: the unwire primitive exiting 0 doesn't itself prove the
      // resource is gone — re-probe and treat ANY result other than
      // 'absent' (still 'present', or now merely 'degraded') as a failure.
      const reprobeCtx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
      const reprobe = probesLib.runProbe(item, reprobeCtx);
      if (reprobe.actual !== 'absent') {
        disableErrors.push(`${item.id}: unwire ran but the resource is still ${reprobe.actual} (expected absent)`);
        disableAborted = true;
        break;
      }
      disabled.push({ id: item.id });
    } else {
      // CR fix (HIMMEL-1100 round 6, CodeRabbit App PR #1500 thread #4):
      // this branch used to push the blocker UNCONDITIONALLY, without ever
      // probing the item's actual state — so a full-offboard-only item that
      // is PERMANENTLY degraded (e.g. guardrail-block-global, which through
      // this ticket's own round-3 fix could never reach 'present' from
      // status output alone — HIMMEL-1418 later gave it a `status --json`
      // verb rich enough to confirm a genuine full install, so it is no
      // longer an example of a permanently-degraded item, but the general
      // shape still applies to any probe that structurally can't confirm
      // 'present') wedged EVERY `ensure` run the moment a profile change
      // put it in towardDisabled, with no way to ever clear it (there is no
      // unwire descriptor to run — full-offboard-only items don't have one
      // by definition). Only a genuinely 'present' item blocks (the
      // operator has real convergeable work, via `himmelctl uninstall`);
      // 'degraded' logs an advisory instead of erroring (nothing this loop
      // can DO about it, and a probe that structurally can't confirm
      // 'present' must not permanently wedge every run); 'absent' needs no
      // note at all — it's already gone.
      const probeCtx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
      const probe = probesLib.runProbe(item, probeCtx);
      if (probe.actual === 'present') {
        disableErrors.push(`${item.id}: removable:full-offboard-only — run 'himmelctl uninstall' to remove it`);
        if (args.dryRun) continue;
        disableAborted = true;
        break;
      }
      if (probe.actual === 'degraded') {
        console.log(`himmelctl: ${item.id} is removable:full-offboard-only and currently degraded (${probe.detail}) — nothing to converge here; run 'himmelctl uninstall' if you want it fully removed.`);
        continue;
      }
      // absent — already gone, nothing to do; counts toward the "disabled"
      // summary the same way a genuinely-run unwire would.
      disabled.push({ id: item.id });
    }
  }

  // Step 5: plan + run the toward-enabled work. CR fix (CodeRabbit round
  // 16, MAJOR — fail-closed): skipped entirely when a real disable failure
  // already aborted above (`disableAborted`) — do NOT proceed to installs
  // on top of a disable phase that didn't finish cleanly. `disableAborted`
  // is always false under --dry-run (see above), so dry-run's own preview
  // enumeration below is unaffected.
  let failed = [];
  const previewErrors = [];
  if (towardEnabled.length > 0 && !disableAborted) {
    const plan = installEngineLib.planInstall(towardEnabled, {
      repoRoot: repoRoot(), scope, profile: target.profile, targetPath: baseTargetPath, env: process.env,
      // CR fix (CodeRabbit round 19): the qmd install flow registers the
      // luna collection at the vault path; expandHome mirrors every other
      // vault-path consumer in this file (adopt's --luna-target, the
      // luna-vault-scaffold wire). Undefined/empty when vault.mode=none.
      // CR fix (CodeRabbit round 20): empty here is NOT "harmless — the qmd
      // items are never desired without a vault" (the round-19 reasoning this
      // line used to carry): under an EXPLICIT --profile luna/all the qmd
      // items (profiles:["luna","all"]) ARE desired+red even with no vault,
      // so buildEntry's 'qmd' case guards the empty path itself and returns a
      // hint-only unrunnable entry rather than `qmd_register_collection ""
      // luna`. See install-engine.js.
      vaultPath: expandHome(cachedAnswers.vault && cachedAnswers.vault.path),
    });
    if (args.dryRun) {
      for (const p of plan) {
        // CR fix: a plan entry can be {unrunnable: "..."} (buildEntry's own
        // failure case, e.g. an unmapped win32 dep) with no .cmd/.args at
        // all — printing `DRY: ${p.cmd} ${p.args.join(' ')}` against that
        // shape crashed into `DRY: undefined undefined` and (since nothing
        // threw) still returned success. Detect it first and surface it as
        // a genuine preview failure instead.
        if (p.unrunnable) {
          previewErrors.push(`${p.id}: ${p.unrunnable}`);
          console.log(`DRY: ${p.id}: ${p.unrunnable}`);
          continue;
        }
        console.log(`DRY: ${p.cmd} ${p.args.join(' ')}`);
      }
    } else {
      const result = installEngineLib.runInstall(plan, { dryRun: false });
      failed = result.failed;
    }
  }

  // CR fix: a --dry-run full-offboard-only blocker (pushed into
  // disableErrors above regardless of --dry-run) must NOT be silently
  // dropped — surface it as a DRY line and fail the dry-run's own exit
  // code, matching what the real (non-dry-run) run would report. Folds in
  // previewErrors (unrunnable plan entries, above) the same way.
  if (args.dryRun) {
    for (const e of disableErrors) console.log(`DRY: ${e}`);
    return (disableErrors.length > 0 || previewErrors.length > 0) ? 1 : 0;
  }

  // CR fix (CodeRabbit round 16, MAJOR — fail-closed): a real disable
  // failure aborted the loop above BEFORE any install was ever attempted
  // (Step 5, above, already skipped on `disableAborted`) — report it now
  // and stop, never reaching the post-check below. `disableErrors` holds
  // exactly the one failure that triggered the abort (the loop broke on
  // the first one), not every subsequent item's state.
  if (disableAborted) {
    for (const e of disableErrors) console.error(`himmelctl: ${e}`);
    return 1;
  }

  // Step 6: post-check + fail-closed — name still-not-converged items THAT
  // HAD a runnable install descriptor (never fail-close on a hint-only item).
  // Same `state` object as the pre-check (already persisted by this point —
  // dry-run already returned above); its ACTUAL probe results still read
  // real disk (fresh probesLib.runProbe calls) — only the DESIRED flags
  // come from the passed-in state.
  const post = statusReportLib.statusReport({
    manifest, scope, targetPath: baseTargetPath, answers: cachedAnswers, itemIds: args.items, state,
  });
  const stillNotConverged = post.items.filter((r) => {
    const item = byId.get(r.id);
    if (!item || !r.desired || (r.severity !== 'red' && r.severity !== 'degraded')) return false;
    return Boolean(item.install) && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(item.install.type) !== -1;
  });

  // CR fix: `failed` (runInstall's own report) was computed but never
  // consulted here — a primitive that genuinely failed (nonzero exit,
  // signal, or an unrunnable descriptor) whose target item's post-check
  // probe HAPPENED to pass anyway (e.g. a partially-applied change, or an
  // unrelated pre-existing green) read as a false success. A failed/nonzero
  // install must never yield a successful ensure, independent of what the
  // probe says afterward.
  if (stillNotConverged.length > 0 || disableErrors.length > 0 || failed.length > 0) {
    if (stillNotConverged.length > 0) {
      console.error(`himmelctl: ${stillNotConverged.length} item(s) still not converged: ${stillNotConverged.map((r) => r.id).join(', ')}`);
    }
    if (failed.length > 0) {
      console.error(`himmelctl: ${failed.length} install(s) failed: ${failed.map((f) => `${f.id} (${f.reason})`).join(', ')}`);
    }
    for (const e of disableErrors) console.error(`himmelctl: ${e}`);
    return 1;
  }
  // CR fix (CodeRabbit round 19): count MANIFEST ITEMS converged, not plan
  // ENTRIES executed. runInstall's per-entry report under-counts when
  // COALESCE_TYPES collapse the work: two adopt items coalesce into ONE
  // adopt.sh invocation, so the old `ran.length` reported "1 converged" for
  // two items actually converged. towardEnabled holds exactly the manifest
  // items desired+red that this run set out to converge — every one of them
  // IS converged here (stillNotConverged/failed already returned 1 above), so
  // its length is the honest install-side count; `disabled` adds the toward-
  // disabled unwires (already per-item, never coalesced).
  const convergedCount = towardEnabled.length + disabled.length;
  console.log(`himmelctl: ensure complete (${convergedCount} converged).`);
  return 0;
}

// ── scope (HIMMEL-757 C — scope-switch MVP) ───────────────────────────────
//
// `scope get` / `scope status` print the current install scope (a natural
// read off the install-profile cache). `scope set <project|user>` re-projects
// the install from its CURRENT scope to the TARGET scope and converges BOTH
// sides: wires the target scope (toward-enabled, via the same
// planInstall/runInstall cmdEnsure uses) AND unwires the old scope (toward-
// disabled, via unwireCommand/runUnwire in reverseDependencyOrder, with
// ctx.scope=OLD scope so each primitive targets the old scope's RELOCATED
// settings path — project: targetPath/.claude, user: $HOME/.claude).
//
// HARD REQ (operator-LOCKED, do NOT deviate): an item must NEVER be wired in
// BOTH scopes at once — the switch is not complete until the OLD scope is
// clean. MVP can only MECHANICALLY unwire items that carry a runnable
// `unwire` descriptor (today wiring-pretooluse/wiring-statusline). Any item
// that is present in the OLD scope, exists in BOTH scopes, and is
// full-offboard-only with NO runnable unwire descriptor (e.g.
// claude-plugins-pluginSet, tokensave-mcp, graphify-mcp) would be left wired
// in both scopes — FAIL CLOSED before any mutation: list those items, exit
// non-zero. No partial switch.
//
// Mirrors cmdEnsure's proven machinery (consolidated confirm gate, --yes,
// --dry-run zero-mutation, non-interactive-requires-`--yes`, deferred state
// save past consent). Does NOT hand-roll spawns — routes through install-
// engine's hardened runInstall/runUnwire, exactly as cmdEnsure does.

// `scope get` / `scope status` — print the current scope off the install-
// profile cache (the same cache cmdStatus/cmdEnsure load). No manifest, no
// state, no probes: the scope is an ANSWER field, not a derived value.
function cmdScopeGet() {
  const profilePath = cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const cachedAnswers = loadProfile(profilePath);
  console.log(cachedAnswers.scope);
  return 0;
}

async function cmdScopeSet(args) {
  const manifest = loadManifest();

  const profilePath = cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const cachedAnswers = loadProfile(profilePath);

  const oldScope = cachedAnswers.scope;
  const newScope = args.targetScope;
  if (oldScope === newScope) {
    console.log(`himmelctl: current scope is already '${oldScope}' — nothing to switch.`);
    return 0;
  }

  // Base target path per scope — project scope keys off cwd (adopt.sh's own
  // --target default of $PWD), user scope off the himmel checkout (mirrors
  // cmdStatus/cmdEnsure's baseTargetPath resolution). The settings.json a
  // wire/unwire primitive targets is RELOCATED by this: project ->
  // targetPath/.claude, user -> $HOME/.claude (install-engine.js settingsPath).
  const oldBaseTargetPath = oldScope === 'user' ? repoRoot() : path.resolve(process.cwd());
  const newBaseTargetPath = newScope === 'user' ? repoRoot() : path.resolve(process.cwd());
  const oldTargetKey = oldScope === 'user' ? 'user' : path.resolve(process.cwd());
  const newTargetKey = newScope === 'user' ? 'user' : path.resolve(process.cwd());

  const state = stateLib.load();

  // Fail closed when the SOURCE is project scope but the CWD is not the
  // recorded project install target (CR bin.js:59). cachedAnswers.scope may
  // say 'project', but a project install is keyed by absolute path in
  // state.targets — run `scope set` from any OTHER directory and the old-scope
  // probes (rooted at cwd) would see nothing, the real project would never be
  // unwired, and the WRONG state key (this cwd) would be deleted, leaving both
  // scopes wired despite the hard invariant. `scope set` from a project source
  // must run from the adopted project's root, same as install/status/ensure.
  if (oldScope === 'project' && !state.targets[oldTargetKey]) {
    console.error(`himmelctl: current directory is not the recorded project install (${oldTargetKey}) — run 'himmelctl scope set ${newScope}' from the adopted project's root (the same location as install/status/ensure).`);
    return 2;
  }

  // Step 1 (HARD REQ): fail-closed pre-flight. Probe the OLD scope for every
  // item that is present there, exists in BOTH scopes (so it would ALSO be
  // desired + wired in the target scope), and has NO runnable unwire
  // descriptor (so it cannot be mechanically removed from the old scope).
  // Switching would wire it into the target while it stays stranded in the
  // old -> both scopes at once. Refuse BEFORE any mutation (the probes are
  // pure reads), regardless of --dry-run: the switch genuinely cannot
  // proceed, so a preview must say so rather than paint a partial plan. The
  // unwireable pair (wiring-pretooluse/wiring-statusline) is excluded — the
  // unwire path below handles those.
  const failClosed = [];
  for (const item of manifest.items) {
    if (!item.scopes.includes(oldScope) || !item.scopes.includes(newScope)) continue;
    const hasUnwire = Boolean(item.unwire && item.unwire.type === 'wire');
    if (hasUnwire) continue;
    const ctx = { repoRoot: repoRoot(), targetPath: oldBaseTargetPath, scope: oldScope, env: process.env };
    const probe = probesLib.runProbe(item, ctx);
    if (probe.actual !== 'absent') failClosed.push(item.id);
  }
  if (failClosed.length > 0) {
    console.error(`himmelctl: cannot switch scope '${oldScope}' -> '${newScope}': the following item(s) are wired in the old scope '${oldScope}' and have no mechanical unwire path, so switching would leave them wired in BOTH scopes:`);
    for (const id of failClosed) console.error(`  - ${id}`);
    console.error("Handle each manually (or via 'himmelctl uninstall'), or wait for the per-item unwire extension (HIMMEL-1172).");
    return 1;
  }

  // Step 2: re-project membership for the TARGET scope. reconcileTarget
  // re-derives every item's `enabled` for {profile, newScope} and writes the
  // entry at targetKeyForScope(newScope). The profile is UNCHANGED by a scope
  // switch (only the scope moves), so it stays profileForVault(cachedAnswers).
  // Done in-memory; the save is DEFERRED past the consent gate below (mirror
  // cmdEnsure's deferred-save exactly — an operator who declines, or a
  // non-interactive run refused for lacking --yes, leaves state.json
  // byte-untouched).
  const targetProfile = profileForVault(cachedAnswers);
  const oldEntry = state.targets[oldTargetKey];
  const newEntry = stateLib.reconcileTarget(state, manifest, cachedAnswers, { profile: targetProfile, scope: newScope });
  // Carry per-item `overrides` FROM the old scope's entry for items that
  // exist in BOTH scopes (reconcileTarget only carries overrides from the
  // new key's OWN existing entry, not cross-scope); items absent from the
  // target scope simply don't appear in the reconciled entry, so their
  // overrides are dropped by construction.
  if (oldEntry && oldEntry.items) {
    for (const item of manifest.items) {
      if (!item.scopes.includes(oldScope) || !item.scopes.includes(newScope)) continue;
      const oldItem = oldEntry.items[item.id];
      if (oldItem && oldItem.overrides && typeof oldItem.overrides === 'object' && !Array.isArray(oldItem.overrides)) {
        newEntry.items[item.id].overrides = oldItem.overrides;
      }
    }
  }

  // Target-scope pre-check (uses the in-memory reconciled state so the
  // preview matches the reconcile, same as cmdEnsure's pre-check). The
  // toward-enabled work = desired+red/degraded items with a RUNNABLE install
  // descriptor; items with no runnable install are hints (surfaced, never
  // dispatched, never fail-closing — same exemption as cmdEnsure).
  const pre = statusReportLib.statusReport({
    manifest, scope: newScope, targetPath: newBaseTargetPath, answers: cachedAnswers, state,
  });
  const byId = new Map(manifest.items.map((i) => [i.id, i]));
  const wireItems = [];
  const hints = [];
  for (const r of pre.items) {
    const item = byId.get(r.id);
    if (!item || !r.desired || (r.severity !== 'red' && r.severity !== 'degraded')) continue;
    const install = item.install;
    if (install && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(install.type) !== -1) {
      wireItems.push(item);
    } else {
      hints.push(item.id);
    }
  }

  // Old-scope toward-disabled work: every unwireable item still present
  // there (the per-item `unwire:{type:"wire"}` pair). These are unwired from
  // the old scope's relocated settings path so the old scope ends CLEAN —
  // the HARD REQ.
  const unwireItems = [];
  for (const item of manifest.items) {
    if (!item.scopes.includes(oldScope)) continue;
    if (!Boolean(item.unwire && item.unwire.type === 'wire')) continue;
    const ctx = { repoRoot: repoRoot(), targetPath: oldBaseTargetPath, scope: oldScope, env: process.env };
    const probe = probesLib.runProbe(item, ctx);
    if (probe.actual !== 'absent') unwireItems.push(item);
  }

  if (hints.length > 0) {
    console.log(`himmelctl: ${hints.length} item(s) need manual convergence in the target scope (no automated install path yet): ${hints.join(', ')}`);
  }

  // A scope switch ALWAYS at least re-keys state (oldScope !== newScope was
  // confirmed above), so — unlike cmdEnsure — there is no "nothing to
  // converge" early return: even with zero wire/unwire work the target
  // entry moves from oldTargetKey to newTargetKey.

  // Non-interactive without --yes (and not --dry-run) must NOT silently
  // proceed — checked BEFORE the offer/confirm and any dispatch. state.json
  // stays untouched (the save is deferred past consent below).
  if (!args.yes && !args.dryRun && !isInteractive(args)) {
    console.error('himmelctl: non-interactive scope switch requires --yes');
    return 2;
  }

  // Consolidated offer, printed ONCE up front (never per-item). --yes skips
  // both the offer print and the confirm.
  if (!args.yes) {
    const parts = [];
    if (wireItems.length > 0) parts.push(`wire ${wireItems.length} item(s) into '${newScope}': ${wireItems.map((i) => i.id).join(', ')}`);
    if (unwireItems.length > 0) parts.push(`unwire ${unwireItems.length} item(s) from '${oldScope}': ${unwireItems.map((i) => i.id).join(', ')}`);
    const tag = parts.length > 0 ? ` (${parts.join('; ')})` : '';
    console.log(`himmelctl: about to switch scope '${oldScope}' -> '${newScope}'${tag}`);
    if (!args.dryRun && isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log('himmelctl: declined; nothing run.');
        return 0;
      }
    }
  }

  // Build the target-scope wire plan ONCE here — planInstall is deterministic
  // (no spawn, pure computation), so an unrunnable install descriptor (e.g.
  // an unmapped win32 dep) is known BEFORE Step 3 unwires the old scope,
  // instead of only surfacing after. Reused as-is by the dry-run preview
  // below AND by Step 4's runInstall — planInstall is invoked exactly once
  // per switch.
  const wirePlan = wireItems.length > 0
    ? installEngineLib.planInstall(wireItems, {
        repoRoot: repoRoot(), scope: newScope, profile: targetProfile, targetPath: newBaseTargetPath, env: process.env,
        vaultPath: expandHome(cachedAnswers.vault && cachedAnswers.vault.path),
      })
    : [];

  // --dry-run: print the plan (unwire old, wire new, re-key) and exit 0
  // WITHOUT executing or mutating anything. state.json is not saved (the
  // save below is gated on !args.dryRun). Unrunnable wire-plan entries are
  // printed same as always — dry-run stays non-fatal even when Step 3 below
  // would abort a real run.
  if (args.dryRun) {
    for (const item of installEngineLib.reverseDependencyOrder(unwireItems)) {
      console.log(`DRY: unwire ${item.id} (from ${oldScope})`);
    }
    for (const p of wirePlan) {
      if (p.unrunnable) { console.log(`DRY: ${p.id}: ${p.unrunnable}`); continue; }
      console.log(`DRY: ${p.cmd} ${p.args.join(' ')}`);
    }
    console.log(`DRY: re-key state '${oldTargetKey}' -> '${newTargetKey}'`);
    return 0;
  }

  // Fail-closed BEFORE any mutation: an unrunnable wire-plan entry (e.g. an
  // unmapped win32 dep) must abort the switch here, before Step 3 (the first
  // mutating step) unwires the old scope — not after, when Step 4 would
  // otherwise discover it with the old scope already torn down.
  const wirePlanErrors = wirePlan.filter((p) => p.unrunnable);
  if (wirePlanErrors.length > 0) {
    for (const p of wirePlanErrors) console.error(`himmelctl: ${p.id}: ${p.unrunnable}`);
    console.error(`himmelctl: scope switch aborted — the target scope '${newScope}' has ${wirePlanErrors.length} unrunnable item(s); old scope '${oldScope}' was NOT touched.`);
    return 1;
  }

  // Consent granted (--yes or an interactive confirm). The re-keyed state is
  // held IN MEMORY here (reconcileTarget already added the new target entry
  // above) and is NOT persisted yet: the delete-old + save is deferred to
  // AFTER unwire+wire fully converge (just before the cache flip below). A
  // mid-switch failure must leave BOTH state.json AND the install-profile
  // cache describing the OLD scope, so a re-run retries the whole switch
  // idempotently instead of stranding a re-keyed state.json against an
  // unchanged cache and losing the old-scope entry (CR codex-1). Nothing
  // between here and the persist reads state.json from disk — the wire/unwire
  // primitives are external spawns, and the post-check statusReport reads the
  // in-memory `state` — so the deferral is safe.

  // Step 3: UNWIRE the old scope FIRST. Mirrors cmdEnsure's toward-disabled-
  // before-toward-enabled order AND is the safer order for the HARD REQ:
  // unwiring old first means an item is briefly in NEITHER scope (never in
  // both), even on partial failure. Fail-closed: a real unwire failure
  // aborts BEFORE any wire dispatch — do not wire the target scope on top of
  // a broken old-scope teardown. The recorded scope (install-profile cache)
  // is only flipped AFTER full success (see writeCache below), so a re-run
  // of `scope set <newScope>` still sees the OLD scope as current and retries
  // the whole switch idempotently.
  const unwireErrors = [];
  let unwireAborted = false;
  for (const item of installEngineLib.reverseDependencyOrder(unwireItems)) {
    const spec = installEngineLib.unwireCommand(item, { repoRoot: repoRoot(), scope: oldScope, targetPath: oldBaseTargetPath, env: process.env });
    if (spec.unrunnable) {
      unwireErrors.push(`${item.id}: ${spec.unrunnable}`);
      unwireAborted = true;
      break;
    }
    const result = installEngineLib.runUnwire(spec);
    if (!result.ok) {
      unwireErrors.push(`${item.id}: unwire failed (${result.reason})`);
      unwireAborted = true;
      break;
    }
    // The unwire primitive exiting 0 doesn't itself prove the resource is
    // gone — re-probe the OLD scope and treat anything other than 'absent'
    // as a failure (mirrors cmdEnsure's toward-disabled reprobe gate).
    const reprobeCtx = { repoRoot: repoRoot(), targetPath: oldBaseTargetPath, scope: oldScope, env: process.env };
    const reprobe = probesLib.runProbe(item, reprobeCtx);
    if (reprobe.actual !== 'absent') {
      unwireErrors.push(`${item.id}: unwire ran but the resource is still ${reprobe.actual} in ${oldScope} (expected absent)`);
      unwireAborted = true;
      break;
    }
  }
  if (unwireAborted) {
    for (const e of unwireErrors) console.error(`himmelctl: ${e}`);
    console.error(`himmelctl: scope switch aborted — old scope '${oldScope}' teardown did not converge; the new scope was NOT wired and the recorded scope was NOT changed. Re-run 'himmelctl scope set ${newScope}' to retry (idempotent).`);
    return 1;
  }

  // Step 4: WIRE the target scope (toward-enabled). Skipped entirely if an
  // unwire failure aborted above. Reuses `wirePlan` (built + validated above,
  // before Step 3) via the same runInstall cmdEnsure uses (topological order,
  // coalescing, hardened spawn) — planInstall is not called again here.
  let failed = [];
  if (wireItems.length > 0) {
    const result = installEngineLib.runInstall(wirePlan, { dryRun: false });
    failed = result.failed;
  }

  // Step 5: post-check the target scope + fail-closed. Name any target-scope
  // item still not converged that HAD a runnable install descriptor, plus any
  // primitive that genuinely failed (nonzero exit/signal/unrunnable) even if
  // its post-check probe coincidentally reads green — same posture as cmdEnsure.
  const post = statusReportLib.statusReport({
    manifest, scope: newScope, targetPath: newBaseTargetPath, answers: cachedAnswers, state,
  });
  const stillNotConverged = post.items.filter((r) => {
    const item = byId.get(r.id);
    if (!item || !r.desired || (r.severity !== 'red' && r.severity !== 'degraded')) return false;
    return Boolean(item.install) && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(item.install.type) !== -1;
  });
  if (stillNotConverged.length > 0 || failed.length > 0) {
    if (stillNotConverged.length > 0) {
      console.error(`himmelctl: ${stillNotConverged.length} target-scope item(s) still not converged: ${stillNotConverged.map((r) => r.id).join(', ')}`);
    }
    if (failed.length > 0) {
      console.error(`himmelctl: ${failed.length} install(s) failed: ${failed.map((f) => `${f.id} (${f.reason})`).join(', ')}`);
    }
    console.error(`himmelctl: scope switch incomplete — old scope '${oldScope}' unwired, but the new scope '${newScope}' did not fully converge, and the recorded scope was NOT changed. Re-run 'himmelctl scope set ${newScope}' to retry (idempotent).`);
    return 1;
  }

  // The switch fully converged. NOW commit the two metadata artifacts other
  // verbs read — the install-profile cache (recorded scope, read by
  // cmdScopeGet/status/ensure) and the re-keyed state.json — the LAST steps,
  // deliberately AFTER successful unwire+wire. These are two non-atomic writes;
  // the AUTHORITATIVE cache pointer is written FIRST, then the state re-key, so
  // a failure BETWEEN them is benign and self-healing: the cache already
  // describes the new scope (correct — the disk wiring matches), and `ensure`
  // re-derives the target-scope state entry on the next run. The reverse order
  // would leave the cache pointing at the OLD scope with the old state key
  // already deleted, which the CWD guard above then refuses to retry (stuck).
  // A fully transactional commit (journal/recovery marker) is deferred to
  // HIMMEL-1174; the hard invariant (no item wired in BOTH scopes) already
  // holds here — the wiring converged on disk above, before either write.
  // Gated behind !dryRun (dry-run returned above).
  writeCache(Object.assign({}, cachedAnswers, { scope: newScope }));
  delete state.targets[oldTargetKey];
  stateLib.save(state);

  console.log(`himmelctl: scope switched '${oldScope}' -> '${newScope}' (${wireItems.length} wired, ${unwireItems.length} unwired).`);
  return 0;
}

// `scope` dispatcher: validates the verb (+ target for set), then routes to
// the read (get/status) or the switch (set). parseArgs already rejected an
// unknown verb / a misplaced target / a duplicate, so the remaining checks
// here are the "verb/target simply absent" class parseArgs can't surface
// (null vs. a value).
async function cmdScope(args) {
  if (args.scopeVerb === null) {
    console.error("himmelctl: scope requires a verb: set|get|status");
    console.error("Run 'himmelctl --help' for usage.");
    return 2;
  }
  if (args.scopeVerb === 'get' || args.scopeVerb === 'status') {
    return cmdScopeGet();
  }
  // scopeVerb === 'set'
  if (args.targetScope === null) {
    console.error("himmelctl: scope set requires a target: project|user");
    console.error("Run 'himmelctl --help' for usage.");
    return 2;
  }
  return cmdScopeSet(args);
}

// ── trust ledger wiring (HIMMEL-1551) ───────────────────────────────────────
//
// `himmelctl trust on|off|status` — install, remove, or report the HIMMEL-1529
// shadow ledger's hook entries in the project's .claude/settings.json. The
// count lives in the wiring script's ENTRIES table, not here — HIMMEL-1547
// made it seven, and a number repeated in a comment is a number that drifts.
//
// Why this is a command at all: the recorder shipped behind a MANUAL PASTE of
// six JSON blocks, and three consecutive chain legs then measured
// `requests recorded 0`. A capability that ships behind a manual paste is a
// capability that does not ship.
//
// Kept THIN on purpose, matching the `config` pattern above: every assertion
// that makes writing a deny-listed file safe (permissions unchanged, nothing
// but `hooks` touched, idempotent, byte-reversible) lives in the wiring script,
// which is what the test suite exercises. This function only resolves the path
// and forwards a verb — so the guarantees cannot drift between two callers.
// The project `trust` acts on. Routed through `bash -c` for the same reason
// detectRole() is: a hermetic test can stub `git` with a plain bash script on
// the stub PATH, which direct spawnSync cannot exec on win32. The git line is a
// fixed string, never user input. Any git failure (absent git, not a repo)
// falls through to the working directory, which is still the directory the
// operator is standing in — never this CLI's own checkout.
function trustTargetDir() {
  if (process.env.CLAUDE_PROJECT_DIR) return process.env.CLAUDE_PROJECT_DIR;
  const t = spawnSync(resolveBash(), ['-c', 'git rev-parse --show-toplevel'], { encoding: 'utf8' });
  const top = (!t.error && t.status === 0 && t.stdout) ? t.stdout.trim() : '';
  return top || process.cwd();
}

async function cmdTrust(args) {
  if (args.trustVerb === null) {
    console.error('himmelctl: trust requires a verb: on|off|status');
    console.error("Run 'himmelctl --help' for usage.");
    return 2;
  }
  const script = path.join(repoRoot(), 'scripts', 'trust', 'wire-trust-hooks.mjs');
  if (!fs.existsSync(script)) {
    console.error(`himmelctl: trust wiring script not found at ${script}`);
    return 1;
  }
  // Pass the target EXPLICITLY — and resolve it from the project the operator
  // is STANDING IN, never from this CLI's own location.
  //
  // `repoRoot()` is correct for locating himmel's own wiring script above, and
  // WRONG for the target: it is `resolve(__dirname, '..', '..')`, so it names
  // the himmel checkout whatever directory you ran from. An earlier round tried
  // to fix ambient resolution by printing the path — which made the wrong
  // target visible without making it correct, and additionally suppressed the
  // script's own `CLAUDE_PROJECT_DIR` fallback by passing an explicit path that
  // overrode it. Printing a path is not targeting it.
  //
  // Order is CLAUDE_PROJECT_DIR, then the working directory's git root, then
  // the working directory itself. It deliberately does NOT match the wiring
  // script's own `defaultSettingsPath()`, whose second step is
  // `resolve(HERE,'..','..')` — the script checkout — because that fallback is
  // the very ambient resolution this fixes. They agree on the step that
  // matters (CLAUDE_PROJECT_DIR wins) and diverge where the CLI knows more:
  // the CLI has a meaningful cwd, a script invoked directly may not. Wiring a
  // project that has no
  // recorder is still refused by the script's own precondition — that refusal
  // is the safety net this resolution order makes reachable again.
  const settingsPath = path.join(trustTargetDir(), '.claude', 'settings.json');
  if (!fs.existsSync(settingsPath)) {
    console.error(`himmelctl: no .claude/settings.json at ${settingsPath}`);
    console.error('  trust configures the project you are standing in — cd to that project,');
    console.error('  or set CLAUDE_PROJECT_DIR to name it explicitly.');
    return 1;
  }
  console.log(`himmelctl trust: target ${settingsPath}`);
  const flags = [...{ on: [], off: ['--off'], status: ['--check'] }[args.trustVerb], settingsPath];
  // `node` directly, not via bash: the wiring script is a .mjs and this avoids
  // the Windows bare-`bash` resolution failure the hook commands themselves are
  // written to dodge (HIMMEL-1516/1526).
  const r = spawnSync(process.execPath, [script, ...flags], { stdio: 'inherit' });
  if (r.error) {
    console.error(`himmelctl: could not run the trust wiring script: ${r.error.message}`);
    return 1;
  }
  return typeof r.status === 'number' ? r.status : 1;
}

// ── config (HIMMEL-758, epic HIMMEL-755 sub-ticket D) ───────────────────────
//
// `himmelctl config` — an interactive TUI (reuses the T2 question engine's
// own makeAsk()/askEnum()/askPath() readline primitives) plus a
// non-interactive `config set <path> <value>` / `config get <path>` pair, so
// an operator can toggle himmel capabilities without hand-editing files.
// Kept THIN on purpose (P1 pattern): every actual mutation lives in a pure-
// ish setter function below; the TUI only asks questions and calls them, so
// the setters — not the interactive loop — are what the test suite exercises.
//
// Three config surfaces, three DIFFERENT real mechanisms (never a uniform
// fake one):
//   initiative.<leg>     on|off  -> scripts/lib/set-env-var.sh upserts
//                                  HIMMEL_INITIATIVE=<comma-legs> into the
//                                  repo .env (the same file
//                                  scripts/hooks/inject-initiative.sh sources).
//   lanes.<id>            on|off  -> scripts/lanes/set-lane-override.mjs
//                                  upserts a `{id, probe:{kind}}` entry into
//                                  the gitignored scripts/lanes/lanes.local.json
//                                  overlay (never scripts/lanes/lanes.json —
//                                  the shared registry is read-only from here).
//   hooks.improveOnSubmit on|off  -> ADVISORY ONLY. IMPROVE_ON_SUBMIT
//                                  (scripts/hooks/improve-on-submit.sh) is
//                                  documented launching-shell-only — the hook
//                                  never sources the repo .env — so writing it
//                                  to a file would be a silent no-op. Printing
//                                  the correct manual instructions IS the
//                                  honest mechanism here.
//   hooks.plugin.<name>   on|off  -> `claude plugin enable/disable <name>`
//                                  (mirrors applyPluginStep()'s own
//                                  runPluginEnable() bash-c pattern), for the
//                                  documented pluginSet=full plugin names
//                                  (FULL_PLUGIN_ENABLE).
// Deliberately NOT exposed here: the built-in safety PreToolUse hooks
// (auto-approve-safe-bash / block-edit-on-main / block-read-secrets). Those
// are wired via wire-pretouluse-hooks.sh as part of `install`/`ensure`, not a
// casual per-hook toggle — CLAUDE.md's own layering doctrine treats them as
// safety-critical default-hooks, and giving them a friendly on/off switch
// here would undermine exactly the guardrail-escalation model this repo
// documents. Their bypass stays the existing documented convention (a
// session env var set in the LAUNCHING shell), unrelated to a config write.

// The 7 configurable initiative legs — scripts/lib/initiative-legs.sh's own
// _IL_VOCAB minus 'plan', which that file documents as a reserved token with
// no behavior yet (nothing to toggle).
const INITIATIVE_LEGS = ['execute', 'prcheck', 'pr', 'ticket', 'merge', 'public', 'handover'];

// The plugin names `hooks.plugin.<name>` accepts — derived lazily from the
// canonical pluginSet=full data rather than a second hand-maintained list.
function hookPluginNames() {
  return fullPluginEnable().map((p) => p.spec.split('@')[0]);
}

function envFilePath() {
  return path.join(repoRoot(), '.env');
}

// The bash executable EVERY himmelctl bash spawn must use (HIMMEL-1192).
// `bash` bare is resolved by the OS PATH, and on the operator's Windows
// PowerShell PATH that resolves to C:\Windows\System32\bash.exe — the WSL
// launcher — because Git Bash is LAST on PATH. WSL cannot run a Windows-path
// script in ANY form: backslashes are eaten (C:\...\x.sh -> C:...x.sh, "No
// such file or directory") and the forward-slashed C:/... form is absent from
// the WSL rootfs (which needs /mnt/c/...). So trusting PATH order is the bug
// (sibling of the MSYS backslash mangling toBashPath handles — that one only
// helps once the RIGHT, Git-Bash, interpreter is chosen). Resolve a
// Windows-native Git Bash DETERMINISTICALLY instead: it runs the mixed C:/...
// form toBashPath produces. Candidate search over the standard
// Git-for-Windows install locations; first hit wins (bin\bash.exe preferred —
// it sets up the MSYS environment). There is deliberately NO process.platform
// guard: the ProgramFiles/LOCALAPPDATA env vars being set (and a Git\bin\bash
// actually existing under them) IS the "this is a Windows Git install" signal,
// which keeps the helper uniformly unit-testable on a posix CI runner (point
// ProgramFiles at a fixture) — on real posix those vars are unset, so the loop
// finds nothing and falls through. If the standard locations miss, a win32
// fallback scans PATH for a Git Bash installed elsewhere (scoop / portable /
// choco-to-custom-dir) but NOT a WSL launcher (CR [codex-1] — HIMMEL-1192).
// Only then does it fall back to bare 'bash' (posix always; win32 only if the
// sole bash on PATH is WSL — then HIMMELCTL_BASH is the escape hatch; himmel
// hard-gates bash, so an adopter has one). HIMMELCTL_BASH overrides everything
// (nonstandard install OR a hermetic test pinning a specific bash) — same
// env-seam class as HIMMELCTL_REPO_ROOT.
function resolveBash() {
  if (process.env.HIMMELCTL_BASH) return process.env.HIMMELCTL_BASH;
  const localPrograms = process.env.LOCALAPPDATA
    ? path.join(process.env.LOCALAPPDATA, 'Programs')
    : null;
  const bases = [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], localPrograms];
  const relCandidates = [['Git', 'bin', 'bash.exe'], ['Git', 'usr', 'bin', 'bash.exe']];
  for (const base of bases) {
    if (!base) continue;
    for (const rel of relCandidates) {
      const cand = path.join(base, ...rel);
      try {
        if (fs.existsSync(cand)) return cand;
      } catch (_e) { /* unreadable base — try the next candidate */ }
    }
  }
  // Git installed off the standard locations but ON PATH — return it rather
  // than the WSL bare-'bash'. win32-only: on posix bare 'bash' is correct and a
  // concrete PATH hit would needlessly break the hermetic suites' bare-'bash'
  // contract (they pin a stub bash on PATH).
  if (process.platform === 'win32') {
    const onPath = firstNonWslBashOnPath();
    if (onPath) return onPath;
  }
  return 'bash';
}

// Scan PATH for the first `bash`/`bash.exe` that is NOT a Windows WSL launcher
// (System32\bash.exe, or the WindowsApps app-execution alias) — those ARE the
// WSL bash resolveBash() exists to avoid. Returns null when the only bash on
// PATH is a WSL launcher (or none is), leaving resolveBash's bare-'bash' last
// resort + the HIMMELCTL_BASH override. win32-only caller, but pure/portable.
function firstNonWslBashOnPath() {
  const raw = process.env.PATH || process.env.Path || '';
  for (const dir of raw.split(path.delimiter)) {
    if (!dir) continue;
    const low = dir.toLowerCase();
    if (low.includes('system32') || low.includes('windowsapps')) continue;
    for (const name of ['bash.exe', 'bash']) {
      const cand = path.join(dir, name);
      try {
        if (fs.existsSync(cand)) return cand;
      } catch (_e) { /* unreadable dir — try the next */ }
    }
  }
  return null;
}

// Convert a native repo path to the Git-Bash/MSYS-safe form for any path
// handed to `bash` as a spawn arg. path.join() emits BACKSLASHES on Windows
// (C:\...); Git-Bash can misresolve a backslashed/drive-letter --env-file
// target to the wrong file, whereas the forward-slice form (C:/...) resolves
// reliably — the same convention the test harness's own winpath()/cygpath -m
// uses at the node/bash boundary. No-op on posix (no backslashes). Applied to
// every SCRIPT-PATH arg handed to resolveBash() (writeEnvVar, writeHandoverDir,
// runPreflight, deriveCommand, deriveExistingVaultPlan, deriveUpdateCommand)
// and to the --env-file target by writeEnvVar/writeHandoverDir (HIMMEL-758/1192).
function toBashPath(p) {
  return p.replace(/\\/g, '/');
}

// Read one KEY's raw value from the repo .env FILE ONLY — never process.env.
// config get/set manage the PERSISTED value; a session's launching-shell env
// is a different, unrelated thing (same distinction writeHandoverDir's own
// callers already draw). Absent file or absent key -> ''.
function readEnvVarFile(key) {
  let raw;
  try {
    raw = fs.readFileSync(envFilePath(), 'utf8');
  } catch (e) {
    // ONLY an absent file means "unset" -> ''. An EACCES / I/O error must NOT
    // masquerade as unset: config set would then derive its replacement from a
    // bogus empty value and DROP every token already in the real file. Rethrow
    // so main()'s catch turns it into a hard exit 1 before any mutation.
    if (e && e.code === 'ENOENT') return '';
    throw e;
  }
  return probesLib.parseDotEnv(raw)[key] || '';
}

// Toggle one token in a comma-separated set string. Pure. Preserves every
// OTHER token already present (including ones outside INITIATIVE_LEGS —
// never silently drops an operator's hand-edited value).
function toggleToken(csv, token, on) {
  const set = new Set(String(csv || '').split(',').map((s) => s.trim()).filter(Boolean));
  if (on) set.add(token); else set.delete(token);
  return [...set].join(',');
}

// Write KEY=VALUE to the repo .env via set-env-var.sh (never a direct file
// write of our own — see install-engine.js's own wiring-writer doctrine).
// --dry-run prints the would-be line and returns without spawning anything.
function writeEnvVar(key, value, args) {
  const target = envFilePath();
  if (args.dryRun) {
    console.log(`DRY: ${key}=${value} (would write to ${target})`);
    return true;
  }
  const script = path.join(repoRoot(), 'scripts', 'lib', 'set-env-var.sh');
  const r = spawnSync(resolveBash(), [toBashPath(script), key, value, '--env-file', toBashPath(target)], { encoding: 'utf8' });
  if (r.error || r.status !== 0) {
    const detail = (r.stderr || (r.error && r.error.message) || '').trim();
    console.error(`himmelctl: failed to write ${key} via ${script}${detail ? `: ${detail}` : ''}`);
    return false;
  }
  console.log(`${key} -> ${value || '(empty)'} (written to ${target})`);
  return true;
}

function cmdConfigSetInitiative(leg, onOff, args) {
  if (INITIATIVE_LEGS.indexOf(leg) === -1) {
    console.error(`himmelctl: unknown initiative leg '${leg}' (known: ${INITIATIVE_LEGS.join(', ')})`);
    return 2;
  }
  const current = readEnvVarFile('HIMMEL_INITIATIVE');
  const next = toggleToken(current, leg, onOff === 'on');
  return writeEnvVar('HIMMEL_INITIATIVE', next, args) ? 0 : 1;
}

function cmdConfigGetInitiative(leg) {
  const current = readEnvVarFile('HIMMEL_INITIATIVE');
  const activeSet = new Set(current.split(',').map((s) => s.trim()).filter(Boolean));
  if (leg) {
    if (INITIATIVE_LEGS.indexOf(leg) === -1) {
      console.error(`himmelctl: unknown initiative leg '${leg}' (known: ${INITIATIVE_LEGS.join(', ')})`);
      return 2;
    }
    console.log(`initiative.${leg}: ${activeSet.has(leg) ? 'on' : 'off'}`);
    return 0;
  }
  console.log(`HIMMEL_INITIATIVE=${current || '(unset)'} (from ${envFilePath()})`);
  const active = INITIATIVE_LEGS.filter((l) => activeSet.has(l));
  console.log(`active legs: ${active.length > 0 ? active.join(', ') : '(none)'}`);
  return 0;
}

// lanes.<id> — the overlay surface. Base scripts/lanes/lanes.json is READ
// ONLY (id validation); every write targets lanes.local.json exclusively.
function lanesBasePath() {
  return path.join(repoRoot(), 'scripts', 'lanes', 'lanes.json');
}
function lanesLocalPath() {
  return path.join(repoRoot(), 'scripts', 'lanes', 'lanes.local.json');
}
// Returns the base registry object, or `null` when it is missing, unreadable or
// malformed. The null distinction lets callers FAIL CLOSED: an unreadable
// registry must never let an arbitrary id through validation.
function readLanesBase() {
  try {
    const base = JSON.parse(fs.readFileSync(lanesBasePath(), 'utf8'));
    return base && typeof base === 'object' && Array.isArray(base.lanes) ? base : null;
  } catch (_e) {
    return null;
  }
}
function knownLaneIds() {
  const base = readLanesBase();
  return base
    ? base.lanes.map((l) => l && l.id).filter((id) => typeof id === 'string' && id !== '')
    : null;
}
function readLanesLocal() {
  let raw;
  try {
    raw = fs.readFileSync(lanesLocalPath(), 'utf8');
  } catch (e) {
    // Reserve the empty fallback for a genuinely-absent overlay (ENOENT = no
    // overrides). An EACCES / I/O error must not masquerade as "no overrides".
    if (e && e.code === 'ENOENT') return { lanes: [] };
    throw e;
  }
  // Malformed JSON throws here -> main()'s catch, exit 1 (never silently
  // treated as empty). A valid-JSON-but-wrong-shape overlay (null, or
  // {"lanes":{}}) would otherwise crash later at `.lanes.find`; reject it here
  // with a clear message instead.
  const parsed = JSON.parse(raw);
  if (!parsed || typeof parsed !== 'object' || !Array.isArray(parsed.lanes)) {
    throw new Error(`malformed lanes overlay ${lanesLocalPath()} — expected an object with a "lanes" array`);
  }
  return parsed;
}

// Report the resolver's adopter-profile decision for one lane from the same
// base + local data config get already owns. A scoped profile constrains only
// its wizard-owned ids; legacy profiles without a scope retain their original
// all-optional-lanes meaning. Probe overrides are intentionally separate.
function laneProfileState(base, local, laneId) {
  if (!Array.isArray(local.profileAllowlist)) return 'no adopter profile allowlist';
  if (!base) return 'unknown (base lane registry is missing or unreadable)';
  const lane = base.lanes.find((l) => l && l.id === laneId);
  if (!lane) return 'unknown (lane absent from base registry)';
  if (lane.class === 'claude-tier') return 'not constrained (Claude tier)';
  const scope = Array.isArray(local.profileAllowlistScope) ? local.profileAllowlistScope : null;
  if (scope && scope.indexOf(laneId) === -1) return 'not constrained by adopter profile';
  return local.profileAllowlist.indexOf(laneId) === -1
    ? 'suppressed-by-profile'
    : 'allowlisted by adopter profile';
}

function cmdConfigSetLane(laneId, onOff, args) {
  const known = knownLaneIds();
  if (known === null) {
    console.error(`himmelctl: cannot validate lane id — base lane registry ${lanesBasePath()} is missing or unreadable`);
    return 2;
  }
  if (known.indexOf(laneId) === -1) {
    console.error(`himmelctl: unknown lane id '${laneId}' (known: ${known.join(', ') || '(none)'})`);
    return 2;
  }
  const probeKind = onOff === 'on' ? 'always' : 'never';
  const target = lanesLocalPath();
  if (args.dryRun) {
    console.log(`DRY: lane '${laneId}' -> probe.kind=${probeKind} (would write to ${target})`);
    return 0;
  }
  const script = path.join(repoRoot(), 'scripts', 'lanes', 'set-lane-override.mjs');
  const r = spawnSync(process.execPath, [script, laneId, probeKind, '--file', target], { encoding: 'utf8' });
  if (r.error || r.status !== 0) {
    const detail = (r.stderr || (r.error && r.error.message) || '').trim();
    console.error(`himmelctl: failed to write lane override via ${script}${detail ? `: ${detail}` : ''}`);
    return 1;
  }
  const profileNote = (r.stdout || '').includes('added to profileAllowlist')
    ? '; added to adopter profile allowlist'
    : '';
  console.log(`lane '${laneId}' -> probe.kind=${probeKind}${profileNote} (written to ${target})`);
  return 0;
}

function cmdConfigGetLane(laneId) {
  const target = lanesLocalPath();
  const base = readLanesBase();
  if (!laneId) {
    console.log(`lanes overlay: ${target}`);
    if (!fs.existsSync(target)) {
      console.log('  (no overrides — scripts/lanes/lanes.json applies as-is)');
      console.log('profile suppression: no adopter profile allowlist');
      return 0;
    }
    const local = readLanesLocal();
    console.log(JSON.stringify(local, null, 2));
    if (!base) {
      console.log('profile suppression: unknown (base lane registry is missing or unreadable)');
      return 0;
    }
    const suppressed = base.lanes
      .filter((lane) => lane && laneProfileState(base, local, lane.id) === 'suppressed-by-profile')
      .map((lane) => lane.id);
    console.log(`profile policy suppresses when base probes pass: ${suppressed.length > 0 ? suppressed.join(', ') : '(none)'}`);
    return 0;
  }
  const local = readLanesLocal();
  const override = (local.lanes || []).find((l) => l && l.id === laneId);
  const profileState = laneProfileState(base, local, laneId);
  console.log(override
    ? `lane '${laneId}': override probe.kind=${override.probe && override.probe.kind}`
    : `lane '${laneId}': no override (falls back to the base probe in scripts/lanes/lanes.json)`);
  console.log(`lane '${laneId}' profile: ${profileState === 'suppressed-by-profile'
    ? 'suppressed-by-profile when its base probe passes'
    : profileState}`);
  return 0;
}

// hooks.<...> — two real, DIFFERENT mechanisms; see this section's own
// header for why a uniform toggle would be dishonest here.
function cmdConfigSetHook(hookPath, onOff, args) {
  if (hookPath.length === 1 && hookPath[0] === 'improveOnSubmit') {
    // Not a settable config value: IMPROVE_ON_SUBMIT is a launching-shell-only
    // env var (scripts/hooks/improve-on-submit.sh reads it straight from the
    // process env and never sources the repo .env), so no file himmelctl could
    // write would activate it. Reject with rc 2 rather than returning a
    // success code for a no-op write — a script checking $? must not read this
    // as "the toggle happened". The how-to guidance still prints.
    console.error('himmelctl: hooks.improveOnSubmit is not settable via config — '
      + 'IMPROVE_ON_SUBMIT is a launching-shell-only env var that no file himmelctl '
      + 'writes can activate.');
    console.error(onOff === 'on'
      ? '  To enable: export IMPROVE_ON_SUBMIT=1 in the shell that launches claude, then restart the session.'
      : '  To disable: unset IMPROVE_ON_SUBMIT in the launching shell, then restart the session.');
    return 2;
  }
  if (hookPath.length === 2 && hookPath[0] === 'plugin') {
    const name = hookPath[1];
    if (hookPluginNames().indexOf(name) === -1) {
      console.error(`himmelctl: unknown plugin '${name}' (known: ${hookPluginNames().join(', ')})`);
      return 2;
    }
    const verb = onOff === 'on' ? 'enable' : 'disable';
    const line = `claude plugin ${verb} ${name}`;
    if (args.dryRun) {
      console.log(`DRY: ${line}`);
      return 0;
    }
    // Routed through `bash -c` for the same reason applyPluginStep's own
    // runPluginEnable() is (see its header): hermetically stubbable with a
    // plain script on PATH, and avoids win32 spawnSync's own PATH resolution
    // picking an unrelated same-named binary over the correct .cmd shim.
    console.log(`himmelctl: ${line}`);
    const r = spawnSync(resolveBash(), ['-c', line], { stdio: 'inherit' });
    if (r.error) {
      console.error(`himmelctl: failed to launch: ${r.error.message}`);
      return 1;
    }
    if (r.status !== 0) {
      console.error(`himmelctl: command exited ${r.status}: ${line}`);
      return 1;
    }
    return 0;
  }
  console.error(`himmelctl: unknown hook path: hooks.${hookPath.join('.')}`);
  return 2;
}

function cmdConfigGet(pathParts) {
  const [ns, ...rest] = pathParts;
  if (ns === 'initiative') {
    // 'initiative' (whole) or 'initiative.<leg>' — reject over-qualified
    // (initiative.execute.extra) and unknown legs (cmdConfigGetInitiative
    // does not validate the leg itself).
    if (rest.length > 1) {
      console.error(`himmelctl: config get: over-qualified path 'initiative.${rest.join('.')}' — expected 'initiative' or 'initiative.<leg>'`);
      return 2;
    }
    if (rest.length === 1 && INITIATIVE_LEGS.indexOf(rest[0]) === -1) {
      console.error(`himmelctl: config get: unknown initiative leg '${rest[0]}' (known: ${INITIATIVE_LEGS.join(', ')})`);
      return 2;
    }
    return cmdConfigGetInitiative(rest[0]);
  }
  if (ns === 'lanes') {
    // 'lanes' (whole overlay) or 'lanes.<id>' — reject over-qualified and
    // validate the id against the base registry (fail-closed if unreadable).
    if (rest.length > 1) {
      console.error(`himmelctl: config get: over-qualified path 'lanes.${rest.join('.')}' — expected 'lanes' or 'lanes.<id>'`);
      return 2;
    }
    if (rest.length === 1) {
      const known = knownLaneIds();
      if (known === null) {
        console.error(`himmelctl: cannot validate lane id — base lane registry ${lanesBasePath()} is missing or unreadable`);
        return 2;
      }
      if (known.indexOf(rest[0]) === -1) {
        console.error(`himmelctl: unknown lane id '${rest[0]}' (known: ${known.join(', ') || '(none)'})`);
        return 2;
      }
    }
    return cmdConfigGetLane(rest[0]);
  }
  if (ns === 'hooks') {
    // himmelctl config does not READ hook state — neither hooks.* path exposes a
    // value config owns: improveOnSubmit lives only in the launching shell's env,
    // and a plugin's enabled state lives in claude's own config, not any file
    // himmelctl reads. Returning a mapping-description as if it were a value is
    // what CodeRabbit flagged (an "instructions, not current value" get), so all
    // `get hooks*` paths reject with rc 2 + guidance on where the real state
    // lives. (`config set hooks.plugin.<name>` still performs the real toggle.)
    if (rest.length === 2 && rest[0] === 'plugin' && hookPluginNames().indexOf(rest[1]) === -1) {
      console.error(`himmelctl: config get: unknown plugin '${rest[1]}' (known: ${hookPluginNames().join(', ')})`);
      return 2;
    }
    const validShape = rest.length === 0
      || (rest.length === 1 && rest[0] === 'improveOnSubmit')
      || (rest.length === 2 && rest[0] === 'plugin');
    if (!validShape) {
      console.error(`himmelctl: config get: unknown hook path 'hooks.${rest.join('.')}' — expected 'hooks', 'hooks.improveOnSubmit', or 'hooks.plugin.<name>'`);
      return 2;
    }
    console.error('himmelctl: config get does not report hook state — hooks are not a readable config value.');
    console.error('  hooks.improveOnSubmit: launching-shell env var — check IMPROVE_ON_SUBMIT in the shell that launches claude.');
    console.error(`  hooks.plugin.<name>: claude-owned — run 'claude plugin list' for actual enabled state (known: ${hookPluginNames().join(', ')}).`);
    return 2;
  }
  console.error(`himmelctl: unknown config path: ${pathParts.join('.')}`);
  return 2;
}

function cmdConfigSet(pathParts, value, args) {
  if (value !== 'on' && value !== 'off') {
    console.error(`himmelctl: config set: value must be 'on' or 'off' (got '${value}')`);
    return 2;
  }
  const [ns, ...rest] = pathParts;
  if (ns === 'initiative' && rest.length === 1) return cmdConfigSetInitiative(rest[0], value, args);
  if (ns === 'lanes' && rest.length === 1) return cmdConfigSetLane(rest[0], value, args);
  if (ns === 'hooks' && rest.length >= 1) return cmdConfigSetHook(rest, value, args);
  console.error(`himmelctl: config set: unknown path '${pathParts.join('.')}'`);
  return 2;
}

// Interactive TUI — a THIN caller over the same setters `config set` uses
// (P1 pattern: readline is hard to test, so it carries as little logic as
// possible). Reuses makeAsk()/askEnum()/askPath() verbatim, same as
// askQuestions() above. Loops until the operator picks 'quit' (or blank ->
// default 'quit') at the top-level menu.
async function cmdConfigInteractive(args) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
  const ask = makeAsk(rl);
  // Track the highest failure across the session — a failed .env/lane/plugin
  // mutation must not let the interactive session still exit 0 once the
  // operator quits. The loop keeps running (a mid-session setter failure
  // shouldn't abort the whole TUI), but the process exit reflects it.
  let exitCode = 0;
  for (;;) {
    const category = await askEnum(
      ask,
      '? config: what would you like to configure? [initiative|lanes|hooks|quit] (default: quit)\n> ',
      ['initiative', 'lanes', 'hooks', 'quit'], 'quit',
    );
    if (category === 'quit') break;
    if (category === 'initiative') {
      const leg = await askEnum(ask, `? which leg? [${INITIATIVE_LEGS.join('|')}] (blank to cancel)\n> `, INITIATIVE_LEGS, '');
      if (!leg) continue;
      const onOff = await askEnum(ask, '? on or off? [on|off] (default: on)\n> ', ['on', 'off'], 'on');
      const rc = cmdConfigSetInitiative(leg, onOff, args);
      if (rc !== 0) exitCode = Math.max(exitCode, rc);
      continue;
    }
    if (category === 'lanes') {
      const known = knownLaneIds();
      const prompt = (Array.isArray(known) && known.length > 0)
        ? `? lane id [${known.join('|')}] (blank to cancel)\n> `
        : '? lane id (blank to cancel)\n> ';
      const laneId = await askPath(ask, prompt, '');
      if (!laneId) continue;
      const onOff = await askEnum(ask, '? on or off? [on|off] (default: on)\n> ', ['on', 'off'], 'on');
      const rc = cmdConfigSetLane(laneId, onOff, args);
      if (rc !== 0) exitCode = Math.max(exitCode, rc);
      continue;
    }
    if (category === 'hooks') {
      const target = await askPath(
        ask,
        `? hook target ('improveOnSubmit' or 'plugin.<name>'; known plugins: ${hookPluginNames().join(', ')}) (blank to cancel)\n> `,
        '',
      );
      if (!target) continue;
      const onOff = await askEnum(ask, '? on or off? [on|off] (default: on)\n> ', ['on', 'off'], 'on');
      const rc = cmdConfigSetHook(target.split('.'), onOff, args);
      if (rc !== 0) exitCode = Math.max(exitCode, rc);
      continue;
    }
  }
  rl.close();
  return exitCode;
}

// `himmelctl config [get <path> | set <path> <value>]` — no action -> the
// interactive TUI. Owns its own tiny argv scan (see main()'s dispatch
// comment for why): --dry-run is recognized ANYWHERE in argv, every other
// token is positional.
async function cmdConfig(argv) {
  const args = { dryRun: false };
  const positional = [];
  for (const a of argv) {
    if (a === '--dry-run') { args.dryRun = true; continue; }
    if (a.indexOf('--') === 0) {
      console.error(`himmelctl: config: unknown argument: ${a}`);
      return 2;
    }
    positional.push(a);
  }
  if (positional.length === 0) return await cmdConfigInteractive(args);
  const action = positional[0];
  if (action === 'get') {
    if (positional.length !== 2) {
      console.error('himmelctl: config get requires exactly one <path>');
      return 2;
    }
    return cmdConfigGet(positional[1].split('.'));
  }
  if (action === 'set') {
    if (positional.length !== 3) {
      console.error('himmelctl: config set requires exactly <path> <value>');
      return 2;
    }
    return cmdConfigSet(positional[1].split('.'), positional[2], args);
  }
  console.error(`himmelctl: config: unknown action '${action}' (expected 'get' or 'set')`);
  return 2;
}

// ── deps (HIMMEL-759, sub-ticket C of epic HIMMEL-755) ───────────────────
//
// `himmelctl deps status|ensure|upgrade` — a version-aware toolchain
// manager over scripts/install/deps.json, SEPARATE from the manifest's
// presence-only kind:"dep" items above (operator-locked design: different
// lifecycles — see deps.json's own header and deps-engine.js for the full
// rationale). Unlike install/status/ensure, deps has NO per-target state —
// deps.json is a flat declared set, so every verb here is state-free (no
// state.json read/write, no install-profile cache dependency). The heavy
// logic (per-OS recipe derivation, presence/version probing) lives in
// lib/deps-engine.js; this section only orchestrates + reports + owns the
// interactive confirm, mirroring how cmdEnsure delegates to
// install-engine.js/status-report.js and keeps only the prompting here.

function loadDeps() {
  return depsEngineLib.loadDeps(repoRoot());
}

// `deps status` — read-only. Probes every declared dep's presence + version,
// prints a red/degraded/green table (red first), and a one-line summary.
async function cmdDepsStatus(args) {
  const deps = loadDeps();
  const ctx = { repoRoot: repoRoot(), platform: process.platform };
  const results = deps.map((d) => depsEngineLib.depStatus(d, ctx));

  if (args.json) {
    process.stdout.write(JSON.stringify({ deps: results }) + '\n');
    return 0;
  }

  const groupOrder = { red: 0, degraded: 1, green: 2 };
  const printed = results.slice().sort((a, b) => {
    const byGroup = groupOrder[a.severity] - groupOrder[b.severity];
    return byGroup !== 0 ? byGroup : (a.id < b.id ? -1 : a.id > b.id ? 1 : 0);
  });
  for (const r of printed) console.log(`${r.severity}  ${r.id}  ${r.detail}`);
  const red = results.filter((r) => r.severity === 'red').length;
  const degraded = results.filter((r) => r.severity === 'degraded').length;
  const green = results.filter((r) => r.severity === 'green').length;
  console.log(`${red} red, ${degraded} degraded, ${green} green`);
  return 0;
}

// `deps ensure` — installs every MISSING (severity:red) declared dep via its
// per-OS recipe. --dry-run prints the plan without executing; otherwise one
// consolidated confirm (skipped by --yes), then dispatch through
// install-engine.js's already-hardened runInstall() (timeout, tree-kill,
// env-scrubbed spawn) — this function never spawns a mutating process
// itself, same separation cmdEnsure keeps above.
async function cmdDepsEnsure(args) {
  const deps = loadDeps();
  const ctx = { repoRoot: repoRoot(), platform: process.platform };
  const byId = new Map(deps.map((d) => [d.id, d]));
  const results = deps.map((d) => depsEngineLib.depStatus(d, ctx));
  const missing = results.filter((r) => r.severity === 'red');

  if (missing.length === 0) {
    console.log('himmelctl: nothing to converge — every declared dep is present.');
    return 0;
  }

  const plan = missing.map((r) => depsEngineLib.buildDepEntry(byId.get(r.id), ctx));

  if (args.dryRun) {
    for (const p of plan) {
      console.log(p.unrunnable ? `DRY: ${p.id}: ${p.unrunnable}` : `DRY: ${p.cmd} ${p.args.join(' ')}`);
    }
    return plan.some((p) => p.unrunnable) ? 1 : 0;
  }

  console.log(`himmelctl: about to install ${missing.length} dep(s): ${missing.map((r) => r.id).join(', ')}`);
  if (!args.yes) {
    if (!isInteractive(args)) {
      console.error('himmelctl: non-interactive deps ensure requires --yes');
      return 2;
    }
    const ans = await askConfirmSafe('Proceed? [Y/n] ');
    if (/^\s*n/i.test(ans)) {
      console.log('himmelctl: declined; nothing run.');
      return 0;
    }
  }

  const { ran, failed } = installEngineLib.runInstall(plan, { dryRun: false });

  // CR fix (CodeRabbit, MAJOR): an entry runInstall reports as "installed" is
  // NOT verified to actually be present afterward — a recipe can exit 0 yet
  // leave the tool off PATH (a no-op stub, a partial install, a recipe that
  // succeeds for an unrelated reason). Re-probe every reported-installed entry
  // with the SAME presence check `deps status` uses (depStatus), and move any
  // STILL absent (severity 'red') into the FAILED set with a clear reason
  // before reporting success — so `deps ensure` never claims success for an
  // install that didn't actually land. A present-but-degraded entry DID land
  // (the binary is there; only its version probe failed), so it stays in the
  // installed count; only a genuinely-still-absent entry fails out.
  const verified = [];
  for (const r of ran) {
    const dep = byId.get(r.id);
    const recheck = dep && depsEngineLib.depStatus(dep, ctx);
    if (!recheck || recheck.severity === 'red') {
      failed.push({ id: r.id, type: r.type, reason: 'installed but still not found on PATH' });
    } else {
      verified.push(r);
    }
  }

  for (const f of failed) console.error(`himmelctl: ${f.id}: ${f.reason}`);
  console.log(`himmelctl: deps ensure complete (${verified.length} installed, ${failed.length} failed).`);
  return failed.length > 0 ? 1 : 0;
}

// `deps upgrade` — re-runs every PRESENT declared dep's recipe in "upgrade"
// mode (bump toward latest; a floor-less dep, which is every dep today, has
// no other notion of "outdated" to converge toward). qmd's model pull
// (~2.1 GB — the SAME `qmd pull` primitive adopt.sh's wire_qmd_core already
// uses) is gated behind an explicit prompt (default decline, unlike every
// other confirm in this file — this one is opt-IN) or --with-models for
// non-interactive opt-in, mirroring adopt.sh's own size-caveat-first
// posture for the same download.
async function cmdDepsUpgrade(args) {
  const deps = loadDeps();
  const ctx = { repoRoot: repoRoot(), platform: process.platform };
  const byId = new Map(deps.map((d) => [d.id, d]));
  const results = deps.map((d) => depsEngineLib.depStatus(d, ctx));
  const present = results.filter((r) => r.severity !== 'red');
  let hadFailure = false;

  if (present.length === 0) {
    console.log('himmelctl: nothing to upgrade — no declared deps are present.');
  } else {
    const plan = present.map((r) => depsEngineLib.buildDepEntry(byId.get(r.id), ctx, { upgrade: true }));

    if (args.dryRun) {
      for (const p of plan) {
        console.log(p.unrunnable ? `DRY: ${p.id}: ${p.unrunnable}` : `DRY: ${p.cmd} ${p.args.join(' ')}`);
      }
      if (plan.some((p) => p.unrunnable)) hadFailure = true;
    } else {
      console.log(`himmelctl: about to upgrade ${present.length} dep(s): ${present.map((r) => r.id).join(', ')}`);
      if (!args.yes) {
        if (!isInteractive(args)) {
          console.error('himmelctl: non-interactive deps upgrade requires --yes');
          return 2;
        }
        const ans = await askConfirmSafe('Proceed? [Y/n] ');
        if (/^\s*n/i.test(ans)) {
          console.log('himmelctl: declined; nothing run.');
          return 0;
        }
      }
      const { ran, failed } = installEngineLib.runInstall(plan, { dryRun: false });
      for (const f of failed) console.error(`himmelctl: ${f.id}: ${f.reason}`);
      console.log(`himmelctl: deps upgrade complete (${ran.length} upgraded, ${failed.length} failed).`);
      if (failed.length > 0) hadFailure = true;
    }
  }

  // qmd model pull — gated separately from the main upgrade plan above (it
  // is not "converging toward outdated", it's a large opt-in download).
  // Only offered when qmd is actually declared AND present (post-upgrade) —
  // an absent qmd has nothing to pull models FOR.
  if (byId.has('qmd')) {
    const qmdNowPresent = args.dryRun
      ? present.some((r) => r.id === 'qmd')
      : depsEngineLib.depStatus(byId.get('qmd'), ctx).present;
    if (qmdNowPresent) {
      let pullModels = args.withModels;
      if (!args.withModels) {
        if (args.dryRun) {
          console.log('DRY: prompt to pull qmd embedding/rerank models (~2.1 GB) — pass --with-models to opt in non-interactively');
        } else if (!isInteractive(args)) {
          console.log('himmelctl: skipping qmd model pull (non-interactive; pass --with-models to opt in)');
        } else {
          const ans = await askConfirmSafe('Pull qmd embedding/rerank models now? (~2.1 GB download) [y/N] ');
          pullModels = /^\s*y/i.test(ans);
        }
      }
      if (pullModels && !args.dryRun) {
        const entry = depsEngineLib.qmdPullModelsEntry(byId.get('qmd'), ctx);
        const result = installEngineLib.runInstall([entry], { dryRun: false });
        if (result.failed.length > 0) {
          console.error(`himmelctl: qmd model pull failed: ${result.failed[0].reason}`);
          return 1;
        }
      } else if (pullModels && args.dryRun) {
        console.log('DRY: qmd pull (downloads ~2.1 GB of embedding/rerank models)');
      }
    }
  }

  return hadFailure ? 1 : 0;
}

async function cmdDeps(args) {
  if (args.depsVerb === 'status') return cmdDepsStatus(args);
  if (args.depsVerb === 'ensure') return cmdDepsEnsure(args);
  return cmdDepsUpgrade(args);
}

async function main() {
  const argv = process.argv.slice(2);
  // --help / -h (anywhere) or no args → usage banner, exit 0.
  if (argv.length === 0 || argv.indexOf('-h') !== -1 || argv.indexOf('--help') !== -1) {
    console.log(USAGE);
    return 0;
  }
  // --version (anywhere) → `himmel <semver>`, exit 0. Special-cased here for
  // the same reason -h/--help is: parseArgs below only understands the shared
  // flag grammar, and this must answer before any subcommand dispatch.
  //
  // HIMMEL-1599: himmel had no version, so no measurement we take — gate
  // false-positive rates, dispatch-completion rates, suite timings — could be
  // attributed to a build. Reads VERSION rather than embedding a constant, so
  // there is exactly one place to bump.
  //
  // NEVER throws: an unreadable or absent VERSION prints `himmel unknown` and
  // still exits 0. `--version` failing loudly would make a diagnostic command
  // the thing that breaks the diagnosis.
  if (argv.indexOf('--version') !== -1) {
    let version = 'unknown';
    try {
      version = fs.readFileSync(path.join(repoRoot(), 'VERSION'), 'utf8').trim() || 'unknown';
    } catch {
      // fall through to 'unknown'
    }
    console.log(`himmel ${version}`);
    return 0;
  }
  // `config` owns its OWN positional grammar (get/set <path> [<value>]) that
  // the shared flag-only parseArgs()/ALLOWED_OPTIONS machinery below has no
  // notion of (every other subcommand takes flags only) — special-cased here
  // the same way -h/--help already is, before parseArgs ever sees it.
  // A leading global flag may precede `config` — e.g. `himmelctl --dry-run
  // config set …` — matching the order-independent flags every other
  // subcommand accepts. `--dry-run` is the ONLY global flag `config` honors
  // (cmdConfig rejects any other `--flag`), and it is arity-0, so we skip only
  // leading `--dry-run` tokens before checking for `config`. We deliberately do
  // NOT skip value-taking flags (--items/--profile/--from-profile): those
  // belong to other subcommands and their VALUE must never be mistaken for the
  // config subcommand — e.g. `himmelctl --items config status` is
  // `status --items=config`, not config. Only the config token itself is
  // dropped; a later `config` used as a path/value is preserved. cmdConfig
  // already recognizes --dry-run anywhere in the args it receives.
  let ci = 0;
  while (argv[ci] === '--dry-run') ci++;
  if (argv[ci] === 'config') {
    return await cmdConfig(argv.slice(0, ci).concat(argv.slice(ci + 1)));
  }
  const args = parseArgs(argv);
  // CR fix: parseArgs signals a fatal validation error (e.g. a bad
  // --profile value) by setting process.exitCode itself and returning
  // early, rather than calling process.exit() synchronously. Returning
  // undefined here (a non-number) tells the top-level .then() below to
  // NOT force an exit code of its own — the process exits naturally with
  // whatever parseArgs already set, once buffered diagnostics flush.
  if (typeof process.exitCode === 'number') return undefined;
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
  if (args.subcommand === 'update') {
    return await cmdUpdate(args);
  }
  if (args.subcommand === 'status') {
    return await cmdStatus(args);
  }
  if (args.subcommand === 'ensure') {
    return await cmdEnsure(args);
  }
  if (args.subcommand === 'scope') {
    return await cmdScope(args);
  }
  if (args.subcommand === 'trust') {
    return await cmdTrust(args);
  }
  if (args.subcommand === 'deps') {
    return await cmdDeps(args);
  }
  // parseArgs already rejected unknown subcommands, so this is unreachable.
  console.error(`himmelctl: unknown command: ${args.subcommand}`);
  return 2;
}

main()
  // CR fix: ASSIGN process.exitCode rather than calling process.exit(code) —
  // process.exit() can truncate buffered stdout (notably a piped `--json`
  // payload) before it flushes. Setting exitCode and letting the process
  // terminate naturally once the event loop drains preserves the exit code
  // AND the full output. A non-number result (main()'s early-return) means
  // process.exitCode was already set upstream (by parseArgs) — leave it.
  .then((code) => {
    if (typeof code === 'number') process.exitCode = code;
  })
  .catch((err) => {
    console.error(`himmelctl: ${err && err.message ? err.message : err}`);
    process.exit(1);
  });
