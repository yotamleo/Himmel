import { describe, it, expect, beforeEach } from 'vitest';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, writeFileSync } from 'node:fs';
import { tmpdir, platform } from 'node:os';
import { join, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const __dirname = fileURLToPath(new URL('.', import.meta.url));
const CLI = resolve(__dirname, '../lib/repo-context-cli.mjs');
const IS_WIN = platform() === 'win32';

let workDir;
let cacheRoot;
let stub;

// FORGE=bitbucket + BITBUCKET_CLI=<node stub> routes the CLI at a node script
// that echoes fixture JSON — the cross-platform analogue of the fake-gh PATH
// shim (works on Windows too, unlike the gh.cmd shim).
function envBb(extras = {}) {
  const env = {
    ...process.env,
    FORGE: 'bitbucket',
    // JSON-array form (HIMMEL-345): exact argv, no space-split — safe on Windows
    // where process.execPath contains a space (C:\Program Files\nodejs\node.exe).
    BITBUCKET_CLI: JSON.stringify([process.execPath, stub]),
    ...extras,
  };
  if (IS_WIN) env.LOCALAPPDATA = cacheRoot;
  else {
    env.XDG_CACHE_HOME = cacheRoot;
    delete env.HOME;
  }
  return env;
}

function writeStub(body) {
  stub = join(workDir, 'bb-stub.mjs');
  writeFileSync(stub, body);
}

beforeEach(() => {
  workDir = mkdtempSync(join(tmpdir(), 'himmel-gh-bb-cli-'));
  cacheRoot = join(workDir, 'cache');
});

// Runs on Windows too (HIMMEL-345): BITBUCKET_CLI now takes a JSON-array form
// parsed as exact argv, so the space in process.execPath (Program Files) no
// longer hits the (space-splitting) legacy path — same seam the thread CLIs use.
describe('repo-context-cli — bitbucket forge', () => {
  it('repo view JSON {workspace, repo_slug} → owner=workspace name=repo_slug', () => {
    writeStub(
      `process.stdout.write(JSON.stringify({ workspace: 'example-ws', repo_slug: 'demo', full_name: 'example-ws/demo', default_branch: 'main' })); process.exit(0);`,
    );
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(0);
    expect(r.stdout).toMatch(/owner=example-ws name=demo/);
  });

  it('missing repo_slug → exit 1', () => {
    writeStub(`process.stdout.write(JSON.stringify({ workspace: 'ws' })); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/missing workspace\/repo_slug/);
  });

  it('invalid JSON → exit 1', () => {
    writeStub(`process.stdout.write('nope'); process.exit(0);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(1);
    expect(r.stderr).toMatch(/invalid JSON/);
  });

  it('CLI non-zero exit → propagates exit code', () => {
    writeStub(`process.stderr.write('bb auth 401\\n'); process.exit(3);`);
    const r = spawnSync(process.execPath, [CLI], { env: envBb(), cwd: workDir, encoding: 'utf8' });
    expect(r.status).toBe(3);
  });
});
