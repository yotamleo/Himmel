#!/usr/bin/env node
// HIMMEL-471 — generate a GPT-adapted AGENTS.md from CLAUDE.md.
//
// CLAUDE.md stays the single source of truth; AGENTS.md is regenerated (never
// hand-maintained) so the two cannot drift. A pre-commit guard runs --check.
//
// Adaptation is confined to the authored preamble (an explicit precedence
// ladder that resolves CLAUDE.md hedges globally + a non-Claude-harness reading
// note) plus a small literal debrand table. The body ships near-verbatim — see
// the design spec for why a mechanical, reproducible transform is required
// (the drift guard must verify it deterministically).
//
// Modes:  --write  write AGENTS.md   |   --check  compare (drift guard)
// Exit:   0 fresh/written · 1 stale · 2 cannot-evaluate (@include / >32KiB / missing input)
//
// Path overrides (env): AGENTS_MD_SOURCE, AGENTS_MD_TARGET,
//                       AGENTS_MD_PREAMBLE, AGENTS_MD_DEBRAND

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = dirname(fileURLToPath(import.meta.url));
const REPO_ROOT = join(SCRIPT_DIR, '..', '..'); // scripts/agents-md -> repo root

const SOURCE   = process.env.AGENTS_MD_SOURCE   || join(REPO_ROOT, 'CLAUDE.md');
const TARGET   = process.env.AGENTS_MD_TARGET   || join(REPO_ROOT, 'AGENTS.md');
const PREAMBLE = process.env.AGENTS_MD_PREAMBLE || join(SCRIPT_DIR, 'preamble.md');
const DEBRAND  = process.env.AGENTS_MD_DEBRAND  || join(SCRIPT_DIR, 'debrand.json');

const WARN_BYTES = 24576; // 24 KiB — local-file budget (headroom for global ~/.codex/AGENTS.md)
const HARD_BYTES = 32768; // 32 KiB — Codex project_doc_max_bytes; never emit over this

const lf = (s) => s.replace(/\r\n/g, '\n').replace(/\r/g, '\n');
const die = (code, msg) => { process.stderr.write(msg + '\n'); process.exit(code); };

function build() {
  for (const [label, p] of [['source CLAUDE.md', SOURCE], ['preamble', PREAMBLE], ['debrand table', DEBRAND]]) {
    if (!existsSync(p)) die(2, `agents-md: cannot evaluate — missing ${label}: ${p}`);
  }

  const body = lf(readFileSync(SOURCE, 'utf8'));
  // Reject Claude-Code @include directives Codex cannot resolve (would inline a dead token).
  if (/^@\S/m.test(body)) {
    die(2, `agents-md: cannot evaluate — ${SOURCE} contains an @include directive.\n` +
           `         Inline the referenced content into CLAUDE.md (Codex does not resolve @includes).`);
  }

  const preamble = lf(readFileSync(PREAMBLE, 'utf8'));
  let debranded = body;
  let table;
  try { table = JSON.parse(readFileSync(DEBRAND, 'utf8')); }
  catch (e) { die(2, `agents-md: cannot evaluate — debrand table is not valid JSON: ${e.message}`); }
  for (const entry of table) {
    const { from, to } = entry;
    // Skip malformed entries: a non-string/empty `from` would either no-op or
    // (empty string) corrupt the body by inserting `to` between every char.
    if (typeof from !== 'string' || from === '' || typeof to !== 'string') {
      process.stderr.write(`agents-md: skipping malformed debrand entry: ${JSON.stringify(entry)}\n`);
      continue;
    }
    debranded = debranded.split(from).join(to);
  }

  // Assemble: preamble, exactly one blank line, then the (debranded) body. LF, single trailing newline.
  let out = preamble.replace(/\s*$/, '') + '\n\n' + debranded.replace(/^\s*/, '');
  if (!out.endsWith('\n')) out += '\n';

  const bytes = Buffer.byteLength(out, 'utf8');
  if (bytes > HARD_BYTES) {
    die(2, `agents-md: cannot evaluate — assembled AGENTS.md is ${bytes} bytes (> ${HARD_BYTES}, Codex cap).\n` +
           `         Trim CLAUDE.md; Codex would truncate an over-cap file.`);
  }
  if (bytes > WARN_BYTES) {
    process.stderr.write(`agents-md: WARNING — AGENTS.md is ${bytes} bytes (> ${WARN_BYTES} budget). ` +
      `Headroom for global ~/.codex/AGENTS.md is shrinking; total concat must stay < ${HARD_BYTES}.\n`);
  }
  return out;
}

const mode = process.argv[2];
const out = build(); // @include / >32KiB / missing-input all exit 2 here, in both modes

if (mode === '--write') {
  writeFileSync(TARGET, out, 'utf8');
  process.stdout.write(`agents-md: wrote ${TARGET} (${Buffer.byteLength(out, 'utf8')} bytes)\n`);
  process.exit(0);
} else if (mode === '--check') {
  if (!existsSync(TARGET)) die(2, `agents-md: cannot evaluate — ${TARGET} does not exist (run --write).`);
  const current = lf(readFileSync(TARGET, 'utf8'));
  if (current === out) process.exit(0);
  die(1, `agents-md: ${TARGET} is STALE — CLAUDE.md changed without regenerating.\n` +
         `         Fix: node scripts/agents-md/generate.mjs --write  (then stage AGENTS.md).`);
} else {
  die(2, `agents-md: usage: generate.mjs --write | --check`);
}
