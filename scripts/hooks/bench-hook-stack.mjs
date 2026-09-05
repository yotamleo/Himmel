#!/usr/bin/env node
// bench-hook-stack.mjs — measure the Claude-side hook stack's latency so the
// per-hook `timeout` values in .claude/settings.json can be SIZED rather than
// guessed (HIMMEL-1985, follow-up to HIMMEL-1982's Codex-side runner fix).
//
// WHY: Claude Code defaults an unset command-hook timeout to 600s. A wedged
// hook therefore stalls a tool call for ten minutes, and a timed-out PreToolUse
// command hook fails OPEN — the guardrail is silently skipped. Setting a
// timeout is only safe if we know the real p95; a bound that fires under normal
// suite load is worse than 600s. This is the measuring stick.
//
// REPORT-ONLY: no measurement can make it exit non-zero — a slow, wedged,
// unbounded or outright broken hook is reported, never enforced, so this is
// safe to wire anywhere as an advisory. A usage error (bad --runs, unreadable
// or malformed settings file) still exits non-zero; that is a caller mistake,
// not a finding.
//
// Side-effect containment is three-layered, and DELIBERATELY not "run it in a
// clean env" — a hook stripped of PATH/HOME/git config takes an error path in
// milliseconds and the number we measure is a lie:
//   1. BENIGN payload — an `echo`, an empty agent result — so no hook's acting
//      branch is reached (no destructive command to block, no push to trigger
//      on, no cap sentinel to arm from).
//   2. Env REDIRECT for the hooks that write regardless — the trust ledger, the
//      session-runs ledger, the auto-arm state dir + arm binary, and the three
//      cache/ledger dirs the injectors regenerate — all pointed at a scratch dir
//      via each hook's own documented test seam (see benchEnv). Side benefit:
//      a cold cache is the SLOW path, so the measurement stays conservative.
//   3. SKIP for the handful that can emit something OUTBOUND and irreversible
//      (a PR comment, a Telegram message) — see SKIP.
// The hook still inherits the caller's real environment and the real repo as
// cwd, credentials included. That is the point: this measures the stack as the
// session actually runs it. The accepted consequence, stated so the next reader
// does not have to rediscover it: a hook that writes LOCAL state writes it here
// too, exactly as it does on every ordinary tool call — that is in scope by
// design, and layer 2 exists to keep the ones we know about out of real paths.
// What is NOT accepted is anything irreversible or visible to someone else, and
// that is what layer 3 covers. A new hook that emits outbound must be added to
// SKIP — and the suite fails the commit if it is not, so that is a gate, not a
// reminder.
//
// Usage:
//   node scripts/hooks/bench-hook-stack.mjs [--runs N] [--settings PATH]
//
// Re-benchmark recipe + the timeout policy it feeds:
// docs/internals/enforcement.md ("Hook timeout policy").

import { spawnSync } from 'node:child_process';
import { readFileSync, mkdtempSync, rmSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createRequire } from 'node:module';

// The SAME interpreter resolution the wired hooks get. On Windows bare `bash`
// can be the WSL launcher or a 0-byte WindowsApps alias, so measuring through
// it would time a different shell than the one the session actually uses — or
// hang. run-hook-with-bash.js already owns this; do not re-derive it.
const { resolveBash } = createRequire(import.meta.url)('./run-hook-with-bash.js');

// p95 target for a single hook, in ms. Matching ENTRIES run concurrently, so
// the stack's cost is roughly the slowest matching entry, not their sum — but a
// `--chain` entry (HIMMEL-2002) runs its own members serially, so that row's
// p95 is their sum.
export const SLO_P95_MS = 1000;

// A configured timeout must leave this much headroom over measured p95, or the
// bound is close enough to normal latency to fire under load.
export const MIN_TIMEOUT_HEADROOM = 3;

// Hooks that can emit something OUTBOUND and irreversible, which neither a
// benign payload nor an env redirect can take back. Substring match on the
// command string. Every one of these is cheap and detached in production; the
// number we would learn is not worth a real message. Anything added here must
// be justified by an outbound emission, not by "it looked risky".
//
// This list is NOT maintained by remembering to update it:
// bench-hook-stack.test.mjs scans every wired hook's source for outbound-emission
// markers and fails if one is missing here, and the pre-commit gate that runs
// that suite already fires on scripts/hooks/**, .claude/settings.json and the
// plugin hooks.json.
export const SKIP = [
  // Posts an `@coderabbitai review` comment; the dedup ledger is keyed per head
  // SHA, so a replay burns a real trigger slot for that SHA.
  'trigger-cr-on-pr-create.sh',
  'trigger-cr-on-push.sh',
  // detach_run a curl to api.telegram.org — a replay sends real messages.
  'telegram-notification.sh',
  'telegram-session-end.sh',
  'jira-nudge-on-end.sh',
];

// A plugin's hooks.json uses ${CLAUDE_PLUGIN_ROOT} for its own files. The only
// shape that exists is <plugin>/hooks/hooks.json, so the root is two levels up.
export function pluginRootFor(settingsPath) {
  const parts = String(settingsPath).split(/[\\/]/);
  if (parts[parts.length - 1] !== 'hooks.json') return null;
  return parts.slice(0, -2).join('/');
}

// Env overrides that keep the write-through hooks inside a scratch dir.
export function benchEnv(scratchDir, projectDir, pluginRoot) {
  return {
    CLAUDE_PROJECT_DIR: projectDir,
    ...(pluginRoot ? { CLAUDE_PLUGIN_ROOT: pluginRoot } : {}),
    // shadow-ledger.mjs: redirect its append-only trust ledger.
    HIMMEL_TRUST_LEDGER_DIR: scratchDir,
    // session-run-hook.ts: redirect the session-runs JSONL.
    HIMMEL_SESSION_RUNS_LEDGER: join(scratchDir, 'session-runs.jsonl'),
    // auto-arm-on-cap.sh / auto-arm-on-subagent-cap.sh: let the REAL check run
    // (AUTO_ARM_DISABLE would fast-exit and understate it) but neuter the arm —
    // AUTO_ARM_BIN is the documented stub point, CHECK_INTERVAL=0 defeats the
    // 60s throttle so every replay walks the slow path, STATE_DIR keeps the
    // throttle/fired markers out of the real /tmp/claude.
    AUTO_ARM_BIN: '/bin/true',
    AUTO_ARM_CHECK_INTERVAL: '0',
    AUTO_ARM_STATE_DIR: join(scratchDir, 'auto-arm'),
    // inject-where-are-we.sh / refresh-where-are-we-on-end.sh: both regenerate
    // the where-are-we ledger + freshness marker in place.
    WHERE_ARE_WE_STATE_DIR: join(scratchDir, 'where-are-we'),
    // check-update-available.sh: throttle + last-seen-version state.
    UPDATE_CHECK_STATE_DIR: join(scratchDir, 'update-check'),
    // qmd-staleness-notice.sh: staleness-notice cache.
    QMD_STALENESS_CACHE_DIR: join(scratchDir, 'qmd-staleness'),
    // speak-reply.sh: off unless explicitly 1, but be explicit.
    VOICE_SPEAK: '0',
  };
}

// Flatten settings.json's hooks tree into one row per command hook.
export function enumerateHooks(settings) {
  const out = [];
  const tree = (settings && settings.hooks) || {};
  for (const [event, groups] of Object.entries(tree)) {
    if (!Array.isArray(groups)) continue;
    for (const group of groups) {
      for (const hook of (group && group.hooks) || []) {
        if (!hook || hook.type !== 'command' || typeof hook.command !== 'string') continue;
        out.push({
          event,
          matcher: group.matcher ?? '',
          command: hook.command,
          timeout: typeof hook.timeout === 'number' ? hook.timeout : null,
        });
      }
    }
  }
  return out;
}

// The tool names a hook will see. A matcher is a regex alternation
// ('Bash|Grep'), '*', or an mcp__ pattern. Every literal alternative is
// benched, not just the first: a hook that branches by tool (block-read-secrets
// reads .command for Bash and .file_path for Read) has a different cost per
// branch, and a timeout must be sized off the slowest one.
export function toolNamesFor(matcher) {
  const raw = String(matcher || '').trim();
  if (!raw || raw === '*' || raw === '.*') return ['Bash'];
  const names = raw.split('|')
    .map((part) => part.trim().replace(/[^A-Za-z0-9_]/g, ''))
    .filter(Boolean);
  return names.length ? names : ['Bash'];
}

// First alternative — the representative tool for a single payload.
export function toolNameFor(matcher) {
  return toolNamesFor(matcher)[0];
}

// A representative, deliberately BENIGN stdin payload for one event.
export function payloadFor(event, matcher, cwd) {
  const base = {
    session_id: 'bench-hook-stack',
    transcript_path: join(cwd, '.claude', 'bench-hook-stack-transcript.jsonl'),
    cwd,
    hook_event_name: event,
  };
  const tool = toolNameFor(matcher);
  // Shaped per tool, because a hook that cannot find the field it reads exits
  // early and the sample understates it. Covers the tools our matchers name;
  // anything else gets the file shape, which is what the Edit/Write/Read guards
  // read.
  let toolInput;
  if (tool === 'Bash' || tool === 'PowerShell') toolInput = { command: 'echo himmel-hook-bench' };
  else if (tool === 'Agent') toolInput = { description: 'himmel hook bench', prompt: 'himmel hook bench', subagent_type: 'Explore' };
  else if (tool === 'Skill') toolInput = { skill: 'himmel-ops:stuck-playbook' };
  else if (tool === 'Grep' || tool === 'Glob') toolInput = { pattern: 'himmel-hook-bench', path: cwd };
  else if (tool === 'Read') toolInput = { file_path: join(cwd, 'README.md') };
  else {
    // Edit/Write/MultiEdit/NotebookEdit and anything else file-shaped.
    // guard-memory-capture.sh hashes and line-scans `.content // .new_string`,
    // so an edit body has to be here or its scan cost is invisible.
    const body = '- himmel hook bench line one\n- himmel hook bench line two\n';
    toolInput = { file_path: join(cwd, 'README.md'), content: body, old_string: '', new_string: body };
  }
  switch (event) {
    case 'PreToolUse':
    case 'PermissionRequest':
      return { ...base, tool_name: tool, tool_input: toolInput };
    case 'PermissionDenied':
      return { ...base, tool_name: tool, tool_input: toolInput, permission_decision: 'deny' };
    case 'PostToolUse':
      return { ...base, tool_name: tool, tool_input: toolInput, tool_response: { stdout: 'himmel-hook-bench', stderr: '' } };
    case 'PostToolUseFailure':
      // Both shapes: the only hook wired here is shadow-ledger's `postfail`,
      // whose recordOutcome() reads tool_name / tool_input / session_id and
      // neither of these — so fidelity here costs nothing and buys nothing
      // today. It is here so the fixture stays faithful if one is ever wired.
      return { ...base, tool_name: tool, tool_input: toolInput, error: 'himmel-hook-bench', tool_response: { stdout: '', stderr: 'himmel-hook-bench' } };
    case 'SessionStart':
      return { ...base, source: 'startup' };
    case 'SessionEnd':
      return { ...base, reason: 'clear' };
    case 'Stop':
    case 'SubagentStop':
      return { ...base, stop_hook_active: false };
    case 'Notification':
      return { ...base, message: 'himmel-hook-bench' };
    default:
      return base;
  }
}

// Nearest-rank percentile over an unsorted sample.
export function percentile(samples, p) {
  if (!samples.length) return 0;
  const sorted = [...samples].sort((a, b) => a - b);
  const rank = Math.ceil((p / 100) * sorted.length);
  return sorted[Math.min(sorted.length - 1, Math.max(0, rank - 1))];
}

// ok | warn:failed | warn:tight | warn:no-timeout | warn:slo | skipped
export function statusFor(row) {
  if (row.skipped) return 'skipped';
  // Checked FIRST: a hook whose binary is missing, that crashes, or that the
  // harness kills exits in milliseconds. Reported as "fast and healthy" that is
  // exactly backwards, so a failed run invalidates the sample outright.
  if (row.failures) return 'warn:failed';
  if (row.timeout === null) return 'warn:no-timeout';
  if (row.p95 > row.timeout * 1000 / MIN_TIMEOUT_HEADROOM) return 'warn:tight';
  if (row.p95 > SLO_P95_MS) return 'warn:slo';
  return 'ok';
}

// Short label for a hook command: the script it ultimately runs.
export function labelFor(command) {
  const parts = String(command).split(/\s+/).filter(Boolean);
  // A --chain entry (HIMMEL-2002) runs several scripts from ONE launcher, so
  // the tail token would name only the last of them.
  if (parts.includes('--chain')) {
    const members = parts.slice(parts.indexOf('--chain') + 1)
      // Skip further flags (`--lifecycle`, HIMMEL-2003) — only members are named.
      .filter((p) => !p.startsWith('--'))
      .map((p) => p.replace(/^"|"$/g, '').split(/[\\/]/).pop());
    return `chain(${members.join('+')})`;
  }
  // Last script-looking token: hooks are wrapped (`node run-hook-with-bash.js
  // <target>.sh`), so the target is the tail, not the head. Falls back to the
  // executable itself for a bare binary invocation (graphify.EXE hook-guard).
  const script = [...parts].reverse().find((p) => /\.(sh|mjs|js|ts|EXE|exe)"?$/.test(p));
  const chosen = (script || parts[0] || command).replace(/^"|"$/g, '');
  return chosen.split(/[\\/]/).pop();
}

export function formatReport(rows, meta) {
  const lines = [];
  lines.push(`hook-stack bench — settings=${meta.settings} runs=${meta.runs} slo_p95_ms=${SLO_P95_MS}`);
  lines.push(['EVENT', 'TIMEOUT', 'P50', 'P95', 'MAX', 'STATUS', 'HOOK'].join('\t'));
  for (const row of rows) {
    lines.push([
      row.event,
      row.timeout === null ? '-' : `${row.timeout}s`,
      row.skipped ? '-' : `${row.p50}ms`,
      row.skipped ? '-' : `${row.p95}ms`,
      row.skipped ? '-' : `${row.max}ms`,
      statusFor(row),
      labelFor(row.command),
    ].join('\t'));
  }
  const counted = rows.filter((r) => !r.skipped);
  const warn = rows.filter((r) => statusFor(r).startsWith('warn')).length;
  // NOT a chain p95: the runner fires matching hooks concurrently, so what the
  // session actually waits on is the SLOWEST matching hook. Reporting a
  // percentile across per-hook p95s would discard exactly that hook.
  const slowest = counted.length ? Math.max(...counted.map((r) => r.p95)) : 0;
  lines.push(`SUMMARY: hooks=${rows.length} measured=${counted.length} skipped=${rows.length - counted.length} warn=${warn} no_timeout=${rows.filter((r) => r.timeout === null).length} failed=${rows.filter((r) => r.failures).length} slowest_hook_p95_ms=${slowest}`);
  return lines.join('\n');
}

// Only 0 (allow/continue) and 2 (block) are hook outcomes. Claude Code treats
// every OTHER exit as a non-blocking ERROR and shows stderr to the user — which
// is precisely the "broken hook" case, and it is also where a missing `jq`, an
// unparseable payload or a script bug lands, all of them in a few ms. Accepting
// 1 here would report exactly those as the fastest, healthiest hooks in the
// stack. (Empirically the whole live stack runs at failed=0 under this rule.)
export function isFailedRun(result) {
  if (!result || result.error) return true;
  if (result.signal) return true;
  return result.status !== 0 && result.status !== 2;
}

// Per-branch percentiles, then the WORST branch — not one pooled distribution.
// Pooling hides a slow alternative whose samples are under 5% of the total,
// which is exactly the branch a timeout has to cover.
export function summarize(groups) {
  const nonEmpty = groups.filter((g) => g.length);
  if (!nonEmpty.length) return { p50: 0, p95: 0, max: 0 };
  return {
    p50: Math.max(...nonEmpty.map((g) => percentile(g, 50))),
    p95: Math.max(...nonEmpty.map((g) => percentile(g, 95))),
    max: Math.max(...nonEmpty.flat()),
  };
}

export function benchOne(hook, { runs, cwd, env, bash }) {
  if (SKIP.some((s) => hook.command.includes(s))) {
    return { ...hook, skipped: true, samples: [], failures: 0 };
  }
  const groups = [];
  const samples = [];
  let failures = 0;
  for (const tool of toolNamesFor(hook.matcher)) {
    const input = JSON.stringify(payloadFor(hook.event, tool, cwd)) + '\n';
    const group = [];
    groups.push(group);
    for (let i = 0; i < runs; i += 1) {
      const started = process.hrtime.bigint();
      const result = spawnSync(bash, ['-c', hook.command], {
        input,
        cwd,
        env: { ...process.env, ...env },
        encoding: 'utf8',
        timeout: 60_000,
      });
      if (isFailedRun(result)) failures += 1;
      const elapsed = Number((process.hrtime.bigint() - started) / 1_000_000n);
      group.push(elapsed);
      samples.push(elapsed);
    }
  }
  return { ...hook, skipped: false, samples, failures, ...summarize(groups) };
}

// Throws on anything that would produce meaningless statistics (0 runs gives
// -Infinity maxima, a fractional count silently truncates).
export function parseRuns(value) {
  const runs = Number(value);
  if (!Number.isInteger(runs) || runs < 1) {
    throw new Error(`--runs needs a positive integer, got: ${value === undefined ? '(missing)' : value}`);
  }
  return runs;
}

function main(argv) {
  let runs = 5;
  let settingsPath = null;
  // Consume values, and refuse anything unrecognised: a mistyped flag that
  // silently benchmarks the default config is a wrong answer wearing a right
  // one's clothes.
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === '--runs') { runs = parseRuns(argv[i + 1]); i += 1; continue; }
    if (argv[i] === '--settings') {
      settingsPath = argv[i + 1];
      if (!settingsPath) throw new Error('--settings needs a path');
      i += 1;
      continue;
    }
    throw new Error(`unknown argument: ${argv[i]} (usage: bench-hook-stack.mjs [--runs N] [--settings PATH])`);
  }
  const cwd = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  settingsPath = settingsPath || join(cwd, '.claude', 'settings.json');
  const settings = JSON.parse(readFileSync(settingsPath, 'utf8'));
  const bash = resolveBash();
  if (!bash) throw new Error('no usable bash found (same resolver the wired hooks use) — cannot measure');
  const scratch = mkdtempSync(join(tmpdir(), 'hook-bench-'));
  try {
    const env = benchEnv(scratch, cwd, pluginRootFor(settingsPath));
    const rows = enumerateHooks(settings).map((h) => benchOne(h, { runs, cwd, env, bash }));
    process.stdout.write(formatReport(rows, { settings: settingsPath, runs }) + '\n');
  } finally {
    rmSync(scratch, { recursive: true, force: true });
  }
  return 0; // no measurement, however bad, changes this
}

if (process.argv[1] && fileURLToPath(import.meta.url) === process.argv[1]) {
  process.exit(main(process.argv.slice(2)));
}
