import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const checkScript = resolve(__dirname, '..', 'lib', 'check-required.mjs');

function cacheEnv(tmpDir) {
  if (platform() === 'win32') {
    return { LOCALAPPDATA: tmpDir };
  }
  return { HOME: tmpDir, XDG_CACHE_HOME: '' };
}

function writeStubMeta(cacheRoot, data) {
  const sub = platform() === 'win32'
    ? join(cacheRoot, 'himmel-cli', 'jira')
    : join(cacheRoot, '.cache', 'himmel-cli', 'jira');
  mkdirSync(sub, { recursive: true });
  writeFileSync(join(sub, 'metadata.json'), JSON.stringify(data));
}

function run(args, envOverrides = {}) {
  return spawnSync(process.execPath, [checkScript, ...args], {
    encoding: 'utf8',
    env: { ...process.env, ...envOverrides },
  });
}

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-creq-'));
});

describe('check-required', () => {
  it('exits 1 with "no-cache" when metadata is absent', () => {
    const env = cacheEnv(dir);
    const r = run(['--type', 'Task', '--project', 'FOO'], env);
    expect(r.status).toBe(1);
    expect(r.stdout).toContain('no-cache');
  });

  it('prints required fields for a valid type+project', () => {
    const env = cacheEnv(dir);
    const meta = {
      fetched_at: new Date().toISOString(),
      default_project: 'FOO',
      projects: {
        FOO: {
          issue_types: {
            Task: { required_fields: ['summary', 'issuetype'] },
          },
        },
      },
    };
    writeStubMeta(dir, meta);
    const r = run(['--type', 'Task', '--project', 'FOO'], env);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain('required: summary,issuetype');
  });

  it('falls back to default_project when --project is omitted (portable: no hardcoded HIMMEL)', () => {
    const env = cacheEnv(dir);
    const meta = {
      fetched_at: new Date().toISOString(),
      default_project: 'ACME',
      projects: {
        ACME: {
          issue_types: {
            Task: { required_fields: ['summary'] },
          },
        },
      },
    };
    writeStubMeta(dir, meta);
    const r = run(['--type', 'Task'], env);
    expect(r.status).toBe(0);
    expect(r.stdout).toContain('required: summary');
  });

  it('prints (cache stale...) to stderr when fetched_at is >30 days old', () => {
    const env = cacheEnv(dir);
    const fortyDaysAgo = new Date(Date.now() - 40 * 86400_000).toISOString();
    const meta = {
      fetched_at: fortyDaysAgo,
      default_project: 'FOO',
      projects: {
        FOO: {
          issue_types: {
            Task: { required_fields: ['summary'] },
          },
        },
      },
    };
    writeStubMeta(dir, meta);
    const r = run(['--type', 'Task', '--project', 'FOO'], env);
    expect(r.stderr).toContain('cache stale');
  });
});
