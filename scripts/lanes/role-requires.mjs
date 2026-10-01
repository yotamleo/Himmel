// scripts/lanes/role-requires.mjs
// HIMMEL-4012 — the plugins each shipped profile MUST have loaded for its role.
// One table, two consumers: plugin-profiles.test.mjs (the resolver enables
// them) and profile-context-probe.mjs (the live init event actually exposes
// their skills/commands/agents). A profile with no row here is untested.
export const ROLE_REQUIRES = {
  user: ['lean-skills@himmel'],
  design: ['plannotator-effective-html@himmel', 'frontend-design@claude-plugins-official',
    'ui-ux-pro-max@ui-ux-pro-max-skill', 'impeccable@himmel'],
  'lane-impl': ['pr-review-toolkit-himmel@himmel'],
  'leg-impl': ['pr-review-toolkit-himmel@himmel'],
  'lane-review': ['pr-review-toolkit-himmel@himmel'],
  'lane-content': ['claude-obsidian@himmel', 'obsidian-triage@himmel'],
  telegram: ['claude-obsidian@himmel', 'obsidian-triage@himmel'],
  bare: [], 'console-relay': [], 'console-judge': [],
};
