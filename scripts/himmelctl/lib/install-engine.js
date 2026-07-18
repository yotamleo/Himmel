'use strict';
// scripts/himmelctl/lib/install-engine.js — planInstall()/runInstall()
// (HIMMEL-755 A4): the install-descriptor engine `ensure` (A5) drives to
// converge red/degraded manifest items. This engine NEVER re-implements
// wiring/plugin-install/settings-merge logic — every dispatch shells out to
// an EXISTING primitive script (adopt.sh, setup.sh, the wire-*.sh/
// unwire-*.sh libs, install-plugins.sh, qmd-bin.sh's qmd_install), mirroring
// the doctrine test-wizard-noinstall-guard.sh already enforces on bin.js
// itself. Keeping this dispatch table in its OWN file (not bin.js) keeps
// that guard's bin.js-only script-literal scan meaningful — ensure's actual
// primitive invocations live here, covered by this file's own test suite.
//
// planInstall(items, ctx) never spawns and never WRITES to the filesystem:
// it only orders `items` (already filtered to reds/degradeds-with-a-
// runnable-install-descriptor by the caller) and decides coalescing. It is
// NOT otherwise side-effect-free, though: building a linux `dep` entry may
// READ the primary checkout's .env (resolveSudoPassword — never written to)
// and, at most once per call, print a one-line advisory to stderr when no
// HIMMELCTL_SUDO_PASSWORD is configured (see buildEntry's own header).
// runInstall(plan, opts) is the ONLY place that calls spawnSync —
// `dryRun:true` returns before any spawn, so a --dry-run run is provably
// zero-exec (proven by a spawn spy in the test suite).

const fs = require('fs');
const path = require('path');
const os = require('os');
const { spawnSync } = require('child_process');
const { parseDotEnv } = require('./probes.js');

// install.types planInstall/runInstall know how to dispatch. `config` is
// deliberately absent — config-type items are hint-only pre-sub-ticket-D; the
// caller (ensure, A5) must exclude them from the item list handed to
// planInstall in the first place, never rely on this engine to skip them.
const RUNNABLE_INSTALL_TYPES = ['adopt', 'setup', 'wire', 'plugins', 'qmd', 'dep', 'build'];

// The closed `target` vocabulary each target-bearing install type dispatches
// on — the SINGLE source of truth buildEntry()'s switch (and unwireCommand()'s
// 'wire' branch) actually branch on, exported so manifest-lint.mjs can reject
// a typo (e.g. "statuslien") that would otherwise lint clean and silently
// dispatch the WRONG primitive: every non-'statusline' wire target falls
// through to pretooluse-hooks, every non-'jira-cli' build target to
// bitbucket. Keep in lockstep with those branches — a value authored here
// without a matching dispatch site (or vice versa) is a bug.
const INSTALL_TARGETS = {
  wire: ['statusline', 'pretooluse-hooks'],
  build: ['jira-cli', 'bitbucket-cli'],
};

// adopt/setup items COLLAPSE to ONE invocation — each converges the WHOLE
// core bundle in one shot (adopt.sh/setup.sh are monolithic installers), so
// planning two adopt-type items still yields exactly one `adopt.sh` entry.
const COALESCE_TYPES = new Set(['adopt', 'setup']);

// win32 has no bare-name package-manager fallback (unlike brew/apt) — mirror
// bin.js's own WINGET_IDS map for the 5 tools it documents a winget id for;
// every other `dep` item has no known win32 install path (same limitation
// bin.js's installMissing() already documents) and surfaces as a failed
// primitive with a clear reason rather than a doomed spawn.
const WINGET_IDS = {
  git: 'Git.Git',
  jq: 'jqlang.jq',
  python3: 'Python.Python.3.12',
  node: 'OpenJS.NodeJS.LTS',
  npm: 'OpenJS.NodeJS.LTS',
};

function depToolName(item, ctx) {
  const probe = item.probe || {};
  const platform = (ctx && ctx.platform) || process.platform;
  return probe.cmd || (platform === 'win32' ? probe.win32 : probe.posix);
}

// Resolve HIMMELCTL_SUDO_PASSWORD: process.env wins, else the primary
// checkout's .env (mirrors scripts/lib/load-dotenv.sh's own precedence —
// a live env value always wins over the file — and reuses probes.js's
// parseDotEnv rather than writing a third .env parser). Returns null,
// uniformly, whether the var is genuinely unset OR present-but-empty (an
// empty string is never treated as "configured") — callers must never
// reveal WHICH of those two cases applies, only "not configured".
// SECURITY: never logged, never returned to a caller that might print it —
// only consumed to build a spawnSync `input` string (stdin), never argv.
function resolveSudoPassword(repoRoot) {
  if (process.env.HIMMELCTL_SUDO_PASSWORD) return process.env.HIMMELCTL_SUDO_PASSWORD;
  try {
    const raw = fs.readFileSync(path.join(repoRoot, '.env'), 'utf8');
    const parsed = parseDotEnv(raw);
    if (parsed.HIMMELCTL_SUDO_PASSWORD) return parsed.HIMMELCTL_SUDO_PASSWORD;
  } catch (_e) {
    // .env absent/unreadable -> no password available; fall through to null.
  }
  return null;
}

// Build one plan entry's {cmd,args} for a given manifest item + its install
// descriptor. `ctx` = { repoRoot, scope, profile, targetPath, platform? }.
// `ctx.platform` overrides process.platform when present — the ONLY way
// this file's platform-branched logic (win32/darwin/linux) is testable
// deterministically from a single host (the hermetic suite runs on
// Windows Git Bash and needs to exercise the linux/darwin branches too).
// `diagnosticState` (optional, shared across every buildEntry() call within
// ONE planInstall() run — see planInstall()'s own header) tracks whether
// the "no HIMMELCTL_SUDO_PASSWORD configured" diagnostic has already
// printed this run, so it prints AT MOST once regardless of how many linux
// dep items need sudo without a password.
function buildEntry(item, ctx, diagnosticState) {
  const install = item.install;
  const platform = (ctx && ctx.platform) || process.platform;
  const scriptsDir = path.join(ctx.repoRoot, 'scripts');
  switch (install.type) {
    case 'adopt':
      return { cmd: 'bash', args: [path.join(scriptsDir, 'adopt.sh'), '--profile', ctx.profile, '--scope', ctx.scope, '--target', ctx.targetPath] };
    case 'setup':
      return { cmd: 'bash', args: [path.join(scriptsDir, 'setup.sh')] };
    case 'wire': {
      const settings = settingsPath(ctx.scope, ctx.targetPath, ctx.env);
      if (install.target === 'statusline') {
        return { cmd: 'bash', args: [path.join(scriptsDir, 'lib', 'wire-statusline.sh'), settings, ctx.repoRoot] };
      }
      // 'pretooluse-hooks' (the other authored wire target). prefix mirrors
      // adopt.sh's own convention: $CLAUDE_PROJECT_DIR for project scope, the
      // himmel clone's abs path for user scope.
      const prefix = ctx.scope === 'user' ? ctx.repoRoot : '$CLAUDE_PROJECT_DIR';
      return { cmd: 'bash', args: [path.join(scriptsDir, 'lib', 'wire-pretooluse-hooks.sh'), settings, prefix] };
    }
    case 'plugins':
      // install-plugins.sh stays the tested, parameterized orchestrator
      // (--scope/--template/HIMMEL-1032 lean-floor reconcile) — this engine
      // never re-implements or collapses it.
      return { cmd: 'bash', args: [path.join(scriptsDir, 'machine-setup', 'install-plugins.sh'), '--scope', ctx.scope] };
    case 'qmd': {
      // CR fix: the resolver path is passed as a bash POSITIONAL arg ($1),
      // never interpolated into the -c script text — a checkout path
      // carrying a space or apostrophe (e.g. "C:/Users/John O'Brien/...")
      // would otherwise break the quoting. spawnSync's argv is never
      // shell-re-parsed, so a positional arg is safe regardless of content.
      // CR fix (CodeRabbit round 19): qmd_install only installs the BINARY.
      // The qmd-index probe stays RED until BOTH the himmel and luna
      // collections are registered, so this same flow invokes the existing
      // qmd_register_collection() (scripts/lib/qmd-bin.sh — $1 = path, $2 =
      // name) for each, right after qmd_install. The two collection paths
      // ride the SAME positional-arg channel ($2 himmel = ctx.repoRoot, $3
      // luna = ctx.vaultPath) — never interpolated into the -c text, for the
      // same quoting-safety reason as $1. Chained with && so a registration
      // failure propagates as a nonzero exit (runInstall classifies it
      // failed[]) rather than being swallowed — a red qmd-index must not
      // false-green on a binary-only install.
      const resolverPath = path.join(scriptsDir, 'lib', 'qmd-bin.sh');
      const himmelPath = ctx.repoRoot;
      const lunaPath = ctx.vaultPath || '';
      // CR fix (CodeRabbit round 20): a no-vault adopter has ctx.vaultPath
      // === '' (bin.js's vaultPath stays '' when vault.mode='none', and
      // expandHome('') === '' — so ctx.vaultPath is legitimately EMPTY). The
      // qmd-index probe (manifest.json) requires BOTH the himmel AND luna
      // collections, and qmd-binary/qmd-index are profiles:["luna","all"], so
      // they ARE desired+red under --profile luna/all even with NO vault
      // configured. Without this guard the flow below would run
      // `qmd_register_collection "" luna` — registering an empty/wrong dir
      // AFTER consent/state persistence — and qmd-index STILL could never go
      // green (the luna collection has no real path). Return a hint-only
      // unrunnable entry (mirrors the winget branch's own `!id` guard above)
      // so ensure surfaces the real fix (configure a vault via 'himmelctl
      // install', then re-run) instead of a corrupt registration. Do NOT
      // register only `himmel` and call it converged: the probe needs BOTH
      // collections, so a one-collection "converged" would be the exact
      // false-green this PR has been fighting.
      if (!lunaPath) {
        return { unrunnable: "no luna vault path configured — configure one via 'himmelctl install', then re-run" };
      }
      return { cmd: 'bash', args: ['-c', '. "$1" && qmd_install && qmd_register_collection "$2" himmel && qmd_register_collection "$3" luna', 'himmel-qmd', resolverPath, himmelPath, lunaPath] };
    }
    case 'build': {
      // Same positional-arg fix as 'qmd' above, for the build dir.
      // CR fix: an explicit if/else, NOT `bun … || (npm …)` — the `||` form
      // masks a bun install/build FAILURE by falling through to npm. With the
      // branch, a failing bun path propagates its failure; npm runs only when
      // bun is genuinely absent.
      const dir = install.target === 'jira-cli' ? path.join(scriptsDir, 'jira') : path.join(scriptsDir, 'bitbucket');
      return {
        cmd: 'bash',
        args: ['-c', 'cd "$1" && (if command -v bun >/dev/null 2>&1; then bun install && bun run build; else npm install && npm run build; fi)', 'himmel-build', dir],
      };
    }
    case 'dep': {
      const tool = depToolName(item, ctx);
      if (platform === 'win32') {
        const id = WINGET_IDS[tool];
        if (!id) return { unrunnable: `no winget id known for '${tool}' — install it manually` };
        // CR fix: --silent + --disable-interactivity + the two --accept-*
        // flags — without them winget PROMPTS (source/package agreements),
        // which hangs an unattended `ensure` (the whole point is running
        // outside a Claude session, non-interactively).
        //
        // CR fix (CodeRabbit round 16 — Fable, injection-hardening
        // consistency): `id` used to be interpolated straight into the -c
        // string (`` `winget install --id ${id} ...` ``) — the SAME class
        // of shell-injection surface the 'qmd'/'build' cases above were
        // already hardened against, just missed here. `id` comes from the
        // lint-gated WINGET_IDS map (real risk low), but the fix is cheap
        // and keeps every buildEntry() case consistent: pass it as a bash
        // POSITIONAL arg ($1), never re-interpolated into the script text.
        return { cmd: 'bash', args: ['-c', 'winget install --id "$1" -e --silent --disable-interactivity --accept-source-agreements --accept-package-agreements', 'himmel-dep', id] };
      }
      const pkg = platform === 'darwin' && tool === 'npm' ? 'node' : tool;
      if (platform === 'darwin') {
        // CR fix (CodeRabbit round 16 — Fable, injection-hardening
        // consistency): same fix as the winget branch above — `pkg` as a
        // positional arg, not interpolated into the -c string.
        return { cmd: 'bash', args: ['-c', 'brew install "$1"', 'himmel-dep', pkg] };
      }
      // Linux: prefer a configured HIMMELCTL_SUDO_PASSWORD, passed to sudo
      // on STDIN ONLY — never argv (ps-visible), never a log line, never a
      // DRY: print, never a failed[] reason. `-S` reads the password from
      // stdin; `-p ''` suppresses sudo's own prompt text so nothing sudo
      // itself writes could echo a hint about the value. `env
      // DEBIAN_FRONTEND=noninteractive` (not a bare env-var-prefix, which
      // sudo would treat as PART of the command line rather than the
      // command's environment) keeps apt/debconf from prompting even once
      // authenticated.
      // CR fix (HIMMEL-1119 item 1 — secret-in-plan shape): the credential is
      // resolved at EXEC time (runHardenedSpawn, the single spawnSync site),
      // NOT here at plan time. This returned entry must NEVER hold the live
      // secret — any present or future code that logs, serializes, returns, or
      // prints a plan would leak it (a round-17 finding already caught a test
      // that JSON.stringify'd this plan and would have printed the REAL
      // HIMMELCTL_SUDO_PASSWORD on a Linux runner; pinning ctx.platform in
      // those tests treated the symptom, not the shape). The plan keeps ONLY
      // the BOOLEAN "is a password configured?" (resolveSudoPassword called
      // here for the boolean, value discarded) to choose the `sudo -S -p ''`
      // form below vs. the fail-fast `sudo -n` form; when the password form is
      // chosen the entry carries a NON-SECRET marker (needsSudoPassword) +
      // repoRoot (non-secret — a checkout path; threaded here so the exec path
      // can resolve the real credential immediately before the spawn) — never
      // the value, under any key.
      const passwordConfigured = !!resolveSudoPassword(ctx.repoRoot);
      if (passwordConfigured) {
        return {
          cmd: 'sudo',
          args: ['-S', '-p', '', 'env', 'DEBIAN_FRONTEND=noninteractive', 'apt-get', 'install', '-y', pkg],
          needsSudoPassword: true,
          repoRoot: ctx.repoRoot,
        };
      }
      // No password configured (unset OR empty — see resolveSudoPassword's
      // own header; never distinguish the two) -> the fail-fast form, so
      // an adopter without the var gets a clean immediate failure instead
      // of a hang. Surfaced via a ONE-PER-RUN diagnostic (diagnosticState,
      // shared across every buildEntry() call planInstall() makes) rather
      // than silently emitting the doomed-without-a-cached-credential form
      // with no explanation — never prints the value (there isn't one).
      if (diagnosticState && !diagnosticState.sudoWarned) {
        diagnosticState.sudoWarned = true;
        console.error(
          "himmelctl: no HIMMELCTL_SUDO_PASSWORD configured — using sudo -n (fails fast if sudo needs a password). "
          + "Set it in the primary checkout's .env for unattended apt installs.",
        );
      }
      // CR fix (CodeRabbit round 16 — Fable, injection-hardening
      // consistency): `pkg` as a positional arg, not interpolated into the
      // -c string — same fix as the winget/brew branches above.
      return { cmd: 'bash', args: ['-c', 'sudo -n DEBIAN_FRONTEND=noninteractive apt-get install -y "$1"', 'himmel-dep', pkg] };
    }
    default:
      return { unrunnable: `unrecognized install.type '${install.type}'` };
  }
}

// Scope-appropriate settings.json path — mirrors bin.js's own
// settingsPathForScope(), parameterized by an explicit targetPath rather
// than reading process.cwd() (same design principle as status-report.js).
// CR correction: a prior review suggested switching to bare os.homedir() —
// REJECTED. That would break the hermetic test convention this codebase
// already relies on (probes.js:103's resolveConfigFile, bin.js's own
// settingsPathForScope) AND could make a user-scope test write to the
// operator's REAL ~/.claude/settings.json when HOME isn't overridden.
// Instead `env` is threaded through explicitly (mirrors probes.js:103's
// `(ctx.env && ctx.env.HOME) || os.homedir()` exactly) so callers pass
// process.env and tests inject a scratch HOME via ctx.env.
function settingsPath(scope, targetPath, env) {
  if (scope === 'user') return path.join((env && env.HOME) || os.homedir(), '.claude', 'settings.json');
  return path.join(targetPath, '.claude', 'settings.json');
}

// planInstall(items, ctx) -> [{id, type, cmd, args, deps, coalesceKey?}]
// `items` = manifest items already filtered by the caller to those needing
// convergence (red/degraded, with a runnable install descriptor). Ordered by
// deps[] (DFS post-order over the GIVEN item set only — a dep outside that
// set is treated as already-satisfied, since ensure only hands this function
// items that still need converging). A cycle throws (defense-in-depth;
// manifest-lint.mjs's own DFS cycle detector already rejects a cyclic
// manifest, so this should never fire against a lint-clean manifest).
//
// CR fix: coalescing (adopt/setup collapse to ONE invocation) now happens
// BEFORE topological ordering, not after — items sharing a COALESCE_TYPE are
// grouped into ONE graph node up front, and that node's dep edges are the
// UNION of every member item's deps (minus any dep that points at another
// member of the SAME group, which would otherwise be a self-loop post-merge).
// Coalescing-after-ordering (the shipped-then-buggy approach) used only the
// FIRST occurrence's deps for the merged node's graph position, so a
// prerequisite reachable only through the SECOND occurrence could sort
// AFTER the coalesced action instead of before it. Each plan entry also now
// carries `deps` (the OTHER PLAN ENTRIES' ids this one depends on) so
// runInstall() can skip a dependent after its prerequisite fails.
function planInstall(items, ctx) {
  const byId = new Map(items.map((it) => [it.id, it]));
  // Shared across every buildEntry() call THIS run makes — see buildEntry's
  // own header — so the "no HIMMELCTL_SUDO_PASSWORD configured" diagnostic
  // prints at most once per planInstall() invocation, not once per linux
  // dep item.
  const diagnosticState = { sudoWarned: false };

  // groupIdForItem: item.id -> its graph node id. A coalesce-type item's
  // node id is shared across every item of that type (`__coalesce__<type>`);
  // every other item is its own singleton node (keyed by its own id).
  const groupIdForItem = new Map();
  const itemsInGroup = new Map(); // groupId -> [item, ...] (first-seen order)
  for (const item of items) {
    const install = item.install;
    if (!install || RUNNABLE_INSTALL_TYPES.indexOf(install.type) === -1) continue;
    const groupId = COALESCE_TYPES.has(install.type) ? `__coalesce__${install.type}` : item.id;
    groupIdForItem.set(item.id, groupId);
    if (!itemsInGroup.has(groupId)) itemsInGroup.set(groupId, []);
    itemsInGroup.get(groupId).push(item);
  }

  // The plan entry emitted for a group carries the FIRST member's id (same
  // convention the shipped code already used for buildEntry) — this is also
  // what a dependent entry's `deps` array references.
  const groupRepresentativeId = new Map();
  for (const [groupId, groupItems] of itemsInGroup) {
    groupRepresentativeId.set(groupId, groupItems[0].id);
  }

  // Union of deps per group, translated to GROUP ids.
  const groupDeps = new Map();
  for (const [groupId, groupItems] of itemsInGroup) {
    const deps = new Set();
    for (const item of groupItems) {
      for (const dep of item.deps || []) {
        if (!byId.has(dep)) continue; // outside the given item set — already satisfied
        const depGroup = groupIdForItem.get(dep);
        if (!depGroup || depGroup === groupId) continue; // no install descriptor, or same-group self-ref
        deps.add(depGroup);
      }
    }
    groupDeps.set(groupId, [...deps]);
  }

  // Topological order over GROUPS (not raw items).
  const WHITE = 0;
  const GRAY = 1;
  const BLACK = 2;
  const color = new Map();
  for (const groupId of itemsInGroup.keys()) color.set(groupId, WHITE);
  const orderedGroups = [];

  function visit(groupId) {
    const state = color.get(groupId);
    if (state === BLACK) return;
    if (state === GRAY) throw new Error(`planInstall: dependency cycle detected at '${groupId}'`);
    color.set(groupId, GRAY);
    for (const dep of groupDeps.get(groupId) || []) visit(dep);
    color.set(groupId, BLACK);
    orderedGroups.push(groupId);
  }
  // Visit in the ORIGINAL items order (stable — matches the shipped
  // per-item DFS's own traversal order for non-coalesced items), deduped
  // via groupIdForItem so each group is visited exactly once.
  const seenGroups = new Set();
  for (const item of items) {
    const groupId = groupIdForItem.get(item.id);
    if (!groupId || seenGroups.has(groupId)) continue;
    seenGroups.add(groupId);
    visit(groupId);
  }

  const plan = [];
  for (const groupId of orderedGroups) {
    const groupItems = itemsInGroup.get(groupId);
    const representative = groupItems[0];
    const install = representative.install;
    const built = buildEntry(representative, ctx, diagnosticState);
    const depIds = (groupDeps.get(groupId) || []).map((g) => groupRepresentativeId.get(g)).filter(Boolean);
    const entry = { id: representative.id, type: install.type, deps: depIds, ...built };
    if (COALESCE_TYPES.has(install.type)) entry.coalesceKey = install.type;
    plan.push(entry);
  }
  return plan;
}

// reverseDependencyOrder(items) -> items reordered so a DEPENDENT item (one
// whose deps[] includes another item in the SAME set) is unwound BEFORE the
// item it depends on — the inverse of planInstall's install-time
// topological order. CR fix (toward-disabled dispatch, ensure A5b): tearing
// down must happen in reverse build order — if B was wired ON TOP OF A (B
// deps on A), B must be unwired first, or the unwind can leave a dangling
// reference / undo things in an order the original wiring never assumed.
// A simple DFS post-order (same shape as manifest-lint.mjs's own dep-cycle
// detector and planInstall's pre-coalescing traversal) over `items`' OWN
// `deps` field (not `.install`-derived — this works for ANY item carrying
// deps, independent of whether it has a runnable install descriptor),
// reversed. Ignores a dep that points outside the given item set (same
// convention planInstall uses — an out-of-set dep is treated as already
// resolved/irrelevant to this ordering). A cycle throws (defense-in-depth;
// manifest-lint.mjs's own cycle detector already rejects a cyclic manifest).
function reverseDependencyOrder(items) {
  const byId = new Map(items.map((it) => [it.id, it]));
  const WHITE = 0;
  const GRAY = 1;
  const BLACK = 2;
  const color = new Map();
  for (const it of items) color.set(it.id, WHITE);
  const ordered = [];

  function visit(id) {
    const state = color.get(id);
    if (state === BLACK) return;
    if (state === GRAY) throw new Error(`reverseDependencyOrder: dependency cycle detected at '${id}'`);
    color.set(id, GRAY);
    const item = byId.get(id);
    for (const dep of item.deps || []) {
      if (byId.has(dep)) visit(dep);
    }
    color.set(id, BLACK);
    ordered.push(item);
  }
  for (const it of items) visit(it.id);

  return ordered.reverse();
}

// CR fix: installs legitimately take minutes (npm/bun install+build,
// apt-get, winget, ...) — a MUCH larger default than probes.js's
// spawnProbeSync's own 10s probe timeout, but a wedged installer must
// still not hang an unattended `ensure` forever. Read fresh on every call
// (not cached at module load) so a test can inject a tiny value via the
// env var without needing to reload this module. An invalid/non-positive
// override falls back to the default rather than disabling the timeout.
const DEFAULT_INSTALL_TIMEOUT_SECS = 900;
function installTimeoutMs() {
  const raw = process.env.INSTALL_TIMEOUT_SECS;
  const secs = raw ? Number(raw) : DEFAULT_INSTALL_TIMEOUT_SECS;
  return (Number.isFinite(secs) && secs > 0 ? secs : DEFAULT_INSTALL_TIMEOUT_SECS) * 1000;
}

// runHardenedSpawn(entry) -> {ok:true} | {ok:false, reason}
// The SINGLE hardened spawnSync call every himmelctl-driven primitive goes
// through — installs (runInstall, below) AND unwinds (runUnwire, below)
// alike. `entry` = {cmd, args, input?, needsSudoPassword?, repoRoot?}, the
// SAME shape buildEntry() and unwireCommand() both produce. Extracted (CR
// fix — a cross-model review caught that bin.js's toward-disabled unwire
// dispatch had its OWN raw
// spawnSync call that got NEITHER of the hardenings below when they first
// landed on the install path — exactly the drift a shared implementation
// prevents) so install and unwire can never fall out of hardening sync
// again: fix it ONCE, here, and both call sites get it.
//
// A spawn launch failure, a nonzero exit, OR a signal-terminated primitive
// (r.signal set — killed, not a clean exit; r.status is null in that case,
// so it must be checked explicitly rather than falling through to the
// r.status!==0 nonzero-exit branch, which would silently classify a signal
// kill as success) all count as failed (fail-closed, never silent).
//
// CR fix: an entry carrying `input` (the linux sudo-with-password dep form)
// has that string piped to the child's stdin — see the spawnOpts branch
// below. SECURITY: `entry.input` (when present) holds a raw credential —
// never returned to the caller, never logged.
//
// CR fix: every spawnSync call carries a timeout (installTimeoutMs(),
// default 900s, overridable via INSTALL_TIMEOUT_SECS — see its own header)
// + killSignal:'SIGKILL', so a wedged primitive (install OR unwire) can't
// hang an unattended `ensure` forever. A timed-out entry fails with a
// "timed out after Ns" reason — see the ETIMEDOUT branch below. On timeout
// the WHOLE process tree is killed, not just the direct child — see
// childEnv/isWin/the ETIMEDOUT branch's own comments for how.
//
// CR fix (SECURITY, secret leak): every spawned child gets an EXPLICIT env
// — process.env with HIMMELCTL_SUDO_PASSWORD deleted — never the default
// (spawnSync inherits process.env verbatim when `env` is omitted). Putting
// the password on stdin (above) is necessary but NOT sufficient: an
// inherited env var is readable from /proc/<pid>/environ by any same-uid
// process for the child's whole lifetime, AND is inherited by every
// grandchild the primitive spawns (apt hooks, postinst scripts, ...) — none
// of which need it, since `sudo -S` only ever reads the password from
// stdin. Applied to EVERY entry, not only input-bearing ones (defense in
// depth — an unwire primitive never carries `input` at all today, but gets
// the SAME scrub for free by going through this one function).
//
// Platform split: POSIX and win32 need genuinely different tree-kill
// mechanisms (see runHardenedSpawnPosix/runHardenedSpawnWin32's own
// headers), so this dispatches to one or the other rather than cramming
// both into a single spawnSync call shape.
function runHardenedSpawn(entry) {
  // CR fix (HIMMEL-1119 item 1): resolve the sudo credential HERE, at the
  // single hardened spawnSync site — immediately before the spawn — never at
  // plan time (see buildEntry's 'dep' case, which emits only the NON-SECRET
  // marker `needsSudoPassword` + `repoRoot`). The live credential lives ONLY
  // in this stack frame's local `entry` COPY (the caller's plan object is
  // never mutated, so a plan logged/serialized after the run still carries no
  // secret), then feeds the child's stdin exactly as before via
  // spawnOpts.input. resolveSudoPassword is pure (reads process.env + the
  // .env file) and
  // already returned truthy for this entry at plan time, so the same value
  // resolves here deterministically — the resolution happens BEFORE childEnv
  // is built and scrubbed below, so the password reaches stdin but never the
  // child's env.
  if (entry.needsSudoPassword) {
    const password = resolveSudoPassword(entry.repoRoot);
    entry = Object.assign({}, entry, { input: `${password}\n` });
  }
  const timeoutMs = installTimeoutMs();
  const childEnv = Object.assign({}, process.env);
  // CR fix (SECURITY, MAJOR): Windows env var names are case-insensitive —
  // an exact-case `delete childEnv.HIMMELCTL_SUDO_PASSWORD` only removes a
  // key spelled EXACTLY that way. Object.assign copies process.env's own
  // keys with whatever casing the underlying environment block actually
  // carries, so a differently-cased HIMMELCTL_SUDO_PASSWORD would survive
  // the exact-case delete and leak into the child's env. Scrub every key
  // that matches case-insensitively instead (a no-op extra check on POSIX,
  // where case differences are genuinely different variables, so this can
  // never over-delete an unrelated var there either).
  for (const key of Object.keys(childEnv)) {
    if (key.toUpperCase() === 'HIMMELCTL_SUDO_PASSWORD') delete childEnv[key];
  }
  return process.platform === 'win32'
    ? runHardenedSpawnWin32(entry, timeoutMs, childEnv)
    : runHardenedSpawnPosix(entry, timeoutMs, childEnv);
}

// runHardenedSpawnPosix(entry, timeoutMs, childEnv) -> {ok:true} | {ok:false, reason}
// CR fix: an entry carrying `input` (the linux sudo-with-password dep form
// — see buildEntry's 'dep' case) needs its stdin PIPED so the password can
// be written to it, instead of 'inherit' (which connects the child
// directly to the parent's own stdin/terminal and provides no way to feed
// it programmatically). Every other entry keeps the exact shipped
// { stdio: 'inherit' } behavior unchanged (only `input`/`stdio` differ;
// `timeout`/`killSignal`/`env` apply to BOTH forms). `detached:true` makes
// entry.cmd the leader of its OWN new process group — required so a
// timeout's group-kill (below) can target ONLY the primitive's tree, never
// our own process group (without the detach, entry.cmd would share OUR
// process group, and a negative-pid kill would take our own process down
// with it).
function runHardenedSpawnPosix(entry, timeoutMs, childEnv) {
  const spawnOpts = Object.assign(
    entry.input !== undefined
      ? { input: entry.input, stdio: ['pipe', 'inherit', 'inherit'] }
      : { stdio: 'inherit' },
    { timeout: timeoutMs, killSignal: 'SIGKILL', env: childEnv, detached: true },
  );
  const r = spawnSync(entry.cmd, entry.args, spawnOpts);
  // CR fix: a timed-out spawnSync sets r.error.code==='ETIMEDOUT' (Node also
  // SIGKILLs the child, so r.signal is typically ALSO set) — checked FIRST,
  // before the generic r.error branch, so a wedged primitive fails with a
  // CLEAR "timed out after Ns" reason instead of a raw "spawnSync <cmd>
  // ETIMEDOUT" error message.
  if (r.error && r.error.code === 'ETIMEDOUT') {
    // CR fix: spawnSync's OWN timeout kill only reaches entry.cmd itself
    // (e.g. bash) — a grandchild it spawned (apt-get, a postinst hook, ...)
    // can survive and keep running/hung in the background. detached:true
    // (above) made entry.cmd the leader of its OWN process group (pgid ===
    // its own pid) — process.kill(-pid, 'SIGKILL') signals every process in
    // THAT group. Best-effort: r.pid may be unset if the spawn itself never
    // succeeded (shouldn't happen for a genuine ETIMEDOUT, which implies
    // the child DID start), and the target may already be gone (ESRCH) —
    // either way, swallow and still report the timeout below.
    //
    // CR fix (CodeRabbit round 17, item 2) — the LIMIT of this mechanism,
    // stated explicitly: a process-group kill is NOT escape-proof. It
    // reaches exactly the processes still in THIS group, so any descendant
    // that deliberately left it — setsid()/setpgid() into a new session or
    // group, or a double-fork daemonization — survives, and so does a
    // descendant re-parented to init while sitting in another group. This
    // is the one real asymmetry with the win32 branch: a Job Object is
    // escape-proof by construction (membership is inherited and cannot be
    // renounced), which is precisely why that side is worth its complexity.
    // POSIX has no equivalent primitive here, so this path is best-effort
    // BY DESIGN and cannot promise the tree is gone — only that everything
    // still in the group was signalled. The timeout is still reported as a
    // failure either way (fail-closed), so an escaped straggler degrades
    // cleanup, never the correctness of the result we return.
    if (r.pid) {
      try {
        process.kill(-r.pid, 'SIGKILL');
      } catch (_e) {
        // already gone, or never had any descendants — nothing to clean up.
      }
    }
    return { ok: false, reason: `timed out after ${Math.round(timeoutMs / 1000)}s` };
  }
  if (r.error) return { ok: false, reason: r.error.message };
  if (r.signal) return { ok: false, reason: `terminated by signal ${r.signal}` };
  if (typeof r.status === 'number' && r.status !== 0) return { ok: false, reason: `exited ${r.status}` };
  return { ok: true };
}

// The exit code job-run.ps1 uses to signal "I killed this on timeout" —
// MUST match that script's own $TIMEOUT_EXIT_CODE constant exactly. Chosen
// deliberately outside the 0-255 range most CLI tools' own exit codes stay
// within, to minimize (not eliminate — no code is 100% collision-proof;
// the SAME residual-ambiguity tradeoff already accepted for POSIX's own
// ETIMEDOUT/signal-also-set nuance) the chance a genuinely-succeeding
// wrapped command's OWN real exit code is misread as a timeout.
const JOB_RUN_TIMEOUT_EXIT_CODE = 4217;

// The exit code job-run.ps1 uses to signal "Job Object setup failed and I
// refused to run/continue without tree-kill protection" (CodeRabbit round
// 15, item 2 — fail-closed, not a silent degrade to weaker best-effort
// cleanup). MUST match that script's own $JOB_SETUP_FAILED_EXIT_CODE
// constant exactly.
const JOB_RUN_SETUP_FAILED_EXIT_CODE = 4218;

// The exit code job-run.ps1 uses to signal "WaitForExit threw and I
// couldn't confirm the wrapped command actually completed, so I killed
// the tree defensively" (CodeRabbit round 16, item 3 — Fable-confirmed
// fail-open: the old catch treated a wait exception as "not a timeout,"
// which released the job while the tree kept running unbounded). Distinct
// from JOB_RUN_TIMEOUT_EXIT_CODE — this did NOT genuinely run past
// -TimeoutSeconds, the wait itself just failed — but gets the same
// tree-kill-then-fail treatment. MUST match job-run.ps1's own
// $WAIT_FAILED_EXIT_CODE constant exactly.
const JOB_RUN_WAIT_FAILED_EXIT_CODE = 4219;

// The exit code job-run.ps1 uses to signal "the wrapped command succeeded,
// but I could not clear KILL_ON_JOB_CLOSE before releasing the job, so
// closing the handle may have killed a legitimate background descendant it
// launched" (codex round 17 — the same fail-OPEN class as round 16's
// WaitForExit find: the old success branch exited with the wrapped
// command's OWN success code, so ensure reported green immediately after
// potentially breaking the service it just installed). This spawn is
// classified by exit code alone — job-run's stderr warning is never read —
// so the sentinel is the only channel that can carry it. MUST match
// job-run.ps1's own $CLEANUP_FAILED_EXIT_CODE constant exactly.
const JOB_RUN_CLEANUP_FAILED_EXIT_CODE = 4220;

// runHardenedSpawnWin32(entry, timeoutMs, childEnv) -> {ok:true} | {ok:false, reason}
// CR fix (win32 tree-kill, HIMMEL-755): `taskkill /PID <pid> /T /F` (the
// PREVIOUS win32 cleanup) walks the CURRENT process snapshot's
// ParentProcessID chain starting from the root pid, AT KILL TIME — a
// descendant that has already re-parented (exactly what installers and
// package postinst/daemon scripts do: spawn a background daemon inside a
// subshell that itself exits immediately) can be MISSED. Verified
// empirically against a genuine re-parenting reproduction: taskkill left
// the grandchild running; routing through job-run.ps1's Windows Job Object
// (JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE — every descendant automatically
// joins the SAME job at creation, nested-job support, so there's no
// re-parenting escape and no snapshot-timing race) did not. See
// test-wizard-install-engine.sh's win32 tree-kill cases for the harness
// that proves this both ways, and job-run.ps1's own header for the full
// design (why PowerShell/P-Invoke rather than a native npm binding —
// koffi/ffi-napi would violate the zero-new-deps doctrine — and the
// base64+JSON argument transport, needed because plain multi-token
// `-CommandArgs` binding and raw-JSON-in-argv were both tried and broke).
//
// entry.cmd/entry.args are passed to job-run.ps1, NOT spawned directly —
// job-run.ps1 owns the ENTIRE spawn+wait+timeout+kill lifecycle for the
// wrapped command internally; Node's own `timeout` here is a BACKSTOP only
// (job-run.ps1 should always return within its own -TimeoutSeconds
// budget), with a grace period absorbing PowerShell's own cold-start
// overhead (Add-Type P/Invoke compilation, ~1-2s). If the backstop EVER
// fires, killing powershell.exe still triggers the SAME Job Object
// kill-on-close — Windows closes every handle a terminated process held,
// including the job handle, as part of normal process teardown.
//
// SECURITY: entry.input (when present) is piped to POWERSHELL's OWN stdin
// via spawnSync's `input` option — the EXACT same mechanism the POSIX
// branch uses — and job-run.ps1 relays it verbatim, hop-by-hop, to the
// wrapped command's stdin. It is NEVER placed in job-run.ps1's argv, in
// ANY encoding: an earlier draft base64-encoded it into a `-InputTextB64`
// CLI argument and was caught and reverted before shipping — base64 is
// encoding, not encryption, and a base64'd secret in a command line is
// still fully `ps`/Task-Manager-visible to any other user on the box,
// trivially reversible. See job-run.ps1's own header for the full
// before/after. entry.args (never itself secret — buildEntry's sudo entry
// puts the password ONLY in `.input`) is fine over base64+argv; the
// credential itself is not, under any encoding.
function runHardenedSpawnWin32(entry, timeoutMs, childEnv) {
  const jobRunScript = path.join(__dirname, 'job-run.ps1');
  const psArgs = [
    // CR fix: without -ExecutionPolicy Bypass, a machine at the DEFAULT
    // Windows client policy (Restricted) or Server default (RemoteSigned)
    // refuses to load job-run.ps1 at all ("running scripts is disabled on
    // this system") — EVERY win32 install/unwire would fail before the
    // wrapper even started. Only this dev box's LocalMachine=Unrestricted
    // policy masked it locally. Bypass (not Unrestricted) is
    // process-scoped: it applies to this ONE invocation only, changes no
    // machine/user policy, and prompts for nothing — mirrors the SAME flag
    // bin.js's own setup.ps1/uninstall.ps1 invocations already carry.
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', jobRunScript,
    '-Command', entry.cmd,
    '-CommandArgsB64', Buffer.from(JSON.stringify(entry.args), 'utf8').toString('base64'),
    '-TimeoutSeconds', String(Math.round(timeoutMs / 1000)),
  ];
  // NOTE (CodeRabbit round 16 — Fable, dead-parity-surface flag): this
  // branch is not exercised by any PRODUCTION buildEntry() case today —
  // every credential-bearing entry (the sudo-password dep install) is
  // Linux-only, so entry.input is currently always undefined on the win32
  // path in real use. Deliberate parity/future-proofing with the POSIX
  // branch above, not dead code to prune — it's exercised by
  // test-wizard-install-engine.sh's own case m the same as everything else
  // here, and job-run.ps1's own -HasInput relay (see its header) exists
  // specifically so a future win32-relevant credential path has this ready
  // rather than needing the stdin-relay design worked out from scratch.
  if (entry.input !== undefined) psArgs.push('-HasInput');
  const backstopMs = timeoutMs + 15000;
  const spawnOpts = Object.assign(
    entry.input !== undefined
      ? { input: entry.input, stdio: ['pipe', 'inherit', 'inherit'] }
      : { stdio: 'inherit' },
    { env: childEnv, timeout: backstopMs, killSignal: 'SIGKILL' },
  );
  const r = spawnSync('powershell', psArgs, spawnOpts);
  if (r.error && r.error.code === 'ETIMEDOUT') {
    return { ok: false, reason: `timed out after ${Math.round(timeoutMs / 1000)}s` };
  }
  if (r.error) return { ok: false, reason: r.error.message };
  if (r.signal) return { ok: false, reason: `terminated by signal ${r.signal}` };
  if (r.status === JOB_RUN_TIMEOUT_EXIT_CODE) {
    return { ok: false, reason: `timed out after ${Math.round(timeoutMs / 1000)}s` };
  }
  if (r.status === JOB_RUN_SETUP_FAILED_EXIT_CODE) {
    return { ok: false, reason: 'Windows Job Object setup failed — refusing to run without tree-kill protection (fail-closed)' };
  }
  if (r.status === JOB_RUN_WAIT_FAILED_EXIT_CODE) {
    return { ok: false, reason: 'could not confirm completion (WaitForExit failed) — tree killed defensively' };
  }
  if (r.status === JOB_RUN_CLEANUP_FAILED_EXIT_CODE) {
    return { ok: false, reason: 'command succeeded but releasing the Job Object may have killed its background descendants (failed to clear KILL_ON_JOB_CLOSE) — reporting failure rather than a false green' };
  }
  if (typeof r.status === 'number' && r.status !== 0) return { ok: false, reason: `exited ${r.status}` };
  return { ok: true };
}

// runInstall(plan, {dryRun}) -> {ran:[{id,type}], failed:[{id,type,reason}]}
// dryRun:true returns BEFORE any spawnSync — a --dry-run plan is provably
// zero-exec. A plan entry that couldn't be built into a runnable command
// (buildEntry's `unrunnable` case, e.g. an unmapped win32 dep) lands in
// failed[] without ever spawning. Every actually-spawned entry goes through
// runHardenedSpawn() (see its own header for the full hardening list —
// timeout+tree-kill, env-scrubbed credential, signal/ETIMEDOUT
// classification); ran[]/failed[] never carry `entry.input` (SECURITY: a
// raw credential, when present — both arrays only ever hold {id,
// type[, reason]}), never logged.
//
// CR fix: an entry whose `deps` (set by planInstall, see its own header)
// include an id that's ALREADY in failed[] (this run, so far) is SKIPPED
// rather than run — a dependent must not execute after its prerequisite
// failed. The skip itself lands in failed[] too (with a reason naming the
// failed prerequisite) and its own id joins failedIds, so a chain of
// dependents skips transitively.
function runInstall(plan, { dryRun } = {}) {
  const ran = [];
  const failed = [];
  if (dryRun) return { ran, failed };
  const failedIds = new Set();
  for (const entry of plan) {
    const blockedBy = (entry.deps || []).find((d) => failedIds.has(d));
    if (blockedBy) {
      failedIds.add(entry.id);
      failed.push({ id: entry.id, type: entry.type, reason: `skipped: prerequisite '${blockedBy}' failed` });
      continue;
    }
    if (entry.unrunnable) {
      failedIds.add(entry.id);
      failed.push({ id: entry.id, type: entry.type, reason: entry.unrunnable });
      continue;
    }
    const result = runHardenedSpawn(entry);
    if (result.ok) {
      ran.push({ id: entry.id, type: entry.type });
    } else {
      failedIds.add(entry.id);
      failed.push({ id: entry.id, type: entry.type, reason: result.reason });
    }
  }
  return { ran, failed };
}

// unwireCommand(item, ctx) -> {cmd, args} | {unrunnable}
// The toward-disabled counterpart to buildEntry(), for a `removable:per-item`
// item's `unwire` descriptor (A5b). Only the 'wire' unwire type is authored
// in this phase (wiring-statusline/wiring-pretooluse).
function unwireCommand(item, ctx) {
  const unwire = item.unwire;
  if (!unwire || unwire.type !== 'wire') return { unrunnable: 'no runnable unwire descriptor' };
  const scriptsDir = path.join(ctx.repoRoot, 'scripts');
  const settings = settingsPath(ctx.scope, ctx.targetPath, ctx.env);
  if (unwire.target === 'statusline') {
    return { cmd: 'bash', args: [path.join(scriptsDir, 'lib', 'unwire-statusline.sh'), settings] };
  }
  return { cmd: 'bash', args: [path.join(scriptsDir, 'lib', 'unwire-pretooluse-hooks.sh'), settings] };
}

// runUnwire(spec) -> {ok:true} | {ok:false, reason}
// The toward-disabled counterpart to runInstall() — CR fix: bin.js's
// toward-disabled dispatch used to call spawnSync directly with a bare
// {stdio:'inherit'}, getting NEITHER the env-scrub NOR the timeout that
// runInstall's own spawns already had (a cross-model review caught this
// drift after ~10 CodeRabbit rounds). Now routes through the SAME
// runHardenedSpawn() as every install, so the two paths can never diverge
// again. Takes a single unwireCommand() spec (the toward-disabled dispatch
// in bin.js calls this once per item inside its own reverse-dependency-order
// loop, not a batch like runInstall's plan[]) — the caller (bin.js) owns
// the `spec.unrunnable` check and the --dry-run short-circuit (printing its
// own "DRY: unwire <id>" line), exactly as before; this function is only
// ever called on the real, non-dry-run execution path.
function runUnwire(spec) {
  return runHardenedSpawn(spec);
}

module.exports = {
  planInstall, runInstall, unwireCommand, runUnwire, settingsPath, RUNNABLE_INSTALL_TYPES, INSTALL_TARGETS, reverseDependencyOrder,
  resolveSudoPassword,
};
