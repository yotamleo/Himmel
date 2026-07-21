import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdir, mkdtemp, realpath, rm, symlink, writeFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import { isJjRepo, getJjStatus } from '../dist/jj.js';

function hasJj() {
  try {
    execFileSync('jj', ['--version'], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}
const jjAvailable = hasJj();
const skipReason = jjAvailable ? false : 'jj binary not installed';

test('isJjRepo returns false when cwd is undefined', () => {
  assert.equal(isJjRepo(undefined), false);
});

test('isJjRepo returns false for a non-jj directory', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-nojj-'));
  try {
    assert.equal(isJjRepo(dir), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus returns null when cwd is undefined', async () => {
  const result = await getJjStatus(undefined);
  assert.equal(result, null);
});

test('getJjStatus returns null for a non-jj directory', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-nojj-'));
  try {
    const result = await getJjStatus(dir);
    assert.equal(result, null);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus uses a fixed read-only bounded invocation', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-runner-'));
  let invocation;
  try {
    const result = await getJjStatus(dir, async (file, args, options) => {
      invocation = { file, args: [...args], options };
      return { stdout: 'qpvuntsm\x1fmain\x1f0\x1f0\n' };
    });

    assert.equal(result?.branch, 'main');
    assert.equal(invocation?.file, 'jj');
    assert.deepEqual(invocation?.args.slice(0, 4), [
      '--ignore-working-copy',
      '--at-operation=@',
      '--no-pager',
      'log',
    ]);
    assert.deepEqual(invocation?.args.slice(4, 10), [
      '-r', '@', '--no-graph', '--color', 'never', '-T',
    ]);
    assert.match(invocation?.args[10] ?? '', /local_bookmarks/);
    assert.equal(invocation?.options.cwd, await realpath(dir));
    assert.equal(invocation?.options.timeout, 2000);
    assert.equal(invocation?.options.maxBuffer, 16 * 1024);
    assert.equal(invocation?.options.encoding, 'utf8');
    assert.equal(invocation?.options.shell, false);
    assert.equal(invocation?.options.windowsHide, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus strictly validates field count and boolean flags', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-parse-'));
  try {
    for (const stdout of [
      'change\x1fmain\x1f0',
      'change\x1fmain\x1f0\x1f0\x1fextra',
      'change\x1fmain\x1fyes\x1f0',
      'change\x1fmain\x1f0\x1f2',
      '\x1fmain\x1f0\x1f0',
      'change\x1fmain\x1f0\x1f0\nextra',
      'change\x1fmain\x1e\x1f0\x1f0',
    ]) {
      const result = await getJjStatus(dir, async () => ({ stdout }));
      assert.equal(result, null, `expected malformed output to be rejected: ${JSON.stringify(stdout)}`);
    }
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus preserves commas and separates local bookmarks safely', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-bookmarks-'));
  try {
    const result = await getJjStatus(
      dir,
      async () => ({ stdout: 'qpvuntsm\x1ffeature,one\x1efeature-two\x1f1\x1f0' }),
    );
    assert.equal(result?.branch, 'feature,one');
    assert.equal(result?.isDirty, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus sanitizes terminal controls and caps the chosen label', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-label-'));
  try {
    const unsafe = `safe\x1b]8;;https://evil.example\x07link\x1b]8;;\x07\u202E${'x'.repeat(100)}`;
    const result = await getJjStatus(
      dir,
      async () => ({ stdout: `qpvuntsm\x1f${unsafe}\x1f0\x1f1` }),
    );
    assert.ok(result);
    assert.equal(result.branch.length, 64);
    assert.equal(result.branch.includes('\x1b'), false);
    assert.equal(result.branch.includes('\u202E'), false);
    assert.equal(result.conflict, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('isJjRepo resolves the cwd before walking', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-realpath-'));
  const link = `${dir}-link`;
  try {
    await mkdir(path.join(dir, '.jj'));
    await symlink(dir, link, 'dir');
    assert.equal(isJjRepo(link), true);
  } finally {
    await rm(link, { recursive: true, force: true });
    await rm(dir, { recursive: true, force: true });
  }
});

test('isJjRepo rejects a symlinked .jj marker', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-symlink-'));
  const markerTarget = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-marker-'));
  try {
    await symlink(markerTarget, path.join(dir, '.jj'), 'dir');
    assert.equal(isJjRepo(dir), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
    await rm(markerTarget, { recursive: true, force: true });
  }
});

test('isJjRepo stops at a nearer .git marker', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-boundary-'));
  const nested = path.join(dir, 'nested');
  const deep = path.join(nested, 'deep');
  try {
    await mkdir(path.join(dir, '.jj'));
    await mkdir(deep, { recursive: true });
    await writeFile(path.join(nested, '.git'), 'gitdir: elsewhere\n');
    assert.equal(isJjRepo(deep), false);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('isJjRepo prefers a same-directory .jj marker over .git', async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-colocated-'));
  try {
    await mkdir(path.join(dir, '.jj'));
    await mkdir(path.join(dir, '.git'));
    assert.equal(isJjRepo(dir), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('isJjRepo and getJjStatus detect a real jj repo', { skip: skipReason }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-'));
  try {
    execFileSync('jj', ['git', 'init'], { cwd: dir, stdio: 'ignore' });

    assert.equal(isJjRepo(dir), true);

    const result = await getJjStatus(dir);
    assert.equal(result?.vcs, 'jj');
    assert.equal(result?.conflict, false);
    assert.equal(result?.isDirty, false);
    assert.ok(result?.branch, `expected an anonymous change id, got ${JSON.stringify(result)}`);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus reports isDirty after an uncommitted change', { skip: skipReason }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-'));
  try {
    execFileSync('jj', ['git', 'init'], { cwd: dir, stdio: 'ignore' });
    await writeFile(path.join(dir, 'a.txt'), 'hello');

    const result = await getJjStatus(dir);
    assert.equal(result?.isDirty, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus reports the bookmark name at @ when one exists', { skip: skipReason }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-'));
  try {
    execFileSync('jj', ['git', 'init'], { cwd: dir, stdio: 'ignore' });
    execFileSync('jj', ['bookmark', 'create', 'mybookmark', '-r', '@'], { cwd: dir, stdio: 'ignore' });

    const result = await getJjStatus(dir);
    assert.equal(result?.branch, 'mybookmark');
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('isJjRepo detects a jj repo from a nested subdirectory', { skip: skipReason }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-'));
  try {
    execFileSync('jj', ['git', 'init'], { cwd: dir, stdio: 'ignore' });
    const nested = path.join(dir, 'a', 'b', 'c');
    await mkdir(nested, { recursive: true });

    assert.equal(isJjRepo(nested), true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});

test('getJjStatus detects a genuine conflict', { skip: skipReason }, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-jj-'));
  try {
    execFileSync('jj', ['git', 'init'], { cwd: dir, stdio: 'ignore' });
    await writeFile(path.join(dir, 'f.txt'), 'original\n');
    execFileSync('jj', ['commit', '-m', 'initial'], { cwd: dir, stdio: 'ignore' });

    const initialId = execFileSync(
      'jj',
      ['log', '-r', 'heads(::@- ~ root())', '--no-graph', '-T', 'change_id.shortest(8)'],
      { cwd: dir, encoding: 'utf8' }
    ).trim();

    execFileSync('jj', ['new', initialId, '-m', 'A'], { cwd: dir, stdio: 'ignore' });
    await writeFile(path.join(dir, 'f.txt'), 'A-version\n');
    const aId = execFileSync('jj', ['log', '-r', '@', '--no-graph', '-T', 'change_id.shortest(8)'], { cwd: dir, encoding: 'utf8' }).trim();

    execFileSync('jj', ['new', initialId, '-m', 'B'], { cwd: dir, stdio: 'ignore' });
    await writeFile(path.join(dir, 'f.txt'), 'B-version\n');
    const bId = execFileSync('jj', ['log', '-r', '@', '--no-graph', '-T', 'change_id.shortest(8)'], { cwd: dir, encoding: 'utf8' }).trim();

    execFileSync('jj', ['rebase', '-r', bId, '-d', aId], { cwd: dir, stdio: 'ignore' });
    execFileSync('jj', ['edit', bId], { cwd: dir, stdio: 'ignore' });

    const result = await getJjStatus(dir);
    assert.equal(result?.conflict, true);
  } finally {
    await rm(dir, { recursive: true, force: true });
  }
});
