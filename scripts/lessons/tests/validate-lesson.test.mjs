// scripts/lessons/tests/validate-lesson.test.mjs
import { test, after } from 'node:test';
import assert from 'node:assert/strict';
import { spawnSync } from 'node:child_process';
import { mkdtempSync, rmSync, writeFileSync } from 'node:fs';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { fileURLToPath } from 'node:url';
import {
  validateRecord, validateMarkdown, validateJsonlText, parseYamlSubset, extractFrontmatter,
  extractLessonsJsonl,
} from '../validate-lesson.mjs';

const VALID = {
  id: '2026-07-08-example-widget-api-429',
  claim: 'Widget API returns 429 under concurrent writes; serialize calls.',
  source: { type: 'session', ref: 'transcripts/session-42.jsonl:120-160' },
  captured_at: '2026-07-08T14:32:00Z',
  captured_by: 'manual',
  confidence: 'high',
  scope: ['harness'],
  status: 'active',
};

test('valid record → no failures', () => {
  assert.deepEqual(validateRecord(VALID), []);
});

test('valid frontmatter record (.md) → isLesson true, no failures', () => {
  const md = `---
type: reference
lesson:
  id: 2026-07-08-example-widget-api-429
  claim: "Widget API returns 429 under concurrent writes; serialize calls."
  source:
    type: session
    ref: "transcripts/session-42.jsonl:120-160"
  captured_at: 2026-07-08T14:32:00Z
  captured_by: manual
  confidence: high
  scope:
    - harness
  status: active
---

Body text here.
`;
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.equal(result.id, '2026-07-08-example-widget-api-429');
  assert.deepEqual(result.fails, []);
});

test('md file with NO lesson block → passes as "not a lesson"', () => {
  const md = `---
type: reference
title: some unrelated memory file
---

Body text, no lesson here.
`;
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, false);
  assert.deepEqual(result.fails, []);
});

test('md file with no frontmatter at all → passes as "not a lesson"', () => {
  const md = '# Just a heading\n\nSome prose.\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, false);
});

test('valid JSONL stream (multiple records) → all pass', () => {
  const line1 = JSON.stringify(VALID);
  const line2 = JSON.stringify({ ...VALID, id: '2026-07-08-second-lesson' });
  const results = validateJsonlText(`${line1}\n\n${line2}\n`);
  assert.equal(results.length, 2);
  assert.deepEqual(results[0].fails, []);
  assert.deepEqual(results[1].fails, []);
});

test('blank lines in JSONL are skipped (not counted as records)', () => {
  const results = validateJsonlText(`\n\n${JSON.stringify(VALID)}\n\n`);
  assert.equal(results.length, 1);
});

// --- Required-field failure classes ---

for (const field of ['id', 'claim', 'captured_at', 'captured_by', 'confidence', 'status']) {
  test(`missing required field: ${field} → fails`, () => {
    const rec = { ...VALID };
    delete rec[field];
    const fails = validateRecord(rec);
    assert.ok(fails.some((f) => f.includes(`missing required field: ${field}`)), fails.join('; '));
  });
}

test('missing source.type → fails', () => {
  const rec = { ...VALID, source: { ref: VALID.source.ref } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing required field: source.type')));
});

test('missing source.ref → fails', () => {
  const rec = { ...VALID, source: { type: VALID.source.type } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing required field: source.ref')));
});

test('missing scope (empty array) → fails', () => {
  const rec = { ...VALID, scope: [] };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing required field: scope')));
});

// --- Bad id ---

test('bad id (not YYYY-MM-DD-<kebab-slug>) → fails', () => {
  for (const badId of ['2026-7-8-foo', 'not-a-date-foo', '2026-07-08', '2026-07-08-Has-Upper', '2026-07-08_underscore']) {
    const fails = validateRecord({ ...VALID, id: badId });
    assert.ok(fails.some((f) => f.includes('invalid id format')), `expected id failure for "${badId}", got: ${fails.join('; ')}`);
  }
});

// --- Bad enums ---

test('bad source.type enum → fails', () => {
  const fails = validateRecord({ ...VALID, source: { ...VALID.source, type: 'bogus' } });
  assert.ok(fails.some((f) => f.includes('invalid source.type')));
});

test('bad confidence enum → fails', () => {
  const fails = validateRecord({ ...VALID, confidence: 'super-sure' });
  assert.ok(fails.some((f) => f.includes('invalid confidence')));
});

test('bad status enum → fails', () => {
  const fails = validateRecord({ ...VALID, status: 'maybe' });
  assert.ok(fails.some((f) => f.includes('invalid status')));
});

test('bad captured_by enum → fails', () => {
  const fails = validateRecord({ ...VALID, captured_by: 'random-script' });
  assert.ok(fails.some((f) => f.includes('invalid captured_by')));
});

test('scope tag outside controlled list → fails', () => {
  const fails = validateRecord({ ...VALID, scope: ['harness', 'not-a-real-tag'] });
  assert.ok(fails.some((f) => f.includes('scope has tag(s) outside the controlled list')));
});

test('bad captured_at (not ISO-8601 UTC) → fails', () => {
  for (const bad of ['2026-07-08', '07/08/2026 14:32', '2026-07-08T14:32:00']) {
    const fails = validateRecord({ ...VALID, captured_at: bad });
    assert.ok(fails.some((f) => f.includes('invalid captured_at')), `expected captured_at failure for "${bad}"`);
  }
});

// --- Rule 4: audit is single-writer (capture-time vs at-rest) ---

const WELL_FORMED_AUDIT = { audited_at: '2026-07-09T00:00:00Z', verdict: 'confirmed', auditor: 'lesson-auditor' };

test('--capture: ANY audit block → fails (rule 4), even well-formed', () => {
  const rec = { ...VALID, audit: WELL_FORMED_AUDIT };
  const fails = validateRecord(rec, { capture: true });
  assert.ok(fails.some((f) => f.includes('rule 4 violation')), fails.join('; '));
});

test('default (at-rest): well-formed audit block → passes', () => {
  const rec = { ...VALID, audit: WELL_FORMED_AUDIT };
  assert.deepEqual(validateRecord(rec), []);
});

test('default (at-rest): audit missing verdict → fails (rule 4)', () => {
  const rec = { ...VALID, audit: { audited_at: '2026-07-09T00:00:00Z', auditor: 'lesson-auditor' } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing verdict')), fails.join('; '));
});

test('default (at-rest): audit missing auditor → fails (rule 4)', () => {
  const rec = { ...VALID, audit: { audited_at: '2026-07-09T00:00:00Z', verdict: 'confirmed' } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing auditor')), fails.join('; '));
});

test('default (at-rest): audit missing audited_at → fails (rule 4)', () => {
  const rec = { ...VALID, audit: { verdict: 'confirmed', auditor: 'lesson-auditor' } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('missing audited_at')), fails.join('; '));
});

test('default (at-rest): audit with bad verdict enum → fails (rule 4)', () => {
  const rec = { ...VALID, audit: { ...WELL_FORMED_AUDIT, verdict: 'plausible' } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('invalid verdict')), fails.join('; '));
});

test('default (at-rest): audit with bad audited_at → fails (rule 4)', () => {
  const rec = { ...VALID, audit: { ...WELL_FORMED_AUDIT, audited_at: 'yesterday' } };
  const fails = validateRecord(rec);
  assert.ok(fails.some((f) => f.includes('invalid audited_at')), fails.join('; '));
});

test('audit block absent → no rule-4 failure in either mode', () => {
  assert.ok(!validateRecord(VALID).some((f) => f.includes('rule 4')));
  assert.ok(!validateRecord(VALID, { capture: true }).some((f) => f.includes('rule 4')));
});

test('default (at-rest): audit key with null / "" / [] value → malformed-audit failure (not a silent pass)', () => {
  for (const v of [null, '', []]) {
    const fails = validateRecord({ ...VALID, audit: v });
    assert.ok(fails.some((f) => f.includes('malformed audit block: not an object')), `audit:${JSON.stringify(v)} passed clean: ${fails.join('; ')}`);
  }
});

test('default (at-rest): audit as a scalar string → malformed-audit failure', () => {
  const fails = validateRecord({ ...VALID, audit: 'confirmed' });
  assert.ok(fails.some((f) => f.includes('malformed audit block: not an object')));
});

// --- supersedes / superseded_by accepted ---

test('supersedes / superseded_by present → accepted (no failures)', () => {
  const rec = { ...VALID, supersedes: '2026-07-01-old-lesson' };
  assert.deepEqual(validateRecord(rec), []);
  const rec2 = { ...VALID, id: '2026-07-01-old-lesson', status: 'superseded', superseded_by: '2026-07-08-example-widget-api-429' };
  assert.deepEqual(validateRecord(rec2), []);
});

// --- YAML subset parser sanity (used by validateMarkdown) ---

test('extractFrontmatter returns null when no closing delimiter', () => {
  assert.equal(extractFrontmatter('---\nfoo: bar\n'), null);
});

test('parseYamlSubset handles nested maps, block lists, and quoted scalars', () => {
  const parsed = parseYamlSubset('a: "hello world"\nb:\n  c: 1\n  d:\n    - x\n    - y\n');
  assert.equal(parsed.a, 'hello world');
  assert.equal(parsed.b.c, '1');
  assert.deepEqual(parsed.b.d, ['x', 'y']);
});

test('parseYamlSubset accepts flush-style block lists (items at the SAME indent as the key)', () => {
  const parsed = parseYamlSubset('lesson:\n  scope:\n  - harness\n  - jira\n  status: active\n');
  assert.deepEqual(parsed.lesson.scope, ['harness', 'jira']);
  assert.equal(parsed.lesson.status, 'active');
});

test('frontmatter lesson with flush-style scope list validates clean', () => {
  const md = `---
lesson:
  id: 2026-07-08-flush-list-lesson
  claim: "Flush-style lists are valid YAML."
  source:
    type: session
    ref: "transcripts/session-1.jsonl:1-10"
  captured_at: 2026-07-08T14:32:00Z
  captured_by: manual
  confidence: high
  scope:
  - harness
  status: active
---
`;
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.deepEqual(result.fails, []);
});

// --- Scope must be a list ---

test('scalar scope (bare string) → fails "scope must be a list"', () => {
  const fails = validateRecord({ ...VALID, scope: 'harness' });
  assert.ok(fails.some((f) => f.includes('scope must be a list')), fails.join('; '));
});

// --- Capture-mode audit KEY presence (null / {} / "" all fail) ---

test('--capture: audit:null → fails (key presence, not value)', () => {
  const fails = validateRecord({ ...VALID, audit: null }, { capture: true });
  assert.ok(fails.some((f) => f.includes('rule 4 violation')), fails.join('; '));
});

test('--capture: audit:{} → fails (key presence, not value)', () => {
  const fails = validateRecord({ ...VALID, audit: {} }, { capture: true });
  assert.ok(fails.some((f) => f.includes('rule 4 violation')), fails.join('; '));
});

// --- lesson: key present but not a mapping ---

test('lesson: scalar value → isLesson true + named fail (not a free pass)', () => {
  const md = '---\ntype: reference\nlesson: just-a-string\n---\n\nBody.\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.ok(result.fails.some((f) => f.includes('not a mapping')), result.fails.join('; '));
});

// --- Tab indentation in the lesson block ---

test('tab-indented lesson block → clear "tab indentation" fail, not misleading missing-field noise', () => {
  const md = '---\nlesson:\n\tid: 2026-07-08-tabbed\n\tclaim: "x"\n---\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.ok(result.fails.some((f) => f.includes('tab indentation not supported')), result.fails.join('; '));
});

// --- Duplicate ids within one JSONL input ---

test('duplicate id within one JSONL input → fails on the second record, names the rule', () => {
  const line = JSON.stringify(VALID);
  const results = validateJsonlText(`${line}\n${line}\n`);
  assert.equal(results.length, 2);
  assert.deepEqual(results[0].fails, []);
  assert.ok(results[1].fails.some((f) => f.includes('duplicate id')), results[1].fails.join('; '));
});

test('malformed JSON line is isolated — other lines still validated', () => {
  const good = JSON.stringify(VALID);
  const results = validateJsonlText(`{not json\n${good}\n`);
  assert.equal(results.length, 2);
  assert.ok(results[0].fails.some((f) => f.includes('invalid JSON')));
  assert.deepEqual(results[1].fails, []);
});

// --- Body ## Lessons block (the end-session-wiki form) ---

const BODY_NOTE = (jsonlLines) => `---
date: 2026-07-08T14:32:00Z
type: session
---

Preamble.

## Summary

Stuff.

## Lessons

\`\`\`jsonl
${jsonlLines}
\`\`\`

## Raw Conversation

> [!note]- Raw conversation
> hi
`;

test('valid body ## Lessons jsonl block → isLesson true, all body records pass', () => {
  const rec = { ...VALID, captured_by: 'end-session-wiki' };
  const result = validateMarkdown(BODY_NOTE(JSON.stringify(rec)));
  assert.equal(result.isLesson, true);
  assert.equal(result.fmLesson, false);
  assert.equal(result.bodyRecords.length, 1);
  assert.deepEqual(result.bodyRecords[0].fails, []);
});

test('invalid body record → fails naming the rule', () => {
  const rec = { ...VALID, confidence: 'sure' };
  const result = validateMarkdown(BODY_NOTE(JSON.stringify(rec)));
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('invalid confidence')));
});

test('malformed JSON line in body block → fails as invalid JSON', () => {
  const result = validateMarkdown(BODY_NOTE('{oops'));
  assert.equal(result.isLesson, true);
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('invalid JSON')));
});

test('body records honor --capture (audit key fails)', () => {
  const rec = { ...VALID, audit: null };
  const result = validateMarkdown(BODY_NOTE(JSON.stringify(rec)), { capture: true });
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('rule 4 violation')));
});

test('note with BOTH frontmatter lesson and body block validates both', () => {
  const bodyRec = { ...VALID, id: '2026-07-08-body-lesson', captured_by: 'end-session-wiki' };
  const md = `---
lesson:
  id: 2026-07-08-fm-lesson
  claim: "Frontmatter lesson."
  source:
    type: session
    ref: "transcripts/session-1.jsonl:1-10"
  captured_at: 2026-07-08T14:32:00Z
  captured_by: manual
  confidence: high
  scope:
    - harness
  status: bogus-status
---

## Lessons

\`\`\`jsonl
${JSON.stringify(bodyRec)}
\`\`\`
`;
  const result = validateMarkdown(md);
  assert.equal(result.fmLesson, true);
  assert.equal(result.id, '2026-07-08-fm-lesson');
  assert.ok(result.fails.some((f) => f.includes('invalid status')));
  assert.equal(result.bodyRecords.length, 1);
  assert.deepEqual(result.bodyRecords[0].fails, []);
});

test('extractLessonsJsonl: section bounded by the next h2; absent section → null', () => {
  assert.equal(extractLessonsJsonl('## Summary\n\nno lessons here\n'), null);
  const result = extractLessonsJsonl('## Lessons\n\n```jsonl\n{"a":1}\n```\n\n## Raw Conversation\n\n```jsonl\n{"b":2}\n```\n');
  assert.equal(result.jsonl, '{"a":1}');
});

// --- Malformed ## Lessons section must FAIL, not pass as not-a-lesson ---

test('## Lessons heading with NO fenced block → named failure (isLesson true)', () => {
  const md = '## Summary\n\nx\n\n## Lessons\n\nJust prose, no fence.\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.equal(result.bodyRecords.length, 1);
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('no fenced jsonl block')), result.bodyRecords[0].fails.join('; '));
});

test('## Lessons heading with an UNLABELED fence → named failure', () => {
  const md = '## Lessons\n\n```\n{"a":1}\n```\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('not labeled jsonl')), result.bodyRecords[0].fails.join('; '));
});

test('## Lessons heading with an UNCLOSED jsonl fence → named failure', () => {
  const md = '## Lessons\n\n```jsonl\n{"a":1}\n';
  const result = validateMarkdown(md);
  assert.equal(result.isLesson, true);
  assert.ok(result.bodyRecords[0].fails.some((f) => f.includes('unclosed')), result.bodyRecords[0].fails.join('; '));
});

test('CLI: .md with malformed ## Lessons section → exit 1, section-level label', () => {
  const p = join(CLI_TMP, 'malformed-section.md');
  writeFileSync(p, '## Lessons\n\nno fence here\n');
  const r = runCliProc([p]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /FAIL body ## Lessons section/);
});

// --- CLI (spawned end-to-end) ---

const SCRIPT = fileURLToPath(new URL('../validate-lesson.mjs', import.meta.url));
const CLI_TMP = mkdtempSync(join(tmpdir(), 'lessons-cli-test-'));
after(() => rmSync(CLI_TMP, { recursive: true, force: true }));

const runCliProc = (args, input) =>
  spawnSync(process.execPath, [SCRIPT, ...args], { encoding: 'utf8', input });

test('CLI: valid .jsonl file → exit 0, PASS output', () => {
  const p = join(CLI_TMP, 'valid.jsonl');
  writeFileSync(p, JSON.stringify(VALID) + '\n');
  const r = runCliProc([p]);
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /^PASS /m);
});

test('CLI: invalid .jsonl file → exit 1, FAIL output naming the rule', () => {
  const p = join(CLI_TMP, 'invalid.jsonl');
  writeFileSync(p, JSON.stringify({ ...VALID, status: 'maybe' }) + '\n');
  const r = runCliProc([p]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /invalid status/);
});

test('CLI: --capture works BEFORE and AFTER the path', () => {
  const p = join(CLI_TMP, 'audited.jsonl');
  writeFileSync(p, JSON.stringify({ ...VALID, audit: { audited_at: '2026-07-09T00:00:00Z', verdict: 'confirmed', auditor: 'a' } }) + '\n');
  assert.equal(runCliProc([p]).status, 0);              // at-rest: well-formed audit passes
  assert.equal(runCliProc(['--capture', p]).status, 1); // flag before path
  assert.equal(runCliProc([p, '--capture']).status, 1); // flag after path
});

test('CLI: stdin `-` mode validates JSONL from stdin', () => {
  const ok = runCliProc(['-'], JSON.stringify(VALID) + '\n');
  assert.equal(ok.status, 0, ok.stderr);
  const bad = runCliProc(['-'], JSON.stringify({ ...VALID, confidence: 'nope' }) + '\n');
  assert.equal(bad.status, 1);
});

test('CLI: no args → exit 2 with usage', () => {
  const r = runCliProc([]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /usage:/);
});

test('CLI: nonexistent file → clean one-line error + exit 2 (no stack trace)', () => {
  const r = runCliProc([join(CLI_TMP, 'no-such-file.jsonl')]);
  assert.equal(r.status, 2);
  assert.match(r.stderr, /validate-lesson: cannot read /);
  assert.ok(!r.stderr.includes('at '), 'stderr must not contain a stack trace');
});

test('CLI: .md routing — not-a-lesson note passes; lesson note validated', () => {
  const plain = join(CLI_TMP, 'plain.md');
  writeFileSync(plain, '---\ntype: reference\n---\n\nJust memory.\n');
  const r1 = runCliProc([plain]);
  assert.equal(r1.status, 0);
  assert.match(r1.stdout, /not a lesson/);

  const lessonMd = join(CLI_TMP, 'lesson.md');
  writeFileSync(lessonMd, `---
lesson:
  id: 2026-07-08-cli-md-lesson
  claim: "CLI routes .md correctly."
  source:
    type: session
    ref: "transcripts/session-1.jsonl:1-10"
  captured_at: 2026-07-08T14:32:00Z
  captured_by: manual
  confidence: high
  scope:
    - harness
  status: active
---
`);
  const r2 = runCliProc([lessonMd]);
  assert.equal(r2.status, 0, r2.stdout + r2.stderr);
  assert.match(r2.stdout, /PASS 2026-07-08-cli-md-lesson/);
});

test('CLI: .md with invalid BODY ## Lessons record → exit 1', () => {
  const p = join(CLI_TMP, 'body.md');
  writeFileSync(p, BODY_NOTE(JSON.stringify({ ...VALID, scope: ['not-a-tag'] })));
  const r = runCliProc([p]);
  assert.equal(r.status, 1);
  assert.match(r.stdout, /outside the controlled list/);
});

test('CLI: UTF-8 BOM at head of file is stripped (first record not "invalid JSON")', () => {
  const p = join(CLI_TMP, 'bom.jsonl');
  writeFileSync(p, '﻿' + JSON.stringify(VALID) + '\n');
  const r = runCliProc([p]);
  assert.equal(r.status, 0, r.stdout + r.stderr);
});

test('CLI: BOM on stdin is stripped too', () => {
  const r = runCliProc(['-'], '﻿' + JSON.stringify(VALID) + '\n');
  assert.equal(r.status, 0, r.stdout + r.stderr);
});
