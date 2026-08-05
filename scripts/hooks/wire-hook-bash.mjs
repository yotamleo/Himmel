#!/usr/bin/env node
// hooks/wire-hook-bash.mjs — sanctioned settings wiring chokepoint (HIMMEL-1516).
//
// `.claude/settings.json` is deliberately deny-listed for direct agent edits.
// This script performs one narrow transformation: route the known hook command
// inventory through run-hook-with-bash.js. It refuses an unfamiliar command or
// inventory, proves the parsed permissions.allow/deny/ask values are unchanged,
// and verifies that no parsed field except hook commands changed.

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const EXPECTED_COUNTS = Object.freeze({
  PreToolUse: 11,
  PostToolUse: 2,
  SessionStart: 3,
});
const EXPECTED_TOTAL = 16;
const EXPECTED_SCRIPT_ORDER = Object.freeze([
  'auto-approve-safe-bash.sh',
  'check-cr-marker-on-pr-create.sh',
  'block-jira-compound-write.sh',
  'block-edit-on-main.sh',
  'guard-memory-capture.sh',
  'orchestrator-inline-guard.sh',
  'block-read-secrets.sh',
  'block-destructive-commands.sh',
  'block-rogue-claude-schedule.sh',
  'block-backend-tier.sh',
  'auto-arm-on-cap.sh',
  'auto-arm-on-subagent-cap.sh',
  'trigger-cr-on-pr-create.sh',
  'check-update-available.sh',
  'inject-initiative.sh',
  'qmd-staleness-notice.sh',
]);
const KNOWN_HOOK_SCRIPTS = new Set(EXPECTED_SCRIPT_ORDER);
const COMMAND_FIELD = /("command")(\s*:\s*)("(?:\\.|[^"\\])*")/g;
const COMMAND_SENTINEL = '__WIRE_HOOK_BASH_COMMAND__';

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

function hookEntries(settings) {
  const hooks = settings?.hooks;
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

  if (entries.length !== EXPECTED_TOTAL) {
    fail(`hook inventory total mismatch: expected ${EXPECTED_TOTAL}, found ${entries.length}`);
  }
  return entries;
}

function parseKnownCommand(command, entryPath) {
  if (typeof command !== 'string') fail(`${entryPath}.command must be a string`);

  let match = command.match(/^bash \$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)$/);
  if (!match) {
    match = command.match(/^bash "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  }
  if (match) {
    if (!KNOWN_HOOK_SCRIPTS.has(match[1])) {
      fail(`${entryPath} invokes unrecognised hook script: ${match[1]}`);
    }
    return { script: match[1], wired: false };
  }

  match = command.match(/^node "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js" "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  if (match) {
    if (!KNOWN_HOOK_SCRIPTS.has(match[1])) {
      fail(`${entryPath} invokes unrecognised hook script: ${match[1]}`);
    }
    return { script: match[1], wired: true };
  }

  fail(`${entryPath} has unrecognised command: ${command}`);
}

function wiredCommand(script) {
  return `node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"`;
}

function serialized(value) {
  return JSON.stringify(value);
}

export function assertPermissionsUnchanged(before, after) {
  for (const field of ['allow', 'deny', 'ask']) {
    const beforeValue = before?.permissions?.[field];
    const afterValue = after?.permissions?.[field];
    if (serialized(beforeValue) !== serialized(afterValue)) {
      fail(`permissions.${field} changed; refusing to write`);
    }
  }
}

function scrubHookCommands(settings) {
  const copy = parseJson(JSON.stringify(settings), 'settings clone');
  for (const { hook } of hookEntries(copy)) hook.command = COMMAND_SENTINEL;
  return copy;
}

export function assertOnlyHookCommandsChanged(before, after) {
  const scrubbedBefore = scrubHookCommands(before);
  const scrubbedAfter = scrubHookCommands(after);
  if (serialized(scrubbedBefore) !== serialized(scrubbedAfter)) {
    fail('a parsed field outside hook commands changed; refusing to write');
  }
}

export function rewriteSettingsText(text) {
  const before = parseJson(text, 'settings input');
  const entries = hookEntries(before);
  const recognised = entries.map(({ path: entryPath, hook }) => {
    if (!hook || hook.type !== 'command') {
      fail(`${entryPath} is not a recognised command hook`);
    }
    return parseKnownCommand(hook.command, entryPath);
  });
  recognised.forEach(({ script }, index) => {
    if (script !== EXPECTED_SCRIPT_ORDER[index]) {
      fail(`${entries[index].path} script inventory mismatch: expected ${EXPECTED_SCRIPT_ORDER[index]}, found ${script}`);
    }
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
    return `${key}${separator}${JSON.stringify(wiredCommand(known.script))}`;
  });

  if (commandIndex !== entries.length) {
    fail(`expected ${entries.length} textual command fields, found ${commandIndex}`);
  }

  const after = parseJson(output, 'rewritten settings');

  // SECURITY GATE: this comparison is unconditional. The chokepoint is trusted
  // only because it refuses any widening or other mutation of the permission
  // policy, including an absent/present change to permissions.ask.
  assertPermissionsUnchanged(before, after);
  assertOnlyHookCommandsChanged(before, after);

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
  if (paths.length > 1) fail('only one settings path may be supplied');
  return { check, settingsPath: paths[0] };
}

function defaultSettingsPath() {
  const projectDir = process.env.CLAUDE_PROJECT_DIR || resolve(HERE, '..', '..');
  return join(projectDir, '.claude', 'settings.json');
}

function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const settingsPath = resolve(args.settingsPath || defaultSettingsPath());
    const input = readFileSync(settingsPath, 'utf8');
    const { output, changed } = rewriteSettingsText(input);

    if (args.check) {
      const action = changed === 0 ? 'already wired; no change needed' : `would rewrite ${changed} hook command(s)`;
      process.stdout.write(`wire-hook-bash: check passed for ${settingsPath} — ${action}; wrote nothing\n`);
      return;
    }

    if (changed === 0) {
      process.stdout.write(`wire-hook-bash: ${settingsPath} is already wired; no change made\n`);
      return;
    }

    writeFileSync(settingsPath, output, 'utf8');
    process.stdout.write(`wire-hook-bash: rewrote ${changed} hook command(s) in ${settingsPath}; permissions unchanged\n`);
  } catch (error) {
    process.stderr.write(`wire-hook-bash: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
