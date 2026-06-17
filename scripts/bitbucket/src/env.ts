import { execFileSync } from 'node:child_process';
import { existsSync, readFileSync } from 'node:fs';
import { dirname } from 'node:path';

// Mirrors scripts/jira/src/client.ts: resolve the primary checkout root via
// git so the CLI loads the right .env even when invoked from a worktree
// (where .git is a file pointing at the common dir).
function repoRoot(): string {
  try {
    const gitCommonDir = execFileSync('git', ['rev-parse', '--git-common-dir'], {
      encoding: 'utf8',
    }).trim();
    return dirname(gitCommonDir);
  } catch (e) {
    process.stderr.write(
      `bitbucket: warning: git rev-parse --git-common-dir failed (${(e as Error).message}); ` +
        `falling back to cwd=${process.cwd()} for .env lookup. ` +
        `Set BITBUCKET_EMAIL/BITBUCKET_API_TOKEN via env vars to bypass.\n`,
    );
    return process.cwd();
  }
}

function loadEnv(): void {
  const envPath = `${repoRoot()}/.env`;
  if (!existsSync(envPath)) return;
  for (const line of readFileSync(envPath, 'utf8').split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith('#') || !trimmed.includes('=')) continue;
    const [key, ...rest] = trimmed.split('=');
    process.env[key.trim()] ??= rest.join('=').trim();
  }
}

// CRLF-safe Basic auth (same defensive parsing as the Jira CLI, HIMMEL-111):
// a CRLF-sourced env file leaves a trailing \r in the value, which corrupts
// the base64 Basic header and returns 401 with no hint. Strip + warn once.
export function normalizeEnv(): void {
  for (const key of ['BITBUCKET_EMAIL', 'BITBUCKET_API_TOKEN', 'BITBUCKET_WORKSPACE', 'BITBUCKET_REPO_SLUG']) {
    const raw = process.env[key];
    if (raw === undefined) continue;
    const cleaned = raw.replace(/[\s]+$/, '');
    if (cleaned !== raw) {
      process.stderr.write(
        `bitbucket: warning: stripped trailing whitespace from ${key} ` +
          '(probably from CRLF env file - run dos2unix on the source to silence)\n',
      );
      process.env[key] = cleaned;
    }
  }
}

loadEnv();
normalizeEnv();

export const BASE_URL = 'https://api.bitbucket.org/2.0';

export function authHeader(): string {
  const email = process.env.BITBUCKET_EMAIL ?? '';
  const token = process.env.BITBUCKET_API_TOKEN ?? '';
  if (!email || !token) {
    throw new Error(
      'BITBUCKET_EMAIL and BITBUCKET_API_TOKEN must be set (repo-root .env or environment). ' +
        'Create an Atlassian API token "with scopes" and select the Bitbucket app. ' +
        'See docs/setup/new-machine.md.',
    );
  }
  return `Basic ${Buffer.from(`${email}:${token}`).toString('base64')}`;
}
