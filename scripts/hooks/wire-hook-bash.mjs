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
//
// HIMMEL-2002: one entry may now be a CHAIN (`run-hook-with-bash.js --chain a.sh
// b.sh ...`), so the list below is the FLATTENED document order — a guardrail
// wired for several disjoint matchers appears once per matcher. That is the
// point of the dispatcher: making the matchers disjoint is what buys one launch
// per tool event, and it necessarily repeats a guardrail that guards several
// tools. The invariant is unchanged in strength: the flattened owned scripts,
// in document order, must equal this list EXACTLY — same count, same order, no
// extras, no unexpected repeats.
const OWNED_EVENTS = Object.freeze(new Set(['PreToolUse', 'PostToolUse', 'SessionStart']));
export const EXPECTED_SCRIPT_ORDER = Object.freeze([
  // PreToolUse `Bash` chain.
  'auto-approve-safe-bash.sh',
  'check-cr-marker-on-pr-create.sh',
  'block-jira-compound-write.sh',
  'block-tail-pipe-on-gates.sh',
  'block-read-secrets.sh',
  'block-destructive-commands.sh',
  'block-git-stash.sh',
  'block-rogue-claude-schedule.sh',
  'block-chokepoint-env-prefix.sh',
  'require-quiet-run.sh',
  // Also in the Bash chain (HIMMEL-2360): the deny rules this hook replaces
  // covered Bash REDIRECT targets too ("Bash redirect targets are checked
  // against Edit rules"), so guarding only the edit tools would have silently
  // reopened `echo x > <primary>/.claude/settings.json`. Listed once per chain
  // it appears in, per HIMMEL-2002.
  'block-edit-live-settings.sh',
  // PreToolUse `PowerShell` chain.
  'block-read-secrets.sh',
  'block-destructive-commands.sh',
  'block-git-stash.sh',
  'block-rogue-claude-schedule.sh',
  'block-chokepoint-env-prefix.sh',
  // PreToolUse `Read|Grep`.
  'block-read-secrets.sh',
  // PreToolUse `Edit|Write|MultiEdit|NotebookEdit` chain.
  'block-edit-on-main.sh',
  // HIMMEL-2360: denies writes to a LIVE settings.json/settings.local.json
  // (user-scope $HOME/.claude, or the PRIMARY checkout's) while ALLOWING the
  // worktree copy, so hook wiring rides the owning leg's own PR. Replaces the
  // two `Edit(**/.claude/settings*.json)` deny rules, which could not tell a
  // primary checkout from a linked worktree.
  'block-edit-live-settings.sh',
  'guard-memory-capture.sh',
  // PreToolUse `Edit|Write|NotebookEdit` — its own entry, NOT folded into the
  // chain above: it does not guard MultiEdit, and widening a guard's matcher is
  // not something a launch-count refactor gets to do.
  'orchestrator-inline-guard.sh',
  // PreToolUse, one entry each.
  'block-backend-tier.sh',
  'auto-arm-on-cap.sh',
  // PreToolUse `Bash|Monitor` — its own matcher (HIMMEL-2140): denies a
  // subagent (agent_id present) from backgrounding a Bash call or reaching
  // for Monitor — the parking pathology. Parents (no agent_id) are
  // unaffected. See block-subagent-park.sh's header for the full derivation.
  'block-subagent-park.sh',
  // PostToolUse — two sibling entries, deliberately un-chained: both are
  // side-effecting, and chaining would make the push trigger reachable only
  // when the PR-create trigger does not deny first.
  'auto-arm-on-subagent-cap.sh',
  'trigger-cr-on-pr-create.sh',
  'trigger-cr-on-push.sh',
  // PostToolUse `Bash|Edit|Write|MultiEdit|NotebookEdit` — write-time hook-file
  // parse guard, appended after the trust ledger's own (foreign) entry in that
  // block, so the flattened OWNED order below still matches document order.
  'check-hook-file-parse.sh',
  // SessionStart chain (HIMMEL-2003).
  'check-update-available.sh',
  'inject-initiative.sh',
  'qmd-staleness-notice.sh',
  'graphify-freshness-advisory.sh',
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
//   { kind: 'owned', scripts, wired } a scripts/hooks/<known>.sh invocation
//                                     this tool routes through run-hook-with-
//                                     bash (wired) or would route (unwired).
//                                     `scripts` holds one name, or several for
//                                     a `--chain` entry (HIMMEL-2002).
//   { kind: 'impostor', script }      a scripts/hooks/*.sh invocation naming a
//                                     script NOT in KNOWN_HOOK_SCRIPTS. Refused
//                                     by hookEntries under an owned event.
//   { kind: 'foreign' }               anything else — a trust-ledger
//                                     `node .../trust/...` command, a foreign
//                                     event's own .sh hook, a malformed entry.
//                                     This tool owns neither its routing nor its
//                                     text; it is left byte-identical.
// HIMMEL-2047: a bare `node "<path>"` launcher is unresolvable if node itself
// is off PATH (the nvm-windows migration window that dropped SessionEnd hooks
// silently) — the very failure scripts/lib/run-node.sh exists to survive.
// LEGACY_LAUNCHER is the pre-HIMMEL-2047 bare-node form, recognised so an
// already-wired-the-old-way command still migrates.
const RUN_NODE = '$CLAUDE_PROJECT_DIR/scripts/lib/run-node.sh';
const LEGACY_LAUNCHER = 'node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js"';

// The wired form: SOURCE run-node.sh (`.` — a shell builtin, no PATH lookup,
// and not the bare-`bash` token HIMMEL-1516 banned from this inventory
// either) when it EXISTS, so it resolves node at runtime
// (scripts/lib/resolve-node.sh's resolve_node() — the same helper HIMMEL-2015
// gave individual project hook scripts) and execs it; fall back to the
// pre-HIMMEL-2047 bare `node` launcher when run-node.sh is ABSENT (an old
// checkout predating this fix), so that case degrades to exactly today's
// behaviour rather than a NEW hard failure at the launcher (critic-panel
// finding [codex-1], HIMMEL-2047 CR round 1). `argsSuffix` is everything that
// followed `run-hook-with-bash.js` in the legacy form — INCLUDING its leading
// space — so it drops in unchanged on both branches, single script or
// `--chain` member list alike. An `if`, not `[ -f ] && … || node …`: the
// latter re-runs the hook a second time via bare node whenever the FIRST run
// exits non-zero for its own reasons (e.g. a guard denying), not only when
// run-node.sh is missing.
function wrapWithFallback(argsSuffix) {
  const target = '$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js';
  return `if [ -f "${RUN_NODE}" ]; then . "${RUN_NODE}" "${target}"${argsSuffix}; else node "${target}"${argsSuffix}; fi`;
}

// The suffix after a recognised launcher prefix: either one script, or a
// `--chain` (optionally `--lifecycle`, HIMMEL-2003) member list. Returns the
// owned scripts, or null if the suffix matches neither shape.
function launcherSuffixScripts(rest) {
  let m = rest.match(/^"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  if (m) return [m[1]];
  m = rest.match(/^--chain (?:--lifecycle )?((?:"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/[A-Za-z0-9._-]+\.sh" )*"\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/[A-Za-z0-9._-]+\.sh")$/);
  if (m) return [...m[1].matchAll(/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)/g)].map((x) => x[1]);
  return null;
}

// The wired command is `wrapWithFallback` applied to a legacy-shaped suffix —
// recognise it by matching the fixed if/then/else scaffold with the shared
// args captured once and required (via backreference) to match on both
// branches, exactly what wrapWithFallback emits.
const WIRED_RE = new RegExp(
  '^if \\[ -f "\\$CLAUDE_PROJECT_DIR/scripts/lib/run-node\\.sh" \\]; then \\. '
  + '"\\$CLAUDE_PROJECT_DIR/scripts/lib/run-node\\.sh" "\\$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash\\.js"( .+); '
  + 'else node "\\$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash\\.js"\\1; fi$'
);

function classifyCommand(command) {
  if (typeof command !== 'string') return { kind: 'foreign' };

  let match = command.match(/^bash \$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)$/);
  if (!match) {
    match = command.match(/^bash "\$CLAUDE_PROJECT_DIR\/scripts\/hooks\/([A-Za-z0-9._-]+\.sh)"$/);
  }
  if (match) {
    return KNOWN_HOOK_SCRIPTS.has(match[1])
      ? { kind: 'owned', scripts: [match[1]], wired: false }
      : { kind: 'impostor', script: match[1] };
  }

  // argsSuffix always includes its leading space (matches wrapWithFallback's
  // own convention), so launcherSuffixScripts always sees the same shape
  // whichever launcher form it was pulled from.
  let argsSuffix = null;
  let wired = false;
  const wiredMatch = command.match(WIRED_RE);
  if (wiredMatch) {
    argsSuffix = wiredMatch[1];
    wired = true;
  } else if (command.startsWith(`${LEGACY_LAUNCHER} `)) {
    argsSuffix = ` ${command.slice(LEGACY_LAUNCHER.length + 1)}`;
  }
  if (argsSuffix !== null) {
    const scripts = launcherSuffixScripts(argsSuffix.slice(1));
    if (scripts) {
      const unknown = scripts.find((s) => !KNOWN_HOOK_SCRIPTS.has(s));
      return unknown ? { kind: 'impostor', script: unknown } : { kind: 'owned', scripts, wired };
    }
  }

  return { kind: 'foreign' };
}

function wiredCommand(script) {
  return wrapWithFallback(` "$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"`);
}

function bareCommand(script) {
  return `bash "$CLAUDE_PROJECT_DIR/scripts/hooks/${script}"`;
}

// EXPECTED_SCRIPT_ORDER scripts with zero present entries (HIMMEL-1643:
// install-when-missing). Order-preserving so installMissingEntries() can
// process them in EXPECTED_SCRIPT_ORDER order and chain anchors correctly.
function missingOwnedScripts(entries) {
  const present = new Set(entries.flatMap((e) => e.classified.scripts));
  // De-duplicated: EXPECTED_SCRIPT_ORDER repeats a guardrail once per matcher
  // it is wired for, but "missing" is a property of the SCRIPT, not of a slot.
  return [...new Set(EXPECTED_SCRIPT_ORDER)].filter((s) => !present.has(s));
}

// The owned scripts in document order, one row per script — a chain entry
// contributes one row per member. This is the list the frozen inventory is
// compared against.
function flatOwnedScripts(entries) {
  return entries.flatMap((e) => e.classified.scripts.map((script) => ({ path: e.path, script })));
}

// Compare the flattened owned scripts against the inventory minus whatever is
// legitimately missing. One check covers count, order, extras and duplicates.
function assertInventory(entries, missing, label) {
  const found = flatOwnedScripts(entries);
  const expected = EXPECTED_SCRIPT_ORDER.filter((s) => !missing.includes(s));
  if (found.length !== expected.length) {
    fail(`${label}owned hook inventory size mismatch: expected ${expected.length}, found ${found.length}`);
  }
  found.forEach((row, i) => {
    if (row.script !== expected[i]) {
      fail(`${row.path} script inventory mismatch: expected ${expected[i]}, found ${row.script}`);
    }
  });
}

// Index of the bracket matching text[openIdx] ('[' or '{'), skipping over
// string literals (respecting backslash escapes) so a brace/bracket inside a
// command string can't confuse the depth count. Tracks ONLY the one bracket
// type given at openIdx — correct for valid JSON, where '[' / ']' and
// '{' / '}' each nest independently of the other type.
function matchingBracket(text, openIdx) {
  const open = text[openIdx];
  const close = open === '[' ? ']' : '}';
  let depth = 0;
  let inString = false;
  for (let i = openIdx; i < text.length; i++) {
    const ch = text[i];
    if (inString) {
      if (ch === '\\') { i++; continue; }
      if (ch === '"') inString = false;
      continue;
    }
    if (ch === '"') { inString = true; continue; }
    if (ch === open) depth++;
    else if (ch === close) {
      depth--;
      if (depth === 0) return i;
    }
  }
  return -1;
}

// Install-when-missing (HIMMEL-1643). Inserts exactly one BARE (unwired) hook
// object per script in `missing` --
//   {"type":"command","command":"bash \"$CLAUDE_PROJECT_DIR/scripts/hooks/<script>.sh\"","timeout":30}
// -- under hooks.SessionStart, immediately after that script's nearest
// PRECEDING EXPECTED_SCRIPT_ORDER script that is currently present (an entry
// installed earlier in the same call counts as present for anchoring a LATER
// missing script, so several new tail entries chain correctly in one pass).
// Inserted BARE rather than pre-wired so the existing textual command-rewrite
// pass below treats it like any other unwired command and folds it into the
// same `changed` count -- no separate "installed" bookkeeping needed.
//
// SessionStart ONLY (own-only invariant, minimally extended): this tool has
// no general "which event does script X belong to" table, so it only knows
// how to install into the one event its current inventory tail lives in. A
// missing script with NO preceding present SessionStart entry to anchor on
// (e.g. a PostToolUse/PreToolUse script that vanished) is refused rather than
// guessed at -- see the fail() below.
//
// Confines the reformatting blast radius to the hooks.SessionStart array's
// OWN text span (located via matchingBracket): every other byte in the file
// is untouched, matching the rest of this tool's minimal-diff philosophy.
function installMissingEntries(text, missing) {
  const keyMatch = text.match(/"SessionStart"\s*:\s*\[/);
  if (!keyMatch) fail('cannot install: hooks.SessionStart array not found in settings text');
  const openIdx = keyMatch.index + keyMatch[0].length - 1; // index of '['
  const closeIdx = matchingBracket(text, openIdx);
  if (closeIdx === -1) fail('cannot install: hooks.SessionStart array is not balanced');

  const lineStart = text.lastIndexOf('\n', keyMatch.index) + 1;
  const baseIndent = text.slice(lineStart, keyMatch.index).match(/^\s*/)[0];

  const groups = parseJson(text.slice(openIdx, closeIdx + 1), 'hooks.SessionStart array');

  // Flat, anchorable list of {group, hookIndex, script} for OWNED entries
  // currently in this array, in document order. Only classification is
  // needed here (not impostor-refusal) -- an impostor anywhere under an
  // owned event was already refused by the caller's hookEntries(before) walk
  // over the WHOLE file before installMissingEntries is ever reached.
  const scoped = [];
  groups.forEach((group) => {
    (group.hooks || []).forEach((hook, hookIndex) => {
      const c = classifyCommand(hook && hook.command);
      if (c.kind === 'owned') for (const script of c.scripts) scoped.push({ group, hookIndex, script });
    });
  });

  for (const script of missing) {
    const pos = EXPECTED_SCRIPT_ORDER.indexOf(script);
    let anchor = null;
    for (let i = pos - 1; i >= 0; i--) {
      const candidate = scoped.find((e) => e.script === EXPECTED_SCRIPT_ORDER[i]);
      if (candidate) { anchor = candidate; break; }
    }
    if (!anchor) {
      fail(`cannot install ${script}: no preceding EXPECTED_SCRIPT_ORDER script is present in hooks.SessionStart to anchor after`);
    }
    // timeout: 30 (codex-adv-3): every hand-wired SessionStart sibling carries
    // an explicit, bounded timeout (10/15/30 here). An installed entry WITHOUT
    // one defaults to the harness's 600s, so a hung advisory could block session
    // startup for ten minutes. Bound it like its siblings.
    anchor.group.hooks.splice(anchor.hookIndex + 1, 0, { type: 'command', command: bareCommand(script), timeout: 30 });
    // Later entries in the SAME group shift by one; register the new entry
    // itself so a SECOND missing script (processed next) can anchor on it.
    scoped.forEach((e) => { if (e.group === anchor.group && e.hookIndex > anchor.hookIndex) e.hookIndex += 1; });
    scoped.push({ group: anchor.group, hookIndex: anchor.hookIndex + 1, script });
  }

  const reindented = JSON.stringify(groups, null, 2)
    .split('\n')
    .map((line, i) => (i === 0 ? line : baseIndent + line))
    .join('\n');
  return text.slice(0, openIdx) + reindented + text.slice(closeIdx + 1);
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

// Remove exactly the hook objects for `insertedScripts` from a CLONE of
// `settings`, classifying by their CURRENT (real, unscrubbed) command value —
// must run BEFORE scrubHookCommands, whose sentinel overwrite would erase the
// script name this needs to match on. Any OTHER structural change (an extra
// entry not in `insertedScripts`, a removed field, ...) survives pruning and
// is caught by the scrubbed-comparison below, exactly as before HIMMEL-1643 —
// this only widens the gate for the SPECIFIC entries this tool itself just
// installed, nothing else.
function pruneInsertedEntries(settings, insertedScripts) {
  const copy = parseJson(JSON.stringify(settings), 'settings clone (prune)');
  const toPrune = new Set(insertedScripts);
  for (const event of Object.keys(copy.hooks || {})) {
    if (!OWNED_EVENTS.has(event)) continue;
    for (const group of copy.hooks[event]) {
      if (!Array.isArray(group.hooks)) continue;
      group.hooks = group.hooks.filter((hook) => {
        const c = classifyCommand(hook && hook.command);
        // Installed entries are always single-script (installMissingEntries
        // writes the bare form), so a chain can never be pruned by this gate.
        return !(c.kind === 'owned' && c.scripts.length === 1 && toPrune.has(c.scripts[0]));
      });
    }
  }
  return copy;
}

// insertedScripts (HIMMEL-1643): the scripts installMissingEntries() legally
// added this run. When non-empty, `after` is pruned of exactly those entries
// BEFORE the scrub-and-compare — the ONLY tolerance this security gate grants
// beyond command-value changes. An unauthorized structural change (anything
// NOT in insertedScripts) still fails the comparison and refuses, unchanged
// from the pre-HIMMEL-1643 behaviour.
export function assertOnlyHookCommandsChanged(before, after, insertedScripts = []) {
  const comparableAfter = insertedScripts.length > 0 ? pruneInsertedEntries(after, insertedScripts) : after;
  const scrubbedBefore = scrubHookCommands(before);
  const scrubbedAfter = scrubHookCommands(comparableAfter);
  if (serialized(scrubbedBefore) !== serialized(scrubbedAfter)) {
    fail('a parsed field outside hook commands changed; refusing to write');
  }
}

export function rewriteSettingsText(text) {
  const originalBefore = parseJson(text, 'settings input');
  const originalEntries = hookEntries(originalBefore);

  // The owned scripts, in the document order they appear, must reconcile
  // EXACTLY to this tool's inventory: every FOUND entry plus every MISSING
  // one (HIMMEL-1643: install-when-missing) must together equal
  // EXPECTED_SCRIPT_ORDER's frozen count. A mismatch beyond that — an extra
  // entry, a duplicate — is still refused; a shortfall that is fully
  // explained by known-missing scripts is not.
  const missing = missingOwnedScripts(originalEntries);
  assertInventory(originalEntries, missing, '');

  // Install missing owned SessionStart entries (bare/unwired) BEFORE the
  // normal command-rewrite pass below, so they flow through it like any other
  // unwired command and land in the SAME `changed` count — no separate
  // "installed N" message needed. text/before/entries are re-derived from the
  // post-install text for everything that follows.
  const workingText = missing.length > 0 ? installMissingEntries(text, missing) : text;
  const before = parseJson(workingText, 'settings input (post-install)');
  const entries = hookEntries(before);
  // Defensive re-check: install must have produced EXACTLY the full inventory,
  // in order — a sanity net on installMissingEntries itself, not a case a
  // caller can reach differently (mirrors the "ALIGNMENT" net further below).
  assertInventory(entries, [], 'post-install ');

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
  const output = workingText.replace(COMMAND_FIELD, (whole, key, separator, literal) => {
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
    // Two prior (unwired) shapes reach here: a fully bare `bash .../<script>.sh`
    // (single script only — a chain has no bare form) migrates via
    // wiredCommand(); an already-launcher-wired-the-OLD-way command
    // (HIMMEL-2047: bare `node`, single or `--chain`) migrates by wrapping its
    // existing script argument(s) — a chain's members included, verbatim — in
    // the if/then/else fallback wrapWithFallback() builds.
    const newCommand = entry.hook.command.startsWith(`${LEGACY_LAUNCHER} `)
      ? wrapWithFallback(` ${entry.hook.command.slice(LEGACY_LAUNCHER.length + 1)}`)
      : wiredCommand(c.scripts[0]);
    return `${key}${separator}${JSON.stringify(newCommand)}`;
  });

  if (slotIndex !== commandSlots.length) {
    // The structural walk recorded a "command" field the regex did not visit —
    // the two have diverged. Refuse rather than risk mis-slotting a write.
    fail(`command field count mismatch: parsed ${commandSlots.length} command field(s), visited ${slotIndex}`);
  }

  const after = parseJson(output, 'rewritten settings');

  // SECURITY GATE: this comparison is unconditional, and runs against
  // originalBefore (the TRUE pre-install/pre-rewrite state), not the
  // post-install `before` — proving the whole operation, install included,
  // widened nothing except the declared `missing` entries. The chokepoint is
  // trusted only because it refuses any widening or other mutation of the
  // permission policy, including an absent/present change to permissions.ask.
  assertPermissionsUnchanged(originalBefore, after);
  assertOnlyHookCommandsChanged(originalBefore, after, missing);

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
