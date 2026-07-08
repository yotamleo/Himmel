// scripts/lessons/tests/sample-audit.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync, readFileSync, mkdirSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT = fileURLToPath(new URL('../sample-audit.mjs', import.meta.url));
const TMP = mkdtempSync(join(tmpdir(), 'sample-audit-test-'));
after(() => rmSync(TMP, { recursive: true, force: true }));

const run = (args, input, env) => spawnSync(process.execPath, [SCRIPT, ...args], {
  encoding: 'utf8', input, env: env ? { ...process.env, ...env } : undefined,
});
const parseJsonl = (text) => text.split(/\r?\n/).filter((l) => l.trim() !== '').map((l) => JSON.parse(l));

let counter = 0;
const nextDir = () => {
  const d = join(TMP, `case-${counter++}`);
  mkdirSync(d, { recursive: true });
  return d;
};

const rec = (overrides = {}) => ({
  id: overrides.id || `2026-07-${String(1 + (counter % 28)).padStart(2, '0')}-lesson-${counter}`,
  claim: 'Some claim worth remembering.',
  source: { type: 'session', ref: 'transcripts/x.jsonl:1-10' },
  captured_at: '2026-07-08T14:32:00Z',
  captured_by: 'manual',
  confidence: 'high',
  scope: ['harness'],
  status: 'active',
  ...overrides,
});

function jsonlFile(dir, name, records) {
  const p = join(dir, name);
  writeFileSync(p, records.map((r) => JSON.stringify(r)).join('\n') + '\n');
  return p;
}

function frontmatterMdFile(dir, name, lessonFields, { crlf = false } = {}) {
  const p = join(dir, name);
  let body = `---\nlesson:\n  id: ${lessonFields.id}\n  claim: "${lessonFields.claim}"\n  source:\n    type: ${lessonFields.source.type}\n    ref: "${lessonFields.source.ref}"\n  captured_at: ${lessonFields.captured_at}\n  captured_by: ${lessonFields.captured_by}\n  confidence: ${lessonFields.confidence}\n  scope:\n    - ${lessonFields.scope[0]}\n  status: ${lessonFields.status}\n---\n\nBody text.\n`;
  if (crlf) body = body.replace(/\n/g, '\r\n');
  writeFileSync(p, body);
  return p;
}

function bodyLessonsMdFile(dir, name, records) {
  const p = join(dir, name);
  const jsonl = records.map((r) => JSON.stringify(r)).join('\n');
  const body = `---\ndate: 2026-07-08T14:32:00Z\ntype: session\n---\n\nPreamble.\n\n## Summary\n\nStuff.\n\n## Lessons\n\n\`\`\`jsonl\n${jsonl}\n\`\`\`\n\n## Raw Conversation\n\n> hi\n`;
  writeFileSync(p, body);
  return p;
}

// --- Extraction from all 3 carriers ---

test('sample: extracts from frontmatter, body-lessons, and jsonl carriers', () => {
  const dir = nextDir();
  const fmId = 'sample-fm-a';
  const bodyId = 'sample-body-a';
  const jsonlId = 'sample-jsonl-a';
  const fmFile = frontmatterMdFile(dir, 'fm.md', rec({ id: `2026-07-01-${fmId}` }));
  const bodyFile = bodyLessonsMdFile(dir, 'body.md', [rec({ id: `2026-07-02-${bodyId}`, captured_by: 'end-session-wiki' })]);
  const jsonlF = jsonlFile(dir, 'ledger.jsonl', [rec({ id: `2026-07-03-${jsonlId}` })]);

  const r = run(['sample', fmFile, bodyFile, jsonlF, '--n', '3', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  const worksheet = parseJsonl(r.stdout);
  assert.equal(worksheet.length, 3);
  const carriers = worksheet.map((w) => w.origin.carrier).sort();
  assert.deepEqual(carriers, ['body-lessons', 'frontmatter', 'jsonl']);
  const fmEntry = worksheet.find((w) => w.origin.carrier === 'frontmatter');
  assert.equal(fmEntry.id, `2026-07-01-${fmId}`);
  assert.equal(fmEntry.origin.file, fmFile);
});

// --- Status filtering ---

test('sample: status filtering excludes superseded/invalidated, keeps active/unverified', () => {
  const dir = nextDir();
  const records = [
    rec({ id: '2026-07-01-status-active', status: 'active' }),
    rec({ id: '2026-07-01-status-unverified', status: 'unverified' }),
    rec({ id: '2026-07-01-status-superseded', status: 'superseded' }),
    rec({ id: '2026-07-01-status-invalidated', status: 'invalidated' }),
  ];
  const f = jsonlFile(dir, 'ledger.jsonl', records);
  const r = run(['sample', f, '--n', '4', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  const ws = parseJsonl(r.stdout);
  const ids = ws.map((w) => w.id).sort();
  assert.deepEqual(ids, ['2026-07-01-status-active', '2026-07-01-status-unverified']);
});

// --- Audited-exclusion default + --include-audited ---

test('sample: excludes already-audited records by default; --include-audited re-includes', () => {
  const dir = nextDir();
  const audited = rec({
    id: '2026-07-01-already-audited',
    audit: { audited_at: '2026-07-05T00:00:00Z', verdict: 'confirmed', auditor: 'x' },
  });
  const fresh = rec({ id: '2026-07-01-fresh' });
  const f = jsonlFile(dir, 'ledger.jsonl', [audited, fresh]);

  const r1 = run(['sample', f, '--n', '5', '--allow-small']);
  assert.equal(r1.status, 0, r1.stderr);
  const ws1 = parseJsonl(r1.stdout);
  assert.deepEqual(ws1.map((w) => w.id), ['2026-07-01-fresh']);

  const r2 = run(['sample', f, '--n', '5', '--allow-small', '--include-audited']);
  assert.equal(r2.status, 0, r2.stderr);
  const ws2 = parseJsonl(r2.stdout);
  assert.deepEqual(ws2.map((w) => w.id).sort(), ['2026-07-01-already-audited', '2026-07-01-fresh']);
});

// --- Deterministic sampling ---

test('sample: same seed on a >N population yields the same sampled id set', () => {
  const dir = nextDir();
  const records = [];
  for (let i = 0; i < 25; i++) records.push(rec({ id: `2026-07-${String(1 + i).padStart(2, '0')}-pop-${i}` }));
  const f = jsonlFile(dir, 'ledger.jsonl', records);

  const r1 = run(['sample', f, '--n', '20', '--seed', '7']);
  const r2 = run(['sample', f, '--n', '20', '--seed', '7']);
  assert.equal(r1.status, 0, r1.stderr);
  assert.equal(r2.status, 0, r2.stderr);
  assert.deepEqual(parseJsonl(r1.stdout).map((w) => w.id), parseJsonl(r2.stdout).map((w) => w.id));
});

test('sample: different seeds on a >N population yield different sampled sets', () => {
  const dir = nextDir();
  const records = [];
  for (let i = 0; i < 25; i++) records.push(rec({ id: `2026-07-${String(1 + i).padStart(2, '0')}-pop2-${i}` }));
  const f = jsonlFile(dir, 'ledger.jsonl', records);

  const r1 = run(['sample', f, '--n', '20', '--seed', '1']);
  const r2 = run(['sample', f, '--n', '20', '--seed', '2']);
  const ids1 = parseJsonl(r1.stdout).map((w) => w.id).sort();
  const ids2 = parseJsonl(r2.stdout).map((w) => w.id).sort();
  assert.notDeepEqual(ids1, ids2);
});

// --- Population < N ---

test('sample: eligible population < N → exit 3', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec({ id: '2026-07-01-tiny' })]);
  const r = run(['sample', f, '--n', '20']);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /eligible population \(1\) < requested N \(20\)/);
});

// --- --allow-small ---

test('sample: --allow-small permits smaller-than-N samples', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec({ id: '2026-07-01-small-a' }), rec({ id: '2026-07-01-small-b' })]);
  const r = run(['sample', f, '--n', '20', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  assert.equal(parseJsonl(r.stdout).length, 2);
});

// --- apply round-trip: jsonl carrier ---

test('apply: jsonl round-trip writes audit block, preserves other lines byte-for-byte', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-jsonl-apply-target' });
  const untouched = rec({ id: '2026-07-01-jsonl-apply-untouched' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target, untouched]);
  const originalLines = readFileSync(f, 'utf8').split('\n');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: 'checked' }) + '\n');

  const r = run(['apply', '--verdicts', worksheet, '--auditor', 'test-auditor', '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r.status, 0, r.stderr);

  const newLines = readFileSync(f, 'utf8').split('\n');
  assert.equal(newLines[1], originalLines[1]); // untouched record line identical
  const updated = JSON.parse(newLines[0]);
  assert.deepEqual(updated.audit, { audited_at: '2026-07-09T00:00:00Z', verdict: 'confirmed', auditor: 'test-auditor' });
  // all original fields preserved
  for (const k of Object.keys(target)) assert.deepEqual(updated[k], target[k]);
});

// --- apply round-trip: frontmatter carrier ---

test('apply: frontmatter round-trip nests audit: inside lesson:, preserves body text', () => {
  const dir = nextDir();
  const lesson = rec({ id: '2026-07-01-fm-apply-target' });
  const f = frontmatterMdFile(dir, 'lesson.md', lesson);

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...lesson, origin: { file: f, carrier: 'frontmatter' }, verdict: 'stale', notes: '' }) + '\n');

  const r = run(['apply', '--verdicts', worksheet, '--auditor', 'operator', '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r.status, 0, r.stderr);

  const newText = readFileSync(f, 'utf8');
  assert.ok(newText.includes('Body text.\n'), 'body content preserved');
  assert.match(newText, /lesson:\n(?:.*\n)*?\s{2}audit:\n\s{4}audited_at: 2026-07-09T00:00:00Z\n\s{4}verdict: stale\n\s{4}auditor: operator\n/);

  // Re-verify via sample: the record now has an audit block and is excluded by default.
  const r2 = run(['sample', f, '--n', '1', '--allow-small']);
  assert.equal(parseJsonl(r2.stdout).length, 0);
  const r3 = run(['sample', f, '--n', '1', '--allow-small', '--include-audited']);
  const ws3 = parseJsonl(r3.stdout);
  assert.equal(ws3.length, 1);
  assert.deepEqual(ws3[0].audit, { audited_at: '2026-07-09T00:00:00Z', verdict: 'stale', auditor: 'operator' });
});

test('apply: re-running the same worksheet is idempotent for the frontmatter carrier (audit replaced, not duplicated)', () => {
  const dir = nextDir();
  const lesson = rec({ id: '2026-07-01-fm-rerun-target' });
  const f = frontmatterMdFile(dir, 'lesson.md', lesson);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...lesson, origin: { file: f, carrier: 'frontmatter' }, verdict: 'confirmed', notes: '' }) + '\n');

  const r1 = run(['apply', '--verdicts', worksheet, '--auditor', 'x', '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r1.status, 0, r1.stderr);
  const afterFirst = readFileSync(f, 'utf8');

  const r2 = run(['apply', '--verdicts', worksheet, '--auditor', 'x', '--audited-at', '2026-07-10T00:00:00Z']);
  assert.equal(r2.status, 0, r2.stderr);
  const afterSecond = readFileSync(f, 'utf8');

  assert.equal((afterSecond.match(/^\s+audit:$/gm) || []).length, 1, 'exactly one audit: mapping after re-run');
  assert.match(afterSecond, /audited_at: 2026-07-10T00:00:00Z/);
  assert.ok(!afterSecond.includes('2026-07-09T00:00:00Z'), 'old audit block replaced, not kept');
  assert.equal(afterSecond.length, afterFirst.length, 'file size stable across re-runs');
});

// --- apply round-trip: body-lessons carrier ---

test('apply: body-lessons round-trip writes audit on the target line only; prose + sibling byte-identical', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-body-apply-target', captured_by: 'end-session-wiki' });
  const sibling = rec({ id: '2026-07-01-body-apply-sibling', captured_by: 'end-session-wiki' });
  const f = bodyLessonsMdFile(dir, 'session.md', [target, sibling]);
  const originalLines = readFileSync(f, 'utf8').split('\n');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'body-lessons' }, verdict: 'refuted', notes: '' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet, '--auditor', 'x', '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r.status, 0, r.stderr);

  const newLines = readFileSync(f, 'utf8').split('\n');
  assert.equal(newLines.length, originalLines.length, 'line count unchanged');
  const targetIdx = originalLines.findIndex((l) => l.includes('body-apply-target'));
  assert.ok(targetIdx > -1);
  // (b) + (c): every line except the target — frontmatter, prose sections,
  // fences, and the sibling body record — is byte-identical.
  for (let i = 0; i < originalLines.length; i++) {
    if (i === targetIdx) continue;
    assert.equal(newLines[i], originalLines[i], `line ${i + 1} changed unexpectedly`);
  }
  const siblingIdx = originalLines.findIndex((l) => l.includes('body-apply-sibling'));
  assert.equal(newLines[siblingIdx], JSON.stringify(sibling), 'sibling body record byte-identical');
  // (a): the target record's line gained exactly the audit key.
  const updated = JSON.parse(newLines[targetIdx]);
  assert.deepEqual(updated.audit, { audited_at: '2026-07-09T00:00:00Z', verdict: 'refuted', auditor: 'x' });
  for (const k of Object.keys(target)) assert.deepEqual(updated[k], target[k]);
});

// --- apply refusals ---

test('apply: empty verdict → exit 1, lists unverdicted ids', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-empty-verdict' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: '', notes: '' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet, '--auditor', 'x']);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /no verdict/);
  assert.match(r.stderr, /2026-07-01-empty-verdict/);
});

test('apply: bad verdict enum → exit 1', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-bad-verdict' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: 'plausible', notes: '' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet, '--auditor', 'x']);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /invalid verdict/);
});

test('apply: missing auditor (no flag, no per-line field) → exit 1', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-missing-auditor' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /no auditor/);
});

test('apply: per-line "auditor" field satisfies the requirement without --auditor', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-per-line-auditor' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'line-auditor' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 0, r.stderr);
});

test('apply: unknown id at origin → exit 1', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-real-id' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, id: '2026-07-01-does-not-exist', origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /unknown\/missing id/);
});

// --- Staged validation (stage-then-commit: no write happens at all) ---

test('apply: staged validation failure (pre-existing invalid sibling) aborts with NO write, file byte-identical', () => {
  const dir = nextDir();
  // Two records in one file: `good` is the audit target, `bad` is already
  // structurally invalid (bad status enum) — pre-existing corruption that
  // makes the WHOLE-FILE at-rest validation of the staged content fail,
  // which must abort BEFORE any disk write.
  const good = rec({ id: '2026-07-01-restore-good' });
  const bad = rec({ id: '2026-07-01-restore-bad', status: 'not-a-real-status' });
  const f = jsonlFile(dir, 'ledger.jsonl', [good, bad]);
  const originalText = readFileSync(f, 'utf8');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...good, origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');

  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /staged validation failed/);
  assert.match(r.stderr, /no files were written/);
  assert.equal(readFileSync(f, 'utf8'), originalText, 'file must be byte-identical (never written)');
});

// --- Multi-file apply: stage-then-commit ordering ---

test('apply: origin file deleted between sample and apply → exit 1 BEFORE any other file is touched', () => {
  const dir = nextDir();
  const recA = rec({ id: '2026-07-01-multi-a' });
  const recB = rec({ id: '2026-07-01-multi-b' });
  const fileA = jsonlFile(dir, 'a.jsonl', [recA]);
  const fileB = jsonlFile(dir, 'b.jsonl', [recB]);
  const originalA = readFileSync(fileA, 'utf8');
  rmSync(fileB); // B vanishes between sample and apply

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, [
    JSON.stringify({ ...recA, origin: { file: fileA, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
    JSON.stringify({ ...recB, origin: { file: fileB, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
  ].join('\n') + '\n');

  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /cannot read origin/);
  assert.equal(readFileSync(fileA, 'utf8'), originalA, 'file A must be untouched');
});

test('apply: staged-validation failure in file B aborts before ANY write (A and B byte-identical)', () => {
  const dir = nextDir();
  const recA = rec({ id: '2026-07-01-stage-a' });
  const recB = rec({ id: '2026-07-01-stage-b' });
  const corrupt = rec({ id: '2026-07-01-stage-corrupt', confidence: 'super-sure' }); // pre-existing invalid sibling in B
  const fileA = jsonlFile(dir, 'a.jsonl', [recA]);
  const fileB = jsonlFile(dir, 'b.jsonl', [recB, corrupt]);
  const originalA = readFileSync(fileA, 'utf8');
  const originalB = readFileSync(fileB, 'utf8');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, [
    JSON.stringify({ ...recA, origin: { file: fileA, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
    JSON.stringify({ ...recB, origin: { file: fileB, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
  ].join('\n') + '\n');

  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /staged validation failed/);
  assert.equal(readFileSync(fileA, 'utf8'), originalA, 'file A must be byte-identical (staged abort precedes ALL writes)');
  assert.equal(readFileSync(fileB, 'utf8'), originalB, 'file B must be byte-identical');
});

// fs-level phase-3 failure: induced via the one-shot test fault-injection
// env var (SAMPLE_AUDIT_FAULT_WRITE_ONCE) — no cross-platform fs trick
// forces a mid-loop write failure deterministically (Windows renames
// straight over read-only targets, POSIX perms live on the directory).
// One-shot means the subsequent restore write on the same file succeeds,
// exercising the clean `restored:` accounting branch.
test('apply: fs-level write failure mid-loop prints applied/restored/not-attempted accounting', () => {
  const dir = nextDir();
  const recA = rec({ id: '2026-07-01-acct-a' });
  const recB = rec({ id: '2026-07-01-acct-b' });
  const recC = rec({ id: '2026-07-01-acct-c' });
  const fileA = jsonlFile(dir, 'a.jsonl', [recA]);
  const fileB = jsonlFile(dir, 'b.jsonl', [recB]);
  const fileC = jsonlFile(dir, 'c.jsonl', [recC]);
  const originalB = readFileSync(fileB, 'utf8');
  const originalC = readFileSync(fileC, 'utf8');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, [
    JSON.stringify({ ...recA, origin: { file: fileA, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
    JSON.stringify({ ...recB, origin: { file: fileB, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
    JSON.stringify({ ...recC, origin: { file: fileC, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
  ].join('\n') + '\n');

  const r = run(['apply', '--verdicts', worksheet, '--audited-at', '2026-07-09T00:00:00Z'], undefined,
    { SAMPLE_AUDIT_FAULT_WRITE_ONCE: 'b.jsonl' });
  assert.equal(r.status, 1);
  assert.match(r.stderr, /write failed for .*b\.jsonl.*fault injection/);
  assert.match(r.stderr, /accounting — applied: \[[^\]]*a\.jsonl\], restored: \[[^\]]*b\.jsonl\], not-attempted: \[[^\]]*c\.jsonl\]/);
  assert.ok(JSON.parse(readFileSync(fileA, 'utf8').trim()).audit, 'file A (applied) keeps its audit block');
  assert.equal(readFileSync(fileB, 'utf8'), originalB, 'file B restored/unchanged');
  assert.equal(readFileSync(fileC, 'utf8'), originalC, 'file C not attempted');
});

// --- gate math boundary ---

function gateWorksheet(dir, confirmedN, otherVerdict, otherN) {
  const entries = [];
  for (let i = 0; i < confirmedN; i++) entries.push({ id: `g-confirmed-${i}`, verdict: 'confirmed' });
  for (let i = 0; i < otherN; i++) entries.push({ id: `g-other-${i}`, verdict: otherVerdict });
  const p = join(dir, 'gate-worksheet.jsonl');
  writeFileSync(p, entries.map((e) => JSON.stringify(e)).join('\n') + '\n');
  return p;
}

test('gate: 18/20 confirmed = 0.90 precision → passes default threshold', () => {
  const dir = nextDir();
  const ws = gateWorksheet(dir, 18, 'refuted', 2);
  const r = run(['gate', '--verdicts', ws]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /precision: 0\.9000/);
  assert.match(r.stdout, /RESULT: PASS/);
});

test('gate: 17/20 confirmed = 0.85 precision → fails default threshold', () => {
  const dir = nextDir();
  const ws = gateWorksheet(dir, 17, 'refuted', 3);
  const r = run(['gate', '--verdicts', ws]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /precision: 0\.8500/);
  assert.match(r.stdout, /RESULT: FAIL/);
});

test('gate: total < 20 → exit 3 unless --allow-small', () => {
  const dir = nextDir();
  const ws = gateWorksheet(dir, 5, 'refuted', 0);
  const r1 = run(['gate', '--verdicts', ws]);
  assert.equal(r1.status, 3);
  const r2 = run(['gate', '--verdicts', ws, '--allow-small']);
  assert.equal(r2.status, 0, r2.stderr); // 5/5 confirmed = 1.0 >= 0.90
});

// --- CRLF and BOM inputs ---

test('sample: CRLF frontmatter .md input extracts cleanly', () => {
  const dir = nextDir();
  const lesson = rec({ id: '2026-07-01-crlf-fm' });
  const f = frontmatterMdFile(dir, 'crlf.md', lesson, { crlf: true });
  const r = run(['sample', f, '--n', '1', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  const ws = parseJsonl(r.stdout);
  assert.equal(ws.length, 1);
  assert.equal(ws[0].id, '2026-07-01-crlf-fm');
});

test('sample: UTF-8 BOM on a .jsonl input is stripped, first record still parses', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-bom-jsonl' });
  const p = join(dir, 'bom.jsonl');
  writeFileSync(p, '﻿' + JSON.stringify(target) + '\n');
  const r = run(['sample', p, '--n', '1', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  const ws = parseJsonl(r.stdout);
  assert.equal(ws.length, 1);
  assert.equal(ws[0].id, '2026-07-01-bom-jsonl');
});

test('apply: BOM + CRLF jsonl input round-trips and restores byte-for-byte on the untouched line', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-bom-crlf-target' });
  const untouched = rec({ id: '2026-07-01-bom-crlf-untouched' });
  const p = join(dir, 'bomcrlf.jsonl');
  const content = '﻿' + [target, untouched].map((r) => JSON.stringify(r)).join('\r\n') + '\r\n';
  writeFileSync(p, content);

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, origin: { file: p, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet, '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r.status, 0, r.stderr);

  const newContent = readFileSync(p, 'utf8');
  assert.ok(newContent.includes('\r\n'), 'CRLF line endings preserved');
  const untouchedLine = newContent.split('\r\n').find((l) => l.includes('bom-crlf-untouched'));
  assert.equal(untouchedLine, JSON.stringify(untouched));
});

// --- Absent-id / drift errors at apply time ---
// (The in-memory drain check after applyJsonlLineEditsInRange is defense in
// depth behind these preflight errors: with findAuditFenceRange bounded to
// the same section as extractLessonsJsonl, an id the preflight resolves is
// always drained, so the CLI-visible failure for an absent id is preflight's.)

test('apply: worksheet id absent from the fenced block at apply time → exit 1 naming the id', () => {
  const dir = nextDir();
  const present = rec({ id: '2026-07-01-fence-present', captured_by: 'end-session-wiki' });
  const f = bodyLessonsMdFile(dir, 'session.md', [present]);
  const ghost = rec({ id: '2026-07-01-fence-ghost', captured_by: 'end-session-wiki' });
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...ghost, origin: { file: f, carrier: 'body-lessons' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /2026-07-01-fence-ghost/);
});

test('apply: body-lessons carrier against a file with NO ## Lessons section → exit 1', () => {
  const dir = nextDir();
  const lesson = rec({ id: '2026-07-01-no-section' });
  const f = frontmatterMdFile(dir, 'topic.md', lesson); // has frontmatter carrier only
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...lesson, origin: { file: f, carrier: 'body-lessons' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /unknown\/missing id/);
});

test('apply: frontmatter carrier against a file with NO lesson: block → exit 1', () => {
  const dir = nextDir();
  const lesson = rec({ id: '2026-07-01-no-fm-block', captured_by: 'end-session-wiki' });
  const f = bodyLessonsMdFile(dir, 'session.md', [lesson]); // body carrier only
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...lesson, origin: { file: f, carrier: 'frontmatter' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /unknown\/missing id/);
});

// --- Fence END-boundary edits ---

test('apply: last record (immediately before the closing fence) and middle record both edit cleanly', () => {
  const dir = nextDir();
  const r1 = rec({ id: '2026-07-01-fence-first', captured_by: 'end-session-wiki' });
  const r2 = rec({ id: '2026-07-01-fence-middle', captured_by: 'end-session-wiki' });
  const r3 = rec({ id: '2026-07-01-fence-last', captured_by: 'end-session-wiki' });
  const f = bodyLessonsMdFile(dir, 'session.md', [r1, r2, r3]);
  const originalLines = readFileSync(f, 'utf8').split('\n');

  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, [
    JSON.stringify({ ...r2, origin: { file: f, carrier: 'body-lessons' }, verdict: 'confirmed', notes: '', auditor: 'x' }),
    JSON.stringify({ ...r3, origin: { file: f, carrier: 'body-lessons' }, verdict: 'stale', notes: '', auditor: 'x' }),
  ].join('\n') + '\n');
  const r = run(['apply', '--verdicts', worksheet, '--audited-at', '2026-07-09T00:00:00Z']);
  assert.equal(r.status, 0, r.stderr);

  const newLines = readFileSync(f, 'utf8').split('\n');
  assert.equal(newLines.length, originalLines.length);
  const firstIdx = originalLines.findIndex((l) => l.includes('fence-first'));
  assert.equal(newLines[firstIdx], originalLines[firstIdx], 'un-verdicted first record untouched');
  const middle = JSON.parse(newLines[originalLines.findIndex((l) => l.includes('fence-middle'))]);
  assert.equal(middle.audit.verdict, 'confirmed');
  const last = JSON.parse(newLines[originalLines.findIndex((l) => l.includes('fence-last'))]);
  assert.equal(last.audit.verdict, 'stale');
  // The fence and following section survive intact.
  assert.ok(newLines.some((l) => l === '```'), 'closing fence intact');
  assert.ok(newLines.some((l) => l === '## Raw Conversation'), 'following h2 intact');
});

// --- sample --out ---

test('sample: --out writes the exact stdout form to the file', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [
    rec({ id: '2026-07-01-out-a' }), rec({ id: '2026-07-01-out-b' }), rec({ id: '2026-07-01-out-c' }),
  ]);
  const outPath = join(dir, 'worksheet.jsonl');
  const r1 = run(['sample', f, '--n', '3', '--seed', '5', '--allow-small', '--out', outPath]);
  assert.equal(r1.status, 0, r1.stderr);
  assert.equal(r1.stdout, '', 'no stdout when --out is given');
  const r2 = run(['sample', f, '--n', '3', '--seed', '5', '--allow-small']);
  assert.equal(readFileSync(outPath, 'utf8'), r2.stdout, '--out content == stdout form');
});

test('sample: unwritable --out path → exit 2 with clean error', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec({ id: '2026-07-01-out-bad' })]);
  const r = run(['sample', f, '--n', '1', '--allow-small', '--out', join(dir, 'no-such-subdir', 'w.jsonl')]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /cannot write --out/);
  assert.ok(!r.stderr.includes('    at '), 'no stack trace');
});

test('sample: unreadable input file → exit 2 with clean error', () => {
  const dir = nextDir();
  const r = run(['sample', join(dir, 'no-such-file.jsonl')]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /cannot read /);
  assert.ok(!r.stderr.includes('    at '), 'no stack trace');
});

// --- sample skip accounting (visible, never silent) ---

test('sample: malformed / id-less / invalid records are counted on stderr and excluded', () => {
  const dir = nextDir();
  const valid = rec({ id: '2026-07-01-skip-valid' });
  const invalid = rec({ id: '2026-07-01-skip-invalid', confidence: 'super-sure' });
  const p = join(dir, 'ledger.jsonl');
  writeFileSync(p, [
    JSON.stringify(valid),
    '{not json',
    JSON.stringify({ claim: 'no id here' }),
    JSON.stringify(invalid),
  ].join('\n') + '\n');
  const r = run(['sample', p, '--n', '10', '--allow-small']);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stderr, /skipped 1 malformed line\(s\), 1 id-less record\(s\), excluded 1 invalid record\(s\)/);
  const ws = parseJsonl(r.stdout);
  assert.deepEqual(ws.map((w) => w.id), ['2026-07-01-skip-valid']);
});

// --- Worksheet-entry guard branches ---

test('apply: worksheet entry missing origin → exit 1', () => {
  const dir = nextDir();
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ id: '2026-07-01-no-origin', verdict: 'confirmed', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /missing id\/origin/);
});

test('apply: worksheet entry missing origin.carrier → exit 1', () => {
  const dir = nextDir();
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ id: '2026-07-01-no-carrier', origin: { file: join(dir, 'x.jsonl') }, verdict: 'confirmed', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /missing id\/origin/);
});

test('apply: worksheet entry missing id → exit 1', () => {
  const dir = nextDir();
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ origin: { file: join(dir, 'x.jsonl'), carrier: 'jsonl' }, verdict: 'confirmed', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /missing id\/origin/);
});

// --- Worksheet duplicate ids + claim cross-check ---

test('apply: duplicate worksheet id → exit 2 naming the id', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-dup-ws' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const line = JSON.stringify({ ...target, origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' });
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, line + '\n' + line + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /duplicate worksheet id "2026-07-01-dup-ws"/);
});

test('apply: claim mismatch between worksheet and origin → exit 1 (wrong-file guard)', () => {
  const dir = nextDir();
  const target = rec({ id: '2026-07-01-claim-mismatch' });
  const f = jsonlFile(dir, 'ledger.jsonl', [target]);
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, JSON.stringify({ ...target, claim: 'A DIFFERENT claim entirely.', origin: { file: f, carrier: 'jsonl' }, verdict: 'confirmed', notes: '', auditor: 'x' }) + '\n');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 1);
  assert.match(r.stderr, /does not match sampled record/);
});

// --- apply on empty worksheet ---

test('apply: empty worksheet → exit 0, nothing to do', () => {
  const dir = nextDir();
  const worksheet = join(dir, 'worksheet.jsonl');
  writeFileSync(worksheet, '');
  const r = run(['apply', '--verdicts', worksheet]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /nothing to do/);
});

// --- gate exit codes, separately ---

test('gate: unverdicted line → exit 3 (distinct from small-sample)', () => {
  const dir = nextDir();
  const entries = [];
  for (let i = 0; i < 20; i++) entries.push({ id: `g-uv-${i}`, verdict: i === 7 ? '' : 'confirmed' });
  const ws = join(dir, 'ws.jsonl');
  writeFileSync(ws, entries.map((e) => JSON.stringify(e)).join('\n') + '\n');
  const r = run(['gate', '--verdicts', ws]);
  assert.equal(r.status, 3);
  assert.match(r.stderr, /not fully verdicted/);
});

test('gate: empty worksheet with --allow-small → precision 0, exit 1 (never a silent pass)', () => {
  const dir = nextDir();
  const ws = join(dir, 'ws.jsonl');
  writeFileSync(ws, '');
  const r = run(['gate', '--verdicts', ws, '--allow-small']);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /precision: 0\.0000/);
  assert.match(r.stdout, /RESULT: FAIL/);
});

test('gate: --threshold out of (0, 1] → exit 2', () => {
  const dir = nextDir();
  const ws = gateWorksheet(dir, 20, 'refuted', 0);
  for (const bad of ['0', '1.5', '-0.1', 'abc']) {
    const r = run(['gate', '--verdicts', ws, '--threshold', bad]);
    assert.equal(r.status, 2, `--threshold ${bad} should exit 2, got ${r.status}`);
    assert.match(r.stderr, /--threshold must be a number in \(0, 1\]/);
  }
});

// --- sample numeric flag validation ---

test('sample: non-integer --n → exit 2', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec({ id: '2026-07-01-badn' })]);
  for (const bad of ['abc', '1.5', '-3']) {
    const r = run(['sample', f, '--n', bad, '--allow-small']);
    assert.equal(r.status, 2, `--n ${bad} should exit 2, got ${r.status}`);
    assert.match(r.stderr, /--n must be a non-negative integer/);
  }
});

test('sample: non-integer --seed → exit 2', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec({ id: '2026-07-01-badseed' })]);
  for (const bad of ['xyz', '1.5']) {
    const r = run(['sample', f, '--n', '1', '--allow-small', '--seed', bad]);
    assert.equal(r.status, 2, `--seed ${bad} should exit 2, got ${r.status}`);
    assert.match(r.stderr, /--seed must be an integer/);
  }
});

// --- atomicWrite code-filter branch ---
// Not tested directly: the fs functions are destructured named imports, so
// there is no clean injection seam to force renameSync to throw a specific
// non-Windows code, and inducing a real one cross-platform is inherently
// flaky (per review guidance: skip rather than write a flaky test). The
// Windows-code path is exercised by the accounting test above (win32).
test('atomicWrite: non-Windows-code rename failure rethrows without unlinking the original', { skip: 'no clean injection seam for named fs imports; do not write a flaky fs-error test' }, () => {});

// --- CLI hygiene ---

test('CLI: unknown verb → exit 2 with usage', () => {
  const r = run(['bogus-verb']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage:/);
});

test('CLI: unknown flag → exit 2 with usage', () => {
  const dir = nextDir();
  const f = jsonlFile(dir, 'ledger.jsonl', [rec()]);
  const r = run(['sample', f, '--bogus-flag']);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /unknown flag/);
});

test('CLI: --help prints usage, exit 0', () => {
  const r = run(['--help']);
  assert.equal(r.status, 0);
  assert.match(r.stdout, /usage:/);
});

test('CLI: no verb → exit 2 with usage', () => {
  const r = run([]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage:/);
});
