/**
 * @typedef {Object} AuthStatusUnauth
 * @property {'unauth'} mode
 * @property {null} user
 * @property {string[]} scopes
 * @property {string[]} missingScopes
 * @property {number} exitCode
 * @property {string} summary
 * @property {string} [stderrHint]
 *
 * @typedef {Object} AuthStatusEnvToken
 * @property {'env-token'} mode
 * @property {string|null} user
 * @property {string[]} scopes
 * @property {string[]} missingScopes
 * @property {number} exitCode
 * @property {string} summary
 *
 * @typedef {Object} AuthStatusKeyring
 * @property {'keyring'} mode
 * @property {string|null} user
 * @property {string[]} scopes
 * @property {string[]} missingScopes
 * @property {number} exitCode
 * @property {string} summary
 *
 * @typedef {AuthStatusUnauth | AuthStatusEnvToken | AuthStatusKeyring} AuthStatusResult
 */

import { spawn } from 'node:child_process';

export const REQUIRED_SCOPES = ['repo', 'read:org', 'workflow'];

export function buildErrorStderr(existingStderr, err) {
  const tag = err && err.code ? `${err.code}: ` : '';
  return `${existingStderr}${tag}${err && err.message ? err.message : String(err)}\n`;
}

function extractUser(stdout) {
  const m = stdout.match(/Logged in to \S+ account (\S+)/);
  return m ? m[1] : null;
}

function extractScopes(stdout) {
  const m = stdout.match(/Token scopes:\s*(.+)/);
  if (!m) return [];
  const raw = m[1].trim();
  if (raw === 'none' || raw === '<none>') return [];
  return raw
    .split(',')
    .map((s) => s.trim().replace(/^['"]|['"]$/g, ''))
    .filter((s) => s && s !== 'none');
}

function detectMode({ stdout, exitCode, envHasToken }) {
  if (exitCode !== 0) return 'unauth';
  if (envHasToken) return 'env-token';
  if (/\(GH_TOKEN\)/.test(stdout)) return 'env-token';
  return 'keyring';
}

/**
 * @param {{ stdout: string, stderr: string, exitCode: number, envHasToken: boolean }} args
 * @returns {AuthStatusResult}
 */
export function parseAuthStatus({ stdout, stderr, exitCode, envHasToken }) {
  const mode = detectMode({ stdout, exitCode, envHasToken });

  if (mode === 'unauth') {
    return {
      mode,
      user: null,
      scopes: [],
      missingScopes: [],
      exitCode: 1,
      summary: 'gh NOT logged in. run: gh auth login --web',
      stderrHint: (stderr.trim().split('\n')[0] || '').slice(0, 200),
    };
  }

  const user = extractUser(stdout);

  if (mode === 'env-token') {
    return {
      mode,
      user,
      scopes: [],
      missingScopes: [],
      exitCode: 0,
      summary: `gh OK: ${user ?? '?'} @ github.com (env-token, scope check skipped)`,
    };
  }

  const scopes = extractScopes(stdout);
  const missingScopes = REQUIRED_SCOPES.filter((s) => !scopes.includes(s));
  const scopesPart = scopes.length ? scopes.join(', ') : '(none)';
  const missingPart = missingScopes.length ? ` | missing: ${missingScopes.join(', ')}` : '';
  return {
    mode,
    user,
    scopes,
    missingScopes,
    exitCode: 0,
    summary: `gh OK: ${user ?? '?'} @ github.com | scopes: ${scopesPart}${missingPart}`,
  };
}

function execGhDefault() {
  return new Promise((resolve) => {
    let stdout = '';
    let stderr = '';
    const proc = spawn('gh', ['auth', 'status', '--hostname', 'github.com'], {
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    proc.stdout.on('data', (d) => (stdout += d.toString()));
    proc.stderr.on('data', (d) => (stderr += d.toString()));
    proc.on('error', (err) => {
      const code = err.code === 'ENOENT' ? 127 : 1;
      resolve({ stdout, stderr: buildErrorStderr(stderr, err), exitCode: code });
    });
    proc.on('close', (code, signal) =>
      resolve({
        stdout,
        stderr: signal ? `${stderr}gh killed by signal ${signal}\n` : stderr,
        exitCode: code ?? (signal ? 129 : 1),
      }),
    );
  });
}

/**
 * @param {{ execGh?: () => Promise<{stdout: string, stderr: string, exitCode: number}>, env?: NodeJS.ProcessEnv }} [opts]
 * @returns {Promise<AuthStatusResult>}
 */
export async function runInit({ execGh = execGhDefault, env = process.env } = {}) {
  const { stdout, stderr, exitCode } = await execGh();
  if (exitCode === 127) {
    return {
      mode: 'unauth',
      user: null,
      scopes: [],
      missingScopes: [],
      exitCode: 127,
      summary: 'gh CLI not found on PATH. install: https://cli.github.com/',
    };
  }
  return parseAuthStatus({
    stdout,
    stderr,
    exitCode,
    envHasToken: Boolean(env.GH_TOKEN || env.GITHUB_TOKEN),
  });
}
