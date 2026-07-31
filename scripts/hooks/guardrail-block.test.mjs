import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, readdirSync, statSync, unlinkSync, chmodSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join, dirname, resolve } from 'node:path';
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
