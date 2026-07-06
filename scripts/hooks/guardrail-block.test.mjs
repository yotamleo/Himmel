import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';

const HERE = dirname(fileURLToPath(import.meta.url));
const MODULE = join(HERE, 'guardrail-block.mjs');
const NODE = process.execPath;
const BASH = process.platform === 'win32' ? 'C:/Program Files/Git/bin/bash.exe' : '/bin/bash';
const GUARDS = [
  ['auto-approve-safe-bash.sh', 'Bash'],
  ['block-edit-on-main.sh', 'Edit|Write|MultiEdit|NotebookEdit'],
  ['block-read-secrets.sh', 'Bash|PowerShell|Read|Grep'],
];

function work() {
  const dir = mkdtempSync(join(tmpdir(), 'gblock-'));
  const repo = join(dir, 'himmel');
  mkdirSync(join(repo, 'scripts', 'hooks'), { recursive: true });
  return { dir, repo, settings: join(dir, 'settings.json') };
}

function writeJson(file, data) {
  writeFileSync(file, `${JSON.stringify(data, null, 2)}\n`);
}

function readJson(file) {
  return JSON.parse(readFileSync(file, 'utf8'));
}

function run(args, ctx, opts = {}) {
  return execFileSync(process.execPath, [MODULE, ...args], {
    env: { ...process.env, CLAUDE_USER_SETTINGS: ctx.settings, HIMMEL_REPO: ctx.repo, ...opts.env },
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

function runCode(args, ctx) {
  try {
    const stdout = run(args, ctx);
    return { code: 0, stdout, stderr: '' };
  } catch (e) {
    return { code: e.status, stdout: e.stdout?.toString() ?? '', stderr: e.stderr?.toString() ?? '' };
  }
}

function backups(ctx) {
  const name = 'settings.json.';
  return readdirSync(ctx.dir).filter((entry) => entry.startsWith(name) && entry.includes('.bak'));
}

function preToolUse(data) {
  return data.hooks?.PreToolUse ?? [];
}

function hooks(data) {
  return preToolUse(data).flatMap((group) => group.hooks ?? []);
}

function wrappedHooks(data) {
  return hooks(data).filter((hook) => hook.command?.includes('guardrail-skip-in-himmel.js'));
}

function foreignHooks(data) {
  return hooks(data).filter((hook) => !hook.command?.includes('guardrail-skip-in-himmel.js'));
}

function install(ctx, stamp = '1000') {
  return run(['install', '--node', NODE, '--bash', BASH, '--stamp', stamp], ctx);
}

function assertThreeWrapped(data) {
  assert.equal(wrappedHooks(data).length, 3);
  for (const [basename, matcher] of GUARDS) {
    const group = preToolUse(data).find((candidate) => candidate.matcher === matcher && (candidate.hooks ?? []).some((hook) => hook.command?.includes(basename)));
    assert.ok(group, `missing matcher group for ${basename}`);
    const matches = wrappedHooks(data).filter((hook) => hook.command.includes(basename));
    assert.equal(matches.length, 1, `${basename} should appear exactly once`);
  }
}

function assertBakedPaths(data) {
  for (const hook of wrappedHooks(data)) {
    assert.ok(hook.command.includes(JSON.stringify(NODE)), 'node path baked into command');
    assert.ok(hook.command.includes(JSON.stringify(BASH)), 'bash path baked into command');
    assert.ok(hook.command.includes('guardrail-skip-in-himmel.js'), 'wrapper path baked into command');
  }
}

function realShapedFixture() {
  return {
    hooks: {
      PreToolUse: [
        { matcher: 'Bash', hooks: [{ type: 'command', command: 'bash scripts/hooks/rtk-hook-guard.sh' }] },
        { matcher: 'Bash', hooks: [{ type: 'command', command: 'node caveman-user-hook.js' }] },
        { matcher: 'Bash', hooks: [{ type: 'command', command: 'echo unrelated bash hook' }] },
      ],
      SessionEnd: [{ hooks: [{ type: 'command', command: 'echo end' }] }],
      SessionStart: [{ hooks: [{ type: 'command', command: 'echo start' }] }],
    },
  };
}

function staleFixture() {
  return {
    hooks: {
      PreToolUse: [
        {
          matcher: 'Bash',
          hooks: [
            { type: 'command', command: 'bash scripts/hooks/rtk-hook-guard.sh' },
            { type: 'command', command: 'GUARDRAIL_BASH="C:/old/bash.exe" "C:/Program Files/nodejs/node.exe" "C:/Users/example/.claude/hooks/guardrail-skip-in-himmel.js" "C:/Users/example/.claude/hooks/auto-approve-safe-bash.sh"' },
            { type: 'command', command: 'GUARDRAIL_BASH="C:/old/bash.exe" "C:/Program Files/nodejs/node.exe" "C:/Users/example/.claude/hooks/guardrail-skip-in-himmel.js" "C:/Users/example/.claude/hooks/auto-approve-safe-bash.sh"' },
          ],
        },
        {
          matcher: 'Edit|Write|MultiEdit|NotebookEdit',
          hooks: [{ type: 'command', command: 'GUARDRAIL_BASH="C:/old/bash.exe" "C:/Program Files/nodejs/node.exe" "C:/Users/example/.claude/hooks/guardrail-skip-in-himmel.js" "C:/Users/example/.claude/hooks/block-edit-on-main.sh"' }],
        },
        {
          matcher: 'Bash|PowerShell|Read|Grep',
          hooks: [{ type: 'command', command: 'GUARDRAIL_BASH="C:/old/bash.exe" "C:/Program Files/nodejs/node.exe" "C:/Users/example/.claude/hooks/guardrail-skip-in-himmel.js" "C:/Users/example/.claude/hooks/block-read-secrets.sh"' }],
        },
      ],
    },
  };
}

test('install into empty settings creates exactly three wrapped matcher entries', () => {
  const ctx = work();
  writeJson(ctx.settings, {});

  install(ctx);
  const data = readJson(ctx.settings);

  assertThreeWrapped(data);
  assertBakedPaths(data);
  assert.deepEqual(backups(ctx), ['settings.json.1000.bak']);
});

test('real-shaped fixture preserves foreign hooks and session hooks while adding three wrapped entries', () => {
  const ctx = work();
  writeJson(ctx.settings, realShapedFixture());

  install(ctx);
  const data = readJson(ctx.settings);

  assertThreeWrapped(data);
  assert.equal(foreignHooks(data).length, 3);
  assert.ok(foreignHooks(data).some((hook) => hook.command.includes('rtk-hook-guard.sh')));
  assert.ok(foreignHooks(data).some((hook) => hook.command.includes('caveman')));
  assert.equal(data.hooks.SessionEnd.length, 1);
  assert.equal(data.hooks.SessionStart.length, 1);
});

test('stale wrapped paths are rewritten in place without duplicates and foreign hooks remain', () => {
  const ctx = work();
  writeJson(ctx.settings, staleFixture());

  install(ctx);
  const text = readFileSync(ctx.settings, 'utf8');
  const data = JSON.parse(text);

  assertThreeWrapped(data);
  assertBakedPaths(data);
  assert.equal(foreignHooks(data).length, 1);
  assert.ok(foreignHooks(data)[0].command.includes('rtk-hook-guard.sh'));
  assert.equal(text.includes('C:/Users/example/.claude/hooks'), false);
  assert.equal(text.includes('C:/old/bash.exe'), false);
  assert.equal(text.includes('C:/Program Files/nodejs/node.exe'), false);
});

test('idempotent install with already-correct paths writes nothing and creates no backup', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  install(ctx, 'first');
  for (const backup of backups(ctx)) {
    // Leave the first backup in place to prove the second run does not add one.
    assert.ok(backup.includes('first'));
  }
  const before = readFileSync(ctx.settings, 'utf8');
  const mtimeBefore = statSync(ctx.settings).mtimeMs;

  const out = install(ctx, 'second');
  const after = readFileSync(ctx.settings, 'utf8');

  assert.match(out, /no changes/);
  assert.equal(after, before);
  assert.equal(statSync(ctx.settings).mtimeMs, mtimeBefore);
  assert.deepEqual(backups(ctx), ['settings.json.first.bak']);
  assertThreeWrapped(readJson(ctx.settings));
});

test('partial block with one wrapped hook is repaired to exactly three', () => {
  const ctx = work();
  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: [
        { matcher: 'Bash', hooks: [{ type: 'command', command: 'GUARDRAIL_BASH="/old/bash" "/old/node" "/old/guardrail-skip-in-himmel.js" "/old/auto-approve-safe-bash.sh"' }] },
      ],
    },
  });

  install(ctx);
  assertThreeWrapped(readJson(ctx.settings));
});

test('remove deletes wrapper hooks only, preserving foreign hooks and non-empty groups', () => {
  const ctx = work();
  writeJson(ctx.settings, staleFixture());
  install(ctx, 'install');

  run(['remove', '--stamp', 'remove'], ctx);
  const data = readJson(ctx.settings);

  assert.equal(wrappedHooks(data).length, 0);
  assert.equal(foreignHooks(data).length, 1);
  assert.ok(foreignHooks(data)[0].command.includes('rtk-hook-guard.sh'));
  assert.equal(preToolUse(data).length, 1, 'empty matcher groups are garbage-collected');
});

test('malformed input aborts without changing the original or creating backups', () => {
  const ctx = work();
  writeFileSync(ctx.settings, '{not json');

  const result = runCode(['install', '--node', NODE, '--bash', BASH, '--stamp', 'bad'], ctx);

  assert.notEqual(result.code, 0);
  assert.equal(readFileSync(ctx.settings, 'utf8'), '{not json');
  assert.deepEqual(backups(ctx), []);
});

test('detect reports project when absent and global when wrapped entries are present', () => {
  const ctx = work();
  writeJson(ctx.settings, realShapedFixture());

  assert.equal(run(['detect'], ctx), 'project\n');
  install(ctx);
  assert.equal(run(['detect'], ctx), 'global\n');
});

test('global and project aliases install and remove for setup-hooks', () => {
  const ctx = work();
  writeJson(ctx.settings, {});

  run(['global', '--node', NODE, '--bash', BASH, '--stamp', 'global'], ctx);
  assert.equal(run(['detect'], ctx), 'global\n');
  run(['project', '--stamp', 'project'], ctx);
  assert.equal(run(['detect'], ctx), 'project\n');
});
