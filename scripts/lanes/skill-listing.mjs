// scripts/lanes/skill-listing.mjs
// HIMMEL-4038 — keep a profile's REQUIRED skills described in the skill listing.
// Claude Code caps the listing at skillListingBudgetFraction (default 0.01) of
// the context window and, over it, drops descriptions least-invoked first. Two
// levers, both measured live (HIMMEL-4038 feasibility, 2 haiku /context calls):
//   skillOverrides {"<bare skill name>": "name-only"}  shrinks NON-plugin skills
//     (user, project, bundled). It is INERT for plugin skills under both the bare
//     and the `plugin:skill` key (the settings docs say so too).
//   skillListingBudgetFraction raises the cap.
// ponytail: plugin skills cannot be shrunk, so the fraction is sized for the
// whole unshrunk enabled-plugin listing, ceiling 0.05 of the window, upgrade
// path: an upstream Claude Code change making skillOverrides reach plugin skills
// (then size the fraction on the required set only).
import { ROLE_REQUIRES } from './role-requires.mjs';
import { pluginCacheOf, scanCommandTrees, runtimeNamesOf } from './skill-cost.mjs';

export const DEFAULT_FRACTION = 0.01;
export const MAX_FRACTION = 0.05;
const WINDOW = 200_000; // the binding case: 1M windows get 5x the same fraction
// The fraction is a CEILING, not a spend: extra headroom costs nothing until the
// listing actually grows into it. Headroom for listing entries the scan cannot
// see (measured 2026-10-01: a user skills-dir plugin with 47 commands = 1850 tok,
// a synced plugin 25 tok; neither is a SKILL.md under the plugin cache), so
// the required skills are not starved by them.
// A caller passing configDir gets its skills-dir command trees scanned plus a
// small margin for the rest (a synced plugin); an unscannable configDir, or none
// passed, falls back to the fixed constant.
// ponytail: chars/4 estimate of the tree commands + 250 tok margin, upgrade path:
// measure the margin against /context if the cap trips.
const UNSCANNED_RESERVE = 2500;
const UNSCANNED_MARGIN = 250;

const commandTreeReserve = (configDir) => {
  const skipped = [];
  const cmds = configDir === undefined ? null : scanCommandTrees(configDir, skipped);
  if (!cmds) return UNSCANNED_RESERVE;
  // the reserve is understated by whatever the scan could not read: say so
  for (const s of skipped) process.stderr.write(`skill-listing: command tree path skipped (${s.code}): ${s.path}\n`);
  return UNSCANNED_MARGIN + cmds.reduce((a, e) => a + describedTokens(e, e.tree), 0);
};

// ponytail: static list of the bundled/desktop skills seen in a measured listing
// (2026-10-01, Claude Code 2.1.286); an override for a skill that is absent is
// harmless, a new bundled skill is simply not shrunk. Upgrade path: none from
// the scan (bundled skills have no files), revisit if the budget cap trips.
export const BUILTIN_SKILL_NAMES = [
  'update-config', 'keybindings-help', 'code-review', 'simplify', 'fewer-permission-prompts', 'loop',
  'schedule', 'claude-api', 'workflow-authoring', 'run', 'init', 'security-review', 'built-in-browser',
  'chrome-browser', 'computer-use', 'docs', 'docx', 'google-workspace', 'import-memory', 'morning',
  'pdf', 'pptx', 'skill-creator', 'xlsx', 'dataviz',
];

const pluginName = (id) => id.split('@')[0];
const nameOnlyTokens = (name) => Math.ceil(name.length / 3) + 2; // matches isNameOnlySkill's heuristic

// uncapped listing cost of one plugin skill: `<plugin>:<name> <description>`, chars/4
const describedTokens = (e, plugin) => Math.ceil((plugin.length + 1 + e.name.length + 2 + (e.countedRoutingChars ?? 0)) / 4);

// entries = scanSkillCosts().entries. Returns {} when the profile requires no
// plugin (nothing to protect), else { skillOverrides, skillListingBudgetFraction }.
// runtimeNames (skill-cost's runtimeNamesOf, read from configDir when omitted): the
// plugin.json name Claude lists a strict:true plugin's skills under, which sets
// each listing line's length (HIMMEL-4068); the cache DIRECTORY (entry name)
// still selects the entries.
export function skillListingSettings({ entries, enabledIds, requiredIds, window = WINDOW, configDir, cwd, runtimeNames = configDir === undefined ? undefined : runtimeNamesOf(configDir, cwd) }) {
  if (!requiredIds.length) return {};
  const skillOverrides = {};
  let tokens = 0;
  for (const name of BUILTIN_SKILL_NAMES) skillOverrides[name] = 'name-only';
  for (const e of entries) {
    if (e.scope !== 'plugin-skills') skillOverrides[e.name] = 'name-only';
  }
  for (const name of Object.keys(skillOverrides)) tokens += nameOnlyTokens(name);
  // several cached versions of one plugin can match: count each plugin skill once, largest wins
  const best = new Map();
  for (const id of enabledIds) {
    const plugin = pluginName(id);
    for (const e of entries) {
      if (e.scope !== 'plugin-skills' || pluginCacheOf(e.path)?.plugin !== plugin) continue;
      const key = `${plugin}:${e.name}`;
      best.set(key, Math.max(best.get(key) ?? 0, describedTokens(e, runtimeNames?.get(id) ?? plugin)));
    }
  }
  for (const t of best.values()) tokens += t;
  tokens += commandTreeReserve(configDir);
  const fraction = Math.max(DEFAULT_FRACTION, Math.ceil((tokens / window) * 1000) / 1000);
  if (fraction > MAX_FRACTION) {
    throw new Error(`skill-listing: computed skillListingBudgetFraction ${fraction} exceeds the ${MAX_FRACTION} sanity cap (${tokens} tok over ${window}); refusing to emit it, check the skill scan`);
  }
  return { skillOverrides, skillListingBudgetFraction: fraction };
}

export const requiredIdsFor = (profile) => ROLE_REQUIRES[profile] ?? [];
