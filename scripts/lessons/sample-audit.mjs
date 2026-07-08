// scripts/lessons/sample-audit.mjs — HIMMEL-767 deliverable 2: sample-audit
// precision gate for lesson provenance records (docs/internals/lesson-provenance.md).
//
// Three verbs:
//   sample  <files...> [--n N] [--seed S] [--include-audited] [--allow-small] [--out FILE]
//   apply   --verdicts <worksheet.jsonl> [--audited-at ISO] [--auditor NAME]
//   gate    --verdicts <worksheet.jsonl> [--threshold 0.90] [--allow-small]
//
// Runbook: docs/internals/lesson-audit.md. Node stdlib only, no deps.
import { readFileSync, writeFileSync, renameSync, unlinkSync } from 'node:fs';
import { dirname, join, extname, basename } from 'node:path';
import {
  AUDIT_VERDICTS, validateRecord,
  extractFrontmatter, parseYamlSubset, extractLessonsJsonl,
  validateMarkdown, validateJsonlText,
} from './validate-lesson.mjs';

// Eligible = not yet resolved (excludes superseded/invalidated) — a subset
// of validate-lesson's STATUSES enum, kept literal since "eligible for
// audit" is a narrower, sample-audit-specific concept.
const ELIGIBLE_STATUSES = ['active', 'unverified'];

// --- Small utils ---
const stripBom = (s) => (s.charCodeAt(0) === 0xFEFF ? s.slice(1) : s);
// NOTE: reads strip a UTF-8 BOM and apply never re-writes it — an edited
// origin file is BOM-normalized as a side effect (intentional; at-rest
// validation reads through stripBom too, so round-trips stay stable).
const readText = (filePath) => stripBom(readFileSync(filePath, 'utf8'));
const nowIso = () => new Date().toISOString();

function yamlScalar(v) {
  const s = String(v);
  const needsQuote = s === ''
    || /^\s/.test(s) || /\s$/.test(s)
    || /^[-?:,\[\]{}#&*!|>'"%@`]/.test(s)
    || /: /.test(s) || /:$/.test(s);
  if (!needsQuote) return s;
  return `"${s.replace(/\\/g, '\\\\').replace(/"/g, '\\"')}"`;
}

// Deterministic PRNG (mulberry32) so a given --seed always yields the same
// sample over a given sorted population.
function mulberry32(seed) {
  let t = seed >>> 0;
  return function rng() {
    t += 0x6D2B79F5;
    let r = Math.imul(t ^ (t >>> 15), 1 | t);
    r ^= r + Math.imul(r ^ (r >>> 7), 61 | r);
    return ((r ^ (r >>> 14)) >>> 0) / 4294967296;
  };
}

function seededShuffle(arr, seed) {
  const rng = mulberry32(seed);
  const a = arr.slice();
  for (let i = a.length - 1; i > 0; i--) {
    const j = Math.floor(rng() * (i + 1));
    [a[i], a[j]] = [a[j], a[i]];
  }
  return a;
}

function byIdThenFile(a, b) {
  if (a.record.id !== b.record.id) return a.record.id < b.record.id ? -1 : 1;
  if (a.origin.file === b.origin.file) return 0;
  return a.origin.file < b.origin.file ? -1 : 1;
}

// --- Line-preserving text editing (byte-precision for untouched lines) ---
function splitLinesPreserving(text) {
  const parts = text.split(/(\r\n|\n)/);
  const lines = [];
  for (let i = 0; i < parts.length; i += 2) lines.push({ content: parts[i], eol: parts[i + 1] || '' });
  return lines;
}
const joinLinesPreserving = (lines) => lines.map((l) => l.content + l.eol).join('');

// --- Record extraction (shared by sample + apply's preflight) ---
// Returns { records: [{ record, origin: { file, carrier } }], malformed }.
// malformed counts JSON lines that failed to parse (validate-lesson.mjs is
// the gate for malformed records; this tool reads well-formed ones out of
// already-validated artifacts, but skips are COUNTED, never silent).
function extractRecordsFromText(filePath, text) {
  const ext = extname(filePath).toLowerCase();
  const records = [];
  let malformed = 0;
  if (ext === '.md') {
    const fm = extractFrontmatter(text);
    if (fm !== null) {
      const parsed = parseYamlSubset(fm);
      if (parsed.lesson && typeof parsed.lesson === 'object' && !Array.isArray(parsed.lesson)) {
        records.push({ record: parsed.lesson, origin: { file: filePath, carrier: 'frontmatter' } });
      }
    }
    const body = extractLessonsJsonl(text);
    if (body !== null && !body.error) {
      for (const line of body.jsonl.split(/\r?\n/)) {
        if (line.trim() === '') continue;
        try {
          records.push({ record: JSON.parse(line), origin: { file: filePath, carrier: 'body-lessons' } });
        } catch { malformed++; }
      }
    }
  } else {
    for (const line of text.split(/\r?\n/)) {
      if (line.trim() === '') continue;
      try {
        records.push({ record: JSON.parse(line), origin: { file: filePath, carrier: 'jsonl' } });
      } catch { malformed++; }
    }
  }
  return { records, malformed };
}

function extractRecords(filePath) {
  return extractRecordsFromText(filePath, readText(filePath));
}

// --- CLI arg parsing ---
function parseArgs(args, { flags = [], valueFlags = [] } = {}) {
  const out = { _: [] };
  for (let i = 0; i < args.length; i++) {
    const a = args[i];
    if (a.startsWith('--')) {
      const name = a.slice(2);
      if (valueFlags.includes(name)) {
        if (i + 1 >= args.length) return { error: `--${name} requires a value` };
        out[name] = args[++i];
      } else if (flags.includes(name)) {
        out[name] = true;
      } else {
        return { error: `unknown flag --${name}` };
      }
    } else {
      out._.push(a);
    }
  }
  return out;
}

function usage() {
  return `usage: sample-audit.mjs <verb> [options]

  sample <files...> [--n N] [--seed S] [--include-audited] [--allow-small] [--out FILE]
      Sample N (default 20) eligible lesson records (status active|unverified,
      un-audited unless --include-audited) into a worksheet JSONL.

  apply --verdicts <worksheet.jsonl> [--audited-at ISO] [--auditor NAME]
      Write verdicted worksheet entries back to their origin artifacts as
      audit blocks (single-writer: audited_at, verdict, auditor).

  gate --verdicts <worksheet.jsonl> [--threshold 0.90] [--allow-small]
      Compute precision (confirmed / total) over a fully-verdicted worksheet;
      exit 0 iff precision >= threshold.

See docs/internals/lesson-audit.md for the full runbook.
`;
}

// --- sample ---
function cmdSample(args) {
  const parsed = parseArgs(args, {
    flags: ['include-audited', 'allow-small', 'help'],
    valueFlags: ['n', 'seed', 'out'],
  });
  if (parsed.error) { process.stderr.write(`sample-audit sample: ${parsed.error}\n${usage()}`); return 2; }
  if (parsed.help) { process.stdout.write(usage()); return 0; }
  const files = parsed._;
  if (files.length === 0) { process.stderr.write(`sample-audit sample: no input files given\n${usage()}`); return 2; }
  const n = parsed.n !== undefined ? parseInt(parsed.n, 10) : 20;
  const seed = parsed.seed !== undefined ? parseInt(parsed.seed, 10) : 1;
  if (!Number.isInteger(n) || n < 0 || (parsed.n !== undefined && String(n) !== parsed.n.trim())) {
    process.stderr.write(`sample-audit sample: --n must be a non-negative integer, got "${parsed.n}"\n`);
    return 2;
  }
  if (!Number.isInteger(seed) || (parsed.seed !== undefined && String(seed) !== parsed.seed.trim())) {
    process.stderr.write(`sample-audit sample: --seed must be an integer, got "${parsed.seed}"\n`);
    return 2;
  }

  const eligible = [];
  for (const f of files) {
    let extraction;
    try {
      extraction = extractRecords(f);
    } catch (e) {
      process.stderr.write(`sample-audit sample: cannot read ${f}: ${e.message}\n`);
      return 2;
    }
    let idless = 0;
    let invalid = 0;
    for (const { record, origin } of extraction.records) {
      if (!record || typeof record !== 'object' || Array.isArray(record) || !record.id) { idless++; continue; }
      // At-rest validation: invalid records are visible contamination —
      // counted and excluded from the population, never sampled silently.
      if (validateRecord(record).length) { invalid++; continue; }
      if (!ELIGIBLE_STATUSES.includes(record.status)) continue;
      if (record.audit && !parsed['include-audited']) continue;
      eligible.push({ record, origin });
    }
    if (extraction.malformed || idless || invalid) {
      process.stderr.write(
        `sample-audit sample: ${f}: skipped ${extraction.malformed} malformed line(s), `
        + `${idless} id-less record(s), excluded ${invalid} invalid record(s)\n`,
      );
    }
  }
  eligible.sort(byIdThenFile);

  const population = eligible.length;
  if (population < n && !parsed['allow-small']) {
    process.stderr.write(
      `sample-audit sample: eligible population (${population}) < requested N (${n}) — `
      + `the >=90% precision gate needs >=20 samples. Use --allow-small (paired with --n) for tests/smoke only.\n`,
    );
    return 3;
  }

  const sampleSize = Math.min(n, population);
  const sampled = seededShuffle(eligible, seed).slice(0, sampleSize).sort(byIdThenFile);
  const lines = sampled.map(({ record, origin }) => JSON.stringify({ ...record, origin, verdict: '', notes: '' }));
  const outputText = lines.join('\n') + (lines.length ? '\n' : '');
  if (parsed.out) {
    try {
      writeFileSync(parsed.out, outputText, 'utf8');
    } catch (e) {
      process.stderr.write(`sample-audit sample: cannot write --out ${parsed.out}: ${e.message}\n`);
      return 2;
    }
  } else {
    process.stdout.write(outputText);
  }
  return 0;
}

// --- apply ---
function findAuditFenceRange(lines) {
  const headingIdx = lines.findIndex((l) => /^## Lessons\s*$/.test(l.content));
  if (headingIdx === -1) return null;
  let fenceOpen = -1;
  for (let i = headingIdx + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i].content)) break;
    if (/^```jsonl\s*$/.test(lines[i].content)) { fenceOpen = i; break; }
  }
  if (fenceOpen === -1) return null;
  let fenceClose = -1;
  for (let i = fenceOpen + 1; i < lines.length; i++) {
    // Bound at the next h2 — mirrors extractLessonsJsonl's sectioning so the
    // two boundary scanners agree on malformed docs (unclosed fence, etc.).
    if (/^## /.test(lines[i].content)) break;
    if (/^```\s*$/.test(lines[i].content)) { fenceClose = i; break; }
  }
  if (fenceClose === -1) return null;
  return { start: fenceOpen + 1, end: fenceClose };
}

function applyJsonlLineEditsInRange(lines, editsById, start, end) {
  for (let i = start; i < end; i++) {
    const c = lines[i].content;
    if (c.trim() === '') continue;
    let rec;
    try { rec = JSON.parse(c); } catch { continue; }
    if (rec && rec.id && editsById.has(rec.id)) {
      rec.audit = editsById.get(rec.id);
      lines[i] = { ...lines[i], content: JSON.stringify(rec) };
      editsById.delete(rec.id);
    }
  }
}

// Inserts a nested `audit:` mapping at the end of the existing `lesson:`
// frontmatter block, matching that block's own indent style.
function insertAuditIntoFrontmatter(lines, auditObj) {
  if (lines[0]?.content !== '---') return null;
  let closingIdx = -1;
  for (let i = 1; i < lines.length; i++) {
    if (lines[i].content === '---') { closingIdx = i; break; }
  }
  if (closingIdx === -1) return null;
  let lessonIdx = -1;
  let lessonIndent = 0;
  for (let i = 1; i < closingIdx; i++) {
    const m = lines[i].content.match(/^(\s*)lesson:\s*$/);
    if (m) { lessonIdx = i; lessonIndent = m[1].length; break; }
  }
  if (lessonIdx === -1) return null;

  let childIndent = lessonIndent + 2;
  if (lessonIdx + 1 < closingIdx) {
    const next = lines[lessonIdx + 1].content;
    const nextIndent = (next.match(/^(\s*)/) || ['', ''])[1].length;
    if (next.trim() !== '' && nextIndent > lessonIndent) childIndent = nextIndent;
  }

  let end = closingIdx;
  for (let i = lessonIdx + 1; i < closingIdx; i++) {
    const c = lines[i].content;
    if (c.trim() === '') continue;
    const indent = (c.match(/^(\s*)/) || ['', ''])[1].length;
    if (indent <= lessonIndent) { end = i; break; }
  }

  // Idempotence: if the lesson block already carries an audit: mapping
  // (e.g. a re-run after a partial apply, or --include-audited), replace
  // it instead of appending a duplicate key.
  const out0 = lines.slice();
  for (let i = lessonIdx + 1; i < end; i++) {
    const m2 = out0[i].content.match(/^(\s*)audit:\s*$/);
    if (!m2 || m2[1].length <= lessonIndent) continue;
    const auditIndent = m2[1].length;
    let subtreeEnd = i + 1;
    while (subtreeEnd < end) {
      const c = out0[subtreeEnd].content;
      if (c.trim() !== '' && ((c.match(/^(\s*)/) || ['', ''])[1].length <= auditIndent)) break;
      subtreeEnd++;
    }
    out0.splice(i, subtreeEnd - i);
    end -= subtreeEnd - i;
    break;
  }

  const eol = lines[lessonIdx].eol || '\n';
  const pad = ' '.repeat(childIndent);
  const padInner = ' '.repeat(childIndent + 2);
  const newLines = [
    { content: `${pad}audit:`, eol },
    { content: `${padInner}audited_at: ${auditObj.audited_at}`, eol },
    { content: `${padInner}verdict: ${auditObj.verdict}`, eol },
    { content: `${padInner}auditor: ${yamlScalar(auditObj.auditor)}`, eol },
  ];
  out0.splice(end, 0, ...newLines);
  return out0;
}

function validateFileAtRest(filePath, text) {
  const ext = extname(filePath).toLowerCase();
  if (ext === '.md') {
    const { fails, bodyRecords } = validateMarkdown(text);
    const all = [...fails, ...bodyRecords.flatMap((r) => r.fails)];
    return all.length ? all.join('; ') : null;
  }
  const results = validateJsonlText(text);
  const all = results.flatMap((r) => r.fails);
  return all.length ? all.join('; ') : null;
}

// Codes Windows raises when it refuses rename-over-existing / unlink of a
// busy or read-only target. Anything else is unexpected — rethrow WITHOUT
// touching the original file.
const WIN_RENAME_CODES = ['EPERM', 'EBUSY', 'EEXIST', 'ENOTEMPTY', 'EACCES'];

// Test-only fault injection (SAMPLE_AUDIT_FAULT_WRITE_ONCE=<basename>):
// forces the FIRST atomicWrite touching that basename to throw, so the test
// suite can exercise the phase-3 failure accounting + restore deterministically
// (no cross-platform fs trick forces a mid-loop write failure reliably — e.g.
// Windows renames straight over read-only targets). Never set in production.
let testFaultFired = false;

function atomicWrite(filePath, content) {
  if (process.env.SAMPLE_AUDIT_FAULT_WRITE_ONCE
      && basename(filePath) === process.env.SAMPLE_AUDIT_FAULT_WRITE_ONCE
      && !testFaultFired) {
    testFaultFired = true;
    throw new Error('fault injection: write refused (SAMPLE_AUDIT_FAULT_WRITE_ONCE)');
  }
  const dir = dirname(filePath);
  const tmp = join(dir, `.${basename(filePath)}.sa-tmp-${process.pid}-${Date.now()}-${Math.random().toString(36).slice(2)}`);
  try {
    writeFileSync(tmp, content, 'utf8');
  } catch (e) {
    // No destructive action has been taken — the original is untouched.
    throw new Error(`could not write temp file ${tmp}: ${e.message}`);
  }
  try {
    renameSync(tmp, filePath);
  } catch (e) {
    if (!WIN_RENAME_CODES.includes(e.code)) {
      // Unexpected failure class: clean up our temp, never unlink the original.
      try { unlinkSync(tmp); } catch { /* best-effort tmp cleanup */ }
      throw e;
    }
    // Windows rename-over-existing refusal: unlink the target, retry the rename.
    try { unlinkSync(filePath); } catch { /* best-effort */ }
    try {
      renameSync(tmp, filePath);
    } catch (e2) {
      // Double failure: the original path may now be unlinked. Recover by
      // writing the content directly (we still hold it in memory); only if
      // THAT also fails, surface the surviving temp as the recovery file.
      try {
        writeFileSync(filePath, content, 'utf8');
      } catch {
        throw new Error(`atomic write failed for ${filePath} — content preserved in ${tmp}: ${e2.message}`);
      }
      try { unlinkSync(tmp); } catch { /* best-effort tmp cleanup */ }
    }
  }
}

function readWorksheet(path) {
  const text = readText(path);
  const entries = [];
  for (const line of text.split(/\r?\n/)) {
    if (line.trim() === '') continue;
    entries.push(JSON.parse(line));
  }
  return entries;
}

function cmdApply(args) {
  const parsed = parseArgs(args, { flags: ['help'], valueFlags: ['verdicts', 'audited-at', 'auditor'] });
  if (parsed.error) { process.stderr.write(`sample-audit apply: ${parsed.error}\n${usage()}`); return 2; }
  if (parsed.help) { process.stdout.write(usage()); return 0; }
  if (!parsed.verdicts) { process.stderr.write(`sample-audit apply: --verdicts <worksheet.jsonl> is required\n${usage()}`); return 2; }

  let entries;
  try {
    entries = readWorksheet(parsed.verdicts);
  } catch (e) {
    process.stderr.write(`sample-audit apply: cannot read worksheet ${parsed.verdicts}: ${e.message}\n`);
    return 2;
  }

  // Duplicate worksheet ids are a malformed worksheet — refuse outright
  // rather than last-write-wins.
  const seenIds = new Set();
  for (const e of entries) {
    if (!e || !e.id) continue;
    if (seenIds.has(e.id)) {
      process.stderr.write(`sample-audit apply: duplicate worksheet id "${e.id}" — refusing (no last-write-wins); fix the worksheet\n`);
      return 2;
    }
    seenIds.add(e.id);
  }

  const unverdicted = entries.filter((e) => !e.verdict);
  if (unverdicted.length) {
    process.stderr.write(`sample-audit apply: ${unverdicted.length} record(s) have no verdict: ${unverdicted.map((e) => e.id).join(', ')}\n`);
    return 1;
  }
  const badVerdict = entries.filter((e) => !AUDIT_VERDICTS.includes(e.verdict));
  if (badVerdict.length) {
    process.stderr.write(`sample-audit apply: invalid verdict(s): ${badVerdict.map((e) => `${e.id}=${e.verdict}`).join(', ')} (expected one of ${AUDIT_VERDICTS.join('|')})\n`);
    return 1;
  }
  const missingAuditor = entries.filter((e) => !(e.auditor || parsed.auditor));
  if (missingAuditor.length) {
    process.stderr.write(`sample-audit apply: no auditor for: ${missingAuditor.map((e) => e.id).join(', ')} (pass --auditor or set a per-line "auditor" field)\n`);
    return 1;
  }
  if (!entries.length) { process.stdout.write('sample-audit apply: worksheet is empty, nothing to do\n'); return 0; }

  const auditedAt = parsed['audited-at'] || nowIso();
  const byFile = new Map();
  for (const e of entries) {
    if (!e.id || !e.origin || !e.origin.file || !e.origin.carrier) {
      process.stderr.write(`sample-audit apply: worksheet entry missing id/origin: ${JSON.stringify(e)}\n`);
      return 1;
    }
    const auditObj = { audited_at: auditedAt, verdict: e.verdict, auditor: e.auditor || parsed.auditor };
    const list = byFile.get(e.origin.file) || [];
    list.push({ id: e.id, claim: e.claim, carrier: e.origin.carrier, auditObj });
    byFile.set(e.origin.file, list);
  }

  // Phase 1: preflight + stage. Read every origin, verify every targeted id
  // still resolves (id + carrier + claim), and build the new content for ALL
  // files in memory. Any failure here aborts before a single disk write.
  const staged = []; // { file, originalText, newText }
  let appliedRecords = 0;
  for (const [file, fileEntries] of byFile) {
    let originalText;
    try {
      originalText = readText(file);
    } catch (e) {
      process.stderr.write(`sample-audit apply: cannot read origin ${file}: ${e.message} (no files were written)\n`);
      return 1;
    }
    const present = extractRecordsFromText(file, originalText).records;
    for (const fe of fileEntries) {
      const match = present.find((p) => p.record && p.record.id === fe.id && p.origin.carrier === fe.carrier);
      if (!match) {
        process.stderr.write(`sample-audit apply: unknown/missing id "${fe.id}" (carrier ${fe.carrier}) at origin ${file} (no files were written)\n`);
        return 1;
      }
      if ((match.record.claim ?? '') !== (fe.claim ?? '')) {
        process.stderr.write(`sample-audit apply: origin record does not match sampled record for "${fe.id}" at ${file} — worksheet may point at the wrong file (no files were written)\n`);
        return 1;
      }
    }

    let lines = splitLinesPreserving(originalText);
    const fmEntries = fileEntries.filter((e) => e.carrier === 'frontmatter');
    for (const fe of fmEntries) {
      const updated = insertAuditIntoFrontmatter(lines, fe.auditObj);
      if (!updated) {
        process.stderr.write(`sample-audit apply: could not locate lesson: frontmatter block for "${fe.id}" in ${file} (no files were written)\n`);
        return 1;
      }
      lines = updated;
      appliedRecords++;
    }

    const jsonlEntries = fileEntries.filter((e) => e.carrier === 'jsonl');
    const bodyEntries = fileEntries.filter((e) => e.carrier === 'body-lessons');
    if (jsonlEntries.length) {
      const editsById = new Map(jsonlEntries.map((e) => [e.id, e.auditObj]));
      const want = editsById.size;
      applyJsonlLineEditsInRange(lines, editsById, 0, lines.length);
      if (editsById.size) {
        process.stderr.write(`sample-audit apply: drain check failed — un-applied id(s) in ${file} (carrier jsonl): ${[...editsById.keys()].join(', ')} (no files were written)\n`);
        return 1;
      }
      appliedRecords += want;
    }
    if (bodyEntries.length) {
      const range = findAuditFenceRange(lines);
      if (!range) {
        process.stderr.write(`sample-audit apply: could not locate ## Lessons fenced jsonl block in ${file} (no files were written)\n`);
        return 1;
      }
      const editsById = new Map(bodyEntries.map((e) => [e.id, e.auditObj]));
      const want = editsById.size;
      applyJsonlLineEditsInRange(lines, editsById, range.start, range.end);
      if (editsById.size) {
        process.stderr.write(`sample-audit apply: drain check failed — un-applied id(s) in ${file} (carrier body-lessons): ${[...editsById.keys()].join(', ')} (no files were written)\n`);
        return 1;
      }
      appliedRecords += want;
    }

    staged.push({ file, originalText, newText: joinLinesPreserving(lines) });
  }

  // Phase 2: at-rest validation of every staged result IN MEMORY, so a
  // validation failure — including pre-existing corruption elsewhere in a
  // touched file — aborts before any disk write.
  for (const s of staged) {
    const invalid = validateFileAtRest(s.file, s.newText);
    if (invalid) {
      process.stderr.write(`sample-audit apply: staged validation failed for ${s.file} — no files were written. ${invalid}\n`);
      return 1;
    }
  }

  // Phase 3: write. Per-file atomic; the read-back re-validation is kept as
  // a belt over phase 2. A mid-loop failure restores that file and prints an
  // explicit accounting of what was / wasn't touched.
  const applied = [];
  for (let i = 0; i < staged.length; i++) {
    const { file, originalText, newText } = staged[i];
    try {
      atomicWrite(file, newText);
      const invalid = validateFileAtRest(file, stripBom(readFileSync(file, 'utf8')));
      if (invalid) throw new Error(`post-write read-back validation failed: ${invalid}`);
      applied.push(file);
    } catch (e) {
      const notAttempted = staged.slice(i + 1).map((s) => s.file);
      let restoreLine;
      try {
        atomicWrite(file, originalText);
        restoreLine = `restored: [${file}]`;
      } catch (e2) {
        let recoveryPath = null;
        try {
          recoveryPath = join(dirname(file), `.${basename(file)}.sa-recovery-${Date.now()}`);
          writeFileSync(recoveryPath, originalText, 'utf8');
        } catch { recoveryPath = null; }
        process.stderr.write(
          `sample-audit apply: CRITICAL: write/validation failed for ${file} AND restore also failed — file on disk may be invalid`
          + `${recoveryPath ? `; original preserved at ${recoveryPath}` : ''} (${e2.message})\n`,
        );
        restoreLine = `restore-FAILED: [${file}]`;
      }
      process.stderr.write(`sample-audit apply: write failed for ${file}: ${e.message}\n`);
      process.stderr.write(`sample-audit apply: accounting — applied: [${applied.join(', ')}], ${restoreLine}, not-attempted: [${notAttempted.join(', ')}]\n`);
      return 1;
    }
  }

  process.stdout.write(`sample-audit apply: wrote audit blocks for ${appliedRecords} record(s) across ${staged.length} file(s)\n`);
  return 0;
}

// --- gate ---
function cmdGate(args) {
  const parsed = parseArgs(args, { flags: ['allow-small', 'help'], valueFlags: ['verdicts', 'threshold'] });
  if (parsed.error) { process.stderr.write(`sample-audit gate: ${parsed.error}\n${usage()}`); return 2; }
  if (parsed.help) { process.stdout.write(usage()); return 0; }
  if (!parsed.verdicts) { process.stderr.write(`sample-audit gate: --verdicts <worksheet.jsonl> is required\n${usage()}`); return 2; }

  let entries;
  try {
    entries = readWorksheet(parsed.verdicts);
  } catch (e) {
    process.stderr.write(`sample-audit gate: cannot read worksheet ${parsed.verdicts}: ${e.message}\n`);
    return 2;
  }

  const threshold = parsed.threshold !== undefined ? parseFloat(parsed.threshold) : 0.90;
  if (Number.isNaN(threshold) || threshold <= 0 || threshold > 1) {
    process.stderr.write(`sample-audit gate: --threshold must be a number in (0, 1], got "${parsed.threshold}"\n`);
    return 2;
  }

  const unverdicted = entries.filter((e) => !e.verdict || !AUDIT_VERDICTS.includes(e.verdict));
  if (unverdicted.length) {
    process.stderr.write(`sample-audit gate: ${unverdicted.length} record(s) not fully verdicted (empty or invalid): ${unverdicted.map((e) => `${e.id}=${JSON.stringify(e.verdict)}`).join(', ')}\n`);
    return 3;
  }

  const total = entries.length;
  if (total < 20 && !parsed['allow-small']) {
    process.stderr.write(`sample-audit gate: total (${total}) < 20 — the >=90% precision gate requires >=20 samples. Use --allow-small for tests/smoke only.\n`);
    return 3;
  }

  const counts = { confirmed: 0, refuted: 0, stale: 0 };
  for (const e of entries) counts[e.verdict]++;
  const precision = total ? counts.confirmed / total : 0;

  process.stdout.write(
    `confirmed: ${counts.confirmed}\nrefuted: ${counts.refuted}\nstale: ${counts.stale}\ntotal: ${total}\n`
    + `precision: ${precision.toFixed(4)}\nthreshold: ${threshold.toFixed(4)}\n`
    + `RESULT: ${precision >= threshold ? 'PASS' : 'FAIL'}\n`,
  );
  return precision >= threshold ? 0 : 1;
}

// --- main ---
function main(argv) {
  const [verb, ...rest] = argv;
  if (!verb) { process.stderr.write(usage()); return 2; }
  if (verb === '--help' || verb === '-h') { process.stdout.write(usage()); return 0; }
  switch (verb) {
    case 'sample': return cmdSample(rest);
    case 'apply': return cmdApply(rest);
    case 'gate': return cmdGate(rest);
    default:
      process.stderr.write(`sample-audit: unknown verb "${verb}"\n${usage()}`);
      return 2;
  }
}

if (process.argv[1]?.endsWith('sample-audit.mjs')) {
  process.exit(main(process.argv.slice(2)));
}

export { mulberry32, seededShuffle, extractRecords };
