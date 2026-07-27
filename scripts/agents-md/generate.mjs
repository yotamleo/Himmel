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
  if (!Array.isArray(table)) {
    die(2, `agents-md: cannot evaluate — debrand table must be a JSON array, got ${typeof table}.`);
  }
  // Coverage validation (HIMMEL-480). `split/join` silently no-ops when `from`
  // is absent, so a CLAUDE.md edit that moves or rewrites debranded text turns
  // its rule into a dead no-op with NO signal — the transform quietly stops
  // protecting that string. Every rule must therefore either match, or declare
  // `"dormant": true` with a `note` saying why. An unmatched, undeclared rule is
  // a hard error: structural, not a warning nobody reads (HIMMEL-195).
  const orphans = [];
  const revived = [];
  const seenFrom = new Set();
  for (const entry of table) {
    // Validate the entry SHAPE before destructuring — `const {…} = null` throws
    // a raw TypeError instead of the structured cannot-evaluate message.
    if (entry === null || typeof entry !== 'object' || Array.isArray(entry)) {
      die(2, `agents-md: cannot evaluate — malformed debrand entry (expected an object):\n` +
             `         ${JSON.stringify(entry)}`);
    }
    const { from, to, dormant } = entry;
    // Malformed entries are FATAL, not skipped. A non-string/empty `from` would
    // either no-op or (empty string) corrupt the body by inserting `to` between
    // every char — and a skipped entry never reaches the orphan calculation
    // below, so a one-character schema typo would silently disable a live
    // neutralization rule while BOTH gates still went green. Fail closed.
    if (typeof from !== 'string' || from === '' || typeof to !== 'string') {
      die(2, `agents-md: cannot evaluate — malformed debrand entry ` +
             `(needs a non-empty string "from" and a string "to"):\n` +
             `         ${JSON.stringify(entry)}`);
    }
    if (to === from) {
      die(2, `agents-md: cannot evaluate — debrand entry maps "from" to itself:\n` +
             `         ${JSON.stringify(entry)}\n` +
             `         This performs no substitution and therefore protects nothing.`);
    }
    if (seenFrom.has(from)) {
      die(2, `agents-md: cannot evaluate — duplicate debrand "from" value:\n` +
             `         ${JSON.stringify(entry)}\n` +
             `         Each source string may appear only once in the ordered mapping table.`);
    }
    seenFrom.add(from);
    // A `dormant` flag suppresses the coverage error below, so it must carry its
    // own justification — an unexplained dormant rule is the same silent drift
    // the coverage check exists to surface, just opted out of.
    if (dormant === true && (typeof entry.note !== 'string' || entry.note.trim() === '')) {
      die(2, `agents-md: cannot evaluate — debrand entry is marked "dormant": true but has no "note" ` +
             `explaining why:\n         · ${JSON.stringify(from)}\n` +
             `         Record where the content went, so the rule can be revived or deleted later.`);
    }
    // Match against the ORIGINAL body, not the progressively rewritten text:
    // an earlier rule's replacement can destroy a later rule's `from` (false
    // orphan) or synthesize one (false revival). Coverage is a question about
    // the SOURCE, so it must be asked of the source.
    const matched = body.includes(from);
    if (!matched && dormant !== true) orphans.push(from);
    if (matched && dormant === true) revived.push(from);
    const before = debranded;
    debranded = debranded.split(from).join(to);
    if (matched && debranded === before) {
      die(2, `agents-md: cannot evaluate — live debrand entry produced no substitution:\n` +
             `         ${JSON.stringify(entry)}\n` +
             `         An earlier rule consumed its source text, so this mapping silently protects nothing.`);
    }
  }
  if (revived.length) {
    const msg = `${revived.length} debrand rule(s) marked "dormant": true now MATCH again:\n` +
      revived.map((f) => `         · ${JSON.stringify(f)}`).join('\n') + '\n' +
      `         Drop their "dormant" flag. While the flag stays, the rule is exempt\n` +
      `         from orphan detection — so a later rewrite of that phrase would go\n` +
      `         unnoticed, which is the exact silent drift this check exists to stop.`;
    // Fatal under enforcement, advisory otherwise: a dormant flag left on a live
    // rule quietly re-opens the fail-open path for every future edit.
    if (process.env.AGENTS_MD_ENFORCE_COVERAGE === '1') {
      die(2, `agents-md: cannot evaluate — ${msg}`);
    }
    process.stderr.write(`agents-md: NOTE — ${msg}\n`);
  }
  // Coverage enforcement is OPT-IN, because this generator legitimately runs
  // against partial sources: the freshness hooks regenerate from a staged temp
  // copy, and both test suites build stub fixtures containing none of the live
  // phrases. Making it unconditional fails all of those spuriously; keying it
  // on "does SOURCE look like the canonical CLAUDE.md" fails the opposite way —
  // the freshness hook's temp copy never matches, so the check would be dead in
  // the one path that gates a commit.
  //
  // Instead the dedicated pre-commit gate (scripts/hooks/check-debrand-coverage.sh)
  // sets AGENTS_MD_ENFORCE_COVERAGE=1 and points SOURCE at the real staged
  // CLAUDE.md. One job per caller; the gate is what makes this structural.
  if (orphans.length && process.env.AGENTS_MD_ENFORCE_COVERAGE === '1') {
    die(2, `agents-md: cannot evaluate — ${orphans.length} debrand rule(s) no longer match ${SOURCE}:\n` +
           orphans.map((f) => `         · ${JSON.stringify(f)}`).join('\n') + '\n' +
           `         A rule that matches nothing is a silent no-op: the string it protected\n` +
           `         is either gone or moved OUT of CLAUDE.md (and is therefore no longer\n` +
           `         debranded anywhere). Either restore the text, or mark the rule\n` +
           `         "dormant": true with a "note" recording where the content went.`);
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
