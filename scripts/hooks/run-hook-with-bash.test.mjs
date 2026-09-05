import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { chmodSync, existsSync, mkdtempSync, readdirSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { dirname, isAbsolute, join } from 'node:path';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const {
  DEFAULT_CHAIN_BUDGET_MS,
  MIN_MEMBER_TIMEOUT_MS,
  MUST_RUN_CHAIN_MEMBERS,
  isKnownBadWindowsBash,
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
  const dir = mkdtempSync(join(tmpdir(), 'hook-bash-zero-byte-'));
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
  const dir = mkdtempSync(join(tmpdir(), 'hook-bash-launcher-'));
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
  const dir = mkdtempSync(join(tmpdir(), 'hook-bash-chain-'));
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

test('MUST_RUN_CHAIN_MEMBERS covers exactly the deny-capable security guards', () => {
  assert.deepEqual(
    [...MUST_RUN_CHAIN_MEMBERS].sort(),
    [
      'block-chokepoint-env-prefix.sh',
      'block-destructive-commands.sh',
      'block-git-stash.sh',
      'block-jira-compound-write.sh',
      'block-read-secrets.sh',
      'block-rogue-claude-schedule.sh',
      'block-tail-pipe-on-gates.sh',
      'check-cr-marker-on-pr-create.sh',
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
// HIMMEL-2047: the wired command is now `if [ -f run-node.sh ]; then . …
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
  for (const key of Object.keys(overrides)) saved[key] = process.env[key];
  Object.assign(process.env, overrides);
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
  const dir = mkdtempSync(join(tmpdir(), 'hook-integrity-'));
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
  const dir = mkdtempSync(join(tmpdir(), 'hook-integrity-'));
  const integrityDir = mkdtempSync(join(tmpdir(), 'hook-integrity-pins-'));
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
    withEnv({ CLAUDE_PROJECT_DIR: dir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir }, () => {
      assert.equal(verifyProjectHookIntegrity(scriptPath, 's1').ok, true);
      writeFileSync(scriptPath, 'echo tampered\n');
      const result = verifyProjectHookIntegrity(scriptPath, 's1');
      assert.equal(result.ok, false);
      assert.equal(result.relPath, scriptRel);
    });
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(integrityDir, { recursive: true, force: true });
  }
});

test('verifyProjectHookIntegrity: HIMMEL_HOOK_INTEGRITY_BYPASS_OK=1 always allows', () => {
  const dir = mkdtempSync(join(tmpdir(), 'hook-integrity-'));
  const integrityDir = mkdtempSync(join(tmpdir(), 'hook-integrity-pins-'));
  try {
    const scriptRel = 'scripts/hooks/guard.sh';
    const scriptPath = join(dir, ...scriptRel.split('/'));
    require('node:fs').mkdirSync(dirname(scriptPath), { recursive: true });
    writeFileSync(scriptPath, 'echo tampered\n');
    writeFileSync(
      join(integrityDir, 's1.json'),
      JSON.stringify({ session_id: 's1', pins: { [scriptRel]: 'deadbeef'.repeat(5) } }),
    );
    withEnv(
      { CLAUDE_PROJECT_DIR: dir, HIMMEL_HOOK_INTEGRITY_DIR: integrityDir, HIMMEL_HOOK_INTEGRITY_BYPASS_OK: '1' },
      () => {
        assert.equal(verifyProjectHookIntegrity(scriptPath, 's1').ok, true);
      },
    );
  } finally {
    rmSync(dir, { recursive: true, force: true });
    rmSync(integrityDir, { recursive: true, force: true });
  }
});
