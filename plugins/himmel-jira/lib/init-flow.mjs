import { appendFileSync, existsSync, mkdirSync, readFileSync, chmodSync } from 'node:fs';
import { dirname } from 'node:path';
import { jiraFetch, envFilePath } from './jira-fetch.mjs';
import { writeMetadata } from './metadata.mjs';

function loadEnvFile(path) {
  if (!existsSync(path)) return {};
  const out = {};
  for (const line of readFileSync(path, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const [k, ...rest] = t.split('=');
    out[k.trim()] = rest.join('=').trim();
  }
  return out;
}

export function loadEnvIntoProcess(envPath) {
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const t = line.trim();
    if (!t || t.startsWith('#') || !t.includes('=')) continue;
    const [k, ...rest] = t.split('=');
    const key = k.trim();
    const value = rest.join('=').trim();
    // Strip optional surrounding quotes
    const unquoted = value.replace(/^"(.*)"$/, '$1').replace(/^'(.*)'$/, '$1');
    if (!process.env[key]) process.env[key] = unquoted;
  }
}

export function ensureEnvKeys(envPath, keys) {
  const current = loadEnvFile(envPath);
  return keys.filter((k) => !current[k]);
}

// Resolve the project key(s) to discover, in precedence order:
//   --projects flag  >  JIRA_PROJECTS (comma-list)  >  JIRA_PROJECT_KEY
// Returns a clean array (whitespace trimmed, empties dropped). An empty array
// means "nothing configured" — the caller must fail loud, never default to a
// project. `rawArg` may be the boolean `true` when `--projects` is passed with
// no value (arg parser quirk); coerce non-strings to '' so that misuse routes
// to the empty-array path instead of a TypeError.
export function resolveProjects({ rawArg, env = process.env } = {}) {
  const raw = (typeof rawArg === 'string' ? rawArg : '')
    || env.JIRA_PROJECTS || env.JIRA_PROJECT_KEY || '';
  return raw.split(',').map((p) => p.trim()).filter(Boolean);
}

export const UNSAFE_VALUE_RE = /[=\n\r]|^["'](?!.*\1$)/;

export function appendEnvKeys(envPath, kvs) {
  for (const [k, v] of Object.entries(kvs)) {
    if (UNSAFE_VALUE_RE.test(v)) {
      throw new Error(
        `appendEnvKeys: value for ${k} contains '=', newline, or unbalanced quotes — refusing to write`,
      );
    }
  }
  const dir = dirname(envPath);
  if (dir && !existsSync(dir)) mkdirSync(dir, { recursive: true, mode: 0o700 });
  const lines = Object.entries(kvs).map(([k, v]) => `${k}=${v}`);
  appendFileSync(envPath, (existsSync(envPath) ? '\n' : '') + lines.join('\n') + '\n');
  try {
    chmodSync(envPath, 0o600);
  } catch (e) {
    if (process.platform !== 'win32') {
      process.stderr.write(`[jira-init] warning: chmod 600 failed on ${envPath}: ${e.message}\n`);
    }
  }
}

export async function checkAuth() {
  const me = await jiraFetch('GET', '/myself');
  return { displayName: me.displayName, accountId: me.accountId, base: process.env.JIRA_BASE_URL };
}

export async function discoverMetadata(projectsToTrack) {
  const out = { fetched_at: new Date().toISOString(), default_project: undefined, projects: {}, aliases: {}, accounts: {} };
  const projects = await jiraFetch('GET', '/project/search');
  const allProjects = projects.values ?? [];
  if (!allProjects.length) {
    process.stderr.write('[jira-init] warning: /project/search returned no projects\n');
    return out;
  }
  // Order by the configured projectsToTrack (not the API's response order) so
  // default_project is deterministic — it must equal the first configured key
  // (= JIRA_PROJECT_KEY for single-project users) since check-required now
  // resolves to default_project when --project is omitted.
  const tracked = projectsToTrack
    .map((k) => allProjects.find((p) => p.key === k))
    .filter(Boolean);
  out.default_project = tracked[0]?.key;
  for (const p of tracked) {
    // Use paginated createmeta endpoints (old combined endpoint deprecated June 2024).
    // Default page size (50 types, 50 fields) is sufficient for v1.
    const typesRes = await jiraFetch('GET', `/issue/createmeta/${p.key}/issuetypes`);
    if (!typesRes.issueTypes) {
      process.stderr.write(`[jira-init] warning: no issueTypes in createmeta response for ${p.key}\n`);
    }
    const types = {};
    for (const t of typesRes.issueTypes ?? []) {
      let required = [];
      try {
        const fieldsRes = await jiraFetch('GET', `/issue/createmeta/${p.key}/issuetypes/${t.id}`);
        required = (fieldsRes.fields ?? []).filter((f) => f.required).map((f) => f.fieldId);
      } catch (e) {
        process.stderr.write(`[jira-init] warning: could not fetch fields for ${p.key}/${t.name}: ${e.message}\n`);
      }
      types[t.name] = { id: t.id, required_fields: required };
    }
    let transitions = {};
    try {
      const search = await jiraFetch('GET', `/search?jql=project=${p.key}&maxResults=1&fields=summary`);
      if (search.issues?.[0]) {
        const tx = await jiraFetch('GET', `/issue/${search.issues[0].key}/transitions`);
        transitions = Object.fromEntries(tx.transitions.map((tr) => [tr.to?.name ?? tr.name, tr.id]));
        if (Object.keys(transitions).length < 3) {
          process.stderr.write(`[jira-init] warning: only ${Object.keys(transitions).length} transition(s) found for ${p.key} — transitions cache may be incomplete; run /jira-refresh after more workflow states are configured\n`);
        }
      } else {
        process.stderr.write(`[jira-init] warning: project ${p.key} has no issues yet — transitions cache empty, run /jira-refresh after first issue is created\n`);
      }
    } catch (e) {
      process.stderr.write(`[jira-init] warning: could not fetch transitions for ${p.key}: ${e.message}\n`);
      process.stderr.write(`  /jira-transition for ${p.key} will not work until you run /jira-refresh\n`);
    }
    out.projects[p.key] = { id: p.id, name: p.name, issue_types: types, transitions };
    out.aliases[p.key.toLowerCase()] = p.key;
  }
  return out;
}

export async function autoFetchAccountId(email) {
  try {
    const users = await jiraFetch('GET', `/user/search?query=${encodeURIComponent(email)}`);
    if (!users[0]?.accountId) {
      process.stderr.write(`[jira-init] warning: no Jira account found for ${email}\n`);
      return null;
    }
    return users[0].accountId;
  } catch (e) {
    process.stderr.write(`[jira-init] warning: could not resolve account for ${email}: ${e.message}\n`);
    return null;
  }
}

export async function runInit({ envOverride, projects = [], emails = [] } = {}) {
  if (!projects.length) {
    throw new Error('runInit: no projects to discover — set JIRA_PROJECT_KEY (or JIRA_PROJECTS) and re-run');
  }
  const envFile = envFilePath(envOverride);
  loadEnvIntoProcess(envFile);
  const missing = ensureEnvKeys(envFile, ['JIRA_EMAIL', 'JIRA_API_TOKEN', 'JIRA_BASE_URL']);
  if (missing.length) return { needsPrompt: true, missing, envFile };
  const auth = await checkAuth();
  const metadata = await discoverMetadata(projects);
  for (const e of emails) {
    const id = await autoFetchAccountId(e);
    if (id) metadata.accounts[e] = id;
  }
  writeMetadata(metadata);
  return {
    needsPrompt: false,
    summary: `JIRA OK: ${auth.displayName} @ ${auth.base} | cached ${Object.keys(metadata.projects).length} projects`,
  };
}
