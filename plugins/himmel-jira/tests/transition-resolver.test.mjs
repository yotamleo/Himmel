import { describe, it, expect, beforeEach } from 'vitest';
import { mkdtempSync, rmSync, mkdirSync, writeFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join, resolve } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const resolverScript = resolve(__dirname, '..', 'lib', 'transition-resolver.mjs');

/** Set the env var that controls metadataPath cache root. */
function cacheEnv(tmpDir) {
  if (platform() === 'win32') {
    return { LOCALAPPDATA: tmpDir };
  }
  return { HOME: tmpDir, XDG_CACHE_HOME: '' };
}

/** Write a stub metadata.json under the expected cache path. */
function writeStubMeta(cacheRoot, data) {
  const sub = platform() === 'win32'
    ? join(cacheRoot, 'himmel-cli', 'jira')
    : join(cacheRoot, '.cache', 'himmel-cli', 'jira');
  mkdirSync(sub, { recursive: true });
  writeFileSync(join(sub, 'metadata.json'), JSON.stringify(data));
}

function run(args, envOverrides = {}) {
  return spawnSync(process.execPath, [resolverScript, ...args], {
    encoding: 'utf8',
    env: { ...process.env, ...envOverrides },
  });
}

let dir;

beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), 'himmel-tresolver-'));
});

describe('transition-resolver', () => {
  it('exits 1 with "no-cache" when metadata is absent', () => {
    const env = cacheEnv(dir);
    const r = run([], env);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('no-cache');
  });

  it('exits 1 with "--key required" when --key is missing', () => {
    const env = cacheEnv(dir);
    const meta = { projects: { FOO: { transitions: { Done: '31' } } } };
    writeStubMeta(dir, meta);
    const r = run(['--status', 'Done'], env);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('--key required');
  });

  it('exits 1 with "--status required" when --status is missing', () => {
    const env = cacheEnv(dir);
    const meta = { projects: { FOO: { transitions: { Done: '31' } } } };
    writeStubMeta(dir, meta);
    const r = run(['--key', 'FOO-1'], env);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('--status required');
  });

  it('prints transition ID to stdout on success', () => {
    const env = cacheEnv(dir);
    const meta = { projects: { FOO: { transitions: { Done: '31' } } } };
    writeStubMeta(dir, meta);
    const r = run(['--key', 'FOO-1', '--status', 'Done'], env);
    expect(r.status).toBe(0);
    expect(r.stdout.trim()).toBe('31');
  });

  it('exits 1 with "no transition" when status is absent for that project', () => {
    const env = cacheEnv(dir);
    const meta = { projects: { FOO: { transitions: { Done: '31' } } } };
    writeStubMeta(dir, meta);
    const r = run(['--key', 'FOO-1', '--status', 'InProgress'], env);
    expect(r.status).toBe(1);
    expect(r.stderr).toContain('no transition InProgress for FOO');
  });
});
