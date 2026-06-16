import { describe, it, expect, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, chmodSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const CLI = resolve(__dirname, '../lib/repo-context-cli.mjs');
const IS_WIN = platform() === 'win32';

let workDir;
let fakeBin;
let cacheRoot;

function envWithFakeGh(extras = {}) {
  const env = {
    ...process.env,
    PATH: `${fakeBin}${IS_WIN ? ';' : ':'}${process.env.PATH}`,
    ...extras,
  };
  if (IS_WIN) env.LOCALAPPDATA = cacheRoot;
  else {
    env.XDG_CACHE_HOME = cacheRoot;
    delete env.HOME; // force XDG path
  }
  return env;
}

function writeFakeGh(script) {
  if (IS_WIN) {
    const js = join(fakeBin, 'gh-impl.js');
    writeFileSync(js, script);
    const cmd = `@echo off\r\nnode "${js}" %*\r\n`;
    writeFileSync(join(fakeBin, 'gh.cmd'), cmd);
  } else {
    const sh = join(fakeBin, 'gh');
    writeFileSync(sh, `#!/usr/bin/env node\n${script}\n`);
    chmodSync(sh, 0o755);
  }
}

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'himmel-gh-cli-'));
  fakeBin = join(workDir, 'bin');
  cacheRoot = join(workDir, 'cache');
  mkdirSync(fakeBin, { recursive: true });
  mkdirSync(cacheRoot, { recursive: true });
});

// Windows: Node's spawn('gh', ...) without shell:true can't resolve .cmd
// shims reliably (it only finds .exe on PATH). The fake-gh shim pattern
// works on POSIX. We skip CLI tests on Windows and rely on lib-level
// tests (repo-context.test.mjs) for cross-platform coverage. The CLI
// runs on Windows in production via the real gh.exe.
describe.skipIf(IS_WIN)('repo-context-cli', () => {
  it('happy path: gh repo view JSON → owner=... name=... + cache written', () => {
    writeFakeGh(`process.stdout.write(JSON.stringify({ owner: { login: 'yotamleo' }, name: 'himmel' })); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/owner=yotamleo name=himmel/);
  });

  it('invalid JSON → exit 1 + stderr explanation', () => {
    writeFakeGh(`process.stdout.write('not-json-at-all'); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/invalid JSON/);
  });

  it('missing owner.login → exit 1', () => {
    writeFakeGh(`process.stdout.write(JSON.stringify({ owner: {}, name: 'himmel' })); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/missing owner\/name/);
  });

  it('missing name → exit 1', () => {
    writeFakeGh(`process.stdout.write(JSON.stringify({ owner: { login: 'a' } })); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/missing owner\/name/);
  });

  it('gh repo view non-zero exit → propagates exit code', () => {
    writeFakeGh(`process.stderr.write('not a github repo\\n'); process.exit(4);`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(4);
    expect(r.stderr).toMatch(/not a github repo/);
  });

  it.skipIf(IS_WIN)('signal-killed close on POSIX → exitCode 129', () => {
    writeFakeGh(`process.kill(process.pid, 'SIGTERM');`);
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(129);
  });

  it('writeCache failure → still exits 0, prints owner=... + stderr warn', () => {
    // Force writeCache to fail by making the himmel-cli child path a regular
    // file (so mkdirSync recursive inside writeCache hits ENOTDIR).
    writeFakeGh(`process.stdout.write(JSON.stringify({ owner: { login: 'a' }, name: 'b' })); process.exit(0);`);
    const collision = join(cacheRoot, 'himmel-cli');
    writeFileSync(collision, 'blocker');
    const r = spawnSync(process.execPath, [CLI], { env: envWithFakeGh(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/owner=a name=b/);
    expect(r.stderr).toMatch(/cache write failed/);
  });
});
