#!/usr/bin/env node
// Resolve the Bash interpreter for Claude Code hooks before running the hook.
// On Windows, bare `bash` can resolve to the WSL launcher or the 0-byte
// WindowsApps alias instead of Git Bash. This launcher selects a concrete,
// usable executable and fails closed when none exists. Node is intentionally
// required before the hook starts: if Node is missing, the launcher blocks the
// action rather than risking a guard script failing open under another shell.
'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
// Directory-relative on purpose: the canonical launcher gets
// scripts/hooks/hook-integrity.js and the vendored plugin copy gets
// marketplace/plugins/himmel-ops/hooks/hook-integrity.js. Both copies of that
// module are byte-identical (test-plugin-hook-bash-wiring.sh proves it).
const {
  denyIntegrityMismatch,
  gitBlobSha1,
  hookIntegrityDir,
  loadIntegrityRecord,
  verifyProjectHookIntegrity,
} = require('./hook-integrity.js');

function normalize(candidate) {
  return String(candidate || '').replace(/\\/g, '/').replace(/\/+$/, '');
}

function isKnownBadWindowsBash(candidate) {
  const low = normalize(candidate).toLowerCase();
  return low.includes('/windows/system32/bash.exe') ||
    low.includes('/windows/sysnative/bash.exe') ||
    low.includes('/windowsapps/bash.exe');
}

function isUsable(candidate, platform = process.platform) {
  if (!candidate || (platform === 'win32' && isKnownBadWindowsBash(candidate))) return false;
  try {
    const stat = fs.statSync(candidate);
    if (!stat.isFile()) return false;
    // Windows App Execution Aliases are 0-byte reparse points. Refuse any
    // zero-byte candidate even if it appears outside the usual WindowsApps dir.
    if (platform === 'win32' && stat.size === 0) return false;
    if (platform !== 'win32') fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch (_e) {
    return false;
  }
}

function windowsCandidates(env) {
  const p = path.win32;
  const candidates = [];
  const addRoot = (root) => {
    if (!root) return;
    candidates.push(p.join(root, 'Git', 'bin', 'bash.exe'));
    candidates.push(p.join(root, 'Git', 'usr', 'bin', 'bash.exe'));
  };

  addRoot(env.ProgramFiles);
  addRoot(env['ProgramFiles(x86)']);
  if (env.LOCALAPPDATA) addRoot(p.join(env.LOCALAPPDATA, 'Programs'));
  // Keep canonical locations even when a non-Windows test or stripped process
  // environment omits ProgramFiles.
  addRoot('C:\\Program Files');
  addRoot('C:\\Program Files (x86)');

  const pathDirs = String(env.PATH || env.Path || '').split(';').filter(Boolean);
  for (const dir of pathDirs) {
    const base = p.basename(dir).toLowerCase();
    let gitRoot = null;
    if (base === 'bin' && p.basename(p.dirname(dir)).toLowerCase() === 'usr') gitRoot = p.dirname(p.dirname(dir));
    else if (base === 'cmd' || base === 'bin') gitRoot = p.dirname(dir);
    if (gitRoot) {
      candidates.push(p.join(gitRoot, 'bin', 'bash.exe'));
      candidates.push(p.join(gitRoot, 'usr', 'bin', 'bash.exe'));
    }
    candidates.push(p.join(dir, 'bash.exe'));
    candidates.push(p.join(dir, 'bash'));
  }
  return candidates;
}

function posixCandidates(env) {
  const candidates = [];
  for (const dir of String(env.PATH || '').split(path.posix.delimiter).filter(Boolean)) {
    candidates.push(path.posix.join(dir, 'bash'));
  }
  candidates.push('/bin/bash', '/usr/bin/bash');
  return candidates;
}

function resolveBash(options = {}) {
  const platform = options.platform || process.platform;
  const env = options.env || process.env;
  const usable = options.isUsable || ((candidate) => isUsable(candidate, platform));
  const candidates = platform === 'win32' ? windowsCandidates(env) : posixCandidates(env);
  const seen = new Set();
  for (const candidate of candidates) {
    const key = normalize(candidate).toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    if (usable(candidate)) return normalize(candidate);
  }
  return null;
}

// Hook-integrity verification (HIMMEL-1666 rewrite fence, HIMMEL-2528 re-pin)
// lives in ./hook-integrity.js, required above — see that file's header for the
// full mechanism, the fail-open cases, and the honest residuals.
function parseHookArgs(argv) {
  let optional = false;
  let failClosedWhen = null;
  let chain = false;
  let lifecycle = false;
  let index = 0;

  while (index < argv.length && argv[index].startsWith('--')) {
    if (argv[index] === '--chain') {
      chain = true;
      index += 1;
      continue;
    }
    if (argv[index] === '--lifecycle') {
      lifecycle = true;
      index += 1;
      continue;
    }
    if (argv[index] === '--optional') {
      optional = true;
      index += 1;
      continue;
    }
    if (argv[index] === '--fail-closed-when') {
      const condition = argv[index + 1] || '';
      const match = condition.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
      if (!match) throw new Error('--fail-closed-when requires NAME=VALUE');
      failClosedWhen = { name: match[1], value: match[2], display: condition };
      index += 2;
      continue;
    }
    throw new Error(`unknown option: ${argv[index]}`);
  }

  const hookArgs = argv.slice(index);
  if (hookArgs.length === 0) throw new Error('missing hook script path');
  if (failClosedWhen && !optional) throw new Error('--fail-closed-when requires --optional');
  // --chain owns every remaining argument as a chain MEMBER, so there is no
  // room left for the single-script options' semantics (extra hook args, an
  // absent-script carve-out). Refusing the combination is cheaper than
  // inventing a meaning for it.
  if (chain && (optional || failClosedWhen)) {
    throw new Error('--chain cannot be combined with --optional/--fail-closed-when');
  }
  // --lifecycle only changes how a CHAIN combines its members' output; on a lone
  // hook the launcher already passes stdout/stderr straight through.
  if (lifecycle && !chain) throw new Error('--lifecycle requires --chain');
  return { hookArgs, optional, failClosedWhen, chain, lifecycle };
}

// ---------------------------------------------------------------- chain mode
//
// HIMMEL-2002. Claude Code launches one command hook per settings.json entry,
// and each of ours is a node + Git Bash pair; a Bash tool call matched 13 of
// them, 11 of those through this launcher. Process launches pin kernel pool
// objects (HIMMEL-1993), so the launch COUNT is the lever: `--chain a.sh b.sh
// ...` runs the same guardrails, in the same order, from ONE node process.
// Scope of the win, stated plainly: the N-1 NODE launches go away; the members
// stay one Git Bash each, deliberately (no extra wrapper shell). Twin of the
// Codex-side dispatcher in
// .codex/codex-hook-adapter.sh (HIMMEL-1989); same invariants: whole-chain
// validation before any member runs, first deny short-circuits, and the one
// side-effecting hook (auto-arm-on-cap.sh) stays OUT of every chain.

// Claude Code reads our stdout as ONE JSON object (or nothing). These are the
// keys a chain knows how to combine; anything else is dropped with a warning
// rather than silently mis-merged.
const MERGEABLE_TOP_KEYS = new Set(['hookSpecificOutput', 'systemMessage', 'continue', 'stopReason']);
const MERGEABLE_HOOK_KEYS = new Set(['hookEventName', 'permissionDecision', 'permissionDecisionReason', 'additionalContext']);

// Per-MEMBER bound (HIMMEL-2002). The settings entry's own `timeout` now bounds
// the whole chain, so without this one hung member could burn the shared budget
// and have Claude Code kill the entry with the later security guards never run —
// and a PreToolUse timeout fails OPEN, so they would be skipped silently. 15 s is
// not a new number: it is the fast-guard tier these members each carried as their
// own settings entry, restored per member. Env override for slow boxes and for
// the suite, which cannot afford to wait out the real bound.
const DEFAULT_MEMBER_TIMEOUT_MS = 15_000;

// ...but N members at the full per-member bound can outlast the ENTRY's own
// timeout (ten × 15 s against a 60 s entry), and blowing that budget is the very
// thing the per-member bound exists to prevent: Claude Code kills the entry and
// the untried tail is skipped SILENTLY. So the chain also carries a whole-run
// budget and hands each member the smaller of its own bound and what is left —
// the same clamp critic-panel.sh applies to its members (HIMMEL-1280). Every
// skip is then reported by US, and the launcher still reaches its merge/emit
// path. Set just inside the 60 s entry timeout the multi-member chains carry.
const DEFAULT_CHAIN_BUDGET_MS = 50_000;

// ...and a member is never clamped below this, even by a fully spent budget. A
// clamp with no floor kills the tail after ~0ms — technically "reported", but
// no guard ever gets to decide, which is the starvation the clamp exists to
// bound rather than to cause. The floor is affordable BY CONSTRUCTION: the
// worst case is budget + members x floor, so the 10-member Bash chain tops out
// at 50s + 10x0.5s = 55s, still inside its 60s entry timeout. 500ms is also
// past the ~210ms per-member p95, so a floored member usually still finishes.
const MIN_MEMBER_TIMEOUT_MS = 500;

// A chained member's output is BUFFERED (we parse it as a decision), where a
// lone hook keeps `stdio: 'inherit'` and streams with no ceiling at all. The
// spawnSync default is 1 MiB and surfaces overflow as an `ENOBUFS` error, so
// without an explicit, generous ceiling AND the skip handling below, a chatty
// hook would DENY the tool call. 16 MiB is far past anything a guardrail that
// prints a refusal message emits.
const MEMBER_MAX_BUFFER = 16 * 1024 * 1024;

// HIMMEL-2060. Under load the shared chain budget above can starve a LATE
// member down to the MIN_MEMBER_TIMEOUT_MS floor, and the launcher's response
// to that was uniform: skip it, note it on stderr, keep going. Fine for an
// advisory nudge (require-quiet-run.sh already fails open by design) — wrong
// for a security fence: a starved block-read-secrets.sh means the secret read
// it exists to catch just runs. Those members must FAIL CLOSED on a starved
// budget instead of being silently skipped.
//
// Keyed by BASENAME here rather than an inline `--must-run` marker inside the
// .claude/settings.json chain command string (the other shape this ticket
// considered): wire-hook-bash.mjs's classifyCommand() parses that exact
// command string with a frozen regex to police the owned-hook inventory
// (HIMMEL-1552/HIMMEL-2002) — teaching it a new inline token is a second,
// riskier change to a security-reviewed chokepoint for a property that is
// pure LAUNCHER execution policy, not wiring. A basename set here is legible
// next to the members it governs, needs no wire-hook-bash.mjs change, and
// still lets any future chain (PreToolUse Bash *and* PowerShell both wire
// these same guardrails) pick it up for free.
const MUST_RUN_CHAIN_MEMBERS = new Set([
  'block-read-secrets.sh',
  'block-destructive-commands.sh',
  'block-git-stash.sh',
  'block-rogue-claude-schedule.sh',
  'block-chokepoint-env-prefix.sh',
  'block-jira-compound-write.sh',
  'block-tail-pipe-on-gates.sh',
  'check-cr-marker-on-pr-create.sh',
  // HIMMEL-2526's destination-write fence, landing in a sibling PR. This set is
  // BASENAME-keyed and is consulted only when a member with that basename has
  // been starved of budget, so naming a file that does not exist yet is inert:
  // nothing looks the entry up until that hook is actually wired into a chain.
  'block-write-into-main-checkout.sh',
]);

function envMs(name, fallback) {
  const raw = Number(process.env[name]);
  return Number.isFinite(raw) && raw > 0 ? raw : fallback;
}

function memberTimeoutMs() {
  return envMs('RUN_HOOK_CHAIN_MEMBER_TIMEOUT_MS', DEFAULT_MEMBER_TIMEOUT_MS);
}

function chainBudgetMs() {
  return envMs('RUN_HOOK_CHAIN_BUDGET_MS', DEFAULT_CHAIN_BUDGET_MS);
}

// Durable record of every starved member (HIMMEL-2060) — the stderr line
// below is one line for a reason (session-context noise), so the detail
// (which member, how starved, for which tool call) has to live somewhere a
// human can later ask "how often is this happening". RUN_HOOK_CHAIN_SKIP_LOG
// overrides the path for the test suite; the default sits next to the
// project's own tree so it travels with the checkout that produced it and a
// stale worktree's log never mixes with another's.
function skipLogPath() {
  if (process.env.RUN_HOOK_CHAIN_SKIP_LOG) return process.env.RUN_HOOK_CHAIN_SKIP_LOG;
  const projectDir = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  return path.join(projectDir, '.claude', 'logs', 'hook-chain-skips.jsonl');
}

// Best-effort: a log write failing must never change the chain's allow/deny
// decision — this is observability, not policy, so any error here is swallowed
// (never thrown), but noted on stderr once so a permissions/disk issue isn't
// completely invisible (HIMMEL-2060 CR round 1, codex-3).
function logChainSkip(row) {
  try {
    const file = skipLogPath();
    fs.mkdirSync(path.dirname(file), { recursive: true });
    fs.appendFileSync(file, `${JSON.stringify(row)}\n`);
  } catch (e) {
    process.stderr.write(`run-hook-with-bash: could not write ${skipLogPath()} (${e.message})\n`);
  }
}

// Same shape-based secret redaction as scripts/hooks/stop-queue.mjs's
// redactSecrets/NAMED_SECRET_ASSIGNMENT (HIMMEL-2060 CR round 1, codex-1): the
// tool call a starved guard never evaluated can BE a secret read
// (block-read-secrets.sh is itself must-run-able), so its raw command text
// must not land verbatim in a durable log. Duplicated rather than imported —
// stop-queue.mjs is ESM and this launcher is CommonJS, so a cross-module
// require() is not portable here, and extracting a shared lib is out of this
// ticket's scope for a 4-line regex chain.
const SECRET_NAME_SHAPES = 'TOKEN|SECRET|KEY|PASSWORD|PASSWD|CREDENTIAL|COOKIE|AUTH|CHAT_ID|DSN|_URL|CONNECTION|PRIVATE|CERT|BEARER|SIGNATURE|SESSION_ID';
const NAMED_SECRET_ASSIGNMENT = new RegExp(
  `([A-Za-z0-9_]*(?:${SECRET_NAME_SHAPES})[A-Za-z0-9_]*\\s*[=:]\\s*)\\S+`, 'gi',
);
// ponytail: shape-based, so an unnamed or multi-word credential (e.g.
// `curl -u user:pass`, a quoted passphrase with spaces) still gets through —
// same ceiling stop-queue.mjs's copy documents, and the same call: a tripwire
// for the shapes that actually occur (name=value, Bearer/Basic/Token headers,
// GH/Slack tokens, long opaque strings), not a proof no secret can leak.
// Closing that fully means a real secret scanner (gitleaks already is one),
// not more regexes bolted onto a chain-skip logger (HIMMEL-2060 CR round 3,
// codex-1).
function redactSecrets(text) {
  return String(text)
    // HIMMEL-2060 CR round 2 (codex-1): an `Authorization: Bearer <token>`
    // header has the credential in a SEPARATE word after the scheme, so
    // NAMED_SECRET_ASSIGNMENT below — which only redacts the single \S+ run
    // right after "Authorization[=:]" (the scheme word itself) — leaves the
    // actual token untouched. Catch the scheme+credential pair first, before
    // that pass can consume the scheme word and remove the anchor this needs.
    .replace(/\b(Bearer|Basic|Token)\s+\S+/gi, '$1 <redacted>')
    // curl-style basic auth (HIMMEL-2060 CR round 4, codex-1): `-u user:pass`
    // and URL userinfo (`https://user:pass@host`) carry a credential outside
    // every other pattern's shape. Boundary is start-of-string/whitespace/
    // quote, not just whitespace — a real command usually has the flag
    // sitting right inside a quoted string (`"-u user:pass"`).
    .replace(/(^|[\s"'])(-u|--user)(\s+)\S+/gi, '$1$2$3<redacted>')
    .replace(/(https?:\/\/)[^\s/@]+:[^\s/@]+(@)/gi, '$1<redacted>$2')
    .replace(NAMED_SECRET_ASSIGNMENT, '$1<redacted>')
    .replace(/(https?:\/\/[^\s/]*\/bot)[^\s/]+/gi, '$1<redacted>')
    .replace(/\b(?:gh[pousr]|xox[baprs])_[A-Za-z0-9_-]{10,}/g, '<redacted>')
    .replace(/\b[A-Za-z0-9_-]{40,}\b/g, '<redacted>');
}

// A short, greppable stand-in for the tool call a starved guard never saw —
// capped at 120 chars so one runaway command can't bloat the JSONL row.
function toolCallSummary(hookInput) {
  if (!hookInput || typeof hookInput !== 'object') return '';
  const name = typeof hookInput.tool_name === 'string' ? hookInput.tool_name : '';
  const ti = hookInput.tool_input && typeof hookInput.tool_input === 'object' ? hookInput.tool_input : {};
  const detail = ti.command || ti.cmd || ti.file_path || '';
  const summary = redactSecrets(`${name} ${detail}`.trim());
  return summary.length > 120 ? `${summary.slice(0, 117)}...` : summary;
}

function parseJsonObject(text) {
  if (!String(text).trim()) return null;
  try {
    const value = JSON.parse(text);
    return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
  } catch (_e) {
    return null;
  }
}

// Both spellings of "block this call". The legacy top-level `decision: "block"`
// is not one our hooks emit today, but it IS valid PreToolUse output — and the
// merge allowlist would drop it, so a member blocking that way could have had
// another member's `allow` win. A refusal silently becoming an allow is the one
// failure this chain must not have, so recognise it HERE, where it
// short-circuits and is passed through verbatim, rather than trusting that no
// future hook uses the documented form.
function isDeny(output) {
  if (!output) return false;
  if (output.decision === 'block') return true;
  return Boolean(output.hookSpecificOutput) && output.hookSpecificOutput.permissionDecision === 'deny';
}

// Combine the JSON decisions several chain members emitted. `deny` never
// reaches here (it short-circuits the chain), so the decision lattice is just
// ask > allow. onDrop(key, source) is called for every key this cannot merge.
function mergeHookOutputs(items, onDrop = () => {}) {
  const hookOutput = {};
  const reasons = [];
  const contexts = [];
  const messages = [];
  let decision = null;
  let halted = false;
  let stopReason = null;

  for (const { source, output } of items) {
    for (const key of Object.keys(output)) {
      if (!MERGEABLE_TOP_KEYS.has(key)) onDrop(key, source);
    }
    if (output.continue === false) halted = true;
    if (typeof output.stopReason === 'string' && output.stopReason) stopReason = output.stopReason;
    if (typeof output.systemMessage === 'string' && output.systemMessage) messages.push(output.systemMessage);

    const specific = output.hookSpecificOutput;
    if (!specific || typeof specific !== 'object') continue;
    for (const key of Object.keys(specific)) {
      if (!MERGEABLE_HOOK_KEYS.has(key)) onDrop(`hookSpecificOutput.${key}`, source);
    }
    if (!hookOutput.hookEventName && typeof specific.hookEventName === 'string') {
      hookOutput.hookEventName = specific.hookEventName;
    }
    if (specific.permissionDecision === 'ask') decision = 'ask';
    else if (specific.permissionDecision === 'allow' && decision !== 'ask') decision = 'allow';
    if (typeof specific.permissionDecisionReason === 'string' && specific.permissionDecisionReason) {
      reasons.push(specific.permissionDecisionReason);
    }
    if (typeof specific.additionalContext === 'string' && specific.additionalContext) {
      contexts.push(specific.additionalContext);
    }
  }

  if (decision) hookOutput.permissionDecision = decision;
  if (reasons.length) hookOutput.permissionDecisionReason = reasons.join(' | ');
  if (contexts.length) hookOutput.additionalContext = contexts.join('\n');

  const merged = {};
  if (Object.keys(hookOutput).length) merged.hookSpecificOutput = hookOutput;
  if (messages.length) merged.systemMessage = messages.join('\n');
  if (halted) merged.continue = false;
  if (stopReason !== null) merged.stopReason = stopReason;
  return merged;
}

function readAllStdin() {
  try {
    return fs.readFileSync(0, 'utf8');
  } catch (_e) {
    return '';
  }
}

// HIMMEL-2557: spawnSync surfaces EPIPE on the parent's stdin WRITE when the
// child exits before draining it (a guard that returns on its first line, or
// the write racing the child's exit under load — 2d687f9c, main red
// 2026-09-12). The child still ran to completion, so its own status/stdout/
// stderr are the real verdict; only a numeric status proves it actually
// exited — EPIPE with a null status stays fail-closed like any other error.
function isRecoverableEpipe(result) {
  return Boolean(result.error) && result.error.code === 'EPIPE' && typeof result.status === 'number';
}

// Returns the exit code rather than calling process.exit(): on Windows a pipe
// stdout is ASYNC, so exiting immediately after a write can truncate the very
// JSON decision this exists to deliver. The caller sets process.exitCode and
// lets node drain and exit on its own.
function runChain(members, lifecycle = false) {
  // Validate the WHOLE chain before running any of it: a typo'd or duplicated
  // member must deny outright, never run a prefix of the chain.
  const seen = new Set();
  for (const member of members) {
    if (seen.has(member)) {
      process.stderr.write(`run-hook-with-bash: duplicate chain member ${member}; refusing to run chain\n`);
      return 2;
    }
    seen.add(member);
    let stat = null;
    try {
      stat = fs.statSync(member);
    } catch (_e) {
      stat = null;
    }
    if (!stat || !stat.isFile()) {
      process.stderr.write(`run-hook-with-bash: chain member not found: ${member}; refusing to run chain\n`);
      return 2;
    }
  }

  const bash = resolveBash();
  if (!bash) {
    process.stderr.write('run-hook-with-bash: no usable Bash interpreter found; refusing to run hook\n');
    return 2;
  }

  // Read once, fan the same payload to every member — each sees the full hook
  // JSON exactly as it would as its own entry.
  const input = readAllStdin();
  // Parsed once for the skip/deny log rows below (HIMMEL-2060) — never for
  // chain decisions, which stay per-member exactly as before.
  const hookInput = parseJsonObject(input);
  const sessionId = hookInput && typeof hookInput.session_id === 'string' ? hookInput.session_id : null;

  // HIMMEL-2003. `--lifecycle` chains a SessionStart-class event, where hooks are
  // ADVISORY: Claude injects a hook's plain stdout as context and there is no
  // permission gate, so the PreToolUse rules below (one JSON object or nothing,
  // deny short-circuits, plain stdout diverted to stderr) are all wrong here.
  // Instead: concatenate every member's stdout, forward every member's stderr,
  // and always exit 0 — one broken advisory must never silence the rest of the
  // chain or colour the session's startup. Whole-chain validation above still
  // fails closed, so a stale checkout is loud rather than silently degraded.
  // No JSON merging: a member emitting a hookSpecificOutput envelope would be
  // concatenated as text like any other body (none does today).
  if (lifecycle) {
    // Same per-member clamp and buffer ceiling the PreToolUse chain carries: an
    // advisory that hangs would otherwise burn the ENTRY's timeout and have
    // Claude Code kill the whole chain, silently losing every later notice.
    const lifecycleDeadline = Date.now() + chainBudgetMs();
    for (const member of members) {
      // HIMMEL-1666: advisory-lane rewrite protection is symmetric with the
      // must-run lane below — a tampered lifecycle member is skipped (not
      // fatal, matching this loop's existing advisory contract) rather than
      // silently run.
      const integrity = verifyProjectHookIntegrity(member, sessionId);
      if (!integrity.ok) {
        denyIntegrityMismatch(member, integrity.relPath, integrity.reason);
        continue;
      }
      const bound = Math.max(MIN_MEMBER_TIMEOUT_MS, Math.min(memberTimeoutMs(), lifecycleDeadline - Date.now()));
      const memberStart = Date.now();
      const result = spawnSync(bash, [member], {
        input,
        env: process.env,
        encoding: 'utf8',
        timeout: bound,
        killSignal: 'SIGKILL',
        maxBuffer: MEMBER_MAX_BUFFER,
        windowsHide: true,   // HIMMEL-2043: no console flash per hook call
      });
      if (result.error) {
        // Advisory: a member that hung, flooded, or failed to start is dropped
        // with a note and the chain continues — never a nonzero exit. No
        // must-run concept here: a --lifecycle chain is advisory BY DEFINITION
        // (HIMMEL-2003, always exits 0), so nothing on it can fail closed.
        const basename = path.basename(member);
        const elapsed = Date.now() - memberStart;
        // HIMMEL-2060 CR round 3 (codex-3): only ETIMEDOUT/ENOBUFS are budget
        // starvation — the thing this durable log is FOR. A launch failure
        // (missing/unexecutable hook, e.g. ENOENT/EACCES) is a different
        // problem and must not be counted alongside real skips, or the C22
        // doctor advisory misreads a broken hook as budget pressure. Mirrors
        // the ETIMEDOUT/ENOBUFS gate the non-lifecycle chain below already has.
        if (result.error.code === 'ETIMEDOUT' || result.error.code === 'ENOBUFS') {
          logChainSkip({
            ts: new Date().toISOString(),
            action: 'skip',
            member: basename,
            budget: bound,
            elapsed,
            reason: result.error.code,
            sessionId,
            toolCall: toolCallSummary(hookInput),
          });
          process.stderr.write(
            `run-hook-with-bash: SKIP ${basename} (budget=${bound}ms elapsed=${elapsed}ms) — guard did not evaluate this call.\n`,
          );
        } else {
          process.stderr.write(
            `run-hook-with-bash: lifecycle member ${basename} skipped: ${result.error.message}\n`,
          );
        }
        continue;
      }
      if (result.stderr) process.stderr.write(result.stderr);
      // Emit each body as it lands rather than joining at the end: byte-identical
      // output, and whatever the chain already collected survives an outer
      // SIGKILL. For an advisory lane partial context beats none.
      // Drop ONE trailing newline so exactly one separator lands per body.
      const body = String(result.stdout || '').replace(/\n$/, '');
      if (body) process.stdout.write(`${body}\n`);
    }
    return 0;
  }

  const emitters = [];
  // Everything a non-denying member said, flushed to OUR stderr after the
  // chain. Held rather than streamed so a later member's deny reaches the
  // model on its own, verbatim.
  const held = [];
  let carriedStatus = 0;

  const chainDeadline = Date.now() + chainBudgetMs();

  for (const member of members) {
    // HIMMEL-1666: a tampered project-local member must not run at all — deny
    // the whole chain the same way a must-run member's starvation does below,
    // since a security-fence member reachable via --chain is exactly as
    // rewrite-able as one reachable via --optional.
    const integrity = verifyProjectHookIntegrity(member, sessionId);
    if (!integrity.ok) {
      denyIntegrityMismatch(member, integrity.relPath, integrity.reason);
      return 2;
    }
    // Clamped to what is left of the chain budget, but never below the floor:
    // a spent budget must not reduce the remaining guards to a 0ms execution
    // slice — each still gets a real, if small, chance to decide.
    const bound = Math.max(MIN_MEMBER_TIMEOUT_MS, Math.min(memberTimeoutMs(), chainDeadline - Date.now()));
    const memberStart = Date.now();
    const result = spawnSync(bash, [member], {
      input,
      env: process.env,
      encoding: 'utf8',
      timeout: bound,
      killSignal: 'SIGKILL',
      maxBuffer: MEMBER_MAX_BUFFER,
      windowsHide: true,   // HIMMEL-2043: no console flash per hook call
    });
    if (result.error && !isRecoverableEpipe(result)) {
      // A member that outran a LIMIT of ours is not a launcher failure. Two
      // limits reach here: the per-member timeout, and the output buffer (a
      // single hook keeps `stdio: 'inherit'` and has no buffer at all, so
      // overflow is a hazard chaining introduced). HIMMEL-2060: what happens
      // next now depends on whether this member is MUST_RUN_CHAIN_MEMBERS —
      // an advisory member is skipped exactly as before (Claude Code killing
      // the hung ENTRY would have skipped the sibling entries the same way);
      // a must-run SECURITY member instead fails the whole chain CLOSED,
      // because a starved guard silently skipped is a starved guard that
      // never got to deny.
      const overran = { ETIMEDOUT: true, ENOBUFS: true };
      if (overran[result.error.code]) {
        const basename = path.basename(member);
        const elapsed = Date.now() - memberStart;
        const mustRun = MUST_RUN_CHAIN_MEMBERS.has(basename);
        logChainSkip({
          ts: new Date().toISOString(),
          action: mustRun ? 'deny' : 'skip',
          member: basename,
          budget: bound,
          elapsed,
          reason: result.error.code,
          sessionId,
          toolCall: toolCallSummary(hookInput),
        });
        if (mustRun) {
          process.stderr.write(
            `run-hook-with-bash: DENY ${basename} (budget=${bound}ms elapsed=${elapsed}ms) — must-run guard did not evaluate this call; failing closed.\n`,
          );
          return 2;
        }
        process.stderr.write(
          `run-hook-with-bash: SKIP ${basename} (budget=${bound}ms elapsed=${elapsed}ms) — guard did not evaluate this call.\n`,
        );
        if (carriedStatus === 0) carriedStatus = 1;
        continue;
      }
      process.stderr.write(`run-hook-with-bash: failed to start ${bash}: ${result.error.message}\n`);
      return 2;
    }
    const stdout = result.stdout || '';
    const stderr = result.stderr || '';
    const status = typeof result.status === 'number' ? result.status : 2;
    const output = parseJsonObject(stdout);

    // exit 2 is the deny convention; a deny expressed as JSON on exit 0 is the
    // same decision in the structured channel. Both end the chain here.
    if (status === 2 || (status === 0 && isDeny(output))) {
      process.stdout.write(stdout);
      process.stderr.write(stderr);
      return 2;
    }
    if (status === 0 && output) {
      emitters.push({ source: path.basename(member), output, raw: stdout });
    } else if (stdout.trim()) {
      // Plain stdout on exit 0 is transcript-only for a lone hook, but our
      // stdout must stay one JSON object or empty — so it goes to stderr.
      held.push(stdout.endsWith('\n') ? stdout : `${stdout}\n`);
    }
    if (stderr) held.push(stderr);
    // Any other non-zero exit is a non-blocking error: report it, keep going,
    // and carry the first rc so the chain still reports the failure.
    if (status !== 0 && carriedStatus === 0) carriedStatus = status;
  }

  if (held.length) process.stderr.write(held.join(''));

  if (emitters.length === 0) return carriedStatus;
  if (emitters.length === 1) {
    process.stdout.write(emitters[0].raw);
    return 0;
  }
  const merged = mergeHookOutputs(emitters, (key, source) => {
    process.stderr.write(`run-hook-with-bash: chain: dropping unmergeable key ${key} from ${source}\n`);
  });
  process.stdout.write(`${JSON.stringify(merged)}\n`);
  return 0;
}

function main() {
  let parsed;
  try {
    parsed = parseHookArgs(process.argv.slice(2));
  } catch (error) {
    process.stderr.write(`run-hook-with-bash: ${error.message}\n`);
    process.exit(2);
  }

  const { hookArgs, optional, failClosedWhen, chain, lifecycle } = parsed;
  if (chain) {
    process.exitCode = runChain(hookArgs, lifecycle);
    return;
  }

  const hookScript = hookArgs[0];
  if (optional && !fs.existsSync(hookScript)) {
    if (failClosedWhen && process.env[failClosedWhen.name] === failClosedWhen.value) {
      const hookName = path.basename(hookScript, path.extname(hookScript));
      process.stderr.write(`${hookName}: hook script missing while ${failClosedWhen.display} (stale checkout?) - failing closed\n`);
      process.exit(2);
    }
    process.exit(0);
  }

  // HIMMEL-1666: stdin has to be READ (to recover session_id for the integrity
  // check below) rather than left as a live 'inherit' pipe, so it is buffered
  // once here and replayed to the child via `input` — byte-identical to what
  // the child would have read directly, since these hooks read one JSON
  // payload and stop.
  const input = readAllStdin();
  const hookInput = parseJsonObject(input);
  const sessionId = hookInput && typeof hookInput.session_id === 'string' ? hookInput.session_id : null;
  const integrity = verifyProjectHookIntegrity(hookScript, sessionId);
  if (!integrity.ok) {
    denyIntegrityMismatch(hookScript, integrity.relPath, integrity.reason);
    process.exit(2);
  }

  const bash = resolveBash();
  if (!bash) {
    process.stderr.write('run-hook-with-bash: no usable Bash interpreter found; refusing to run hook\n');
    process.exit(2);
  }
  const result = spawnSync(bash, hookArgs, { input, stdio: ['pipe', 'inherit', 'inherit'], env: process.env, windowsHide: true });   // HIMMEL-2043
  if (result.error && !isRecoverableEpipe(result)) {
    process.stderr.write(`run-hook-with-bash: failed to start ${bash}: ${result.error.message}\n`);
    process.exit(2);
  }
  process.exit(typeof result.status === 'number' ? result.status : 2);
}

module.exports = {
  DEFAULT_CHAIN_BUDGET_MS,
  MIN_MEMBER_TIMEOUT_MS,
  MUST_RUN_CHAIN_MEMBERS,
  isKnownBadWindowsBash,
  isRecoverableEpipe,
  isUsable,
  mergeHookOutputs,
  resolveBash,
  windowsCandidates,
  // Re-exported from ./hook-integrity.js so the launcher's test surface is
  // unchanged by the module split.
  gitBlobSha1,
  hookIntegrityDir,
  loadIntegrityRecord,
  verifyProjectHookIntegrity,
  denyIntegrityMismatch,
};
if (require.main === module) main();
