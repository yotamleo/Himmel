#!/usr/bin/env node
// scripts/lanes/tier-return-sweep.mjs - P0.3 Tier-return escalation counter
// (HIMMEL-2977, G10). Walks subagent transcript JSONL, takes the model from
// each transcript's first assistant message, and counts how many end their
// final assistant message with a `> **Tier-return:** <reason>` marker (a
// child returning work as above its tier - see docs/internals/lane-calibration.md).
//
// Platform guard: no .ps1 twin, by design. Node 18+ walking Claude Code
// transcript JSONL, same format on every platform; it runs under git bash
// unchanged.
//
// Usage: node tier-return-sweep.mjs --since <ISO8601> [--projects-dir <dir>]
// Prints one line per dispatched model: `<model> <returned>/<dispatched>`.

import { readdirSync, readFileSync, statSync } from 'node:fs';
import { join } from 'node:path';

function parseArgs(argv) {
  const args = { since: null, projectsDir: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--since') args.since = argv[++i];
    else if (argv[i] === '--projects-dir') args.projectsDir = argv[++i];
  }
  if (!args.since) {
    console.error('usage: tier-return-sweep.mjs --since <ISO8601> [--projects-dir <dir>]');
    process.exit(2);
  }
  return args;
}

function walkJsonl(dir, inSubagents) {
  const out = [];
  for (const name of readdirSync(dir)) {
    const p = join(dir, name);
    const st = statSync(p);
    if (st.isDirectory()) out.push(...walkJsonl(p, inSubagents || name === 'subagents'));
    else if (inSubagents && name.endsWith('.jsonl')) out.push(p);
  }
  return out;
}

function shortModel(model) {
  const m = /claude-(opus|sonnet|haiku|fable)-/.exec(model || '');
  return m ? m[1] : model || 'unknown';
}

function readAssistantMessages(file) {
  const lines = readFileSync(file, 'utf8').split('\n').filter(Boolean);
  const msgs = [];
  for (const line of lines) {
    let row;
    try {
      row = JSON.parse(line);
    } catch {
      continue;
    }
    if (row.type === 'assistant') msgs.push(row);
  }
  return msgs;
}

function textOf(msg) {
  const content = msg?.message?.content;
  if (!Array.isArray(content)) return '';
  return content
    .filter((b) => b.type === 'text')
    .map((b) => b.text || '')
    .join('\n');
}

function endsWithTierReturn(text) {
  const lines = text.split('\n');
  let i = lines.length - 1;
  while (i >= 0 && lines[i].trim() === '') i--;
  return i >= 0 && /^> \*\*Tier-return:\*\* /.test(lines[i]);
}

const { since, projectsDir } = parseArgs(process.argv.slice(2));
const root = projectsDir || `${process.env.CLAUDE_CONFIG_DIR || `${process.env.HOME}/.claude`}/projects`;
const sinceEpoch = Date.parse(since);
if (!Number.isFinite(sinceEpoch)) {
  console.error(`tier-return-sweep: invalid --since: ${since}`);
  process.exit(2);
}

const counts = new Map();
for (const file of walkJsonl(root, false)) {
  const msgs = readAssistantMessages(file);
  if (msgs.length === 0) continue;
  const first = msgs[0];
  const last = msgs[msgs.length - 1];
  const firstEpoch = Date.parse(first.timestamp);
  if (!Number.isFinite(firstEpoch) || firstEpoch < sinceEpoch) continue;

  const model = shortModel(first.message?.model);
  const entry = counts.get(model) || { dispatched: 0, returned: 0 };
  entry.dispatched++;
  if (endsWithTierReturn(textOf(last))) entry.returned++;
  counts.set(model, entry);
}

for (const [model, { dispatched, returned }] of counts) {
  console.log(`${model} ${returned}/${dispatched}`);
}
