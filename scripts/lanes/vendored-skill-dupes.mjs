#!/usr/bin/env node
// vendored-skill-dupes.mjs — detect a lean-skills@himmel / upstream-plugin overlap
// (HIMMEL-3064).
//
// WHY: lean-skills@himmel vendors 11 of superpowers' 14 skill directories and
// grilling from mattpocock/skills, so a session lists 13 skills instead of 25.
// That is only a win while the UPSTREAM plugins stay disabled. An adopter who
// enables superpowers@claude-plugins-official alongside it gets BOTH copies of
// brainstorming, writing-plans, systematic-debugging and eight more — a
// duplicated listing that costs more context than either arrangement alone, and
// two same-named skills whose bodies drift apart as upstream moves.
//
// Resolution rule when both are on: the UPSTREAM plugin wins. It is the source
// we copied from, it is what upstream keeps current, and our vendored trees are
// a frozen snapshot of one release (see scripts/upstreams.json ->
// superpowers-skills / mattpocock-skills). Preferring the local copy would pin
// the adopter to whatever we last re-vendored.
//
// Effective-truth semantics mirror readEnabledPluginIds' layer walk in
// plugin-profiles.mjs (home settings, then every ancestor .claude/settings.json
// and .claude/settings.local.json from cwd up to the filesystem root), but this
// script needs the merged VALUE rather than the key set: a later layer's
// `false` genuinely disables a plugin an earlier layer turned on, and an overlap
// that only exists in an overridden layer is not an overlap.
//
// Usage: node scripts/lanes/vendored-skill-dupes.mjs [--json]
// Exit codes: 0 no overlap, 10 overlap found, 2 a settings layer is unreadable.
//
// Test seams: VENDORED_DUPES_HOME, VENDORED_DUPES_CWD, VENDORED_DUPES_CONFIG_DIR.

import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { homedir } from 'node:os';
import { fileURLToPath } from 'node:url';

const LOCAL = 'lean-skills@himmel';

// himmel-authored skills with no upstream at all — never reported as an
// overlap with ANY source, regardless of how a source's skill list is
// computed. Excluded before attribution (not by a source's subtraction), so a
// future re-vendor of superpowers/mattpocock (which only ever touches THEIR
// trees) cannot silently sweep a local skill back in.
const LOCAL_ONLY = ['context7-mcp'];

// Which upstream plugin each vendored skill directory came from. Derived from
// the tree itself rather than hardcoded, so a future re-vendor that adds or
// drops a skill cannot leave this list quietly stale.
const SOURCES = [
  { id: 'superpowers@claude-plugins-official', repo: 'obra/superpowers', skills: null },
  { id: 'mattpocock-skills@claude-plugins-official', repo: 'mattpocock/skills', skills: ['grilling'] },
];

function settingsLayers(home, cwd, configDir) {
  const files = [join(configDir || join(home, '.claude'), 'settings.json')];
  const dirs = [];
  if (cwd) {
    let d = resolve(cwd);
    for (;;) {
      dirs.push(d);
      const parent = dirname(d);
      if (parent === d) break;
      d = parent;
    }
  }
  // Nearest layer wins, so apply from the filesystem root inward: reverse the
  // cwd walk (which runs inward -> outward) and keep home settings outermost.
  // Reverse the DIRECTORY order ONLY. Within one directory settings.local.json
  // must still be applied AFTER settings.json (CR round 1, PR #777): the
  // previous flat `files.slice(1).reverse()` flipped that pair too, so a
  // shared settings.json overwrote the sibling settings.local.json for the
  // same enabledPlugins key -- backwards from this repo's own precedence rule.
  for (const d of dirs.reverse()) {
    files.push(join(d, '.claude', 'settings.json'), join(d, '.claude', 'settings.local.json'));
  }
  return files;
}

function effectiveEnabled(home, cwd, configDir) {
  const merged = new Map();
  for (const f of settingsLayers(home, cwd, configDir)) {
    if (!existsSync(f)) continue;
    let j;
    try { j = JSON.parse(readFileSync(f, 'utf8')); }
    catch (e) {
      const err = new Error(`vendored-skill-dupes: ${f} is unreadable/unparseable (${e?.message ?? e})`);
      err.code = 2;
      throw err;
    }
    const m = j?.enabledPlugins;
    if (m && typeof m === 'object' && !Array.isArray(m)) {
      for (const [k, v] of Object.entries(m)) merged.set(k, v === true);
    }
  }
  return merged;
}

function vendoredSkills(repoRoot) {
  const dir = join(repoRoot, 'marketplace', 'plugins', 'lean-skills', 'skills');
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true })
    .filter((e) => e.isDirectory())
    .map((e) => e.name)
    .filter((name) => !LOCAL_ONLY.includes(name));
}

export function findOverlap({ home, cwd, configDir, repoRoot }) {
  const enabled = effectiveEnabled(home, cwd, configDir);
  if (enabled.get(LOCAL) !== true) return [];
  const local = new Set(vendoredSkills(repoRoot));
  const out = [];
  for (const src of SOURCES) {
    if (enabled.get(src.id) !== true) continue;
    // A null skill list means "every vendored skill except those another source
    // claims" — superpowers is the bulk source, mattpocock contributes grilling.
    const claimed = SOURCES.filter((s) => s !== src && s.skills).flatMap((s) => s.skills);
    const shared = [...local].filter((s) => (src.skills ? src.skills.includes(s) : !claimed.includes(s))).sort();
    if (shared.length) out.push({ plugin: src.id, repo: src.repo, skills: shared });
  }
  return out;
}

const thisFile = fileURLToPath(import.meta.url);
const isMain = process.argv[1] !== undefined && resolve(process.argv[1]) === thisFile;
if (isMain) {
  // `!== undefined` (not `||`) on every seam: an explicit empty string must
  // mean "skip this layer" (a test's deliberate no-cwd-walk hermetic seam),
  // not "unset, fall back to the real value" — `||` treated them the same and
  // silently walked the operator's REAL cwd/home ancestry into a fixture-only
  // run, picking up their live ~/.claude overrides (HIMMEL-3064 Defect B).
  const home = process.env.VENDORED_DUPES_HOME !== undefined ? process.env.VENDORED_DUPES_HOME : homedir();
  const cwd = process.env.VENDORED_DUPES_CWD !== undefined ? process.env.VENDORED_DUPES_CWD : process.cwd();
  const configDir = process.env.VENDORED_DUPES_CONFIG_DIR !== undefined ? process.env.VENDORED_DUPES_CONFIG_DIR
    : (process.env.CLAUDE_CONFIG_DIR || '');
  const repoRoot = resolve(dirname(thisFile), '..', '..');
  let overlap;
  try {
    overlap = findOverlap({ home, cwd, configDir, repoRoot });
  } catch (e) {
    process.stderr.write(`${e.message}\n`);
    process.exit(e.code === 2 ? 2 : 1);
  }
  if (process.argv.includes('--json')) {
    process.stdout.write(`${JSON.stringify(overlap)}\n`);
  } else {
    for (const o of overlap) {
      process.stdout.write(
        `${o.plugin} is enabled alongside ${LOCAL}, which vendors ${o.skills.length} of its skills ` +
        `(${o.skills.join(', ')}) — both copies are listed. Prefer the upstream plugin (it is the ` +
        `live ${o.repo}; our copies are a frozen release snapshot) and drop those skills from the ` +
        `local vendor, or disable ${o.plugin}.\n`,
      );
    }
  }
  process.exit(overlap.length ? 10 : 0);
}
