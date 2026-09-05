#!/usr/bin/env node
// scripts/lanes/bench/bank-snapshot-core.mjs — HIMMEL-1723 P2.6
// Pure parsing/threshold helpers for bank-snapshot.sh, plus the CLI that
// script shells out to. Reuses scripts/lanes/bank-status-core.mjs's
// parseBankStatusOutput (the same per-lane `<id> <funded|spent|unknown>
// <detail>` grammar `bun scripts/lanes/bank-status.ts` already emits)
// instead of re-parsing raw bank-status output a second, divergent way.
//
// Two thresholds here are DELIBERATELY DIFFERENT from bank-status.ts's own
// funded/spent verdict (LANE_FUNDED_MAX_PCT, default 99): this bench refuses
// at codex weekly >= 80% or Claude seven_day >= 70% (spec §7.2) — well below
// the lane's own ~90-99% refuse point, so a 2-3h, 20-dispatch batch cannot
// die mid-run right at the boundary.
import { readFileSync, writeFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { parseBankStatusOutput } from '../bank-status-core.mjs';

// CLAUDE_SEVEN_DAY_WINDOW_LABEL: readClaudeBank (scripts/observability/
// quota-sources.ts) reads the statusline cache's `seven_day` FIELD but
// labels the resulting reading "weekly" (`[["five_hour","5h"],
// ["seven_day","weekly"]]`) — the SAME string readCodexWeeklyBank uses for
// codex's own weekly reading. That is harmless here because every lookup is
// scoped to one lane's own detail string (extractLaneWindowPct below), but
// searching for a window literally named "seven_day" would silently match
// nothing and read as `null` (unmeasured) forever. Named as a constant so
// this is not a magic string two call sites could drift out of sync on.
export const CLAUDE_SEVEN_DAY_WINDOW_LABEL = 'weekly';

// extractLaneWindowPct — the usedPct for one lane's named reading window
// (e.g. laneId="claudex", windowName="weekly"; laneId="sonnet",
// windowName=CLAUDE_SEVEN_DAY_WINDOW_LABEL — any claude-tier lane reads the
// SAME account-wide number per spec §1.1, so which lane id is picked doesn't
// matter). Returns null when the lane is absent from the output, not in
// "measured" state (flat-rate / unmeasurable), or lacks that specific window.
export function extractLaneWindowPct(bankStatusOutput, laneId, windowName) {
  const byLane = parseBankStatusOutput(bankStatusOutput);
  const status = byLane.get(laneId);
  if (!status || !status.detail.startsWith('measured ')) return null;
  const body = status.detail.slice('measured '.length);
  for (const segment of body.split(';')) {
    const m = /^\s*(\S+)\s+used=([0-9.]+)%/.exec(segment);
    if (m && m[1] === windowName) return Number(m[2]);
  }
  return null;
}

// spec §7.2 — refuse to start / abort a running batch.
export const CODEX_WEEKLY_REFUSE_PCT = 80;
export const CLAUDE_SEVEN_DAY_REFUSE_PCT = 70;

export function evaluatePreflight({ codexWeeklyPct, claudeSevenDayPct }) {
  const reasons = [];
  if (!Number.isFinite(codexWeeklyPct)) {
    reasons.push('codex weekly UNKNOWN');
  } else if (codexWeeklyPct >= CODEX_WEEKLY_REFUSE_PCT) {
    reasons.push(`codex weekly ${codexWeeklyPct}% >= ${CODEX_WEEKLY_REFUSE_PCT}%`);
  }
  if (!Number.isFinite(claudeSevenDayPct)) {
    reasons.push('claude seven_day UNKNOWN');
  } else if (claudeSevenDayPct >= CLAUDE_SEVEN_DAY_REFUSE_PCT) {
    reasons.push(`claude seven_day ${claudeSevenDayPct}% >= ${CLAUDE_SEVEN_DAY_REFUSE_PCT}%`);
  }
  return { proceed: reasons.length === 0, reasons };
}

// evaluateDelta — spec §6.2's stale-source rule: a post-reading <= its
// pre-reading is reported UNMEASURED (stale source), NEVER as a zero or
// negative draw — codex's log source has a known unfixed stale-LOW defect
// (HIMMEL-1689) that can mask real exhaustion across a weekly reset.
export function evaluateDelta(pre, post) {
  if (pre === null || pre === undefined || post === null || post === undefined) {
    return { status: 'UNMEASURED', reason: 'missing reading' };
  }
  if (post <= pre) return { status: 'UNMEASURED', reason: 'stale source (post <= pre)' };
  return { status: 'MEASURED', deltaPct: post - pre };
}

function readStdin() {
  return new Promise((resolve) => {
    let data = '';
    process.stdin.setEncoding('utf8');
    process.stdin.on('data', (c) => { data += c; });
    process.stdin.on('end', () => resolve(data));
  });
}

function parseFlags(args) {
  const out = {};
  for (let i = 0; i < args.length; i++) {
    if (args[i].startsWith('--')) { out[args[i].slice(2)] = args[i + 1]; i++; }
  }
  return out;
}

async function main() {
  const [cmd, ...rest] = process.argv.slice(2);
  const flags = parseFlags(rest);

  if (cmd === 'preflight' || cmd === 'check') {
    const output = await readStdin();
    const codexPct = extractLaneWindowPct(output, flags['codex-lane'] || 'claudex', 'weekly');
    const claudePct = extractLaneWindowPct(output, flags['claude-lane'] || 'sonnet', CLAUDE_SEVEN_DAY_WINDOW_LABEL);
    const result = evaluatePreflight({ codexWeeklyPct: codexPct, claudeSevenDayPct: claudePct });
    process.stdout.write(`codex weekly: ${codexPct === null ? 'unmeasured' : codexPct + '%'}\n`);
    process.stdout.write(`claude seven_day: ${claudePct === null ? 'unmeasured' : claudePct + '%'}\n`);
    if (!result.proceed) {
      process.stderr.write(`bank-snapshot ${cmd}: REFUSE — ${result.reasons.join('; ')}\n`);
      process.exitCode = 1;
      return;
    }
    process.stdout.write(`bank-snapshot ${cmd}: proceed\n`);
    return;
  }

  if (cmd === 'snapshot') {
    const output = await readStdin();
    const codexPct = extractLaneWindowPct(output, flags['codex-lane'] || 'claudex', 'weekly');
    const claudePct = extractLaneWindowPct(output, flags['claude-lane'] || 'sonnet', CLAUDE_SEVEN_DAY_WINDOW_LABEL);
    const record = { ts: new Date().toISOString(), codex: { usedPct: codexPct }, claude: { usedPct: claudePct } };
    const text = JSON.stringify(record, null, 2) + '\n';
    if (flags.out) writeFileSync(flags.out, text);
    else process.stdout.write(text);
    return;
  }

  if (cmd === 'delta') {
    if (!flags.pre || !flags.post) {
      process.stderr.write('bank-snapshot delta: --pre and --post are required\n');
      process.exitCode = 2;
      return;
    }
    const pre = JSON.parse(readFileSync(flags.pre, 'utf8'));
    const post = JSON.parse(readFileSync(flags.post, 'utf8'));
    for (const bank of ['codex', 'claude']) {
      const d = evaluateDelta(pre[bank]?.usedPct ?? null, post[bank]?.usedPct ?? null);
      if (d.status === 'UNMEASURED') process.stdout.write(`${bank}: UNMEASURED (stale source) — ${d.reason}\n`);
      else process.stdout.write(`${bank}: delta=+${d.deltaPct}%\n`);
    }
    return;
  }

  process.stderr.write('usage: bank-snapshot-core.mjs preflight|check|snapshot|delta ...\n');
  process.exitCode = 2;
}

// Resolved-path comparison, not a filename suffix (codex CR) — a suffix match
// also fires when this module is imported by a script whose own filename ends
// with the same string, running main() as an import side effect.
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  main();
}
