#!/usr/bin/env node
// prepare-ship-index.mjs — build a shippable qmd index snapshot for a RECEIVING
// machine: consistent copy -> collection reconcile -> vec0 orphan GC -> VACUUM
// -> stats (HIMMEL-1275).
//
// WHY THIS EXISTS: win2 cannot BUILD its own search substrate. Measured
// 2026-07-25: it embeds at ~5 docs/min vs ~256 docs/min locally (50x), so an
// in-place reindex there was projected at ~17 HOURS and was killed mid-run. The
// only workable shape is build-local / ship-the-artifact. This script is the
// "prepare the artifact" half; scripts/luna/ship-index.sh is the transport.
//
// WHY NODE AND NOT PYTHON/sqlite3-CLI: the index carries a vec0 virtual table
// (`vectors_vec`). Python's stdlib sqlite3 CANNOT load the vec0 extension on
// these boxes (`no such module: vec0`), and the sqlite3 CLI is not guaranteed to
// have it either. node + better-sqlite3 + vec0.dll via db.loadExtension() is the
// path that works, so the GC lives here rather than in the shell script.
//
// ---------------------------------------------------------------------------
// The four facts this script is built on (all verified against the live index
// on 2026-07-25 — do not re-derive them by guessing):
//
//   1. SCHEMA
//        store_collections(name PK, path, pattern, ...)
//        documents(id PK, collection, path, title, hash, ..., active)
//        content(hash PK, doc, created_at)
//        content_vectors(hash, seq PK, pos, model, ...)
//        vectors_vec USING vec0(hash_seq TEXT PRIMARY KEY, embedding float[768])
//
//   2. vectors_vec.hash_seq == hash + "_" + seq  (UNDERSCORE separator).
//      Sampled: "46b47b19…cc8ebf_0", "…_1". The GC predicate depends on this
//      exact shape; a wrong separator silently deletes EVERY vector.
//
//   3. `hash_seq TEXT PRIMARY KEY` REPLACES rowid in a vec0 table. So
//      `DELETE FROM vectors_vec WHERE rowid = ?` fails with
//      "no such column: rowid" — deletions MUST key on hash_seq.
//
//   4. FTS IS HANDLED BY A TRIGGER, NOT BY US. `documents_ad` is an
//      AFTER DELETE trigger on documents that deletes the matching
//      documents_fts row. So deleting documents cascades to FTS for free.
//      Do NOT hand-delete from documents_fts (it is a contentless fts5 table —
//      manual deletes corrupt it), and do NOT skip the documents delete
//      thinking FTS needs separate handling.
//
// CONTENT IS SHARED ACROSS COLLECTIONS. `luna-curated` indexes a SUBSET of the
// same luna vault, so a content hash can be referenced by documents in more
// than one collection. Orphan cleanup is therefore "referenced by NO surviving
// document", never "belonged to a dropped collection" — the latter would delete
// content that a kept collection still needs.
//
// SAFETY: the source index is opened READONLY and is never modified. All
// mutation happens on the copy. The copy is made with SQLite's own backup API
// (better-sqlite3 db.backup), NOT a filesystem copy, so it is consistent even
// while the local qmd MCP daemon is live.
//
// Usage:
//   node prepare-ship-index.mjs --src <index.sqlite> --out <staging.sqlite> \
//        --collections himmel,luna [--vec0 <path>] [--json]
//
// Exit codes:
//   0  staging index built + verified self-consistent
//   1  usage / input error
//   2  dependency unusable (better-sqlite3 or vec0 not loadable)
//   3  source index unreadable / unexpected schema
//   4  reconcile or GC failed
//   5  post-build self-check failed (staging index is internally inconsistent)

import { existsSync, mkdirSync, renameSync, rmSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { createRequire } from 'node:module';
import { homedir } from 'node:os';

const require = createRequire(import.meta.url);

function die(code, msg) {
  process.stderr.write(`ERR prepare-ship-index: ${msg}\n`);
  process.exit(code);
}

// --- args -------------------------------------------------------------------
const args = process.argv.slice(2);
let src = '', out = '', collectionsArg = null, vec0Path = '', asJson = false;
for (let i = 0; i < args.length; i++) {
  const a = args[i];
  const need = (name) => {
    const v = args[i + 1];
    if (v === undefined || v.startsWith('--')) die(1, `${name} requires a value`);
    i++;
    return v;
  };
  switch (a) {
    case '--src': src = need('--src'); break;
    case '--out': out = need('--out'); break;
    case '--collections': collectionsArg = need('--collections'); break;
    case '--vec0': vec0Path = need('--vec0'); break;
    case '--json': asJson = true; break;
    case '-h': case '--help':
      process.stdout.write(
        'Usage: prepare-ship-index.mjs --src <index.sqlite> --out <staging.sqlite> ' +
        '--collections a,b [--vec0 <vec0.dll>] [--json]\n');
      process.exit(0);
    default: die(1, `unknown arg: ${a}`);
  }
}
if (!src || !out) die(1, '--src and --out are required');
if (collectionsArg === null) die(1, '--collections is required (the RECEIVING machine\'s set)');

// An empty --collections would reconcile the shipped index down to nothing,
// which is a plausible typo/shell-expansion accident and never a real intent.
const keep = collectionsArg.split(',').map(s => s.trim()).filter(Boolean);
if (keep.length === 0) die(1, '--collections resolved to an empty set — refusing to ship an empty index');

src = resolve(src);
out = resolve(out);
if (!existsSync(src)) die(3, `source index not found: ${src}`);
if (src === out) die(1, 'refusing to use the same path for --src and --out');

// --- dependencies -----------------------------------------------------------
// better-sqlite3 is not a dependency of this repo; it comes from the qmd fork
// checkout that scripts/lib/qmd-bin.sh manages. Probe the known locations
// rather than assuming a global install.
const bs3Candidates = [
  process.env.HIMMEL_BETTER_SQLITE3,
  `${homedir()}/.himmel/qmd-fork/node_modules/better-sqlite3`,
  `${homedir()}/Documents/github/qmd/node_modules/better-sqlite3`,
].filter(Boolean);

let Database = null, bs3Used = '';
for (const c of bs3Candidates) {
  try { Database = require(c); bs3Used = c; break; } catch { /* try next */ }
}
if (!Database) {
  die(2, 'better-sqlite3 not found. Looked in:\n' + bs3Candidates.map(c => `    ${c}`).join('\n') +
         '\n    Set HIMMEL_BETTER_SQLITE3 to its directory, or install the qmd fork.');
}

// sqlite-vec ships a per-platform package with a per-platform library name, so
// a Windows-only candidate list would make every POSIX host look like "vec0
// unavailable" even with it installed. Cover the three platforms explicitly.
const vec0Pkgs = process.platform === 'win32'
  ? [['sqlite-vec-windows-x64', 'vec0.dll']]
  : process.platform === 'darwin'
    ? [['sqlite-vec-darwin-arm64', 'vec0.dylib'], ['sqlite-vec-darwin-x64', 'vec0.dylib']]
    : [['sqlite-vec-linux-x64', 'vec0.so'], ['sqlite-vec-linux-arm64', 'vec0.so']];
const vec0Roots = [
  `${homedir()}/.himmel/qmd-fork/node_modules`,
  `${homedir()}/Documents/github/qmd/node_modules`,
  `${homedir()}/.bun/install/global/node_modules`,
];
const vec0Candidates = [
  vec0Path,
  process.env.HIMMEL_VEC0,
  ...vec0Roots.flatMap(r => vec0Pkgs.map(([pkg, lib]) => `${r}/${pkg}/${lib}`)),
].filter(Boolean);

function loadVec0(db) {
  for (const c of vec0Candidates) {
    if (!existsSync(c)) continue;
    try { db.loadExtension(c); return c; } catch { /* try next */ }
  }
  return null;
}

// --- build ------------------------------------------------------------------
const stats = { src, out, keptCollections: keep, bs3: bs3Used };

mkdirSync(dirname(out), { recursive: true });

// Build at a unique sibling path and PROMOTE to --out only after every step
// (reconcile, GC, VACUUM, self-check) has succeeded. Deleting/overwriting --out
// up front would destroy a previous good artifact the moment anything failed,
// leaving the operator with neither the old one nor a usable new one — and a
// half-written file at exactly the path the transport is about to upload. Same
// staged-then-promoted discipline the cadence emitters use for their runners.
const workPath = `${out}.building.${process.pid}`;
let promoted = false;
// SQLite writes -wal and -shm SIDECARS next to the database. They must be
// cleaned up and replaced together with the main file: a stale -wal left beside
// a NEW database is not just litter, it is a journal belonging to a DIFFERENT
// database sitting where SQLite will look for one.
const sidecars = (p) => [`${p}-wal`, `${p}-shm`];
const rmQuiet = (p) => { try { if (existsSync(p)) rmSync(p, { force: true }); } catch { /* best effort */ } };
const discardWork = () => {
  if (!promoted) {
    rmQuiet(workPath);
    for (const s of sidecars(workPath)) rmQuiet(s);
  }
};
process.on('exit', discardWork);

let source;
try {
  source = new Database(src, { readonly: true });
} catch (e) {
  die(3, `cannot open source index readonly: ${e.message}`);
}

// Schema sanity BEFORE touching anything: a qmd index that does not look like
// the one this script was written against must not be silently "reconciled".
const tables = new Set(
  source.prepare("select name from sqlite_master where type in ('table','view')").all().map(r => r.name));
for (const t of ['store_collections', 'documents', 'content', 'content_vectors', 'vectors_vec', 'documents_fts']) {
  if (!tables.has(t)) {
    source.close();
    die(3, `source index is missing the '${t}' table — schema is not what this script expects. ` +
           'Re-verify the schema before shipping (see the header).');
  }
}

// The FTS cascade is an ASSUMPTION this script depends on, so verify it rather
// than trust it. We deliberately do NOT touch documents_fts: correctness relies
// entirely on the documents_ad AFTER DELETE trigger removing the matching FTS
// row. If a qmd version ever drops or renames that trigger, the reconcile would
// still "succeed" and silently ship an index whose full-text search returns
// documents that are no longer in it — a wrong-answer failure with no error.
// Refuse instead.
const hasAd = source.prepare(
  "select count(*) c from sqlite_master where type='trigger' and name='documents_ad'").get().c;
if (!hasAd) {
  source.close();
  die(3, "source index has no 'documents_ad' trigger. This script relies on it to cascade " +
         'document deletes into documents_fts, and never deletes from that (contentless) FTS ' +
         'table itself. Without the trigger the shipped index would full-text-match deleted ' +
         'documents. Refusing to ship.');
}

const srcCollections = source.prepare('select name from store_collections order by name').all().map(r => r.name);
stats.sourceCollections = srcCollections;

// Refuse to invent collections on the receiver. If the receiver asks for a
// collection the source does not have, the ship would silently deliver an
// index missing it — better to fail here and let the operator decide.
const missing = keep.filter(k => !srcCollections.includes(k));
if (missing.length) {
  source.close();
  die(1, `receiver expects collection(s) the SOURCE does not have: ${missing.join(', ')}\n` +
         `    source has: ${srcCollections.join(', ')}\n` +
         '    Refusing to ship an index that silently omits them.');
}

stats.droppedCollections = srcCollections.filter(c => !keep.includes(c));

try {
  await source.backup(workPath);
} catch (e) {
  source.close();
  die(3, `SQLite backup to staging failed: ${e.message}`);
}
source.close();

let db;
try {
  db = new Database(workPath);
} catch (e) {
  die(3, `cannot open staging index: ${e.message}`);
}

const vec0Used = loadVec0(db);
if (!vec0Used) {
  db.close();
  die(2, 'could not load the vec0 extension. Looked in:\n' + vec0Candidates.map(c => `    ${c}`).join('\n') +
         '\n    vec0 is REQUIRED: vectors_vec is a vec0 virtual table, and its orphan rows ' +
         'cannot be deleted without it. Set HIMMEL_VEC0 or pass --vec0.');
}
stats.vec0 = vec0Used;

const count = (sql) => db.prepare(sql).get().c;
stats.before = {
  collections: count('select count(*) c from store_collections'),
  documents: count('select count(*) c from documents'),
  content: count('select count(*) c from content'),
  contentVectors: count('select count(*) c from content_vectors'),
  vectors: count('select count(*) c from vectors_vec'),
};

const placeholders = keep.map(() => '?').join(',');
try {
  db.exec('BEGIN');
  // 1. Drop documents outside the receiver's set. The documents_ad trigger
  //    cascades each delete into documents_fts, so FTS needs no separate step
  //    (and must not get one — it is a contentless fts5 table).
  db.prepare(`DELETE FROM documents WHERE collection NOT IN (${placeholders})`).run(...keep);
  // 2. Drop the collection rows themselves, so the receiver never sees an
  //    orphan collection it does not configure.
  db.prepare(`DELETE FROM store_collections WHERE name NOT IN (${placeholders})`).run(...keep);
  // 3. Content is SHARED across collections (luna-curated indexes a subset of
  //    the luna vault), so drop only what NO surviving document references.
  //
  //    NOT EXISTS, NOT `NOT IN` — this is a correctness requirement, not style.
  //    SQL `x NOT IN (subquery)` evaluates to NULL (not TRUE) for every row as
  //    soon as the subquery yields a single NULL, so ONE document with a NULL
  //    hash silently deletes NOTHING. Verified: with one NULL hash present,
  //    the NOT IN form finds 0 orphans where NOT EXISTS correctly finds 1.
  //    documents.hash has no NOT NULL constraint, so this is reachable — and it
  //    would ship a bloated index while the self-check below (which used the
  //    same predicate) reported it clean.
  db.prepare(
    'DELETE FROM content WHERE NOT EXISTS (SELECT 1 FROM documents d WHERE d.hash = content.hash)').run();
  // 4. Vector metadata follows content. Same NULL-safety reasoning.
  db.prepare(
    'DELETE FROM content_vectors WHERE NOT EXISTS (SELECT 1 FROM content c WHERE c.hash = content_vectors.hash)').run();
  // 5. vec0 orphan GC. These rows NEVER self-clean (22,895 were GC'd by hand on
  //    2026-07-23). Key on hash_seq — a vec0 TEXT PRIMARY KEY replaces rowid,
  //    so a rowid predicate errors outright.
  //    NOT EXISTS here TOO. This is the same NULL trap as steps 3-4 and it is
  //    easy to miss because the subquery looks like a computed string rather
  //    than a column: `hash || '_' || seq` is NULL whenever EITHER operand is
  //    NULL, so one such row makes `hash_seq NOT IN (...)` NULL for every row
  //    and the orphan GC deletes nothing — silently, with the convergence
  //    self-check below then failing for a reason that points elsewhere.
  db.prepare(
    'DELETE FROM vectors_vec WHERE NOT EXISTS (' +
    "SELECT 1 FROM content_vectors cv WHERE cv.hash IS NOT NULL AND cv.seq IS NOT NULL " +
    "AND cv.hash || '_' || cv.seq = vectors_vec.hash_seq)").run();
  db.exec('COMMIT');
} catch (e) {
  try { db.exec('ROLLBACK'); } catch { /* already rolled back */ }
  db.close();
  die(4, `reconcile/GC failed: ${e.message}`);
}

// VACUUM outside the transaction — reclaims the space the deletes freed, which
// is the difference between shipping ~440MB and shipping the pre-strip size.
try {
  db.exec('VACUUM');
} catch (e) {
  db.close();
  die(4, `VACUUM failed: ${e.message}`);
}

stats.after = {
  collections: count('select count(*) c from store_collections'),
  documents: count('select count(*) c from documents'),
  content: count('select count(*) c from content'),
  contentVectors: count('select count(*) c from content_vectors'),
  vectors: count('select count(*) c from vectors_vec'),
};

// --- self-check: never hand the transport a known-inconsistent artifact ------
// This is the local half of "verify, don't assume". The remote half (does the
// receiver actually report these numbers afterwards) lives in ship-index.sh.
const problems = [];
// Absolute equality is deliberate here, NOT a before/after delta comparison (a
// CR suggestion this rejects): post-GC, EVERY vec0 row must have a matching
// content_vectors row and vice versa — that is the whole invariant. A delta
// check would pass an index that merely removed as many orphans as it gained,
// which is exactly the silently-wrong shape this script exists to prevent. The
// orphans fixture proves equality is reachable from a source that starts unequal.
if (stats.after.vectors !== stats.after.contentVectors) {
  problems.push(
    `vec0 rows (${stats.after.vectors}) != content_vectors rows (${stats.after.contentVectors}) — ` +
    'orphan GC did not converge. If these differ, the hash_seq separator assumption ' +
    "(hash + '_' + seq) is probably wrong for this qmd version.");
}
const strayDocs = db.prepare(
  `select count(*) c from documents where collection not in (${placeholders})`).get(...keep).c;
if (strayDocs !== 0) problems.push(`${strayDocs} document(s) outside the kept collections survived`);
const strayCols = db.prepare(
  `select count(*) c from store_collections where name not in (${placeholders})`).get(...keep).c;
if (strayCols !== 0) problems.push(`${strayCols} collection row(s) outside the kept set survived`);
// NOT EXISTS here too — with the NOT IN form this check would report zero
// orphans for the very same NULL-hash reason that caused them, confirming a
// broken reconcile as clean.
const orphanContent = count(
  'select count(*) c from content where not exists (select 1 from documents d where d.hash = content.hash)');
if (orphanContent !== 0) problems.push(`${orphanContent} orphan content row(s) survived`);

stats.sizeBytes = statSync(workPath).size;
db.close();

if (problems.length) {
  process.stderr.write('ERR prepare-ship-index: staging index failed its self-check:\n');
  for (const p of problems) process.stderr.write(`    - ${p}\n`);
  process.stderr.write('    Refusing to hand a known-inconsistent index to the transport.\n');
  if (asJson) process.stdout.write(JSON.stringify({ ...stats, ok: false, problems }) + '\n');
  // process.exitCode, NOT process.exit(5): an immediate exit can truncate a
  // stdout write that has not flushed yet, and the JSON above is exactly what a
  // caller parses to learn WHY the build failed. Setting the code lets node
  // drain and exit naturally. The exit hook still discards the work file (and
  // its sidecars), so a failed build leaves any previous --out artifact intact.
  process.exitCode = 5;
} else {

// PROMOTE: everything succeeded, so the verified artifact becomes --out. Only
// now is any previous artifact at that path replaced.
try {
  // renameSync alone for the MAIN file — no rmSync first. fs.renameSync
  // atomically REPLACES an existing destination (Windows included, Node 10+),
  // so pre-deleting only opens a window where a failing rename leaves the
  // operator with neither the old artifact nor the new one.
  renameSync(workPath, out);
  promoted = true;
  // The sidecars are NOT covered by that atomic replace. Any -wal/-shm left
  // beside the OLD artifact now belongs to a database that no longer exists at
  // this path; SQLite would find it and try to use it. Remove those, then move
  // ours across if the build produced any (a clean close usually checkpoints
  // them away, so their absence is normal).
  for (const s of sidecars(out)) rmQuiet(s);
  for (const s of sidecars(workPath)) {
    if (existsSync(s)) {
      try { renameSync(s, s.replace(workPath, out)); } catch { rmQuiet(s); }
    }
  }
} catch (e) {
  die(4, `could not promote the verified staging index to ${out}: ${e.message}`);
}

if (asJson) {
  process.stdout.write(JSON.stringify({ ...stats, ok: true }) + '\n');
} else {
  const mb = (n) => (n / 1024 / 1024).toFixed(1) + 'MB';
  process.stdout.write(
    `prepare-ship-index: OK\n` +
    `  kept collections : ${keep.join(', ')}\n` +
    `  dropped          : ${stats.droppedCollections.join(', ') || '(none)'}\n` +
    `  documents        : ${stats.before.documents} -> ${stats.after.documents}\n` +
    `  content          : ${stats.before.content} -> ${stats.after.content}\n` +
    `  content_vectors  : ${stats.before.contentVectors} -> ${stats.after.contentVectors}\n` +
    `  vectors_vec      : ${stats.before.vectors} -> ${stats.after.vectors}\n` +
    `  staging size     : ${mb(stats.sizeBytes)}\n` +
    `  staging path     : ${out}\n`);
  }
}
