import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import crypto from 'node:crypto';
import fs, { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, unlinkSync, rmSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import zlib from 'node:zlib';
import { install as installStatusData, statusDetail, sanitizedGitEnv, findPackOffset, readObject, applyDelta, readHeadOid } from './guardrail-block.mjs';

const HERE = dirname(fileURLToPath(import.meta.url));
const MODULE = join(HERE, 'guardrail-block.mjs');
const NODE = process.execPath;
// The full-install fixture needs a bash path the wrapper resolves as runnable
// (isRunnableExecutable: isFile + R_OK + X_OK). Hardcoding
// "C:/Program Files/Git/bin/bash.exe" assumes one Git layout — the real install
// resolves bash across install locations and PATH, so a machine with Git
// elsewhere (Program Files (x86), Scoop, or none at all) would read
// bashResolves=false and flip these tests red for no real reason. A temp
// executable stub is layout-independent and resolves identically everywhere
// (X_OK is a no-op on Windows; the chmod covers POSIX) — the direct analog of
// writeHookStubs() stubbing the wrapper/script files so their baked paths
// resolve. The deadBash negative test still uses its own nonexistent path.
function makeBashStub() {
  const dir = mkdtempSync(join(tmpdir(), 'gblock-bash-stub-'));
  const stub = join(dir, 'bash');
  writeFileSync(stub, '#!/bin/sh\nexit 0\n');
  chmodSync(stub, 0o755);
  return stub;
}
const BASH = makeBashStub();
process.on('exit', () => { try { rmSync(dirname(BASH), { recursive: true, force: true }); } catch { /* best-effort tmp cleanup */ } });
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

// HIMMEL-1422: every other helper in this file pins HIMMEL_REPO to ctx.repo
// (the fixture's own scratch checkout), so the anchor is always
// deterministic in those tests. This variant deliberately DROPS it (even
// if the outer test-runner process happens to have HIMMEL_REPO set) to
// exercise the self-checkout fallback — resolveAnchor() must fall back to
// the checkout this guardrail-block.mjs is itself running from.
function runNoAnchorEnv(args, ctx) {
  const env = { ...process.env, CLAUDE_USER_SETTINGS: ctx.settings };
  delete env.HIMMEL_REPO;
  return execFileSync(process.execPath, [MODULE, ...args], { env, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] });
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

// Creates stub files under <repo>/scripts/hooks/ so a baked wrapper/script
// path in a status --json fixture actually resolves (fs.existsSync) instead
// of pointing at a directory that was mkdir'd but never populated.
function writeHookStubs(ctx, { wrapper = true, basenames = GUARDS.map(([basename]) => basename) } = {}) {
  const hooksDir = join(ctx.repo, 'scripts', 'hooks');
  if (wrapper) writeFileSync(join(hooksDir, 'guardrail-skip-in-himmel.js'), '// stub\n');
  for (const basename of basenames) {
    writeFileSync(join(hooksDir, basename), '# stub\n');
  }
}

function writeRealHookCopies(ctx) {
  const hooksDir = join(ctx.repo, 'scripts', 'hooks');
  writeFileSync(join(hooksDir, 'guardrail-skip-in-himmel.js'), readFileSync(join(HERE, 'guardrail-skip-in-himmel.js')));
  for (const [basename] of GUARDS) {
    writeFileSync(join(hooksDir, basename), readFileSync(join(HERE, basename)));
  }
}

function writeLooseObject(gitDir, type, body) {
  const header = Buffer.from(`${type} ${body.length}\0`);
  const raw = Buffer.concat([header, Buffer.from(body)]);
  const oid = crypto.createHash('sha1').update(raw).digest('hex');
  const objectDir = join(gitDir, 'objects', oid.slice(0, 2));
  mkdirSync(objectDir, { recursive: true });
  writeFileSync(join(objectDir, oid.slice(2)), zlib.deflateSync(raw));
  return oid;
}

function treeBody(entries) {
  return Buffer.concat(entries.flatMap(({ mode, name, oid }) => [
    Buffer.from(`${mode} ${name}\0`),
    Buffer.from(oid, 'hex'),
  ]));
}

// Builds loose blob/tree/commit objects for a tree of scripts/hooks/<files>
// (name→body) under gitDir and returns the commit OID. Shared by the
// primary-checkout fixture (commitHookTree) and the linked-worktree fixture
// (commitHookTreeWorktree), whose objects live in the COMMON dir, so the
// tree-construction logic isn't duplicated.
function commitHookObjects(gitDir, contentsByName) {
  mkdirSync(join(gitDir, 'objects'), { recursive: true });
  const hooksEntries = Object.entries(contentsByName)
    .map(([name, body]) => ({ mode: '100644', name, oid: writeLooseObject(gitDir, 'blob', body) }))
    .sort((a, b) => a.name.localeCompare(b.name));
  const hooksTree = writeLooseObject(gitDir, 'tree', treeBody(hooksEntries));
  const scriptsTree = writeLooseObject(gitDir, 'tree', treeBody([{ mode: '040000', name: 'hooks', oid: hooksTree }]));
  const rootTree = writeLooseObject(gitDir, 'tree', treeBody([{ mode: '040000', name: 'scripts', oid: scriptsTree }]));
  const commit = Buffer.from(`tree ${rootTree}\n` +
    'author guardrail block test <guardrail-block-test@example.invalid> 0 +0000\n' +
    'committer guardrail block test <guardrail-block-test@example.invalid> 0 +0000\n' +
    '\nfixture\n');
  return writeLooseObject(gitDir, 'commit', commit);
}

// Builds a minimal commit (loose blob/tree/commit objects + HEAD) whose tree
// is exactly scripts/hooks/<files> with the given name→body contents, then
// writes its OID to <repo>/.git/HEAD. Shared by the real-checkout fixture
// (commitHookCopies, contents read from disk) and the round-2 GIT_DIR-poison
// decoy (divergent contents) so the tree-construction logic isn't duplicated.
function commitHookTree(repo, contentsByName) {
  const gitDir = join(repo, '.git');
  const commitOid = commitHookObjects(gitDir, contentsByName);
  writeFileSync(join(gitDir, 'HEAD'), `${commitOid}\n`);
}

function commitHookCopies(ctx) {
  const names = ['guardrail-skip-in-himmel.js', ...GUARDS.map(([basename]) => basename)];
  const contentsByName = Object.fromEntries(names.map((name) => [name, readFileSync(join(ctx.repo, 'scripts', 'hooks', name))]));
  commitHookTree(ctx.repo, contentsByName);
}

// Linked-worktree fixture (HIMMEL-1427 r4, codex-adv-3): objects/refs live in
// a COMMON dir; the worktree's own <repo>/.git is a gitdir-pointer FILE to a
// per-worktree gitdir that carries HEAD + a commondir pointer back to the
// common dir. Mirrors `git worktree add`'s on-disk layout, built BY HAND so
// the test does not depend on git for fixture creation. With the git
// subprocess forced off (withNoGitOnPath), the manual fallback must follow
// commondir to resolve refs/objects from the common dir, not the per-worktree
// gitdir (which carries none of them).
function commitHookTreeWorktree(repo, commonDir, contentsByName) {
  const gitDir = join(commonDir, '.git');
  const commitOid = commitHookObjects(gitDir, contentsByName);
  writeFileSync(join(gitDir, 'HEAD'), `${commitOid}\n`); // common (main-branch) HEAD
  const wtGitDir = join(gitDir, 'worktrees', 'wt');
  mkdirSync(wtGitDir, { recursive: true });
  writeFileSync(join(wtGitDir, 'HEAD'), `${commitOid}\n`); // detached at the same commit
  // commondir is relative to the per-worktree gitdir; ../.. resolves to gitDir
  // (the common dir) — exactly what git writes for a standard linked worktree.
  writeFileSync(join(wtGitDir, 'commondir'), '../..\n');
  writeFileSync(join(wtGitDir, 'gitdir'), `${join(repo, '.git')}\n`);
  // The worktree's .git is a FILE naming the per-worktree gitdir.
  writeFileSync(join(repo, '.git'), `gitdir: ${wtGitDir}\n`);
}
// Mirrors guardrail-block.mjs's own commandFor() so a fixture can hand-craft
// exactly one owned hook without going through install().
function ownedCommand({ ctx, basename, nodePath = NODE, bashPath = BASH }) {
  const wrapper = join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js');
  const script = join(ctx.repo, 'scripts', 'hooks', basename);
  return `GUARDRAIL_BASH=${JSON.stringify(bashPath)} ${JSON.stringify(nodePath)} ${JSON.stringify(wrapper)} ${JSON.stringify(script)}`;
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

// ── status --json (HIMMEL-1418) ─────────────────────────────────────────────

test('status --json after a full install reports complete=true with all three hooks present and resolving', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);

  install(ctx);
  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'global');
  assert.equal(out.complete, true);
  assert.equal(out.hooks.length, 3);
  GUARDS.forEach(([basename, matcher], i) => {
    const hook = out.hooks[i];
    assert.equal(hook.basename, basename, 'hooks[] stays in GUARDRAILS order');
    assert.equal(hook.matcher, matcher);
    assert.equal(hook.expectedMatcher, matcher);
    assert.equal(hook.matcherMatches, true);
    assert.equal(hook.present, true);
    assert.equal(hook.entryCount, 1);
    assert.deepEqual(hook.duplicates, []);
    assert.equal(hook.bashResolves, true);
    assert.equal(hook.nodeResolves, true);
    assert.equal(hook.wrapperResolves, true);
    assert.equal(hook.scriptResolves, true);
  });
});

// ── matcher + bash completeness (CR fix, codex-adv-1/2 on 68c0b82c) ────────

test('status --json reports the ACTUAL configured matcher, not the expected one, and complete=false on a matcher mismatch', () => {
  const ctx = work();
  writeHookStubs(ctx);
  // All 3 owned hooks wired under a single 'Bash' matcher group — exactly
  // the codex-adv-1 repro: paths all resolve, but block-edit-on-main.sh
  // (needs Edit|Write|MultiEdit|NotebookEdit) and block-read-secrets.sh
  // (needs Bash|PowerShell|Read|Grep) would never fire on their real tools.
  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: [
        {
          matcher: 'Bash',
          hooks: GUARDS.map(([basename]) => ({ type: 'command', command: ownedCommand({ ctx, basename }) })),
        },
      ],
    },
  });

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'global');
  assert.equal(out.complete, false, 'a coverage-breaking matcher must never read complete');
  const byBasename = Object.fromEntries(out.hooks.map((hook) => [hook.basename, hook]));
  // auto-approve-safe-bash.sh's OWN expected matcher genuinely IS 'Bash', so
  // this one hook matches by coincidence — proves the check isn't just
  // "matcher is falsy".
  assert.equal(byBasename['auto-approve-safe-bash.sh'].matcher, 'Bash');
  assert.equal(byBasename['auto-approve-safe-bash.sh'].expectedMatcher, 'Bash');
  assert.equal(byBasename['auto-approve-safe-bash.sh'].matcherMatches, true);
  assert.equal(byBasename['block-edit-on-main.sh'].matcher, 'Bash');
  assert.equal(byBasename['block-edit-on-main.sh'].expectedMatcher, 'Edit|Write|MultiEdit|NotebookEdit');
  assert.equal(byBasename['block-edit-on-main.sh'].matcherMatches, false);
  assert.equal(byBasename['block-read-secrets.sh'].matcher, 'Bash');
  assert.equal(byBasename['block-read-secrets.sh'].expectedMatcher, 'Bash|PowerShell|Read|Grep');
  assert.equal(byBasename['block-read-secrets.sh'].matcherMatches, false);
  // Paths all still resolve — proves the false complete is caused ONLY by
  // the matcher check, not incidental path breakage.
  for (const hook of out.hooks) {
    assert.equal(hook.present, true);
    assert.equal(hook.bashResolves, true);
    assert.equal(hook.nodeResolves, true);
    assert.equal(hook.wrapperResolves, true);
    assert.equal(hook.scriptResolves, true);
  }
});

test('status --json with a dead baked bash path reports bashResolves=false on every hook and complete=false', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  const deadBash = join(ctx.dir, 'nonexistent-bash.exe');

  run(['install', '--node', NODE, '--bash', deadBash, '--stamp', 'deadbash'], ctx);
  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'global');
  assert.equal(out.complete, false, 'a missing baked bash executable must never read complete (the wrapper fails closed on it)');
  for (const hook of out.hooks) {
    assert.equal(hook.present, true);
    // baked paths round-trip through settings.json with backslashes doubled
    // (JSON.stringify() bakes the command text once inside commandFor(),
    // then the whole settings object is serialized a second time) — collapse
    // before comparing, same as every other JSON-quoted arg in this file.
    assert.equal(hook.bashPath.replace(/\\\\/g, '\\'), deadBash);
    assert.equal(hook.bashResolves, false);
    // Node/wrapper/script are unaffected by the bash breakage — proves the
    // false complete is caused ONLY by the bash check.
    assert.equal(hook.nodeResolves, true);
    assert.equal(hook.wrapperResolves, true);
    assert.equal(hook.scriptResolves, true);
  }
});

// ── usability + duplicate-entry completeness (CR fix, codex-adv-3/4, round 3
// on 9112bfe9) ───────────────────────────────────────────────────────────

test('status --json with a DIRECTORY at the wrapper path reports wrapperResolves=false, not merely "exists" (complete=false)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);
  // fs.existsSync() alone accepts a directory — replace the wrapper file
  // with a directory of the SAME name to reproduce codex-adv-3 exactly.
  unlinkSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'));
  mkdirSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'));

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.complete, false, 'a directory must never be reported as a usable wrapper path');
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperResolves, false);
    // node/script are unaffected — proves the false complete is caused ONLY
    // by the directory-vs-file distinction, not incidental breakage.
    assert.equal(hook.nodeResolves, true);
    assert.equal(hook.scriptResolves, true);
  }
});

test('status --json with a DIRECTORY at the baked node path reports nodeResolves=false, not merely "exists" (complete=false)', () => {
  const ctx = work();
  writeHookStubs(ctx);
  const nodeDir = join(ctx.dir, 'node-is-actually-a-dir');
  mkdirSync(nodeDir);
  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: [
        { matcher: 'Bash', hooks: [{ type: 'command', command: ownedCommand({ ctx, basename: 'auto-approve-safe-bash.sh', nodePath: nodeDir }) }] },
      ],
    },
  });

  const out = JSON.parse(run(['status', '--json'], ctx));
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');

  assert.equal(out.complete, false);
  assert.equal(hook.nodeResolves, false, 'a directory must never be reported as a runnable node path');
});

// Windows' fs.accessSync(path, X_OK) has no real executable-bit concept and
// behaves like F_OK (existence only) — confirmed empirically and documented
// in the contract comment — so a non-executable-but-readable file is NOT
// distinguishable from a runnable one there. This case is only meaningful on
// POSIX; the directory tests above already cover the portable, load-bearing
// part of the codex-adv-3 fix (isFile()) on every platform.
test('status --json with a non-executable (but readable) baked node path reports nodeResolves=false', { skip: process.platform === 'win32' ? "X_OK is a no-op on Windows (see guardrail-block.mjs's status --json contract comment) — not meaningfully testable here" : false }, () => {
  const ctx = work();
  writeHookStubs(ctx);
  const nonExecNode = join(ctx.dir, 'non-exec-node');
  writeFileSync(nonExecNode, '#!/bin/sh\n');
  chmodSync(nonExecNode, 0o644); // readable, deliberately NOT executable
  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: [
        { matcher: 'Bash', hooks: [{ type: 'command', command: ownedCommand({ ctx, basename: 'auto-approve-safe-bash.sh', nodePath: nonExecNode }) }] },
      ],
    },
  });

  const out = JSON.parse(run(['status', '--json'], ctx));
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');

  assert.equal(out.complete, false);
  assert.equal(hook.nodeResolves, false, 'a non-executable file must never be reported as a runnable node path');
});

test('status --json with a valid entry PLUS a dead-node duplicate for the same hook reports entryCount=2, the duplicate in `duplicates`, and complete=false', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);

  // Add a SECOND owned entry for auto-approve-safe-bash.sh with a dead node
  // path, alongside the valid one install() already wrote — installData()'s
  // own dedup step ("remove EVERY existing owned hook for this guardrail")
  // exists precisely because this drift state occurs in practice; a probe
  // that only looks at the first match can't see the dead duplicate, even
  // though it is still independently wired and can fail closed at runtime.
  const data = readJson(ctx.settings);
  const deadNode = join(ctx.dir, 'nonexistent-node-duplicate');
  data.hooks.PreToolUse.push({
    matcher: 'Bash',
    hooks: [{ type: 'command', command: ownedCommand({ ctx, basename: 'auto-approve-safe-bash.sh', nodePath: deadNode }) }],
  });
  writeJson(ctx.settings, data);

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.complete, false, 'a duplicate owned entry must block complete even though the FIRST-FOUND one is fully valid');
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');
  assert.equal(hook.present, true);
  assert.equal(hook.entryCount, 2);
  // The primary (first-found = originally-installed) entry stays valid.
  assert.equal(hook.nodeResolves, true);
  assert.equal(hook.duplicates.length, 1);
  assert.equal(hook.duplicates[0].nodeResolves, false, 'the dead duplicate is surfaced in duplicates[], not silently dropped');
  // The other two guardrails are untouched (still exactly 1 entry each) —
  // proves the duplicate detection is per-basename, not a global flag.
  for (const other of ['block-edit-on-main.sh', 'block-read-secrets.sh']) {
    assert.equal(out.hooks.find((h) => h.basename === other).entryCount, 1);
  }
});

// ── decoy / identity ownership (CR fix, codex-adv-5, round 4 on 9d1b24a5) ──

test('status --json: real script arg is a decoy (claude-stub.sh) with each guardrail basename ONLY in a trailing comment — none are counted as owned (present=false, entryCount=0), complete=false', () => {
  const ctx = work();
  writeHookStubs(ctx);
  const wrapper = join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js');
  const decoyScript = join(ctx.repo, 'scripts', 'hooks', 'claude-stub.sh');
  writeFileSync(decoyScript, '#!/bin/sh\nexit 0\n');

  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: GUARDS.map(([basename, matcher]) => ({
        matcher,
        hooks: [{
          type: 'command',
          // The pre-fix isOwnedHook()/parseOwnedCommand() would have called
          // this "owned by <basename>, script=claude-stub.sh, resolves=true"
          // — the real (4th quoted) script arg is the decoy; the guardrail's
          // actual basename appears ONLY in a trailing shell comment that no
          // quoted-argument parse ever inspected. Exactly the reviewer's
          // reproduced scenario.
          command: `GUARDRAIL_BASH=${JSON.stringify(BASH)} ${JSON.stringify(NODE)} ${JSON.stringify(wrapper)} ${JSON.stringify(decoyScript)} # ${basename}`,
        }],
      })),
    },
  });

  const out = JSON.parse(run(['status', '--json'], ctx));

  // detectMode() (the plain, intentionally loose `status` line's engine)
  // still substring-matches WRAPPER and reads mode=global off the decoy —
  // that engine is unchanged/out of scope here. The point of this fix is
  // that the STRICT --json attestation must not be fooled by it: every
  // guardrail still correctly reads not-owned, so complete stays false.
  assert.equal(out.mode, 'global');
  assert.equal(out.complete, false, 'a decoy command must never read complete, even with a real guardrail basename in a trailing comment');
  for (const hook of out.hooks) {
    assert.equal(hook.present, false, `${hook.basename} must NOT be counted as owned by a decoy that merely mentions it in a comment — chosen semantic: not owned at all, reads identically to "never wired"`);
    assert.equal(hook.entryCount, 0);
    assert.deepEqual(hook.duplicates, []);
    assert.equal(hook.matcher, null);
    assert.equal(hook.nodePath, null, 'a non-owned hook reports no path data at all, not the decoy\'s paths');
    // codex-adv-7 regression guard: a comment-only mention must NOT be
    // picked up by the bounded quoted-argument identity test either — it's
    // a true decoy in BOTH tiers, not merely "non-canonical".
    assert.equal(hook.nonCanonicalCount, 0);
    assert.deepEqual(hook.nonCanonical, []);
  }
});

// ── non-canonical (same-identity, non-generated-shape) duplicates
// (CR fix, codex-adv-7, round 5 on 07a7ae10) ────────────────────────────────

test('status --json: canonical entry PLUS a same-identity duplicate with a TRAILING EXTRA ARGUMENT — reports nonCanonicalCount=1, forces complete=false (round-3 blind spot reopened via a different shape)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx); // the canonical, fully-valid entry for all 3 guardrails.

  // guardrail-skip-in-himmel.js reads only process.argv[2] — a trailing
  // extra token after the (correct) script arg is silently ignored at
  // runtime, so this duplicate is NOT a decoy: it references the REAL
  // wrapper/script identity, just in a non-canonical shape (GENERATED_
  // COMMAND_RE's `$` anchor rejects it, but Claude still executes it).
  // Give it a DEAD node path — exactly the "still fails closed on a
  // matching tool call" risk this fix exists to surface.
  const data = readJson(ctx.settings);
  const deadNode = join(ctx.dir, 'nonexistent-node-noncanonical');
  const wrapper = join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js');
  const script = join(ctx.repo, 'scripts', 'hooks', 'auto-approve-safe-bash.sh');
  data.hooks.PreToolUse.push({
    matcher: 'Bash',
    hooks: [{
      type: 'command',
      command: `GUARDRAIL_BASH=${JSON.stringify(BASH)} ${JSON.stringify(deadNode)} ${JSON.stringify(wrapper)} ${JSON.stringify(script)} "extra-trailing-arg"`,
    }],
  });
  writeJson(ctx.settings, data);

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.complete, false, 'a same-identity non-canonical duplicate must force complete=false, even though the canonical entry alone is fully valid');
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');
  // The canonical entry is untouched — still exactly 1, still fully valid.
  assert.equal(hook.present, true);
  assert.equal(hook.entryCount, 1);
  assert.equal(hook.nodeResolves, true);
  assert.deepEqual(hook.duplicates, []);
  // The non-canonical anomaly is surfaced, not silently dropped.
  assert.equal(hook.nonCanonicalCount, 1);
  assert.equal(hook.nonCanonical.length, 1);
  assert.equal(hook.nonCanonical[0].matcher, 'Bash');
  assert.ok(hook.nonCanonical[0].command.includes('extra-trailing-arg'));
  // The other two guardrails are untouched.
  for (const other of ['block-edit-on-main.sh', 'block-read-secrets.sh']) {
    const otherHook = out.hooks.find((h) => h.basename === other);
    assert.equal(otherHook.entryCount, 1);
    assert.equal(otherHook.nonCanonicalCount, 0);
  }
});

test('status --json with no owned hooks reports mode=project, complete=false, every hook absent', () => {
  const ctx = work();
  writeJson(ctx.settings, realShapedFixture());

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'project');
  assert.equal(out.complete, false);
  assert.equal(out.hooks.length, 3);
  for (const hook of out.hooks) {
    assert.equal(hook.present, false);
    assert.equal(hook.nodePath, null);
  }
});

test('status --json partial install (one of three hooks wired) reports complete=false with the missing hooks named', () => {
  const ctx = work();
  writeHookStubs(ctx);
  writeJson(ctx.settings, {
    hooks: {
      PreToolUse: [
        { matcher: 'Bash', hooks: [{ type: 'command', command: ownedCommand({ ctx, basename: 'auto-approve-safe-bash.sh' }) }] },
      ],
    },
  });

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'global');
  assert.equal(out.complete, false);
  const byBasename = Object.fromEntries(out.hooks.map((hook) => [hook.basename, hook]));
  assert.equal(byBasename['auto-approve-safe-bash.sh'].present, true);
  assert.equal(byBasename['auto-approve-safe-bash.sh'].nodeResolves, true);
  assert.equal(byBasename['auto-approve-safe-bash.sh'].wrapperResolves, true);
  assert.equal(byBasename['auto-approve-safe-bash.sh'].scriptResolves, true);
  assert.equal(byBasename['block-edit-on-main.sh'].present, false);
  assert.equal(byBasename['block-read-secrets.sh'].present, false);
});

test('status --json with a dead wrapper path reports wrapperResolves=false on every hook and complete=false', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);
  // Simulate a rotted wrapper path post-install (e.g. a moved/deleted himmel checkout).
  unlinkSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'));

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.mode, 'global');
  assert.equal(out.complete, false);
  for (const hook of out.hooks) {
    assert.equal(hook.present, true);
    assert.equal(hook.nodeResolves, true);
    assert.equal(hook.wrapperResolves, false);
    assert.equal(hook.scriptResolves, true);
  }
});

test('status --json with a dead script path on one hook reports that hook alone as unresolved', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);
  // Simulate one guardrail script disappearing while the other two stay intact.
  unlinkSync(join(ctx.repo, 'scripts', 'hooks', 'block-edit-on-main.sh'));

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.complete, false);
  const byBasename = Object.fromEntries(out.hooks.map((hook) => [hook.basename, hook]));
  assert.equal(byBasename['block-edit-on-main.sh'].scriptResolves, false);
  assert.equal(byBasename['auto-approve-safe-bash.sh'].scriptResolves, true);
  assert.equal(byBasename['block-read-secrets.sh'].scriptResolves, true);
});

test('plain status output is unchanged by the --json addition (himmel-update.sh parses this line)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);

  assert.equal(run(['status'], ctx), 'guardrail-mode=global node-resolves=yes\n');
});

// ── trust anchor (HIMMEL-1422) ──────────────────────────────────────────────
// Companion finding to codex-adv-5/7: ownsGuardrail() is deliberately
// basename-only (a settings.json referencing a same-named file passes
// ownership regardless of WHERE that file lives), so a stale/moved checkout
// — or an unrelated same-named no-op stub — previously still read
// present:true/*Resolves:true. These tests cover the two additive gates
// this ticket adds: (1) realpath-compare the configured wrapper/script
// against a resolved trust anchor (HIMMEL_REPO env, else self-checkout),
// and (2) a cheap content-sanity floor so a truncated/empty file at an
// otherwise-correct (even anchor-matching) path still can't read resolves.

test('status --json: with HIMMEL_REPO set, anchor.source is "HIMMEL_REPO" and anchor.repo is the resolved env value', () => {
  const ctx = work();
  writeJson(ctx.settings, {});

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.anchor.source, 'HIMMEL_REPO');
  assert.equal(out.anchor.repo, resolve(ctx.repo));
});

test('status --json: with HIMMEL_REPO unset, anchor falls back to self-checkout — the running guardrail-block.mjs\'s own two-levels-up repo root', () => {
  const ctx = work();
  writeJson(ctx.settings, {});

  const out = JSON.parse(runNoAnchorEnv(['status', '--json'], ctx));

  assert.equal(out.anchor.source, 'self-checkout');
  assert.equal(out.anchor.repo, resolve(HERE, '..', '..'));
});

test('status --json: an install() run reports wrapperMatchesAnchor/scriptMatchesAnchor=true on every hook (the anchor it baked from is the anchor status reads back)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);

  const out = JSON.parse(run(['status', '--json'], ctx));

  for (const hook of out.hooks) {
    assert.equal(hook.wrapperMatchesAnchor, true);
    assert.equal(hook.scriptMatchesAnchor, true);
    assert.equal(hook.anchorScriptPath, join(resolve(ctx.repo), 'scripts', 'hooks', hook.basename));
  }
});

test('status --json: same-basename wiring from a WRONG (non-anchor) checkout reports present=true but *MatchesAnchor=false, and forces complete=false (HIMMEL-1422 same-basename no-op)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);

  // Simulate a stale/global install pointing at a DIFFERENT, otherwise-real
  // checkout: same basenames (wrapper + auto-approve-safe-bash.sh), real
  // non-empty content, but under a directory that is NOT ctx.repo (the
  // pinned trust anchor).
  const otherRepo = join(ctx.dir, 'other-checkout');
  mkdirSync(join(otherRepo, 'scripts', 'hooks'), { recursive: true });
  writeFileSync(join(otherRepo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'), '// real content, not empty\n');
  writeFileSync(join(otherRepo, 'scripts', 'hooks', 'auto-approve-safe-bash.sh'), '# real content, not empty\n');

  const data = readJson(ctx.settings);
  for (const group of data.hooks.PreToolUse) {
    group.hooks = group.hooks.filter((hook) => !hook.command?.includes('auto-approve-safe-bash.sh'));
  }
  data.hooks.PreToolUse.push({
    matcher: 'Bash',
    hooks: [{ type: 'command', command: ownedCommand({ ctx: { repo: otherRepo }, basename: 'auto-approve-safe-bash.sh' }) }],
  });
  writeJson(ctx.settings, data);

  const out = JSON.parse(run(['status', '--json'], ctx));
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');

  assert.equal(hook.present, true, 'basename ownership is unchanged (codex-adv-5) — still counted as owned');
  assert.equal(hook.entryCount, 1);
  assert.equal(hook.wrapperResolves, true, 'the wrong-checkout wrapper is a real, non-empty, readable file');
  assert.equal(hook.scriptResolves, true, 'the wrong-checkout script is a real, non-empty, readable file');
  assert.equal(hook.wrapperMatchesAnchor, false, 'wrapper is NOT the anchor\'s own copy');
  assert.equal(hook.scriptMatchesAnchor, false, 'script is NOT the anchor\'s own copy');
  assert.equal(hook.anchorScriptPath, join(resolve(ctx.repo), 'scripts', 'hooks', 'auto-approve-safe-bash.sh'), 'anchorScriptPath names the TRUE anchor, not the wrong-checkout path');
  assert.equal(out.complete, false, 'a same-basename wrong-checkout script must never read complete');
  // The other two guardrails are untouched by this — still anchor-matching.
  for (const other of ['block-edit-on-main.sh', 'block-read-secrets.sh']) {
    const otherHook = out.hooks.find((h) => h.basename === other);
    assert.equal(otherHook.wrapperMatchesAnchor, true);
    assert.equal(otherHook.scriptMatchesAnchor, true);
  }
});

test('status --json: a ZERO-BYTE script file at the CORRECT (anchor-matching) path reports scriptResolves=false, not present-with-a-no-op (HIMMEL-1422 truncation floor)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);
  // Truncate in place — same path, same anchor, only the CONTENT changes.
  writeFileSync(join(ctx.repo, 'scripts', 'hooks', 'auto-approve-safe-bash.sh'), '');

  const out = JSON.parse(run(['status', '--json'], ctx));
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');

  assert.equal(hook.present, true);
  assert.equal(hook.scriptMatchesAnchor, true, 'the path IS the anchor\'s own copy — only the content is a no-op');
  assert.equal(hook.scriptResolves, false, 'a zero-byte file must never read as a resolving/usable script');
  assert.equal(out.complete, false);
});

test('status --json: a WHITESPACE-ONLY (near-empty) wrapper file at the correct path reports wrapperResolves=false (content-sanity floor is not just a size-zero check)', () => {
  const ctx = work();
  writeJson(ctx.settings, {});
  writeHookStubs(ctx);
  install(ctx);
  writeFileSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'), '   \n\n\t\n');

  const out = JSON.parse(run(['status', '--json'], ctx));

  assert.equal(out.complete, false);
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperMatchesAnchor, true, 'the shared wrapper path is still the anchor\'s own copy');
    assert.equal(hook.wrapperResolves, false, 'a whitespace-only file must never read as a resolving/usable wrapper');
  }
});

// -- attestation v2: audit anchor + content integrity (HIMMEL-1427) -----------

function withDeclaredRepo(repo, fn) {
  const old = process.env.HIMMEL_REPO;
  process.env.HIMMEL_REPO = repo;
  try {
    return fn();
  } finally {
    if (old === undefined) delete process.env.HIMMEL_REPO;
    else process.env.HIMMEL_REPO = old;
  }
}

// HIMMEL-1427 (CR round 2, finding 2): poisons process.env.GIT_DIR for the
// duration of fn so the in-process statusDetail()'s `git -C <repo> show`
// spawn would — WITHOUT the sanitizedGitEnv() fix — resolve the decoy repo
// instead of the explicit -C target. Restored unconditionally in finally.
function withPoisonedGitDir(gitDir, fn) {
  const old = process.env.GIT_DIR;
  process.env.GIT_DIR = gitDir;
  try {
    return fn();
  } finally {
    if (old === undefined) delete process.env.GIT_DIR;
    else process.env.GIT_DIR = old;
  }
}

// The GIT_DIR-poison regression only bites when the `git` spawn in the
// integrity path actually RUNS — if git is not on PATH, readHeadBlob() falls
// back to the GIT_DIR-independent manual loose-object reader (which reads
// readGitDir(repo) = the -C target directly) and would mask the bug, making
// the test pass trivially without exercising the fix. Skip in that case.
function gitAvailable() {
  try {
    execFileSync('git', ['--version'], { stdio: ['ignore', 'pipe', 'ignore'], encoding: 'utf8' });
    return true;
  } catch (_e) {
    return false;
  }
}

function installedData(ctx) {
  return installStatusData({}, { nodePath: NODE, bashPath: BASH, himmelRepo: ctx.repo });
}

// Forces readHeadBlob()'s git subprocess to fail (ENOENT — git not found) so
// the manual fallback runs. This is the suite's existing "git not on PATH"
// path (see gitAvailable()'s comment): clearing PATH reproduces it on any
// machine, including one where git IS installed, so the fallback path is
// exercised deterministically. Scoped to fn; PATH/PATHEXT restored in finally.
function withNoGitOnPath(fn) {
  const oldPath = process.env.PATH;
  const oldPathExt = process.env.PATHEXT;
  process.env.PATH = '';
  if (Object.prototype.hasOwnProperty.call(process.env, 'PATHEXT')) delete process.env.PATHEXT;
  try {
    return fn();
  } finally {
    process.env.PATH = oldPath;
    if (oldPathExt !== undefined) process.env.PATHEXT = oldPathExt;
  }
}

// Runs a git command inside <repo> with a fixed test identity (a real `git
// commit` refuses without user.name/email). Only used to BUILD fixtures; the
// integrity assertion itself forces git off via withNoGitOnPath.
function gitCmd(repo, args) {
  return execFileSync('git', ['-c', 'user.name=guardrail-block-test', '-c', 'user.email=guardrail-block-test@example.invalid', ...args], {
    cwd: repo,
    encoding: 'utf8',
    stdio: ['ignore', 'pipe', 'pipe'],
  });
}

// Builds a REAL git repo at <repo> whose HEAD tree is scripts/hooks/<files>
// (the on-disk copies writeRealHookCopies wrote), then repacks so the blobs
// exist ONLY in objects/pack/*.pack with no loose copies — exercises the
// fallback's packed-object reader (incl. delta resolution) when git is forced
// off. Requires git (callers gate on gitAvailable()).
function buildPackedRepo(repo) {
  gitCmd(repo, ['init', '-q']);
  gitCmd(repo, ['add', 'scripts/hooks']);
  gitCmd(repo, ['commit', '-q', '-m', 'fixture']);
  gitCmd(repo, ['repack', '-q', '-a', '-d']);
  gitCmd(repo, ['prune-packed']);
}

test('status --json: module checkout and declared HIMMEL_REPO divergence is surfaced while preserving declared-anchor verdicts', () => {
  const ctx = work();
  writeHookStubs(ctx);
  const data = installedData(ctx);

  const out = withDeclaredRepo(ctx.repo, () => statusDetail(data));

  assert.equal(out.anchor.source, 'HIMMEL_REPO');
  assert.equal(out.anchor.repo, resolve(ctx.repo));
  assert.equal(out.auditAnchor.source, 'self-checkout');
  assert.equal(out.auditAnchor.repo, resolve(HERE, '..', '..'));
  assert.equal(out.anchorMatchesAudit, false, 'declared HIMMEL_REPO and executing module checkout must be compared independently');
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperMatchesAnchor, true, 'v1 declared-anchor verdict is preserved');
    assert.equal(hook.scriptMatchesAnchor, true, 'v1 declared-anchor verdict is preserved');
    assert.equal(hook.wrapperMatchesAuditAnchor, false, 'audit anchor sees the stale declared checkout');
    assert.equal(hook.scriptMatchesAuditAnchor, false, 'audit anchor sees the stale declared checkout');
    assert.equal(hook.wrapperIntegrity.verdict, 'degraded');
    assert.equal(hook.wrapperIntegrity.reason, 'reference-unavailable');
  }
});

test('statusDetail accepts an explicit repoRoot audit anchor', () => {
  const ctx = work();
  writeHookStubs(ctx);
  const data = {
    hooks: {
      PreToolUse: GUARDS.map(([basename, matcher]) => ({
        matcher,
        hooks: [{ type: 'command', command: ownedCommand({ ctx, basename }) }],
      })),
    },
  };

  const out = withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo }));

  assert.equal(out.auditAnchor.source, 'ctx.repoRoot');
  assert.equal(out.auditAnchor.repo, resolve(ctx.repo));
  assert.equal(out.anchorMatchesAudit, true);
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperMatchesAuditAnchor, true);
    assert.equal(hook.scriptMatchesAuditAnchor, true);
  }
});

test('status --json: genuine checked-in wrapper and scripts report healthy content integrity', () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  commitHookCopies(ctx);
  const data = installedData(ctx);

  const out = withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo }));

  assert.equal(out.contentIntegrityComplete, true);
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperIntegrity.verdict, 'healthy');
    assert.equal(hook.wrapperIntegrity.reason, 'matches-git-object');
    assert.equal(hook.scriptIntegrity.verdict, 'healthy');
    assert.equal(hook.scriptIntegrity.reason, 'matches-git-object');
  }
});

test('status --json: comment-only file at the correct anchor path reports degraded content integrity', () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  commitHookCopies(ctx);
  const data = installedData(ctx);
  writeFileSync(join(ctx.repo, 'scripts', 'hooks', 'auto-approve-safe-bash.sh'), '# comment only\n');

  const out = withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo }));
  const hook = out.hooks.find((h) => h.basename === 'auto-approve-safe-bash.sh');

  assert.equal(hook.scriptMatchesAnchor, true);
  assert.equal(hook.scriptResolves, true, 'v1 non-whitespace floor still reads as resolving');
  assert.equal(hook.scriptIntegrity.verdict, 'degraded');
  assert.equal(hook.scriptIntegrity.reason, 'content-mismatch');
  assert.equal(out.contentIntegrityComplete, false);
});

test('status --json: syntactically-valid no-op wrapper at the correct anchor path reports degraded content integrity', () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  commitHookCopies(ctx);
  const data = installedData(ctx);
  writeFileSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'), '#!/usr/bin/env node\nprocess.exit(0);\n');

  const out = withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo }));

  assert.equal(out.contentIntegrityComplete, false);
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperMatchesAnchor, true);
    assert.equal(hook.wrapperResolves, true, 'v1 non-whitespace floor still reads as resolving');
    assert.equal(hook.wrapperIntegrity.verdict, 'degraded');
    assert.equal(hook.wrapperIntegrity.reason, 'content-mismatch');
  }
});

// -- git env sanitization (HIMMEL-1427 CR round 2, finding 2) ----------------

test('status --json: content integrity ignores a poisoned GIT_DIR pointing at a different repo (CR round 2, finding 2)', {
  skip: gitAvailable() ? false : 'poisoned GIT_DIR only redirects when the git spawn actually runs; git is not on PATH (the manual loose-object fallback is GIT_DIR-independent and would mask the bug)',
}, () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  commitHookCopies(ctx); // ctx.repo HEAD carries the REAL wrapper/script blobs

  // A second repo (the decoy) whose HEAD carries a DIVERGENT wrapper blob but
  // the real script blobs. With an INHERITED GIT_DIR, `git -C ctx.repo show
  // HEAD:...wrapper` resolves the DECOY's HEAD instead of ctx.repo's
  // (reproduced: GIT_DIR overrides repository discovery even with an explicit
  // -C), yielding the decoy blob → a false content-mismatch on the wrapper.
  // sanitizedGitEnv() must delete GIT_DIR so the explicit -C ctx.repo wins.
  const decoy = join(ctx.dir, 'decoy');
  const realWrapper = readFileSync(join(ctx.repo, 'scripts', 'hooks', 'guardrail-skip-in-himmel.js'));
  const decoyContents = {
    'guardrail-skip-in-himmel.js': Buffer.concat([realWrapper, Buffer.from('\n// DECOY TAMPER MARKER\n')]),
  };
  // Give the decoy the real script blobs so only the WRAPPER diverges —
  // isolates the GIT_DIR redirect to the wrapper signal (scripts would match
  // either repo and thus can't witness the redirect on their own).
  for (const [basename] of GUARDS) {
    decoyContents[basename] = readFileSync(join(ctx.repo, 'scripts', 'hooks', basename));
  }
  commitHookTree(decoy, decoyContents);

  const data = installedData(ctx);
  const out = withPoisonedGitDir(join(decoy, '.git'), () => withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo })));

  // Without the fix, GIT_DIR=decoy would make `git -C ctx.repo show` return
  // the DECOY wrapper blob, hashing differently than the real on-disk wrapper
  // → wrapperIntegrity 'degraded' / 'content-mismatch'. With sanitizedGitEnv()
  // the spawn reads ctx.repo and the reference matches the disk file.
  assert.equal(out.contentIntegrityComplete, true, 'a poisoned GIT_DIR must not redirect the integrity reference away from -C ctx.repo');
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperIntegrity.verdict, 'healthy');
    assert.equal(hook.wrapperIntegrity.reason, 'matches-git-object');
  }
});

// -- git env sanitization is CASE-INSENSITIVE (HIMMEL-1427 r4, codex-adv-2) ----
// Windows env-var names are case-insensitive for the spawned git child while
// JS preserves spelling, so a case-sensitive startsWith('GIT_') filter let
// mixed-case `git_dir` / `Git_Dir` through — and git honored them, redirecting
// the integrity reference. sanitizedGitEnv() now normalizes case-insensitively
// on BOTH the prefix filter and the GIT_TERMINAL_PROMPT exception. Tested
// directly (git-subprocess-independent) by swapping process.env for a plain
// object with exact-case keys — the real env is untouched.

test('sanitizedGitEnv removes GIT_* overrides in every spelling and preserves GIT_TERMINAL_PROMPT in any spelling (HIMMEL-1427 r4, codex-adv-2)', () => {
  const orig = process.env;
  process.env = {
    PATH: '/usr/bin',
    GIT_DIR: '/poison/upper',
    git_dir: '/poison/lower',
    Git_Dir: '/poison/mixed',
    GIT_OBJECT_DIRECTORY: '/poison/obj',
    GIT_TERMINAL_PROMPT: '0', // the one benign exception, canonical spelling
    git_terminal_prompt: '1', // same exception, case variant — must ALSO survive
    KEEP: 'untouched',
  };
  let sanitized;
  try {
    sanitized = sanitizedGitEnv();
  } finally {
    process.env = orig;
  }

  // Repository/object override vars removed in EVERY spelling.
  assert.equal(sanitized.GIT_DIR, undefined);
  assert.equal(sanitized.git_dir, undefined, 'lowercase git_dir must be stripped (case-insensitive prefix)');
  assert.equal(sanitized.Git_Dir, undefined, 'mixed-case Git_Dir must be stripped (case-insensitive prefix)');
  assert.equal(sanitized.GIT_OBJECT_DIRECTORY, undefined);
  // The benign UI-hint exception survives in BOTH spellings — the exception
  // compare is case-insensitive too.
  assert.equal(sanitized.GIT_TERMINAL_PROMPT, '0');
  assert.equal(sanitized.git_terminal_prompt, '1', 'a case-variant git_terminal_prompt survives as the exception');
  // Non-GIT vars are untouched.
  assert.equal(sanitized.KEEP, 'untouched');
  assert.equal(sanitized.PATH, '/usr/bin');
});

// -- linked-worktree + packed-object fallback (HIMMEL-1427 r4, codex-adv-3) ----
// readHeadBlob()'s manual fallback resolved refs/objects from readGitDir()'s
// gitdir — but for a LINKED WORKTREE that is the per-worktree gitdir, which
// carries none of them (they live in the COMMON dir), and it only read LOOSE
// objects (so a `git gc`'d repo read degraded). These exercise the commondir
// resolution and the packed-object reader, both with the git subprocess forced
// off (withNoGitOnPath) so the fallback — not `git show` — does the work.

test('status --json: a linked-worktree fixture resolves refs/objects from the common dir when git is forced off (HIMMEL-1427 r4, codex-adv-3)', () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  const names = ['guardrail-skip-in-himmel.js', ...GUARDS.map(([basename]) => basename)];
  const contentsByName = Object.fromEntries(names.map((name) => [name, readFileSync(join(ctx.repo, 'scripts', 'hooks', name))]));
  const commonDir = join(ctx.dir, 'common-checkout');
  commitHookTreeWorktree(ctx.repo, commonDir, contentsByName);

  const data = installedData(ctx);
  const out = withNoGitOnPath(() => withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo })));

  assert.equal(out.contentIntegrityComplete, true, 'a linked worktree must resolve refs/objects from the common dir via commondir, not the per-worktree gitdir');
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperIntegrity.verdict, 'healthy');
    assert.equal(hook.wrapperIntegrity.reason, 'matches-git-object');
    assert.equal(hook.scriptIntegrity.verdict, 'healthy');
    assert.equal(hook.scriptIntegrity.reason, 'matches-git-object');
  }
});

test('status --json: a packed-object fixture (no loose objects) resolves via the pack reader when git is forced off (HIMMEL-1427 r4, codex-adv-3)', {
  skip: gitAvailable() ? false : 'building the packed fixture needs git (init/commit/repack)',
}, () => {
  const ctx = work();
  writeRealHookCopies(ctx);
  buildPackedRepo(ctx.repo);
  // Sanity: the target objects are PACKED, not loose — otherwise this would
  // pass via the loose reader and not exercise the pack path at all.
  const looseDirs = readdirSync(join(ctx.repo, '.git', 'objects')).filter((e) => e !== 'pack' && e !== 'info');
  assert.equal(looseDirs.length, 0, 'fixture must have no loose object dirs (repack -ad + prune-packed)');

  const data = installedData(ctx);
  const out = withNoGitOnPath(() => withDeclaredRepo(ctx.repo, () => statusDetail(data, { repoRoot: ctx.repo })));

  assert.equal(out.contentIntegrityComplete, true, 'packed blobs must resolve through the pack reader (incl. deltas) when git is unavailable');
  for (const hook of out.hooks) {
    assert.equal(hook.wrapperIntegrity.verdict, 'healthy');
    assert.equal(hook.wrapperIntegrity.reason, 'matches-git-object');
    assert.equal(hook.scriptIntegrity.verdict, 'healthy');
    assert.equal(hook.scriptIntegrity.reason, 'matches-git-object');
  }
});

// -- malformed pack idx is skipped, never thrown (HIMMEL-1427 r7, codex-adv-2) ----
// findPackOffset trusted the v2 fanout/total and passed derived ranges to
// Buffer.compare/readUint32BE unchecked; a truncated or crafted idx threw
// ERR_OUT_OF_RANGE OUTSIDE any catch, crashing status --json instead of
// returning reference-unavailable. Now every derived range is bounds-checked
// against idx.length and the fanout window against total, so a malformed idx
// returns null (honest "absent"). Tested directly — findPackOffset is a pure
// (idx, oidHex) function.

const IDX_MAGIC = Buffer.from([0xff, 0x74, 0x4f, 0x63]); // "\377tOc"

// Builds a v2 idx buffer: header(8) + fanout(256*4) + per-entry oid(20)/
// crc(4)/offset(4). `fanout` overrides default cumulative counts (default: the
// advertised `total` in every cell) to craft monotonicity violations;
// `truncateAt` drops the tail to craft a truncated idx whose tables don't fit.
function buildIdx(entries, { total = entries.length, fanout = {}, truncateAt } = {}) {
  const parts = [IDX_MAGIC];
  const ver = Buffer.alloc(4); ver.writeUInt32BE(2, 0); parts.push(ver);
  const fan = Buffer.alloc(256 * 4);
  for (let i = 0; i < 256; i++) fan.writeUInt32BE(fanout[i] !== undefined ? fanout[i] : total, i * 4);
  parts.push(fan);
  for (const e of entries) parts.push(Buffer.from(e.oid, 'hex'));
  for (const e of entries) parts.push(Buffer.alloc(4)); // crc (unchecked by the reader)
  for (const e of entries) { const o = Buffer.alloc(4); o.writeUInt32BE(e.off, 0); parts.push(o); }
  let buf = Buffer.concat(parts);
  if (truncateAt !== undefined) buf = buf.subarray(0, truncateAt);
  return buf;
}

test('findPackOffset: a truncated idx (tables shorter than the advertised total) returns null without throwing (HIMMEL-1427 r7)', () => {
  // 1032-byte idx (header+fanout only) but fanout[255]=5 → table span
  // 1032 + 5*28 = 1172 > 1032. Pre-fix, Buffer.compare hit an out-of-range
  // offset and threw ERR_OUT_OF_RANGE, crashing status --json.
  const idx = buildIdx([], { total: 5, truncateAt: 1032 });
  assert.equal(idx.length, 1032);
  assert.equal(findPackOffset(idx, '0123456789abcdef0123456789abcdef01234567'), null);
});

test('findPackOffset: an absurd fanout total (0xffffffff) returns null without throwing (HIMMEL-1427 r7)', () => {
  const idx = buildIdx([], { total: 0xffffffff, truncateAt: 1032 });
  assert.equal(findPackOffset(idx, '0123456789abcdef0123456789abcdef01234567'), null);
});

test('findPackOffset: a non-monotonic fanout window (hi > total) returns null without throwing (HIMMEL-1427 r7)', () => {
  // One real entry whose tables fit (total=1), but fanout[0]=2 → the searched
  // bucket window hi(2) exceeds total(1): a crafted out-of-range search window.
  const oid00 = '003456789abcdef0123456789abcdef012345678'; // leading 0x00 → bucket 0
  const idx = buildIdx([{ oid: oid00, off: 12 }], { total: 1, fanout: { 0: 2 } });
  assert.equal(findPackOffset(idx, oid00), null);
});

// -- REF_DELTA cycle degrades at once, without per-level pack re-reads --------
// (HIMMEL-1427 r7, codex-adv-2) A REF_DELTA can name a base that resolves back
// to itself; the depth cap stopped the recursion at MAX_DELTA_DEPTH but only
// after re-readFileSync'ing the whole pack once per level (earlier frames still
// held their buffers). readObject now tracks visited OIDs per lookup and rejects
// a repeat immediately, and threads a per-lookup pack cache so each pack file is
// read at most once. The fixture crafts a pack whose single object is a
// REF_DELTA onto its OWN oid — a direct self-cycle git would never emit.

function buildCycleRepo() {
  const dir = mkdtempSync(join(tmpdir(), 'gblock-cycle-'));
  const commonDir = join(dir, 'git');
  const packDir = join(commonDir, 'objects', 'pack');
  mkdirSync(packDir, { recursive: true });

  const oid = '0123456789abcdef0123456789abcdef01234567'; // firstByte 0x01
  const oidBytes = Buffer.from(oid, 'hex');

  // Pack entry at offset 12 (right after the 12-byte PACK header): a REF_DELTA
  // (type 7) whose result size is 1, followed by the 20-byte base oid (= oid,
  // self-cycle), then a zlib-compressed minimal delta. The delta is never
  // applied — the cycle check fires first — but it must decompress so the reader
  // reaches the recursive readObject rather than bailing on inflate.
  const delta = zlib.deflateSync(Buffer.from([0x01, 0x01, 0x01, 0x41])); // baseSize1 targetSize1 insert 'A'
  const entry = Buffer.concat([Buffer.from([0x71]), oidBytes, delta]); // 0x71 = (7<<4)|1
  const header = Buffer.alloc(12);
  header.write('PACK', 0, 'ascii');
  header.writeUInt32BE(2, 4); // version 2
  header.writeUInt32BE(1, 8); // 1 object
  const pack = Buffer.concat([header, entry]);

  // Matching v2 idx: one entry (oid → offset 12). bucket 0 is empty, buckets
  // 1..255 each hold the cumulative 1.
  const idx = buildIdx([{ oid, off: 12 }], { total: 1, fanout: { 0: 0 } });

  writeFileSync(join(packDir, 'pack-cycle.idx'), idx);
  writeFileSync(join(packDir, 'pack-cycle.pack'), pack);
  return { dir, commonDir, oid };
}

test('readObject: a REF_DELTA self-cycle degrades after a single pack read, not one per delta level (HIMMEL-1427 r7)', () => {
  const { dir, commonDir, oid } = buildCycleRepo();
  process.on('exit', () => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort tmp cleanup */ } });

  // Spy on fs.readFileSync to count .pack reads across this lookup. The module
  // under test does `import fs from 'node:fs'` and calls fs.readFileSync at call
  // time, so reassigning the property on the shared namespace lands.
  const realReadFileSync = fs.readFileSync;
  let packReads = 0;
  fs.readFileSync = function readFileSyncSpy(p, ...args) {
    if (typeof p === 'string' && p.endsWith('.pack')) packReads += 1;
    return realReadFileSync.call(this, p, ...args);
  };
  let result;
  try {
    result = readObject(commonDir, oid);
  } finally {
    fs.readFileSync = realReadFileSync;
  }

  assert.equal(result, null, 'a REF_DELTA self-cycle must degrade to reference-unavailable');
  assert.equal(packReads, 1, 'the pack must be read once for the whole lookup, not re-read per delta level (pre-fix: ~MAX_DELTA_DEPTH reads)');
});

// -- applyDelta offset/varint hardening (HIMMEL-1427 r8) ----------------------
// Two panel-sug findings on the delta op-stream reader, tested directly:
//   (1) the copy offset's 4th byte was shifted with `<< 24`, which yields a
//       SIGNED Int32 — a byte >= 0x80 made cpOff negative, corrupting copy
//       offsets on >2GB base objects (read from the wrong place instead of
//       degrading). Now assembled unsigned (multiply + `+`, matching
//       readUint32BE).
//   (2) the header varints / copy bytes / insert payloads were read without
//       bounds checks, so a TRUNCATED delta silently produced a short/empty
//       result instead of degrading as malformed. Now every read past the
//       delta buffer returns null (fail-closed to 'degraded').
// applyDelta is a pure (base, delta) function — the cases below operate on
// small synthetic buffers and assert the computed behavior, not a real 2GB read.

test('applyDelta: a copy offset whose 4th byte is >= 0x80 is computed UNSIGNED (HIMMEL-1427 r8)', () => {
  // baseSize varint(256) = [0x80,0x02] MATCHES base.length so r9's declared-base
  // check passes and the copy path is reached. Then copy op 0x8F (bit7 copy +
  // all four offset bytes) | 0xFF 0xFF 0xFF 0xFF = offset 0xFFFFFFFF. As a
  // SIGNED Int32 (the pre-fix `<< 24` path) that is -1, which read from the END
  // of a small base. UNSIGNED assembly yields 0xFFFFFFFF, far past the base →
  // r9's range check degrades (null). (This exact case is null under both
  // signed and unsigned assembly: r9's cpOff<0 guard catches the signed -1
  // directly, and the unsigned offset is caught by the range check. So the
  // unsigned rewrite is NOT discriminated from the signed one by any positive
  // test here — an in-range offset whose 4th byte is >= 0x80 would need a
  // >=2GiB base, which the small synthetic buffers above rule out by design
  // — so the unsigned-assembly path is covered by this degrade case plus code
  // review, not by a discriminating positive test.)
  const base = Buffer.alloc(256);
  for (let i = 0; i < 256; i += 1) base[i] = i;
  const delta = Buffer.from([0x80, 0x02, 0x01, 0x8F, 0xFF, 0xFF, 0xFF, 0xFF]);
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: a valid small copy still resolves (unsigned assembly does not break normal offsets) (HIMMEL-1427 r8)', () => {
  // baseSize(4) | targetSize(2) | copy op 0x90 (copy with size-byte-0 only) |
  // size byte 0x02 → cpOff 0, cpSize 2 → base[0..2]. Guards against the
  // unsigned rewrite regressing the ordinary in-range copy path.
  const base = Buffer.from([0x41, 0x42, 0x43, 0x44]);
  const delta = Buffer.from([0x04, 0x02, 0x90, 0x02]);
  assert.deepEqual(applyDelta(base, delta), Buffer.from([0x41, 0x42]));
});

test('applyDelta: a truncated header varint degrades instead of a silent empty result (HIMMEL-1427 r8)', () => {
  // [0x80] — a base-size varint byte with the continuation bit set and nothing
  // after it. Pre-fix the reader walked off the end (`undefined & 0x80` =
  // NaN/falsy), fell through both headers to targetSize 0, and returned an
  // EMPTY buffer (0 === 0) as if the delta were a well-formed zero-length
  // object. Now it degrades to null at either header varint.
  const base = Buffer.alloc(0);
  assert.equal(applyDelta(base, Buffer.from([0x80])), null); // truncated base-size varint
  assert.equal(applyDelta(base, Buffer.from([0x00, 0x80])), null); // truncated target-size varint (baseSize 0 matches the empty base)
});

test('applyDelta: a truncated copy command degrades instead of a silent short result (HIMMEL-1427 r8)', () => {
  // baseSize(2) | targetSize(2) | copy op 0x88 (copy with the 4th offset byte
  // selected) but no byte follows. Pre-fix the missing byte read as undefined
  // (cpOff |= 0), the copy defaulted to base[0..2], and length 2 === targetSize
  // returned base as a silently-accepted result. Now the bounds check degrades
  // to null. (baseSize matches base.length so r9's declared-base check passes
  // and this reaches the copy command.)
  const base = Buffer.from([0xAA, 0xBB]);
  const delta = Buffer.from([0x02, 0x02, 0x88]);
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: an insert payload running past the delta end degrades instead of a silent short result (HIMMEL-1427 r8)', () => {
  // baseSize(0) | targetSize(2) | insert op 0x03 (insert 3 bytes) but only 2
  // bytes follow. Pre-fix Buffer.subarray clamped the read to the 2 available
  // bytes, p still advanced by 3, and length 2 === targetSize returned those 2
  // bytes as a silently-accepted result. Now the bounds check degrades to null.
  // (baseSize matches base.length so r9's declared-base check passes and this
  // reaches the insert op.)
  const base = Buffer.alloc(0);
  const delta = Buffer.from([0x00, 0x02, 0x03, 0x41, 0x42]);
  assert.equal(applyDelta(base, delta), null);
});

// -- applyDelta copy-range / declared-base-size validation (HIMMEL-1427 r9) ----
// A codex-adv finding (premise verified): applyDelta accepted OUT-OF-RANGE copy
// commands because Buffer.subarray CLAMPS an overrun instead of throwing, and
// only the resulting TOTAL length was checked. A copy past the base end could
// be silently truncated to a length that still matched targetSize → a false
// healthy verdict on malformed pack data (which can become the trusted
// attestation reference when `git show` fails). r9 also validates the DECLARED
// base size from the delta header against the actual base (it was parsed then
// discarded) and bounds each copy range explicitly. The four cases below mirror
// the r8 style: small synthetic buffers asserting the computed behavior.

test('applyDelta: a copy range past the base end degrades instead of a clamped false-healthy result (HIMMEL-1427 r9)', () => {
  // Reviewer's exact repro. base "ABC" (len 3), delta:
  //   baseSize(3) | targetSize(1) | copy op 0x91 (0x80|0x10|0x01) | off 0x02 | size 0x02
  // → cpOff 2, cpSize 2 — 2 bytes from offset 2. base[2..4] runs one byte past
  // the base end. Buffer.subarray CLAMPS that to base[2..3] = "C", which matched
  // targetSize 1 → pre-fix this returned "C" as a silently-accepted result. Now
  // cpOff+cpSize (4) > base.length (3) → degrade (null), NOT "C".
  const base = Buffer.from([0x41, 0x42, 0x43]); // "ABC"
  const delta = Buffer.from([0x03, 0x01, 0x91, 0x02, 0x02]);
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: a copy that starts in range but ends past the base end degrades (HIMMEL-1427 r9)', () => {
  // Partial-range overrun: the copy STARTS well inside the base (offset 4 of 8)
  // so a start-only bounds check would miss it; only the full cpOff+cpSize guard
  // catches that it ends past the end. base 8 bytes, copy op 0x91 | off 0x04 |
  // size 0x08 → cpOff 4 (in range), cpSize 8 → 4+8 > 8 → degrade.
  const base = Buffer.from([0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48]);
  const delta = Buffer.from([0x08, 0x08, 0x91, 0x04, 0x08]);
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: a declared base size that does not match the actual base degrades (HIMMEL-1427 r9)', () => {
  // base is 3 bytes but the delta header DECLARES baseSize 2. Pre-fix the
  // declared base size was parsed and discarded, so the delta would apply against
  // a mismatched base. Now the mismatch degrades to null before any op runs (the
  // would-be-valid insert never executes).
  const base = Buffer.from([0x41, 0x42, 0x43]);
  const delta = Buffer.from([0x02, 0x01, 0x01, 0x41]); // baseSize(2) != base.length 3
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: a copy whose range exactly reaches the base end still applies (HIMMEL-1427 r9)', () => {
  // Boundary of the r9 guard: cpOff+cpSize === base.length is IN range and must
  // still resolve (the check is `>`, not `>=`). Guards against an off-by-one
  // regression that would reject a valid tail-of-base copy. base "ABCD", copy op
  // 0x91 | off 0x02 | size 0x02 → base[2..4] = "CD", exactly reaching the end.
  const base = Buffer.from([0x41, 0x42, 0x43, 0x44]); // "ABCD"
  const delta = Buffer.from([0x04, 0x02, 0x91, 0x02, 0x02]);
  assert.deepEqual(applyDelta(base, delta), Buffer.from([0x43, 0x44])); // "CD"
});

// -- applyDelta size-varint overflow + readObject OID recompute (HIMMEL-1427 r10) -
// Two panel findings (premises verified):
//   (1) applyDelta's header size varints accumulated with JS bitwise shifts, which
//       coerce to a SIGNED 32-bit Int32 — a 5-byte size varint like
//       [0x81,0x80,0x80,0x80,0x10] (== 4_294_967_297, i.e. 2^32+1) WRAPPED to 1,
//       bypassing the r9 declared-base-size check (baseSize 1 === base.length 1)
//       instead of degrading. Now decoded with non-wrapping Number math and a
//       MAX_OBJECT_SIZE cap (decodeSizeVarint). The same defect existed in the
//       target-size varint and the OFS_DELTA negOff varint.
//   (2) readPackedObject resolved oid→offset via findPackOffset and returned the
//       entry's { type, body } WITHOUT hashing it — a crafted/corrupt idx that
//       maps the oid to ANOTHER object's offset serves the wrong blob, and the
//       integrity comparison read false-healthy. readObject now recomputes the
//       git object id at this single chokepoint and degrades on mismatch.

test('applyDelta: a base-size varint that overflows 32 bits degrades instead of wrapping past the declared-size check (HIMMEL-1427 r10)', () => {
  // Reviewer's exact repro. The 5-byte base-size varint [0x81,0x80,0x80,0x80,0x10]
  // encodes 4_294_967_297 (2^32 + 1). Under the OLD bitwise accumulator
  // (`val |= (b&0x7f)<<shift`) JS coerced that to a signed Int32 and it WRAPPED to
  // 1 — which === base.length(1), so r9's declared-base-size check PASSED and the
  // delta proceeded. Non-wrapping decode (decodeSizeVarint) rejects the value
  // (> MAX_OBJECT_SIZE) → null, never applied.
  const base = Buffer.from([0x41]); // length 1 — matches the OLD wrapped value
  const delta = Buffer.from([0x81, 0x80, 0x80, 0x80, 0x10]);
  assert.equal(applyDelta(base, delta), null);
});

test('applyDelta: a target-size varint that overflows 32 bits degrades instead of wrapping to a matching length (HIMMEL-1427 r10)', () => {
  // baseSize(1) matches the 1-byte base so the base check passes; the target-size
  // varint [0x81,0x80,0x80,0x80,0x10] then overflows. Pre-fix it WRAPPED to 1, and
  // the trailing insert of 'A' produced out.length 1 === targetSize 1 → a silently
  // accepted one-byte result. Non-wrapping decode rejects the oversized target →
  // null before any op runs.
  const base = Buffer.from([0x41]);
  const delta = Buffer.from([0x01, 0x81, 0x80, 0x80, 0x80, 0x10, 0x01, 0x41]);
  assert.equal(applyDelta(base, delta), null);
});

// readObject recomputes the object id (HIMMEL-1427 r10). The fixture builds a pack
// of two real blobs; with `swapOffsets` the idx maps oidA → blobB's offset (and
// vice-versa). The bytes at the swapped offset ARE a valid git object — just a
// different one — so only the post-read OID check catches it (inflate and range
// checks all pass).

function gitObjectId(type, body) {
  return crypto.createHash('sha1').update(`${type} ${body.length}\0`, 'utf8').update(body).digest('hex');
}

// Builds a 2-blob pack whose idx maps each oid to its OWN offset, or — when
// `swapOffsets` — to the OTHER blob's offset. Entries are sorted by oid bytes
// (idx binary search) and the fanout is the true cumulative first-byte count.
function buildTwoBlobPack(swapOffsets) {
  const dir = mkdtempSync(join(tmpdir(), 'gblock-oid-'));
  const commonDir = join(dir, 'git');
  const packDir = join(commonDir, 'objects', 'pack');
  mkdirSync(packDir, { recursive: true });

  const bodyA = Buffer.from('AAA');   // blob, 3 bytes
  const bodyB = Buffer.from('BBBBB'); // blob, 5 bytes
  const oidA = gitObjectId('blob', bodyA);
  const oidB = gitObjectId('blob', bodyB);

  const header = Buffer.alloc(12);
  header.write('PACK', 0, 'ascii');
  header.writeUInt32BE(2, 4);
  header.writeUInt32BE(2, 8); // 2 objects
  const entryA = Buffer.concat([Buffer.from([0x33]), zlib.deflateSync(bodyA)]); // (blob<<4)|3
  const entryB = Buffer.concat([Buffer.from([0x35]), zlib.deflateSync(bodyB)]); // (blob<<4)|5
  const offA = 12;
  const offB = offA + entryA.length;
  const packBody = Buffer.concat([header, entryA, entryB]);
  const trailer = crypto.createHash('sha1').update(packBody).digest(); // 20-byte pack checksum
  const pack = Buffer.concat([packBody, trailer]);

  const entries = [
    { oid: oidA, off: swapOffsets ? offB : offA },
    { oid: oidB, off: swapOffsets ? offA : offB },
  ].sort((a, b) => Buffer.compare(Buffer.from(a.oid, 'hex'), Buffer.from(b.oid, 'hex')));
  const fanout = {};
  for (let i = 0; i < 256; i += 1) {
    fanout[i] = entries.filter((e) => Buffer.from(e.oid, 'hex')[0] <= i).length;
  }
  const idx = buildIdx(entries, { total: 2, fanout });

  writeFileSync(join(packDir, 'pack-oid.idx'), idx);
  writeFileSync(join(packDir, 'pack-oid.pack'), pack);
  return { dir, commonDir, oidA, oidB };
}

test('readObject: an idx that maps an oid to a DIFFERENT valid object degrades on OID mismatch (HIMMEL-1427 r10)', () => {
  // The swapped idx serves oidA the bytes of blobB (and vice-versa). Both are
  // valid, well-formed git objects, so inflate and range checks pass — only the
  // recomputed id (sha1 of blobB's {type,body} == oidB) differs from the request
  // (oidA) → degrade (null), never the wrong blob.
  const { dir, commonDir, oidA, oidB } = buildTwoBlobPack(true);
  process.on('exit', () => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort tmp cleanup */ } });

  assert.equal(readObject(commonDir, oidA), null, 'oidA mapped at blobB must degrade on OID mismatch');
  assert.equal(readObject(commonDir, oidB), null, 'oidB mapped at blobA must degrade on OID mismatch');
});

test('readObject: a correct pack/idx pair still resolves (no false-degrade from the OID recompute) (HIMMEL-1427 r10)', () => {
  // Boundary of the r10 check: a well-formed idx mapping each oid to its OWN
  // offset must still resolve — the recomputed id equals the request. Guards
  // against the verification rejecting honest data (wrong hash algo, or a
  // header/body assembly that would make every healthy install read degraded).
  const { dir, commonDir, oidA, oidB } = buildTwoBlobPack(false);
  process.on('exit', () => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort tmp cleanup */ } });

  assert.deepEqual(readObject(commonDir, oidA), { type: 'blob', body: Buffer.from('AAA') });
  assert.deepEqual(readObject(commonDir, oidB), { type: 'blob', body: Buffer.from('BBBBB') });
});

// HIMMEL-1468: the manual ref/HEAD fallback parser (used when the git subprocess
// is unavailable) used to accept only 40-hex sha1 OIDs, degrading a sha256 repo
// even though readObject supports sha256. readHeadOid must now accept 40- OR
// 64-hex detached OIDs, and a ref: pointing at a loose ref or a packed-ref.
const HEAD_SHA1 = '0123456789abcdef0123456789abcdef01234567';
const HEAD_SHA256 = '0123456789abcdef'.repeat(4); // 64 hex chars

function buildHeadFixture({ head, looseRef, packedRef } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'gblock-head-'));
  const gitDir = join(dir, 'git');
  mkdirSync(gitDir, { recursive: true });
  writeFileSync(join(gitDir, 'HEAD'), head);
  if (looseRef) {
    const [refName, oid] = looseRef;
    const refPath = join(gitDir, ...refName.split('/'));
    mkdirSync(dirname(refPath), { recursive: true });
    writeFileSync(refPath, `${oid}\n`);
  }
  if (packedRef) {
    writeFileSync(join(gitDir, 'packed-refs'), `${packedRef[1]} ${packedRef[0]}\n`);
  }
  return { dir, gitDir };
}

function dropOnExit(dir) {
  process.on('exit', () => { try { rmSync(dir, { recursive: true, force: true }); } catch { /* best-effort tmp cleanup */ } });
}

test('readHeadOid: accepts a 64-hex sha256 detached HEAD and still rejects non-hex (HIMMEL-1468)', () => {
  const sha256 = buildHeadFixture({ head: `${HEAD_SHA256}\n` });
  dropOnExit(sha256.dir);
  assert.equal(readHeadOid(sha256.gitDir, sha256.gitDir), HEAD_SHA256, '64-hex sha256 detached HEAD must resolve');

  const sha1 = buildHeadFixture({ head: `${HEAD_SHA1}\n` });
  dropOnExit(sha1.dir);
  assert.equal(readHeadOid(sha1.gitDir, sha1.gitDir), HEAD_SHA1, '40-hex sha1 detached HEAD still resolves (control)');

  const junk = buildHeadFixture({ head: 'not-an-oid\n' });
  dropOnExit(junk.dir);
  assert.equal(readHeadOid(junk.gitDir, junk.gitDir), null, 'non-hex HEAD is rejected');
});

test('readHeadOid: follows ref: to a 64-hex sha256 loose ref and to packed-refs (HIMMEL-1468)', () => {
  const loose = buildHeadFixture({ head: 'ref: refs/heads/main\n', looseRef: ['refs/heads/main', HEAD_SHA256] });
  dropOnExit(loose.dir);
  assert.equal(readHeadOid(loose.gitDir, loose.gitDir), HEAD_SHA256, 'loose ref carrying a sha256 oid resolves');

  // No loose ref → readHeadOid falls through to readPackedRef.
  const packed = buildHeadFixture({ head: 'ref: refs/heads/main\n', packedRef: ['refs/heads/main', HEAD_SHA256] });
  dropOnExit(packed.dir);
  assert.equal(readHeadOid(packed.gitDir, packed.gitDir), HEAD_SHA256, 'packed-ref carrying a sha256 oid resolves');
});
