import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { remarkDocs } from './src/plugins/remark-docs.mjs';
import { SITE_ORIGIN, REPO_URL } from './src/urls.mjs';
import { readAllowlist } from './src/loaders/docs-loader.mjs';

const here = path.dirname(fileURLToPath(import.meta.url));
const DOCS = path.resolve(here, '../docs');
const BASE = '/Himmel';
const ALLOW = readAllowlist(path.join(here, 'allowlist.txt'));
const HTML_PASSTHROUGH = ['adoption-trail.html', 'guide/installer-journey.html', 'guide/loops-and-graphs.html', 'guide/dev-graph.html'];
// The development graph page loads these next to itself.
const GUIDE_ASSETS = ['guide/dev-graph/dev-graph.js', 'guide/dev-graph/dev-graph.css', 'guide/dev-graph/tokens.css', 'guide/dev-graph/graph.json'];

// Raw files that keep resolving at their docs/ paths: every allowlisted .md
// plus the install JSON files the setup pages link to.
const RAW_FILES = [
  ...ALLOW,
  'setup/settings-template.json',
  ...fs.readdirSync(path.join(DOCS, 'setup/profiles')).filter((f) => f.endsWith('.json')).map((f) => `setup/profiles/${f}`),
];

// Standalone HTML pages and raw files ship byte-identical at their docs/ paths.
const copyPassthrough = {
  name: 'copy-passthrough',
  hooks: {
    'astro:build:done': ({ dir }) => {
      for (const rel of [...HTML_PASSTHROUGH, ...GUIDE_ASSETS, ...RAW_FILES]) {
        const out = path.join(fileURLToPath(dir), rel);
        fs.mkdirSync(path.dirname(out), { recursive: true });
        fs.copyFileSync(path.join(DOCS, rel), out);
      }
    },
  },
};

// Mermaid blocks are emitted as <pre class="mermaid">; the renderer is a lazy chunk fetched only on pages that have one.
// A render replaces the source with an SVG, so the source is kept on the node to redraw after a theme toggle.
const mermaid = {
  name: 'mermaid-inject',
  hooks: {
    'astro:config:setup': ({ injectScript }) => {
      injectScript('page', `
if (document.querySelector('pre.mermaid')) import('mermaid').then(({ default: mermaid }) => {
  const nodes = [...document.querySelectorAll('pre.mermaid')];
  for (const n of nodes) n.dataset.src = n.textContent;
  const isDark = () => {
    const t = document.documentElement.dataset.theme;
    return t ? t === 'dark' : matchMedia('(prefers-color-scheme: dark)').matches;
  };
  let queue = Promise.resolve();
  const render = () => {
    queue = queue.then(async () => {
      for (const n of nodes) { n.textContent = n.dataset.src; n.removeAttribute('data-processed'); }
      mermaid.initialize({ startOnLoad: false, theme: isDark() ? 'dark' : 'default' });
      await mermaid.run({ nodes });
    }).catch(console.error);
  };
  render();
  new MutationObserver(render).observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme'] });
});
`);
    },
  },
};

export default defineConfig({
  site: SITE_ORIGIN,
  base: BASE,
  // Starlight drops the .html from a sidebar link; this serves the trail and the development graph at the extensionless path too.
  redirects: { '/adoption-trail': `${BASE}/adoption-trail.html`, '/guide/dev-graph': `${BASE}/guide/dev-graph.html` },
  markdown: { remarkPlugins: [[remarkDocs, { base: BASE, allow: ALLOW, html: HTML_PASSTHROUGH }]] },
  integrations: [
    starlight({
      title: 'himmel',
      // tokens.css is the canonical palette (the console serves a byte copy); the map points Starlight's --sl-* at it.
      customCss: ['./src/styles/tokens.css', './src/styles/starlight-map.css'],
      // Top-level groups are the F1 frame of docs-mockup-v4-agreed.html; test-site-build.sh asserts the list.
      sidebar: [
        {
          label: 'Get started',
          items: [
            { label: 'What himmel is', slug: 'why-himmel' },
            { label: 'Quickstart', slug: 'getting-started' },
            { label: 'The adoption trail', link: '/adoption-trail.html' },
            { label: 'Install on your project', slug: 'setup/install' },
            { label: 'Install profiles', slug: 'setup/profiles' },
            'setup/new-machine',
            { label: 'Updating & uninstalling', slug: 'setup/updating' },
            { label: 'Moving from an older install', slug: 'setup/migrating' },
          ],
        },
        {
          label: 'Use it',
          items: [
            { label: 'The daily loop', slug: 'daily-loop' },
            { label: 'The development graph', link: '/guide/dev-graph.html' },
            { label: 'Slash commands', slug: 'commands-catalog' },
            { label: 'The himmelctl command', slug: 'himmelctl' },
            { label: 'Settings & configuration', slug: 'configuration' },
            { label: 'Scheduled jobs', slug: 'cadences' },
            { label: 'The local dashboard', slug: 'ui' },
            {
              label: 'Lanes & launchers',
              items: [
                { label: 'Launchers and lanes', slug: 'launchers' },
                { label: 'Running under Codex', slug: 'setup/codex' },
                { label: 'CLIProxyAPI codex lane', slug: 'setup/cli-proxy-lane' },
                { label: 'Hermes runbook', slug: 'hermes-runbook' },
              ],
            },
            { label: 'Cloud sessions', slug: 'setup/cloud-environment' },
            { label: 'Telegram bridge', slug: 'telegram-bridge' },
            {
              label: 'Second brain (notes vault)',
              items: [
                { label: 'Overview', slug: 'luna' },
                { label: 'Compounding loop', slug: 'luna/compounding' },
                { label: 'End-session wiki', slug: 'luna/end-session-wiki' },
                { label: 'Session note schema', slug: 'luna/end-session-wiki-schema' },
                { label: 'Google Health connector', slug: 'luna/google-health-connector-setup' },
                { label: 'PR-lane guard', slug: 'luna/pr-lane-guard' },
              ],
            },
            {
              label: 'Optional subsystems',
              items: [
                { label: 'Jarvis subsystems', slug: 'jarvis-subsystems' },
                { label: 'himmel-bus (early)', slug: 'himmel-bus' },
                { label: 'Voice (beta)', slug: 'voice' },
              ],
            },
            {
              label: 'Plugins',
              items: [
                { label: 'himmel-guard', link: `${REPO_URL}/tree/main/marketplace/plugins/himmel-guard` },
                { label: 'shadcn-mcp', link: `${REPO_URL}/tree/main/marketplace/plugins/shadcn-mcp` },
                { label: 'handover', link: `${REPO_URL}/tree/main/marketplace/plugins/handover` },
              ],
            },
          ],
        },
        {
          label: 'Run many sessions',
          items: [
            { label: 'AFK (unattended) runs', slug: 'handover/afk-mode' },
            { label: 'The chief and its workers', slug: 'handover/running-a-console' },
            { label: 'Handover notes', slug: 'internals/handover-system' },
            { label: 'Orchestration patterns', slug: 'orchestration-patterns' },
            { label: 'Usage and cost', slug: 'token-economy' },
          ],
        },
        {
          label: 'Reference',
          items: [
            { label: 'Every guardrail and gate', slug: 'internals/enforcement' },
            { label: 'When a guardrail stops you', slug: 'internals/stuck-playbook' },
            { label: 'What data leaves your machine', slug: 'internals/egress-matrix' },
            { label: 'Running without a terminal', slug: 'internals/headless-modes' },
            { label: 'Using it from Codex', slug: 'internals/harness-compat' },
            { label: 'Jira integration', slug: 'internals/jira-plugin' },
            { label: 'Glossary', slug: 'glossary' },
          ],
        },
        {
          label: 'For contributors',
          items: [
            { label: 'Contributing', slug: 'contributing' },
            { label: 'How himmel is built', slug: 'system-design' },
            { label: 'Security review', slug: 'security-review' },
            { label: 'Testing', slug: 'internals/testing' },
            {
              label: 'Releases & licenses',
              items: [
                { label: 'v1.1.2 notes', slug: 'release/v1.1.2-notes' },
                { label: 'v1.0.0 notes', slug: 'release/v1.0.0-notes' },
                { label: 'Versioning scheme', slug: 'release/versioning-scheme' },
                { label: 'License audit', slug: 'license-audit' },
                { label: 'Third-party licenses', slug: 'third-party-licenses' },
                { label: 'Credits', slug: 'credits' },
              ],
            },
            {
              label: 'Internals',
              items: [
                { label: 'Architecture diagrams', slug: 'architecture' },
                { label: 'Context architecture', slug: 'internals/context-architecture' },
                { label: 'Environment gotchas', slug: 'internals/environment-gotchas' },
                { label: 'Lane calibration', slug: 'internals/lane-calibration' },
                { label: 'Lane parity', slug: 'internals/lane-parity' },
                { label: 'RETASK channel', slug: 'internals/retask-channel' },
                { label: 'Prompt cache', slug: 'internals/prompt-cache' },
                { label: 'Config layers', slug: 'internals/config-layers' },
                { label: 'MCP servers', slug: 'internals/mcp-servers' },
                { label: 'The ponytail convention', slug: 'internals/ponytail-convention' },
              ],
            },
            {
              label: 'Security policies',
              items: [
                { label: 'npm policy', slug: 'security/npm-policy' },
                { label: 'Python policy', slug: 'security/python-policy' },
              ],
            },
            {
              label: 'Tool adoption',
              items: [
                { label: 'Rubric', slug: 'tool-adoption/rubric' },
                { label: 'Registry', slug: 'tool-adoption/registry' },
                { label: 'Telemetry', slug: 'tool-adoption/telemetry' },
                { label: 'Lane adoption playbook', slug: 'tool-adoption/lane-adoption-playbook' },
              ],
            },
            {
              label: 'Evals',
              items: [
                { label: 'Prompt cache', slug: 'evals/prompt-cache' },
                { label: 'Review panel', slug: 'evals/review-panel' },
              ],
            },
          ],
        },
      ],
    }),
    mermaid,
    copyPassthrough,
  ],
});
