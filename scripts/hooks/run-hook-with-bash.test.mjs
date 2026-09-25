import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { chmodSync, existsSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makeTmpDir } from '../lib/test-tmpdir.mjs';

const require = createRequire(import.meta.url);
const {
  DEFAULT_CHAIN_BUDGET_MS,
  MIN_MEMBER_TIMEOUT_MS,
  MUST_RUN_CHAIN_MEMBERS,
  isKnownBadWindowsBash,
  isRecoverableEpipe,
  isUsable,
  mergeHookOutputs,
  resolveBash,
  gitBlobSha1,
  verifyProjectHookIntegrity,
} = require('./run-hook-with-bash.js');
const HERE = dirname(fileURLToPath(import.meta.url));
const LAUNCHER = join(HERE, 'run-hook-with-bash.js');

const norm = (value) => String(value).replace(/\\/g, '/');

test('Windows resolver refuses WSL and WindowsApps bash aliases', () => {
  assert.equal(isKnownBadWindowsBash('C:\\Windows\\System32\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Windows\\Sysnative\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps\\bash.exe'), true);
  assert.equal(isKnownBadWindowsBash('C:\\Program Files\\Git\\bin\\bash.exe'), false);
});

test('Windows resolver refuses zero-byte alias files outside WindowsApps', () => {
  const dir = makeTmpDir('hook-bash-zero-byte-');
  const alias = join(dir, 'bash.exe');
  try {
    writeFileSync(alias, '');
    assert.equal(isUsable(alias, 'win32'), false);
    writeFileSync(alias, 'not empty');
    assert.equal(isUsable(alias, 'win32'), true);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('Windows resolver selects Git Bash even when bad aliases lead PATH', () => {
  const gitBash = 'C:/Tools/Git/bin/bash.exe';
  const usable = new Set([gitBash.toLowerCase()]);
  const resolved = resolveBash({
    platform: 'win32',
    env: { PATH: 'C:\\Windows\\System32;C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps;C:\\Tools\\Git\\cmd' },
    isUsable: (candidate) => usable.has(norm(candidate).toLowerCase()),
  });
  assert.equal(resolved, gitBash);
});

test('Windows resolver fails closed when only bad aliases are available', () => {
  const resolved = resolveBash({
    platform: 'win32',
    env: { PATH: 'C:\\Windows\\System32;C:\\Users\\u\\AppData\\Local\\Microsoft\\WindowsApps' },
    isUsable: (candidate) => !isKnownBadWindowsBash(candidate) && false,
  });
  assert.equal(resolved, null);
});

test('non-Windows resolver preserves PATH order before system fallbacks', () => {
  const resolved = resolveBash({
    platform: 'darwin',
    env: { PATH: '/opt/homebrew/bin:/usr/local/bin' },
    isUsable: (candidate) => candidate === '/opt/homebrew/bin/bash' || candidate === '/bin/bash',
  });
  assert.equal(resolved, '/opt/homebrew/bin/bash');
});

test('current platform resolves a concrete Bash executable', () => {
  const resolved = resolveBash();
  assert.ok(resolved);
  assert.equal(isAbsolute(resolved), true);
  if (process.platform === 'win32') assert.equal(isKnownBadWindowsBash(resolved), false);
});

test('launcher executes a hook through the resolved Bash and forwards extra args', () => {
  const dir = makeTmpDir('hook-bash-launcher-');
  const hook = join(dir, 'hook.sh');
  try {
    writeFileSync(hook, '#!/usr/bin/env bash\nprintf \'HOOK_FIRED:%s\\n\' "$BASH_VERSION"\nprintf \'ARGS:%s|%s\\n\' "$1" "$2"\n');
    chmodSync(hook, 0o755);
    const result = spawnSync(process.execPath, [LAUNCHER, hook, 'alpha', 'two words'], { encoding: 'utf8' });
    assert.equal(result.status, 0, result.stderr);
    assert.match(result.stdout, /^HOOK_FIRED:\d+\./);
    assert.match(result.stdout, /ARGS:alpha\|two words/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('--optional exits zero before Bash resolution when the hook is absent', () => {
  const missing = join(tmpdir(), 'missing-optional-hook.sh');
  const result = spawnSync(process.execPath, [LAUNCHER, '--optional', missing], {
    encoding: 'utf8',
    env: {},
  });
  assert.equal(result.status, 0, result.stderr);
});

// HIMMEL-1649 [codex-adv-1]: a DELETED guard must not silently pass in a
// DISPATCHED WORKER. `--optional` alone exits 0 on a missing script, so a worker
// holding Edit(<worktree>/**) + Bash(node *) could remove the guard in one
// command and disable it for every later tool call. A worker cannot strip the
// marker either — a tool-call child cannot edit the harness process env — so
// under the marker a deleted hook bricks the worker, which is the correct
// outcome for tampering.
test('a missing guard fails closed in a dispatched worker', () => {
  const missing = join(tmpdir(), 'block-glm-external-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_GLM_WORKER=1', missing],
    { encoding: 'utf8', env: { HIMMEL_GLM_WORKER: '1' } }
  );
  assert.equal(result.status, 2);
  assert.equal(
    result.stderr,
    'block-glm-external-writes: hook script missing while HIMMEL_GLM_WORKER=1 (stale checkout?) - failing closed\n'
  );
});

// The other half, and the round-6 regression this keying exists to prevent: an
// INTERACTIVE GLM session (claude-glm, whose documented primary workload runs
// with cwd in the luna vault) has no himmel scripts/ tree, so the hook is
// legitimately absent. Keying on the provider instead of worker-ness denied
// every Bash/PowerShell/MCP call there. The marker is absent, so it must pass —
// even with the GLM provider env set.
test('a missing guard still passes in an interactive GLM session', () => {
  const missing = join(tmpdir(), 'block-glm-external-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_GLM_WORKER=1', missing],
    { encoding: 'utf8', env: { ANTHROPIC_BASE_URL: 'https://api.z.ai/api/anthropic' } }
  );
  assert.equal(result.status, 0, result.stderr);
});

test('--fail-closed-when preserves the lesson-loop missing-hook refusal', () => {
  const missing = join(tmpdir(), 'block-lesson-enforcement-writes.sh');
  const result = spawnSync(
    process.execPath,
    [LAUNCHER, '--optional', '--fail-closed-when', 'HIMMEL_LESSON_LOOP=1', missing],
    { encoding: 'utf8', env: { HIMMEL_LESSON_LOOP: '1' } }
  );
  assert.equal(result.status, 2);
  assert.equal(
    result.stderr,
    'block-lesson-enforcement-writes: hook script missing while HIMMEL_LESSON_LOOP=1 (stale checkout?) - failing closed\n'
  );
});

// HIMMEL-1992 — the CALL-SITE half of this resolver's contract. A bare `bash`
// spawned from Node/Bun/pwsh resolves through the SPAWNING process's PATH,
// which on Windows finds C:\Windows\System32\bash.exe (the WSL launcher)
// before Git Bash: a 600s hang or a silent wrong-shell run. The resolver above
// only helps where it is actually called, so this scans the covered trees for
// a spawn that still names a bare "bash".
//
// NOT flagged, deliberately: a bare `bash` INSIDE a fixture — a stub script's
// own shebang, a heredoc a test writes, an expected-argv string. Those run in
// an ALREADY-RUNNING bash and are not spawn sites; the patterns below match
// only the interpreter argument of a spawn/exec call, or a pwsh `& bash`.
const BASH_LINT_TREES = [
  'scripts/telegram',
  'scripts/himmelctl',
  'scripts/hooks',
  'scripts/lanes',
  'marketplace/plugins',
];
// Every JS/TS module extension in one rule, per tree: a per-tree extension list
// let a .ts under scripts/lanes (or any .cjs) introduce a bare-bash spawn the
// scan never opened (CR round 2, codex-1).
const BASH_LINT_EXT = /\.(?:[cm]?js|[cm]?ts)$/;
// The pwsh half: the two operator installers this rule covers. scripts/codex/
// is deliberately absent — it owns the cmd-side resolver and its own tests
// assert ON the string `& bash`.
const BASH_LINT_PS1 = ['scripts/setup.ps1', 'scripts/adopt.ps1'];
// The trailing boundary is quote-OR-space so a command-STRING call -- one that
// passes the whole command line as a single quoted argument to exec/execSync --
// is caught too, not just the argv form (CR round 1, codex-4). "bashful" still
// does not match. NB the scan is textual, so a covered file that merely spells
// that shape out in PROSE trips it: reword the comment, do not exempt the file.
// HIMMEL-2289: the name is matched with a trailing `[A-Za-z]*` so a local
// WRAPPER around the spawn is caught too, not just the node built-ins. That
// hole let scripts/himmelctl/lib/probes.js hand the bare name to its own
// spawn wrapper at 13 call sites and still lint clean here — the literal was
// right there, the function name simply was not one of the built-ins.
const SPAWN_BARE_BASH = /(?:spawn|exec)[A-Za-z]*\s*\(\s*\[?\s*["'`]bash(?:["'`]|\s)/;
// The optional quotes catch `& "bash"` / `& 'bash'`, which resolve through PATH
// exactly like the bare word (CR round 2, codex-2).
const PS_BARE_BASH = /(?:^|[;&|(\s])&\s*(["']?)bash\1(?:\s|$)/;

test('no covered call site spawns a bare "bash" instead of the resolved one', () => {
  const repo = join(HERE, '..', '..');
  const offenders = [];
  for (const rel of BASH_LINT_TREES) {
    let entries = [];
    try {
      entries = readdirSync(join(repo, rel), { recursive: true, withFileTypes: true });
    } catch (_e) {
      continue; // a tree that does not exist in this checkout is not a finding
    }
    for (const entry of entries) {
      if (!entry.isFile() || !BASH_LINT_EXT.test(entry.name)) continue;
      const full = join(entry.parentPath || entry.path, entry.name);
      const shown = norm(full);
      if (shown.includes('/node_modules/') || shown.includes('/dist/')) continue;
      if (SPAWN_BARE_BASH.test(readFileSync(full, 'utf8'))) offenders.push(shown.slice(norm(repo).length + 1));
    }
  }
  for (const rel of BASH_LINT_PS1) {
    readFileSync(join(repo, rel), 'utf8').split('\n').forEach((line, i) => {
      if (/^\s*#/.test(line)) return; // a comment quoting the rule, not a call
      if (PS_BARE_BASH.test(line)) offenders.push(`${rel}:${i + 1}`);
    });
  }
  assert.deepEqual(
    offenders,
    [],
    `spawn the RESOLVED bash (resolveBash() / BASH_BIN / $GitBash), never a bare "bash": ${offenders.join(', ')}`
  );
});

// ------------------------------------------------------------ chain mode (HIMMEL-2002)
//
// The dispatcher contract: one node launch runs N guardrails in order, the
// first deny short-circuits, and our stdout stays ONE JSON object or empty.

const PAYLOAD = JSON.stringify({ hook_event_name: 'PreToolUse', tool_name: 'Bash', tool_input: { command: 'echo hi' } });

// Fixture members. Each writes a marker file so a short-circuit is provable by
// the ABSENCE of a later member's marker, not by output alone.
const MEMBERS = {
  'allow.sh': `printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"safe"}}'`,
  'ask.sh': `printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"confirm"}}'`,
  'context.sh': `printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"ctx"},"systemMessage":"note"}'`,
  'updated-input.sh': `printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","additionalContext":"c2"},"updatedInput":{"command":"x"}}'`,
  'deny-exit2.sh': `printf 'DENY-STDOUT'; printf 'deny reason\\n' >&2; exit 2`,
  'deny-json.sh': `printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"nope"}}'; printf 'why\\n' >&2`,
  'plain-stdout.sh': `printf 'just words'`,
  'exit1.sh': `printf 'broke\\n' >&2; exit 1`,
  'echo-stdin.sh': `printf 'SAW:'; cat`,
  // Outruns the 500 ms bound the timeout test sets by 6x, so "was it killed?"
  // is not a race — but stays short, because if the kill ever regressed this
  // member would run to completion and the suite would pay it. The assertion
  // still fails in that case (no kill message, wrong ordering), just cheaply.
  'hang.sh': `sleep 3`,
  'hang2.sh': `sleep 3`,
  // Same shape as hang.sh, named like a real must-run security guard so the
  // MUST_RUN_CHAIN_MEMBERS lookup (keyed by basename) actually fires in the
  // fixture dir (HIMMEL-2060).
  'block-read-secrets.sh': `sleep 3`,
  // HIMMEL-3383: the /pr-check literal guard is must-run too.
  'guard-pr-check-literal.sh': `sleep 3`,
  // HIMMEL-3601: a must-run member that CRASHES (not a timeout) — named like
  // a real must-run guard so MUST_RUN_CHAIN_MEMBERS fires, exits 1 the way a
  // `set -u` abort or a failed `.` source would.
  'block-jira-compound-write.sh': `printf 'boom\\n' >&2; exit 1`,
  // HIMMEL-3601: a must-run member killed by a signal (null status), not via
  // our own timeout path.
  'block-git-stash.sh': `kill -9 "$$"`,
  // The LEGACY PreToolUse block spelling — valid output, and not a shape the
  // merge allowlist could carry, so it has to short-circuit.
  'deny-legacy.sh': `printf '{"decision":"block","reason":"legacy block"}'`,
  // Past the 16 MiB member buffer, so spawnSync returns ENOBUFS.
  'flood.sh': `head -c 17000000 /dev/zero | tr '\\0' 'x'`,
  // Advisory bodies for the --lifecycle chain (HIMMEL-2003).
  'adv1.sh': `printf 'ADV-ONE\\n'`,
  'adv2.sh': `printf 'ADV-TWO\\n'`,
  'adv3.sh': `printf 'ADV-THREE\\n'`,
};

function chainFixture() {
  const dir = makeTmpDir('hook-bash-chain-');
  for (const [name, body] of Object.entries(MEMBERS)) {
    // Every member drops a marker so "did it run?" is observable.
    writeFileSync(join(dir, name), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-${name}"\n${body}\n`);
    chmodSync(join(dir, name), 0o755);
  }
  return dir;
}

const runChain = (dir, names, input = PAYLOAD) =>
  spawnSync(process.execPath, [LAUNCHER, '--chain', ...names.map((n) => (isAbsolute(n) ? n : join(dir, n)))], {
    encoding: 'utf8',
    input,
  });

const runLifecycle = (dir, names, input = PAYLOAD) =>
  spawnSync(
    process.execPath,
    [LAUNCHER, '--chain', '--lifecycle', ...names.map((n) => (isAbsolute(n) ? n : join(dir, n)))],
    { encoding: 'utf8', input },
  );

const ran = (dir, name) => existsSync(join(dir, `ran-${name}`));

// A killed member leaves its `ran-*` marker (written before its body runs)
// even when SIGKILL lands mid-write, truncating its JSON stdout — the same
// starved-tail symptom the adjoining `ran()` assert already names, not a
// different failure. Route the parse through that assertion (same message)
// so retryFlaky (HIMMEL-2063) treats it identically, instead of a raw
// JSON.parse SyntaxError it correctly refuses to retry as unrelated.
function parsedDecision(result, message) {
  let parsed = null;
  try {
    parsed = JSON.parse(result.stdout);
  } catch (_e) {
    parsed = null;
  }
  assert.ok(parsed && parsed.hookSpecificOutput, message);
  return parsed;
}

function withChain(fn) {
  const dir = chainFixture();
  try {
    fn(dir);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
}

// HIMMEL-2063: two chain-timeout tests race a trivial member's spawn against
// MIN_MEMBER_TIMEOUT_MS (the 500ms floor a spent budget clamps to). That floor
// is sized to the ~210ms per-member p95 the launcher's own comment documents —
// "usually still finishes", not a guarantee — so a loaded box (this suite's own
// prior chain tests, or a neighbor process) can occasionally push a bash.exe
// spawn past 500ms with no launcher misbehaviour at all. Retrying the whole
// attempt re-checks the SAME assertions (nothing here is loosened); it only
// absorbs transient scheduling noise the floor was never meant to survive.
//
// Residual risk (CR round 2, codex-1): a GENUINE intermittent launcher
// regression that occasionally starves the tail would raise this exact same
// assertion, so no message-based filter can tell it apart from spawn-latency
// noise — that is inherent to any retry-tolerant flake fix, not something
// this function can algorithmically close. The distinction was made ONCE,
// out-of-band: a controlled A/B toggle of windowsHide (the commit under
// bisection) reproduced the identical failure with the flag OFF, and every
// failing run's stderr showed the launcher's kill/skip/clamp bounds reported
// correctly — only the wall-clock "did it finish in time" race varied. See
// the HIMMEL-2063 PR body for the full evidence trail.
function retryFlaky(fn, expectedMessages, attempts = 8) {
  const messages = Array.isArray(expectedMessages) ? expectedMessages : [expectedMessages];
  for (let i = 1; i <= attempts; i++) {
    try {
      fn();
      return;
    } catch (err) {
      // Only retry the KNOWN timing-sensitive assertions (HIMMEL-2063 CR: a
      // blanket catch-and-retry would also mask a real intermittent launcher
      // regression surfacing as a DIFFERENT assertion — a wrong kill/skip
      // message, the decision, or any non-assertion error. Those must fail
      // on the first attempt, not get silently retried away.
      if (!(err instanceof assert.AssertionError) || !messages.some((m) => err.message.includes(m))) throw err;
      if (i === attempts) throw err;
    }
  }
}

test('chain runs members in order and every member sees the full stdin', () => {
  withChain((dir) => {
    const result = runChain(dir, ['echo-stdin.sh', 'plain-stdout.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, '');
    // Both bodies land on OUR stderr, in chain order, never on stdout.
    assert.equal(result.stderr, `SAW:${PAYLOAD}\njust words\n`);
  });
});

test('chain emits a lone JSON decision byte-for-byte verbatim', () => {
  withChain((dir) => {
    const result = runChain(dir, ['plain-stdout.sh', 'allow.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      result.stdout,
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"safe"}}',
    );
  });
});

test('chain merges two emitters: ask beats allow, reasons and context joined', () => {
  withChain((dir) => {
    const result = runChain(dir, ['allow.sh', 'ask.sh', 'context.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(JSON.parse(result.stdout), {
      hookSpecificOutput: {
        hookEventName: 'PreToolUse',
        permissionDecision: 'ask',
        permissionDecisionReason: 'safe | confirm',
        additionalContext: 'ctx',
      },
      systemMessage: 'note',
    });
  });
});

test('chain drops an unmergeable key with a warning instead of mis-merging it', () => {
  withChain((dir) => {
    const result = runChain(dir, ['allow.sh', 'updated-input.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(JSON.parse(result.stdout).updatedInput, undefined);
    assert.match(result.stderr, /dropping unmergeable key updatedInput from updated-input\.sh/);
  });
});

// HIMMEL-2002: the entry's `timeout` bounds the WHOLE chain now, so a member
// that hangs must not be allowed to spend the budget the later security guards
// need — Claude Code would kill the entry and, because a PreToolUse timeout
// fails OPEN, skip them silently. Each member carries its own bound instead.
test('a hung chain member is killed and the chain continues past it', () => {
  retryFlaky(() => withChain((dir) => {
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh'), join(dir, 'allow.sh')],
      // 2000ms, not the 500ms floor: this member's bound is a free choice (the
      // budget is untouched, default 50s), so give the member AFTER the kill
      // real headroom to spawn under load rather than racing the floor itself —
      // that race is what the budget-clamp test below exists to cover.
      { encoding: 'utf8', input: PAYLOAD, env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '2000' } },
    );
    // Not a deny: a hook that outran its bound is skipped, exactly as it was
    // when Claude Code killed it as its own settings entry.
    assert.notEqual(result.status, 2);
    // HIMMEL-2060: the verbose per-skip line collapsed to one compact line.
    assert.match(result.stderr, /^run-hook-with-bash: SKIP hang\.sh \(budget=2000ms elapsed=\d+ms\) — guard did not evaluate this call\.$/m);
    // The load-bearing half: the member AFTER the hang still ran.
    assert.equal(ran(dir, 'allow.sh'), true, 'a hung member must not starve later guards');
    assert.equal(
      parsedDecision(result, 'a hung member must not starve later guards').hookSpecificOutput.permissionDecision,
      'allow',
    );
  }), 'a hung member must not starve later guards');
});

// N members at the full per-member bound can outlast the ENTRY's timeout, and
// that budget blowing is what silently skips the tail. The chain clamps each
// member to what is left, so it always reaches its own end and reports there.
test('a spent chain budget clamps later members instead of overrunning the entry', () => {
  retryFlaky(() => withChain((dir) => {
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh'), join(dir, 'hang2.sh'), join(dir, 'allow.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: {
          ...process.env,
          // Per-member bound deliberately LARGER than the whole-chain budget:
          // without the clamp the two hangs alone would run 2 x 4000ms.
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '4000',
          RUN_HOOK_CHAIN_BUDGET_MS: '1200',
        },
      },
    );
    // Assert the BOUNDS the launcher reports, not wall clock: a killed member
    // can leave an orphaned `sleep` holding the pipe on Windows, which makes
    // elapsed time measure the fixture rather than the clamp.
    //
    // Every skip is also reported BY US — that is the point: a budget this far
    // gone still ends with the launcher naming what it dropped, where letting
    // the entry's own timeout fire would have skipped the tail silently.
    //
    // First member: clamped to ~1200ms (the whole budget), well under its own
    // 4000ms bound — proof the budget clamp binds at all. Real overhead
    // between capturing the deadline and spawning member 1 can shave a few ms
    // off under load (observed 1199ms), so match a narrow window rather than
    // the exact literal — CR round 3: 10ms covers the observed jitter with
    // margin without loosening enough to hide a materially early clamp (a
    // wider window would mask a real regression that fires the clamp early).
    // CR round 4: this is itself a timing-sensitive assertion, so it carries
    // a message and is retried too (below) — a heavier-loaded host shaving
    // more than 10ms is the same spawn-latency story as the other two.
    assert.match(
      result.stderr,
      /run-hook-with-bash: SKIP hang\.sh \(budget=(119[0-9]|1200)ms/,
      'first member clamp fell outside the expected budget window',
    );
    // Second: budget spent, so it lands on the 500ms floor, not on 0ms and not
    // on its own 4000ms bound.
    assert.match(result.stderr, /run-hook-with-bash: SKIP hang2\.sh \(budget=500ms/);
    // The floor is the other half: a spent budget clamps the tail, but never to
    // a 0ms slice — the guard after two hangs still gets to decide, and its
    // decision still reaches the model.
    assert.equal(ran(dir, 'allow.sh'), true, 'a spent budget must not starve the tail to 0ms');
    assert.equal(
      parsedDecision(result, 'a spent budget must not starve the tail to 0ms').hookSpecificOutput.permissionDecision,
      'allow',
    );
  }), ['a spent budget must not starve the tail to 0ms', 'first member clamp fell outside the expected budget window']);
});

// Chaining BUFFERS member output (a lone hook streams with `stdio: 'inherit'`
// and has no ceiling), so buffer overflow is a hazard chaining introduced. It
// must never become a deny — a chatty hook is not grounds to block a tool call.
test('a member that overflows the output buffer is skipped, not turned into a deny', () => {
  withChain((dir) => {
    const result = runChain(dir, ['flood.sh', 'allow.sh']);
    assert.notEqual(result.status, 2, 'buffer overflow must not deny the tool call');
    assert.match(result.stderr, /run-hook-with-bash: SKIP flood\.sh \(budget=\d+ms elapsed=\d+ms\) — guard did not evaluate this call\./);
    assert.equal(ran(dir, 'allow.sh'), true, 'the chain must continue past an overflowing member');
    assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, 'allow');
  });
});

// -------------------------------------------------- HIMMEL-2557: EPIPE-with-status is not a launcher failure
//
// spawnSync surfaces EPIPE on the parent's stdin WRITE when the child exits
// before draining it (a guard that returns on its first line, or the write
// racing the child's exit under load — 2d687f9c, main red 2026-09-12). The
// child still ran to completion, so its own status/stdout/stderr are the real
// verdict. A payload well past the 64 KiB pipe buffer makes the write land
// after the fixture has already closed its stdin and exited, reproducing the
// race deterministically instead of relying on scheduler timing.
const EPIPE_PAYLOAD = JSON.stringify({
  hook_event_name: 'PreToolUse',
  tool_name: 'Bash',
  tool_input: { command: 'a'.repeat(300 * 1024) },
});

function epipeFixture(name, body) {
  const dir = makeTmpDir('hook-bash-epipe-');
  const script = join(dir, name);
  writeFileSync(script, `#!/usr/bin/env bash\n${body}\n`);
  chmodSync(script, 0o755);
  return script;
}

test('a chain member that exits without reading stdin still ALLOWS on an EPIPE write', () => {
  const script = epipeFixture('exit-without-reading-allow.sh', 'exec 0<&-\nexit 0');
  const result = runChain(dirname(script), [script], EPIPE_PAYLOAD);
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stderr, /failed to start/);
});

test('a chain member that exits without reading stdin still DENIES on an EPIPE write', () => {
  const script = epipeFixture('exit-without-reading-deny.sh', "exec 0<&-\necho '⛔ fixture deny' >&2\nexit 2");
  const result = runChain(dirname(script), [script], EPIPE_PAYLOAD);
  assert.equal(result.status, 2);
  assert.match(result.stderr, /⛔ fixture deny/);
  assert.doesNotMatch(result.stderr, /failed to start/);
});

test('a lone (non-chain) hook that exits without reading stdin still ALLOWS on an EPIPE write', () => {
  const script = epipeFixture('exit-without-reading-allow.sh', 'exec 0<&-\nexit 0');
  const result = spawnSync(process.execPath, [LAUNCHER, script], { encoding: 'utf8', input: EPIPE_PAYLOAD });
  assert.equal(result.status, 0, result.stderr);
  assert.doesNotMatch(result.stderr, /failed to start/);
});

// CONTROL: only EPIPE with a NUMERIC status (proof the child actually exited)
// may fall through. Every other spawn error, and EPIPE with a null status (the
// child never exited — e.g. it was itself killed), stays fail-closed. Exercised
// as a unit test on the extracted predicate rather than end-to-end: system bash
// always resolves on this box, so there is no way to force a genuine non-EPIPE
// `result.error` out of the real launcher without corrupting the system's own
// /bin/bash — the boundary the predicate encodes is the actual thing at risk.
test('isRecoverableEpipe only accepts EPIPE paired with a numeric status', () => {
  assert.equal(isRecoverableEpipe({ error: { code: 'EPIPE' }, status: null }), false);
  assert.equal(isRecoverableEpipe({ error: { code: 'ENOENT' }, status: 0 }), false);
  assert.equal(isRecoverableEpipe({ error: { code: 'EPIPE' }, status: 2 }), true);
});

// -------------------------------------------------- must-run vs skippable (HIMMEL-2060)
//
// A shared chain budget can starve a LATE member down to the floor. Before
// this, every starved member was skipped-and-continued, including the deny-
// capable security guards — an advisory shape wrong for a security fence.
// Neither test below races a trivial follow-up member's spawn window the way
// the two retryFlaky tests above do (no member has to spawn+finish inside a
// tight post-kill window): the must-run test denies before `allow.sh` would
// ever need to run, and the skippable test chains only the starved member
// itself. So neither needs retryFlaky.

// This list is pinned EXACTLY on purpose: promoting a guard to must-run changes
// what a starved chain does to a real tool call, so it is a deliberate edit
// here, never an incidental one. Keep it in sync with MUST_RUN_CHAIN_MEMBERS in
// run-hook-with-bash.js.
//
// block-write-into-main-checkout.sh is HIMMEL-2526's destination-write fence,
// landing in a sibling PR (HIMMEL-2528 added the entry ahead of it). The set is
// BASENAME-keyed and is consulted only when a member with that basename has
// been starved of budget, so naming a file that does not exist yet is inert:
// nothing looks the entry up until that hook is actually wired into a chain.
test('MUST_RUN_CHAIN_MEMBERS covers exactly the deny-capable security guards', () => {
  assert.deepEqual(
    [...MUST_RUN_CHAIN_MEMBERS].sort(),
    [
      'block-chokepoint-env-prefix.sh',
      'block-destructive-commands.sh',
      'block-edit-live-settings.sh',
      'block-git-stash.sh',
      'block-jira-compound-write.sh',
      'block-read-secrets.sh',
      'block-rogue-claude-schedule.sh',
      'block-tail-pipe-on-gates.sh',
      'block-write-into-main-checkout.sh',
      'check-cr-marker-on-pr-create.sh',
      'guard-pr-check-literal.sh',
    ].sort(),
  );
});

test('a must-run member over its budget DENIES the chain instead of being skipped', () => {
  withChain((dir) => {
    const logFile = join(dir, 'skips.jsonl');
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'block-read-secrets.sh'), join(dir, 'allow.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: logFile },
      },
    );
    assert.equal(result.status, 2, result.stderr);
    assert.match(
      result.stderr,
      /^run-hook-with-bash: DENY block-read-secrets\.sh \(budget=500ms elapsed=\d+ms\) — must-run guard did not evaluate this call; failing closed\.\n$/,
    );
    // The load-bearing half: a starved must-run guard ends the chain, it does
    // not let a later member decide in its place.
    assert.equal(ran(dir, 'allow.sh'), false, 'a starved must-run guard must deny, not skip past it');

    const rows = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows.length, 1);
    assert.equal(rows[0].action, 'deny');
    assert.equal(rows[0].member, 'block-read-secrets.sh');
    assert.equal(rows[0].budget, 500);
    assert.equal(typeof rows[0].elapsed, 'number');
  });
});

// HIMMEL-3080: a must-run member starved by the SHARED chain budget (an
// upstream non-must-run member ate it) must get its own dedicated evaluation
// window rather than being denied unevaluated at whatever floor was left. The
// guard here needs 900ms to decide — more than the MIN_MEMBER_TIMEOUT_MS
// floor (500ms) the old clamp would have left it, less than its own full
// per-member timeout (2000ms). hog.sh's bound is deliberately tighter than
// its own sleep, so it ALWAYS overruns and eats the whole 600ms chain budget,
// making the tail's shared-budget remainder land on the floor deterministically
// (Math.max's floor, not a race) — this fixture never depends on the retry
// wrapper the two timing-sensitive tests above need.
test('a must-run member starved by the shared chain budget gets its own window and still decides (HIMMEL-3080)', () => {
  const dir = makeTmpDir('hook-bash-starve-');
  try {
    writeFileSync(join(dir, 'hog.sh'), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-hog.sh"\nsleep 3\n`);
    chmodSync(join(dir, 'hog.sh'), 0o755);
    // Named like the real must-run tail from the ticket's own incident.
    writeFileSync(
      join(dir, 'block-chokepoint-env-prefix.sh'),
      `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-tail.sh"\nsleep 0.9\nprintf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"fast"}}'\n`,
    );
    chmodSync(join(dir, 'block-chokepoint-env-prefix.sh'), 0o755);

    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hog.sh'), join(dir, 'block-chokepoint-env-prefix.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: {
          ...process.env,
          RUN_HOOK_CHAIN_BUDGET_MS: '600',
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '2000',
        },
      },
    );
    assert.equal(result.status, 0, result.stderr);
    assert.equal(existsSync(join(dir, 'ran-tail.sh')), true, 'the must-run tail must actually run, not be denied unevaluated');
    assert.equal(
      JSON.parse(result.stdout).hookSpecificOutput.permissionDecision,
      'allow',
      'a must-run tail starved of shared budget must still get to decide on its own window',
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-3080: the denial message for a genuinely starved-and-still-timed-out
// must-run member must NAME the upstream member that ate the shared budget,
// not merely the starved tail — the ticket's DONE WHEN instrumentation ask.
// hog.sh's bound is clamped to the MIN_MEMBER_TIMEOUT_MS floor (500ms,
// deterministic regardless of jitter — see the comment on the test above),
// which always leaves the tail's shared remainder starved below its own
// 900ms window. The tail's body (1.3s) is longer even than that full 900ms
// window, so it denies on a REAL timeout of its OWN window, not the shared
// clamp — proving the consumer note reports upstream starvation that
// happened regardless of the ultimate cause of this member's own denial.
test('a starved-then-still-timed-out must-run member names the upstream budget consumer (HIMMEL-3080)', () => {
  const dir = makeTmpDir('hook-bash-starve-consumer-');
  try {
    writeFileSync(join(dir, 'hog.sh'), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-hog.sh"\nsleep 3\n`);
    chmodSync(join(dir, 'hog.sh'), 0o755);
    writeFileSync(
      join(dir, 'block-chokepoint-env-prefix.sh'),
      `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-tail.sh"\nsleep 1.3\nprintf 'allow'\n`,
    );
    chmodSync(join(dir, 'block-chokepoint-env-prefix.sh'), 0o755);

    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hog.sh'), join(dir, 'block-chokepoint-env-prefix.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: {
          ...process.env,
          RUN_HOOK_CHAIN_BUDGET_MS: '300',
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '900',
        },
      },
    );
    assert.equal(result.status, 2, result.stderr);
    // hog.sh's OWN skip line always names hog.sh (that is not the point being
    // tested) — the DENY line ITSELF, for the starved tail, must also name
    // hog.sh as the budget consumer, not just report the tail's own elapsed.
    const denyLine = result.stderr.split('\n').find((l) => l.includes('DENY block-chokepoint-env-prefix.sh'));
    assert.ok(denyLine, `expected a DENY line for the tail:\n${result.stderr}`);
    assert.match(denyLine, /hog\.sh/, 'the DENY line must name the member that ate the shared budget');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-3080 (J1259O F1): a must-run member's own window must ALSO be capped
// by an entry-safe deadline — left uncapped, several must-run members (or one
// that hangs, here) can collectively outrun the settings.json entry `timeout`
// (60s on every real chain that carries a must-run member). Claude Code then
// kills the whole hook, and a killed PreToolUse hook fails OPEN — every guard
// that had not run yet is silently skipped, where the runner itself would
// have denied. Scaled ÷10 like the judge's own fixtures.sh. An outer
// `timeout`-shaped kill on the LAUNCHER process itself (spawnSync's own
// `timeout`/`killSignal`) stands in for that entry timeout: at base this
// test's chain outruns it and gets killed with no decision emitted; the fix
// must make the runner deny well inside it instead.
test('a chain whose advisory members hang and eat the budget, then a hung must-run member, DENIES strictly before the entry timeout (HIMMEL-3080 F1)', () => {
  const dir = makeTmpDir('hook-bash-entry-deadline-');
  try {
    const hangs = ['hog1.sh', 'hog2.sh', 'hog3.sh', 'hog4.sh'];
    for (const name of hangs) {
      writeFileSync(join(dir, name), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-${name}"\nsleep 100\n`);
      chmodSync(join(dir, name), 0o755);
    }
    // Named like a real must-run guard so MUST_RUN_CHAIN_MEMBERS fires.
    writeFileSync(join(dir, 'block-read-secrets.sh'), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-tail.sh"\nsleep 100\n`);
    chmodSync(join(dir, 'block-read-secrets.sh'), 0o755);

    const HARNESS_MS = 6500;
    const t0 = Date.now();
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', ...hangs.map((n) => join(dir, n)), join(dir, 'block-read-secrets.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        timeout: HARNESS_MS,
        killSignal: 'SIGKILL',
        env: {
          ...process.env,
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '3000',
          RUN_HOOK_CHAIN_BUDGET_MS: '3000',
          RUN_HOOK_CHAIN_ENTRY_TIMEOUT_MS: '6500',
          RUN_HOOK_CHAIN_ENTRY_SAFETY_MARGIN_MS: '1000',
        },
      },
    );
    const wall = Date.now() - t0;
    assert.notEqual(
      result.signal,
      'SIGKILL',
      `the launcher must decide before the entry timeout, not be killed by it (stderr: ${result.stderr})`,
    );
    assert.equal(result.status, 2, result.stderr);
    assert.ok(wall < HARNESS_MS, `chain took ${wall}ms, must stay under the ${HARNESS_MS}ms entry timeout`);
    assert.match(result.stderr, /DENY block-read-secrets\.sh/);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-3080 (J1259O F1): the same regression without any single member ever
// hanging — several must-run members that each decide SLOWLY but always
// within their own full window can still, uncapped, collectively outrun the
// entry timeout. The fix must cap every window so the chain denies (here, via
// the new pre-spawn deadline-exhausted path once no safe window is left)
// strictly before the entry timeout, even though nothing ever times out on
// its own merits.
test('a chain of many slow-but-deciding must-run members DENIES strictly before the entry timeout (HIMMEL-3080 F1)', () => {
  const dir = makeTmpDir('hook-bash-entry-deadline-slow-');
  try {
    const names = [
      'block-destructive-commands.sh',
      'block-rogue-claude-schedule.sh',
      'block-chokepoint-env-prefix.sh',
      'block-tail-pipe-on-gates.sh',
      'check-cr-marker-on-pr-create.sh',
      'block-edit-live-settings.sh',
      'block-write-into-main-checkout.sh',
    ];
    for (const name of names) {
      writeFileSync(
        join(dir, name),
        `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-${name}"\nsleep 1.3\nprintf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"slow"}}'\n`,
      );
      chmodSync(join(dir, name), 0o755);
    }

    const HARNESS_MS = 6000;
    const t0 = Date.now();
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', ...names.map((n) => join(dir, n))],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        timeout: HARNESS_MS,
        killSignal: 'SIGKILL',
        env: {
          ...process.env,
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '1500',
          RUN_HOOK_CHAIN_BUDGET_MS: '1000',
          RUN_HOOK_CHAIN_ENTRY_TIMEOUT_MS: '6000',
          RUN_HOOK_CHAIN_ENTRY_SAFETY_MARGIN_MS: '500',
        },
      },
    );
    const wall = Date.now() - t0;
    assert.notEqual(
      result.signal,
      'SIGKILL',
      `the launcher must decide before the entry timeout, not be killed by it (stderr: ${result.stderr})`,
    );
    assert.equal(result.status, 2, result.stderr);
    assert.ok(wall < HARNESS_MS, `chain took ${wall}ms, must stay under the ${HARNESS_MS}ms entry timeout`);
    const ranCount = names.filter((n) => existsSync(join(dir, `ran-${n}`))).length;
    assert.ok(ranCount < names.length, 'the chain must deny before every member gets a chance to run');
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-3080 (J1259O F2): the denial's "budget consumer" note must name the
// member that actually spent the SHARED chain budget, not merely whichever
// prior member has the largest raw elapsed time. block-destructive-commands.sh
// here runs LONGER (1.2s) than hog.sh's own budget spend (1.0s) but does so
// inside its OWN entry-safe window, after the shared budget was already gone —
// the old max-elapsed heuristic would wrongly blame it instead of hog.sh.
test('a starved denial names the member that actually spent the shared budget, not a later must-run member that ran longer in its own window (HIMMEL-3080 F2)', () => {
  const dir = makeTmpDir('hook-bash-consumer-attribution-');
  try {
    writeFileSync(join(dir, 'hog.sh'), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-hog.sh"\nsleep 100\n`);
    chmodSync(join(dir, 'hog.sh'), 0o755);
    writeFileSync(
      join(dir, 'block-destructive-commands.sh'),
      `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-mid.sh"\nsleep 1.2\nprintf '%s' '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"slow"}}'\n`,
    );
    chmodSync(join(dir, 'block-destructive-commands.sh'), 0o755);
    writeFileSync(join(dir, 'block-tail-pipe-on-gates.sh'), `#!/usr/bin/env bash\n: > "$(dirname "$0")/ran-tail.sh"\nsleep 100\n`);
    chmodSync(join(dir, 'block-tail-pipe-on-gates.sh'), 0o755);

    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hog.sh'), join(dir, 'block-destructive-commands.sh'), join(dir, 'block-tail-pipe-on-gates.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: {
          ...process.env,
          RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '2000',
          RUN_HOOK_CHAIN_BUDGET_MS: '1000',
          RUN_HOOK_CHAIN_ENTRY_TIMEOUT_MS: '3500',
          RUN_HOOK_CHAIN_ENTRY_SAFETY_MARGIN_MS: '500',
        },
      },
    );
    assert.equal(result.status, 2, result.stderr);
    assert.equal(existsSync(join(dir, 'ran-mid.sh')), true, 'the middle must-run member must actually get to run in its own window');
    const denyLine = result.stderr.split('\n').find((l) => l.includes('DENY block-tail-pipe-on-gates.sh'));
    assert.ok(denyLine, `expected a DENY line for the tail:\n${result.stderr}`);
    assert.match(denyLine, /hog\.sh/, 'the DENY line must name hog.sh, the member that actually spent the shared budget');
    assert.equal(
      /block-destructive-commands\.sh/.test(denyLine),
      false,
      'the DENY line must NOT blame the middle member merely for running longer in its own window',
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// HIMMEL-3383: a starved guard-pr-check-literal.sh must deny, never let the
// bare scripts/cr literal fall through to the allow rule unchecked.
test('a starved guard-pr-check-literal.sh DENIES the chain instead of being skipped', () => {
  withChain((dir) => {
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'guard-pr-check-literal.sh'), join(dir, 'allow.sh')],
      {
        encoding: 'utf8',
        input: PAYLOAD,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: join(dir, 'skips.jsonl') },
      },
    );
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /DENY guard-pr-check-literal\.sh \(budget=500ms/);
    assert.equal(ran(dir, 'allow.sh'), false, 'a starved literal guard must deny, not skip past it');
  });
});

// HIMMEL-3601: a must-run member that crashes (exits with anything other
// than 0 or 2) must deny the chain the same as one that times out, not fall
// to the generic non-blocking error path.
test('a must-run member that crashes DENIES the chain instead of falling open', () => {
  withChain((dir) => {
    const result = runChain(dir, ['block-jira-compound-write.sh', 'allow.sh']);
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /DENY block-jira-compound-write\.sh \(rc=1\)/);
    assert.equal(ran(dir, 'allow.sh'), false, 'a crashed must-run guard must deny, not fall open');
  });
});

// HIMMEL-3601: same, for a must-run member killed by a signal (null status).
test('a must-run member killed by a signal DENIES the chain and names the signal', () => {
  withChain((dir) => {
    const result = runChain(dir, ['block-git-stash.sh', 'allow.sh']);
    assert.equal(result.status, 2, result.stderr);
    assert.match(result.stderr, /DENY block-git-stash\.sh \(signal SIGKILL\)/);
    assert.equal(ran(dir, 'allow.sh'), false, 'a signal-killed must-run guard must deny, not fall open');
  });
});

test('a skippable member over budget produces exactly one stderr line and one JSONL row', () => {
  withChain((dir) => {
    const logFile = join(dir, 'skips.jsonl');
    const input = JSON.stringify({
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'echo hi' },
      session_id: 'sess-abc',
    });
    const result = spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh')],
      {
        encoding: 'utf8',
        input,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: logFile },
      },
    );
    // Not a deny — hang.sh is not in MUST_RUN_CHAIN_MEMBERS.
    assert.notEqual(result.status, 2);
    assert.match(
      result.stderr,
      /^run-hook-with-bash: SKIP hang\.sh \(budget=500ms elapsed=\d+ms\) — guard did not evaluate this call\.\n$/,
    );

    const rows = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows.length, 1, 'exactly one durable row per skip');
    assert.equal(rows[0].action, 'skip');
    assert.equal(rows[0].member, 'hang.sh');
    assert.equal(rows[0].budget, 500);
    assert.equal(typeof rows[0].elapsed, 'number');
    assert.equal(rows[0].sessionId, 'sess-abc');
    assert.ok(rows[0].ts, 'row carries a timestamp');
    assert.match(rows[0].toolCall, /Bash echo hi/);
  });
});

// HIMMEL-2060 CR round 1 (codex-1): a starved guard's own command text can BE
// a secret read (block-read-secrets.sh is itself must-run-able), so the JSONL
// row must never carry it verbatim.
test('a secret-shaped token in the starved command is redacted in the JSONL row', () => {
  withChain((dir) => {
    const logFile = join(dir, 'skips.jsonl');
    const input = JSON.stringify({
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      // Low-entropy filler (not a real credential shape) so this fixture
      // does not itself trip the gitleaks generic-api-key scan.
      tool_input: { command: 'curl -H "AUTH_TOKEN=xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" https://example.com' },
    });
    spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh')],
      {
        encoding: 'utf8',
        input,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: logFile },
      },
    );
    const rows = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows.length, 1);
    assert.doesNotMatch(rows[0].toolCall, /xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx/, 'raw token must not reach the durable log');
    assert.match(rows[0].toolCall, /<redacted>/);
  });
});

// HIMMEL-2060 CR round 2 (codex-1): the credential in an "Authorization:
// Bearer <token>" header sits in a SEPARATE word after the scheme, which the
// name=value redaction alone does not reach.
test('a Bearer-scheme credential is redacted even when short', () => {
  withChain((dir) => {
    const logFile = join(dir, 'skips.jsonl');
    const input = JSON.stringify({
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      // Not a literal `curl -H "Authorization: Bearer ..."` shape (avoids
      // gitleaks' dedicated curl-auth-header rule on this fixture) — the
      // header text alone is enough to exercise the redaction pass.
      tool_input: { command: 'echo "Authorization: Bearer shorttoken123"' },
    });
    spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh')],
      {
        encoding: 'utf8',
        input,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: logFile },
      },
    );
    const rows = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows.length, 1);
    // The credential is gone either way — whether "Bearer" itself survives
    // depends on redaction pass ORDER (NAMED_SECRET_ASSIGNMENT's own "Authorization:"
    // match can also consume the now-adjacent "Bearer" word on a second pass),
    // which is an implementation detail this test does not pin.
    assert.doesNotMatch(rows[0].toolCall, /shorttoken123/, 'the credential word after the scheme must not reach the durable log');
    assert.match(rows[0].toolCall, /<redacted>/);
  });
});

// HIMMEL-2060 CR round 4 (codex-1): curl's `-u user:pass` shorthand and URL
// userinfo (`https://user:pass@host`) carry a credential outside every other
// pattern's shape.
test('curl -u/--user and URL userinfo credentials are redacted', () => {
  withChain((dir) => {
    const logFile = join(dir, 'skips.jsonl');
    const input = JSON.stringify({
      hook_event_name: 'PreToolUse',
      tool_name: 'Bash',
      tool_input: { command: 'echo "-u myuser:mypassvalue https://otheruser:otherpassvalue@example.com/api"' },
    });
    spawnSync(
      process.execPath,
      [LAUNCHER, '--chain', join(dir, 'hang.sh')],
      {
        encoding: 'utf8',
        input,
        env: { ...process.env, RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS: '500', RUN_HOOK_CHAIN_SKIP_LOG: logFile },
      },
    );
    const rows = readFileSync(logFile, 'utf8').trim().split('\n').map((line) => JSON.parse(line));
    assert.equal(rows.length, 1);
    assert.doesNotMatch(rows[0].toolCall, /myuser:mypassvalue/, 'a -u credential must not reach the durable log');
    assert.doesNotMatch(rows[0].toolCall, /otheruser:otherpassvalue/, 'URL userinfo must not reach the durable log');
    assert.match(rows[0].toolCall, /example\.com\/api/, 'the rest of the URL is not needlessly destroyed');
  });
});

// The merge allowlist cannot carry a top-level `decision`, so if this did not
// short-circuit, a later member's `allow` would win and a refusal would have
// silently become an approval.
test('the legacy top-level decision:block short-circuits like a permissionDecision deny', () => {
  withChain((dir) => {
    const result = runChain(dir, ['deny-legacy.sh', 'allow.sh']);
    assert.equal(result.status, 2);
    assert.equal(ran(dir, 'allow.sh'), false, 'a legacy block must end the chain');
    // Passed through verbatim, so Claude Code sees the block it was given.
    assert.equal(JSON.parse(result.stdout).decision, 'block');
  });
});

test('the first deny short-circuits: a later member never runs', () => {
  withChain((dir) => {
    const result = runChain(dir, ['allow.sh', 'deny-exit2.sh', 'plain-stdout.sh']);
    assert.equal(result.status, 2);
    assert.equal(ran(dir, 'deny-exit2.sh'), true);
    assert.equal(ran(dir, 'plain-stdout.sh'), false, 'chain must not run past the first deny');
    // Verbatim, and only the denier's: no earlier member's held output.
    assert.equal(result.stdout, 'DENY-STDOUT');
    assert.equal(result.stderr, 'deny reason\n');
  });
});

test('a deny expressed as JSON on exit 0 short-circuits exactly like exit 2', () => {
  withChain((dir) => {
    const result = runChain(dir, ['deny-json.sh', 'plain-stdout.sh']);
    assert.equal(result.status, 2);
    assert.equal(ran(dir, 'plain-stdout.sh'), false);
    assert.equal(JSON.parse(result.stdout).hookSpecificOutput.permissionDecision, 'deny');
    assert.equal(result.stderr, 'why\n');
  });
});

test('a non-blocking member error carries its rc only when nothing decided', () => {
  withChain((dir) => {
    const failed = runChain(dir, ['exit1.sh', 'plain-stdout.sh']);
    assert.equal(failed.status, 1);
    assert.equal(ran(dir, 'plain-stdout.sh'), true, 'a non-blocking error must not stop the chain');
    assert.match(failed.stderr, /broke/);
  });
  withChain((dir) => {
    // A real decision outranks the error rc — exit 2/0 are the only outcomes
    // Claude Code acts on, and a JSON decision must reach it.
    const decided = runChain(dir, ['exit1.sh', 'allow.sh']);
    assert.equal(decided.status, 0);
    assert.match(decided.stdout, /"permissionDecision":"allow"/);
  });
});

test('a missing or duplicated member fails the whole chain closed before anything runs', () => {
  withChain((dir) => {
    const missing = runChain(dir, ['allow.sh', join(dir, 'nope.sh')]);
    assert.equal(missing.status, 2);
    assert.match(missing.stderr, /chain member not found/);
    assert.equal(ran(dir, 'allow.sh'), false, 'validation must precede execution');
  });
  withChain((dir) => {
    const dupe = runChain(dir, ['allow.sh', 'plain-stdout.sh', 'allow.sh']);
    assert.equal(dupe.status, 2);
    assert.match(dupe.stderr, /duplicate chain member/);
    assert.equal(ran(dir, 'allow.sh'), false);
  });
});

test('--chain refuses --optional/--fail-closed-when and an empty member list', () => {
  const combined = spawnSync(process.execPath, [LAUNCHER, '--chain', '--optional', 'a.sh'], { encoding: 'utf8', input: PAYLOAD });
  assert.equal(combined.status, 2);
  assert.match(combined.stderr, /--chain cannot be combined/);

  const empty = spawnSync(process.execPath, [LAUNCHER, '--chain'], { encoding: 'utf8', input: PAYLOAD });
  assert.equal(empty.status, 2);
  assert.match(empty.stderr, /missing hook script path/);
});

test('mergeHookOutputs keeps continue:false and stopReason from any member', () => {
  const dropped = [];
  const merged = mergeHookOutputs(
    [
      { source: 'a.sh', output: { hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' } } },
      { source: 'b.sh', output: { continue: false, stopReason: 'halt', decision: 'block' } },
    ],
    (key, source) => dropped.push(`${key}@${source}`),
  );
  assert.deepEqual(merged, {
    hookSpecificOutput: { hookEventName: 'PreToolUse', permissionDecision: 'allow' },
    continue: false,
    stopReason: 'halt',
  });
  assert.deepEqual(dropped, ['decision@b.sh']);
});

// ------------------------------------------------------ lifecycle mode (HIMMEL-2003)
//
// The advisory contract: SessionStart hooks have no permission gate, so every
// member's stdout is CONCATENATED to ours, a member's failure never stops the
// chain and never changes our exit, and we always exit 0 once the whole-chain
// validation the PreToolUse path already performs has passed.

test('lifecycle concatenates every member body in chain order', () => {
  withChain((dir) => {
    const result = runLifecycle(dir, ['adv1.sh', 'adv2.sh', 'adv3.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'ADV-ONE\nADV-TWO\nADV-THREE\n');
  });
});

// HIMMEL-3134: a member that never reads stdin (every advisory body here is a
// bare `printf`) can exit before OUR write of the shared `input` payload
// finishes landing in its pipe. That write then gets EPIPE even though the
// member ran to completion and its stdout was fully captured — the same
// recoverable case `isRecoverableEpipe` exists to absorb in the non-lifecycle
// loop below (:589). The lifecycle loop's `if (result.error)` at :511 has no
// such guard, so a recoverable EPIPE is treated as a launch failure and the
// member's stdout is dropped via `continue`. A payload past the OS pipe
// buffer (64 KiB on Linux) makes the child-exits-before-write-finishes race
// deterministic instead of load-dependent, reproducing CI's flaky drop
// on demand.
test('lifecycle keeps a member\'s stdout when writing its stdin EPIPEs (HIMMEL-3134)', () => {
  withChain((dir) => {
    const bigInput = 'x'.repeat(200_000);
    const result = runLifecycle(dir, ['adv1.sh', 'adv2.sh', 'adv3.sh'], bigInput);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'ADV-ONE\nADV-TWO\nADV-THREE\n');
  });
});

test('lifecycle keeps going past a member that exits 2, and still exits 0', () => {
  withChain((dir) => {
    const result = runLifecycle(dir, ['adv1.sh', 'deny-exit2.sh', 'adv3.sh']);
    // exit 2 is the PreToolUse deny convention; here there is nothing to deny.
    assert.equal(result.status, 0, result.stderr);
    assert.equal(ran(dir, 'adv3.sh'), true, 'a failing advisory must not silence the rest');
    assert.equal(result.stdout, 'ADV-ONE\nDENY-STDOUT\nADV-THREE\n');
    assert.equal(result.stderr, 'deny reason\n');
  });
});

test('lifecycle keeps going past a member that exits 1, and forwards its stderr', () => {
  withChain((dir) => {
    const result = runLifecycle(dir, ['exit1.sh', 'adv2.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(result.stdout, 'ADV-TWO\n');
    assert.equal(result.stderr, 'broke\n');
  });
});

test('lifecycle still fails the whole chain closed before anything runs', () => {
  withChain((dir) => {
    const result = runLifecycle(dir, ['adv1.sh', join(dir, 'nope.sh')]);
    assert.equal(result.status, 2);
    assert.match(result.stderr, /chain member not found/);
    assert.equal(ran(dir, 'adv1.sh'), false, 'a stale checkout must be loud, not silently advisory');
  });
});

test('--lifecycle without --chain is a usage error', () => {
  const result = spawnSync(process.execPath, [LAUNCHER, '--lifecycle', 'a.sh'], { encoding: 'utf8', input: PAYLOAD });
  assert.equal(result.status, 2);
  assert.match(result.stderr, /--lifecycle requires --chain/);
});

// Documented limitation: lifecycle mode does NOT merge JSON. A member emitting a
// decision envelope is concatenated as text like any other body — no member does
// today, and a SessionStart hook has no permission gate to address one to.
test('lifecycle passes a JSON-emitting member through as plain text', () => {
  withChain((dir) => {
    const result = runLifecycle(dir, ['allow.sh', 'adv2.sh']);
    assert.equal(result.status, 0, result.stderr);
    assert.equal(
      result.stdout,
      '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"safe"}}\nADV-TWO\n',
    );
  });
});

// ------------------------------------------------- settings wiring shape (HIMMEL-2002)

const SETTINGS = join(HERE, '..', '..', '.claude', 'settings.json');
// HIMMEL-2047/2758: the wired command is now `if [ -f run-node.sh ]; then sh …
// run-hook-with-bash.js" --chain <members>; else node …
// run-hook-with-bash.js" --chain <members>; fi` — the SAME member list
// verbatim on both branches. Stop the capture at the first `;` (a chain
// member's quoted path never contains one) so it reads only the first
// branch's list, not both concatenated.
const CHAIN_RE = /run-hook-with-bash\.js"\s+--chain\s+([^;]*)/;

function chainMembersOf(command) {
  const m = String(command).match(CHAIN_RE);
  if (!m) return null;
  return [...m[1].matchAll(/([\w.-]+\.sh)/g)].map((x) => x[1]);
}

function groupsOf(event) {
  return JSON.parse(readFileSync(SETTINGS, 'utf8')).hooks[event] || [];
}

function preToolUseGroups() {
  return groupsOf('PreToolUse');
}

// Both chained events (HIMMEL-2003 added SessionStart to HIMMEL-2002's PreToolUse).
const CHAINED_EVENTS = ['PreToolUse', 'SessionStart'];

test('every chained hook member exists and appears at most once in its chain', () => {
  for (const event of CHAINED_EVENTS) {
    for (const group of groupsOf(event)) {
      for (const hook of group.hooks || []) {
        const members = chainMembersOf(hook.command);
        if (!members) continue;
        const where = `${event} ${group.matcher || ''}`.trim();
        assert.ok(members.length >= 2, `a chain of one is pointless: ${where}`);
        assert.deepEqual([...new Set(members)], members, `duplicate member in ${where}`);
        for (const member of members) {
          assert.ok(existsSync(join(HERE, member)), `${member} (chained on ${where}) does not exist`);
        }
      }
    }
  }
});

// The launcher's own budget only bounds a chain if the ENTRY outlives it: a
// `timeout` below budget + members x floor lets Claude Code SIGKILL the launcher
// while it still believes it has time, before it reports the members it skipped.
// HIMMEL-2003 shipped the SessionStart chain at 30 s against a 50 s budget by
// inheriting the largest of the four per-hook timeouts it replaced; this asserts
// the worst case the clamp comment already documents, so the next chain cannot
// drift the same way.
test('every chained entry outlives the launcher worst case (budget + members x floor)', () => {
  for (const event of CHAINED_EVENTS) {
    for (const group of groupsOf(event)) {
      for (const hook of group.hooks || []) {
        const members = chainMembersOf(hook.command);
        if (!members) continue;
        const worstCaseMs = DEFAULT_CHAIN_BUDGET_MS + members.length * MIN_MEMBER_TIMEOUT_MS;
        const where = `${event} ${group.matcher || ''}`.trim();
        assert.ok(
          Number(hook.timeout) * 1000 >= worstCaseMs,
          `${where}: timeout ${hook.timeout}s is under the ${worstCaseMs / 1000}s worst case for ${members.length} members`,
        );
      }
    }
  }
});

// --lifecycle is what makes an advisory chain's stdout reach the model at all:
// without it the PreToolUse rules divert every non-JSON body to stderr. On a
// PreToolUse chain the inverse holds — it would drop the deny short-circuit.
test('the SessionStart chain is --lifecycle and no PreToolUse chain is', () => {
  const lifecycled = (command) => /--chain\s+--lifecycle\s/.test(String(command));
  const chains = (event) => groupsOf(event)
    .flatMap((group) => (group.hooks || []).map((hook) => hook.command))
    .filter((command) => chainMembersOf(command));

  const sessionStart = chains('SessionStart');
  assert.ok(sessionStart.length > 0, 'expected a chained SessionStart entry');
  for (const command of sessionStart) assert.ok(lifecycled(command), `SessionStart chain must be --lifecycle: ${command}`);
  for (const command of chains('PreToolUse')) assert.ok(!lifecycled(command), `PreToolUse chain must NOT be --lifecycle: ${command}`);
});

// auto-arm-on-cap is the ONE side-effecting PreToolUse hook: it must fire for
// every tool AND regardless of an earlier deny, so it keeps its own `*` entry.
// Chaining it would let an earlier guardrail's deny silently disarm it.
test('auto-arm-on-cap.sh is never chained', () => {
  for (const group of preToolUseGroups()) {
    for (const hook of group.hooks || []) {
      const members = chainMembersOf(hook.command);
      assert.ok(!members || !members.includes('auto-arm-on-cap.sh'), 'auto-arm-on-cap.sh must stay on its own entry');
    }
  }
});

// The whole point of the dispatcher is ONE launch per tool event. That only
// holds while the chain-carrying matchers stay pairwise disjoint — two matching
// blocks is two launches again, and the drift would be invisible in a diff.
// Mirrors the OVERLAP probe in scripts/codex/test-codex-hook-parity.sh.
test('chain-carrying PreToolUse matchers are pairwise disjoint', () => {
  const matchers = [];
  const tools = new Set();
  for (const group of preToolUseGroups()) {
    const matcher = String(group.matcher || '');
    if (!(group.hooks || []).some((h) => chainMembersOf(h.command))) continue;
    matchers.push([matcher, new RegExp(`^(?:${matcher})$`)]);
    for (const alt of matcher.split('|')) if (/^[\w.]+$/.test(alt)) tools.add(alt);
  }
  assert.ok(matchers.length > 1, 'expected several chained matcher blocks');
  const overlaps = [];
  for (const tool of tools) {
    const hit = matchers.filter(([, re]) => re.test(tool)).map(([m]) => m);
    if (hit.length > 1) overlaps.push(`${tool}=${hit.join('/')}`);
  }
  assert.deepEqual(overlaps, []);
});

// ---------------------------------------------------- HIMMEL-1666 integrity

function withEnv(overrides, fn) {
  const saved = {};
  for (const key of Object.keys(overrides)) {
    saved[key] = process.env[key];
    if (overrides[key] === undefined) delete process.env[key];
    else process.env[key] = overrides[key];
  }
  try {
    return fn();
  } finally {
    for (const key of Object.keys(overrides)) {
      if (saved[key] === undefined) delete process.env[key];
      else process.env[key] = saved[key];
    }
  }
}

test('gitBlobSha1 matches `git hash-object`', () => {
  const buf = Buffer.from('hello himmel\n');
  const want = spawnSync('git', ['hash-object', '--stdin'], { input: buf, encoding: 'utf8' }).stdout.trim();
  assert.equal(gitBlobSha1(buf), want);
});

test('verifyProjectHookIntegrity fails open with no CLAUDE_PROJECT_DIR, no session id, or no pin file', () => {
  const dir = makeTmpDir('hook-integrity-');
  try {
    const script = join(dir, 'scripts', 'hooks', 'guard.sh');
    withEnv({ CLAUDE_PROJECT_DIR: '' }, () => {
      assert.equal(verifyProjectHookIntegrity(script, 's1').ok, true);
    });
    withEnv({ CLAUDE_PROJECT_DIR: dir, HIMMEL_HOOK_INTEGRITY_DIR: join(dir, 'no-such-dir') }, () => {
      assert.equal(verifyProjectHookIntegrity(script, null).ok, true);
      assert.equal(verifyProjectHookIntegrity(script, 's1').ok, true);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

test('verifyProjectHookIntegrity denies a pinned script whose on-disk content drifted, allows an untouched one', () => {
  const dir = makeTmpDir('hook-integrity-');
  const integrityDir = makeTmpDir('hook-integrity-pins-');
  try {
    const scriptRel = 'scripts/hooks/guard.sh';
    const scriptPath = join(dir, ...scriptRel.split('/'));
    require('node:fs').mkdirSync(dirname(scriptPath), { recursive: true });
    writeFileSync(scriptPath, 'echo original\n');
    const pin = gitBlobSha1(readFileSync(scriptPath));
    writeFileSync(
      join(integrityDir, 's1.json'),
      JSON.stringify({ session_id: 's1', pins: { [scriptRel]: pin } }),
    );
    withEnv(
      { CLAUDE_PROJECT_DIR: dir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined },
      () => {
        assert.equal(verifyProjectHookIntegrity(scriptPath, 's1').ok, true);
        writeFileSync(scriptPath, 'echo tampered\n');
        const result = verifyProjectHookIntegrity(scriptPath, 's1');
        assert.equal(result.ok, false);
        assert.equal(result.relPath, scriptRel);
      },
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(integrityDir, { recursive: true, force: true });
  }
});

// HIMMEL-3390: `..` segments and symlinks are resolved BEFORE the project-local
// and pin decisions. Fixture: a pinned guard under <dir>/scripts/hooks, a
// tampered copy of it, and a sibling directory outside the project.
function dotdotFixture() {
  const fs = require('node:fs');
  const dir = makeTmpDir('hook-integrity-dotdot-');
  const integrityDir = makeTmpDir('hook-integrity-dotdot-pins-');
  const scriptRel = 'scripts/hooks/guard.sh';
  const scriptPath = join(dir, ...scriptRel.split('/'));
  fs.mkdirSync(dirname(scriptPath), { recursive: true });
  writeFileSync(scriptPath, 'echo original\n');
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [scriptRel]: gitBlobSha1(readFileSync(scriptPath)) } }),
  );
  const outside = makeTmpDir('hook-integrity-dotdot-outside-');
  fs.mkdirSync(join(outside, 'scripts', 'hooks'), { recursive: true });
  writeFileSync(join(outside, 'scripts', 'hooks', 'guard.sh'), 'echo unpinned foreign\n');
  const env = { CLAUDE_PROJECT_DIR: dir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined };
  const cleanup = () => {
    for (const d of [dir, integrityDir, outside]) rmSync(d, { recursive: true, force: true });
  };
  return { fs, dir, outside, integrityDir, scriptRel, scriptPath, env, cleanup };
}

test('HIMMEL-3390: a `..` alias of a pinned, tampered hook is checked against the pin of its resolved path', () => {
  const fx = dotdotFixture();
  try {
    const alias = `${fx.dir}/scripts/../scripts/hooks/guard.sh`;
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(alias, 's1').ok, true); // untouched: verifies like the plain path
      writeFileSync(fx.scriptPath, 'echo tampered\n');
      const result = verifyProjectHookIntegrity(alias, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
      assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, false); // control: the plain path still denies
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: a `..` path that leaves the project is denied, and the bypass does not rescue it', () => {
  const fx = dotdotFixture();
  try {
    const escaping = `${fx.dir}/scripts/../../${fx.outside.split('/').pop()}/scripts/hooks/guard.sh`;
    withEnv(fx.env, () => {
      const result = verifyProjectHookIntegrity(escaping, 's1');
      assert.equal(result.ok, false);
      assert.match(result.reason, /outside/);
    });
    withEnv({ ...fx.env, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: '1' }, () => {
      assert.equal(verifyProjectHookIntegrity(escaping, 's1').ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: a symlinked in-project path resolves like its target; one that leaves the project is denied', () => {
  const fx = dotdotFixture();
  try {
    fx.fs.symlinkSync(join(fx.dir, 'scripts', 'hooks'), join(fx.dir, 'alias-hooks'));
    fx.fs.symlinkSync(join(fx.outside, 'scripts', 'hooks'), join(fx.dir, 'foreign-hooks'));
    withEnv(fx.env, () => {
      const viaLink = join(fx.dir, 'alias-hooks', 'guard.sh');
      assert.equal(verifyProjectHookIntegrity(viaLink, 's1').ok, true);
      writeFileSync(fx.scriptPath, 'echo tampered\n');
      const result = verifyProjectHookIntegrity(viaLink, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
      assert.equal(verifyProjectHookIntegrity(join(fx.dir, 'foreign-hooks', 'guard.sh'), 's1').ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: a pinned hook swapped for a symlink to an unpinned in-project file is still denied', () => {
  const fx = dotdotFixture();
  try {
    writeFileSync(join(fx.dir, 'scripts', 'hooks', 'other.sh'), 'echo unpinned sibling\n');
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, true);
      fx.fs.rmSync(fx.scriptPath);
      fx.fs.symlinkSync(join(fx.dir, 'scripts', 'hooks', 'other.sh'), fx.scriptPath);
      const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
      assert.equal(result.ok, false); // the pin of the spelled path must still bind, not only the target's
      assert.equal(result.relPath, fx.scriptRel);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: the pin of a swapped leaf still binds when the hook is reached through a directory alias or a link chain', () => {
  const fx = dotdotFixture();
  try {
    const hooks = join(fx.dir, 'scripts', 'hooks');
    writeFileSync(join(hooks, 'other.sh'), 'echo unpinned sibling\n');
    fx.fs.symlinkSync(hooks, join(fx.dir, 'alias-hooks'));
    fx.fs.symlinkSync(join(hooks, 'other.sh'), join(hooks, 'mid.sh'));
    fx.fs.rmSync(fx.scriptPath);
    fx.fs.symlinkSync(join(hooks, 'mid.sh'), fx.scriptPath); // guard.sh -> mid.sh -> other.sh
    withEnv(fx.env, () => {
      for (const spelled of [join(fx.dir, 'alias-hooks', 'guard.sh'), join(hooks, 'guard.sh')]) {
        const result = verifyProjectHookIntegrity(spelled, 's1');
        assert.equal(result.ok, false, spelled);
        assert.equal(result.relPath, fx.scriptRel);
      }
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: `link/..` follows the link (kernel order), not a lexical collapse', () => {
  const fx = dotdotFixture();
  try {
    // <dir>/hop -> <outside>/deep, so <dir>/hop/../scripts/hooks/guard.sh executes
    // <outside>/scripts/hooks/guard.sh, though a lexical collapse reads <dir>/scripts/hooks/guard.sh.
    fx.fs.mkdirSync(join(fx.outside, 'deep'));
    fx.fs.symlinkSync(join(fx.outside, 'deep'), join(fx.dir, 'hop'));
    const viaHop = `${fx.dir}/hop/../scripts/hooks/guard.sh`;
    withEnv(fx.env, () => {
      const result = verifyProjectHookIntegrity(viaHop, 's1');
      assert.equal(result.ok, false);
      assert.match(result.reason, /outside/);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3390: a foreign path with no `..` stays allowed, and a missing project-local hook is not mistaken for an escape', () => {
  const fx = dotdotFixture();
  try {
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(join(fx.outside, 'scripts', 'hooks', 'guard.sh'), 's1').ok, true);
      assert.equal(verifyProjectHookIntegrity(join(fx.dir, 'scripts', 'hooks', 'missing.sh'), 's1').ok, true);
    });
    const linkedProject = `${fx.dir}-link`;
    fx.fs.symlinkSync(fx.dir, linkedProject);
    try {
      withEnv({ ...fx.env, CLAUDE_PROJECT_DIR: linkedProject }, () => {
        assert.equal(verifyProjectHookIntegrity(join(linkedProject, 'scripts', 'hooks', 'missing.sh'), 's1').ok, true);
        writeFileSync(fx.scriptPath, 'echo tampered\n');
        assert.equal(verifyProjectHookIntegrity(join(linkedProject, 'scripts', 'hooks', 'guard.sh'), 's1').ok, false);
      });
    } finally {
      rmSync(linkedProject, { force: true });
    }
  } finally {
    fx.cleanup();
  }
});

// HIMMEL-3397: the claimed identities come from a kernel-order walk, so every
// directory link a path passes through is checked under its own pin.
test('HIMMEL-3397: a pinned hooks directory replaced by a link is still checked when reached through an alias', () => {
  const fx = dotdotFixture();
  try {
    const hooks = join(fx.dir, 'scripts', 'hooks');
    fx.fs.symlinkSync(hooks, join(fx.dir, 'alias-hooks'));
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, true); // control: the wired spelling verifies
      assert.equal(verifyProjectHookIntegrity(join(fx.dir, 'alias-hooks', 'guard.sh'), 's1').ok, true);
      // scripts/hooks itself becomes a link to an unpinned in-project directory.
      fx.fs.mkdirSync(join(fx.dir, 'unpinned'));
      writeFileSync(join(fx.dir, 'unpinned', 'guard.sh'), 'echo tampered\n');
      fx.fs.rmSync(hooks, { recursive: true });
      fx.fs.symlinkSync(join(fx.dir, 'unpinned'), hooks);
      const result = verifyProjectHookIntegrity(join(fx.dir, 'alias-hooks', 'guard.sh'), 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: an internal `sub/..` below a swapped hooks directory still checks the hooks pin', () => {
  const fx = dotdotFixture();
  try {
    const hooks = join(fx.dir, 'scripts', 'hooks');
    fx.fs.symlinkSync(hooks, join(fx.dir, 'alias-hooks'));
    fx.fs.mkdirSync(join(fx.dir, 'unpinned', 'sub'), { recursive: true });
    writeFileSync(join(fx.dir, 'unpinned', 'guard.sh'), 'echo tampered\n');
    fx.fs.rmSync(hooks, { recursive: true });
    fx.fs.symlinkSync(join(fx.dir, 'unpinned'), hooks);
    withEnv(fx.env, () => {
      const result = verifyProjectHookIntegrity(`${fx.dir}/alias-hooks/sub/../guard.sh`, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: a backslash in a POSIX link target is a filename character, not a separator', { skip: process.platform === 'win32' }, () => {
  const fx = dotdotFixture();
  try {
    const hooks = join(fx.dir, 'scripts', 'hooks');
    const odd = join(fx.dir, 'un\\pinned');
    fx.fs.mkdirSync(odd);
    writeFileSync(join(odd, 'guard.sh'), 'echo tampered\n');
    fx.fs.rmSync(hooks, { recursive: true });
    fx.fs.symlinkSync(odd, hooks);
    withEnv(fx.env, () => {
      const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: the alias cap also holds when a queued link frame is restored', () => {
  const fx = dotdotFixture();
  try {
    // x1 -> x2 -> a1/../a6 queue two frames; each a<k> -> n<k> doubles the live aliases to 63.
    let at = fx.dir;
    for (let k = 1; k <= 6; k++) {
      fx.fs.mkdirSync(join(at, `n${k}`));
      fx.fs.symlinkSync(`n${k}`, join(at, `a${k}`));
      at = join(at, `n${k}`);
    }
    writeFileSync(join(at, 'f.sh'), 'echo unpinned\n');
    fx.fs.symlinkSync('a1/a2/a3/a4/a5/a6', join(fx.dir, 'x2'));
    fx.fs.symlinkSync('x2', join(fx.dir, 'x1'));
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(join(at, 'f.sh'), 's1').ok, true); // control: the plain spelling
      assert.equal(verifyProjectHookIntegrity(join(fx.dir, 'x1', 'f.sh'), 's1').ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: `hop/..` after a directory link claims the target-side path, not the lexical collapse', () => {
  const fx = dotdotFixture();
  try {
    // <dir>/scripts/hop -> <dir>/other/deep, so scripts/hop/../guard.sh runs other/guard.sh.
    fx.fs.mkdirSync(join(fx.dir, 'other', 'deep'), { recursive: true });
    writeFileSync(join(fx.dir, 'other', 'guard.sh'), 'echo other\n');
    writeFileSync(join(fx.dir, 'scripts', 'guard.sh'), 'echo scripts\n');
    fx.fs.symlinkSync(join(fx.dir, 'other', 'deep'), join(fx.dir, 'scripts', 'hop'));
    const pin = (rel) => gitBlobSha1(readFileSync(join(fx.dir, ...rel.split('/'))));
    const writePins = (pins) => writeFileSync(join(fx.integrityDir, 's1.json'), JSON.stringify({ session_id: 's1', pins }));
    const viaHop = `${fx.dir}/scripts/hop/../guard.sh`;
    withEnv(fx.env, () => {
      // The lexical spelling is claimed too (an over-claim only ever denies), so a
      // differing pin on scripts/guard.sh is a safe-direction deny.
      writePins({ 'scripts/guard.sh': pin('scripts/guard.sh') });
      assert.equal(verifyProjectHookIntegrity(viaHop, 's1').ok, false);
      writePins({ 'other/guard.sh': pin('other/guard.sh') });
      writeFileSync(join(fx.dir, 'other', 'guard.sh'), 'echo tampered\n');
      const result = verifyProjectHookIntegrity(viaHop, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, 'other/guard.sh');
    });
  } finally {
    fx.cleanup();
  }
});

// A link target that is not valid UTF-8 cannot be walked faithfully (readlink and
// realpath decode it lossily), so it fails closed rather than dropping the pin.
const nonUtf8 = (dir, before, after) => Buffer.concat([Buffer.from(`${dir}/${before}`), Buffer.from([0xff]), Buffer.from(after)]);

for (const [label, relative] of [['absolute', false], ['relative', true]]) {
  test(`HIMMEL-3397: a hooks directory swapped for a ${label} non-UTF-8 link target fails closed`, { skip: process.platform === 'win32' }, () => {
    const fx = dotdotFixture();
    try {
      const hooks = join(fx.dir, 'scripts', 'hooks');
      const odd = nonUtf8(fx.dir, 'u', 'pinned');
      fx.fs.mkdirSync(odd);
      writeFileSync(Buffer.concat([odd, Buffer.from('/guard.sh')]), 'echo tampered\n');
      fx.fs.rmSync(hooks, { recursive: true });
      fx.fs.symlinkSync(relative ? Buffer.concat([Buffer.from('../'), odd.subarray(fx.dir.length + 1)]) : odd, hooks);
      withEnv(fx.env, () => {
        assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, false);
      });
    } finally {
      fx.cleanup();
    }
  });
}

test('HIMMEL-3397: a pinned leaf swapped for a link with a non-UTF-8 target fails closed', { skip: process.platform === 'win32' }, () => {
  const fx = dotdotFixture();
  try {
    fx.fs.mkdirSync(join(fx.dir, 'u'));
    writeFileSync(nonUtf8(fx.dir, 'u/ev', 'il.sh'), 'echo tampered\n');
    rmSync(fx.scriptPath);
    fx.fs.symlinkSync(Buffer.concat([Buffer.from('../../'), nonUtf8(fx.dir, 'u/ev', 'il.sh').subarray(fx.dir.length + 1)]), fx.scriptPath);
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: an `X/..` spelling through a replaced X still claims the lexical pin', () => {
  const fx = dotdotFixture();
  try {
    const hooks = join(fx.dir, 'scripts', 'hooks');
    // scripts/hooks/sub -> x/y, so scripts/hooks/sub/../guard.sh runs x/guard.sh.
    fx.fs.mkdirSync(join(fx.dir, 'x', 'y'), { recursive: true });
    writeFileSync(join(fx.dir, 'x', 'guard.sh'), 'echo tampered\n');
    fx.fs.symlinkSync(join(fx.dir, 'x', 'y'), join(hooks, 'sub'));
    // scripts/hooks -> ../u, so scripts/hooks/../hooks/guard.sh runs hooks/guard.sh.
    fx.fs.mkdirSync(join(fx.dir, 'u'));
    fx.fs.mkdirSync(join(fx.dir, 'hooks'));
    writeFileSync(join(fx.dir, 'hooks', 'guard.sh'), 'echo tampered\n');
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(`${fx.dir}/scripts/hooks/sub/../guard.sh`, 's1').ok, false);
      fx.fs.rmSync(hooks, { recursive: true });
      fx.fs.symlinkSync('../u', hooks);
      assert.equal(verifyProjectHookIntegrity(`${fx.dir}/scripts/hooks/../hooks/guard.sh`, 's1').ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

test('HIMMEL-3397: a symlink loop fails closed; an unpinned, unrelated path stays allowed', () => {
  const fx = dotdotFixture();
  try {
    fx.fs.symlinkSync(join(fx.dir, 'loop-b'), join(fx.dir, 'loop-a'));
    fx.fs.symlinkSync(join(fx.dir, 'loop-a'), join(fx.dir, 'loop-b'));
    writeFileSync(join(fx.dir, 'scripts', 'unrelated.sh'), 'echo unpinned\n');
    withEnv(fx.env, () => {
      assert.equal(verifyProjectHookIntegrity(join(fx.dir, 'scripts', 'unrelated.sh'), 's1').ok, true);
      const result = verifyProjectHookIntegrity(join(fx.dir, 'loop-a', 'guard.sh'), 's1');
      assert.equal(result.ok, false);
    });
  } finally {
    fx.cleanup();
  }
});

// HIMMEL-3448. HIMMEL-3397's non-UTF-8 round-trip check denied ANY path that
// crossed a non-UTF-8 symlink target, even one strictly ABOVE the project —
// where no alias it could produce ever claims an in-project pin key (the
// `keys` loop below only accepts a candidate rooted at resolvedProject or
// spelledProject). That fenced off a real filesystem shape: an ancestor
// mounted or reached through a non-UTF-8-named link, e.g. a bind mount or a
// locale-mismatched home directory. Fixture: <base>/anc -> a raw non-UTF-8
// byte sequence (never decoded by us — only the KERNEL follows it, via the
// clean lexical spelling `anc`), and the real project lives below that.
function ancestorNonUtf8Fixture() {
  const fs = require('node:fs');
  const base = makeTmpDir('hook-integrity-ancestor-');
  const rawName = Buffer.concat([Buffer.from('a'), Buffer.from([0xff])]);
  const real = Buffer.concat([Buffer.from(`${base}/`), rawName]);
  fs.mkdirSync(Buffer.concat([real, Buffer.from('/proj/scripts/hooks')]), { recursive: true });
  const leaf = Buffer.concat([real, Buffer.from('/proj/scripts/hooks/guard.sh')]);
  writeFileSync(leaf, 'echo original\n');
  const scriptRel = 'scripts/hooks/guard.sh';
  const integrityDir = makeTmpDir('hook-integrity-ancestor-pins-');
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [scriptRel]: gitBlobSha1(readFileSync(leaf)) } }),
  );
  const anc = join(base, 'anc'); // clean name; its TARGET (rawName) carries the non-UTF-8 byte
  fs.symlinkSync(rawName, anc);
  const projectDir = join(anc, 'proj'); // spelled via the clean link name, not the dirty target
  const scriptPath = join(projectDir, 'scripts', 'hooks', 'guard.sh');
  const env = { CLAUDE_PROJECT_DIR: projectDir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined };
  const cleanup = () => { for (const d of [base, integrityDir]) rmSync(d, { recursive: true, force: true }); };
  return { fs, base, leaf, scriptRel, scriptPath, env, cleanup };
}

test('HIMMEL-3448: a non-UTF-8 symlink ABOVE the project still verifies what is below it', { skip: process.platform === 'win32' }, () => {
  const fx = ancestorNonUtf8Fixture();
  try {
    withEnv(fx.env, () => {
      // (a) untampered, reached through the ancestor link: ALLOW, not the old unwalkable DENY.
      assert.equal(verifyProjectHookIntegrity(fx.scriptPath, 's1').ok, true);
      // (b) tampered through that same ancestor: still DENY — the fix must not open anything.
      writeFileSync(fx.leaf, 'echo tampered\n');
      const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, fx.scriptRel);
    });
  } finally {
    fx.cleanup();
  }
});

// (c) a non-UTF-8 link AT or BELOW the project must still fail closed — the
// #1096 C1 rows above ("a hooks directory swapped for a ... non-UTF-8 link
// target fails closed", "a pinned leaf swapped for a link with a non-UTF-8
// target fails closed") already cover this and must stay green.

// (d) the same C1 invariant, but the at/below-project non-UTF-8 link is
// NESTED beneath an already-accepted above-project non-UTF-8 link on the
// same walk. Once the first (ancestor) hop is accepted, `resolved` carries
// that link's own unresolved spelling rather than a path lexically rooted
// at resolvedProject — a naive string-prefix containment check on the
// SECOND link would then misclassify it as "above" too and skip the
// fail-closed path, however deep it actually sits. Regression coverage for
// that specific drift.
function nestedNonUtf8Fixture() {
  const fs = require('node:fs');
  const base = makeTmpDir('hook-integrity-nested-');
  const rawAnc = Buffer.concat([Buffer.from('a'), Buffer.from([0xff])]);
  const realAnc = Buffer.concat([Buffer.from(`${base}/`), rawAnc]);
  fs.mkdirSync(Buffer.concat([realAnc, Buffer.from('/proj/scripts')]), { recursive: true });
  const rawHooks = Buffer.concat([Buffer.from('h'), Buffer.from([0xff])]);
  const hooksReal = Buffer.concat([realAnc, Buffer.from('/proj/scripts/'), rawHooks]);
  fs.mkdirSync(hooksReal, { recursive: true });
  const leaf = Buffer.concat([hooksReal, Buffer.from('/guard.sh')]);
  writeFileSync(leaf, 'echo original\n');
  const scriptRel = 'scripts/hooks/guard.sh';
  const integrityDir = makeTmpDir('hook-integrity-nested-pins-');
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [scriptRel]: gitBlobSha1(readFileSync(leaf)) } }),
  );
  const anc = join(base, 'anc'); // first hop: above-project, accepted
  fs.symlinkSync(rawAnc, anc);
  const projectDir = join(anc, 'proj');
  fs.symlinkSync(rawHooks, join(projectDir, 'scripts', 'hooks')); // second hop: at/below-project
  const scriptPath = join(projectDir, scriptRel);
  const env = { CLAUDE_PROJECT_DIR: projectDir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined };
  const cleanup = () => { for (const d of [base, integrityDir]) rmSync(d, { recursive: true, force: true }); };
  return { fs, base, leaf, scriptRel, scriptPath, env, cleanup };
}

test(
  'HIMMEL-3448: a non-UTF-8 link AT/BELOW the project nested beneath an accepted ancestor non-UTF-8 link still fails closed',
  { skip: process.platform === 'win32' },
  () => {
    const fx = nestedNonUtf8Fixture();
    try {
      withEnv(fx.env, () => {
        const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
        assert.equal(result.ok, false);
      });
    } finally {
      fx.cleanup();
    }
  },
);

// (e) containment must be decided by the link's own LOCATION, not by
// following it to its target. A non-UTF-8 link that SITS inside the
// project, but whose (unreadable, untrusted) target points OUTSIDE it, must
// still fail closed even when a LATER hop happens to lead back inside —
// resolving the link's TARGET instead of its own location would read the
// first hop as "above the project" (since the target sits outside) and let
// the walk continue, silently skipping the fail-closed check the location
// alone should have triggered. The outer link's own PARENT directory never
// moves, so this needs no fast-path escape at scriptPath's own final
// resolution: the walk's final destination legitimately sits inside the
// project (via a second, valid, absolute symlink back in), only the
// INTERMEDIATE hop is the ambiguous one.
function linkEscapesProjectViaTargetFixture() {
  const fs = require('node:fs');
  const base = makeTmpDir('hook-integrity-escape-');
  const projectDir = join(base, 'proj');
  fs.mkdirSync(join(projectDir, 'scripts'), { recursive: true });
  fs.mkdirSync(join(projectDir, 'real'), { recursive: true });
  const leaf = join(projectDir, 'real', 'guard.sh');
  writeFileSync(leaf, 'echo original\n');
  const scriptRel = 'real/guard.sh';
  const integrityDir = makeTmpDir('hook-integrity-escape-pins-');
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [scriptRel]: gitBlobSha1(readFileSync(leaf)) } }),
  );
  const rawOut = Buffer.concat([Buffer.from('out'), Buffer.from([0xff])]);
  const outReal = Buffer.concat([Buffer.from(`${base}/`), rawOut]);
  fs.mkdirSync(outReal, { recursive: true });
  // outReal/guard.sh -> absolute, valid-UTF-8, back INSIDE the project.
  fs.symlinkSync(leaf, Buffer.concat([outReal, Buffer.from('/guard.sh')]));
  // scripts/hooks -> ../../out<0xff> (relative, non-UTF-8). The link's own
  // LOCATION is inside the project; only its TARGET is outside.
  const target = Buffer.concat([Buffer.from('../../'), rawOut]);
  fs.symlinkSync(target, join(projectDir, 'scripts', 'hooks'));
  const scriptPath = join(projectDir, 'scripts', 'hooks', 'guard.sh');
  const env = { CLAUDE_PROJECT_DIR: projectDir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined };
  const cleanup = () => { for (const d of [base, integrityDir]) rmSync(d, { recursive: true, force: true }); };
  return { fs, base, leaf, scriptRel, scriptPath, env, cleanup };
}

test(
  'HIMMEL-3448: an in-project non-UTF-8 link whose target escapes the project still fails closed',
  { skip: process.platform === 'win32' },
  () => {
    const fx = linkEscapesProjectViaTargetFixture();
    try {
      withEnv(fx.env, () => {
        const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
        assert.equal(result.ok, false);
      });
    } finally {
      fx.cleanup();
    }
  },
);

// (f) round-3 panel finding [codex-1]: the containment test above compared
// realNext only against resolvedProject. A non-UTF-8 link located exactly AT
// the project root — CLAUDE_PROJECT_DIR itself spells a symlink — never
// equals its own resolved TARGET (that is what a symlink is), so a
// resolvedProject-only test always misread it as "above" and let the walk
// continue on the link's lexical spelling. That spelling IS spelledProject,
// so the outer `keys` loop (which checks both roots) still admitted the
// walked identity as in-project — the exact fail-closed ambiguity this
// branch exists to deny. Regression coverage for checking spelledProject too.
function projectRootIsNonUtf8LinkFixture() {
  const fs = require('node:fs');
  const base = makeTmpDir('hook-integrity-rootlink-');
  const rawReal = Buffer.concat([Buffer.from('real'), Buffer.from([0xff])]);
  const realDir = Buffer.concat([Buffer.from(`${base}/`), rawReal]);
  fs.mkdirSync(Buffer.concat([realDir, Buffer.from('/scripts/hooks')]), { recursive: true });
  const leaf = Buffer.concat([realDir, Buffer.from('/scripts/hooks/guard.sh')]);
  writeFileSync(leaf, 'echo original\n');
  const scriptRel = 'scripts/hooks/guard.sh';
  const integrityDir = makeTmpDir('hook-integrity-rootlink-pins-');
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [scriptRel]: gitBlobSha1(readFileSync(leaf)) } }),
  );
  const projectDir = join(base, 'proj'); // clean name; the link IS the project root, not an ancestor above it
  fs.symlinkSync(rawReal, projectDir);
  const scriptPath = join(projectDir, scriptRel);
  const env = { CLAUDE_PROJECT_DIR: projectDir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: undefined };
  const cleanup = () => { for (const d of [base, integrityDir]) rmSync(d, { recursive: true, force: true }); };
  return { fs, base, leaf, scriptRel, scriptPath, env, cleanup };
}

test(
  'HIMMEL-3448: a non-UTF-8 link AT the project root itself still fails closed',
  { skip: process.platform === 'win32' },
  () => {
    const fx = projectRootIsNonUtf8LinkFixture();
    try {
      withEnv(fx.env, () => {
        const result = verifyProjectHookIntegrity(fx.scriptPath, 's1');
        assert.equal(result.ok, false);
      });
    } finally {
      fx.cleanup();
    }
  },
);

// HIMMEL-3384: the bypass is worktree-only and audited. The old "always
// allows" contract is gone — a bypass with no linked worktree around it is no
// bypass at all, and every use that DOES override a deny leaves one audit line.
function withCwd(dir, fn) {
  const saved = process.cwd();
  process.chdir(dir);
  try {
    return fn();
  } finally {
    process.chdir(saved);
  }
}

function gitOk(cwd, ...args) {
  const r = spawnSync('git', ['-c', 'user.email=t@t', '-c', 'user.name=t', ...args], { cwd, encoding: 'utf8' });
  assert.equal(r.status, 0, `git ${args.join(' ')}: ${r.stderr}`);
}

// A primary checkout plus one linked worktree, both holding a TAMPERED guard
// whose session pin is the original. The record has git_dir (the recorded repo
// the bypass validates against) but not the v2 anchor fields, so a mismatch
// always denies rather than re-pinning.
function makeBypassFixture() {
  const root = makeTmpDir('hook-bypass-');
  const primary = join(root, 'primary');
  const worktree = join(root, 'wt');
  const integrityDir = join(root, 'pins');
  const rel = 'scripts/hooks/guard.sh';
  const mkdirp = (p) => require('node:fs').mkdirSync(p, { recursive: true });
  mkdirp(join(primary, 'scripts', 'hooks'));
  mkdirp(integrityDir);
  writeFileSync(join(primary, ...rel.split('/')), 'echo original\n');
  gitOk(primary, 'init', '-q');
  gitOk(primary, 'add', '-A');
  gitOk(primary, 'commit', '-q', '-m', 'init');
  gitOk(primary, 'worktree', 'add', '-q', '-b', 'wt', worktree);
  const pin = gitBlobSha1(readFileSync(join(primary, ...rel.split('/'))));
  writeFileSync(
    join(integrityDir, 's1.json'),
    JSON.stringify({ session_id: 's1', pins: { [rel]: pin }, git_dir: require('node:fs').realpathSync(join(primary, '.git')) }),
  );
  writeFileSync(join(primary, ...rel.split('/')), 'echo tampered\n');
  writeFileSync(join(worktree, ...rel.split('/')), 'echo tampered\n');
  return {
    root,
    primary,
    worktree,
    integrityDir,
    primaryScript: join(primary, ...rel.split('/')),
    worktreeScript: join(worktree, ...rel.split('/')),
    audit: join(primary, '.git', 'hook-integrity-bypass.jsonl'),
  };
}

function bypassEnv(fx, projectDir) {
  return {
    CLAUDE_PROJECT_DIR: projectDir,
    HIMMEL_HOOK_INTEGRITY_DIR: fx.integrityDir,
    HIMMEL_HOOK_INTEGRITY_BYPASS_OK: '1',
  };
}

const auditLines = (file) => (existsSync(file) ? readFileSync(file, 'utf8').split('\n').filter(Boolean) : []);

test('bypass in the PRIMARY checkout is not honoured: a tampered pinned guard is still denied', () => {
  const fx = makeBypassFixture();
  try {
    withEnv(bypassEnv(fx, fx.primary), () => {
      const result = withCwd(fx.primary, () => verifyProjectHookIntegrity(fx.primaryScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass outside any git checkout is not honoured', () => {
  const fx = makeBypassFixture();
  const bare = makeTmpDir('hook-bypass-nogit-');
  try {
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(bare, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
    rmSync(bare, { recursive: true, force: true });
  }
});

test('bypass in a linked worktree allows the worktree guard and appends exactly one audit line', () => {
  const fx = makeBypassFixture();
  try {
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, true);
    });
    const lines = auditLines(fx.audit);
    assert.equal(lines.length, 1);
    const entry = JSON.parse(lines[0]);
    const real = (p) => require('node:fs').realpathSync(p);
    assert.equal(real(entry.worktree), real(fx.worktree));
    assert.equal(real(entry.cwd), real(fx.worktree));
    assert.deepEqual(entry.hook_paths.map(real), [real(fx.worktreeScript)]);
    assert.equal(entry.session_id, 's1');
    assert.ok(!Number.isNaN(Date.parse(entry.ts)), 'ts is an ISO time');
    assert.ok('session' in entry, 'the session-name field is always present (null when unresolvable)');
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass audits only a use that overrides a deny: an untampered guard leaves no line', () => {
  const fx = makeBypassFixture();
  try {
    writeFileSync(fx.worktreeScript, 'echo original\n');
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, true);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass in a linked worktree is not honoured for a hook path outside that worktree', () => {
  const fx = makeBypassFixture();
  try {
    withEnv(bypassEnv(fx, fx.primary), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.primaryScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass is refused when the audit line cannot be written (fail closed)', () => {
  const fx = makeBypassFixture();
  try {
    // A directory where the audit file belongs: appending to it fails for any uid.
    require('node:fs').mkdirSync(fx.audit);
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false);
    });
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

// HIMMEL-3384 (adversarial round): the worktree, the audit sink and "linked" come
// from the SESSION's own project dir and its RECORDED repo — never from `git
// rev-parse` in cwd, which follows a `.git` pointer FILE a worker can rewrite.
const realp = (p) => require('node:fs').realpathSync(p);

test('C1: a forged scripts/.git pointer in the primary checkout does not make it a linked worktree', () => {
  const fx = makeBypassFixture();
  try {
    const sub = join(fx.primary, 'scripts');
    writeFileSync(join(sub, '.git'), `gitdir: ${join(fx.primary, '.git', 'worktrees', 'wt')}\n`);
    withEnv(bypassEnv(fx, fx.primary), () => {
      const result = withCwd(sub, () => verifyProjectHookIntegrity(fx.primaryScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('C2: a rewritten worktree .git pointer cannot move the audit line into a decoy repo', () => {
  const fx = makeBypassFixture();
  const decoy = join(fx.root, 'decoy');
  try {
    require('node:fs').mkdirSync(decoy);
    gitOk(decoy, 'init', '-q');
    writeFileSync(join(decoy, 'f'), 'x\n');
    gitOk(decoy, 'add', '-A');
    gitOk(decoy, 'commit', '-q', '-m', 'init');
    gitOk(decoy, 'worktree', 'add', '-q', '-b', 'dwt', join(fx.root, 'dwt'));
    writeFileSync(join(fx.worktree, '.git'), `gitdir: ${join(decoy, '.git', 'worktrees', 'dwt')}\n`);
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false, 'a worktree whose .git no longer points at the recorded repo is refused');
    });
    assert.deepEqual(auditLines(join(decoy, '.git', 'hook-integrity-bypass.jsonl')), []);
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('C3: a primary-session hook symlinked to a tampered worktree hook is not vouched for', () => {
  if (process.platform === 'win32') return;
  const fx = makeBypassFixture();
  try {
    const fs = require('node:fs');
    fs.unlinkSync(fx.primaryScript);
    fs.symlinkSync(fx.worktreeScript, fx.primaryScript);
    withEnv(bypassEnv(fx, fx.primary), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.primaryScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('I1: a symlinked audit sink is refused, so /dev/null-style sinks cannot swallow the line', () => {
  if (process.platform === 'win32') return;
  const fx = makeBypassFixture();
  const scratch = join(fx.root, 'scratch.log');
  try {
    writeFileSync(scratch, '');
    require('node:fs').symlinkSync(scratch, fx.audit);
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.equal(readFileSync(scratch, 'utf8'), '', 'nothing was written through the link');
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass from a sibling worktree cwd is refused when CLAUDE_PROJECT_DIR is the other worktree', () => {
  const fx = makeBypassFixture();
  try {
    const wt2 = join(fx.root, 'wt2');
    gitOk(fx.primary, 'worktree', 'add', '-q', '-b', 'wt2', wt2);
    const script2 = join(wt2, 'scripts', 'hooks', 'guard.sh');
    writeFileSync(script2, 'echo tampered\n');
    withEnv(bypassEnv(fx, wt2), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(script2, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass is honoured in a linked worktree whose path git C-quotes in `worktree list` (a newline)', { skip: process.platform === 'win32' }, () => {
  const fx = makeBypassFixture();
  try {
    const odd = join(fx.root, 'wt\nq');
    gitOk(fx.primary, 'worktree', 'add', '-q', '-b', 'wt-odd', odd);
    const oddScript = join(odd, 'scripts', 'hooks', 'guard.sh');
    writeFileSync(oddScript, 'echo tampered\n');
    withEnv(bypassEnv(fx, odd), () => {
      const result = withCwd(odd, () => verifyProjectHookIntegrity(oddScript, 's1'));
      assert.equal(result.ok, true);
    });
    assert.equal(auditLines(fx.audit).length, 1);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass is refused for a legacy record with no git_dir (nothing to validate the worktree against)', () => {
  const fx = makeBypassFixture();
  try {
    writeFileSync(
      join(fx.integrityDir, 's1.json'),
      JSON.stringify({ session_id: 's1', pins: { 'scripts/hooks/guard.sh': gitBlobSha1(Buffer.from('echo original\n')) } }),
    );
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass is refused when the recorded repo does not list the project dir as a linked worktree', () => {
  const fx = makeBypassFixture();
  const other = join(fx.root, 'other');
  try {
    require('node:fs').mkdirSync(other);
    gitOk(other, 'init', '-q');
    const rec = JSON.parse(readFileSync(join(fx.integrityDir, 's1.json'), 'utf8'));
    writeFileSync(join(fx.integrityDir, 's1.json'), JSON.stringify({ ...rec, git_dir: join(other, '.git') }));
    withEnv(bypassEnv(fx, fx.worktree), () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, false);
    });
    assert.deepEqual(auditLines(fx.audit), []);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass writes one audit line per honoured hook (the launcher runs once per chain member)', () => {
  const fx = makeBypassFixture();
  try {
    withEnv(bypassEnv(fx, fx.worktree), () => {
      for (let i = 0; i < 2; i += 1) {
        assert.equal(withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1')).ok, true);
      }
    });
    assert.equal(auditLines(fx.audit).length, 2);
  } finally {
    rmSync(fx.root, { recursive: true, force: true });
  }
});

test('bypass audit line carries the session name resolved from CLAUDE_PID (null only when unresolvable)', () => {
  if (!existsSync('/proc/self/cmdline')) return;
  const fx = makeBypassFixture();
  const child = spawn(process.execPath, ['-e', 'setTimeout(()=>{},60000)', '--', '-n', 'n283-test-session'], { stdio: 'ignore' });
  try {
    withEnv({ ...bypassEnv(fx, fx.worktree), CLAUDE_PID: String(child.pid) }, () => {
      const result = withCwd(fx.worktree, () => verifyProjectHookIntegrity(fx.worktreeScript, 's1'));
      assert.equal(result.ok, true);
    });
    const entry = JSON.parse(auditLines(fx.audit)[0]);
    assert.equal(entry.session, 'n283-test-session');
    assert.equal(realp(entry.worktree), realp(fx.worktree));
  } finally {
    child.kill();
    rmSync(fx.root, { recursive: true, force: true });
  }
});
