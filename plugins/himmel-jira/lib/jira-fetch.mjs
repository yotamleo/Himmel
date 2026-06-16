import { execFileSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { dirname, join } from 'node:path';

function repoRoot() {
  try {
    const dir = execFileSync('git', ['rev-parse', '--git-common-dir'], { encoding: 'utf8' }).trim();
    return dirname(dir);
  } catch (e) {
    // Pre-HIMMEL-108 the non-ENOENT arm silently fell back to cwd, masking
    // the case where a corrupt/bare/missing local git state caused the plugin
    // to load the WRONG .env (cwd) or no creds at all (cwd has no .env) → 401
    // with no clue why. Mirror the HIMMEL-101 fix in scripts/jira/src/client.ts:
    // surface every non-ENOENT failure with the underlying error message so
    // an operator can diagnose, and keep the ENOENT branch specific so the
    // "git not on PATH" case stays distinguishable in logs.
    if (e.code === 'ENOENT') {
      process.stderr.write(
        '[jira-fetch] warning: git not found on PATH — falling back to ' +
          `cwd=${process.cwd()} for .env lookup. ` +
          'Set JIRA_API_TOKEN/JIRA_BASE_URL via env vars to bypass.\n',
      );
    } else {
      process.stderr.write(
        `[jira-fetch] warning: git rev-parse --git-common-dir failed (${e.message}); ` +
          `falling back to cwd=${process.cwd()} for .env lookup. ` +
          'Set JIRA_API_TOKEN/JIRA_BASE_URL via env vars to bypass.\n',
      );
    }
    return process.cwd();
  }
}

export function envFilePath(override) {
  if (override) return override;
  const root = repoRoot();
  const inRepo = join(root, '.env');
  if (existsSync(inRepo)) return inRepo;
  return join(process.env.HOME || process.env.USERPROFILE || '.', '.config', 'himmel-cli', 'jira.env');
}

export async function jiraFetch(method, path, body) {
  const base = process.env.JIRA_BASE_URL;
  if (!base) throw new Error('JIRA_BASE_URL not set — run /jira-init');
  const email = process.env.JIRA_EMAIL || '';
  const token = process.env.JIRA_API_TOKEN || '';
  const auth = `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
  const res = await fetch(`${base}/rest/api/3${path}`, {
    method,
    headers: { Authorization: auth, 'Content-Type': 'application/json', Accept: 'application/json' },
    body: body !== undefined ? JSON.stringify(body) : undefined,
  });
  if (!res.ok) {
    const body = await res.text();
    const snippet = body.length > 300 ? body.slice(0, 300) + '…' : body;
    throw new Error(`HTTP ${res.status}: ${snippet}`);
  }
  const t = await res.text();
  return t.trim() ? JSON.parse(t) : {};
}
