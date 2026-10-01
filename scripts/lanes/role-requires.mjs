// scripts/lanes/role-requires.mjs
// HIMMEL-4012 — the plugins each shipped profile MUST have loaded for its role.
// One table, two consumers: plugin-profiles.test.mjs (the resolver enables
// them) and profile-context-probe.mjs (the live init event actually exposes
// their skills/commands/agents). A profile with no row here is untested.
export const ROLE_REQUIRES = {
  user: ['lean-skills@himmel'],
  design: ['plannotator-effective-html@himmel', 'frontend-design@claude-plugins-official',
    'ui-ux-pro-max@himmel', 'impeccable@himmel', 'taste-skill-core@himmel', 'shadcn-mcp@himmel',
    'context7@claude-plugins-official'],
  'design-motion': ['emilkowalski-skills@himmel', 'animejs-skills@himmel', 'gsap-skills@himmel',
    'lottie-motion-design@himmel', 'motion-lexicon@himmel', 'playground@claude-plugins-official'],
  'design-3d': ['threejs-skills@himmel'],
  'design-imagegen': ['taste-skill-imagegen@himmel', 'ai-image-prompts@himmel'],
  'design-a11y': ['platform-design-skills@himmel'],
  'design-diagram': ['diagram-design@himmel', 'builder-visual@himmel'],
  'design-slides': ['frontend-slides@himmel'],
  'design-reference': ['design-dna@himmel', 'anydesign@himmel', 'taste-skill-styles@himmel',
    'anthropic-design-skills@himmel'],
  'design-trial': ['hallmark@himmel'],
  'lane-impl': ['pr-review-toolkit-himmel@himmel'],
  'leg-impl': ['pr-review-toolkit-himmel@himmel'],
  'lane-review': ['pr-review-toolkit-himmel@himmel'],
  'lane-content': ['claude-obsidian@himmel', 'obsidian-triage@himmel'],
  telegram: ['claude-obsidian@himmel', 'obsidian-triage@himmel'],
  console: ['lean-skills@himmel'],
  bare: [], 'console-relay': [], 'console-judge': [],
};
