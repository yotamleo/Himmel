#!/usr/bin/env node
// hooks/wire-plugin-hook-bash.mjs — sanctioned plugin wiring chokepoint (HIMMEL-1526).
// Kept separate from wire-hook-bash.mjs because installed-plugin commands use
// CLAUDE_PLUGIN_ROOT plus optional project-local targets, a different grammar.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXPECTED_COUNTS = Object.freeze({
  PreToolUse: 11,
  SessionStart: 4,
  SessionEnd: 3,
  Notification: 1,
});
const EXPECTED_HOOKS = Object.freeze([
  { event: 'PreToolUse', script: 'inject-minerva-critic.sh', source: 'plugin' },
  { event: 'PreToolUse', script: 'block-docker-privesc.sh' },
  { event: 'PreToolUse', script: 'block-merged-pr-commit.sh' },
  { event: 'PreToolUse', script: 'block-unresolved-cr-merge.sh' },
  // HIMMEL-1649 [codex-adv-1]: fail CLOSED when this hook is missing AND the
  // session is a DISPATCHED WORKER. `--optional` alone exits 0 on a missing
  // script, so a worker holding Edit(<worktree>/**) + Bash(node *)/Bash(bash *)
  // could DELETE this file — one command — and silently disable the guard for
  // every later tool call.
  // The marker is WORKER-NESS, not the provider. HIMMEL_GLM_WORKER=1 is minted
  // by buildGlmEnv (scripts/telegram/glm-env.ts), which only the orchestrator
  // path reaches, and it asserts the session runs in a himmel worktree where
  // this hook is guaranteed present. Its absence is the NORMAL state for an
  // interactive GLM session. Round 5 keyed this on ANTHROPIC_BASE_URL and
  // BRICKED the interactive launcher: its documented primary workload runs with
  // cwd in the luna vault, where the hook legitimately does not exist, so every
  // Bash/PowerShell/MCP call exited 2 before running — and the wrapper refuses
  // before the hook that reads GLM_EXTERNAL_WRITES_OK can bypass it.
  { event: 'PreToolUse', script: 'block-glm-external-writes.sh', failClosedWhen: 'HIMMEL_GLM_WORKER=1' },
  { event: 'PreToolUse', script: 'block-graphify-egress.sh' },
  { event: 'PreToolUse', script: 'block-rogue-codex-wsl.sh' },
  { event: 'PreToolUse', script: 'block-rogue-codex-exec.sh' },
  { event: 'PreToolUse', script: 'block-lesson-enforcement-writes.sh', failClosedWhen: 'HIMMEL_LESSON_LOOP=1' },
  { event: 'PreToolUse', script: 'guard-implementor-dispatch.sh' },
  { event: 'PreToolUse', script: 'guard-console-dispatch.sh' },
  { event: 'SessionStart', script: 'inject-where-are-we.sh' },
  { event: 'SessionStart', script: 'inject-doc-freshness.sh' },
  { event: 'SessionStart', script: 'inject-worktree-nudge.sh' },
  // HIMMEL-1666: pins every $CLAUDE_PROJECT_DIR-relative hook to its
  // git-committed content before any tool call in the session can run, so
  // run-hook-with-bash.js can detect a worker rewriting a guard's on-disk
  // content mid-session (the vector HIMMEL-1649's --fail-closed-when does not
  // cover — that closes only the DELETE case). See run-hook-with-bash.js's
  // "hook integrity" section for the read side.
  { event: 'SessionStart', script: 'record-hook-integrity.sh' },
  { event: 'SessionEnd', script: 'refresh-where-are-we-on-end.sh' },
  { event: 'SessionEnd', script: 'jira-nudge-on-end.sh' },
  { event: 'SessionEnd', script: 'telegram-session-end.sh' },
  { event: 'Notification', script: 'telegram-notification.sh' },
]);
const COMMAND_FIELD = /("command")(\s*:\s*)("(?:\\.|[^"\\])*")/g;
const COMMAND_SENTINEL = '__WIRE_PLUGIN_HOOK_BASH_COMMAND__';

function fail(message) {
  throw new Error(message);
}

function parseJson(text, label) {
  try {
    return JSON.parse(text);
  } catch (error) {
    fail(`${label} is not valid JSON: ${error.message}`);
  }
}

function hookEntries(pluginHooks) {
  const hooks = pluginHooks?.hooks;
  if (!hooks || typeof hooks !== 'object' || Array.isArray(hooks)) {
    fail('hooks must be an object');
  }

  const unexpectedEvents = Object.keys(hooks).filter((name) => !(name in EXPECTED_COUNTS));
  if (unexpectedEvents.length > 0) {
    fail(`hook inventory has unexpected event(s): ${unexpectedEvents.join(', ')}`);
  }

  const entries = [];
  for (const [event, expected] of Object.entries(EXPECTED_COUNTS)) {
    const groups = hooks[event];
    if (!Array.isArray(groups)) fail(`hooks.${event} must be an array`);

    let count = 0;
    groups.forEach((group, groupIndex) => {
      if (!group || !Array.isArray(group.hooks)) {
        fail(`hooks.${event}[${groupIndex}].hooks must be an array`);
      }
      group.hooks.forEach((hook, hookIndex) => {
        entries.push({
          event,
          path: `hooks.${event}[${groupIndex}].hooks[${hookIndex}]`,
          hook,
        });
        count += 1;
      });
    });
    if (count !== expected) {
      fail(`hook inventory mismatch for ${event}: expected ${expected}, found ${count}`);
    }
  }

  if (entries.length !== EXPECTED_HOOKS.length) {
    fail(`hook inventory total mismatch: expected ${EXPECTED_HOOKS.length}, found ${entries.length}`);
  }
  return entries;
}

function unwiredCommand(expected) {
  if (expected.source === 'plugin') {
    return `bash "\${CLAUDE_PLUGIN_ROOT}/hooks/${expected.script}"`;
  }
  if (expected.failClosedWhen) {
    // Derived from the entry, not hardcoded (HIMMEL-1649 round 5): a SECOND
    // fail-closed hook would otherwise generate a recognizer that probes
    // HIMMEL_LESSON_LOOP and names the lesson hook. Split on the FIRST '='
    // only — the value can itself contain '=' (a URL query, say). The `:-0`
    // default is kept verbatim so this entry's existing output stays
    // byte-identical; it is also correct generically, since an unset var
    // collapses to "0" and no real marker value is "0".
    const eq = expected.failClosedWhen.indexOf('=');
    const name = expected.failClosedWhen.slice(0, eq);
    const value = expected.failClosedWhen.slice(eq + 1);
    const hookName = expected.script.replace(/\.sh$/, '');
    return `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${expected.script}"; if [ -f "$h" ]; then exec bash "$h"; elif [ "\${${name}:-0}" = "${value}" ]; then echo "${hookName}: hook script missing while ${expected.failClosedWhen} (stale checkout?) - failing closed" >&2; exit 2; fi'`;
  }
  return `bash -c 'h="$CLAUDE_PROJECT_DIR/scripts/hooks/${expected.script}"; if [ -f "$h" ]; then exec bash "$h"; fi'`;
}

// HIMMEL-2047: sourced (`.` — a shell builtin, no PATH lookup, and not the
// bare-`bash` token HIMMEL-1516 banned from this inventory either), not
// exec'd via a bare `node` — that launcher was unresolvable whenever node
// fell off PATH (the nvm-windows migration window that dropped these
// SessionEnd hooks silently). run-node.sh resolves node at runtime
// (resolve-node.sh's resolve_node()) and execs it — the same helper
// HIMMEL-2015 gave individual project hook scripts, applied here to the
// launcher itself.
//
// VENDORED into the plugin (marketplace/plugins/himmel-ops/hooks/run-node.sh
// + resolve-node.sh, byte-identical to scripts/lib/'s copies — same pattern
// run-hook-with-bash.js already uses), NOT sourced from
// $CLAUDE_PROJECT_DIR/scripts/lib/: that path is attacker-controlled for any
// project the plugin is active in, and CR round 2's critic-panel finding
// [codex-1] (Critical) is right that sourcing an arbitrary project file
// there — unconditionally, ahead of run-hook-with-bash.js's own
// `--optional` existsSync gate — would let an untrusted opened repo execute
// code on every hook event. Routing through ${CLAUDE_PLUGIN_ROOT} instead
// keeps the launcher itself plugin-trusted, exactly like
// run-hook-with-bash.js already is, and also resolves [codex-2] (Important):
// a vendored copy ships WITH the plugin, so it is present for every
// marketplace consumer — unlike a project-local scripts/lib/run-node.sh,
// which most installs never have. No if/then/else bare-node fallback is
// needed here either: a vendored file is exactly as guaranteed-present as
// run-hook-with-bash.js already is.
function wiredCommand(expected) {
  const launcher = '. "${CLAUDE_PLUGIN_ROOT}/hooks/run-node.sh" "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js"';
  if (expected.source === 'plugin') {
    return `${launcher} "\${CLAUDE_PLUGIN_ROOT}/hooks/${expected.script}"`;
  }
  const failClosed = expected.failClosedWhen
    ? ` --fail-closed-when "${expected.failClosedWhen}"`
    : '';
  return `${launcher} --optional${failClosed} "$CLAUDE_PROJECT_DIR/scripts/hooks/${expected.script}"`;
}

// Pre-HIMMEL-2047 wired form: bare `node`, unresolvable if node is off PATH.
// Recognised (as unwired, in rewritePluginHooksText below) so an
// already-wired-the-old-way entry still migrates to wiredCommand() above.
function legacyWiredCommand(expected) {
  const launcher = 'node "${CLAUDE_PLUGIN_ROOT}/hooks/run-hook-with-bash.js"';
  if (expected.source === 'plugin') {
    return `${launcher} "\${CLAUDE_PLUGIN_ROOT}/hooks/${expected.script}"`;
  }
  const failClosed = expected.failClosedWhen
    ? ` --fail-closed-when "${expected.failClosedWhen}"`
    : '';
  return `${launcher} --optional${failClosed} "$CLAUDE_PROJECT_DIR/scripts/hooks/${expected.script}"`;
}

function scrubHookCommands(pluginHooks) {
  const copy = parseJson(JSON.stringify(pluginHooks), 'plugin hooks clone');
  for (const { hook } of hookEntries(copy)) hook.command = COMMAND_SENTINEL;
  return copy;
}

export function assertOnlyPluginHookCommandsChanged(before, after) {
  if (JSON.stringify(scrubHookCommands(before)) !== JSON.stringify(scrubHookCommands(after))) {
    fail('a parsed field outside hook commands changed; refusing to write');
  }
}

export function rewritePluginHooksText(text) {
  const before = parseJson(text, 'plugin hooks input');
  const entries = hookEntries(before);
  const recognised = entries.map((entry, index) => {
    const expected = EXPECTED_HOOKS[index];
    if (!entry.hook || entry.hook.type !== 'command') {
      fail(`${entry.path} is not a recognised command hook`);
    }
    if (entry.event !== expected.event) {
      fail(`${entry.path} event inventory mismatch: expected ${expected.event}, found ${entry.event}`);
    }
    if (entry.hook.command === wiredCommand(expected)) return { expected, wired: true };
    if (entry.hook.command === unwiredCommand(expected)) return { expected, wired: false };
    if (entry.hook.command === legacyWiredCommand(expected)) return { expected, wired: false };
    return fail(`${entry.path} command inventory mismatch: expected ${expected.script}, found ${entry.hook.command}`);
  });

  let commandIndex = 0;
  let changed = 0;
  const output = text.replace(COMMAND_FIELD, (whole, key, separator, literal) => {
    if (commandIndex >= recognised.length) {
      fail('found a command field outside the asserted hook inventory');
    }
    const sourceValue = parseJson(literal, `command field ${commandIndex + 1}`);
    const entry = entries[commandIndex];
    if (sourceValue !== entry.hook.command) {
      fail(`text command order does not match ${entry.path}`);
    }

    const known = recognised[commandIndex];
    commandIndex += 1;
    if (known.wired) return whole;
    changed += 1;
    return `${key}${separator}${JSON.stringify(wiredCommand(known.expected))}`;
  });

  if (commandIndex !== entries.length) {
    fail(`expected ${entries.length} textual command fields, found ${commandIndex}`);
  }

  const after = parseJson(output, 'rewritten plugin hooks');
  assertOnlyPluginHookCommandsChanged(before, after);
  return { output, changed };
}

function parseArgs(argv) {
  let check = false;
  const paths = [];
  for (const arg of argv) {
    if (arg === '--check') check = true;
    else if (arg.startsWith('-')) fail(`unknown option: ${arg}`);
    else paths.push(arg);
  }
  if (paths.length > 1) fail('only one plugin hooks path may be supplied');
  return { check, hooksPath: paths[0] };
}

function defaultHooksPath() {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || resolve(HERE, '..', '..');
  return join(projectDir, 'marketplace', 'plugins', 'himmel-ops', 'hooks', 'hooks.json');
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const hooksPath = resolve(args.hooksPath || defaultHooksPath());
    const input = readFileSync(hooksPath, 'utf8');
    const { output, changed } = rewritePluginHooksText(input);

    if (args.check) {
      const action = changed === 0 ? 'already wired; no change needed' : `would rewrite ${changed} hook command(s)`;
      process.stdout.write(`wire-plugin-hook-bash: check passed for ${hooksPath} — ${action}; wrote nothing\n`);
      return;
    }

    if (changed === 0) {
      process.stdout.write(`wire-plugin-hook-bash: ${hooksPath} is already wired; no change made\n`);
      return;
    }

    writeFileSync(hooksPath, output, 'utf8');
    process.stdout.write(`wire-plugin-hook-bash: rewrote ${changed} hook command(s) in ${hooksPath}; other fields unchanged\n`);
  } catch (error) {
    process.stderr.write(`wire-plugin-hook-bash: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
