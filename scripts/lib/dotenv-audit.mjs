#!/usr/bin/env node
// Read-only .env allowlist diagnostics (HIMMEL-4910). Never return file values.
import { readdirSync, readFileSync, existsSync } from 'node:fs';
import { join, relative } from 'node:path';
import { fileURLToPath } from 'node:url';

// Named-key readers do not export a parsed dictionary. Config display and
// redaction readers are deliberately excluded: they must see all values.
const NAMED_READERS = {
  'scripts/telegram/glm-env.ts': ['ZAI_API_KEY'],
  'scripts/telegram/poller.ts': ['TELEGRAM_BOT_TOKEN', 'TELEGRAM_AUTO_ACTIONS'],
  'scripts/telegram/session-status.ts': ['TELEGRAM_BOT_TOKEN'],
  'scripts/observability/luna-sync-alert.ts': ['TELEGRAM_BOT_TOKEN'],
  'scripts/alibaba/create-monitoring-key.ts': ['ALIBABA_QUOTA_AK', 'ALIBABA_QUOTA_SK'],
  'scripts/himmelctl/lib/install-engine.js': ['HIMMELCTL_SUDO_PASSWORD'],
  'scripts/luna/enrich-chat-notes.py': ['DEEPSEEK_API_KEY', 'OPENAI_API_KEY', 'ZAI_API_KEY', 'ANTHROPIC_API_KEY'],
};
const KEY = /^[A-Za-z_][A-Za-z0-9_]*$/;

function sources(dir) {
  if (!existsSync(dir)) return [];
  return readdirSync(dir, { withFileTypes: true }).flatMap(e => {
    if (e.isSymbolicLink() || /^(?:node_modules|dist|fixtures|test|tests|__pycache__|\.git)$/.test(e.name)) return [];
    const p = join(dir, e.name);
    if (e.isDirectory()) return sources(p);
    if (/(?:^test[-_]|\.test\.|\.md$|\.json$|\.lock$|\.tsv$)/.test(e.name)) return [];
    return /\.(?:sh|ps1|ts|js|mjs|py)$/.test(e.name) || /^claude-/.test(e.name) ? [p] : [];
  });
}

export function auditDotenv(root) {
  const used = new Set();
  const rows = [];
  const warn = (path, line) => rows.push({ sev: 'WARN', msg: `consumer has no explicit .env allowlist: ${path}:${line}` });
  for (const file of sources(join(root, 'scripts'))) {
    const path = relative(root, file).replaceAll('\\', '/');
    const text = readFileSync(file, 'utf8');
    for (const key of NAMED_READERS[path] ?? []) used.add(key);
    // The key set is declared at the consumer, not a prefix such as JIRA_*.
    for (const m of text.matchAll(/\bDOTENV_KEYS\s*=\s*(?:new Set\(|frozenset\()?\s*[\[({]([\s\S]*?)[\])}]/g)) {
      for (const k of m[1].matchAll(/["']([A-Za-z_][A-Za-z0-9_]*)["']/g)) used.add(k[1]);
    }
    if (/^\s*(?:from dotenv import load_dotenv\b|dotenv\.config\s*\()/m.test(text)) warn(path, 1);
    if (/process\.env\[key(?:\.trim\(\))?\]\s*\?\?=/.test(text) && !/DOTENV_KEYS\.has\(key(?:\.trim\(\))?\)/.test(text)) warn(path, 1);
    if (path.endsWith('.ps1')) {
      for (const m of text.matchAll(/Get-DotenvKey[^\n]*-Name\s+["']([A-Za-z_][A-Za-z0-9_]*)["']/g)) used.add(m[1]);
    }
    if (path.endsWith('.sh') || /\/claude-[^/.]+$/.test(path)) {
      const lines = text.replace(/\\\r?\n/g, ' ').split('\n');
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i].replace(/^\s*#.*$/, '');
        // Exclude definitions, probes and prose: only actual loader calls.
        const call = line.match(/(?:^|[;]|then\s+|&&\s+|!\s+)\s*(?:if\s+)?load_dotenv\b(?!\s*\()(.*)/);
        if (!call) continue;
        const args = call[1].split(/;|\|\|/)[0]
          .replace(/--root\s+(?:"\$\([\s\S]*?\)"|"[^"]*"|'[^']*'|\S+)/, '')
          .replace(/\s*\d*>[^\s]+/g, '').trim();
        if (!args) { warn(path, i + 1); continue; }
        for (const word of args.matchAll(/\b([A-Z][A-Z0-9_]*|himmel_github_token_vm)\b/g)) {
          if (!args.includes(`$${word[1]}`) && !args.includes(`\${${word[1]}`)) used.add(word[1]);
        }
        // Variable lists remain explicit (CR panel credentials, policy subset,
        // provider-selected graph keys). Resolve their literal assignments.
        for (const variable of args.matchAll(/\$(?:\{)?([A-Za-z_][A-Za-z0-9_]*)/g)) {
          const name = variable[1];
          for (const assignment of text.matchAll(new RegExp(`\\b${name}=([^\\n]*)`, 'g'))) {
            for (const key of assignment[1].matchAll(/\b[A-Z][A-Z0-9_]*\b/g)) if (key[0] !== name) used.add(key[0]);
          }
        }
      }
    }
  }
  // The VM consumer chooses credential names from its registry, not all VMs.
  const registry = join(root, 'scripts/lib/vms.json');
  if (existsSync(registry)) {
    for (const vm of Object.values(JSON.parse(readFileSync(registry, 'utf8')))) {
      if (vm.kind === 'station') continue;
      if (!vm.user && KEY.test(vm.user_env ?? '')) used.add(vm.user_env);
      if (KEY.test(vm.pass_env ?? '')) used.add(vm.pass_env);
    }
  }
  const env = join(root, '.env');
  if (existsSync(env)) {
    const unused = new Set();
    // Only capture the name before '='; values never enter the report.
    for (const line of readFileSync(env, 'utf8').split(/\r?\n/)) {
      const m = line.match(/^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=/);
      if (m && !used.has(m[1])) unused.add(m[1]);
    }
    if (unused.size) rows.push({ sev: 'INFO', msg: `.env keys loaded by no consumer: ${[...unused].sort().join(', ')}` });
  }
  if (!rows.length) rows.push({ sev: 'OK', msg: 'explicit .env consumer allowlists; no unused key names' });
  return rows;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  for (const row of auditDotenv(process.argv[2])) console.log(`${row.sev}\t${row.msg}`);
}
