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
//   node scripts/himmelctl/bin.js install [--dry-run] [--from-profile <path>]
//   node scripts/himmelctl/bin.js uninstall [--dry-run]
//   node scripts/himmelctl/bin.js update [--dry-run]
//   node scripts/himmelctl/bin.js status [--items <a,b>] [--json]

const fs = require('fs');
const os = require('os');
const path = require('path');
const readline = require('readline');
const { spawnSync } = require('child_process');
const { cacheDir, profileForVault, which, resolvePowershell } = require('./lib/helpers.js');
const stateLib = require('./lib/state.js');
const statusReportLib = require('./lib/status-report.js');
const installEngineLib = require('./lib/install-engine.js');
const probesLib = require('./lib/probes.js');
const depsEngineLib = require('./lib/deps-engine.js');
const adopterProfileLib = require('./lib/adopter-profile.js');
const contributorProfileLib = require('./lib/contributor-profile.js');
// HIMMEL-2176 Stage-1 PR-C Task 8: luna cadence / secrets walk / bridge
// sections. bridge-persistence.js ships primitives only (never called at
// require-time); luna-config.js owns the adopter's shared config document;
// cadence-emit.js is the pure config->CLI-flag mapping for pipeline-cadence.sh.
const lunaConfigLib = require('./lib/luna-config.js');
const bridgePersistenceLib = require('./lib/bridge-persistence.js');
const cadenceEmitLib = require('./lib/cadence-emit.js');
const SECRETS_MANIFEST = require('./lib/secrets-manifest.json');
// HIMMEL-2302: per-cadence wizard registry (pipeline/qmd/graphmap/codex-sweep
// — see the file's own $comment for why ggs-cadence.sh is excluded). The
// wizard enumerates cadence UNITS from here, never a hardcoded list.
const CADENCE_REGISTRY = require('./lib/cadence-registry.json').cadences;

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
                          installs/wires whatever status reports red/degraded.
                          By default this is CONVERGE-ONLY (HIMMEL-2349) —
                          unwiring/disabling a removable item that's no longer
                          desired is a separate, higher-risk consent gated
                          behind --prune (never bundled into the same Y/n as a
                          converge); run from the same location the
                          corresponding install was run from, same as status
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
  gaps                    read-only report: what does THIS setup not get from
                          the reference machine? Diffs the saved install
                          profile against a reference profile (default
                          docs/setup/profiles/operator.install-profile.json)
                          and prints four groups — answered off/none (your
                          own choice, not a gap), not recorded (predates this
                          question, not a choice), reference-only (no wizard
                          question can produce it yet, ticketed), and present
                          but unverified (recorded, but gaps is a static diff
                          not a live probe — run 'himmelctl status' to
                          confirm). A REPORT, not a gate: exits 0 whenever the
                          report was produced, even when gaps exist.

options:
  --from-profile <path>  install: run non-interactively from a saved profile cache;
                          gaps: read the profile from here instead of the cache
  --default-scope <s>    install question default: project|user (answer remains confirmable)
  --contribute           install: layer the contributor-dev setup.sh/setup.ps1
                          primitive on top of the install (pre-commit gates,
                          .himmel-dev marker, doc-guard wiring, Jira/Bitbucket CLI
                          builds, shell-test toolchain probes). Never a question —
                          set only via this flag. Requires a himmel checkout.
  --lanes <csv>          install: v1 (HIMMEL-2352, ruling 34) accepts only 'none'
                          here — Claude tiers are the only implementation lanes;
                          codex/hermes are CR-only and reachable ONLY via
                          --with-codex/--with-hermes or the interactive prompt,
                          never this flag (one door, not two). 'none' skips the
                          lanes question and selects nothing.
  --with-codex           install: additionally select the codex lane (opt-in)
  --with-hermes          install: additionally select the hermes lane (opt-in)
                          Selecting a lane records the choice, probes it, and on an
                          applied install persists a resolver allowlist.
                          Selected lanes still have to pass their real probes; the
                          allowlist only suppresses non-selected optional lanes.
                          It does NOT install a lane CLI or force a lane present.
  --dry-run              print the derived plan/actions without executing
  --items <a,b>          status/ensure: scope the run to these item ids (comma list)
  --json                 status/deps status/gaps: emit stable machine-readable JSON instead of text
  --profile <p>          ensure: reconcile the target to this profile first (core|luna|all)
  --preset <name>        gaps: compare against docs/setup/profiles/<name>.install-profile.json
                          instead of the default 'operator' reference (same
                          name-safety rules as a saved profile name)
  --yes                  ensure/deps ensure/deps upgrade: skip the confirmation
  --prune                ensure: opt-in to the DISABLE phase (converge-only by
                          default; disabling enabled-but-no-longer-desired items
                          is a separate, higher-risk consent — HIMMEL-2349)
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
  install: ['fromProfile', 'defaultScope', 'contribute', 'dryRun', 'lanes', 'withCodex', 'withHermes'],
  uninstall: ['dryRun'],
  update: ['dryRun'],
  status: ['items', 'json'],
  ensure: ['items', 'profile', 'yes', 'dryRun', 'prune'],
  // `scope` takes its OWN positional verbs/targets (set|get|status, then
  // project|user for set) — parsed in parseArgs's scope cases, not as --flags.
  // --yes/--dry-run apply to `scope set` (get/status are pure reads that
  // ignore them); the option-validation pass keys on the subcommand only, so
  // both are admitted here and cmdScope ignores them on the read verbs.
  scope: ['yes', 'dryRun'],
  // HIMMEL-2348 deliverable 2: gaps owns its OWN grammar (--from-profile
  // reused generically, --preset new, --json reused generically) — a fresh
  // subcommand, never a `status` mode (see the function's own header
  // comment for why: status's flags are a shipped, golden-tested contract).
  gaps: ['fromProfile', 'preset', 'json'],
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
  fromProfile: '--from-profile', defaultScope: '--default-scope', contribute: '--contribute', dryRun: '--dry-run',
  items: '--items', json: '--json', profile: '--profile', yes: '--yes',
  withModels: '--with-models',
  lanes: '--lanes', withCodex: '--with-codex', withHermes: '--with-hermes',
  prune: '--prune',
  preset: '--preset',
};
const OPTION_DEFAULTS = {
  fromProfile: null, defaultScope: null, contribute: false, dryRun: false, items: null, json: false, profile: null, yes: false,
  withModels: false,
  lanes: null, withCodex: false, withHermes: false,
  prune: false,
  preset: null,
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
    contribute: false, // install: layer the dev overlay (HIMMEL-2308, --contribute)
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
    prune: false,      // ensure: --prune (opt-in — disable/unwire candidates require this; HIMMEL-2349)
    preset: null,      // gaps: --preset <name> (null = default 'operator' reference)
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
      case 'gaps':
        if (!setSubcommand('gaps')) return args;
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
      case '--contribute':
        args.contribute = true;
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
      case '--prune':
        args.prune = true;
        break;
      case '--preset':
        args.preset = argv[++i];
        if (args.preset === undefined) {
          console.error('himmelctl: --preset requires a name (resolves to docs/setup/profiles/<name>.install-profile.json)');
          process.exitCode = 2;
          return args;
        }
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
      // HIMMEL-2308: a saved profile already carries its own devOverlay
      // (schemaVersion 2) or migrated role (legacy) — same refusal-not-
      // precedence posture as the lane flags above.
      if (args.contribute !== OPTION_DEFAULTS.contribute) {
        console.error(`himmelctl: ${OPTION_FLAGS.contribute} cannot be combined with --from-profile`);
        console.error('  (the profile already carries its devOverlay answer — edit the profile, or drop --from-profile)');
        process.exitCode = 2;
        return args;
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
// After the preflight gate passes we walk the operator through the profile
// model (HIMMEL-2308): the OLD role fork (adopter|contributor, detected from
// the git origin + a .himmel-dev marker) is gone entirely — every install now
// answers the SAME question set. Two orthogonal axes replace it:
//   - profile     starter|luna|operator|custom (default starter) — SEEDS the
//                 defaults below; every question is still asked regardless of
//                 which preset is picked (see PROFILE_PRESETS).
//   - devOverlay  set ONLY via the --contribute CLI flag, never a question —
//                 layers the contributor-dev setup.sh primitive on top of
//                 whichever profile answers the operator gave (see
//                 deriveOverlayCommand()/runPlan()).
// raw `readline` only — zero npm deps. Question order:
//   1. profile     starter|luna|operator|custom
//   2. scope       project|user
//   3. vault       none|default-template|existing (+path for the last two)
//   4. handover    inline|external (+path for external)
//   5. pluginSet   lean (HIMMEL-2304: 'full' dropped, see askQuestions() below)
//   6. lanes       the HIMMEL-862 delegation-lane subset
//   7. alwaysOn    unattended/scheduled-run hardening
// 8-11 (luna cadence, PHI, secrets walk, bridge) are gated on vault!=none —
// unchanged from before, just no longer role-gated on top of that.

// Preset seeding (HIMMEL-2308): a profile answer only changes the DEFAULT
// value offered at each question below — it never skips a question. 'custom'
// keeps today's plain defaults (vault=none, handover=inline, alwaysOn=no,
// cadence=off, bridge=off); 'luna' seeds a vault so the second-brain
// questions (cadence/PHI/secretsWalk/bridge, already gated on vault!=none)
// come up unprompted; 'operator' seeds the richest defaults (an existing
// vault, external handover, always-on hardening, cadence + bridge on) without
// skipping a single has-it-or-not question — the operator still confirms (or
// declines) every one of them.
// HIMMEL-2302: `cadence: 'off'|'on'` (the old binary question's seed) is
// replaced by `cadenceIds` — the set of cadence-registry ids PRE-SELECTED
// when the per-cadence question's menu first prints (Enter accepts exactly
// this set). Only 'operator' seeds anything (pipeline+qmd+graphmap, matching
// the richest-defaults posture the other preset fields already carry);
// starter/luna/custom seed none, same as today's cadence:'off' default for
// every profile but operator. codex-sweep is never preset-seeded — it needs
// the codex lane too, and decision text (HIMMEL-2302) explicitly holds it out
// of even the operator seed.
// HIMMEL-2346: `whisperModel` seeds the whisper-model question below (bare
// filename, per the BARE FILENAME contract documented at whisperDirPath()'s
// neighbor comment ~L1930). Only `operator` diverges from the schema default
// ('ggml-small.bin', same as lunaConfigLib's defaultConfig()) — the HIMMEL-2307
// capture proved the maintainer machine actually runs large-v3-turbo, so the
// operator preset seeds that instead of silently falling through to small.
const PROFILE_PRESETS = {
  starter: { vaultMode: 'none', handoverMode: 'inline', alwaysOn: 'no', cadenceIds: [], bridge: 'off', whisperModel: 'ggml-small.bin' },
  luna: { vaultMode: 'default-template', handoverMode: 'inline', alwaysOn: 'no', cadenceIds: [], bridge: 'off', whisperModel: 'ggml-small.bin' },
  operator: { vaultMode: 'existing', handoverMode: 'external', alwaysOn: 'yes', cadenceIds: ['pipeline', 'qmd', 'graphmap'], bridge: 'on', whisperModel: 'ggml-large-v3-turbo.bin' },
  custom: { vaultMode: 'none', handoverMode: 'inline', alwaysOn: 'no', cadenceIds: [], bridge: 'off', whisperModel: 'ggml-small.bin' },
};

// Per-option help text for every numbered-enum question in the wizard
// (HIMMEL-2308 P3: generalized from the profile-only PROFILE_HELP that
// shipped in HIMMEL-2308 part A — see askNumberedEnum's helpMap param). One
// factual line per option, verified against what the code right below
// actually does — never a claim the implementation doesn't back.
const PROFILE_HELP = {
  starter: 'core harness: hooks, guardrails, worktrees, statusline, jira CLI',
  luna: 'starter + the second-brain surface, nothing else (vault/qmd/cadences/PHI/secrets/bridge questions)',
  operator: 'the maintainer machine as a consumable profile (seeds defaults ONLY; lanes and every has-it-or-not feature are still asked, each lane line saying what it needs, e.g. "codex — requires the codex CLI + its own login; skip if you don\'t have it")',
  custom: 'walk every question from scratch, no seeding',
};

const SCOPE_HELP = {
  project: "this install's config lives inside this repo's own .claude/ — wire it again separately for another project",
  user: "this install's config lives at ~/.claude/ — applies once, to every project you open",
};

const VAULT_HELP = {
  none: 'no second brain on this machine; every vault question below is skipped',
  'default-template': 'scaffold a fresh vault from templates/luna-second-brain',
  existing: 'point at the Obsidian vault you already have (in-place, STAMPED-gated upgrade)',
};

const HANDOVER_HELP = {
  inline: "no-op — handover state stays in this repo's own handovers/ (adopt.sh/setup.sh default)",
  external: 'persists HANDOVER_DIR to an external state repo you point at next',
};

const PLUGIN_SET_HELP = {
  lean: 'the only supported set — the reconciler wires only what himmel actually runs (HIMMEL-2292)',
};

const ALWAYS_ON_HELP = {
  yes: 'print the unattended/scheduled-run hardening checklist (nothing is executed either way)',
  no: 'print a one-line pointer to the checklist instead',
};

const SECRETS_WALK_HELP = {
  run: 'walk each luna secret with an instruction card + probe (himmelctl never harvests the value)',
  skip: 'skip the walk-through',
};

const BRIDGE_HELP = {
  off: 'no telegram bridge configured',
  on: 'configure telegram voice/text ingestion (.env path, whisper CLI/model, optional persistence)',
};

// HIMMEL-2346: the whisper-model question used to be free text with a default
// nobody could evaluate without asking someone "what is the big one?" — this
// maps the standard whisper.cpp ggml model names (askNumberedEnum's opts) to
// the bare filename actually stored (whisperDirPath()'s BARE FILENAME
// contract, ~L1930) plus per-option size/tradeoff help, same convention as
// PROFILE_HELP. 'custom' is the escape hatch for any other filename — the
// field genuinely accepts arbitrary values (a fine-tuned/quantized build, a
// filename typo'd on purpose to match an existing local file, etc.) — handled
// the same way vaultMode==='existing'/handoverMode==='external' trigger a
// follow-up free-text ask() below, not a new free-text branch inside
// askNumberedEnum() itself.
const WHISPER_MODEL_FILENAMES = {
  tiny: 'ggml-tiny.bin',
  base: 'ggml-base.bin',
  small: 'ggml-small.bin',
  medium: 'ggml-medium.bin',
  'large-v3': 'ggml-large-v3.bin',
  'large-v3-turbo': 'ggml-large-v3-turbo.bin',
};

const WHISPER_MODEL_HELP = {
  tiny: '~75MB — fastest, least accurate',
  base: '~142MB — fast, low accuracy',
  small: '~466MB — current default, balanced speed/accuracy',
  medium: '~1.5GB — slower, better accuracy',
  'large-v3': '~3.1GB — best accuracy, slowest',
  'large-v3-turbo': '~1.6GB — near-large-v3 accuracy at much higher speed',
  custom: 'enter any other ggml model filename',
};

// Reverse-lookup a bare whisper-model filename to its WHISPER_MODEL_FILENAMES
// key, for marking the right menu entry as the recommended default; a
// filename that doesn't match one of the standard models (e.g. an existing
// custom answer) falls back to 'custom' rather than throwing.
function whisperModelKeyFor(filename) {
  for (const key of Object.keys(WHISPER_MODEL_FILENAMES)) {
    if (WHISPER_MODEL_FILENAMES[key] === filename) return key;
  }
  return 'custom';
}

// Serialize the answer object to a stable string (2-space indent, insertion-
// order keys). Used for BOTH the cache write (T3) and the T4 stdout summary so
// a saved cache round-trips byte-for-byte through --from-profile.
function serialize(answers) {
  return JSON.stringify(answers, null, 2);
}

// Build the Draft-A v2 answer object (HIMMEL-2308).
// HIMMEL-2348: `tier` is GONE. It was written here as the constant
// 'standard' and read by nothing — not loadProfile (which validates a named
// allowlist and never looked at it), not status/ensure, not the capture
// script, not the status report — and the committed exemplar
// docs/setup/profiles/operator.install-profile.json never carried it, so the
// canonical profile already disagreed with every wizard write. Validating it
// instead would have enshrined an unread field AND made every tier-less
// profile (that exemplar included) start failing a strict check, so the only
// safe validation would have been optional-when-present: a check that
// verifies nothing while making the field harder to remove. Dropping it is
// backward-compatible in both directions — loadProfile ignores unknown keys,
// so an existing cache carrying `tier` still loads, and serialize() is a
// plain JSON.stringify of whatever object it is given, so such a profile
// still round-trips byte-stably through --from-profile.
// `role` DIES in v2 writes — `profile`/`devOverlay` replace it as
// the two orthogonal axes (see the T2 comment above); loadProfile() migrates
// an old v1 `role` field on READ, but nothing ever writes it again.
// `lanes`/`alwaysOn` are asked UNIVERSALLY now (HIMMEL-2308 killed the old
// adopter-only gating), so in practice they are always defined for a fresh
// v2 write; the `undefined`-passthrough below stays only so a caller that
// legitimately never asks them (there is none left in askQuestions()/
// defaultAnswers(), but the shape is still honored defensively) round-trips
// as genuinely absent rather than a fabricated answer.
// Key ORDER is load-bearing: serialize() is the cache format AND the printed
// summary, and both must round-trip byte-for-byte through --from-profile.
//
// RETASK stage1-build-6d2e round 8 [codex-1] CRITICAL, ROOT CAUSE: `luna`/
// `secretsWalk`/`bridge` (HIMMEL-2176 Task 8) used to fall back to an "off"
// DEFAULT OBJECT here whenever the caller passed undefined — which made
// "the operator was never asked" indistinguishable from "the operator
// answered off", because BOTH produced a real, present, answer-shaped key
// in the serialized profile. `lunaSectionSupplied()`/`bridgeSectionSupplied()`
// (applyLunaSectionsStep's own "was this section actually supplied" gate,
// added in round 1 for the --from-profile legacy-cache case) then read that
// manufactured key as genuine consent and overwrote an existing config with
// cadence off / PHI cleared / bridge disabled — for EVERY caller that
// legitimately never asks (vaultMode=='none' in askQuestions,
// defaultAnswers()'s --dry-run preview). Passing the raw value straight
// through — never defaulting it here — makes "not asked" and "answered off"
// structurally distinguishable exactly once, at the one place both meanings
// used to collapse: JSON.stringify (serialize(), the cache write, AND the
// printed profile) drops an `undefined`-valued key entirely, so a
// never-asked section now round-trips as GENUINELY ABSENT — the identical
// shape loadProfile() already treats as "not supplied" for a legacy cache.
// Every downstream reader (applyLunaSectionsStep, previewLunaSections,
// buildSummary) already defends with `answers.luna || {}` from the round-1/3
// legacy-profile work, so this is safe with zero other call-site changes.
function buildAnswers(profile, devOverlay, scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet, lanes, alwaysOn, luna, secretsWalk, bridge, cadences) {
  return {
    schemaVersion: 2,
    profile: profile,
    devOverlay: Boolean(devOverlay),
    scope: scope,
    vault: { mode: vaultMode, path: vaultPath },
    handover: { mode: handoverMode, path: handoverPath },
    pluginSet: pluginSet,
    lanes: lanes || [],
    // HIMMEL-2300: meaningful only when the lanes question actually ran —
    // `lanes` stays undefined (never []) for a flow that never asks it, so
    // this mirrors that instead of hardcoding true. JSON.stringify drops an
    // undefined-valued key, matching the round-8 luna/secretsWalk/bridge
    // not-asked shape.
    lanesMeaningful: lanes !== undefined ? true : undefined,
    // HIMMEL-2300: pass the raw value through — never Boolean()-coerce — so a
    // flow that never asks alwaysOn round-trips as genuinely absent instead
    // of a fabricated `false`. Same fix class as buildAnswers()'s existing
    // luna/secretsWalk/bridge comment above.
    alwaysOn: alwaysOn,
    luna: luna,
    secretsWalk: secretsWalk,
    bridge: bridge,
    // HIMMEL-2302: `cadences` is a TOP-LEVEL optional section, same pattern
    // as luna/secretsWalk/bridge (not nested under `luna`) — a flow that
    // never asks it (vault=none) round-trips as genuinely absent, never a
    // fabricated {}.
    cadences: cadences,
  };
}

// Canonical "off" bridge-section default — used when the bridge question WAS
// asked (vaultMode!=='none') and the operator declined it, and as the
// prompt-default template for the bridge sub-questions. (round 8: the luna-
// section twin of this, defaultLunaSectionAnswer(), was deleted — it had no
// callers left once buildAnswers()/askQuestions() stopped manufacturing an
// "off" answer for a section nobody was asked about; see buildAnswers()'s
// own comment.) Sourced from luna-config.js's own defaultConfig() for the
// envPath/model strings so this file carries no second copy of those
// literals.
function defaultBridgeSectionAnswer() {
  const d = lunaConfigLib.defaultConfig();
  return {
    enabled: false,
    envPath: d.bridge.envPath,
    whisperCli: d.bridge.whisper.cli || '',
    whisperModel: d.bridge.whisper.model,
    installPersistence: false,
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

// Ask one enum question, re-prompting (same header marker) until the answer
// is empty (accept default) or a member of opts. LITERAL-ONLY — no numeric
// index acceptance. Used by the CONSENT/PHI prompts (PHI declaration, the two
// "consented, --dry-run shows it" mutation prompts) and the unrelated
// `config` TUI, both of which keep their plain, un-numbered wording.
async function askEnum(ask, prompt, opts, defaultVal) {
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    if (t === '') return defaultVal;
    if (opts.indexOf(t) !== -1) return t;
    // invalid — loop re-emits the prompt header so the re-prompt is visible
  }
}

// HIMMEL-2288: ask a NUMBERED enum question — options printed 1..n, the
// recommended default clearly marked, Enter accepts it; the operator may
// answer with the number OR the literal option word. Scoped to the install
// wizard's own enum questions (profile, scope, vault, handover, pluginSet,
// luna cadence, secrets walk, bridge on/off, always-on).
//
// CR round 1 [codex-1]: this numeric acceptance used to live in askEnum()
// itself (shared with every caller), which meant it ALSO covered the
// CONSENT/PHI prompts below — a bare "1"/"2" silently satisfied a
// PHI-declaration or machine-mutation consent that was explicitly supposed
// to require typed yes/no wording, never a bare-number accept. Splitting
// numeric acceptance into this SEPARATE function — used only by the
// non-consent questions above — closes that hole: askEnum() itself is
// literal-only again, so the three consent/PHI call sites (which still call
// askEnum() directly, unchanged) can never be satisfied by a digit.
//
// `helpMap` (HIMMEL-2308 P3): optional { option: 'one-line help' } — when
// given, every menu line gets an " — <help>" suffix, same convention
// askProfile() pioneered (PROFILE_HELP) and now generalized here so every
// enum question in the wizard can carry per-option help without a
// per-question copy of the menu-building loop.
async function askNumberedEnum(ask, title, opts, defaultVal, helpMap) {
  const menu = opts.map((o, i) => `  ${i + 1}) ${o}${o === defaultVal ? ' (recommended — press Enter)' : ''}${helpMap && helpMap[o] ? ` — ${helpMap[o]}` : ''}`).join('\n');
  const prompt = `? ${title} [${opts.join('|')}] (default: ${defaultVal})\n${menu}\n> `;
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    if (t === '') return defaultVal;
    if (opts.indexOf(t) !== -1) return t;
    if (/^[0-9]+$/.test(t)) {
      const idx = Number(t) - 1;
      if (idx >= 0 && idx < opts.length) return opts[idx];
    }
    // invalid — loop re-emits the prompt header so the re-prompt is visible
  }
}

// Ask one free-form path; empty answer accepts the default.
async function askPath(ask, prompt, defaultVal) {
  const ans = await ask(prompt);
  const t = (ans || '').trim();
  return t === '' ? defaultVal : t;
}

// HIMMEL-2347 CR fix 1: the ONE predicate for "is this a usable
// luna.phiVaultPath" — non-blank and absolute (or '~'-prefixed; expandHome()
// resolves '~' later). A previous round enforced this ONLY inside
// loadProfile()'s validator (the --from-profile path); the interactive
// askPath() call in askQuestions() below had no such check, so an operator
// typing a relative path interactively reproduced the exact bug that round
// fixed — a relative phi-roots entry never matches the guards' absolute-path
// comparison (silently inert, the HIMMEL-1773 class) and path.join() places
// .salus relative to the installer's cwd. Factored out so the interactive
// site and loadProfile() share one rule and can never drift apart again.
// HIMMEL-2424: name the first byte in `v` that would corrupt phi-roots'
// line-delimited storage, or null if none. mergePhiRoot() writes one path
// per LINE, but the two things that later read phi-roots back disagree
// about what a mid-line CR does to that: the PHI guards (graph-refresh.sh's
// _under_any_list) use `while IFS= read -r root`, which splits ONLY on LF
// and then strips a TRAILING \r off the line it read, so an embedded CR
// survives inside one guard entry, corrupted but not split. mergePhiRoot()
// itself, though, re-reads the file with split(/\r\n|\r|\n/) -- a bare CR
// IS a separator there -- and writes every line back joined with \n, so the
// very next declaration turns that one corrupted entry into two real
// LF-separated lines, which the guards then do see as two bogus roots. An
// embedded LF has no such ambiguity: both readers split on it immediately.
// NUL is included for a different reason again (it terminates a C string in
// consumers that read phi-roots via a NUL-terminated API) and because it is
// never valid in a path on either platform regardless of this file format —
// not a broader control-character sanitizer, just the two bytes that break
// line-delimited storage (one now, one on the next merge) plus that one
// universally-invalid sibling. Returns a readable name rather than the byte
// itself so callers can build a message without echoing a raw control
// character into the terminal.
//
// HIMMEL-2424 CR: the REASON travels with the name, per byte, because the
// three bytes above do not share one true clause. LF genuinely does split
// phi-roots' line-delimited storage immediately -- that clause stays LF's
// own. CR does NOT: per the mechanism above it corrupts the stored path now
// and only splits it on the NEXT mergePhiRoot() run, so it earns its own
// clause that says exactly that, not LF's "would split" claim. NUL starts
// no new line at all, so its clause was already the odd one out. Collapsing
// these back into one shared string is the over-claiming bug this ticket
// exists to correct, so each reason lives here next to the byte that earns
// it rather than at the call sites, where copies would drift.
//
// HIMMEL-2424 CR round 4: the CHECK ORDER below is LF, then CR, then NUL --
// and that order is load-bearing, not incidental. A value can contain more
// than one of these bytes (a path pasted with mixed line endings, say), and
// whichever check runs first decides which {name, reason} the operator
// sees for the WHOLE value. Testing CR before LF (the previous order) meant
// any value containing both always reported CR's reason -- "corrupts the
// stored path, and the next phi-roots merge splits it" -- even when that
// same value's LF splits phi-roots' storage immediately, on this very
// declaration, regardless of where the CR sits or whether it's even before
// or after the LF. That under-claims the damage: the operator is told a
// delayed-split story about a value that has already earned an
// immediate-split one. LF-first fixes this because LF's claim ("would
// split phi-roots' line-delimited storage") stays TRUE of the value
// whenever an LF is present anywhere in it, no matter what else the value
// also contains -- so checking LF first can never hand back a reason that
// undersells the value's actual effect on the file. CR's own reason, by
// contrast, is only accurate for a value that has a CR and NO LF (a
// CR-only value is unaffected by this reordering and still gets CR's
// delayed-split reason, correctly). NUL stays last either way: it starts
// no new line at all, so its clause never competes with LF's or CR's.
function phiVaultPathBadByte(v) {
  if (v.indexOf('\n') !== -1) return { name: 'a line feed (LF)', reason: "would split phi-roots' line-delimited storage into a bogus extra entry" };
  if (v.indexOf('\r') !== -1) return { name: 'a carriage return (CR)', reason: 'corrupts the stored path, and the next phi-roots merge splits it into a bogus extra entry' };
  if (v.indexOf('\0') !== -1) return { name: 'a NUL byte', reason: 'is never valid in a path and truncates it in any consumer that reads through a NUL-terminated API' };
  return null;
}

function isValidPhiVaultPathAnswer(v) {
  return typeof v === 'string' && v.trim() !== '' && phiVaultPathBadByte(v) === null && (v.charAt(0) === '~' || path.isAbsolute(v));
}

// HIMMEL-862/2308/2352: ask the lane subset. Free-form CSV (not askEnum — the
// answer is a SET, not one value), re-prompting on an invalid id the same way
// askEnum re-emits its header. Empty accepts the default; 'none' selects
// nothing.
//
// HIMMEL-2352 (ruling 34): ALL_LANE_IDS is codex/hermes ONLY in v1 — ollama
// and copilot were dropped from V1_LANES entirely (they never appear in this
// menu, and the wizard never probes them; see adopter-profile.js's own
// comment on that table). The menu therefore reads exactly "codex | hermes |
// none", default none, each option's LANE_HELP line framed as a cross-model
// CR (code-review) lane, not an implementation lane. Selecting one AT THIS
// PROMPT is itself the explicit consent --with-codex/--with-hermes provides
// on the command line (see parseLaneList's own comment) — passed through via
// { allowOptIn: true } below. The --lanes CSV flag is a SEPARATE call site
// (parseArgs) that never sets that option, so it still refuses codex/hermes
// exactly as it did pre-2352 — this menu is the only place that changed.
async function askLanes(ask, defaultLanes) {
  const ids = adopterProfileLib.ALL_LANE_IDS;
  const opts = ids.join(',');
  // HIMMEL-2288: numbered menu — same visual convention as askNumberedEnum()
  // (options 1..n, recommended default marked), extended for a multi-select:
  // "none" and a comma-separated list of names both still work (unchanged
  // CLI/hermetic-test surface); a comma-separated list of the printed numbers
  // is accepted too (translated to names below, BEFORE parseLaneList — the
  // CLI --lanes flag and adopter-profile.js's own tests keep validating
  // names/'none' only, never bare digits).
  const menu = ids.map((id, i) => `  ${i + 1}) ${id}${defaultLanes.indexOf(id) !== -1 ? ' (recommended)' : ''} — ${adopterProfileLib.LANE_HELP[id]}`).join('\n');
  const prompt = `? lanes [${opts}|none] (default: ${defaultLanes.join(',') || 'none'})\n${menu}\n  (Enter accepts the recommended default; comma-separate multiple numbers)\n> `;
  // HIMMEL-2303: disclose the CR-floor consequence AT this decision point,
  // once, before the (possibly re-prompted) question — never inside the loop
  // below, so a retry on invalid input doesn't repeat it.
  for (const line of adopterProfileLib.laneCrossModelDisclosureLines()) console.log(line);
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    if (t === '') return defaultLanes.slice();
    // CR round 3 [codex-2]: require plain decimal digits before coercing —
    // bare Number(s) also accepts '1e0'/'1.0'/'0x1' as integer 1, silently
    // selecting a lane from an undocumented numeric form. Same guard
    // askNumberedEnum() already uses.
    const translated = t === 'none' ? t : t.split(',').map((tok) => {
      const s = tok.trim();
      const n = /^[0-9]+$/.test(s) ? Number(s) : NaN;
      return Number.isInteger(n) && n >= 1 && n <= ids.length ? ids[n - 1] : s;
    }).join(',');
    const parsed = adopterProfileLib.parseLaneList(translated, { allowOptIn: true });
    if (parsed.ok) return parsed.lanes;
    // CR round 1 [glm-2]: say WHY before re-prompting. parseLaneList already
    // distinguishes "unknown lane" from "that one is opt-in, use --with-<id>";
    // discarding that left a bare re-prompt that looks like the input was
    // ignored rather than rejected. The reason goes to stderr so it can never
    // be mistaken for one of the `? ...` question headers on stdout.
    console.error(`  ! ${parsed.error}`);
  }
}

// Cadence-registry rows this run can actually offer: PER-ROW filtering, not
// whole-question vault gating (the HIMMEL-2302 spec deviation this fix
// closes — codex-sweep, `requires:'lane:codex'`, must be offerable on a
// vault-less codex-lane machine). A 'requires:vault' row is offered only when
// vaultMode!=='none'; a 'requires:lane:codex' row only when 'codex' is in the
// FINAL lanes selection; neither ever asked otherwise — the answer stays
// genuinely undefined, the same round-8 "not asked ≠ answered off"
// discipline every other section in this file already follows.
function offeredCadenceRows(lanes, vaultMode) {
  return CADENCE_REGISTRY.filter((r) => {
    if (r.requires === 'lane:codex') return (lanes || []).indexOf('codex') !== -1;
    if (r.requires === 'vault') return vaultMode !== 'none';
    return true;
  });
}

// HIMMEL-2302: per-cadence multi-select, replacing the old binary luna-
// cadence question at the same position. Same numbered-menu conventions as
// askLanes() above: numbers or names, comma-separated, 'none' = explicit
// none, Enter accepts `defaultIds` (the profile-preset-seeded set — see
// PROFILE_PRESETS' own comment). Returns `{ <id>: 'armed'|'off' }` for every
// OFFERED row (asked-and-declined records an honest 'off', never a fabricated
// answer) — a row filtered out by offeredCadenceRows() above is simply absent
// from the returned object, exactly like a never-asked question elsewhere in
// this file.
async function askCadences(ask, lanes, vaultMode, defaultIds) {
  const rows = offeredCadenceRows(lanes, vaultMode);
  const ids = rows.map((r) => r.id);
  const defaults = (defaultIds || []).filter((id) => ids.indexOf(id) !== -1);
  const opts = ids.join(',');
  const menu = rows.map((r, i) => `  ${i + 1}) ${r.id}${defaults.indexOf(r.id) !== -1 ? ' (recommended)' : ''} — ${r.description}`).join('\n');
  const prompt = `? cadences — recurring scheduled jobs to arm now [${opts}|none] (default: ${defaults.join(',') || 'none'})\n${menu}\n  (Enter accepts the recommended defaults; comma-separate multiple numbers)\n> `;
  for (;;) {
    const ans = await ask(prompt);
    const t = (ans || '').trim();
    let selected;
    if (t === '') {
      selected = defaults.slice();
    } else if (t === 'none') {
      selected = [];
    } else {
      const bad = [];
      selected = [];
      for (const tok of t.split(',').map((s) => s.trim()).filter((s) => s !== '')) {
        const n = /^[0-9]+$/.test(tok) ? Number(tok) : NaN;
        const id = Number.isInteger(n) && n >= 1 && n <= ids.length ? ids[n - 1] : tok;
        if (ids.indexOf(id) === -1) { bad.push(tok); continue; }
        if (selected.indexOf(id) === -1) selected.push(id);
      }
      if (bad.length > 0) {
        console.error(`  ! unknown cadence(s): ${bad.join(', ')} — choose from ${opts}, or 'none'`);
        continue;
      }
    }
    const cadences = {};
    for (const id of ids) cadences[id] = selected.indexOf(id) !== -1 ? 'armed' : 'off';
    return cadences;
  }
}

// Walk all questions interactively and return the answer object.
// `laneOpts` = { lanes, withCodex, withHermes } from the CLI flags: a given
// --lanes SKIPS the lanes question entirely (the operator already answered
// it), while --with-codex/--with-hermes append to whatever the base selection
// turns out to be. HIMMEL-2308 Part B: the interactive lanes menu now offers
// codex/hermes too (askLanes() calls parseLaneList with { allowOptIn: true })
// — selecting one AT THE PROMPT is itself the explicit consent, same
// principle as a --from-profile file naming them. The --lanes CSV flag stays
// restricted (no allowOptIn) — naming codex/hermes there must still be
// refused, so --lanes never becomes a second, quieter door around
// --with-codex/--with-hermes. `devOverlay` (HIMMEL-2308) is never a
// question — it is set only by the --contribute CLI flag, threaded straight
// into buildAnswers() below.
async function askQuestions(defaultScope, laneOpts, devOverlay) {
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
  const ask = makeAsk(rl);

  // 1. profile (HIMMEL-2308) — replaces the old role question. Seeds the
  // per-question defaults below; every question is still asked regardless of
  // which preset is picked (see PROFILE_PRESETS' own comment).
  const profile = await askNumberedEnum(ask, 'profile', ['starter', 'luna', 'operator', 'custom'], 'starter', PROFILE_HELP);
  const preset = PROFILE_PRESETS[profile];

  // 2. scope — universal now (the old adopter-only gate died with role).
  const scopeDefault = defaultScope || 'project';
  const scope = await askNumberedEnum(ask, 'scope', ['project', 'user'], scopeDefault, SCOPE_HELP);

  // 3. vault. T2 collects mode+path only (non-luna->luna conversion is O1,
  //    deferred out of P1).
  const vaultMode = await askNumberedEnum(ask, 'vault', ['none', 'default-template', 'existing'], preset.vaultMode, VAULT_HELP);
  let vaultPath = '';
  if (vaultMode !== 'none') {
    vaultPath = await askPath(ask, '? vault path (default: ~/Documents/luna)\n> ', '~/Documents/luna');
  }

  // 4. handover. T2 collects only; the write is T4.5.
  const handoverMode = await askNumberedEnum(ask, 'handover', ['inline', 'external'], preset.handoverMode, HANDOVER_HELP);
  let handoverPath = '';
  if (handoverMode === 'external') {
    const hd = process.env.HANDOVER_DIR || '~/.claude/handover-state';
    handoverPath = await askPath(ask, `? handover path (default: ${hd})\n> `, hd);
  }

  // 5. pluginSet. HIMMEL-2304: 'full' is DROPPED — the full-plugin-enable.json
  // set does not reflect what himmel actually runs (the reconciler whitelist
  // is the truth; see HIMMEL-2292), so offering it installed a batteries-
  // included set nobody operates. 'lean' is the only remaining path; the
  // question stays (rather than being removed outright) so every existing
  // --from-profile cache / hermetic-test stdin sequence that already answers
  // 'lean' here keeps working unchanged — only the 'full' CHOICE is gone.
  const pluginSet = await askNumberedEnum(ask, 'pluginSet', ['lean'], 'lean', PLUGIN_SET_HELP);

  // 6/7 (HIMMEL-862, universal since HIMMEL-2308).
  const opts = laneOpts || {};
  // 6. lanes. --lanes already answered it; otherwise prompt.
  const base = opts.lanes !== null && opts.lanes !== undefined
    ? opts.lanes
    : await askLanes(ask, adopterProfileLib.DEFAULT_LANE_IDS);
  const lanes = adopterProfileLib.applyOptIns(base, opts);
  // 7. alwaysOn. Decides checklist-vs-pointer only — NOTHING is executed
  //    either way (rescope: hardening is printed, never run).
  const ao = await askNumberedEnum(ask, 'always-on machine (unattended/scheduled runs)', ['yes', 'no'], preset.alwaysOn, ALWAYS_ON_HELP);
  const alwaysOn = ao === 'yes';

  // 8 (installer v1 fix, HIMMEL-2302 spec deviation): cadences is PER-ROW
  // gated, not whole-question vault gated — offeredCadenceRows() above
  // already filters each row by its own `requires` (vault vs lane:codex), so
  // the question itself must sit outside the vaultMode!=='none' gate too, or
  // a vault=none + lane:codex machine could never reach codex-sweep at all
  // (the exact bug this fix closes). Asked only when at least one row is
  // actually offered — zero offered rows = never asked, `cadences` stays
  // genuinely undefined (round-8 discipline), same as it always did for a
  // codex-less run before this fix. `cadences` is a TOP-LEVEL answer
  // (buildAnswers below), same pattern as luna/secretsWalk/bridge, not
  // nested inside `luna`.
  let cadences;
  let disarmCadence = false;
  if (offeredCadenceRows(lanes, vaultMode).length > 0) {
    cadences = await askCadences(ask, lanes, vaultMode, preset.cadenceIds);
    // RETASK stage1-build-6d2e round 4 [codex-1] (extended HIMMEL-2302 to
    // every declined UNIT, not just pipeline): declining a unit writes its
    // disposition as 'off' but does NOT, by itself, disarm anything already
    // armed on the machine (deliberate — disarming is machine-state
    // mutation, and this design requires consent for that, same as bridge
    // persistence below). Ask ONE consent question, covering every declined
    // unit by name, ONLY when at least one was actually declined; a decline
    // still gets an explicit still-manual line per unit (buildSummary), so
    // the operator is never left assuming "off" already took effect. Per
    // decision #5 (HIMMEL-2302): ONE consent question for every declined
    // unit — no per-unit disarm consent. Stays with cadences (moved out of
    // the vault gate together) since a vault=none + declined codex-sweep run
    // can equally have an existing armed job to clean up.
    const declinedIds = Object.keys(cadences).filter((id) => cadences[id] === 'off');
    if (declinedIds.length > 0) {
      // HIMMEL-2288: this is a CONSENT prompt for a machine-state mutation
      // (same as installPersistence below) — deliberately NOT
      // askNumberedEnum(); it keeps its full explicit yes/no wording, no
      // bare number-only accept.
      const disarmAns = await askEnum(ask, `? disarm any existing cadence jobs now for: ${declinedIds.join(', ')} (each unit's own disarm subcommand; consented, --dry-run shows it) [yes|no] (default: no)\n> `, ['yes', 'no'], 'no');
      disarmCadence = disarmAns === 'yes';
    }
  }

  // 9-11 (HIMMEL-2176 Task 8): PHI declaration, secrets walk, telegram
  // bridge. Still gated on vault!=none — same conditional-question shape as
  // vault path/handover path above, and for the same reason: an operator who
  // answered vault=none should not see a wall of unrelated prompts. This
  // ALSO keeps test-wizard-questions.sh's fixed question-count stdin
  // sequences (every vault=none case there) untouched — do not remove this
  // gate without updating that suite.
  let luna;
  let secretsWalk;
  let bridge;
  if (vaultMode !== 'none') {
    for (const line of adopterProfileLib.phiChecklistLines()) console.log(line);
    // HIMMEL-2288: PHI declaration — deliberately NOT askNumberedEnum();
    // a trust/consent declaration keeps its explicit yes/no wording.
    const phiAns = await askEnum(ask, '? does this vault handle Protected Health Information (PHI)? [yes|no] (default: no)\n> ', ['yes', 'no'], 'no');

    // HIMMEL-2347: a SEPARATE declaration — the vault being installed above
    // may itself carry no PHI, but the operator can still keep an unrelated
    // personal/medical vault elsewhere on the same machine that every local
    // agent/cloud-backend guard must steer around. This is the wizard half of
    // closing HIMMEL-1773/1767's inertness class: the guards (graph-
    // refresh.sh, refresh-graph-map.sh, graphify-fence.sh) already key off a
    // `.salus` marker + ~/.config/claude-glm/phi-roots, but nothing in the
    // installer ever created either, so every one of those guards has been
    // silently inert on a freshly-adopted machine. Consent-grade — askEnum()
    // literal-only (HIMMEL-2288), NOT askNumberedEnum(): a bare digit must
    // not silently answer this either. Optional: 'no' (the default) or a
    // blank path leaves phiVaultPath genuinely absent — "not asked" and
    // "asked but declined" both collapse to undefined here, and buildAnswers'
    // JSON.stringify drops it, so a declined/never-reached answer never
    // fabricates an empty path on disk (same discipline as phiDeclared next
    // to it).
    const phiVaultAns = await askEnum(ask, "? do you keep a personal/medical vault this machine's agents must never send to cloud backends? [yes|no] (default: no)\n> ", ['yes', 'no'], 'no');
    let phiVaultPath;
    let createSalusMarker;
    if (phiVaultAns === 'yes') {
      let p;
      for (;;) {
        p = await askPath(ask, '? personal/medical vault path\n> ', '');
        if (p.trim() === '' || isValidPhiVaultPathAnswer(p)) break;
        // HIMMEL-2347 CR fix 1: re-prompt with a reason rather than abort —
        // same retry-loop convention askLanes() already uses above (loop +
        // console.error(' ! reason') + re-emit the same prompt header), not
        // a new pattern. Blank still means "decline" (breaks the loop via
        // the check above); only a non-blank, non-absolute (or line-storage-
        // breaking, HIMMEL-2424) answer loops.
        const badByte = phiVaultPathBadByte(p);
        if (badByte) {
          // Name the byte, never print `p` — it's the one that contains it.
          console.error(`  ! that path contains ${badByte.name}, which ${badByte.reason} — remove it and try again, or leave it blank to skip`);
        } else {
          console.error(`  ! '${p}' is not absolute (or '~'-prefixed) — a relative path can never match the PHI guards' absolute-path comparison; try again, or leave it blank to skip`);
        }
      }
      if (p.trim() !== '') {
        phiVaultPath = p;
        // Offer, not an automatic write — creating `.salus` mutates a file
        // INSIDE the operator's own vault, so it gets its own explicit
        // consent, same class as the disarm-cadence/bridge-persistence
        // prompts above/below (HIMMEL-2288 consent wording, literal-only).
        // The phi-roots refresh below is NOT gated on this — it lands in
        // himmelctl's OWN config dir, not the vault, so recording the
        // declaration there needs no separate consent (same posture as
        // phiDeclared -> ~/.himmel/config.json just below).
        const salusAns = await askEnum(ask, `? create the .salus marker at ${p} now (marks this vault PHI to every local guard that checks it; consented, --dry-run shows it) [yes|no] (default: no)\n> `, ['yes', 'no'], 'no');
        createSalusMarker = salusAns === 'yes';
      }
    }
    // luna.cadenceEnabled mirrors the pipeline row (HIMMEL-2302 legacy
    // interplay: kept so an older reader/test that only ever knew this
    // boolean — status-report.js, cadence-emit.js, every pre-2302 fixture —
    // keeps validating/working on a freshly-written v2 profile). `cadences`
    // is always defined here — vaultMode!=='none' means offeredCadenceRows()
    // above always included at least one 'vault' row, so the question above
    // was always asked on this path.
    luna = { cadenceEnabled: cadences.pipeline === 'armed', phiDeclared: phiAns === 'yes', disarmCadence: disarmCadence, phiVaultPath: phiVaultPath, createSalusMarker: createSalusMarker };

    secretsWalk = await askNumberedEnum(ask, 'walk through luna secrets now (instruction card + probe per secret; himmelctl never harvests the value itself)', ['run', 'skip'], 'skip', SECRETS_WALK_HELP);

    const bridgeAns = await askNumberedEnum(ask, 'configure the telegram bridge (voice/text ingestion)?', ['off', 'on'], preset.bridge, BRIDGE_HELP);
    if (bridgeAns === 'on') {
      const bd = defaultBridgeSectionAnswer();
      const envPath = await askPath(ask, `? bridge .env path (default: ${bd.envPath})\n> `, bd.envPath);
      const whisperCli = await askPath(ask, `? whisper CLI path (blank = autodetect) (default: ${bd.whisperCli || '(autodetect)'})\n> `, bd.whisperCli);
      // HIMMEL-2308/HIMMEL-2346: whisperModel used to be free text with a
      // default the operator had no way to evaluate ("what is the big one?"
      // — the exact complaint this ticket fixes). Numbered enum of the
      // standard ggml models (preset.whisperModel — always defined,
      // PROFILE_PRESETS above — seeds the marked default), 'custom' falls
      // through to the original free-text ask for any other filename.
      const whisperModelKey = await askNumberedEnum(ask, 'whisper model', Object.keys(WHISPER_MODEL_FILENAMES).concat(['custom']), whisperModelKeyFor(preset.whisperModel), WHISPER_MODEL_HELP);
      const whisperModel = whisperModelKey === 'custom'
        ? await askPath(ask, `? whisper model filename (default: ${preset.whisperModel})\n> `, preset.whisperModel)
        : WHISPER_MODEL_FILENAMES[whisperModelKey];
      // RETASK stage1-build-6d2e — CR finding treated as more than a
      // Suggestion: this is the CONSENT prompt for a machine-state
      // mutation, so it must name the artifact THIS platform actually
      // installs (adopterProfileLib.bridgePersistenceArtifact() — the one
      // shared decision buildSummary's own --dry-run wording now reads
      // too), never a hardcoded "systemd --user unit" that is simply
      // false on Windows. On a platform with no installer at all,
      // consent for an install that will never happen is not consent for
      // anything real — skip the question entirely, default to no, and
      // say so.
      const persistArtifact = adopterProfileLib.bridgePersistenceArtifact();
      let installPersistence = false;
      if (persistArtifact) {
        // HIMMEL-2288: CONSENT prompt for a machine-state mutation —
        // deliberately NOT askNumberedEnum(); keeps explicit wording.
        const persistAns = await askEnum(ask, `? install bridge persistence now (${persistArtifact}; consented, --dry-run shows it) [yes|no] (default: no)\n> `, ['yes', 'no'], 'no');
        installPersistence = persistAns === 'yes';
      } else {
        console.log(`himmelctl: bridge persistence has no installer for platform '${process.platform}' — skipping the consent prompt; install/enable it manually (see docs/setup)`);
      }
      bridge = { enabled: true, envPath: envPath, whisperCli: whisperCli, whisperModel: whisperModel, installPersistence: installPersistence };
    } else {
      bridge = defaultBridgeSectionAnswer();
    }
  } else if (disarmCadence) {
    // vault=none can still reach the disarm consent question above (a
    // declined lane:codex row, e.g. codex-sweep) — record it in a partial
    // `luna` carrying ONLY disarmCadence, never phiDeclared/cadenceEnabled
    // (those were never asked on this path). lunaSectionSupplied() above is
    // keyed on `phiDeclared` specifically for exactly this reason: this
    // partial object must not be mistaken for a PHI answer that fabricates
    // `luna.phi.declared = false` on disk. When disarmCadence is false there
    // is nothing to record — `luna` stays undefined, identical in effect
    // (`luna.disarmCadence` reads falsy either way).
    luna = { disarmCadence: disarmCadence };
  }

  rl.close();
  return buildAnswers(profile, devOverlay, scope, vaultMode, vaultPath, handoverMode, handoverPath, pluginSet, lanes, alwaysOn, luna, secretsWalk, bridge, cadences);
}

// All-default answers (no prompts) for --dry-run previews.
function defaultAnswers(defaultScope, laneOpts, devOverlay) {
  const opts = laneOpts || {};
  // The lane rows honor the flags even in an all-defaults preview, so
  // `--dry-run --with-codex` actually previews the codex lane.
  const lanes = adopterProfileLib.applyOptIns(
    (opts.lanes !== null && opts.lanes !== undefined) ? opts.lanes : adopterProfileLib.DEFAULT_LANE_IDS,
    opts,
  );
  return buildAnswers('starter', devOverlay, defaultScope || 'project', 'none', '', 'inline', '', 'lean', lanes, false);
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
  // HIMMEL-2308: schemaVersion 2 replaces `role` (adopter|contributor) with
  // the orthogonal profile/devOverlay axes (see the T2 comment above
  // askQuestions()). Absent schemaVersion means an implicit v1 (legacy)
  // cache — validated against the OLD role-based shape below, then migrated
  // in place once the rest of validation passes. Any other value (a typo, a
  // future version this build doesn't know) fails loud rather than being
  // silently reinterpreted as either shape.
  const isV2 = obj.schemaVersion === 2;
  if (obj.schemaVersion !== undefined && !isV2) {
    profileError(p, `field 'schemaVersion' must be 2 (or absent for a legacy v1 profile) (got ${JSON.stringify(obj.schemaVersion)})`);
  }
  if (isV2) {
    checkEnum('profile', obj.profile, ['starter', 'luna', 'operator', 'custom']);
    if (typeof obj.devOverlay !== 'boolean') {
      profileError(p, `field 'devOverlay' must be a boolean (got ${JSON.stringify(obj.devOverlay)})`);
    }
  } else {
    checkEnum('role', obj.role, ['adopter', 'contributor']);
  }
  checkEnum('scope', obj.scope, ['project', 'user']);
  // HIMMEL-2308/HIMMEL-2304: 'full' was retired from the interactive wizard
  // (applyPluginStep keeps it only as a legacy courtesy via
  // offerRetiredPluginRemoval). A v2 profile is authored fresh under the
  // post-2304 model, so 'full' there must fail loud rather than validate and
  // silently no-op the plugin step. Legacy (pre-schemaVersion) profiles keep
  // accepting 'full' — that's the migration path the courtesy exists for.
  checkEnum('pluginSet', obj.pluginSet, isV2 ? ['lean'] : ['lean', 'full']);
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
  // HIMMEL-2352 backward compatibility: a lane this ticket made DORMANT
  // (ollama, copilot) must NOT hard-fail an existing profile. Those two were
  // the DEFAULT selection before this change, so every adopter who ran the
  // wizard already has them in ~/.claude/himmel/install-profile.json — and
  // docs/setup/profiles/operator.install-profile.json shipped them too.
  // Erroring here would brick every one of those caches on the next
  // `install --from-profile`, `gaps` or re-run: measured, the pre-2352
  // operator profile died with `field 'lanes' contains unknown lane
  // "copilot"`. They are dropped from the effective selection with a loud
  // note instead — the wizard genuinely cannot act on them any more, and
  // saying so is honest, whereas refusing to load is a regression for a
  // profile that was valid when it was written. An id that was NEVER a lane
  // still fails loud, exactly as before: this carve-out is keyed to the
  // known dormant set, not to "anything unrecognised".
  const droppedDormantLanes = [];
  for (const l of obj.lanes) {
    if (adopterProfileLib.ALL_LANE_IDS.indexOf(l) !== -1) continue;
    if (adopterProfileLib.DORMANT_LANE_HINTS[l]) {
      droppedDormantLanes.push(l);
      continue;
    }
    profileError(p, `field 'lanes' contains unknown lane ${JSON.stringify(l)} (known: ${adopterProfileLib.ALL_LANE_IDS.join(', ')})`);
  }
  if (droppedDormantLanes.length > 0) {
    obj.lanes = obj.lanes.filter((l) => adopterProfileLib.ALL_LANE_IDS.indexOf(l) !== -1);
    for (const l of droppedDormantLanes) {
      const env = adopterProfileLib.DORMANT_LANE_HINTS[l].optInEnv;
      console.log(`himmelctl: profile names lane '${l}', which is dormant in v1 — dropped from this run. It is not installed or probed; opt in directly with ${env}=1 (scripts/lanes/lanes.json) if you still want it.`);
    }
  }
  // Pre-HIMMEL-862 caches carried lanes:[] only as a schema placeholder. A new
  // profile marks the field meaningful so [] can safely mean explicit none;
  // legacy profiles that name lanes explicitly remain unambiguous and valid.
  if (obj.lanesMeaningful !== undefined && obj.lanesMeaningful !== true) {
    profileError(p, `field 'lanesMeaningful' must be true when present (got ${JSON.stringify(obj.lanesMeaningful)})`);
  }
  // HIMMEL-2308: lanes is asked UNIVERSALLY now, so a v2 profile's lanes:[]
  // must always carry lanesMeaningful=true — there is no role left to exempt.
  // HIMMEL-1470 (pre-existing, v1 only): the OLD lanes question was
  // adopter-only — buildAnswers gave a contributor lanes:[] and
  // applyLaneProfileStep short-circuited non-adopter — so the
  // legacy-placeholder refusal must still NOT fire for a legacy contributor
  // cache (its [] is a harmless placeholder from a role that never answered
  // it); gating the v1 branch on role==='adopter' keeps that exemption.
  if (isV2 && obj.lanes.length === 0 && obj.lanesMeaningful !== true) {
    profileError(p, "legacy profile has lanes:[] without lanesMeaningful=true; re-run the installer and reconfirm lane selection (use 'none' for an explicit empty allowlist)");
  }
  if (!isV2 && obj.role === 'adopter' && obj.lanes.length === 0 && obj.lanesMeaningful !== true) {
    profileError(p, "legacy profile has lanes:[] without lanesMeaningful=true; re-run the installer and reconfirm lane selection (use 'none' for an explicit empty allowlist)");
  }
  // HIMMEL-2300: optional, like the luna/secretsWalk/bridge sections just
  // below — a contributor cache (askQuestions() never asks alwaysOn for that
  // role, so buildAnswers() now leaves the key genuinely absent) must keep
  // validating rather than being exit-2'd over a field its role never
  // answers. When present it is still closed/strict, same as every other
  // field here.
  if (obj.alwaysOn !== undefined && typeof obj.alwaysOn !== 'boolean') {
    profileError(p, `field 'alwaysOn' must be a boolean when present (got ${JSON.stringify(obj.alwaysOn)})`);
  }
  // HIMMEL-2176 Task 8: luna/secretsWalk/bridge are OPTIONAL WHOLE SECTIONS
  // (unlike every other field above) — a pre-Task-8 cached profile carries
  // none of them, and that must keep validating so this task never breaks
  // an existing --from-profile fixture elsewhere in the suite. When a
  // section IS present, it gets the same closed, loud-on-mismatch treatment
  // as everything else here — a malformed new field must fail loud before
  // any side effect, exactly like the rest of this validator.
  if (obj.luna !== undefined) {
    if (!obj.luna || typeof obj.luna !== 'object' || Array.isArray(obj.luna)) {
      profileError(p, "field 'luna' must be an object when present");
    }
    // HIMMEL-2302 fix: cadenceEnabled/phiDeclared are each individually
    // optional WITHIN the (already-optional) luna section — a vault=none
    // interactive run can now reach the disarm-consent question (a declined
    // lane:codex cadence row) without vault/PHI ever being asked, producing
    // a partial `luna = { disarmCadence }` with neither field. Same
    // optional-when-present treatment disarmCadence itself already has just
    // below.
    if (obj.luna.cadenceEnabled !== undefined && typeof obj.luna.cadenceEnabled !== 'boolean') {
      profileError(p, `field 'luna.cadenceEnabled' must be a boolean (got ${JSON.stringify(obj.luna.cadenceEnabled)})`);
    }
    if (obj.luna.phiDeclared !== undefined && typeof obj.luna.phiDeclared !== 'boolean') {
      profileError(p, `field 'luna.phiDeclared' must be a boolean (got ${JSON.stringify(obj.luna.phiDeclared)})`);
    }
    // disarmCadence (RETASK stage1-build-6d2e round 4 [codex-1]) is itself
    // optional WITHIN the (already-optional) luna section — a profile saved
    // before this field existed still validates; absent means "not
    // answered", handled the same as an explicit decline downstream.
    if (obj.luna.disarmCadence !== undefined && typeof obj.luna.disarmCadence !== 'boolean') {
      profileError(p, `field 'luna.disarmCadence' must be a boolean (got ${JSON.stringify(obj.luna.disarmCadence)})`);
    }
    // HIMMEL-2347: phiVaultPath/createSalusMarker are each individually
    // optional WITHIN the (already-optional) luna section, same treatment as
    // cadenceEnabled/phiDeclared/disarmCadence just above — absent means
    // "never declared" (or declared with no marker consent), never coerced.
    if (obj.luna.phiVaultPath !== undefined) {
      if (typeof obj.luna.phiVaultPath !== 'string') {
        profileError(p, `field 'luna.phiVaultPath' must be a string (got ${JSON.stringify(obj.luna.phiVaultPath)})`);
      }
      // HIMMEL-2347 CR: a blank/whitespace-only or RELATIVE value was
      // silently accepted — path.join(phiVaultAbs, '.salus') on a relative
      // path resolves against the installer's cwd (marker lands somewhere
      // arbitrary), and a relative entry in phi-roots never matches the
      // guards' absolute-path comparison, so the guard goes silently inert
      // (the HIMMEL-1773 class this ticket exists to fix structurally).
      // Require non-blank + absolute (or '~'-prefixed; expandHome() resolves
      // it later) — isValidPhiVaultPathAnswer() is the SAME predicate the
      // interactive askPath() site above now enforces, so the two paths can
      // never drift apart again (CR fix 1).
      // HIMMEL-2424: CR/LF/NUL are rejected too (phiVaultPathBadByte()
      // inside isValidPhiVaultPathAnswer()) — a profile is arbitrary JSON, so
      // "who would type a newline into a path" doesn't apply; profiles are
      // generated and copied between machines. Give that case its own
      // message (JSON.stringify below already escapes the byte as text, so
      // this never echoes a raw control character into the terminal).
      const v = obj.luna.phiVaultPath;
      if (!isValidPhiVaultPathAnswer(v)) {
        const badByte = phiVaultPathBadByte(v);
        profileError(p, badByte
          ? `field 'luna.phiVaultPath' contains ${badByte.name}, which ${badByte.reason} (got ${JSON.stringify(v)})`
          : `field 'luna.phiVaultPath' must be a non-blank absolute path (or '~'-prefixed) (got ${JSON.stringify(v)})`);
      }
    }
    if (obj.luna.createSalusMarker !== undefined && typeof obj.luna.createSalusMarker !== 'boolean') {
      profileError(p, `field 'luna.createSalusMarker' must be a boolean (got ${JSON.stringify(obj.luna.createSalusMarker)})`);
    }
    // HIMMEL-2347 CR fix 4: createSalusMarker:true with no phiVaultPath is a
    // marker request that can never be applied (applyLunaSectionsStep only
    // reaches the marker block when luna.phiVaultPath is truthy) — reject it
    // loudly here rather than silently accepting a request that will
    // silently no-op. createSalusMarker:false with no path is fine — that's
    // just "not asked", the ordinary case.
    if (obj.luna.createSalusMarker === true && !obj.luna.phiVaultPath) {
      profileError(p, "field 'luna.createSalusMarker' is true but 'luna.phiVaultPath' is absent — a marker request needs a declared vault path to create it at");
    }
  }
  if (obj.secretsWalk !== undefined) {
    checkEnum('secretsWalk', obj.secretsWalk, ['run', 'skip']);
  }
  if (obj.bridge !== undefined) {
    if (!obj.bridge || typeof obj.bridge !== 'object' || Array.isArray(obj.bridge)) {
      profileError(p, "field 'bridge' must be an object when present");
    }
    if (typeof obj.bridge.enabled !== 'boolean') {
      profileError(p, `field 'bridge.enabled' must be a boolean (got ${JSON.stringify(obj.bridge.enabled)})`);
    }
    if (typeof obj.bridge.envPath !== 'string') {
      profileError(p, `field 'bridge.envPath' must be a string (got ${JSON.stringify(obj.bridge.envPath)})`);
    }
    if (typeof obj.bridge.whisperCli !== 'string') {
      profileError(p, `field 'bridge.whisperCli' must be a string (got ${JSON.stringify(obj.bridge.whisperCli)})`);
    }
    if (typeof obj.bridge.whisperModel !== 'string') {
      profileError(p, `field 'bridge.whisperModel' must be a string (got ${JSON.stringify(obj.bridge.whisperModel)})`);
    }
    if (typeof obj.bridge.installPersistence !== 'boolean') {
      profileError(p, `field 'bridge.installPersistence' must be a boolean (got ${JSON.stringify(obj.bridge.installPersistence)})`);
    }
  }
  // HIMMEL-2302: `cadences` is an OPTIONAL WHOLE SECTION, same pattern as
  // luna/secretsWalk/bridge just above — absent means never asked (a
  // pre-HIMMEL-2302 cache, or a vault=none flow that never unlocks the
  // question). When present, ids must be known CADENCE_REGISTRY ids and
  // values strictly 'armed'|'off' — a malformed/stale id must fail loud
  // before any side effect, exactly like every other field here.
  if (obj.cadences !== undefined) {
    if (!obj.cadences || typeof obj.cadences !== 'object' || Array.isArray(obj.cadences)) {
      profileError(p, "field 'cadences' must be an object when present");
    }
    // CR round 1 [HIMMEL-2302 Fix 3]: the wizard never writes `{}` (an
    // unasked question leaves the whole section absent, per the comment
    // above) — an empty object here can only be hand-authored, and
    // resolveCadenceDispositions() treats ANY present `cadences` section as
    // authoritative, silently suppressing a legacy `luna.cadenceEnabled`
    // answer with no cadence actually named. Fail loud rather than let that
    // silent-suppression class through --from-profile.
    // CR round 1 [HIMMEL-2302 Fix 3]: the wizard never writes `{}` (an
    // unasked question leaves the whole section absent, per the comment
    // above) — an empty object here can only be hand-authored, and
    // resolveCadenceDispositions() treats ANY present `cadences` section as
    // authoritative, silently suppressing a legacy `luna.cadenceEnabled`
    // answer with no cadence actually named. Fail loud rather than let that
    // silent-suppression class through --from-profile.
    if (Object.keys(obj.cadences).length === 0) {
      profileError(p, "field 'cadences' must not be an empty object — omit the section entirely when no cadence was asked");
    }
    const knownIds = CADENCE_REGISTRY.map((r) => r.id);
    for (const id of Object.keys(obj.cadences)) {
      if (knownIds.indexOf(id) === -1) {
        profileError(p, `field 'cadences' contains unknown cadence id ${JSON.stringify(id)} (known: ${knownIds.join(', ')})`);
      }
      if (obj.cadences[id] !== 'armed' && obj.cadences[id] !== 'off') {
        profileError(p, `field 'cadences.${id}' must be 'armed' or 'off' (got ${JSON.stringify(obj.cadences[id])})`);
      }
    }
    // CR round 1 [HIMMEL-2302 Fix 1]: cross-field validation. A
    // `requires:'vault'` cadence (pipeline/qmd/graphmap) armed while
    // vault.mode='none' validates the two fields independently above, then
    // breaks/no-ops at arm time — the validates-then-breaks class this
    // wizard forbids everywhere else. Fail loud here instead, naming both
    // the cadence and the unmet requirement.
    //
    // Deliberately asymmetric: a `requires:'lane:codex'` cadence (codex-sweep)
    // is NOT gated on whether 'codex' is actually in `lanes` here. `requires:
    // 'vault'` is a functional dependency (the cadence script has nothing to
    // run against without a vault) and is enforced; `requires:'lane:codex'`
    // is a consent surface — same principle as the lanes comment above (a
    // hand-reviewed profile naming codex-sweep IS the consent), so profile
    // naming alone suffices and it is left unchecked on purpose. Do not
    // "fix" this into symmetry.
    for (const row of CADENCE_REGISTRY) {
      if (row.requires === 'vault' && obj.cadences[row.id] === 'armed' && obj.vault.mode === 'none') {
        profileError(p, `field 'cadences.${row.id}' is 'armed' but requires a vault (vault.mode is 'none')`);
      }
    }
  }
  // HIMMEL-2308: migrate a validated legacy v1 (role-based) profile to the
  // v2 profile/devOverlay shape IN MEMORY — every downstream reader
  // (deriveCommand, runPlan, buildSummary, ...) speaks profile/devOverlay
  // only now. role='contributor' -> devOverlay=true (the dev overlay is
  // layered on top, same effective behavior as before this ticket for a
  // contributor cache); role='adopter' -> devOverlay=false. Neither role
  // named a profile preset, so both migrate to 'custom' (no seeding, matches
  // what an old cache's answers already reflect). schemaVersion is stamped
  // 2 here too: a caller that RE-WRITES a migrated object verbatim (e.g.
  // cmdScopeSet's `writeCache(Object.assign({}, cachedAnswers, {scope}))`)
  // must produce a file that reloads as v2 — without this, the re-written
  // cache carried neither `role` (deleted above) nor `schemaVersion` (never
  // set), so the NEXT load fell through to the v1 branch and hard-errored on
  // a missing `role` it could never have had.
  if (!isV2) {
    obj.schemaVersion = 2;
    obj.profile = 'custom';
    obj.devOverlay = obj.role === 'contributor';
    delete obj.role;
  }
  return obj;
}

// ── HIMMEL-2348: save-your-profile — offer to persist the answered profile
// as a NAMED, reusable file `--from-profile` can replay on another machine,
// at the end of a SUCCESSFUL, non-dry-run install/ensure. Landing dir mirrors
// cacheDir()'s own seam (lib/helpers.js) and the WHISPER_DIR pattern
// (whisperDirPath() above): an env override for tests, else a real ~/.himmel
// subdir. The `.install-profile.json` suffix is load-bearing — a CI glob in
// docs/setup/profiles/README.md matches on it.
function profilesDir() {
  return process.env.HIMMELCTL_PROFILES_DIR || path.join(os.homedir(), '.himmel', 'profiles');
}

// The name becomes a filename verbatim (`<name>.install-profile.json`) — a
// trust boundary, not a UX nicety. Reject anything that could escape
// profilesDir(): a path separator, a `..` segment, an absolute path,
// empty/whitespace, or a leading dot.
function isValidProfileName(name) {
  if (typeof name !== 'string') return false;
  const trimmed = name.trim();
  if (!trimmed || trimmed !== name) return false;
  if (trimmed.includes('/') || trimmed.includes('\\')) return false;
  if (trimmed === '.' || trimmed === '..') return false;
  if (trimmed.startsWith('.')) return false;
  if (path.isAbsolute(trimmed)) return false;
  return true;
}

// A free-text prompt that behaves like askConfirmSafe (own header comment
// above, ~line 2043) across the same three stdin shapes, except it resolves
// '' (not 'n') both on a blank Enter AND on EOF — for a name/overwrite
// prompt, "no answer" and "declined" are the same outcome, so a single empty
// string covers both without a caller having to special-case EOF.
function askLineSafe(prompt) {
  return new Promise((resolve) => {
    const rl = readline.createInterface({ input: process.stdin, output: process.stdout, terminal: false });
    let answered = false;
    rl.question(prompt, (ans) => {
      answered = true;
      rl.close();
      resolve(ans || '');
    });
    rl.on('close', () => {
      if (!answered) resolve('');
    });
  });
}

// Offer to save `answers` as a named profile. Called only when the caller has
// already decided the run was a SUCCESS worth offering to save (cmdInstall:
// runPlan returned 0 and !args.dryRun; cmdEnsure: converge completed) — this
// function itself makes no exit-code decision and never throws: a declined
// save (empty name, EOF, a declined overwrite) or a failed write WARNS and
// returns, never changing the caller's result. serialize(answers)+'\n' is the
// exact byte sequence writeCache() writes, so a saved profile round-trips
// through --from-profile identically to the cache.
async function offerSaveProfile(answers) {
  // HIMMEL-2348 cleanup: do NOT pre-trim here — isValidProfileName() below
  // does its own trim check (trimmed !== name rejects leading/trailing
  // whitespace) and is a trust-boundary validator other callers (e.g.
  // `gaps --preset`) also rely on; pre-trimming at this one call site made
  // that half of the check permanently dead here without making it safe to
  // remove from the validator, which every callsite must stay honest about.
  const name = await askLineSafe(
    'himmelctl: save this install profile for reuse elsewhere? Enter a name to save (or press Enter to skip): ',
  );
  if (!name) return;
  if (!isValidProfileName(name)) {
    console.warn(`himmelctl: invalid profile name ${JSON.stringify(name)} (no path separators, no '..', not absolute, no leading '.') — not saved.`);
    return;
  }
  const dir = profilesDir();
  const dest = path.join(dir, `${name}.install-profile.json`);
  const bytes = serialize(answers) + '\n';
  try {
    fs.mkdirSync(dir, { recursive: true });
  } catch (e) {
    console.warn(`himmelctl: could not save profile: ${e.message}`);
    return;
  }

  // Existence check first, purely to decide whether the "overwrite?" prompt
  // is needed — a create still needs no prompt, an existing name still gates
  // on confirmation. The actual write below never opens `dest` directly, so
  // nothing here is a trust boundary by itself.
  let destExists = true;
  try {
    fs.lstatSync(dest);
  } catch (e) {
    if (e.code !== 'ENOENT') {
      console.warn(`himmelctl: could not save profile: ${e.message}`);
      return;
    }
    destExists = false;
  }

  if (destExists) {
    const ans = await askLineSafe(`himmelctl: ${name}.install-profile.json already exists — overwrite? [y/N] `);
    if (!/^\s*y/i.test(ans)) {
      console.log('himmelctl: not overwriting; profile not saved.');
      return;
    }
    // Symlink refusal: this is no longer the security boundary (renameSync
    // below replaces the destination NAME atomically and cannot be made to
    // follow a symlink, so it can't be redirected through one). It stays as
    // a deliberate POLICY choice — we don't silently replace a symlink an
    // operator placed at this path with a regular file; refuse and say so.
    try {
      if (fs.lstatSync(dest).isSymbolicLink()) {
        console.warn(`himmelctl: ${dest} is a symlink — refusing to write through it; profile not saved.`);
        return;
      }
    } catch (e) {
      console.warn(`himmelctl: could not save profile: ${e.message}`);
      return;
    }
  }

  // Write via temp-file + rename, in the SAME directory as `dest` (rename is
  // only atomic within one filesystem). The temp is created exclusively
  // ('wx' — fails rather than clobbering if it somehow already exists) and
  // written with writeFileSync, which writes the whole buffer or throws —
  // no short-write hole from an ignored writeSync() return value. `dest`
  // itself is untouched until the renameSync, so a failure at any point up
  // to and including the write leaves a previously-saved profile intact.
  // renameSync then replaces the destination NAME atomically without
  // following a symlink, so there is no window between a check and a write
  // for something to swap the path underneath — the symlink-swap race the
  // old lstat-then-open('w') shape had is closed, not just narrowed.
  const tmpDest = path.join(dir, `.${name}.install-profile.json.${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}.tmp`);
  let tmpCreated = false;
  try {
    fs.writeFileSync(tmpDest, bytes, { flag: 'wx' });
    tmpCreated = true;
    fs.renameSync(tmpDest, dest);
    tmpCreated = false; // renamed away — nothing left at tmpDest to clean up
    console.log(`himmelctl: saved profile to ${dest}`);
  } catch (e) {
    console.warn(`himmelctl: could not save profile: ${e.message}`);
  } finally {
    if (tmpCreated) {
      try {
        fs.unlinkSync(tmpDest);
      } catch (_e) {
        // best-effort cleanup only; nothing more to do if this fails too.
      }
    }
  }
}

// ── T4/T5a/T4.5: derivation, vault profile, handover/pluginSet, shell-out ────
//
// HIMMEL-2308: ONE execution engine now — every install derives
//   bash scripts/adopt.sh --profile <core|all> --scope <project|user>
//     [--luna-target <path>]
// (profile from the T5a vault mapping below; adopt.sh is bash-native and
// bash is a hard-gate tool on every platform incl. Windows via Git Bash, so
// no win32 branch is needed). The old role fork that instead derived
// setup.sh/setup.ps1 for a 'contributor' role is GONE — devOverlay is
// orthogonal now: when set (via --contribute), deriveOverlayCommand() below
// derives setup.sh/setup.ps1 as an ADDITIONAL step layered on top of the
// adopt.sh run above, never a replacement for it. setup.sh remains the
// idempotent contributor-dev mutation primitive; only WHEN it runs changed.
// --dry-run prints the plan (+ T4.5 side effects) and exits 0 WITHOUT
// executing. Otherwise ONE confirm (`Proceed? [Y/n]`), then the T4.5
// handover-write, the verbatim shell-out (stdio inherit, rc propagated), and
// (on success) the dev overlay (if any) then the T4.5 plugin-enable step.

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
  // HIMMEL-2304: pluginSet=full's extra user-scope target is gone along with
  // its enable step — nothing writes there anymore, so nothing preflights it.
  const targets = [settingsPathForScope(answers.scope)];
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
// are its args, sized for spawnSync. HIMMEL-2308: ONE engine — always
// adopt.sh, regardless of profile/devOverlay (see deriveOverlayCommand()
// below for the dev-overlay's ADDITIONAL command).
function deriveCommand(answers) {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  const argv = [resolveBash(), toBashPath(path.join(scriptsDir, 'adopt.sh'))];
  const profile = profileForVault(answers);
  argv.push('--profile', profile, '--scope', answers.scope || 'project');
  if (profile === 'all' && answers.vault && answers.vault.path) {
    argv.push('--luna-target', toBashPath(expandHome(answers.vault.path)));
  }
  return { argv };
}

// Derive { argv } for the dev-overlay's own command (HIMMEL-2308): the same
// setup.sh/setup.ps1 primitive the OLD contributor role exclusively derived,
// now layered on TOP of deriveCommand()'s adopt.sh run instead of replacing
// it. Only reached when answers.devOverlay is true (the --contribute flag).
function deriveOverlayCommand() {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  if (process.platform === 'win32') {
    return { argv: [resolvePowershell(), '-ExecutionPolicy', 'Bypass', '-File', path.join(scriptsDir, 'setup.ps1')] };
  }
  return { argv: [resolveBash(), toBashPath(path.join(scriptsDir, 'setup.sh'))] };
}

// The dev-overlay primitive's filename for the current platform — shared by
// contributeCheckoutOk() (the existence check) and its own error message
// below, so the two never name different files.
function contributeOverlayFilename() {
  return process.platform === 'win32' ? 'setup.ps1' : 'setup.sh';
}

// HIMMEL-2308: is the resolved repo root an actual himmel checkout the dev
// overlay can run setup.sh/setup.ps1 against? A pure fs read — the same
// primitive deriveOverlayCommand() would target — rather than a second
// heuristic (e.g. the old .himmel-dev marker sniff, which detectRole() used
// to gate the whole role question on; --contribute is explicit consent, so
// the check here is only "does the primitive this flag invokes exist").
function contributeCheckoutOk() {
  const scriptsDir = path.join(repoRoot(), 'scripts');
  return fs.existsSync(path.join(scriptsDir, contributeOverlayFilename()));
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
// rather than throwing. `opts.env`, when given, replaces the child's
// environment (callers pass `{ ...process.env, ... }` to extend rather than
// replace it) — used by cmdUninstall's confirmed WET spawn only (HIMMEL-2505).
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

// Load the documented full-plugin-enable table from data, rather than keeping
// a second inline copy that can drift. HIMMEL-2304: the wizard no longer
// offers pluginSet=full (its enable step is gone — applyPluginStep() is now
// unconditionally a no-op), but this table's plugin NAMES are still the
// canonical vocabulary the `config set hooks.plugin.<name>` toggle validates
// against (hookPluginNames() below) — that command is independent of the
// wizard's pluginSet question, so this loader stays.
let fullPluginEnableCache = null;
function fullPluginEnable() {
  if (fullPluginEnableCache !== null) return fullPluginEnableCache;
  const dataPath = path.join(repoRoot(), 'scripts', 'machine-setup', 'full-plugin-enable.json');
  const data = JSON.parse(fs.readFileSync(dataPath, 'utf8'));
  if (!Array.isArray(data.plugins)) throw new Error(`invalid full plugin data: ${dataPath}`);
  fullPluginEnableCache = data.plugins;
  return fullPluginEnableCache;
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

// T4.5 helper: --dry-run DRY-line preview for handover.mode=external. Shared
// by the main adopter/contributor dry-run preview and the T5b existing-vault
// dry-run preview (FIX 5) so both branches honor the answer identically
// instead of only the main path previewing it. HIMMEL-2304: this used to also
// preview pluginSet=full's enable commands — that whole step (and 'full'
// itself) is gone, so the name stays (still shared with the caller's other
// dry-run bookkeeping) but there is nothing left to preview for plugins.
function previewHandoverAndPlugins(answers) {
  if (answers.handover && answers.handover.mode === 'external') {
    const envFile = path.join(repoRoot(), '.env');
    console.log(`DRY: HANDOVER_DIR -> ${expandHome(answers.handover.path)} (would write to ${envFile})`);
  }
}

// ── HIMMEL-2176 Stage-1 PR-C Task 8: luna cadence / secrets walk / bridge ───
//
// Shared plumbing for the three new adopter-wizard sections (design §3.4,
// A9/A10/A14/A15/A17). Config persistence goes through lib/luna-config.js
// (a CLOSED schema — every field written below already exists in its
// SCHEMA/defaultConfig()); cadence emission goes through lib/cadence-emit.js
// (a pure config->CLI-flag mapping — it never talks to schtasks/cron
// itself); the three previously-unreachable bridge-only probes
// (cmd:whisper_ready, cmd:python_interpreter, distinct-tokens) are dispatched
// via probes.js's runProbe() with a SYNTHESIZED descriptor — no
// scripts/install/manifest.json item names them (that table belongs to a
// sibling task), and A17 puts them inside the OPTIONAL bridge section
// specifically so a cadence-only install never warns about voice tooling.
// Positioned like applyPluginStep: these steps run AFTER the core install
// succeeds and are non-fatal (WARN + continue) — they never gate adopt.sh.

// Reconstruct { dir, base, file } for an arbitrary configured bridge.envPath
// (which may be `~`-prefixed or any absolute path, NOT necessarily the
// manifest's default relative-to-$HOME location) so probes.js's
// resolveConfigFile() — which joins ctx.targetPath + a probe's relative
// `envFile`/`envFileA` field for any non-'.env' value — reconstructs the
// EXACT configured path regardless of where it lives.
//
// RETASK stage1-build-6d2e [codex-4] ROOT CAUSE: resolveConfigFile()
// special-cases the LITERAL string '.env' to mean "ctx.repoRoot's own .env",
// ignoring ctx.targetPath entirely. The bridge env file is conventionally
// ALSO named `.env`, so handing its bare basename ('.env') as the `envFile`/
// `envFileA` value collided with that special case and silently resolved to
// the wrong file (repoRoot/.env) regardless of ctx.targetPath — in
// distinct-tokens this made A and B the SAME file (a vacuous always-pass);
// in cmd:telegram_getme it silently probed the wrong .env entirely. `file`
// below is prefixed with `./` (any non-'.env' string bypasses the special
// case) so `path.join(ctx.targetPath, file)` still reconstructs the exact
// configured path — fixed ONCE here rather than at each of the two call
// sites, since both derive from the same bare-basename mistake.
// ponytail: the `./` prefix can collide back to a bare basename only if the
// env file sits at a filesystem root (dirname(dir)===dir) — not a real-world
// bridge .env location; not defended against.
// RETASK stage1-build-6d2e round 4 [codex-2]: TELEGRAM_ENV is the SAME
// process-env override poller.ts/session-status.ts already read
// (`process.env.TELEGRAM_ENV ?? join(homedir(), ".claude/channels/telegram/
// .env")`) and probes.js's own resolveBridgeEnvFilePath() (used by
// cmd:telegram_getme/telegram-access/bridge-health) already honors it ahead
// of bridge.envPath. distinct-tokens has no such awareness built into
// probes.js — it just resolves whatever envFileA/envFileB strings it's
// given — so the SAME three-tier precedence (process-env override >
// configured value > hardcoded default) has to be applied on THIS side too,
// here in the one shared helper, rather than invented a second way for one
// call site. `runBridgeReadinessProbes`'s distinct-tokens call gets this via
// this function; probeOneSecret's cmd:telegram_getme call gets it too (a
// harmless no-op agreement — probes.js's own TELEGRAM_ENV check already
// wins there regardless of what `file` says).
//
// CR fix (HIMMEL-2176): `(bridge && bridge.envPath) || ''` skipped straight
// to the EMPTY string when the profile legitimately omits the optional
// bridge section — `path.dirname('')` is `.`, so the probe silently looked
// in the CWD instead of the documented default and read 'unconfigured' even
// when a real bridge .env sat where it belongs. An absent/empty
// bridge.envPath must skip the middle tier, not resolve to a technically-
// valid-but-wrong path — same shape as onboard.ts's `??` vs `${VAR:-}` fix
// this round. Falls back to lunaConfigLib.defaultConfig()'s own
// bridge.envPath (the SAME source defaultBridgeSectionAnswer() above uses)
// rather than a second copy of that literal.
function bridgeEnvProbeCtx(bridge) {
  const configured = (bridge && bridge.envPath) || lunaConfigLib.defaultConfig().bridge.envPath;
  const configuredPath = expandHome(configured);
  const envPath = process.env.TELEGRAM_ENV ? expandHome(process.env.TELEGRAM_ENV) : configuredPath;
  const base = path.basename(envPath);
  return { dir: path.dirname(envPath), base: base, file: `./${base}` };
}

// Precedence idiom (brief-mandated, applied throughout this section, stated
// once here): process-env override wins, else the operator's configured
// value, else probes.js's own hardcoded default — achieved by simply NOT
// setting the env key when neither an override nor a configured value
// exists, since probeWhisperReady/etc. already fall back to their own
// hardcoded default when the env key is absent.
function envOverrideOrConfigured(envKey, configuredValue) {
  if (process.env[envKey]) return process.env[envKey];
  return configuredValue || undefined;
}

// RETASK stage1-build-6d2e round 7 [codex-1] ROOT CAUSE: probes.js's
// probeWhisperReady() reads WHISPER_CLI/WHISPER_MODEL as COMPLETE PATHS once
// set (`env.WHISPER_CLI || configuredCli || ...`, `env.WHISPER_MODEL ||
// configuredModel || ...`) — but the two config fields have DIFFERENT
// shapes: `bridge.whisper.cli` is stored as a full path already (matches
// probeWhisperReady's own `configuredCli`, used as-is), while
// `bridge.whisper.model` is stored as a BARE FILENAME (the schema default
// is literally `ggml-small.bin`) — probeWhisperReady's own `configuredModel`
// joins it with the whisper dir before comparing
// (`path.join(dir, whisperConfig.model)`). Handing the bare filename
// straight through as WHISPER_MODEL skipped that join, so a correctly-
// configured model got checked against the process CWD instead of
// ~/.himmel/whisper and read absent — which then blocked bridge persistence
// entirely via the round-1 [codex-2] readiness gate. `cli` has no such bug
// (verified: both this file and probes.js already treat it as a full path,
// never joined) — only `model` needs the join, and it needs it applied
// BEFORE the value is handed over as an env override, since WHISPER_MODEL
// itself carries no "join with dir" semantics on the reading side.
// ONE shared helper, both call sites (runBridgeReadinessProbes below AND
// probeOneSecret's cmd:whisper_ready branch) — the same class of bug as the
// `.env` bare-basename mistake fixed once in bridgeEnvProbeCtx() rather than
// per call site.
function whisperDirPath() {
  const home = process.env.HOME || os.homedir();
  return process.env.WHISPER_DIR || path.join(home, '.himmel', 'whisper');
}
// RETASK stage1-build-6d2e CR round 15 [codex-1]: both of this function's
// current callers already guard with `answers.bridge || {}` before calling
// in, so `bridge` is never actually undefined on the live path today — but
// this was the one place in the bridge-optional family that didn't defend
// itself the way bridgeEnvProbeCtx() above already does (`bridge &&
// bridge.envPath`), so a future caller that forgets that guard (or a
// currently-unguarded new call site) would crash exactly the way this one
// used to. Same precedence either way, just skipping the middle tier when
// there is no bridge section at all: WHISPER_* env override, else the
// configured value when a bridge section exists, else probes.js's own
// hardcoded default (achieved, as envOverrideOrConfigured's own comment
// says, by simply not setting the env key).
function resolveWhisperEnvOverrides(bridge) {
  const configuredModelFull = (bridge && bridge.whisperModel) ? path.join(whisperDirPath(), bridge.whisperModel) : undefined;
  return {
    WHISPER_CLI: envOverrideOrConfigured('WHISPER_CLI', bridge && bridge.whisperCli),
    WHISPER_MODEL: process.env.WHISPER_MODEL || configuredModelFull,
  };
}

// A17: the three bridge-only readiness probes. Never throws — each call is
// independently wrapped so one probe's failure can't hide the others'.
function runBridgeReadinessProbes(bridge) {
  const safe = (label, item, ctx) => {
    try {
      return probesLib.runProbe(item, ctx);
    } catch (e) {
      return { actual: 'degraded', detail: `${label} probe threw: ${e && e.message ? e.message : e}` };
    }
  };
  const platform = process.platform;
  const baseEnv = process.env;

  const whisperEnv = Object.assign({}, baseEnv, resolveWhisperEnvOverrides(bridge));
  const whisperReady = safe('cmd:whisper_ready',
    { probe: { type: 'cmd:whisper_ready' } },
    { repoRoot: repoRoot(), targetPath: repoRoot(), scope: 'project', platform: platform, env: whisperEnv });

  const pythonInterpreter = safe('cmd:python_interpreter',
    { probe: { type: 'cmd:python_interpreter' } },
    { repoRoot: repoRoot(), targetPath: repoRoot(), scope: 'project', platform: platform, env: baseEnv });

  // RETASK stage1-build-6d2e [codex-4]: A11's intent is comparing the
  // BRIDGE bot token against the repo-root HIMMEL_JIRA_NUDGE relay token —
  // two DIFFERENT files. When bridge.envPath itself resolves to the SAME
  // file as repoRoot/.env (a misconfiguration, or a bridge pointed at the
  // repo's own .env), there is only ONE file to read — the comparison is
  // meaningless, not "fine", so it must never read green. Checked BEFORE
  // calling the probe (never even dispatched in that case).
  const envInfo = bridgeEnvProbeCtx(bridge);
  const jiraNudgeEnvPath = path.join(repoRoot(), '.env');
  const bridgeEnvPath = path.join(envInfo.dir, envInfo.base);
  let distinctTokens;
  if (normalizePathForCompare(bridgeEnvPath) === normalizePathForCompare(jiraNudgeEnvPath)) {
    distinctTokens = {
      actual: 'degraded',
      detail: `bridge.envPath (${bridgeEnvPath}) resolves to the SAME file as the repo-root .env (${jiraNudgeEnvPath}) — not applicable: there is only one file to compare, so distinct-tokens cannot tell the bridge and the HIMMEL_JIRA_NUDGE relay apart. Point bridge.envPath at its own file.`,
    };
  } else {
    distinctTokens = safe('distinct-tokens', {
      probe: {
        type: 'distinct-tokens',
        envFileA: envInfo.file, tokenKeyA: 'TELEGRAM_BOT_TOKEN',
        envFileB: '.env', tokenKeyB: 'TELEGRAM_BOT_TOKEN',
      },
    }, { repoRoot: repoRoot(), targetPath: envInfo.dir, scope: 'project', platform: platform, env: baseEnv });
  }

  return { whisperReady, pythonInterpreter, distinctTokens };
}

// win32 lowercases (default-case-insensitive filesystem), POSIX keeps case
// — same convention probes.js's own normalizeForPhiMatch uses; kept local
// (a private compare, not exported cross-module for one call site).
function normalizePathForCompare(p) {
  const resolved = path.resolve(p);
  return process.platform === 'win32' ? resolved.toLowerCase() : resolved;
}

// A14/A15: dispatch ONE secrets-manifest entry's probe — cmd:telegram_getme
// (via the bridge's own configured .env), cmd:whisper_ready (same env
// precedence as runBridgeReadinessProbes above), and luna-sources (via each
// entry's own `sources` field — the fetch-health.py source id(s) that
// credential unlocks, e.g. TWITTER_COOKIE_FILE -> ['x-media'],
// INSTAGRAM_COOKIE_FILE -> ['instagram-media']; see secrets-manifest.json).
// RETASK stage1-build-6d2e: a skipped/never-configured source and a
// configured-but-broken one are DIFFERENT facts and must read differently —
// 'unconfigured' is reserved for the former (A15's skippable case); the
// latter surfaces the probe's OWN failure reason (auth-or-cookie-expired /
// blocked-or-rate-limited / transport-fail), never flattened to
// 'unconfigured'. Never a crash — any probe error this file's own code
// throws (not fetch-health.py's, which probeLunaSources already catches and
// reports as 'degraded') is caught, never aborting the walk (A15/A17: a
// failing source blocks nothing else).
//
// RETASK stage1-build-6d2e round 6 [codex-3]: a THROWN exception used to be
// folded into 'unconfigured' too — but 'unconfigured' means "the adopter
// has not set this up", and telling someone their probe threw an exception
// by saying "go configure this" (when it may already BE configured — we
// never got far enough to check) is exactly the conflation this ticket
// already ruled against for the ok/skipped-vs-failed distinction elsewhere.
// A thrown exception gets its OWN status ('error'), naming the failure, so
// buildSummary can render it as "we don't know — investigate", never as an
// instruction to configure something that might already be configured.
function probeOneSecret(entry, bridge) {
  try {
    if (entry.probe === 'cmd:telegram_getme') {
      const envInfo = bridgeEnvProbeCtx(bridge);
      const r = probesLib.runProbe(
        { probe: { type: 'cmd:telegram_getme', envFile: envInfo.file, tokenKey: 'TELEGRAM_BOT_TOKEN', apiModule: 'scripts/telegram/telegram-api.ts' } },
        { repoRoot: repoRoot(), targetPath: envInfo.dir, scope: 'project', env: process.env },
      );
      if (r.actual === 'present') return { status: 'configured', detail: r.detail };
      if (r.actual === 'degraded') return { status: 'degraded', detail: r.detail };
      return { status: 'unconfigured', detail: r.detail };
    }
    if (entry.probe === 'cmd:whisper_ready') {
      // [codex-1 round 7] same shared helper as runBridgeReadinessProbes —
      // model is a bare filename and must be joined with the whisper dir
      // before it can stand in for WHISPER_MODEL (a complete-path env var).
      const whisperEnv = Object.assign({}, process.env, resolveWhisperEnvOverrides(bridge));
      const r = probesLib.runProbe(
        { probe: { type: 'cmd:whisper_ready' } },
        { repoRoot: repoRoot(), targetPath: repoRoot(), scope: 'project', platform: process.platform, env: whisperEnv },
      );
      if (r.actual === 'present') return { status: 'configured', detail: r.detail };
      if (r.actual === 'degraded') return { status: 'degraded', detail: r.detail };
      return { status: 'unconfigured', detail: r.detail };
    }
    // RETASK stage1-build-6d2e: 'luna-sources' entries are actively probed
    // too, via each entry's own `sources` field (the manifest ids that
    // credential unlocks — see secrets-manifest.json). Reuses
    // probesLib.runProbe's existing 'luna-sources' aggregator (the SAME
    // fetch-health.py `--probe <source>` invocation manifest.json's own
    // luna-sources item drives) rather than re-implementing the spawn —
    // that aggregator already tells "adopter never configured this"
    // (actual:'absent', A15's skippable-unconfigured case) apart from
    // "configured but the probe itself failed" (actual:'degraded', whose
    // detail already carries fetch-health.py's own reason —
    // auth-or-cookie-expired / blocked-or-rate-limited / transport-fail —
    // rather than a flat 'unconfigured' the brief explicitly forbids here).
    if (entry.probe === 'luna-sources' && Array.isArray(entry.sources) && entry.sources.length > 0) {
      const r = probesLib.runProbe(
        { probe: { type: 'luna-sources', script: 'scripts/luna/fetch-health.py', sources: entry.sources } },
        { repoRoot: repoRoot(), targetPath: repoRoot(), scope: 'project', platform: process.platform, env: process.env },
      );
      if (r.actual === 'present') return { status: 'configured', detail: r.detail };
      if (r.actual === 'absent') return { status: 'unconfigured', detail: r.detail };
      // 'degraded' — configured (or partially configured) but the probe
      // itself flagged a real problem; r.detail already names it.
      return { status: 'degraded', detail: r.detail };
    }
  } catch (e) {
    return { status: 'error', detail: `probe threw: ${e && e.message ? e.message : e}` };
  }
  return { status: 'unconfigured', detail: 'not actively probed by the wizard — see the obtain instructions above' };
}

// HIMMEL-2305: split SECRETS_MANIFEST.secrets into what this recorded
// profile's selections actually cover vs. what a never-selected feature
// scopes out — shared by the --dry-run preview and the real walk so the two
// can never disagree on the count. `answers` drives
// adopterProfileLib.resolveActiveFeatures(); see that function's own header
// for its never-asked/fail-open contract (a fail-open `null` scopes nothing
// out here either — every secret stays in `scoped`).
function scopeSecretsByFeature(answers) {
  const activeFeatures = adopterProfileLib.resolveActiveFeatures(answers);
  if (activeFeatures === null) {
    return { scoped: SECRETS_MANIFEST.secrets, skipped: [] };
  }
  const scoped = [];
  const skipped = [];
  for (const entry of SECRETS_MANIFEST.secrets) {
    (activeFeatures.has(entry.feature) ? scoped : skipped).push(entry);
  }
  return { scoped, skipped };
}

// One honest line naming how many secrets were scoped out and why — shared
// wording for the --dry-run preview and the real walk.
function scopedOutLine(skipped) {
  if (skipped.length === 0) return null;
  const features = Array.from(new Set(skipped.map((s) => s.feature))).sort();
  return `  (scoped out ${skipped.length} secret(s) for feature(s) not selected in this profile: ${features.join(', ')} — skip these unless you opt in later)`;
}

// Print the per-secret instruction card (obtain + storage — A15: the wizard
// NEVER harvests the credential itself) then immediately probe it. Returns
// the per-secret result rows buildSummary folds into skipped/manual.
// HIMMEL-2305: walks only the secrets whose feature the recorded selections
// (vault/cadences/bridge/lanes) actually cover — an unselected feature's
// secrets are skipped, with one honest line naming how many and why.
function runSecretsWalk(bridge, answers) {
  const results = [];
  const { scoped, skipped } = scopeSecretsByFeature(answers);
  const line = scopedOutLine(skipped);
  if (line) console.log(line);
  // CR fix (RETASK stage1-build-6d2e): paired credentials (BITBUCKET_API_TOKEN/
  // BITBUCKET_EMAIL, TWITTER_AUTH_TOKEN/TWITTER_CT0) both declare the SAME
  // luna-sources `sources` id, so probing each independently fired the same
  // EXTERNAL health probe (fetch-health.py --probe <source>) twice per walk
  // for zero new information — wasteful against a quota-limited service
  // (firecrawl). Memoized per source id, scoped to this ONE walk only (not a
  // persistent cache, cleared every call) — the second credential naming an
  // already-probed source reuses that result. Verdicts/wording are
  // unaffected: every entry still gets its own printed line and its own row
  // in `results`, including the paired-credential wording that names the
  // sibling (that's buildSummary's job, driven by `results`, untouched here).
  const lunaSourceCache = new Map();
  for (const entry of scoped) {
    console.log(`  ${entry.name} [${entry.required}]`);
    console.log(`    storage: ${entry.storage}`);
    console.log(`    obtain:  ${entry.obtain}`);
    const sourcesKey = (entry.probe === 'luna-sources' && Array.isArray(entry.sources) && entry.sources.length > 0)
      ? entry.sources.join('|')
      : null;
    let r;
    if (sourcesKey && lunaSourceCache.has(sourcesKey)) {
      r = lunaSourceCache.get(sourcesKey);
    } else {
      r = probeOneSecret(entry, bridge);
      if (sourcesKey) lunaSourceCache.set(sourcesKey, r);
    }
    console.log(`    probe:   ${r.status} — ${r.detail}`);
    results.push({ name: entry.name, status: r.status, detail: r.detail, obtain: entry.obtain });
  }
  return results;
}

// --dry-run preview for the three sections — mirrors previewHandoverAndPlugins
// (immediate `DRY:` lines; no mutation, no spawn). Wrapped in its own
// try/catch (the "reporting must never gate" convention, bin.js:1322-1362):
// lunaConfigLib.load() can throw on a malformed on-disk config, and that must
// never abort a --dry-run preview.
// RETASK stage1-build-6d2e [codex-1]: `answers.luna`/`answers.bridge` are
// OPTIONAL WHOLE SECTIONS on --from-profile (loadProfile() validates them
// only when present, for backward compat with a pre-Task-8 cache). "Optional
// on read" has to mean "untouched on write" too — a legacy profile has
// NEITHER key, and treating `undefined` as `false` would silently disarm a
// working cadence/PHI declaration/bridge on every replay. Both helpers below
// are shared by the dry-run preview and the real apply step so the two can
// never drift on what "supplied" means.
// HIMMEL-2302 fix: keyed on `phiDeclared` specifically (not mere presence of
// `luna`) — the cadences question now moves off the vault gate, so a
// vault=none run that still asks cadences (a lane:codex row) can build a
// partial `luna = { disarmCadence }` with NO phiDeclared field (PHI was never
// asked). Checking bare `luna !== undefined` there would wrongly read as
// "PHI supplied" and write a fabricated `luna.phi.declared = false` to disk.
// Every existing profile that supplies `luna` for real (interactive
// vault!=='none', or a --from-profile cache) always carries `phiDeclared` as
// a boolean alongside it, so this is a no-op change for every other caller.
function lunaSectionSupplied(answers) {
  return Boolean(answers.luna) && typeof answers.luna.phiDeclared === 'boolean';
}
function bridgeSectionSupplied(answers) {
  return answers.bridge !== undefined && answers.bridge !== null;
}

// HIMMEL-2302: resolveCadenceDispositions() itself lives in adopter-profile.js
// (adopterProfileLib), not here — buildSummary needs the SAME resolution
// logic and lives in that module, so it's the one shared place both this
// file and buildSummary read from (never drift). See its own comment there.

// HIMMEL-2302: per-unit arm-argv builder. pipeline keeps cadence-emit.js's
// existing persisted config->flag mapping (~/.himmel/config.json's
// luna.cadence.* — untouched by this ticket, see luna-config.js SCHEMA).
// qmd/graphmap/codex-sweep have NO persisted per-adopter schedule surface
// (explicitly NOT IN SCOPE for HIMMEL-2302) — arm them with the script's own
// all-default invocation: verified in-tree against each script's own
// usage()/cmd_arm() that every flag is genuinely optional with a sane
// script-side default (qmd-cadence.sh: --time/--hourly/--ship-to all
// optional; graphmap-cadence.sh: --luna-time/--himmel-time/--vault all
// optional; codex-sweep-cadence.sh: --time/--repeat-hours both optional) —
// none of the four registry units needed a guessed schedule, so none is
// preview-only. graphmap-cadence.sh accepts the same --vault flag pipeline
// does; qmd/codex-sweep take none.
function cadenceArmFlags(id, { doc, vaultPath }) {
  if (id === 'pipeline') return cadenceEmitLib.buildArmFlags({ cadence: doc.luna.cadence, vaultPath: vaultPath });
  if (id === 'graphmap') return vaultPath ? ['--vault', vaultPath] : [];
  return [];
}

function cadenceScriptPath(id) {
  const row = CADENCE_REGISTRY.find((r) => r.id === id);
  return path.join(repoRoot(), row.script);
}

// HIMMEL-2176 CR: the ONE WARN wording for "~/.himmel/config.json could not
// be read" — shared by applyLunaSectionsStep and previewLunaSections so the
// two can never drift on how this refusal is named. A malformed config is a
// FATAL, section-wide refusal on the apply side (see applyLunaSectionsStep's
// own early return below); the preview must report the identical refusal
// rather than manufacturing a default document to plan cadence/secrets/
// bridge actions against.
function lunaConfigLoadFailureWarning(e) {
  return `himmelctl: WARN: could not read ~/.himmel/config.json (${e.message}) — luna cadence/secrets/bridge sections skipped`;
}

// HIMMEL-2347: phi-roots location, mirroring graph-refresh.sh:75/refresh-
// graph-map.sh's own $HOME/.config/claude-glm — CLAUDE_GLM_CONFIG_DIR
// overrides (graph-refresh.sh honors it; refresh-graph-map.sh hardcodes
// $HOME instead, a PRE-EXISTING quirk of that consumer, not something this
// ticket touches). $HOME first, then os.homedir(), same convention as
// expandHome() above (tests fake $HOME; os.homedir() alone reads USERPROFILE
// on win32 and does not honor a bash-level HOME= override for a node child).
function phiRootsPath() {
  const dir = process.env.CLAUDE_GLM_CONFIG_DIR || path.join(process.env.HOME || os.homedir(), '.config', 'claude-glm');
  return path.join(dir, 'phi-roots');
}

// Merge `root` (an absolute path) into the phi-roots list file: append-if-
// absent, LF-only (HIMMEL-1680 class — graph-refresh.sh/refresh-graph-
// map.sh's own consumers read this line-wise, including on this Windows
// host). MERGE RULE: never truncate/rewrite entries an operator or another
// tool put there — an existing file is read first and every line preserved,
// only a genuinely new (not-already-present) root is appended. An existing
// CRLF-saved file is read tolerantly (both readers already strip a trailing
// \r themselves — graph-refresh.sh:228/refresh-graph-map.sh:228's own
// `%$'\r'` — so this rewrite normalizing to bare LF changes nothing they
// read; the split below already drops that \r before either side of the
// comparison sees a line). BOTH sides of the comparison get the SAME
// normalization — see the dedupe comment below for the rule and why it must
// be symmetric.
function mergePhiRoot(root) {
  const file = phiRootsPath();
  // HIMMEL-2347 CR fix 8 (round 4): a trailing path separator is not
  // semantically significant ("/vault/" and "/vault" name the same
  // directory) so it is stripped on BOTH the incoming `root` and each
  // stored line before comparing — round 3 stripped it on the stored side
  // only, which meant a root declared with a trailing separator matched
  // nothing already stored and got appended again on every run
  // (unbounded growth). Whitespace, by contrast, IS significant in a POSIX
  // path ("/vault " and "/vault" are different directories) so it is never
  // trimmed on either side — round 3's `.trim()` on the stored side alone
  // let a stored "/vault " falsely swallow a genuinely distinct incoming
  // "/vault", the opposite failure. The one whitespace-shaped exception is
  // a trailing \r, but that is a CRLF storage artifact, not part of the
  // path, and the CRLF-tolerant split above already strips it before this
  // function ever sees the line. Stripping trailing separators must not
  // collapse a line to '' either (a lone "/" or a drive root like "C:\"
  // would then spuriously match a blank line) — keep the original whenever
  // stripping would empty it out.
  const normPath = (s) => {
    const stripped = s.replace(/[\\/]+$/, '');
    return stripped === '' ? s : stripped;
  };
  let lines = [];
  try {
    lines = fs.readFileSync(file, 'utf8').split(/\r\n|\r|\n/);
    if (lines.length && lines[lines.length - 1] === '') lines.pop();
  } catch (e) {
    // HIMMEL-2347 CR: only ENOENT means "no file yet, start empty" — any
    // other read failure (EACCES/EISDIR/EIO/a transient lock) must NOT fall
    // through to the rewrite below, which would treat "couldn't read it" as
    // "it's empty" and discard every already-recorded PHI root. Throw so the
    // caller sees the declaration was not recorded, never truncate here.
    if (e.code !== 'ENOENT') {
      throw new Error(`could not read ${file}: ${e.message}`);
    }
    lines = [];
  }
  const already = lines.some((l) => normPath(l) === normPath(root));
  if (already) {
    // HIMMEL-2347 CR fix 9 (round 4): nothing to add means the file's
    // content would come out byte-identical, so return before any write —
    // a tmp+rename for a no-op replay was pointless I/O, needlessly bumped
    // the file's metadata, and could fail outright against an otherwise
    // perfectly readable read-only phi-roots even though there was nothing
    // to do.
    return { file: file, added: false };
  }
  lines.push(root);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  // HIMMEL-2347 CR fix 7: an in-place synchronous write (what fix 3 below
  // replaced with a tmp+rename) preserves the target's existing mode; a
  // freshly-created tmp file does not, so without this the rename would
  // silently WIDEN phi-roots to the default mode — a real weakening, since
  // this file enumerates a personal/medical vault's locations and drives
  // the egress guards. Capture the pre-existing mode (ENOENT here just
  // means this is the first declaration — nothing to preserve) and
  // re-apply it to tmp before the rename carries it onto `file`.
  // Best-effort on Windows only: chmodSync there only maps to the
  // read-only attribute from the POSIX write bits — it does not restore
  // Windows ACLs, and there is no mechanism here that does.
  let mode = null;
  try {
    mode = fs.statSync(file).mode;
  } catch (e) {
    mode = null;
  }
  // HIMMEL-2347 CR fix 3: write to a sibling tmp file, then rename() it over
  // `file` — rename within a directory is atomic on both POSIX and Windows,
  // so an interruption mid-write can never leave phi-roots truncated or
  // partial. Same tmp+rename+cleanup-on-failure shape as
  // writeMarkedLauncher() below (reused convention, not a new one).
  //
  // This fixes ONLY the torn-write half. It does NOT fix the concurrency
  // race: two processes can still both read the same stale list and the
  // last rename() still wins, so a root added by a concurrent process can
  // still be lost. That half is deliberately OUT of scope here and tracked
  // separately as HIMMEL-2416 — do not read this atomic write as closing it.
  //
  // HIMMEL-2347 CR fix 10 (round 4): create tmp owner-only (mode 0o600) from
  // the very first write, not via a chmod afterward — a default-mode create
  // followed by a later chmod leaves the sensitive list briefly
  // world/group-readable under a permissive umask. When `file` already
  // existed its mode is re-applied over this default right below, same as
  // before; when this is the first-ever phi-roots (mode === null, nothing
  // to preserve) that owner-only create IS the permanent result, in place
  // of whatever the platform default would otherwise have been.
  const tmp = path.join(path.dirname(file), `.${path.basename(file)}.${process.pid}.tmp`);
  try {
    fs.writeFileSync(tmp, lines.join('\n') + '\n', { mode: 0o600 });
    // If this throws, the catch below discards tmp and the whole merge
    // fails loudly — never rename a wider-than-original file into place.
    if (mode !== null) fs.chmodSync(tmp, mode);
    fs.renameSync(tmp, file);
  } catch (e) {
    try { fs.unlinkSync(tmp); } catch (_e) { /* best-effort tmp cleanup */ }
    throw e;
  }
  return { file: file, added: true };
}

// A17 (RETASK stage1-build-6d2e [codex-2]): "a failed readiness probe blocks
// ONLY bridge arming" means exactly that — installSystemdUnit's own
// `systemctl --user enable --now` (and the Windows scheduled-task
// equivalent) IS arming, so it must not run while any of the three probes
// reads anything other than 'present'.
function bridgeProbesHealthy(bridgeProbes) {
  return ['whisperReady', 'pythonInterpreter', 'distinctTokens'].every((k) => {
    const r = bridgeProbes && bridgeProbes[k];
    return Boolean(r) && r.actual === 'present';
  });
}

function currentOsUser() {
  try {
    return os.userInfo().username;
  } catch (_e) {
    return process.env.USER || process.env.USERNAME || '';
  }
}

// A12/S6 (RETASK stage1-build-6d2e [codex-3]/[codex-6]): Linux persistence is
// the systemd unit AND linger — a unit with no linger stops at logout and S6
// reports it degraded, so linger is its own consented step here, never
// implied. Windows uses the scheduled logon task bridge-persistence.js ships
// (installWindowsLogonTask, same {ok,actions,detail} contract as the
// systemd primitives) — this used to unconditionally call the Linux-only
// installSystemdUnit and report rc=1 for TRYING on Windows, himmel's primary
// platform, even though scripts/telegram/install-logon-task.ps1 already
// implements the capability; it was simply unwired. A platform that is
// neither: never claim success — report still-manual instead.
function attemptBridgePersistence({ dryRun }) {
  if (process.platform === 'win32') {
    if (typeof bridgePersistenceLib.installWindowsLogonTask !== 'function') {
      return { ok: false, actions: [], detail: 'bridge-persistence.js does not export installWindowsLogonTask on this checkout — install the scheduled task manually via scripts/telegram/install-logon-task.ps1' };
    }
    return bridgePersistenceLib.installWindowsLogonTask({ repoRoot: repoRoot(), dryRun: dryRun });
  }
  if (process.platform === 'linux') {
    const unit = bridgePersistenceLib.installSystemdUnit({ repoRoot: repoRoot(), dryRun: dryRun });
    if (!unit.ok) return unit;
    const user = currentOsUser();
    const linger = bridgePersistenceLib.enableLinger({ user: user, dryRun: dryRun });
    if (linger.ok) {
      return { ok: true, actions: unit.actions.concat(linger.actions), detail: `${unit.detail}; ${linger.detail}` };
    }
    // RETASK stage1-build-6d2e round 6 [codex-4]: unit.ok is true here — the
    // unit IS installed and running (enable --now already happened inside
    // installSystemdUnit) — only linger failed. Do NOT attempt an automatic
    // rollback (unwinding machine state on a partial failure is its own
    // risk; this design's posture is honest reporting over clever
    // recovery). `partial:true` lets buildSummary say plainly what IS true
    // (unit running) and what is NOT (linger, so it stops at logout),
    // rather than folding this into the same "NOT installed" wording a
    // total failure gets — that would be false for the half that worked.
    return {
      ok: false,
      partial: true,
      actions: unit.actions.concat(linger.actions),
      detail: `unit installed and RUNNING (${unit.detail}); linger NOT enabled — ${linger.detail}. The bridge will stop at the next logout. Remediation: loginctl enable-linger ${user || '<user>'}`,
    };
  }
  return { ok: false, actions: [], detail: `bridge persistence has no installer for platform '${process.platform}' — install/enable it manually (see docs/setup)` };
}

// HIMMEL-2308: universal now (the old role==='adopter' gate died with role —
// luna/secretsWalk/bridge are gated by whether the sections were actually
// SUPPLIED, via lunaSectionSupplied()/bridgeSectionSupplied() below, which
// already covers "never asked" correctly for every profile/flow).
function previewLunaSections(answers) {
  try {
    const lunaSupplied = lunaSectionSupplied(answers);
    const bridgeSupplied = bridgeSectionSupplied(answers);
    const luna = answers.luna || {};
    const secretsWalk = answers.secretsWalk || 'skip';
    const bridge = answers.bridge || {};
    let doc;
    try {
      doc = lunaConfigLib.load();
    } catch (e) {
      // CR fix: applyLunaSectionsStep refuses ALL cadence/secrets/bridge
      // work on a load failure (see its own early return) — manufacturing a
      // default document here to keep planning against previewed actions
      // the apply step will never perform, so the preview must report the
      // same refusal instead and stop, exactly like the apply path does.
      console.error(lunaConfigLoadFailureWarning(e));
      return { configLoadFailed: true };
    }
    const vaultPath = (answers.vault && answers.vault.mode !== 'none' && answers.vault.path)
      ? expandHome(answers.vault.path)
      : doc.luna.vaultPath;
    if (answers.vault && answers.vault.mode !== 'none' && answers.vault.path) {
      console.log(`DRY: luna.vaultPath -> ${vaultPath} (~/.himmel/config.json)`);
    }
    if (lunaSupplied) {
      console.log(`DRY: luna.phi.declared -> ${Boolean(luna.phiDeclared)} (~/.himmel/config.json)`);
      // HIMMEL-2347: materializing the guard inputs is its own preview line,
      // independent of phi.declared's own true/false — the phi-roots entry
      // and the .salus offer only exist when a vault path was actually
      // declared (phiVaultAns==='yes' + a non-blank path in askQuestions()).
      if (luna.phiVaultPath) {
        const phiVaultAbs = expandHome(luna.phiVaultPath);
        console.log(`DRY: phi-roots -> append ${phiVaultAbs} (${phiRootsPath()})`);
        if (luna.createSalusMarker) {
          console.log(`DRY: .salus marker -> ${path.join(phiVaultAbs, '.salus')} (created only if the vault path exists at apply time)`);
        }
      }
    } else {
      console.log('DRY: profile carries no luna section — luna.phi.declared would be left untouched on disk');
    }
    // HIMMEL-2302: per-cadence dispositions replace the old single
    // lunaSupplied+cadenceEnabled gate — resolveCadenceDispositions() covers
    // both a fresh `cadences` section (authoritative) and a legacy profile
    // that only ever carried `luna.cadenceEnabled` (derives pipeline only).
    const dispositions = adopterProfileLib.resolveCadenceDispositions(answers);
    if (dispositions.pipeline !== undefined) {
      console.log(`DRY: luna.cadence.enabled -> ${dispositions.pipeline === 'armed'} (~/.himmel/config.json)`);
    } else {
      console.log('DRY: no cadence answer this run — luna.cadence.enabled would be left untouched on disk');
    }
    for (const row of CADENCE_REGISTRY) {
      const disp = dispositions[row.id];
      if (disp === 'armed') {
        try {
          const flags = cadenceArmFlags(row.id, { doc: doc, vaultPath: vaultPath });
          console.log(`DRY: bash ${cadenceScriptPath(row.id)} arm${flags.length ? ` ${flags.join(' ')}` : ''}`);
        } catch (e) {
          console.log(`DRY: ${row.id} cadence arm — WOULD FAIL: ${e.message}`);
        }
      } else if (disp === 'off' && luna.disarmCadence) {
        // [codex-1] the consented disarm step, shown by --dry-run exactly
        // like bridge persistence's own consented install preview above/below.
        console.log(`DRY: bash ${cadenceScriptPath(row.id)} disarm`);
      }
    }
    if (secretsWalk === 'run') {
      const { scoped, skipped } = scopeSecretsByFeature(answers);
      console.log(`DRY: secrets walk — would show the instruction card + probe for ${scoped.length} secret(s)`);
      const line = scopedOutLine(skipped);
      if (line) console.log(`DRY:${line}`);
    }
    if (!bridgeSupplied) {
      console.log('DRY: profile carries no bridge section — bridge.* would be left untouched on disk');
    } else if (bridge.enabled) {
      console.log(`DRY: bridge config -> envPath=${bridge.envPath}, whisper.cli=${bridge.whisperCli || '(default)'}, whisper.model=${bridge.whisperModel} (~/.himmel/config.json)`);
      console.log('DRY: bridge readiness probes (cmd:whisper_ready, cmd:python_interpreter, distinct-tokens) — would run; a failed probe skips arm/enable, never aborts the install');
      if (bridge.installPersistence) {
        const r = attemptBridgePersistence({ dryRun: true });
        for (const a of r.actions) console.log(`DRY: ${a}`);
        console.log('DRY: bridge persistence/arm would run ONLY if the readiness probes above are green at apply time');
      }
    }
  } catch (e) {
    console.error(`himmelctl: WARN: luna/secrets/bridge dry-run preview failed (${e && e.message ? e.message : e}) — preview skipped, this is informational only`);
  }
}

// The real apply step — called AFTER the core install succeeds (same
// positioning as applyPluginStep), non-fatal: a failure here WARNs and the
// install still completes. Returns { rc, cadenceArm, secretsWalkResults,
// bridgeProbes, bridgePersistence } — rc is OR'd into the overall exit code
// the same way pluginResult.rc already is, never on its own aborting
// anything upstream (this function runs after adopt.sh/setup.sh already
// exited 0).
function applyLunaSectionsStep(answers) {
  const lunaSupplied = lunaSectionSupplied(answers);
  const bridgeSupplied = bridgeSectionSupplied(answers);
  const luna = answers.luna || {};
  const secretsWalk = answers.secretsWalk || 'skip';
  const bridge = answers.bridge || {};
  const result = { rc: 0 };

  let doc;
  try {
    doc = lunaConfigLib.load();
  } catch (e) {
    console.error(lunaConfigLoadFailureWarning(e));
    result.rc = 1;
    // CR fix: this early return means `result.configSaveOk` is never set at
    // all (the save step below never runs) — buildSummary's own comment
    // treats undefined configSaveOk as "not gated" (true), which used to let
    // the bridge-config claim in `installed:` survive a load failure it
    // never actually persisted. `configLoadFailed` is the same signal
    // previewLunaSections' --dry-run sets on the identical refusal, so
    // buildSummary's one gate on it covers both call sites.
    result.configLoadFailed = true;
    return result;
  }
  // RETASK stage1-build-6d2e round 6 [codex-1]: snapshot BEFORE any field
  // writes below, so a legacy/no-op replay (nothing supplied, nothing
  // changed) can skip save() entirely rather than rewriting — or CREATING —
  // ~/.himmel/config.json for a run that touched nothing. `doc`'s key order
  // never changes (only existing fields are ever reassigned, never added/
  // removed), so a plain JSON.stringify comparison is exact — no need for a
  // deep-equal dependency for a shape this controlled.
  const originalDocJson = JSON.stringify(doc);

  if (answers.vault && answers.vault.mode !== 'none' && answers.vault.path) {
    doc.luna.vaultPath = expandHome(answers.vault.path);
  }
  // [codex-1] only write a field the profile ACTUALLY supplied — an absent
  // section/answer is left exactly as loaded, never coerced to
  // Boolean(undefined).
  if (lunaSupplied) {
    doc.luna.phi.declared = Boolean(luna.phiDeclared);
    // HIMMEL-2347: materialize the guard inputs a declared personal/medical
    // vault path implies. Independent of phi.declared above (a SEPARATE
    // vault from the one being installed) and of configSaveOk below (these
    // two files are not tracked inside ~/.himmel/config.json at all, so a
    // save() failure there creates no drift risk for them — see
    // buildAnswers' round-8 comment for the class of bug that reasoning
    // guards against elsewhere). Only runs when a path was actually
    // declared; "not asked"/"declined" both leave phiVaultPath undefined
    // (askQuestions()'s own comment), so this is a no-op for either.
    if (luna.phiVaultPath) {
      const phiVaultAbs = expandHome(luna.phiVaultPath);
      let merged;
      try {
        merged = mergePhiRoot(phiVaultAbs);
      } catch (e) {
        // HIMMEL-2347 CR: mergePhiRoot() now throws instead of silently
        // treating a genuine read failure (EACCES/EISDIR/a lock) as "empty
        // file" — a fall-through there would have rewritten phi-roots and
        // discarded every already-recorded root. Surface it loudly (rc=1,
        // surfaced via the pluginResult.rc||lunaResult.rc caller return) and
        // skip the marker block below — we don't know whether this root
        // ended up recorded, so don't act as if it did.
        console.error(`himmelctl: WARN: could not update phi-roots for ${phiVaultAbs}: ${e.message} — PHI root NOT recorded; existing entries left untouched`);
        result.rc = 1;
        merged = null;
      }
      if (merged) {
        console.log(`himmelctl: ${merged.added ? 'added' : 'already present'} ${phiVaultAbs} in ${merged.file}`);
        if (luna.createSalusMarker) {
          if (fs.existsSync(phiVaultAbs)) {
            const markerPath = path.join(phiVaultAbs, '.salus');
            // HIMMEL-2347 CR: 'wx' is exclusive-create — never touches an
            // existing marker's contents (an unconditional writeFileSync
            // truncated a marker that already carried an operator note or
            // another tool's metadata). The guards only check existence
            // ([ -e "$d/.salus" ]), so an existing marker needs no rewrite.
            try {
              fs.writeFileSync(markerPath, '', { flag: 'wx' });
              console.log(`himmelctl: created ${markerPath}`);
            } catch (e) {
              if (e.code === 'EEXIST') {
                // Already present is success — the marker exists, which is
                // all the guards check for ([ -e "$d/.salus" ]).
                console.log(`himmelctl: .salus marker already present at ${markerPath} — left untouched`);
              } else {
                // HIMMEL-2347 CR fix 2: a genuine creation failure
                // (permissions, read-only mount, etc.) after the operator
                // explicitly CONSENTED to the marker must not exit 0 — same
                // treatment as the phi-roots write failure above
                // (result.rc = 1). Leaving this a bare WARN meant a
                // requested PHI marker could silently not exist with a
                // green run, exactly the "guard looks armed but isn't"
                // failure mode this ticket exists to close.
                console.error(`himmelctl: WARN: could not create .salus marker at ${phiVaultAbs}: ${e.message}`);
                result.rc = 1;
              }
            }
          } else {
            // Design constraint (HIMMEL-2347 brief): a not-yet-created vault is
            // not a reason to drop the declaration — phi-roots above is
            // written regardless; only the marker (which requires the
            // directory to exist) is deferred, reported honestly rather than
            // silently skipped. CR fix 2: this stays rc=0 deliberately — it
            // is NOT a failure to create something that was never attempted
            // (existing PV5 test pins rc=0 here); only a genuine creation
            // error in the branch above sets result.rc = 1.
            console.log(`himmelctl: vault path ${phiVaultAbs} does not exist yet — .salus marker NOT created; create it manually once the vault exists (the phi-roots declaration above is recorded regardless)`);
          }
        }
      }
    }
  } else {
    console.log('himmelctl: profile carries no luna section — luna.phi.declared left untouched on disk');
  }
  // HIMMEL-2302: luna.cadence.enabled mirrors pipeline's resolved
  // disposition — decoupled from lunaSupplied (unlike phi.declared just
  // above) because a `cadences`-only profile with NO `luna` section at all
  // (the operator-capture shape — docs/setup/profiles/operator.install-
  // profile.json) can still legitimately arm pipeline; resolveCadenceDispositions()
  // is the one shared place that covers both shapes (see its own comment).
  const dispositions = adopterProfileLib.resolveCadenceDispositions(answers);
  if (dispositions.pipeline !== undefined) {
    doc.luna.cadence.enabled = dispositions.pipeline === 'armed';
  } else {
    console.log('himmelctl: no cadence answer this run — luna.cadence.enabled left untouched on disk');
  }
  if (bridgeSupplied) {
    doc.bridge.enabled = Boolean(bridge.enabled);
    if (bridge.enabled) {
      // Explicit acceptance (task brief): bridge.envPath/whisper.{cli,model}
      // are otherwise-inert schema fields — write the operator's actual
      // chosen/defaulted values so the round-trip is real, not just defined.
      doc.bridge.envPath = bridge.envPath;
      doc.bridge.whisper.cli = bridge.whisperCli || null;
      doc.bridge.whisper.model = bridge.whisperModel;
    }
  } else {
    console.log('himmelctl: profile carries no bridge section — bridge.* left untouched on disk');
  }

  // RETASK stage1-build-6d2e round 4 [codex-3]: a save() failure must stop
  // every SUBSEQUENT machine-state mutation (cadence arm/disarm, bridge
  // persistence install) — otherwise the machine ends up in a state the
  // config document never recorded, the exact drift S1/S6 exist to detect.
  // Pure REPORTING (secrets walk, bridge readiness probes) still runs below:
  // neither mutates anything, and the operator still deserves the read-only
  // information even when the write failed.
  //
  // RETASK stage1-build-6d2e round 6 [codex-1]: `docChanged` gates the write
  // itself — a legacy profile (nothing supplied) or an unchanged replay
  // leaves the file untouched (no rewrite, no mtime bump, and critically no
  // CREATE when it didn't already exist), matching the "left untouched on
  // disk" lines just printed above. `configSaveOk` stays true for a skipped-
  // because-unchanged write: nothing failed, there is simply nothing to
  // record that the on-disk document doesn't already say — downstream steps
  // proceed exactly as if the (unnecessary) save had succeeded.
  const docChanged = JSON.stringify(doc) !== originalDocJson;
  let configSaveOk = true;
  if (!docChanged) {
    console.log('himmelctl: ~/.himmel/config.json unchanged — nothing to write');
  } else {
    try {
      lunaConfigLib.save(doc);
      console.log('himmelctl: wrote ~/.himmel/config.json (luna.vaultPath'
        + (dispositions.pipeline !== undefined ? ', luna.cadence.enabled' : '')
        + (lunaSupplied ? ', luna.phi.declared' : '')
        + (bridgeSupplied ? ', bridge.*' : '') + ')');
    } catch (e) {
      console.error(`himmelctl: WARN: failed to save ~/.himmel/config.json: ${e.message}`);
      console.error('himmelctl: WARN: skipping luna cadence arm/disarm and bridge persistence install — refusing to mutate machine state that the config document could not record');
      configSaveOk = false;
      result.rc = 1;
    }
  }
  result.configSaveOk = configSaveOk;

  // HIMMEL-2302: arm/disarm EVERY unit with an actual disposition this run —
  // pipeline keeps the exact single-unit behavior above (same gating, same
  // spawn), generalized to qmd/graphmap/codex-sweep via the registry.
  // disarm stays gated on `luna.disarmCadence` (decision #5: ONE consent
  // question covers every declined unit — no per-unit disarm consent).
  if (configSaveOk) {
    for (const row of CADENCE_REGISTRY) {
      const disp = dispositions[row.id];
      if (disp === 'armed') {
        try {
          const flags = cadenceArmFlags(row.id, { doc: doc, vaultPath: doc.luna.vaultPath });
          const argv = [resolveBash(), toBashPath(cadenceScriptPath(row.id)), 'arm'].concat(flags);
          const cmd = { argv: argv };
          const armRc = runSpawn(cmd);
          result.cadenceResults = result.cadenceResults || {};
          result.cadenceResults[row.id] = { ran: true, rc: armRc, argvDisplay: displayCommand(cmd) };
          if (armRc !== 0) result.rc = 1;
        } catch (e) {
          console.error(`himmelctl: WARN: ${row.id} cadence arm failed: ${e.message}`);
          result.cadenceResults = result.cadenceResults || {};
          result.cadenceResults[row.id] = { ran: false, rc: 1, argvDisplay: e.message };
          result.rc = 1;
        }
      } else if (disp === 'off' && luna.disarmCadence) {
        // [codex-1] the ONE explicit-consent path that actually disarms —
        // reached only when the operator both declined this unit AND opted
        // into the disarm question. `<script> disarm` is idempotent (rc=0
        // "nothing armed" when there was nothing to remove).
        try {
          const argv = [resolveBash(), toBashPath(cadenceScriptPath(row.id)), 'disarm'];
          const cmd = { argv: argv };
          const disarmRc = runSpawn(cmd);
          result.cadenceDisarmResults = result.cadenceDisarmResults || {};
          result.cadenceDisarmResults[row.id] = { ran: true, rc: disarmRc, argvDisplay: displayCommand(cmd) };
          if (disarmRc !== 0) result.rc = 1;
        } catch (e) {
          console.error(`himmelctl: WARN: ${row.id} cadence disarm failed: ${e.message}`);
          result.cadenceDisarmResults = result.cadenceDisarmResults || {};
          result.cadenceDisarmResults[row.id] = { ran: false, rc: 1, argvDisplay: e.message };
          result.rc = 1;
        }
      }
    }
  }

  if (secretsWalk === 'run') {
    console.log('');
    console.log('── secrets walk (instruction card + probe; himmelctl never harvests the value) ──');
    result.secretsWalkResults = runSecretsWalk(bridge, answers);
  }

  if (bridgeSupplied && bridge.enabled) {
    // Read-only reporting — runs regardless of configSaveOk (codex-3: only
    // the MUTATING step below is gated).
    result.bridgeProbes = runBridgeReadinessProbes(bridge);
    if (bridge.installPersistence) {
      // [codex-2] a failed readiness probe skips the arm/enable step
      // entirely (never calls into systemctl/schtasks) — it still does NOT
      // abort the overall install (A17), it just means persistence isn't
      // installed yet; reported honestly below.
      //
      // RETASK stage1-build-6d2e round 3: rc stays 0 for the DELIBERATE skip
      // — refusing to arm an unready bridge is the designed, correct
      // behaviour (codex-2's own ask), not a failure, and the coordinator's
      // ruling draws the same line A15 already draws for an unconfigured
      // secret: "reports unconfigured, not error". `rc` is what a scripted/
      // unattended install reads — turning an expected, fully-reported state
      // (still-manual) into a nonzero exit would make "voice tooling isn't
      // installed yet" read as an install FAILURE. An actual attempt that
      // comes back ok:false (the installer ran and failed) is a real
      // failure and keeps rc=1 — `skipped:true` is what tells the two apart,
      // both in this result and in buildSummary's rendered text.
      if (!configSaveOk) {
        result.bridgePersistence = {
          ok: false,
          skipped: true,
          actions: [],
          detail: 'skipped — the config save above failed; refusing to install persistence for a bridge config that was never recorded (fix the save error, then re-run install)',
        };
      } else if (bridgeProbesHealthy(result.bridgeProbes)) {
        // RETASK stage1-build-6d2e round 6: attemptBridgePersistence's own
        // primitives are contracted to return {ok,actions,detail} rather
        // than throw, but this is a machine-state MUTATION, not a read —
        // an unexpected throw here must never crash the rest of the apply
        // step (or the "declared but never ran"/exception-mid-step class
        // this whole retask thread is about resurfaces one layer up).
        try {
          result.bridgePersistence = attemptBridgePersistence({ dryRun: false });
        } catch (e) {
          result.bridgePersistence = { ok: false, actions: [], detail: `bridge persistence attempt threw: ${e && e.message ? e.message : e}` };
        }
        if (!result.bridgePersistence.ok) result.rc = 1;
      } else {
        result.bridgePersistence = {
          ok: false,
          skipped: true,
          actions: [],
          detail: 'skipped — one or more bridge readiness probes (whisper/python/distinct-tokens) is not green; see the probe rows above. Persistence/arm was NOT attempted (A17: a failed probe blocks arming, never the whole install).',
        };
      }
    }
  }

  return result;
}

// HIMMEL-862: the epilogue — lane probe report, the always-on hardening
// CHECKLIST, and the final honest summary. Printed at the END of EVERY run
// now (HIMMEL-2308 killed the old role==='adopter' gate — see
// printAdopterEpilogue below), dry-run included: every part of it is a READ —
// it mutates nothing — so it is equally truthful before and after the install
// shell-out, and a --dry-run preview is worth exactly as much. (Corrected in
// CR round 5: this used to claim "probeLane never spawns", which is false —
// buildCtx shells out to `git`, and the manifest-backed readiness probes may
// run a tool to check it. Probing under --dry-run is fine; documenting a
// guarantee we do not provide is not.)
//
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
// HIMMEL-2308: the dev-overlay's own report — printed only when
// answers.devOverlay is true (the --contribute flag), IN ADDITION to the
// universal epilogue below (printAdopterEpilogue), not instead of it.
async function printContributorProfile(answers, derived, dryRun) {
  if (!answers.devOverlay) return;
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

// HIMMEL-2536: what the git gate hooks ACTUALLY look like on disk after
// adopt.sh (and, for a dev overlay, setup.sh) has run against $PWD — adopt.sh's
// own --target default, the same resolution settingsPathForScope() mirrors.
//
// WHY a filesystem probe rather than reading adopt.sh's output: adopt.sh runs
// with stdio inherited, so its `WARNING: git hooks: ... — skipping.` line is
// never available to this process. It is also the wrong source of truth. The
// measured HIMMEL-2536 failure was the summary claiming `still manual:
// (nothing)` in the same run whose scrollback carried that warning, and the
// ticket's own principle is that still-manual must be derived from what
// actually ran. Hooks on disk are what actually ran.
//
// Uses `git rev-parse --git-path hooks` rather than `<target>/.git/hooks`
// because a linked worktree's `.git` is a FILE: hooks live in the SHARED
// common dir and are run by every worktree, so the literal join finds nothing
// and would report every worktree install as ungated. That resolution is also
// exactly what pre-commit itself installs into.
//
// CR round 1 [codex-2]: a git probe that FAILS is not the same fact as a
// non-repo target, so the two no longer collapse to one return shape. An
// unverifiable state is reported as unverifiable — silently suppressing the
// warning is the failure mode this whole function exists to remove.
function gitGateHooksState() {
  const target = process.cwd();
  // Mirrors adopt.sh's own `[[ ! -e "$TARGET/.git" ]]` guard: a non-repo
  // target is not a skipped step, it is a step that does not apply, and
  // adopt.sh says so plainly. Nothing to carry into still-manual.
  if (!fs.existsSync(path.join(target, '.git'))) return { applicable: false };
  const r = spawnSync('git', ['rev-parse', '--git-path', 'hooks'], { cwd: target, encoding: 'utf8' });
  if (r.error || r.status !== 0 || !r.stdout) {
    return { applicable: true, verified: false, reason: 'git rev-parse --git-path hooks failed' };
  }
  const hooksDir = path.resolve(target, r.stdout.trim());
  // The three hook types adopt.sh's install_precommit_hooks() wires.
  const wanted = ['pre-commit', 'commit-msg', 'pre-push'];
  const missing = wanted.filter((h) => !gitWouldRunHook(path.join(hooksDir, h)));
  return { applicable: true, verified: true, placed: missing.length === 0, missing: missing };
}

// CR round 1 [codex-1]: "the path exists" is not "git will run it". A
// directory, a dangling entry, or a non-executable leftover at
// .git/hooks/commit-msg all satisfy an existence check while git runs
// nothing — which would let this summary certify a repo as gated when it is
// not, the exact false-clean HIMMEL-2536 is about. Require what git itself
// requires: a regular file, and on POSIX the executable bit (git-for-windows
// runs hooks through sh and ignores the mode, so demanding it there would
// report every Windows install ungated).
function gitWouldRunHook(hookPath) {
  let st;
  try {
    st = fs.statSync(hookPath);
  } catch (_e) {
    return false;
  }
  if (!st.isFile()) return false;
  if (process.platform === 'win32') return true;
  return (st.mode & 0o111) !== 0;
}

// HIMMEL-2537: did the dev overlay's setup.sh step [0.5/9] leave USER_SLUG
// unresolved? That step used to `exit 1`, which aborted runPlan before this
// epilogue ever ran — the summary could not have been wrong because there was
// no summary. Now that it is advisory, the silence becomes possible, and a
// summary that reports nothing left undone while the slug is unset is the
// HIMMEL-2536 defect on a different step.
//
// A REPLAY of the same check rather than a parse of setup.sh's output, for
// 2536's reason: the overlay runs with stdio inherited, so its lines never
// reach this process. Replayed with cwd = repoRoot(), which is where setup.sh
// ran it — the forge source resolves against the checkout's own origin, so a
// probe from the adopter's target dir could disagree with the step it reports on.
//
// --dotenv-root repoRoot() (CR round 2 [codex-1]): without it, this replay
// ignores a USER_SLUG a step [5/9] --fill-env prompt just wrote to .env, and
// disagrees with setup.sh's own footer re-probe (which passes the same flag)
// — the two summaries are supposed to agree on the same fact.
//
// Gated on the overlay having run (see the call site): adopt.sh alone never
// resolves a slug, so for a non-overlay install there is no skipped step to
// name. On win32 the overlay is setup.ps1, which has no USER_SLUG step at all.
function userSlugState() {
  if (process.platform === 'win32') return { applicable: false };
  const script = path.join(repoRoot(), 'scripts', 'setup', 'check-user-slug.sh');
  if (!fs.existsSync(script)) {
    return { applicable: true, verified: false, reason: 'scripts/setup/check-user-slug.sh not found' };
  }
  const r = spawnSync(resolveBash(), [toBashPath(script), '--dotenv-root', toBashPath(repoRoot())], { cwd: repoRoot(), encoding: 'utf8' });
  // 0 = resolved, 3 = advised. Any other status (or a spawn error) means the
  // probe broke, which is not the same fact as an unresolved slug.
  if (r.error || (r.status !== 0 && r.status !== 3)) {
    const why = r.error ? r.error.message : `exited rc=${r.status}`;
    return { applicable: true, verified: false, reason: `check-user-slug.sh ${why}` };
  }
  return { applicable: true, verified: true, resolved: r.status === 0 };
}

// HIMMEL-2308: universal now — printed for every run regardless of
// profile/devOverlay (the old role==='adopter' gate died with role).
async function printAdopterEpilogue(answers, derived, dryRun, pluginResult, vaultScaffolded, lunaResult) {
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

  // HIMMEL-2300: an adopter run always asks alwaysOn (askQuestions()), so this
  // branch only matters for a hand-edited/legacy --from-profile that omits
  // the now-optional field — never claim "you answered no" for a question
  // this profile carries no answer to.
  const alwaysOnSupplied = answers.alwaysOn !== undefined && answers.alwaysOn !== null;
  const hardening = !alwaysOnSupplied
    ? adopterProfileLib.hardeningNotAskedLines()
    : answers.alwaysOn
      ? adopterProfileLib.hardeningChecklistLines(process.platform)
      : adopterProfileLib.hardeningPointerLines();
  for (const line of hardening) console.log(line);

  const lr = lunaResult || {};
  const summary = adopterProfileLib.buildSummary(answers, rows, {
    derived: derived,
    dryRun: Boolean(dryRun),
    pluginFailures: pluginResult ? pluginResult.failed : null,
    vaultScaffolded: vaultScaffolded !== false,
    pluginTotal: pluginResult ? pluginResult.total : 0,
    vaultPath: answers.vault && answers.vault.path ? expandHome(answers.vault.path) : '',
    handoverPath: answers.handover && answers.handover.path ? expandHome(answers.handover.path) : '',
    // HIMMEL-2176 Task 8: luna cadence / secrets walk / bridge results —
    // undefined under --dry-run (nothing was actually run) or when the
    // section is off, both handled by buildSummary's own dryRun/`did()`
    // tense branching.
    // HIMMEL-2302: per-cadence-unit results ({<id>: {ran,rc,argvDisplay}}) —
    // replaces the pipeline-only cadenceArm/cadenceDisarm singular fields.
    cadenceResults: lr.cadenceResults,
    cadenceDisarmResults: lr.cadenceDisarmResults,
    secretsWalkResults: lr.secretsWalkResults,
    bridgeProbes: lr.bridgeProbes,
    bridgePersistence: lr.bridgePersistence,
    // RETASK stage1-build-6d2e round 6 [codex-2]: undefined under --dry-run
    // (save() never runs there at all) — buildSummary treats undefined the
    // same as true (only an explicit `false` gates a claim), so a dry-run
    // preview is unaffected.
    configSaveOk: lr.configSaveOk,
    // CR fix: previewLunaSections() sets this on a --dry-run whose
    // ~/.himmel/config.json failed to load — buildSummary must not then
    // claim cadence/secrets/bridge as `planned` for a load that never
    // succeeded (applyLunaSectionsStep performs none of that work either).
    configLoadFailed: lr.configLoadFailed,
    // HIMMEL-2536: null under --dry-run — this epilogue also renders the
    // PREVIEW, which runs before adopt.sh has been spawned at all, so a probe
    // there would report the hooks the machine happened to already have.
    gitHooks: dryRun ? null : gitGateHooksState(),
    // HIMMEL-2537: null when nothing resolved a slug — a --dry-run (the
    // preview renders through this same epilogue, before anything is spawned)
    // or an install with no dev overlay, whose adopt.sh never runs the check.
    userSlug: (dryRun || !answers.devOverlay) ? null : userSlugState(),
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

// HIMMEL-2308/HIMMEL-2300/HIMMEL-1470: lanes:[] is ambiguous on its own — it
// means either an explicit "no optional lanes" (lanesMeaningful=true) or "the
// lanes question was never asked" (a migrated legacy contributor cache, whose
// old v1 role-gated lanes question never ran — see loadProfile's own !isV2
// role==='adopter' exemption above, which lets exactly this shape validate).
// Mirrors that exemption exactly: a never-asked answer must never be treated
// as an authoritative empty selection. Named lanes (length > 0) stay
// unambiguous either way and are never gated by this.
function lanesAnswerNeverAsked(answers) {
  return answers.lanes === undefined || (answers.lanes.length === 0 && answers.lanesMeaningful !== true);
}

// Validate predictable profile-persistence failures before any installer,
// handover or vault mutation. The post-install write stays authoritative and
// repeats these checks to catch changes during the core install. HIMMEL-2308:
// universal now — lanes is asked to every profile, so this always runs...
// except when lanesAnswerNeverAsked (see above) — nothing will be persisted,
// so there is nothing here to preflight.
async function preflightLaneProfileStep(answers) {
  if (lanesAnswerNeverAsked(answers)) return true;
  try {
    await adopterProfileLib.preflightProfileLaneAllowlist(repoRoot());
    return true;
  } catch (e) {
    console.error(`himmelctl: lane profile preflight failed: ${e && e.message ? e.message : e}`);
    return false;
  }
}

// HIMMEL-1428: persist an APPLIED install's selected optional lanes as the
// resolver's narrowing profile allowlist. This runs only after the core
// install succeeds; dry-run never writes it. Failure is fatal because
// silently leaving every detected backend routable would violate the consent
// boundary the profile selection now represents. HIMMEL-2308: universal now —
// lanes is asked to every profile. HIMMEL-2300/1470: EXCEPT when
// lanesAnswerNeverAsked — persisting an authoritative empty allowlist for a
// question nobody was asked would silently suppress every optional lane
// (the consent-fabrication class HIMMEL-2300 exists to prevent), so skip
// with an honest message instead of writing anything.
async function applyLaneProfileStep(answers) {
  if (lanesAnswerNeverAsked(answers)) {
    console.log('lane profile: lanes never answered on this legacy profile — no allowlist written; re-run the installer to select lanes');
    return true;
  }
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

// HIMMEL-2033's retired-plugin-removal offer: best-effort, advisory only,
// never fails the install. `remove-retired-plugin.sh` owns the actual
// contract (silent when absent; prompt with DEFAULT=remove on a TTY).
function offerRetiredPluginRemoval() {
  const script = path.join(repoRoot(), 'scripts', 'machine-setup', 'remove-retired-plugin.sh');
  if (!fs.existsSync(script)) return;
  spawnSync(resolveBash(), [toBashPath(script)], { stdio: 'inherit' });
}

// T4.5 helper: pluginSet=full's ENABLE step used to live here. HIMMEL-2304
// drops the 'full' option entirely — the full-plugin-enable.json set does
// not reflect what himmel actually runs; the reconciler whitelist (see
// HIMMEL-2292) is the truth — so the enable step is unconditionally a no-op
// for every role/answer now.
//
// CR round 3 [codex-1]: the HIMMEL-2033 retired-plugin-removal offer is NOT
// tied to the enable step's success/failure — it exists because a machine
// PREVIOUSLY provisioned with pluginSet=full may still carry the retired
// plugin, and a legacy 'full' --from-profile cache (still accepted for
// backward compat — loadProfile's checkEnum is unchanged) is exactly the
// population most likely to. `himmelctl update`/`/himmel-update` call the
// same underlying script independently (scripts/himmel-update.sh's own
// offer_retired_plugin_removal(), untouched by this ticket) and would catch
// it eventually — but dropping the install-time offer entirely left a gap
// for an operator replaying an old profile right now. Keep offering it,
// decoupled from the (removed) enable step, scoped to pluginSet=full only —
// a lean install never carried the retired plugin, so it never offers this.
//
// Kept as a thin function (not inlined at both call sites) so the T4.5 shape
// stays the same for the main path and the T5b existing-vault path (FIX 5).
function applyPluginStep(answers) {
  if (answers.pluginSet === 'full') offerRetiredPluginRemoval();
  return { rc: 0, failed: [], total: 0 };
}

// T4/T4.5/T5a/T5b plan: derivation, vault gate, handover/pluginSet, shell-out.
//
// HIMMEL-2460 (de-fork): vault.mode=existing used to be a parallel
// re-implementation of the whole install sequence below — its own confirm,
// handover write, lane preflight, plugin step, luna sections, path shim and
// epilogue — and it RETURNED before ever reaching deriveCommand()/adopt.sh,
// making the core install structurally unreachable for that one mode. It now
// only derives the T5b-specific pieces (the unstamped-vault fail-closed
// refusal, and the additional wire/apply plan for a stamped vault); the
// install sequence itself is the SAME one every other vault mode runs below,
// with wire/apply layered on top of adopt.sh exactly like the dev overlay is
// (HIMMEL-2308's own comment on that pattern, a few lines down).
async function runPlan(answers, args) {
  const vaultExisting = Boolean(answers.vault && answers.vault.mode === 'existing');
  let existingVaultPlan = null;

  // T5b (locked O1): vault.mode=existing, STAMPED vaults only — non-luna→luna
  // conversion stays deferred. HIMMEL-2308: vault is universal now (the old
  // role==='adopter' gate died with role), so this branch is scoped purely on
  // vault.mode.
  if (vaultExisting) {
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
    // STAMPED: derive the two-command wire/apply plan. It is printed and run
    // ADDITIONALLY, after adopt.sh below — never as a substitute for it.
    existingVaultPlan = deriveExistingVaultPlan(answers);
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
  if (answers.vault && answers.vault.mode === 'default-template' && answers.vault.path) {
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
  // vaultExisting already printed the serialized answers above, before its
  // stamp check — never print it twice.
  if (!vaultExisting) process.stdout.write(serialize(answers) + '\n');
  console.log(`derived: ${displayCommand(cmd)}`);
  // HIMMEL-2460: the T5b wire/apply plan is an ADDITIONAL pair of commands
  // layered on top of adopt.sh above, never a substitute for it — same
  // posture as the dev overlay just below.
  if (existingVaultPlan) {
    console.log(`derived: ${displayCommand(existingVaultPlan.wire)}`);
    console.log(`derived: ${displayCommand(existingVaultPlan.apply)}`);
  }
  // HIMMEL-2308: the dev overlay is an ADDITIONAL command layered on top of
  // adopt.sh above, never a substitute for it.
  const overlayCmd = answers.devOverlay ? deriveOverlayCommand() : null;
  if (overlayCmd) console.log(`derived (dev overlay): ${displayCommand(overlayCmd)}`);

  // --dry-run prints the plan (+ T4.5 side effects) and exits WITHOUT
  // executing or mutating anything.
  if (args.dryRun) {
    previewHandoverAndPlugins(answers);
    const lunaPreview = previewLunaSections(answers);
    applyHimmelctlPathShim(args);
    await printContributorProfile(answers, overlayCmd ? displayCommand(overlayCmd) : undefined, args.dryRun);
    await printAdopterEpilogue(answers, displayCommand(cmd), args.dryRun, null, vaultScaffolded, lunaPreview);
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
  if (answers.vault && answers.vault.mode === 'default-template' && answers.vault.path) {
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
  // HIMMEL-2460: the T5b wire/apply plan runs AFTER adopt.sh succeeds, as an
  // additional step — never instead of it.
  if (existingVaultPlan) {
    const wireRc = runSpawn(existingVaultPlan.wire);
    if (wireRc !== 0) return wireRc;
    const applyRc = runSpawn(existingVaultPlan.apply);
    if (applyRc !== 0) return applyRc;
  }
  // HIMMEL-2308: the dev overlay's setup.sh/setup.ps1 runs AFTER adopt.sh
  // succeeds, as an additional idempotent mutation step — never instead of it.
  if (overlayCmd) {
    const overlayRc = runSpawn(overlayCmd);
    if (overlayRc !== 0) return overlayRc;
  }
  if (!await applyLaneProfileStep(answers)) return 1;

  // T4.5: pluginSet=full → the documented per-plugin enable step. lean → no-op
  // (adopt.sh's/setup.sh's settings-template default, HIMMEL-816).
  const pluginResult = applyPluginStep(answers);
  const lunaResult = applyLunaSectionsStep(answers);
  const shimOk = applyHimmelctlPathShim(args);
  await printContributorProfile(answers, overlayCmd ? displayCommand(overlayCmd) : undefined, args.dryRun);
  await printAdopterEpilogue(answers, displayCommand(cmd), args.dryRun, pluginResult, vaultScaffolded, lunaResult);
  printUninstallFooter();
  return pluginResult.rc || lunaResult.rc || (shimOk ? 0 : 1);
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

  // 0.5 (HIMMEL-2308 CR round 3): --contribute outside a himmel checkout is
  // refused HERE, before any preflight/question side effect, so an invalid
  // flag is cheap to fail on — no wizard walk, no cache write. This does NOT
  // duplicate the step-5.5 gate below: that one is the sole AUTHORITATIVE
  // check (it also covers --from-profile/legacy-cache devOverlay, which this
  // early check cannot see since parseArgs refuses --contribute + --from-
  // profile together); this one exists purely for flag ergonomics on the
  // --contribute path specifically, so an interactive run never prompts a
  // single question or persists a devOverlay:true cache before failing.
  if (args.contribute && !contributeCheckoutOk()) {
    console.error(`himmelctl: --contribute requires a himmel checkout — scripts/${contributeOverlayFilename()} not found under ${repoRoot()}`);
    return 1;
  }

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
    answers = await askQuestions(args.defaultScope, laneOpts, args.contribute);
  } else if (args.dryRun) {
    answers = defaultAnswers(args.defaultScope, laneOpts, args.contribute);
  } else {
    console.error('himmelctl: non-interactive install requires --from-profile <path>');
    console.error('  (or set HIMMELCTL_INTERACTIVE=1 to answer prompts interactively)');
    return 1;
  }
  // HIMMEL-2436: cache the resolved answers regardless of source — replaying a
  // profile (--from-profile) is still an install, and the resulting machine
  // should be as introspectable via `status`/`ensure` as an interactively-
  // installed one. Gated on !dryRun (one guard, one source of truth for every
  // branch above): a dry run — from ANY of the three answer-producing
  // branches, interactive included — must make zero persistent changes.
  if (!args.dryRun) writeCache(answers);

  // 5.5 (HIMMEL-2308): devOverlay is only valid inside a himmel checkout —
  // it layers the contributor-dev setup.sh/setup.ps1 primitive on top of the
  // install (see deriveOverlayCommand()), and that primitive does not exist
  // anywhere else. This is the ONE authoritative gate: it fires on the
  // resolved answers regardless of source (--contribute, a --from-profile
  // file with devOverlay:true, or a legacy role:"contributor" cache migrated
  // by loadProfile) — checked before runPlan's first side effect (adopt.sh).
  // A --contribute-only pre-check used to sit above step 1, but it covered
  // only that one source, leaving --from-profile/legacy-cache devOverlay to
  // reach adopt.sh before the (then unreachable) overlay-spawn failure.
  if (answers.devOverlay && !contributeCheckoutOk()) {
    console.error(`himmelctl: --contribute requires a himmel checkout — scripts/${contributeOverlayFilename()} not found under ${repoRoot()}`);
    return 1;
  }

  // T4/T4.5/T5a: derivation, vault gate, handover/pluginSet, shell-out.
  const rc = await runPlan(answers, args);
  // HIMMEL-2348: offer to save the answered profile ONLY after a genuinely
  // successful, non-dry-run, interactive install — never on a failed run
  // (rc !== 0 must reach the caller untouched, no prompt), never on
  // --dry-run (zero mutations), never non-interactively (--from-profile
  // must not block on stdin). This is a NEW call site alongside the
  // existing writeCache(answers) above — that cache write's own ordering is
  // untouched (HIMMEL-2456).
  if (rc === 0 && !args.dryRun && shouldPrompt(args)) {
    await offerSaveProfile(answers);
  }
  return rc;
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
    return { argv: [resolvePowershell(), '-ExecutionPolicy', 'Bypass', '-File', path.join(scriptsDir, 'uninstall.ps1'), '-Yes'] };
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
// reverses, and BOTH declare `scopes: ["project", "user"]` — so each
// convergeable item is probed once per entry in its own `item.scopes` (not a
// hardcoded single scope): 'user' -> ctx.scope='user' (probes.js's
// resolveConfigFile ignores targetPath for user scope and resolves against
// $HOME, matching uninstall.sh's own USER_SETTINGS default); 'project' ->
// ctx.scope='project' with ctx.targetPath=repoRoot() (matching
// settingsPath()'s project-scope convention in install-engine.js).
//
// HIMMEL-2459: an earlier version of this comment claimed "uninstall.sh
// reverses the wiring at whichever settings.json it wired, and for a machine
// offboard that's this himmel checkout's OWN project-scope .claude/
// settings.json as well as the operator's user-scope one" — that premise is
// FALSE against the actual script. scripts/uninstall.sh's [6/6] step
// ("Unwiring ~/.claude/settings.json...") unwires exactly ONE file,
// USER_SETTINGS ("${HIMMEL_USER_SETTINGS:-$HOME/.claude/settings.json}");
// REPO_ROOT is used elsewhere in the script (plugins, pre-commit, telegram)
// but never to locate a project-scope settings.json to unwire. uninstall.sh
// is user-scope only — there is no project-scope target for it to have
// reversed, so probing scope='project' against repoRoot() when repoRoot() IS
// himmel's own checkout was always reading himmel's OWN git-tracked
// .claude/settings.json (repo source carrying the committed dev chain,
// which uninstall correctly never touches) as if it were adopter-owned
// residue — a structural false positive, not a real leftover. This is now
// guarded below (isHimmelOwnCheckout): the 'project' scope is skipped ONLY
// when repoRoot() identity-matches himmel's own canonical checkout;
// 'user' is always probed, since user-scope residue is the only kind
// uninstall.sh could actually leave behind. Do NOT re-widen this to
// "probe project unconditionally" — that was tried once already (the
// sentence this replaces) and reintroduces the exact false positive
// HIMMEL-2459 fixes; do NOT narrow it to "probe project only when the
// settings.json isn't git-tracked" either — an adopter who commits their
// own .claude/settings.json would then be silently exempted from real
// leftover-wiring detection.
//
// Non-fatal: never changes cmdUninstall's own exit code — that stays the
// teardown's rc.
function checkUninstallCompleteness(unwireItems) {
  const convergeable = unwireItems.filter((item) => item.unwire);
  const root = repoRoot();
  // True iff `root` (the project-scope probe target) IS himmel's own
  // canonical checkout, not a separate adopter project — see the HIMMEL-2459
  // comment above. Compared by identity (git-common-dir, then dev+ino), not
  // by string equality, so a trailing separator, a linked worktree, a
  // symlinked path segment, POSIX-vs-Windows slash style, or Windows
  // drive-letter casing cannot misclassify it — same convention
  // primaryCheckoutRoot() above and pr-check-context.sh's `-ef` anchor
  // comparison use for the identical class of problem. Computed once (not
  // per item/scope): cheap relative to the probes themselves, and every
  // convergeable item shares the same answer.
  const isHimmelOwnCheckout = sameFsEntry(primaryCheckoutRoot(root), primaryCheckoutRoot(himmelRoot()));
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
      // HIMMEL-2459: skip the project-scope probe when `root` IS himmel's
      // own checkout — uninstall.sh never had a project-scope target to
      // reverse there (see the comment above), so probing it only ever
      // reads himmel's own tracked repo source. 'user' is never skipped.
      if (scope === 'project' && isHimmelOwnCheckout) continue;
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
  // HIMMEL-2505: this is the ONE spawn that runs uninstall.sh/.ps1 WET, after
  // the human's own confirm above — tell it so its own live-operator-HOME
  // fence doesn't refuse the very machine the operator just confirmed
  // offboarding. The dry-run/plan path above never reaches here.
  const rc = runSpawn(cmd, { env: { ...process.env, HIMMEL_UNINSTALL_REAL_HOME: '1' } });
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
//
// <dir> defaults to repoRoot() (all pre-existing call sites); an explicit
// <dir> (HIMMEL-2459's checkUninstallCompleteness) resolves a DIFFERENT
// directory's primary checkout the same way, so two directories' identity
// can be compared regardless of which linked worktree either one is.
function primaryCheckoutRoot(dir) {
  const root = dir || repoRoot();
  const r = spawnSync(resolveBash(),
    ['-c', 'd=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$d/.." && { pwd -W 2>/dev/null || pwd; }'],
    { cwd: root, encoding: 'utf8' });
  if (r.error || r.status !== 0 || !r.stdout) return root;
  const resolved = r.stdout.trim();
  return resolved ? path.resolve(resolved) : root;
}

// True iff <a> and <b> are the SAME filesystem entry — dev+ino identity, the
// Node equivalent of shell `test -ef` (HIMMEL-2459). Verified on win32/
// Node 24 to be trailing-separator-, slash-style-, and drive-letter-casing-
// insensitive (fs.statSync resolves the real on-disk file, unlike a bare
// fs.realpathSync string compare, which on this platform/Node combo
// preserves the CALLER's input casing instead of normalizing it — realpath
// alone is not a safe discriminator here). Symlinked path segments resolve
// correctly too, since statSync (unlike lstatSync) follows symlinks. Returns
// false, never throws, when either path can't be stat'd.
function sameFsEntry(a, b) {
  try {
    const sa = fs.statSync(a);
    const sb = fs.statSync(b);
    return sa.dev === sb.dev && sa.ino === sb.ino;
  } catch (_e) {
    return false;
  }
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

// ── gaps (HIMMEL-2348 deliverable 2) ─────────────────────────────────────
//
// "What does starter not get from operator?" A NEW subcommand, not a
// `status` mode — deliberately: ALLOWED_OPTIONS is a per-subcommand
// allowlist and main()'s dispatch is a flat uniform chain, so a new
// subcommand costs one allowlist row, one dispatch line, one function and
// one USAGE entry, and changes NO existing command. A `--gaps` flag on
// `status` would instead mutate a shipped contract: status's flags are
// exactly ['items','json'], --json's shape is pinned by
// test-wizard-status-golden.sh, and --items would need a new conflict rule.
// `scope`/`config`/`deps` are precedent for a subcommand owning its own
// grammar.
//
// gaps diffs THIS setup's saved profile (default cachePath(), or
// --from-profile) against a reference profile (default docs/setup/profiles/
// operator.install-profile.json, or --preset <name>) and prints four
// DISTINCT groups — conflating them is exactly what makes this tribal
// knowledge today:
//   (a) answered off/none — the reference has it on, this setup turned it
//       off. The operator's OWN CHOICE, explicitly labelled so it never
//       reads as a deficiency.
//   (b) not recorded — the field is genuinely absent from this profile (a
//       profile written before the question existed), never a false "off"
//       answer the operator never made.
//   (c) reference-only — no wizard question can produce this yet. Rendered
//       from the checked-in tbd-delta.json map (itself checked against
//       docs/setup/operator-profile-tbd-delta.md by test-wizard-gaps.sh, a
//       structural doc<->map agreement test — never hand-sync those two).
//   (d) present but unverified — this setup's answer matches the reference
//       (both "on"), but gaps is a static profile diff, never a live probe;
//       named as still-manual (run `himmelctl status` to confirm it's
//       actually wired).
//
// gaps is a REPORT, not a gate: it exits 0 whenever the report was
// produced, even when gaps exist. Non-zero is reserved for real errors (no
// profile found, an unreadable/invalid preset, a bad flag) — same posture
// exit 2 already carries for a bad arg line elsewhere in this file.
const TBD_DELTA = require('./tbd-delta.json').entries;

// getPath(obj, 'a.b.c') -> obj.a.b.c, or undefined on any missing hop —
// used below so FIELDS can name a comparable leaf as one dotted string.
function getPath(obj, p) {
  return p.split('.').reduce((o, k) => (o && typeof o === 'object' ? o[k] : undefined), obj);
}

// The comparable v2-schema leaves group (a)/(c) diff over. `isOff(v)`
// answers "does this value mean not-using-the-feature" for THAT field —
// pluginSet is deliberately absent (v2 fixes it to 'lean' on both sides, so
// it can never differ) and vault.path/handover.path/bridge.envPath etc are
// deliberately absent (personal/placeholder values, not toggles — only
// vault.mode/handover.mode/bridge.enabled, the actual on/off signal, are
// compared).
const GAPS_FIELDS = [
  { path: 'devOverlay', label: 'contributor dev overlay (--contribute)', isOff: (v) => v !== true },
  { path: 'alwaysOn', label: 'always-on initiative', isOff: (v) => v !== true },
  { path: 'vault.mode', label: 'vault', isOff: (v) => v === 'none' || v === undefined },
  { path: 'handover.mode', label: 'external handover', isOff: (v) => v !== 'external' },
  { path: 'bridge.enabled', label: 'telegram bridge', isOff: (v) => v !== true },
  { path: 'secretsWalk', label: 'secrets walk', isOff: (v) => v !== 'run' },
  { path: 'luna.cadenceEnabled', label: 'luna pipeline cadence (legacy toggle)', isOff: (v) => v !== true },
  { path: 'luna.phiDeclared', label: 'PHI vault declaration', isOff: (v) => v !== true },
];

// diffProfiles(thisProfile, reference) -> { choices, unverified, notRecorded }
// — group (a), (c), and a fourth "not recorded" group in one pass. A
// field/cadence/lane only ever lands in ONE of the three (never more): it's
// only interesting at all when the reference has it on; from there, this
// setup's own value decides which group it belongs to.
function diffProfiles(thisProfile, reference) {
  const choices = [];
  const unverified = [];
  const notRecorded = [];

  for (const f of GAPS_FIELDS) {
    const refVal = getPath(reference, f.path);
    if (refVal === undefined || f.isOff(refVal)) continue; // reference doesn't have it either
    const thisVal = getPath(thisProfile, f.path);
    if (thisVal === undefined) {
      // The field is genuinely ABSENT from this profile (not merely
      // "off") — same collapse buildAnswers() fought above (~line 894):
      // an older profile written before this question existed round-trips
      // as a missing key, not a false "off" answer. isOff(undefined) would
      // treat it as a choice, which would put a claim the operator never
      // made under "your own choice, not a gap" — so it's reported
      // separately, before isOff ever sees it.
      notRecorded.push({ field: f.path, label: f.label, referenceValue: refVal });
    } else if (f.isOff(thisVal)) {
      choices.push({ field: f.path, label: f.label, thisValue: thisVal, referenceValue: refVal });
    } else {
      unverified.push({ field: f.path, label: f.label, value: thisVal });
    }
  }

  for (const row of CADENCE_REGISTRY) {
    const refVal = reference.cadences && reference.cadences[row.id];
    if (refVal !== 'armed') continue;
    const label = `cadence: ${row.id}`;
    const thisValRaw = thisProfile.cadences && thisProfile.cadences[row.id];
    if (thisValRaw === undefined) {
      // Same collapse as GAPS_FIELDS above: a profile written before this
      // cadence existed (or before cadences were tracked at all) round-trips
      // as a missing key, not a false "off" answer — report it as not
      // recorded rather than as a choice the operator never made.
      notRecorded.push({ field: `cadences.${row.id}`, label, referenceValue: refVal });
      continue;
    }
    if (thisValRaw === 'armed') {
      unverified.push({ field: `cadences.${row.id}`, label, value: thisValRaw });
    } else {
      choices.push({ field: `cadences.${row.id}`, label, thisValue: thisValRaw, referenceValue: refVal });
    }
  }

  const refLanes = new Set(reference.lanes || []);
  const thisLanes = new Set(thisProfile.lanes || []);
  // Same collapse as GAPS_FIELDS/cadences above: a legacy v1 non-adopter
  // (contributor) profile round-trips lanes:[] with no lanesMeaningful — the
  // lanes question was never asked of it (loadProfile's own !isV2
  // role==='adopter' exemption lets exactly this shape validate) — so an
  // absent lane here must not be reported as a choice the operator never
  // made. lanesAnswerNeverAsked distinguishes that from an EXPLICIT empty
  // selection (lanes:[], lanesMeaningful:true), which stays a real choice.
  const lanesNeverAsked = lanesAnswerNeverAsked(thisProfile);
  for (const laneId of adopterProfileLib.ALL_LANE_IDS) {
    if (!refLanes.has(laneId)) continue;
    const label = `lane: ${laneId}`;
    if (thisLanes.has(laneId)) {
      unverified.push({ field: `lanes.${laneId}`, label, value: true });
    } else if (lanesNeverAsked) {
      notRecorded.push({ field: `lanes.${laneId}`, label, referenceValue: true });
    } else {
      choices.push({ field: `lanes.${laneId}`, label, thisValue: false, referenceValue: true });
    }
  }

  return { choices, unverified, notRecorded };
}

// referenceOnlyList() -> group (b), sorted by doc row number for a stable
// rendering/JSON order matching the doc's own table order (numeric sort,
// not lexicographic — row keys are numeric strings, and "10" < "2"
// lexicographically would misorder the doc's own row sequence).
function referenceOnlyList() {
  return Object.keys(TBD_DELTA)
    .sort((a, b) => Number(a) - Number(b))
    .map((row) => ({
      row: Number(row), label: TBD_DELTA[row].label, ticket: TBD_DELTA[row].ticket, paths: TBD_DELTA[row].paths,
    }));
}

async function cmdGaps(args) {
  const profilePath = args.fromProfile || cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const thisProfile = loadProfile(profilePath);

  let referencePath;
  if (args.preset !== null) {
    if (!isValidProfileName(args.preset)) {
      console.error(`himmelctl: invalid --preset name ${JSON.stringify(args.preset)} (no path separators, no '..', not absolute, no leading '.')`);
      return 2;
    }
    referencePath = path.join(repoRoot(), 'docs', 'setup', 'profiles', `${args.preset}.install-profile.json`);
  } else {
    referencePath = path.join(repoRoot(), 'docs', 'setup', 'profiles', 'operator.install-profile.json');
  }
  if (!fs.existsSync(referencePath)) {
    console.error(`himmelctl: reference profile not found: ${referencePath}`);
    return 2;
  }
  const reference = loadProfile(referencePath);

  const { choices, unverified, notRecorded } = diffProfiles(thisProfile, reference);
  // HIMMEL-2348 CR finding 3: TBD_DELTA (tbd-delta.json / docs/setup/
  // operator-profile-tbd-delta.md) is a delta capture from ONE specific
  // machine — the operator's, see the doc's opening paragraphs — not a
  // property of "the reference profile" in general. Rendering it against a
  // non-operator --preset would present operator-machine-only deltas as if
  // they were gaps against THAT preset, which they were never measured
  // against. Only 'operator' ships today (no preset registry exists to ask
  // "does preset X have its own TBD delta capture"), so omit group (b)
  // outright for any other reference rather than mislabel it.
  const isOperatorReference = args.preset === null || args.preset === 'operator';
  const referenceOnly = isOperatorReference ? referenceOnlyList() : [];

  if (args.json) {
    process.stdout.write(JSON.stringify({
      thisProfile: profilePath, reference: referencePath, choices, notRecorded,
      referenceOnly, referenceOnlyOmitted: !isOperatorReference, unverified,
    }) + '\n');
    return 0;
  }

  console.log(`himmelctl gaps: comparing ${profilePath}`);
  console.log(`                against  ${referencePath}`);
  console.log('');
  console.log('Answered off/none — your own choice, not a gap:');
  if (choices.length === 0) {
    console.log('  (none)');
  } else {
    for (const c of choices) console.log(`  - ${c.label}: this=${JSON.stringify(c.thisValue)} reference=${JSON.stringify(c.referenceValue)}`);
  }
  console.log('');
  console.log('Not recorded in this profile — predates this question, not a choice:');
  if (notRecorded.length === 0) {
    console.log('  (none)');
  } else {
    for (const n of notRecorded) console.log(`  - ${n.label} (reference=${JSON.stringify(n.referenceValue)})`);
  }
  console.log('');
  console.log('Reference-only — no wizard question can produce these yet:');
  if (!isOperatorReference) {
    console.log(`  (omitted — these rows are the operator machine's own delta capture, not measured against --preset ${args.preset})`);
  } else if (referenceOnly.length === 0) {
    console.log('  (none)');
  } else {
    for (const r of referenceOnly) console.log(`  - ${r.label} [${r.ticket}]`);
  }
  console.log('');
  console.log("Present but unverified — recorded in the profile; run 'himmelctl status' to confirm still wired:");
  if (unverified.length === 0) {
    console.log('  (none)');
  } else {
    for (const u of unverified) console.log(`  - ${u.label}`);
  }
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

// HIMMEL-2349: what running the disable actually DOES, for the per-item
// evidence line below — a per-item removable item names its real unwire
// command (installEngineLib.unwireCommand()); a full-offboard-only item has
// no unwire descriptor by definition, so the honest answer is the manual
// `himmelctl uninstall` path (same wording cmdEnsure's own Step 4 already
// uses for that case).
//
// HIMMEL-2349 (CR round 8, codex-1): returns the WHOLE clause (verb
// included), not just a command string the caller prefixes with a fixed
// "disabling would run: " — the verb differs by case. A full-offboard-only
// item is NEVER run here: cmdEnsure's Step 4 disable dispatch takes the
// else-branch for it, and on a 'present' probe pushes a disableErrors
// entry, sets disableAborted, and BREAKS (see ~line 4536 below) — the run
// STOPS rather than executing 'himmelctl uninstall'. The old fixed
// "disabling would run: 'himmelctl uninstall' (...)" wording was false for
// exactly the case it's shown in (a present item) — consenting doesn't run
// that command, it aborts the run and tells the operator to run it
// themselves. Same false-consent-evidence class this ticket exists to fix,
// reproduced inside the fix itself.
function describeDisableAction(item, ctx) {
  if (item.removable === 'per-item' && item.unwire) {
    const spec = installEngineLib.unwireCommand(item, ctx);
    if (spec.unrunnable) return `disabling has no automated unwire path (${spec.unrunnable}) — manual`;
    // HIMMEL-2349 (codex-4): this line is consent evidence the operator reads
    // before allowing a disable — an unquoted arg containing a space (the
    // common case on Windows, not the edge case) renders ambiguously, so
    // reuse the same display-only shellQuote() displayCommand() already
    // uses for the derived: line.
    const cmd = [spec.cmd, ...spec.args].map(shellQuote).join(' ');
    return `disabling would run: ${cmd}`;
  }
  return "disabling is not automated for this item (removable:full-offboard-only — no per-item unwire); "
    + "the run will STOP and ask you to run 'himmelctl uninstall' yourself";
}

// HIMMEL-2349 (Fix B2 — "explain each disable"): one evidence line per
// disable candidate. "not enabled for this target (profile/scope)" is not
// something an operator can meaningfully consent to — this names what the
// recorded profile actually says, what's live right now, and exactly what
// disabling would run.
//
// HIMMEL-2349 (codex-3, re-raise): `recordedProfile` MUST be
// cachedAnswers.profile (the schema-v2 field actually written into
// install-profile.json) — the call site used to pass `target.profile`
// instead, which is the RESOLVED manifest membership category persisted in
// state.json (core|luna|all, derived from the recorded profile via
// helpers.js's profileForVault, or set directly by an explicit `--profile`
// reconcile) and can go stale relative to it — exactly the divergence this
// ticket exists to fix, reproduced as a false attribution inside the fix
// itself. `resolvedCategory` (also shown, honestly labeled as a SEPARATE
// fact) is that state.json category — genuinely useful for diagnosing
// membership, but never to be sourced to install-profile.json.
function describeDisableCandidate(item, probe, ctx, recordedProfile, resolvedCategory, profileMtime) {
  const action = describeDisableAction(item, ctx);
  const when = profileMtime || 'unknown time';
  // A v1 record (no schema-v2 `profile` field) genuinely has nothing
  // recorded here — say so rather than printing "profile=undefined".
  const recordedLabel = recordedProfile || 'none (v1 record — no profile field)';
  return `${item.id}: recorded install-profile says profile=${recordedLabel} scope=${ctx.scope} `
    + `(recorded ${when} in install-profile.json; resolves to manifest category '${resolvedCategory}'); `
    + `live state says ${probe.actual} (${probe.detail}); ${action}`;
}

async function cmdEnsure(args) {
  const manifest = loadManifest();

  const profilePath = cachePath();
  if (!fs.existsSync(profilePath)) {
    console.error('himmelctl: no himmelctl install profile found — run himmelctl install first');
    return 2;
  }
  const cachedAnswers = loadProfile(profilePath);
  // HIMMEL-2349: install-profile.json carries no "recorded at" field of its
  // own (writeCache() just serializes the answers) — the file's own mtime is
  // the best available "when" for the per-item disable-evidence lines below.
  let profileMtime;
  try {
    profileMtime = fs.statSync(profilePath).mtime.toISOString();
  } catch (_e) {
    profileMtime = 'unknown time';
  }

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

  // HIMMEL-2349 root-cause fix: the recorded install-profile (cachedAnswers)
  // is loaded above for every `ensure` run, but until now nothing ever fed
  // it back into this target's persisted `enabled` flags UNLESS the operator
  // passed an explicit --profile (Step 0 below) — a target derived once
  // (ensureTarget's first-run derive, possibly against a stale/thin
  // cachedAnswers) stayed wrong forever even after the recorded profile grew
  // richer. Additive-only (state.js's own additiveReconcile — mirrors
  // migrateTargetItems: turns items ON, never off, and never touches one
  // carrying a deliberate override, or a target carrying an explicit
  // reconcile stamp — see reconcileTarget()'s own comment): every item the
  // CURRENTLY recorded profile would enable, that this target doesn't
  // already have enabled, gets turned on right here.
  //
  // HIMMEL-2349 (codex-1/codex-2, Critical + Suggestion, same root): SKIPPED
  // ENTIRELY when args.profile is supplied THIS run — Step 0's reconcile
  // moments later is authoritative and would discard whatever this overlay
  // just did anyway (turning items on here only for Step 0 to immediately
  // turn some back off is wasted work, not merely harmless), and printing
  // "persisting; this never disables anything" right before Step 0 disables
  // some of those same items would be an outright false claim, not just
  // noise. This is also what makes reconcileTarget()'s profileSource stamp
  // meaningful ACROSS runs: the one run that sets it never fights it.
  const additive = args.profile
    ? { changed: false, added: [] }
    : stateLib.additiveReconcile(target, manifest, cachedAnswers);
  if (additive.changed) {
    stateChanged = true;
    console.log(`himmelctl: recorded install-profile enables ${additive.added.length} item(s) this target hadn't turned on: ${additive.added.join(', ')} (persisting; this never disables anything)`);
  }

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

  // HIMMEL-2176 (round-3 ruling, ask-first gate): guardrail-block-global
  // writes the OPERATOR'S GLOBAL ~/.claude/settings.json — machine state
  // outside this repo, and outside the blast radius the general per-run
  // --yes consent (Step 3, below) is scoped to reason about. It must never
  // ride that blanket consent into the ordinary towardEnabled pool. Its OWN
  // recorded answer — target.items['guardrail-block-global'].overrides.
  // consent ('yes'|'no') — is the ONLY thing that can. status-report.js's
  // permanent 'n/a' downgrade for this item is lifted ONLY when consent is
  // exactly 'yes' (see its own comment); that is what lets the ordinary
  // Step 2 loop below pick it up like any other runnable item once
  // consented — no separate injection path, so it gets the SAME dependency-
  // closure checks, dry-run printing, and post-check verification as
  // everything else. This block is the ONLY place that ever WRITES that
  // override, and it NEVER treats silence (a closed/non-TTY stdin, or
  // --dry-run) as consent — the one thing the ruling forbids outright.
  //
  // Gated on the same --items membership convention every other per-item
  // check in this function already uses: a filtered run that doesn't name
  // this item never touches it.
  if (!args.items || args.items.indexOf('guardrail-block-global') !== -1) {
    const guardrailItem = manifest.items.find((i) => i.id === 'guardrail-block-global');
    if (guardrailItem && guardrailItem.scopes.includes(scope) && guardrailItem.install
        && installEngineLib.RUNNABLE_INSTALL_TYPES.indexOf(guardrailItem.install.type) !== -1) {
      const guardrailCtx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
      const guardrailProbe = probesLib.runProbe(guardrailItem, guardrailCtx);
      if (guardrailProbe.actual !== 'present') {
        const itemState = target.items['guardrail-block-global'];
        // CR-style defensive normalize (same class as state.js's own
        // malformed-overrides guards) — a hand-edited or pre-this-ticket
        // state.json could carry a non-object `overrides`.
        if (!itemState.overrides || typeof itemState.overrides !== 'object' || Array.isArray(itemState.overrides)) {
          itemState.overrides = {};
        }
        const consent = itemState.overrides.consent;
        if (consent !== 'yes' && consent !== 'no' && !args.dryRun && isInteractive(args)) {
          console.log('himmelctl: guardrail-block-global wires the safety-guardrail hooks into your GLOBAL ~/.claude/settings.json (every project on this machine, not just this one). Recommended: yes.');
          const ans = await askConfirmSafe('Wire it now? [Y/n] ');
          const decided = /^\s*n/i.test(ans) ? 'no' : 'yes';
          itemState.overrides.consent = decided;
          stateChanged = true;
          console.log(`himmelctl: recorded guardrail-block-global consent = ${decided}`);
        } else if (consent !== 'yes' && consent !== 'no') {
          // No recorded answer, and this run cannot ask right now
          // (--dry-run, or non-interactive/piped stdin) — the one thing
          // this gate must never do is treat that silence as consent.
          console.log("himmelctl: guardrail-block-global has no recorded consent yet — staying manual (run 'himmelctl ensure' interactively once to decide; recommended: yes). Direct fix: node scripts/hooks/guardrail-block.mjs install --node <ABS_NODE> --bash <ABS_BASH>");
        }
      }
    }
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
  // HIMMEL-2349: probe evidence per disable candidate, id -> probe, so the
  // consent offer below can explain EACH one ("recorded profile says X;
  // live state says Y; disabling would run Z") instead of a bare id list.
  const towardDisabledProbes = new Map();
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
    if (probe.actual !== 'absent') {
      towardDisabled.push(item);
      towardDisabledProbes.set(item.id, probe);
    }
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
    // item, or tokensave-mcp) never lands in towardEnabled even when
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

  // HIMMEL-2349 (Fix B1/B3 — split consent + under-recorded guard): a
  // disable is a DIFFERENT, higher risk than a converge (converge only ever
  // ADDS wiring; disable REMOVES it) and must never share one Y/n with it —
  // see the incident this ticket fixes: an operator was offered "converge 1;
  // disable 8" as a single choice and had to accept the unwanted 8 to get
  // the wanted 1. Default `ensure` performs converges ONLY; --prune opts
  // into reviewing/disabling. `UNDER_RECORDED_LIVE_THRESHOLD` items that are
  // fully 'present' (not merely 'degraded') and STILL not desired is treated
  // as the record itself looking stale/thin rather than a genuine bulk
  // decommission — same detection Fix A's additive overlay already
  // recognizes (a recorded profile that simply doesn't declare items this
  // target visibly has running); see HIMMEL-2350 for one concrete way a
  // record goes stale (a non-hermetic test suite run overwriting real
  // state). ponytail: a flat constant, not a percentage/config knob — raise
  // it if it proves too eager in practice.
  //
  // HIMMEL-2349 (codex-2, re-raise): this guard used to have NO escape
  // hatch — an operator doing a genuine, deliberate downgrade (`ensure
  // --profile core` on a target previously converged richer) could never
  // carry it out, and worse, it could WEDGE: an explicit --profile reconcile
  // flips the affected items' desired flags to false in `state` right away
  // (Step 0, above), and when there's nothing else to converge that gets
  // SAVED immediately by the "nothing to converge" early return below —
  // but the physical wiring was never unwound (this guard blocked doPrune).
  // towardDisabled is recomputed from desired-ness + a live probe, NOT from
  // state.json's `enabled` flag, so the exact same still-present items
  // reappear as candidates on every subsequent run, the guard fires again
  // (nothing physically changed), and --prune can never proceed — forever.
  // An explicit --profile is the operator re-declaring intent for THIS
  // target, so it earns deference: skip the guard whenever args.profile was
  // supplied (still gated behind its own separate confirm below). The
  // guard's protection is kept for the DEFAULT path (no --profile), which
  // is the actual incident this was written for — an ambient/stale record.
  const UNDER_RECORDED_LIVE_THRESHOLD = 3;
  // HIMMEL-2349 (codex-1, round 6): an item carrying a deliberate per-item
  // override (target.items[id].overrides non-empty — stateLib.hasDeliberateOverride)
  // is recorded OPERATOR INTENT, the strongest possible evidence the record is
  // NOT under-recorded — yet it's still 'removable' + not-desired + physically
  // present (recordedDesired() returns false the instant hasDeliberateOverride()
  // is true), so it lands in towardDisabled and used to count AS under-recorded
  // evidence, inverting the signal and letting three deliberate overrides veto
  // the very prune the operator asked for. Excluded from the EVIDENCE count
  // only — it still stays in towardDisabled and is still offered for disable.
  const presentDisableCandidates = towardDisabled.filter((i) => {
    const p = towardDisabledProbes.get(i.id);
    if (!p || p.actual !== 'present') return false;
    return !stateLib.hasDeliberateOverride(target.items[i.id]);
  });
  const recordLooksUnderRecorded = !args.profile && presentDisableCandidates.length >= UNDER_RECORDED_LIVE_THRESHOLD;
  const doPrune = args.prune && towardDisabled.length > 0 && !recordLooksUnderRecorded;
  // Mutable: Step 3's separate disable confirm (below) can decline the
  // prune while the converge phase still proceeds — `doPrune` itself stays
  // the ORIGINAL pre-confirm intent (used below to derive disabledIds for
  // the hazard walk).
  // HIMMEL-2349 (v2): the reverse-dependency hazard walk below evaluates
  // against this INTENDED prune set (disabledIds, derived from doPrune), but
  // it may only reject the PRUNE pass itself (pruneConfirmed=false,
  // pruneRejected=true) — it must never abort the whole run/veto the
  // converge pass too. That "hazard vetoes the wanted converge" behavior was
  // exactly the incident this ticket exists to fix, in a third disguise: a
  // declinable disable pass was hard-rejecting a run that also had
  // unrelated, safe work to converge.
  let pruneConfirmed = doPrune;
  let pruneRejected = false;

  if (towardDisabled.length > 0) {
    const evidenceCtx = { repoRoot: repoRoot(), targetPath: baseTargetPath, scope, env: process.env };
    if (recordLooksUnderRecorded) {
      console.log(`himmelctl: ${presentDisableCandidates.length} item(s) this target's recorded install-profile does not declare are live and working right now — that looks UNDER-RECORDED, not a genuine bulk decommission (a non-hermetic test suite run can overwrite real state — HIMMEL-2350). NOT offering to disable them.`);
      console.log("himmelctl: fix the record instead — re-run 'himmelctl install --from-profile <path>' or the wizard for real (see HIMMEL-2348 to save your current profile first), then re-run 'himmelctl ensure'. Or, if this IS a deliberate downgrade, re-run with an explicit --profile <core|luna|all> — that re-declares your intent for this target and skips this guard (still behind its own --prune confirm).");
    } else if (!args.prune) {
      console.log(`himmelctl: ${towardDisabled.length} item(s) are enabled but no longer desired for this target (converge-only by default — not disabling; re-run with --prune to review):`);
    } else {
      console.log(`himmelctl: --prune: ${towardDisabled.length} item(s) are enabled but no longer desired for this target:`);
    }
    for (const item of towardDisabled) {
      const probe = towardDisabledProbes.get(item.id);
      console.log(`  ${describeDisableCandidate(item, probe, evidenceCtx, cachedAnswers.profile, target.profile, profileMtime)}`);
    }
  }

  const disabledIds = new Set(doPrune ? towardDisabled.map((i) => i.id) : []);
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
  // HIMMEL-2349 (v2): collected, not printed/aborted immediately — a hazard
  // here may only reject the PRUNE pass (see the pruneConfirmed comment
  // above), never the whole run, so this loop no longer `return`s.
  const pruneHazards = [];
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
        pruneHazards.push(`would disable ${disabledId}, but ${dependentId} (still desired) depends on it${chainNote} — reconcile ${dependentId} toward undesired too (e.g. via --profile) so both unwire together (reverse-dependency order unwinds ${dependentId} first), or drop ${disabledId} from this run`);
        continue;
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
  // HIMMEL-2349 (v2): print every collected hazard once, on stderr, BEFORE
  // any prompt — then narrow the rejection to the PRUNE pass only. The
  // converge phase (towardEnabled) is untouched by this: doPrune stays as
  // computed, but pruneConfirmed (which now gates the disable dispatch and
  // its own confirm below) is forced false.
  if (pruneHazards.length > 0) {
    for (const msg of pruneHazards) console.error(`himmelctl: ${msg}`);
    pruneConfirmed = false;
    pruneRejected = true;
    // ...but ONLY narrow the rejection when there is genuinely something
    // else to do. With no toward-enabled work the prune WAS the whole run,
    // so nothing is being vetoed and the pre-v2 contract still holds exactly:
    // refuse with exit 2 ("refused, nothing ran"), returning HERE — above the
    // "nothing to converge" early return and therefore above its
    // stateLib.save(state), so the reject stays ZERO-MUTATION. Falling
    // through instead would both downgrade a pure refusal to exit 1 (a run
    // that ran nothing reporting the same code as one that ran and failed)
    // and persist derive/reconcile bookkeeping on a rejected run, which the
    // byte-identical state.json assertions in this file's cases g/m/n exist
    // to prevent. Exit 1 is reserved for the case this fix is actually
    // about: converge work ran and only the prune pass was rejected.
    if (towardEnabled.length === 0) return 2;
  }

  // CR fix: hints must be surfaced on EVERY path, not only the "nothing to
  // converge" early return below — a run that ALSO does real work was
  // dropping them silently. Printed once, unconditionally, right after
  // they're known.
  if (hints.length > 0) {
    console.log(`himmelctl: ${hints.length} item(s) need manual convergence (no automated install path yet): ${hints.join(', ')}`);
  }

  // HIMMEL-2349: "nothing to converge" is now judged on towardEnabled +
  // whether a --prune disable pass is actually going to run (pruneConfirmed,
  // which the hazard walk above may have already forced false) — NOT on the
  // mere existence of disable candidates, which by default are
  // informational-only (printed above) and never dispatched.
  if (towardEnabled.length === 0 && !pruneConfirmed) {
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

  // Step 3: SPLIT consent (HIMMEL-2349, Fix B1) — converge and disable are
  // different risk classes (converge only ever ADDS wiring; disable REMOVES
  // it), so disables NEVER ride the converge Y/n: they require their own
  // explicit opt-in (--prune) plus their own separate confirmation below —
  // exactly the incident this ticket fixes ("converge 1; disable 8" as a
  // single choice). The two confirms are NOT symmetric, by design: declining
  // the converge prompt aborts the run entirely (including any pending
  // --prune disable pass), rather than falling through to offer removals
  // right after the operator just said no — that would be worse UX, not
  // better. Declining the disable prompt below, in contrast, skips only the
  // disable pass; converge (if any) still proceeds. --dry-run skips both
  // confirms (as before) but still prints what each phase would do.
  if (towardEnabled.length > 0 && !args.yes) {
    console.log(`himmelctl: about to converge ${towardEnabled.length} item(s): ${towardEnabled.map((i) => i.id).join(', ')}`);
    if (!args.dryRun && isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log(pruneConfirmed
          ? 'himmelctl: declined; nothing run (the pending --prune disable pass is skipped too).'
          : 'himmelctl: declined; nothing run.');
        return 0;
      }
    }
  }
  if (pruneConfirmed && !args.yes) {
    console.log(`himmelctl: --prune: about to disable ${towardDisabled.length} item(s): ${towardDisabled.map((i) => i.id).join(', ')} (see the per-item evidence above)`);
    if (!args.dryRun && isInteractive(args)) {
      const ans = await askConfirmSafe('Proceed with disabling? [Y/n] ');
      if (/^\s*n/i.test(ans)) {
        console.log('himmelctl: declined disabling; converge (if any) still proceeds.');
        pruneConfirmed = false;
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
  // HIMMEL-2349: the whole disable phase is gated on pruneConfirmed — an
  // empty list here means Step 4 below is a complete no-op (disabled stays
  // [], disableAborted stays false), exactly "ensure offers zero disables"
  // by default.
  for (const item of installEngineLib.reverseDependencyOrder(pruneConfirmed ? towardDisabled : [])) {
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
    return (disableErrors.length > 0 || previewErrors.length > 0 || pruneRejected) ? 1 : 0;
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
  if (stillNotConverged.length > 0 || disableErrors.length > 0 || failed.length > 0 || pruneRejected) {
    if (stillNotConverged.length > 0) {
      console.error(`himmelctl: ${stillNotConverged.length} item(s) still not converged: ${stillNotConverged.map((r) => r.id).join(', ')}`);
    }
    if (failed.length > 0) {
      console.error(`himmelctl: ${failed.length} install(s) failed: ${failed.map((f) => `${f.id} (${f.reason})`).join(', ')}`);
    }
    for (const e of disableErrors) console.error(`himmelctl: ${e}`);
    if (pruneRejected) {
      console.error('himmelctl: the --prune disable pass was rejected (see the dependency hazard above); converge was not blocked by it.');
    }
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
  // HIMMEL-2348: same offer as cmdInstall, after a genuinely successful
  // converge. By this point args.dryRun is already known false (the dry-run
  // branch returned above) and the earlier non-interactive-without---yes
  // gate means only two shapes can reach here: args.yes (skip — no
  // prompt), or a genuinely interactive run (isInteractive(args)).
  if (!args.yes && isInteractive(args)) {
    await offerSaveProfile(cachedAnswers);
  }
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
// The project `trust` acts on. Routed through `bash -c` (mirrors
// installMissing's bash-wrap pattern): a hermetic test can stub `git` with a
// plain bash script on the stub PATH, which direct spawnSync cannot exec on
// win32. The git line is a
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
//   hooks.improveOnSubmit on|off  -> ADVISORY ONLY. IMPROVE_ON_SUBMIT is
//                                  documented launching-shell-only (HIMMEL-127)
//                                  — nothing sources it from the repo .env —
//                                  so writing it to a file would be a silent
//                                  no-op. Printing the correct manual
//                                  instructions IS the honest mechanism here.
//   hooks.plugin.<name>   on|off  -> `claude plugin enable/disable <name>`
//                                  (same bash-c dispatch pattern as the rest
//                                  of this file), for the documented plugin
//                                  names in full-plugin-enable.json
//                                  (HIMMEL-2304: that table's own wizard
//                                  enable step is gone; hookPluginNames()
//                                  still reads its plugin NAMES here).
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
    // env var read straight from the process env, never sourced from the repo
    // .env, so no file himmelctl could write would activate it. Reject with
    // rc 2 rather than returning a success code for a no-op write — a script
    // checking $? must not read this as "the toggle happened". The how-to
    // guidance still prints.
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
    // Routed through `bash -c` for the same reason every other tool-shellout
    // in this file is: hermetically stubbable with a plain script on PATH,
    // and avoids win32 spawnSync's own PATH resolution picking an unrelated
    // same-named binary over the correct .cmd shim.
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

// augmentPathForRun(homeDir, originalPath) -> {path, dirsToAdd} — the pure
// computation behind cmdDepsEnsure's PATH re-resolution (HIMMEL-2438):
// $HOME/.bun/bin and $HOME/.local/bin, prepended ahead of originalPath,
// skipping any already present there. `path` === originalPath and
// `dirsToAdd` === [] when both are already on it. Extracted as a pure
// function (never touches process.env itself — the caller assigns
// process.env.PATH = result.path) so the CR round-1 (codex-2) no-trailing-
// delimiter fix is unit-testable directly: an empty originalPath must not
// leave a trailing path.delimiter (that reads as an implicit-cwd PATH
// segment), which a live e2e invocation under a genuinely empty PATH cannot
// observe from the outside (the announcement line below only lists
// dirsToAdd, never the joined PATH string itself).
function augmentPathForRun(homeDir, originalPath) {
  const userInstallDirs = [path.join(homeDir, '.bun', 'bin'), path.join(homeDir, '.local', 'bin')];
  const originalPathDirs = (originalPath || '').split(path.delimiter);
  const dirsToAdd = userInstallDirs.filter((d) => !originalPathDirs.includes(d));
  if (dirsToAdd.length === 0) return { path: originalPath, dirsToAdd };
  const newPath = originalPath
    ? `${dirsToAdd.join(path.delimiter)}${path.delimiter}${originalPath}`
    : dirsToAdd.join(path.delimiter);
  return { path: newPath, dirsToAdd };
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

  // HIMMEL-2438: re-resolve PATH for THIS run BEFORE the status pass below
  // (CR round 1, codex-1) — not right before building the plan. A dep a
  // PRIOR run already installed into $HOME/.bun/bin or $HOME/.local/bin
  // must read PRESENT in `missing`'s own computation, or it stays stuck in
  // the plan forever (re-attempted, re-reported "about to install") even
  // though it never needed installing on THIS run at all. The caller's real
  // shell rc only picks these dirs up on their NEXT login shell, and
  // nothing in THIS process (or a child it spawns) sees them without help.
  // Prepending them to process.env.PATH here (never in `status` — an honest
  // read of the CALLER's own PATH is what `status` is for) does three
  // things: (a) `missing` itself is computed against the augmented PATH, so
  // an already-landed dep is never planned again; (b) install-engine's
  // runInstall copies process.env for every child it spawns, so a
  // bun-dependent dep like qmd can see bun installed earlier in the SAME
  // pass; (c) the post-install re-probe further down resolves a dep that
  // landed in one of these dirs instead of reporting the CR-fixed
  // "installed but still not found on PATH" false failure. The ORIGINAL
  // PATH is kept so the honest-counter check further down can tell "present
  // via the augmented PATH" apart from "present on the caller's own PATH".
  const originalPath = process.env.PATH || '';
  const { path: augmentedPath, dirsToAdd } = augmentPathForRun(os.homedir(), originalPath);
  if (dirsToAdd.length > 0) {
    process.env.PATH = augmentedPath;
    console.log(`himmelctl: PATH for this run also includes ${dirsToAdd.join(', ')}`);
  }

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
  // Honest counter (HIMMEL-2438): a dep that only resolves via the
  // PATH-augmented ctx above (never on the caller's OWN original PATH) DID
  // genuinely land — the recheck stays in the installed count, never the
  // "installed but still not found on PATH" failure that used to fire for
  // this exact case (bun's official installer succeeding, then reported as
  // a failure in the same breath). It still gets an extra line naming where
  // it landed, since the caller's own shell won't see it until their rc is
  // updated. Only a dep absent under BOTH paths counts as a genuine failure.
  //
  // Wet-run fix (ubuntu_new clean-tools VM): a manager:"ensure-tools" recipe
  // (git/jq/python3/shellcheck/gitleaks/bun) ALWAYS exits 0 from its own
  // dispatching entry — ensure_tools() is documented to "always return 0;
  // the caller re-checks `command -v` to see what truly remains" — so `ran`
  // containing one of these does NOT mean its underlying install actually
  // claimed success (bun's own installer can fail internally, e.g. a
  // missing unzip, while the wrapping `ensure_tools bun` call still exits
  // 0). "installed but still not found on PATH" implies a specific PATH
  // failure this codepath never actually confirmed for that manager, so it
  // gets the honest "not present after its install recipe ran" wording
  // instead, pointing at ensure-tools.sh's own already-printed diagnostic
  // lines. Every OTHER manager (script/brew/pip/winget) genuinely exits
  // nonzero on failure — reaching `ran` at all there DOES mean the recipe's
  // own process claimed success, so the PATH-specific wording stays
  // accurate for those.
  const osKeyForCtx = ctx.platform === 'win32' ? 'win32' : ctx.platform === 'darwin' ? 'macos' : 'linux';
  const origCtx = { repoRoot: ctx.repoRoot, platform: ctx.platform, env: Object.assign({}, process.env, { PATH: originalPath }) };
  const verified = [];
  for (const r of ran) {
    const dep = byId.get(r.id);
    const recheck = dep && depsEngineLib.depStatus(dep, ctx);
    if (!recheck || recheck.severity === 'red') {
      const recipe = dep && dep.install && dep.install[osKeyForCtx];
      const reason = recipe && recipe.manager === 'ensure-tools'
        ? 'not present after its install recipe ran — see the ensure-tools lines above'
        : 'installed but still not found on PATH';
      failed.push({ id: r.id, type: r.type, reason });
      continue;
    }
    verified.push(r);
    if (dep && !dep.resolver && dirsToAdd.length > 0) {
      const origRecheck = depsEngineLib.depStatus(dep, origCtx);
      if (!origRecheck.present) {
        const resolved = which(dep.cmd, ctx.env || process.env);
        const dir = resolved ? path.dirname(resolved) : dirsToAdd[0];
        console.log(`himmelctl: ${r.id}: installed to ${dir} — not on your PATH; add ${dir} to your shell rc`);
      }
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
  if (args.subcommand === 'gaps') {
    return await cmdGaps(args);
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

// HIMMEL-2438: guard the CLI's own auto-run so a test can `require()` this
// file to reach a pure helper (augmentPathForRun) without triggering the
// whole install-wizard flow (argv parsing against the TEST's own argv,
// process.exit, etc.) — `node scripts/himmelctl/bin.js ...` still runs
// main() exactly as before (require.main === module there); only a
// `require()` from another module skips straight to the export.
if (require.main === module) {
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
}

module.exports = { augmentPathForRun, gitGateHooksState, userSlugState };
