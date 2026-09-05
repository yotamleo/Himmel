// Spec for the hook-stack benchmark + the HIMMEL-1985 timeout invariant.
//
// Scope (operator, 2026-08-20): pin OUR contract — the report shape the
// re-benchmark recipe in docs/internals/enforcement.md tells a reader to
// diff, and the structural rule that no hook is left on Claude Code's 600s
// default. Claude Code's own hook runner is NOT under test here.

import test from 'node:test';
import assert from 'node:assert/strict';
import { existsSync, readFileSync } from 'node:fs';
import { join, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

import {
  SLO_P95_MS,
  MIN_TIMEOUT_HEADROOM,
  enumerateHooks,
  toolNameFor,
  toolNamesFor,
  payloadFor,
  percentile,
  summarize,
  statusFor,
  labelFor,
  formatReport,
  pluginRootFor,
  benchEnv,
  isFailedRun,
  parseRuns,
  SKIP,
} from './bench-hook-stack.mjs';

const REPO = join(dirname(fileURLToPath(import.meta.url)), '..', '..');
const CONFIGS = [
  join(REPO, '.claude', 'settings.json'),
  join(REPO, 'marketplace', 'plugins', 'himmel-ops', 'hooks', 'hooks.json'),
];

// ---------------------------------------------------------------- enumeration

test('enumerateHooks flattens every command hook with its event, matcher and timeout', () => {
  const rows = enumerateHooks({
    hooks: {
      PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: 'a', timeout: 15 }] }],
      SessionStart: [{ hooks: [{ type: 'command', command: 'b' }] }],
    },
  });
  assert.deepEqual(rows, [
    { event: 'PreToolUse', matcher: 'Bash', command: 'a', timeout: 15 },
    { event: 'SessionStart', matcher: '', command: 'b', timeout: null },
  ]);
});

test('enumerateHooks ignores non-command entries and a missing hooks tree', () => {
  assert.deepEqual(enumerateHooks({}), []);
  assert.deepEqual(
    enumerateHooks({ hooks: { Stop: [{ hooks: [{ type: 'prompt', command: 'x' }] }] } }),
    [],
  );
});

// -------------------------------------------------------------------- payload

test('toolNameFor picks the first literal alternative, defaulting to Bash', () => {
  assert.equal(toolNameFor('Bash|PowerShell'), 'Bash');
  assert.equal(toolNameFor('*'), 'Bash');
  assert.equal(toolNameFor(''), 'Bash');
  assert.equal(toolNameFor('mcp__plugin_atlassian_atlassian__.*'), 'mcp__plugin_atlassian_atlassian__');
  assert.equal(toolNameFor('Agent'), 'Agent');
});

test('toolNamesFor returns EVERY alternative, so a slower branch gets benched too', () => {
  assert.deepEqual(toolNamesFor('Bash|PowerShell|Read|Grep'), ['Bash', 'PowerShell', 'Read', 'Grep']);
  assert.deepEqual(toolNamesFor('Edit|Write|MultiEdit|NotebookEdit'), ['Edit', 'Write', 'MultiEdit', 'NotebookEdit']);
  assert.deepEqual(toolNamesFor('*'), ['Bash']);
  assert.deepEqual(toolNamesFor(''), ['Bash']);
  assert.deepEqual(toolNamesFor('Bash|PowerShell|mcp__.*'), ['Bash', 'PowerShell', 'mcp__']);
});

test('payloadFor carries the event name and a BENIGN command so acting branches stay dormant', () => {
  const pre = payloadFor('PreToolUse', 'Bash', '/repo');
  assert.equal(pre.hook_event_name, 'PreToolUse');
  assert.equal(pre.tool_name, 'Bash');
  assert.equal(pre.tool_input.command, 'echo himmel-hook-bench');

  const post = payloadFor('PostToolUse', 'Agent', '/repo');
  assert.equal(post.tool_response.stdout, 'himmel-hook-bench');
  // Must NOT contain a cap sentinel — that would arm a real resume.
  assert.doesNotMatch(JSON.stringify(post).toLowerCase(), /session limit|usage limit reached/);

  assert.equal(payloadFor('SessionStart', '', '/repo').source, 'startup');
  assert.equal(payloadFor('SessionEnd', '', '/repo').reason, 'clear');
  assert.equal(payloadFor('Stop', '', '/repo').stop_hook_active, false);
});

test('payloadFor shapes tool_input per tool so a hook finds the field it reads', () => {
  // A hook that cannot find its field exits early and the sample understates it.
  assert.equal(payloadFor('PreToolUse', 'Agent', '/repo').tool_input.subagent_type, 'Explore');
  assert.ok(payloadFor('PreToolUse', 'Skill', '/repo').tool_input.skill);
  assert.equal(payloadFor('PreToolUse', 'Grep', '/repo').tool_input.pattern, 'himmel-hook-bench');
  assert.match(payloadFor('PreToolUse', 'Edit|Write', '/repo').tool_input.file_path, /README\.md$/);
});

// ------------------------------------------------------------ containment env

test('benchEnv redirects every write-through hook at the scratch dir', () => {
  const env = benchEnv('/scratch', '/repo');
  assert.equal(env.CLAUDE_PROJECT_DIR, '/repo');
  assert.equal(env.HIMMEL_TRUST_LEDGER_DIR, '/scratch');
  assert.match(env.HIMMEL_SESSION_RUNS_LEDGER, /session-runs\.jsonl$/);
  assert.equal(env.AUTO_ARM_BIN, '/bin/true'); // real check path, neutered arm
  // Every cache/ledger an injector regenerates in place must land in scratch.
  for (const key of ['AUTO_ARM_STATE_DIR', 'WHERE_ARE_WE_STATE_DIR', 'UPDATE_CHECK_STATE_DIR', 'QMD_STALENESS_CACHE_DIR']) {
    assert.match(env[key], /^[\\/]scratch[\\/]/, key);
  }
  assert.equal(env.VOICE_SPEAK, '0');
  assert.equal(env.CLAUDE_PLUGIN_ROOT, undefined);
  assert.equal(benchEnv('/scratch', '/repo', '/plugin').CLAUDE_PLUGIN_ROOT, '/plugin');
});

test('pluginRootFor resolves <plugin>/hooks/hooks.json, and nothing else', () => {
  assert.equal(pluginRootFor('a/b/marketplace/plugins/himmel-ops/hooks/hooks.json'), 'a/b/marketplace/plugins/himmel-ops');
  assert.equal(pluginRootFor('/repo/.claude/settings.json'), null);
});

// ------------------------------------------------------------------ interop

// Canary, not a test of run-hook-with-bash.js: that module is CommonJS and this
// one is ESM, so the seam that can actually break is the createRequire import —
// and if it does, the bench silently falls back to nothing and cannot run.
test('canary: the CJS bash resolver is reachable from this ESM module', () => {
  const { resolveBash } = createRequire(import.meta.url)('./run-hook-with-bash.js');
  assert.equal(typeof resolveBash, 'function');
  assert.ok(resolveBash(), 'no usable bash on this machine');
});

// ------------------------------------------------------------------- statistics

test('percentile uses nearest-rank and tolerates an empty sample', () => {
  assert.equal(percentile([], 95), 0);
  assert.equal(percentile([10], 95), 10);
  assert.equal(percentile([5, 1, 3, 2, 4], 50), 3);
  assert.equal(percentile([1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 95), 10);
});

test('summarize reports the WORST matcher alternative, not a pooled distribution', () => {
  const fast = Array(100).fill(100);
  const slow = [900];
  // Pooled, the slow branch is 1 of 101 samples — under the p95 rank — so p95
  // reads 100ms and a timeout sized off it would not cover that branch at all.
  assert.equal(percentile([...fast, ...slow], 95), 100);
  // Per-branch, the slow one is the answer.
  assert.deepEqual(summarize([fast, slow]), { p50: 900, p95: 900, max: 900 });
  assert.deepEqual(summarize([fast]), { p50: 100, p95: 100, max: 100 });
  assert.deepEqual(summarize([[], []]), { p50: 0, p95: 0, max: 0 });
});

// ----------------------------------------------------------------- classification

test('statusFor flags a failed run, a missing timeout, a tight timeout and an SLO breach', () => {
  assert.equal(statusFor({ skipped: true }), 'skipped');
  assert.equal(statusFor({ timeout: null, p95: 5, failures: 0 }), 'warn:no-timeout');
  // 15s bound, p95 must stay under 15000/3 = 5000ms to be ok.
  assert.equal(statusFor({ timeout: 15, p95: 800, failures: 0 }), 'ok');
  assert.equal(statusFor({ timeout: 15, p95: 6000, failures: 0 }), 'warn:tight');
  // Inside the headroom rule but over the per-hook latency SLO.
  assert.equal(statusFor({ timeout: 60, p95: SLO_P95_MS + 1, failures: 0 }), 'warn:slo');
  // A failed run outranks everything: a missing binary exits in ~0ms and would
  // otherwise be reported as the healthiest hook in the stack.
  assert.equal(statusFor({ timeout: 15, p95: 2, failures: 1 }), 'warn:failed');
});

test('isFailedRun accepts only the two hook OUTCOMES, not every protocol exit', () => {
  assert.equal(isFailedRun({ status: 0 }), false); // allow / continue
  assert.equal(isFailedRun({ status: 2 }), false); // block
  // 1 is a non-blocking ERROR, not an outcome: a missing jq or a script bug
  // lands here in a few ms and must never read as the fastest hook in the stack.
  assert.equal(isFailedRun({ status: 1 }), true);
  assert.equal(isFailedRun({ status: 127 }), true);        // command not found
  assert.equal(isFailedRun({ error: new Error('ENOENT') }), true);
  assert.equal(isFailedRun({ status: null, signal: 'SIGTERM' }), true); // harness timeout
  assert.equal(isFailedRun({ status: null }), true);
  assert.equal(isFailedRun(null), true);
});

test('parseRuns refuses anything that would make the statistics meaningless', () => {
  assert.equal(parseRuns('7'), 7);
  assert.equal(parseRuns(3), 3);
  for (const bad of [undefined, '0', '-1', '2.5', 'abc', '']) {
    assert.throws(() => parseRuns(bad), /--runs needs a positive integer/, `runs=${bad}`);
  }
});

test('labelFor reduces a wrapped hook command to the script it runs', () => {
  assert.equal(
    labelFor('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" "$CLAUDE_PROJECT_DIR/scripts/hooks/block-git-stash.sh"'),
    'block-git-stash.sh',
  );
  // A chain row names every member — the tail token alone would hide the rest.
  assert.equal(
    labelFor('node "$CLAUDE_PROJECT_DIR/scripts/hooks/run-hook-with-bash.js" --chain "$CLAUDE_PROJECT_DIR/scripts/hooks/a.sh" "$CLAUDE_PROJECT_DIR/scripts/hooks/b.sh"'),
    'chain(a.sh+b.sh)',
  );
  assert.equal(labelFor('C:/Users/x/.local/bin/graphify.EXE hook-guard search'), 'graphify.EXE');
  // No script-looking token at all: fall back to the executable, not the args.
  assert.equal(labelFor('/usr/bin/somehook --flag value'), 'somehook');
});

// ---------------------------------------------------------------- report shape

test('formatReport emits the header, one tab-separated row per hook, and a SUMMARY', () => {
  const rows = [
    { event: 'PreToolUse', matcher: 'Bash', command: 'x/a.sh', timeout: 15, skipped: false, failures: 0, p50: 300, p95: 400, max: 500 },
    { event: 'PostToolUse', matcher: 'Bash', command: 'x/trigger-cr-on-push.sh', timeout: 60, skipped: true, failures: 0 },
    { event: 'Stop', matcher: '', command: 'x/c.sh', timeout: null, skipped: false, failures: 0, p50: 1, p95: 2, max: 3 },
  ];
  const lines = formatReport(rows, { settings: '/s.json', runs: 7 }).split('\n');
  assert.match(lines[0], /^hook-stack bench — settings=\/s\.json runs=7 slo_p95_ms=1000$/);
  assert.equal(lines[1], 'EVENT\tTIMEOUT\tP50\tP95\tMAX\tSTATUS\tHOOK');
  assert.equal(lines[2], 'PreToolUse\t15s\t300ms\t400ms\t500ms\tok\ta.sh');
  assert.equal(lines[3], 'PostToolUse\t60s\t-\t-\t-\tskipped\ttrigger-cr-on-push.sh');
  assert.equal(lines[4], 'Stop\t-\t1ms\t2ms\t3ms\twarn:no-timeout\tc.sh');
  // slowest_hook_p95_ms is the MAX across measured p95s, not a percentile.
  assert.equal(lines[5], 'SUMMARY: hooks=3 measured=2 skipped=1 warn=1 no_timeout=1 failed=0 slowest_hook_p95_ms=400');
  assert.equal(lines.length, 6);
});

test('SKIP covers every hook that emits something outbound and irreversible', () => {
  // Locked deliberately: a hook added here silently stops being measured, and a
  // hook missing from here sends a real message on every benchmark run.
  assert.deepEqual([...SKIP].sort(), [
    'jira-nudge-on-end.sh',
    'telegram-notification.sh',
    'telegram-session-end.sh',
    'trigger-cr-on-pr-create.sh',
    'trigger-cr-on-push.sh',
  ]);
});

// Resolve EVERY script a hook command ultimately runs, expanding the two path
// variables the configs use. Plural since HIMMEL-2002: a --chain entry runs
// several scripts from one launcher, and scanning only the tail one would let a
// chained hook reach outbound unscanned. The launcher itself is excluded — it
// is the wrapper, not a guardrail.
function scriptPathsFor(command, pluginRoot) {
  return command.split(/\s+/).filter(Boolean)
    .filter((p) => /\.(sh|mjs|js|ts)"?$/.test(p) && !p.includes('run-hook-with-bash.js'))
    .map((token) => token.replace(/^"|"$/g, '')
      .replace('${CLAUDE_PLUGIN_ROOT}', pluginRoot)
      .replace('$CLAUDE_PROJECT_DIR', REPO));
}

// Markers for an OUTBOUND emission specifically — not for reaching the network
// at all. A READ (`gh api` GET in branch-shipped.sh / ci-green-gate.sh, a plain
// `curl` fetch) is fine to replay; a write is not.
//
// This is a tripwire for the shapes that exist, not a proof of no egress: a
// hook could always reach out through a client nobody listed. It is here to
// make the common case structural instead of remembered, and it is cheap to
// extend when a new client shows up. The general case is a call-graph egress
// analyzer, which is not what a latency benchmark should grow into.
const OUTBOUND_MARKERS = [
  /api\.telegram\.org/,
  // The Telegram relay specifically. NOT a bare scripts/telegram/ match:
  // orchestrator-inline-guard.sh names dispatch-lane.sh in its advisory copy
  // without ever running it, and that is a message about a command, not a send.
  /scripts\/telegram\/session-status\.ts/,
  /cr-trigger-ledger/,     // posts `@coderabbitai review`, dedup keyed per head SHA
  /gh (pr|issue) comment/,
  // Deliberately NOT `gh pr create|merge|...`: this repo's hooks guard those
  // commands rather than run them, so the string is everywhere in guard prose
  // and heredoc advisories (check-cr-marker-on-pr-create.sh, inject-initiative.sh)
  // — measured, both false-positived on it. A marker that cries wolf gets
  // deleted, and then it protects nothing.
  /gh (issue|release|api)[^\n]*(--method|-X) *(POST|PUT|PATCH|DELETE)/,
  // `gh api -f/--field` on a REST endpoint implies POST without naming a
  // method. `gh api graphql -f query=...` is excluded: -f is just how every
  // GraphQL variable is passed, so cr-merge-gate.sh's reviewThreads READ
  // false-positived on it (measured). A graphql WRITE says `mutation`.
  /gh api (?!graphql\b)[^\n]*(-f |--field |--raw-field )/,
  /gh api graphql[^\n]*mutation/,
  // `gh api --input <file>` also defaults to POST.
  /gh api[^\n]*--input /,
  /curl[^\n]*(-X|--request) *(POST|PUT|PATCH|DELETE)/,
  /curl[^\n]*(--data|-d |--form|-F |--upload-file|-T )/,
];

// A hook's own source plus the scripts/lib helpers it names. Hooks reach
// outbound through a lib (trigger-cr-* through cr-trigger-ledger.sh), so the
// scan follows one hop; deeper than that no hook in this repo goes.
// Comment lines are stripped first, and that is load-bearing: a guard hook
// necessarily NAMES the command it guards, so check-cr-marker-on-pr-create.sh's
// header documents `gh pr create` a dozen times without ever running it. Code
// only.
// Line continuations are joined first so a normal multiline
//   curl -sS \
//     --data "$body" ...
// is one line to the markers below; every one of them is single-line by design.
// Comments go FIRST, then continuations: the other order lets a comment ending
// in a backslash swallow the code line under it.
const codeOnly = (text) => text
  .split('\n').filter((l) => !/^\s*#/.test(l)).join('\n')
  .replace(/\\\r?\n\s*/g, ' ');

function sourceOf(script) {
  const body = codeOnly(readFileSync(script, 'utf8'));
  const helpers = [...body.matchAll(/lib\/([a-z0-9-]+\.sh)/g)]
    .map((m) => join(REPO, 'scripts', 'lib', m[1]))
    .filter((p) => existsSync(p));
  return [body, ...helpers.map((p) => codeOnly(readFileSync(p, 'utf8')))].join('\n');
}

// The structural half of SKIP: keeping the denylist correct must not depend on
// whoever adds the next hook remembering that this benchmark exists.
test('no wired hook can emit outbound without being in SKIP', () => {
  let scanned = 0;
  for (const config of CONFIGS) {
    if (!existsSync(config)) continue;
    const pluginRoot = pluginRootFor(config) ?? '';
    for (const hook of enumerateHooks(JSON.parse(readFileSync(config, 'utf8')))) {
      for (const script of scriptPathsFor(hook.command, pluginRoot)) {
        if (!existsSync(script)) continue;
        scanned += 1;
        const body = sourceOf(script);
        if (!OUTBOUND_MARKERS.some((m) => m.test(body))) continue;
        assert.ok(
          SKIP.some((s) => hook.command.includes(s)),
          `${labelFor(hook.command)} can emit outbound but is not in SKIP — benchmarking it would send for real`,
        );
      }
    }
  }
  assert.ok(scanned > 20, `expected to resolve most hook scripts, only scanned ${scanned}`);
});

// ------------------------------------------------- the invariant this ticket buys

// The public mirror 404s .claude/settings.json (PRIVATE_PATHS), so a
// mirror-shaped checkout has nothing to assert against — skip, don't fail.
for (const config of CONFIGS) {
  test(`every command hook in ${config.split(/[\\/]/).slice(-2).join('/')} carries an explicit timeout`, (t) => {
    if (!existsSync(config)) return t.skip('config not present in this checkout');
    const hooks = enumerateHooks(JSON.parse(readFileSync(config, 'utf8')));
    assert.ok(hooks.length > 0, 'expected at least one command hook');
    const untimed = hooks.filter((h) => h.timeout === null).map((h) => labelFor(h.command));
    assert.deepEqual(untimed, [], `left on Claude Code's 600s default: ${untimed.join(', ')}`);
    // The policy is a small closed SET, not a range: 15s fast tier, 60s
    // external-call tier, plus the 10/20/30s bounds that predate HIMMEL-1985
    // and are deliberately grandfathered. A range check would silently bless a
    // 7s or 45s one-off and let the documented tiers rot.
    //
    // 3s is the fail-open ADVISORY-GUARD tier added by HIMMEL-2480: a hook that
    // exits 0 when its tool is absent and whose only job is to nudge is priced
    // to get out of the way, not to finish. Adding the tier here — rather than
    // raising the hook's timeout into an existing one — is the fix for
    // HIMMEL-2496, because raising it would undo exactly the pricing 2480
    // landed. It sits ON the headroom floor asserted below (1000 * 3 / 1000),
    // so it is the smallest tier this policy can ever admit.
    const ALLOWED = [3, 10, 15, 20, 30, 60];
    const outOfBand = hooks.filter((h) => !ALLOWED.includes(h.timeout));
    assert.deepEqual(outOfBand.map((h) => `${labelFor(h.command)}=${h.timeout}s`), []);
    // And the floor still has to clear the headroom rule the SLO implies.
    assert.ok(Math.min(...ALLOWED) >= SLO_P95_MS * MIN_TIMEOUT_HEADROOM / 1000);
  });
}
