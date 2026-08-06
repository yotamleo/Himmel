#!/usr/bin/env node
// hooks/wire-hook-bash.mjs — sanctioned settings wiring chokepoint (HIMMEL-1516).
//
// `.claude/settings.json` is deliberately deny-listed for direct agent edits.
// This script performs one narrow transformation: route the hook commands it
// OWNS through run-hook-with-bash.js. It IGNORES every event and entry it does
// not own (foreign event keys, and foreign entries inside owned events such as
// the trust ledger), so a second sanctioned writer may add its own hooks
// without this one refusing. It still FAILS LOUDLY on an impostor — a
// scripts/hooks/*.sh invocation, under an owned event, naming a script not in
// the owned inventory — because that is a command this tool would otherwise
// route and execute. It proves the parsed permissions.allow/deny/ask values are
// unchanged and that no parsed field except its OWN owned hook commands changed
// (HIMMEL-1552: own-only validation, so the two settings.json writers coexist).

import { readFileSync, writeFileSync } from 'node:fs';
import { dirname, join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

import { withSettingsLock } from '../lib/settings-lock.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
// The event keys whose hook arrays this tool OWNS. Any other event key is
// FOREIGN: it is not walked, not counted, and not impostor-checked, because
// this tool routes no command there. A scripts/hooks/*.sh invocation this tool
// does not recognise is an IMPOSTOR only under an owned event — where this tool
// would otherwise route it through run-hook-with-bash and execute unknown code.
// The same script under a foreign event is somebody else's hook, not ours.
//
// Per-event COUNTS are deliberately not frozen: a second writer (the trust
// ledger) adds entries inside these events, so the count depends on whether it
// is on. The frozen, own-only invariant is the script LIST + its order below
// (HIMMEL-1552). Bumping a count would rebuild the same wall for the next
// capability that adds a hook.
const OWNED_EVENTS = Object.freeze(new Set(['PreToolUse', 'PostToolUse', 'SessionStart']));
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

  // Enumerate in DOCUMENT order (Object.keys(hooks)), not a frozen constant.
  // Foreign event keys are skipped whole; within an owned event, foreign
  // entries (e.g. the trust-ledger `node .../trust/...` command) are skipped
  // too. This tool owns exactly the scripts in EXPECTED_SCRIPT_ORDER and proves
  // that here — everything else in the file is invisible to it. See the header
  // for why an impostor is refused only under an owned event.
  const entries = [];
  for (const event of Object.keys(hooks)) {
    if (!OWNED_EVENTS.has(event)) continue;
    const groups = hooks[event];
    if (!Array.isArray(groups)) fail(`hooks.${event} must be an array`);

    groups.forEach((group, groupIndex) => {
      if (!group || !Array.isArray(group.hooks)) {
        fail(`hooks.${event}[${groupIndex}].hooks must be an array`);
      }
      group.hooks.forEach((hook, hookIndex) => {
        const entryPath = `hooks.${event}[${groupIndex}].hooks[${hookIndex}]`;
        const c = classifyCommand(hook && hook.command);
        if (c.kind === 'impostor') {
          fail(`${entryPath} invokes unrecognised hook script: ${c.script}`);
        }
        if (c.kind === 'owned') {
          entries.push({ path: entryPath, hook, classified: c });
        }
        // foreign: ignore — not counted, not refused.
      });
    });
  }
  return entries;
}

// Classify a hook command. The SAME classification drives both the collection
// of owned entries (hookEntries) and the recognition of owned command fields in
// the textual rewrite (rewriteSettingsText), so the two walks cannot disagree
// about what is owned.
//
//   { kind: 'owned', script, wired }  a scripts/hooks/<known>.sh invocation
//                                     this tool routes through run-hook-with-
//                                     bash (wired) or would route (unwired).
//   { kind: 'impostor', script }      a scripts/hooks/*.sh invocation naming a
//                                     script NOT in KNOWN_HOOK_SCRIPTS. Refused
//                                     by hookEntries under an owned event.
//   { kind: 'foreign' }               anything else — a trust-ledger
//                                     `node .../trust/...` command, a foreign
//                                     event's own .sh hook, a malformed entry.
//                                     This tool owns neither its routing nor its
//                                     text; it is left byte-identical.
function classifyCommand(command) {
  if (typeof command !== 'string') return { kind: 'foreign' };

  let match = command.match(/^bash \$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)$/);
  if (!match) {
    match = command.match(/^bash "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  }
  if (match) {
    return KNOWN_HOOK_SCRIPTS.has(match[1])
      ? { kind: 'owned', script: match[1], wired: false }
      : { kind: 'impostor', script: match[1] };
  }

  match = command.match(/^node "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/run-hook-with-bash\.js" "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  if (match) {
    return KNOWN_HOOK_SCRIPTS.has(match[1])
      ? { kind: 'owned', script: match[1], wired: true }
      : { kind: 'impostor', script: match[1] };
  }

  return { kind: 'foreign' };
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

  // The owned scripts, in the document order they appear, must be exactly this
  // tool's inventory in its frozen order and count. Foreign entries and events
  // are invisible to this assertion, so the file may grow around the owned set
  // without tripping it — that is the point of own-only validation.
  if (entries.length !== EXPECTED_SCRIPT_ORDER.length) {
    fail(`owned hook inventory size mismatch: expected ${EXPECTED_SCRIPT_ORDER.length}, found ${entries.length}`);
  }
  entries.forEach((entry, i) => {
    if (entry.classified.script !== EXPECTED_SCRIPT_ORDER[i]) {
      fail(`${entry.path} script inventory mismatch: expected ${EXPECTED_SCRIPT_ORDER[i]}, found ${entry.classified.script}`);
    }
  });

  // The textual rewrite must walk the SAME set of "command" fields the
  // COMMAND_FIELD regex visits, in the SAME document order, and decide each
  // one's ownership from the PARSED structure — not from the command string
  // alone. classifyCommand() is EVENT-BLIND: a KNOWN script under a FOREIGN
  // event key reads as `owned` to it, yet hookEntries() (event-aware) never
  // collects that entry, so the two walks disagreed and the tool refused a
  // legitimate file (HIMMEL-1577). The fix: enumerate every object whose
  // `command` property is a string in document order — the precise set+order
  // the regex matches in the text — and tag each with the owned entry whose
  // hook object it IS (object identity; both walks derive from the one parse).
  // A known script under a foreign event is then tagged null and left
  // byte-identical, exactly like the unrecognised-.sh-under-foreign case, in
  // agreement with hookEntries rather than fighting it.
  const ownedByObject = new Map();
  for (const entry of entries) ownedByObject.set(entry.hook, entry);
  const commandSlots = [];
  const walkCommands = (value) => {
    if (Array.isArray(value)) {
      for (const item of value) walkCommands(item);
    } else if (value && typeof value === 'object') {
      for (const key of Object.keys(value)) {
        if (key === 'command' && typeof value[key] === 'string') {
          commandSlots.push(ownedByObject.get(value) ?? null);
        } else {
          walkCommands(value[key]);
        }
      }
    }
  };
  walkCommands(before);

  let slotIndex = 0;
  let changed = 0;
  const output = text.replace(COMMAND_FIELD, (whole, key, separator, literal) => {
    if (slotIndex >= commandSlots.length) {
      // The regex visited a "command" field the structural walk did not — the
      // two have diverged. Refuse rather than risk mis-slotting a write.
      fail('textual command field count exceeds the parsed command inventory');
    }
    const sourceValue = parseJson(literal, `command field ${slotIndex + 1}`);
    const entry = commandSlots[slotIndex];
    slotIndex += 1;
    if (!entry) {
      // A foreign command field (a trust-ledger command, a foreign event's own
      // .sh hook — known script or not, ...). This tool owns neither its
      // routing nor its text, so it is returned unchanged. Because
      // scrubHookCommands scrubs only OWNED commands, leaving this untouched is
      // what makes every foreign hook command immutable to this tool in
      // assertOnlyHookCommandsChanged.
      return whole;
    }
    // ALIGNMENT — the loud safety net, kept deliberately (HIMMEL-1577). With
    // ownership now derived from the parsed structure, the textual command at
    // this document position is the very same string as the parsed entry's
    // command by construction — but this still refuses rather than writing a
    // command into the WRONG SLOT should the two walks ever diverge, which is
    // the bad outcome this gate exists to prevent.
    if (sourceValue !== entry.hook.command) {
      fail(`text command order does not match ${entry.path}`);
    }
    const c = entry.classified;
    if (c.wired) return whole;
    changed += 1;
    return `${key}${separator}${JSON.stringify(wiredCommand(c.script))}`;
  });

  if (slotIndex !== commandSlots.length) {
    // The structural walk recorded a "command" field the regex did not visit —
    // the two have diverged. Refuse rather than risk mis-slotting a write.
    fail(`command field count mismatch: parsed ${commandSlots.length} command field(s), visited ${slotIndex}`);
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

async function main() {
  try {
    const args = parseArgs(process.argv.slice(2));
    const settingsPath = resolve(args.settingsPath || defaultSettingsPath());
    // HIMMEL-1552: hold the shared settings lock across the whole read ->
    // transform -> write, so the two sanctioned writers serialise rather than
    // race (a concurrent writer's change would otherwise be silently reverted).
    await withSettingsLock(settingsPath, () => {
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
    });
  } catch (error) {
    process.stderr.write(`wire-hook-bash: REFUSED — ${error.message}\n`);
    process.exitCode = 1;
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) main();
