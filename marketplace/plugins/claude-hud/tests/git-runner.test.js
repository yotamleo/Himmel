import { test } from 'node:test';
import assert from 'node:assert/strict';
import { EventEmitter } from 'node:events';
import { mkdtemp, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import path from 'node:path';
import { execFileSync } from 'node:child_process';
import {
  GIT_MAX_OUTPUT_BYTES,
  createGitEnvironment,
  createGitRunner,
  resolveTaskkillPath,
  resolveWindowsGitExecutable,
  terminateWindowsProcessTree,
} from '../dist/git-runner.js';
import { startWindowsGitWorker } from '../dist/windows-git-worker.js';

class FakeRuntime extends EventEmitter {
  argv = ['node', 'windows-git-worker.js', '/fixture/git'];
  connected = true;
  messages = [];
  disconnectCalls = 0;
  exitCalls = [];

  send(message) {
    this.messages.push(message);
    return true;
  }

  disconnect() {
    this.disconnectCalls++;
    this.connected = false;
    this.emit('disconnect');
  }

  exit(code) {
    this.exitCalls.push(code);
  }

  parentDisconnect() {
    this.connected = false;
    this.emit('disconnect');
  }
}

function createLongRunningChild() {
  const child = new EventEmitter();
  child.stdout = new EventEmitter();
  child.pid = 5151;
  child.exitCode = null;
  child.signalCode = null;
  child.killCalls = 0;
  child.kill = () => {
    child.killCalls++;
    return true;
  };
  return child;
}

const nextTurn = () => new Promise((resolve) => setImmediate(resolve));

test('Git subprocess environment disables prompts and optional locks', () => {
  const environment = createGitEnvironment({
    PATH: '/example/bin',
    GIT_OPTIONAL_LOCKS: '1',
    GIT_TERMINAL_PROMPT: '1',
    GCM_INTERACTIVE: 'Always',
  });

  assert.equal(environment.PATH, '/example/bin');
  assert.equal(environment.GIT_OPTIONAL_LOCKS, '0');
  assert.equal(environment.GIT_TERMINAL_PROMPT, '0');
  assert.equal(environment.GCM_INTERACTIVE, 'Never');
  assert.equal(GIT_MAX_OUTPUT_BYTES, 1024 * 1024);
});

test('taskkill path requires a drive-absolute SystemRoot', () => {
  assert.equal(
    resolveTaskkillPath({ SystemRoot: 'C:\\Windows' }),
    'C:\\Windows\\System32\\taskkill.exe',
  );
  assert.equal(resolveTaskkillPath({ SystemRoot: 'relative\\Windows' }), null);
  assert.equal(resolveTaskkillPath({ SystemRoot: '\\\\server\\share' }), null);
  assert.equal(resolveTaskkillPath({ SystemRoot: 'C:\\Windows\0elsewhere' }), null);
  assert.equal(resolveTaskkillPath({}), null);
});

test('Windows Git resolution ignores relative PATH entries and returns an absolute executable', () => {
  const candidates = [];
  const resolved = resolveWindowsGitExecutable(
    { Path: '.\\repo-bin;C:\\Program Files\\Git\\cmd;D:\\fallback' },
    (candidate) => {
      candidates.push(candidate);
      return candidate.startsWith('C:\\') ? candidate : null;
    },
  );

  assert.deepEqual(candidates, ['C:\\Program Files\\Git\\cmd\\git.exe']);
  assert.equal(resolved, 'C:\\Program Files\\Git\\cmd\\git.exe');
});

test('Windows tree termination targets only the owned child PID without a shell', async () => {
  const killer = new EventEmitter();
  killer.kill = () => true;
  let invocation;
  let fallbackKills = 0;
  const child = {
    pid: 4242,
    exitCode: null,
    signalCode: null,
    kill: () => {
      fallbackKills++;
      return true;
    },
  };

  const termination = terminateWindowsProcessTree(
    child,
    (file, args, options) => {
      invocation = { file, args, options };
      queueMicrotask(() => killer.emit('exit', 0, null));
      return killer;
    },
    { SystemRoot: 'C:\\Windows' },
  );

  await termination;
  assert.deepEqual(invocation, {
    file: 'C:\\Windows\\System32\\taskkill.exe',
    args: ['/PID', '4242', '/T', '/F'],
    options: { windowsHide: true, shell: false, stdio: 'ignore' },
  });
  assert.equal(fallbackKills, 0);
});

test('Windows tree termination falls back to the exact child when SystemRoot is unsafe', async () => {
  let spawnCalls = 0;
  let fallbackKills = 0;
  const child = {
    pid: 4242,
    exitCode: null,
    signalCode: null,
    kill: () => {
      fallbackKills++;
      return true;
    },
  };

  await terminateWindowsProcessTree(
    child,
    () => {
      spawnCalls++;
      throw new Error('must not run');
    },
    { SystemRoot: '.\\repo-controlled' },
  );

  assert.equal(spawnCalls, 0);
  assert.equal(fallbackKills, 1);
});

test('guardian disconnect terminates its active child tree and becomes idle', async () => {
  const runtime = new FakeRuntime();
  const child = createLongRunningChild();
  const descendant = { alive: true };
  const terminated = [];
  const controller = startWindowsGitWorker({
    runtime,
    spawnGit: () => child,
    terminateTree: async (ownedChild) => {
      terminated.push(ownedChild.pid);
      descendant.alive = false;
      queueMicrotask(() => ownedChild.emit('close', null, 'SIGTERM'));
    },
  });

  controller.handleMessage({
    type: 'run',
    id: 1,
    cwd: '/fixture/repo',
    args: ['rev-parse', '--abbrev-ref', 'HEAD'],
    timeout: 1000,
  });
  assert.deepEqual(controller.getState(), { active: true, starting: false, shuttingDown: false });

  runtime.parentDisconnect();
  await nextTurn();

  assert.deepEqual(terminated, [5151]);
  assert.equal(descendant.alive, false);
  assert.deepEqual(controller.getState(), { active: false, starting: false, shuttingDown: true });
  assert.deepEqual(runtime.exitCalls, []);
});

test('disconnect during spawn still registers and terminates the returned child tree', async () => {
  const runtime = new FakeRuntime();
  const child = createLongRunningChild();
  const descendant = { alive: true };
  const terminated = [];
  let controller;
  controller = startWindowsGitWorker({
    runtime,
    spawnGit: () => {
      controller.beginShutdown();
      return child;
    },
    terminateTree: async (ownedChild) => {
      terminated.push(ownedChild.pid);
      descendant.alive = false;
      queueMicrotask(() => ownedChild.emit('close', null, 'SIGTERM'));
    },
  });

  controller.handleMessage({
    type: 'run',
    id: 2,
    cwd: '/fixture/repo',
    args: ['status', '--porcelain'],
    timeout: 1000,
  });
  await nextTurn();

  assert.deepEqual(terminated, [5151]);
  assert.equal(descendant.alive, false);
  assert.equal(runtime.disconnectCalls, 1);
  assert.deepEqual(controller.getState(), { active: false, starting: false, shuttingDown: true });
  assert.deepEqual(runtime.exitCalls, []);
});

test('Windows Git runner reuses one guardian for sequential bounded commands', {
  skip: process.platform === 'win32' ? false : 'requires Windows git.exe resolution',
}, async () => {
  const dir = await mkdtemp(path.join(tmpdir(), 'claude-hud-git-runner-'));
  const runner = createGitRunner(dir, 'win32');
  try {
    execFileSync('git', ['init'], { cwd: dir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.email', 'test@test.com'], { cwd: dir, stdio: 'ignore' });
    execFileSync('git', ['config', 'user.name', 'Test'], { cwd: dir, stdio: 'ignore' });
    execFileSync('git', ['config', 'commit.gpgsign', 'false'], { cwd: dir, stdio: 'ignore' });
    execFileSync('git', ['commit', '--allow-empty', '-m', 'init'], { cwd: dir, stdio: 'ignore' });

    const branch = await runner.run(['rev-parse', '--abbrev-ref', 'HEAD'], 1000);
    const status = await runner.run(['--no-optional-locks', 'status', '--porcelain'], 1000);

    assert.match(branch.stdout.trim(), /^(main|master)$/);
    assert.equal(status.stdout, '');
  } finally {
    await runner.close();
    await rm(dir, { recursive: true, force: true });
  }
});
