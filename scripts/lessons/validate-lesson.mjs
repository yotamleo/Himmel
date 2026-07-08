// scripts/lessons/validate-lesson.mjs — HIMMEL-767 deliverable 1: validate lesson
// provenance records against the schema in docs/internals/lesson-provenance.md.
//
// Input: a file path — .md (validates the `lesson:` block in YAML frontmatter,
// if present; a file with no lesson block passes as "not a lesson") or .jsonl
// (one record per line, blank lines skipped). `-` reads JSONL from stdin.
//
// Two modes (rule 4): `--capture` = strict capture-time — ANY `audit` block
// fails (the capture path never writes audit; writers validate with this).
// Default = at-rest — an `audit` block passes iff well-formed (audited_at
// ISO-8601, verdict in {confirmed,refuted,stale}, auditor non-empty); the
// deliverable-2 auditor and at-rest sweeps validate without the flag.
//
// Node stdlib only, no deps. Exit 1 if ANY record is invalid, else 0.
import { readFileSync } from 'node:fs';
import { extname } from 'node:path';

// --- Controlled vocabularies (kept in lockstep with docs/internals/lesson-provenance.md) ---
export const SOURCE_TYPES = ['session', 'cr', 'incident', 'operator', 'compound'];
export const CONFIDENCES = ['high', 'medium', 'low'];
export const STATUSES = ['active', 'superseded', 'invalidated', 'unverified'];
export const CAPTURE_WRITERS = ['end-session-wiki', 'memory-compound', 'daily-ingest', 'manual', 'auto-memory'];
export const SCOPE_TAGS = [
  'guardrails', 'cr', 'lanes', 'jira', 'handover', 'telegram', 'vault',
  'env-windows', 'env-macos', 'billing', 'harness',
];

export const AUDIT_VERDICTS = ['confirmed', 'refuted', 'stale'];

// Shape-only by design: the date prefix is a LABEL, not a validated timestamp
// (2026-13-99-foo passes). The real timestamp check lives on captured_at.
const ID_RE = /^\d{4}-\d{2}-\d{2}-[a-z0-9]+(?:-[a-z0-9]+)*$/;
const ISO_UTC_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z$/;

const nonEmpty = (v) => v !== undefined && v !== null && v !== '' && !(Array.isArray(v) && v.length === 0);

// --- Validate a single record object, return array of failed-rule strings (empty = valid).
// opts.capture: strict capture-time mode — ANY audit block fails (rule 4: the
// capture path never writes audit). Default (at-rest): an audit block passes
// iff well-formed (audited_at ISO-8601, verdict in enum, auditor non-empty). ---
export function validateRecord(rec, opts = {}) {
  const capture = opts.capture === true;
  const fails = [];
  if (!rec || typeof rec !== 'object') return ['record is not an object'];

  if (!nonEmpty(rec.id)) fails.push('missing required field: id');
  else if (!ID_RE.test(rec.id)) fails.push(`invalid id format (expected YYYY-MM-DD-<kebab-slug>): "${rec.id}"`);

  if (!nonEmpty(rec.claim)) fails.push('missing required field: claim');

  const sourceType = rec.source && rec.source.type;
  const sourceRef = rec.source && rec.source.ref;
  if (!nonEmpty(sourceType)) fails.push('missing required field: source.type');
  else if (!SOURCE_TYPES.includes(sourceType)) fails.push(`invalid source.type (expected one of ${SOURCE_TYPES.join('|')}): "${sourceType}"`);
  if (!nonEmpty(sourceRef)) fails.push('missing required field: source.ref');

  if (!nonEmpty(rec.captured_at)) fails.push('missing required field: captured_at');
  else if (!ISO_UTC_RE.test(rec.captured_at) || Number.isNaN(Date.parse(rec.captured_at))) {
    fails.push(`invalid captured_at (expected ISO-8601 UTC, e.g. 2026-07-08T14:32:00Z): "${rec.captured_at}"`);
  }

  if (!nonEmpty(rec.captured_by)) fails.push('missing required field: captured_by');
  else if (!CAPTURE_WRITERS.includes(rec.captured_by)) fails.push(`invalid captured_by (expected one of ${CAPTURE_WRITERS.join('|')}): "${rec.captured_by}"`);

  if (!nonEmpty(rec.confidence)) fails.push('missing required field: confidence');
  else if (!CONFIDENCES.includes(rec.confidence)) fails.push(`invalid confidence (expected one of ${CONFIDENCES.join('|')}): "${rec.confidence}"`);

  if (!nonEmpty(rec.scope)) {
    fails.push('missing required field: scope');
  } else if (!Array.isArray(rec.scope)) {
    fails.push('scope must be a list (one or more tags), got a scalar');
  } else {
    const bad = rec.scope.filter((t) => !SCOPE_TAGS.includes(t));
    if (bad.length) fails.push(`scope has tag(s) outside the controlled list (${SCOPE_TAGS.join(',')}): ${bad.join(',')}`);
  }

  if (!nonEmpty(rec.status)) fails.push('missing required field: status');
  else if (!STATUSES.includes(rec.status)) fails.push(`invalid status (expected one of ${STATUSES.join('|')}): "${rec.status}"`);

  // Rule 4: audit is single-writer (the deliverable-2 auditor only).
  // --capture (capture-time): the audit KEY present at all — even null / {} /
  // "" — fails; the capture path never writes audit in any form. Default
  // (at-rest): key present → the value must be a well-formed audit OBJECT
  // (null / "" / [] / scalar are malformed, not invisible).
  if (capture) {
    if (Object.prototype.hasOwnProperty.call(rec, 'audit')) {
      fails.push('audit key present in capture-time validation (--capture) — rule 4 violation (the capture path never writes audit; only the deliverable-2 auditor does)');
    }
  } else if (Object.prototype.hasOwnProperty.call(rec, 'audit')) {
    const a = rec.audit;
    if (a === null || typeof a !== 'object' || Array.isArray(a)) {
      fails.push('malformed audit block: not an object — rule 4 (expected {audited_at, verdict, auditor})');
    } else {
      if (!nonEmpty(a.audited_at)) fails.push('malformed audit block: missing audited_at — rule 4');
      else if (!ISO_UTC_RE.test(a.audited_at) || Number.isNaN(Date.parse(a.audited_at))) {
        fails.push(`malformed audit block: invalid audited_at (expected ISO-8601 UTC): "${a.audited_at}" — rule 4`);
      }
      if (!nonEmpty(a.verdict)) fails.push('malformed audit block: missing verdict — rule 4');
      else if (!AUDIT_VERDICTS.includes(a.verdict)) fails.push(`malformed audit block: invalid verdict (expected one of ${AUDIT_VERDICTS.join('|')}): "${a.verdict}" — rule 4`);
      if (!nonEmpty(a.auditor)) fails.push('malformed audit block: missing auditor — rule 4');
    }
  }

  return fails;
}

// --- Minimal YAML-subset parser: scalars, nested maps, block/inline lists of
// scalars, quoted strings. Scoped to the schema's fixed shape, not general YAML. ---
function stripQuotes(s) {
  if (s.length >= 2 && ((s[0] === '"' && s[s.length - 1] === '"') || (s[0] === "'" && s[s.length - 1] === "'"))) {
    return s.slice(1, -1);
  }
  return s;
}

export function parseYamlSubset(text) {
  const lines = [];
  for (const raw of text.split(/\r?\n/)) {
    if (raw.trim() === '' || /^\s*#/.test(raw)) continue;
    const indent = raw.match(/^(\s*)/)[1].length;
    lines.push({ indent, content: raw.slice(indent) });
  }
  let pos = 0;
  function parseBlock(baseIndent) {
    const obj = {};
    while (pos < lines.length && lines[pos].indent === baseIndent) {
      const { content } = lines[pos];
      const m = content.match(/^([A-Za-z0-9_.-]+):\s*(.*)$/);
      if (!m) { pos++; continue; }
      const key = m[1];
      const rawValue = m[2];
      pos++;
      if (rawValue === '') {
        // Block lists accept items at indent >= the key's indent: both the
        // indented style and the flush style (`- tag` at the SAME indent as
        // its key) are valid YAML.
        if (pos < lines.length && lines[pos].indent >= baseIndent && lines[pos].content.startsWith('- ')) {
          const listIndent = lines[pos].indent;
          const arr = [];
          while (pos < lines.length && lines[pos].indent === listIndent && lines[pos].content.startsWith('- ')) {
            arr.push(stripQuotes(lines[pos].content.slice(2).trim()));
            pos++;
          }
          obj[key] = arr;
        } else if (pos < lines.length && lines[pos].indent > baseIndent) {
          obj[key] = parseBlock(lines[pos].indent);
        } else {
          obj[key] = '';
        }
      } else if (rawValue.startsWith('[') && rawValue.endsWith(']')) {
        obj[key] = rawValue.slice(1, -1).split(',').map((s) => stripQuotes(s.trim())).filter((s) => s.length);
      } else {
        obj[key] = stripQuotes(rawValue);
      }
    }
    return obj;
  }
  return parseBlock(0);
}

// extractFrontmatter — returns the raw text between the first two `---` lines,
// or null if the file has no frontmatter block.
export function extractFrontmatter(text) {
  const lines = text.split(/\r?\n/);
  if (lines[0] !== '---') return null;
  const end = lines.slice(1).findIndex((l) => l === '---');
  if (end === -1) return null;
  return lines.slice(1, 1 + end).join('\n');
}

// extractLessonsJsonl — locates the `## Lessons` section in the note BODY
// (the end-session-wiki form; section ends at the next h2). Returns:
//   null               — no `## Lessons` heading at all (genuinely absent)
//   { jsonl }          — the raw text inside its fenced ```jsonl block
//   { error }          — heading present but the fenced jsonl block is
//                        missing, mislabeled, or unclosed (a malformed
//                        section must FAIL, not pass as "not a lesson")
export function extractLessonsJsonl(text) {
  const lines = text.split(/\r?\n/);
  const start = lines.findIndex((l) => /^## Lessons\s*$/.test(l));
  if (start === -1) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i])) { end = i; break; }
  }
  const section = lines.slice(start + 1, end);
  const fenceOpen = section.findIndex((l) => /^```jsonl\s*$/.test(l));
  if (fenceOpen === -1) {
    const anyFence = section.some((l) => /^```/.test(l));
    return {
      error: anyFence
        ? '## Lessons section present but its fenced block is not labeled jsonl — expected ```jsonl'
        : '## Lessons section present but no fenced jsonl block found — expected ```jsonl',
    };
  }
  const fenceClose = section.slice(fenceOpen + 1).findIndex((l) => /^```\s*$/.test(l));
  if (fenceClose === -1) return { error: '## Lessons section has an unclosed ```jsonl fence' };
  return { jsonl: section.slice(fenceOpen + 1, fenceOpen + 1 + fenceClose).join('\n') };
}

// validateMarkdown — validates BOTH lesson carriers a .md note can have:
// a `lesson:` YAML frontmatter block AND a body `## Lessons` fenced jsonl
// block (the end-session-wiki form). Returns { isLesson, fmLesson, id,
// fails, bodyRecords }. isLesson=false means neither carrier was found
// (passes, per design); fmLesson + fails/id cover the frontmatter record,
// bodyRecords is the per-line result array for the body block.
export function validateMarkdown(text, opts = {}) {
  const out = { isLesson: false, fmLesson: false, id: null, fails: [], bodyRecords: [] };
  const fm = extractFrontmatter(text);
  if (fm !== null) {
    const parsed = parseYamlSubset(fm);
    if (parsed.lesson !== undefined) {
      out.isLesson = true;
      out.fmLesson = true;
      if (typeof parsed.lesson !== 'object' || parsed.lesson === null || Array.isArray(parsed.lesson)) {
        // A present-but-non-mapping lesson key is a malformed record, NOT
        // "not a lesson" — a realistic LLM-writer failure mode.
        out.fails = ['lesson: frontmatter key present but not a mapping — expected a nested block of schema fields'];
      } else if (/^[ ]*\t/m.test(fm)) {
        // parseYamlSubset counts a tab as one indent char, which silently
        // truncates the block into misleading missing-field failures —
        // surface the real cause instead.
        out.fails = ['tab indentation not supported in lesson block — use spaces'];
      } else {
        out.id = parsed.lesson.id || null;
        out.fails = validateRecord(parsed.lesson, opts);
      }
    }
  }
  const body = extractLessonsJsonl(text);
  if (body !== null) {
    out.isLesson = true;
    out.bodyRecords = body.error
      ? [{ lineNo: null, id: null, fails: [body.error] }]
      : validateJsonlText(body.jsonl, opts);
  }
  return out;
}

// validateJsonlText — returns array of { lineNo, id, fails } for every
// non-blank line (a JSON-parse error surfaces as a single failed rule and
// never stops the remaining lines from being validated). Duplicate ids
// within one input fail: the ledger is append-only and ids are the
// deliverable-2 auditor's addressing keys, so a dup is silent corruption.
export function validateJsonlText(text, opts = {}) {
  const results = [];
  const seenIds = new Map(); // id -> first lineNo
  const lines = text.split(/\r?\n/);
  lines.forEach((raw, idx) => {
    if (raw.trim() === '') return;
    const lineNo = idx + 1;
    let rec;
    try {
      rec = JSON.parse(raw);
    } catch (e) {
      results.push({ lineNo, id: null, fails: [`invalid JSON: ${e.message}`] });
      return;
    }
    const fails = validateRecord(rec, opts);
    const id = rec && rec.id ? rec.id : null;
    if (id) {
      if (seenIds.has(id)) fails.push(`duplicate id "${id}" (first seen on line ${seenIds.get(id)}) — ids are unique addressing keys in an append-only ledger`);
      else seenIds.set(id, lineNo);
    }
    results.push({ lineNo, id, fails });
  });
  return results;
}

// --- CLI ---
// Strip a UTF-8 BOM (Windows editors/PowerShell 5.1 prepend one; it would
// otherwise make the first record "invalid JSON" / break frontmatter detection).
const stripBom = (s) => (s.charCodeAt(0) === 0xFEFF ? s.slice(1) : s);

function printJsonlResults(results, prefix = '') {
  let anyInvalid = false;
  for (const r of results) {
    // lineNo null = a section-level failure (e.g. malformed ## Lessons fence),
    // not tied to any one record line.
    const label = prefix + (r.id || (r.lineNo != null ? `line ${r.lineNo}` : '## Lessons section'));
    if (r.fails.length === 0) {
      process.stdout.write(`PASS ${label}\n`);
    } else {
      anyInvalid = true;
      process.stdout.write(`FAIL ${label}: ${r.fails.join('; ')}\n`);
    }
  }
  return anyInvalid;
}

function runCli(filePath, opts) {
  let text;
  try {
    text = readFileSync(filePath === '-' ? 0 : filePath, 'utf8');
  } catch (e) {
    process.stderr.write(`validate-lesson: cannot read ${filePath === '-' ? 'stdin' : filePath}: ${e.message}\n`);
    return 2;
  }
  text = stripBom(text);

  if (filePath === '-') {
    return printJsonlResults(validateJsonlText(text, opts)) ? 1 : 0;
  }

  const ext = extname(filePath).toLowerCase();

  if (ext === '.md') {
    const { isLesson, fmLesson, id, fails, bodyRecords } = validateMarkdown(text, opts);
    if (!isLesson) {
      process.stdout.write(`PASS ${filePath} — not a lesson (no lesson: frontmatter block or ## Lessons section)\n`);
      return 0;
    }
    let anyInvalid = false;
    if (fmLesson) {
      const label = id || `${filePath} (frontmatter lesson)`;
      if (fails.length === 0) {
        process.stdout.write(`PASS ${label}\n`);
      } else {
        anyInvalid = true;
        process.stdout.write(`FAIL ${label}: ${fails.join('; ')}\n`);
      }
    }
    if (printJsonlResults(bodyRecords, 'body ')) anyInvalid = true;
    return anyInvalid ? 1 : 0;
  }

  // Default: JSONL file.
  return printJsonlResults(validateJsonlText(text, opts)) ? 1 : 0;
}

if (process.argv[1]?.endsWith('validate-lesson.mjs')) {
  const args = process.argv.slice(2);
  const capture = args.includes('--capture');
  const positional = args.filter((a) => a !== '--capture');
  const filePath = positional[0];
  if (!filePath) {
    process.stderr.write('usage: validate-lesson.mjs [--capture] <file.md|file.jsonl|-> (stdin JSONL)\n');
    process.exit(2);
  }
  process.exit(runCli(filePath, { capture }));
}
