#!/usr/bin/env bash
# Tests for scripts/luna/prepare-ship-index.mjs (HIMMEL-1275).
#
# Builds REAL fixture qmd-shaped SQLite databases (schema + the documents_ad FTS
# trigger + a vec0 virtual table) and runs the real script against them, so the
# reconcile rules and the vec0 orphan GC are exercised for real rather than
# asserted textually. Needs NO second machine and NO network — the transport
# half is not touched here.
#
# SKIPS (cleanly, rc 0) when better-sqlite3 or vec0 cannot be loaded on this
# host: those come from the qmd fork checkout, not from this repo, so a bare CI
# runner legitimately lacks them. A skip prints why — it never reads as a pass
# of assertions that did not run.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/prepare-ship-index.mjs"

PASS=0
FAIL=0
TMP_ROOT=""

# shellcheck disable=SC2329,SC2317
cleanup() {
    if [ -n "$TMP_ROOT" ] && [ -d "$TMP_ROOT" ]; then
        rm -rf "$TMP_ROOT" 2>/dev/null || true
    fi
}
trap cleanup EXIT

pass() { echo "  PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "  FAIL: $1"; if [ $# -ge 2 ]; then printf '    %s\n' "$2"; fi; FAIL=$((FAIL+1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name" "expected '$want', got '$got'"; fi
}
assert_contains() {
    local name="$1" needle="$2" haystack="$3"
    # here-string, not `printf | grep -q` (HIMMEL-1115 pipefail false-negative)
    if grep -qF -- "$needle" <<<"$haystack"; then pass "$name"; else fail "$name" "missing: $needle"; fi
}
assert_rc() {
    local name="$1" want="$2" got="$3"
    if [ "$got" = "$want" ]; then pass "$name"; else fail "$name" "expected rc=$want, got rc=$got"; fi
}
summary() {
    echo
    echo "===================================="
    echo "test summary: $PASS passed, $FAIL failed"
    echo "===================================="
    [ "$FAIL" -gt 0 ] && exit 1 || exit 0
}

command -v node >/dev/null 2>&1 || { echo "SKIP: node not on PATH"; exit 0; }

TMP_ROOT=$(mktemp -d)

# --- dependency probe --------------------------------------------------------
# Resolve better-sqlite3 + vec0 the SAME way the script under test does, so a
# skip here means the script genuinely cannot run on this host.
PROBE="$TMP_ROOT/probe.mjs"
cat >"$PROBE" <<'PROBE_EOF'
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
const require = createRequire(import.meta.url);
const bs3 = [process.env.HIMMEL_BETTER_SQLITE3,
  `${homedir()}/.himmel/qmd-fork/node_modules/better-sqlite3`,
  `${homedir()}/Documents/github/qmd/node_modules/better-sqlite3`].filter(Boolean);
let D = null, used = '';
for (const c of bs3) { try { D = require(c); used = c; break; } catch {} }
if (!D) { console.log('NO_BS3'); process.exit(0); }
// Per-platform sqlite-vec package + library name, mirroring the script under
// test. A Windows-only list makes every POSIX host report "vec0 unavailable".
const pkgs = process.platform === 'win32' ? [['sqlite-vec-windows-x64','vec0.dll']]
  : process.platform === 'darwin' ? [['sqlite-vec-darwin-arm64','vec0.dylib'],['sqlite-vec-darwin-x64','vec0.dylib']]
  : [['sqlite-vec-linux-x64','vec0.so'],['sqlite-vec-linux-arm64','vec0.so']];
const roots = [`${homedir()}/.himmel/qmd-fork/node_modules`,
  `${homedir()}/Documents/github/qmd/node_modules`,
  `${homedir()}/.bun/install/global/node_modules`];
const vecs = [process.env.HIMMEL_VEC0, ...roots.flatMap(r=>pkgs.map(([k,l])=>`${r}/${k}/${l}`))].filter(Boolean);
const db = new D(':memory:');
let ok = '';
for (const c of vecs) { if (!existsSync(c)) continue; try { db.loadExtension(c); ok = c; break; } catch {} }
db.close();
console.log(ok ? 'OK ' + used + ' ' + ok : 'NO_VEC0');
PROBE_EOF
probe_out="$(node "$PROBE" 2>&1 || true)"
case "$probe_out" in
    NO_BS3*)  echo "SKIP: better-sqlite3 unavailable on this host (qmd fork not installed) — $probe_out"; exit 0 ;;
    NO_VEC0*) echo "SKIP: vec0 extension unavailable on this host — $probe_out"; exit 0 ;;
    OK*)      echo "deps OK: $probe_out" ;;
    *)        echo "SKIP: dependency probe inconclusive: $probe_out"; exit 0 ;;
esac

# --- fixture builder ---------------------------------------------------------
# Mirrors the real qmd schema closely enough to exercise every rule under test:
# the documents_ad FTS trigger, content shared across collections, and a vec0
# table keyed by "<hash>_<seq>".
MKFIX="$TMP_ROOT/mkfix.mjs"
cat >"$MKFIX" <<'FIX_EOF'
import { createRequire } from 'node:module';
import { existsSync } from 'node:fs';
import { homedir } from 'node:os';
const require = createRequire(import.meta.url);
const out = process.argv[2];
const mode = process.argv[3] || 'normal';
const bs3 = [process.env.HIMMEL_BETTER_SQLITE3,
  `${homedir()}/.himmel/qmd-fork/node_modules/better-sqlite3`,
  `${homedir()}/Documents/github/qmd/node_modules/better-sqlite3`].filter(Boolean);
let D = null; for (const c of bs3) { try { D = require(c); break; } catch {} }
// Per-platform sqlite-vec package + library name, mirroring the script under
// test. A Windows-only list makes every POSIX host report "vec0 unavailable".
const pkgs = process.platform === 'win32' ? [['sqlite-vec-windows-x64','vec0.dll']]
  : process.platform === 'darwin' ? [['sqlite-vec-darwin-arm64','vec0.dylib'],['sqlite-vec-darwin-x64','vec0.dylib']]
  : [['sqlite-vec-linux-x64','vec0.so'],['sqlite-vec-linux-arm64','vec0.so']];
const roots = [`${homedir()}/.himmel/qmd-fork/node_modules`,
  `${homedir()}/Documents/github/qmd/node_modules`,
  `${homedir()}/.bun/install/global/node_modules`];
const vecs = [process.env.HIMMEL_VEC0, ...roots.flatMap(r=>pkgs.map(([k,l])=>`${r}/${k}/${l}`))].filter(Boolean);
const db = new D(out);
for (const c of vecs) { if (existsSync(c)) { try { db.loadExtension(c); break; } catch {} } }

db.exec(`
CREATE TABLE store_collections(name TEXT PRIMARY KEY, path TEXT, pattern TEXT,
  ignore_patterns TEXT, include_by_default INTEGER, update_command TEXT, context TEXT);
CREATE TABLE documents(id INTEGER PRIMARY KEY, collection TEXT, path TEXT, title TEXT,
  hash TEXT, created_at TEXT, modified_at TEXT, active INTEGER, disk_mtime TEXT);
CREATE TABLE content(hash TEXT PRIMARY KEY, doc TEXT, created_at TEXT);
CREATE TABLE content_vectors(hash TEXT, seq INTEGER, pos INTEGER, model TEXT,
  embedded_at TEXT, embed_fingerprint TEXT, total_chunks INTEGER, PRIMARY KEY(hash, seq));
CREATE VIRTUAL TABLE documents_fts USING fts5(filepath, title, body, tokenize='porter unicode61');
CREATE VIRTUAL TABLE vectors_vec USING vec0(hash_seq TEXT PRIMARY KEY, embedding float[4] distance_metric=cosine);
CREATE TRIGGER documents_ai AFTER INSERT ON documents WHEN new.active = 1 BEGIN
  INSERT INTO documents_fts(rowid, filepath, title, body)
  SELECT new.id, new.collection || '/' || new.path, new.title,
         (SELECT doc FROM content WHERE hash = new.hash) WHERE new.active = 1;
END;
CREATE TRIGGER documents_ad AFTER DELETE ON documents BEGIN
  DELETE FROM documents_fts WHERE rowid = old.id;
END;
`);

const cols = ['himmel', 'luna', 'salus', 'luna-curated'];
const insCol = db.prepare('INSERT INTO store_collections(name,path,pattern) VALUES (?,?,?)');
for (const c of cols) insCol.run(c, '/x/' + c, '**/*.md');

const insContent = db.prepare('INSERT OR IGNORE INTO content(hash,doc,created_at) VALUES (?,?,?)');
const insDoc = db.prepare('INSERT INTO documents(id,collection,path,title,hash,active) VALUES (?,?,?,?,?,1)');
const insCV = db.prepare('INSERT INTO content_vectors(hash,seq,pos,model,total_chunks) VALUES (?,?,?,?,?)');
const insVec = db.prepare('INSERT INTO vectors_vec(hash_seq, embedding) VALUES (?, ?)');
const emb = () => new Float32Array([0.1, 0.2, 0.3, 0.4]);

// h_shared is referenced by BOTH luna and luna-curated — the shared-content
// case that a naive "delete content of dropped collections" would break.
let id = 1;
const rows = [
  ['himmel', 'a.md', 'h_himmel'],
  ['luna', 'b.md', 'h_shared'],
  ['luna-curated', 'b.md', 'h_shared'],
  ['salus', 'c.md', 'h_salus'],
  ['luna-curated', 'd.md', 'h_curated_only'],
];
for (const [col, path, hash] of rows) {
  insContent.run(hash, 'body of ' + hash, '2026-01-01');
  insDoc.run(id++, col, path, 'T ' + path, hash);
}
for (const hash of ['h_himmel', 'h_shared', 'h_salus', 'h_curated_only']) {
  for (let s = 0; s < 2; s++) {
    insCV.run(hash, s, s, 'm', 2);
    insVec.run(hash + '_' + s, emb());
  }
}

if (mode === 'nullhash') {
  // ONE document row with a NULL hash. Under the old `NOT IN (SELECT hash FROM
  // documents)` predicate this makes the whole orphan-content delete evaluate to
  // NULL for every row — deleting NOTHING — and the self-check used the same
  // predicate, so it reported clean. A single NULL silently disabled the entire
  // orphan cleanup while claiming success.
  insDoc.run(id++, 'luna', 'nullish.md', 'T nullish', null);
}

if (mode === 'orphans') {
  // Pre-existing vec0 orphans with NO content_vectors row — the 22,895-row
  // situation that was GC'd by hand on 2026-07-23. These must be gone after.
  for (let s = 0; s < 3; s++) insVec.run('h_ghost_' + s, emb());
}
db.close();
console.log('fixture written: ' + out + ' (' + mode + ')');
FIX_EOF

mkfix() { node "$MKFIX" "$1" "${2:-normal}" >/dev/null; }
q() {
  node -e '
  const {createRequire}=require("module");const req=createRequire(process.cwd()+"/x.js");
  const os=require("os");
  const cands=[process.env.HIMMEL_BETTER_SQLITE3,
    os.homedir()+"/.himmel/qmd-fork/node_modules/better-sqlite3",
    os.homedir()+"/Documents/github/qmd/node_modules/better-sqlite3"].filter(Boolean);
  let D=null;for(const c of cands){try{D=req(c);break;}catch{}}
  const fs=require("fs");
  const pkgs=process.platform==="win32"?[["sqlite-vec-windows-x64","vec0.dll"]]
    :process.platform==="darwin"?[["sqlite-vec-darwin-arm64","vec0.dylib"],["sqlite-vec-darwin-x64","vec0.dylib"]]
    :[["sqlite-vec-linux-x64","vec0.so"],["sqlite-vec-linux-arm64","vec0.so"]];
  const roots=[os.homedir()+"/.himmel/qmd-fork/node_modules",
    os.homedir()+"/Documents/github/qmd/node_modules",
    os.homedir()+"/.bun/install/global/node_modules"];
  const vecs=[process.env.HIMMEL_VEC0].concat(...roots.map(r=>pkgs.map(kl=>r+"/"+kl[0]+"/"+kl[1]))).filter(Boolean);
  const db=new D(process.argv[1],{readonly:true});
  for(const c of vecs){if(fs.existsSync(c)){try{db.loadExtension(c);break;}catch{}}}
  process.stdout.write(String(db.prepare(process.argv[2]).get().c));
  db.close();' "$1" "$2"
}

SRC="$TMP_ROOT/src.sqlite"
OUT="$TMP_ROOT/out.sqlite"

# ============================================================================
echo "TEST: argument handling"
# ============================================================================
rc=0; out=$(node "$SCRIPT" --help 2>&1) || rc=$?
assert_rc "--help rc 0" 0 "$rc"
rc=0; out=$(node "$SCRIPT" --src x 2>&1) || rc=$?
assert_rc "missing --out rc 1" 1 "$rc"
rc=0; out=$(node "$SCRIPT" --src x --out y 2>&1) || rc=$?
assert_rc "missing --collections rc 1" 1 "$rc"
assert_contains "missing --collections explains itself" "--collections is required" "$out"
mkfix "$SRC"
# An empty set would reconcile the shipped index down to nothing — a plausible
# shell-expansion accident, never a real intent.
rc=0; out=$(node "$SCRIPT" --src "$SRC" --out "$OUT" --collections "" 2>&1) || rc=$?
assert_rc "empty --collections rc 1" 1 "$rc"
assert_contains "empty set refused loudly" "refusing to ship an empty index" "$out"
rc=0; out=$(node "$SCRIPT" --src "$SRC" --out "$SRC" --collections luna 2>&1) || rc=$?
assert_rc "same src and out rc 1" 1 "$rc"
rc=0; out=$(node "$SCRIPT" --src "$TMP_ROOT/nope.sqlite" --out "$OUT" --collections luna 2>&1) || rc=$?
assert_rc "missing source rc 3" 3 "$rc"

# ============================================================================
echo "TEST: refuses a collection the SOURCE does not have"
# ============================================================================
# Silently shipping an index missing a collection the receiver expects is the
# "orphan/absent collection" failure the reconcile policy exists to prevent.
rc=0; out=$(node "$SCRIPT" --src "$SRC" --out "$OUT" --collections himmel,nosuch 2>&1) || rc=$?
assert_rc "unknown receiver collection rc 1" 1 "$rc"
assert_contains "names the missing collection" "nosuch" "$out"
assert_contains "refuses rather than silently omitting" "silently omits" "$out"

# ============================================================================
echo "TEST: reconcile keeps only the receiver's collections"
# ============================================================================
rm -f "$OUT"
rc=0; out=$(node "$SCRIPT" --src "$SRC" --out "$OUT" --collections himmel,luna 2>&1) || rc=$?
assert_rc "reconcile rc 0" 0 "$rc"
assert_eq "store_collections reduced to 2" "2" "$(q "$OUT" 'select count(*) c from store_collections')"
assert_eq "only kept-collection documents survive" "0" \
    "$(q "$OUT" "select count(*) c from documents where collection not in ('himmel','luna')")"
assert_eq "kept documents present" "2" "$(q "$OUT" 'select count(*) c from documents')"
# The source must never be touched.
assert_eq "SOURCE still has all 4 collections" "4" "$(q "$SRC" 'select count(*) c from store_collections')"
assert_eq "SOURCE still has all 5 documents" "5" "$(q "$SRC" 'select count(*) c from documents')"

# ============================================================================
echo "TEST: content SHARED across collections is retained"
# ============================================================================
# h_shared is referenced by luna (kept) AND luna-curated (dropped). Deleting
# content by dropped-collection would remove it and break luna's search.
assert_eq "shared content retained" "1" "$(q "$OUT" "select count(*) c from content where hash='h_shared'")"
assert_eq "curated-only content dropped" "0" "$(q "$OUT" "select count(*) c from content where hash='h_curated_only'")"
assert_eq "salus content dropped" "0" "$(q "$OUT" "select count(*) c from content where hash='h_salus'")"
assert_eq "no orphan content at all" "0" \
    "$(q "$OUT" 'select count(*) c from content where hash not in (select hash from documents)')"

# ============================================================================
echo "TEST: vec0 orphan GC (the rows that never self-clean)"
# ============================================================================
assert_eq "vectors_vec == content_vectors after GC" \
    "$(q "$OUT" 'select count(*) c from content_vectors')" \
    "$(q "$OUT" 'select count(*) c from vectors_vec')"
assert_eq "dropped-collection vectors gone" "0" \
    "$(q "$OUT" "select count(*) c from vectors_vec where hash_seq like 'h_salus%'")"
assert_eq "kept vectors survive" "4" \
    "$(q "$OUT" "select count(*) c from vectors_vec where hash_seq like 'h_himmel%' or hash_seq like 'h_shared%'")"

echo "TEST: PRE-EXISTING vec0 orphans are collected too"
SRC2="$TMP_ROOT/src-orphans.sqlite"
OUT2="$TMP_ROOT/out-orphans.sqlite"
mkfix "$SRC2" orphans
assert_eq "fixture really has the ghost rows" "3" \
    "$(q "$SRC2" "select count(*) c from vectors_vec where hash_seq like 'h_ghost%'")"
rc=0; out=$(node "$SCRIPT" --src "$SRC2" --out "$OUT2" --collections himmel,luna 2>&1) || rc=$?
assert_rc "orphan fixture rc 0" 0 "$rc"
assert_eq "ghost vec0 rows collected" "0" \
    "$(q "$OUT2" "select count(*) c from vectors_vec where hash_seq like 'h_ghost%'")"
assert_eq "vectors_vec == content_vectors (orphan fixture)" \
    "$(q "$OUT2" 'select count(*) c from content_vectors')" \
    "$(q "$OUT2" 'select count(*) c from vectors_vec')"

# ============================================================================
echo "TEST: FTS follows the documents delete via the trigger"
# ============================================================================
# documents_ad cascades; the script must NOT hand-delete from the contentless
# fts5 table. If this drifts, the receiver searches deleted docs.
assert_eq "fts rows match surviving active documents" \
    "$(q "$OUT" 'select count(*) c from documents where active=1')" \
    "$(q "$OUT" 'select count(*) c from documents_fts')"

# ============================================================================
echo "TEST: --json emits machine-readable stats the transport consumes"
# ============================================================================
rm -f "$OUT"
# Capture rc explicitly (suite convention): under `set -e` an unguarded failure
# here would abort the whole run silently instead of reporting a FAIL.
rc=0; json=$(node "$SCRIPT" --src "$SRC" --out "$OUT" --collections himmel,luna --json 2>/dev/null) || rc=$?
assert_rc "--json rc 0" 0 "$rc"
assert_contains "json reports ok" '"ok":true' "$json"
assert_contains "json carries after.documents" '"documents"' "$json"
assert_contains "json names dropped collections" 'salus' "$json"
rc=0; docs=$(node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>process.stdout.write(String(JSON.parse(s).after.documents)))' <<<"$json") || rc=$?
assert_rc "json parse rc 0" 0 "$rc"
assert_eq "json after.documents parses to 2" "2" "$docs"

# ============================================================================
echo "TEST: a NULL document hash does not disable orphan cleanup (NOT EXISTS)"
# ============================================================================
# Regression pin for CR finding [glm-4]. `x NOT IN (subquery)` yields NULL — not
# TRUE — for every row once the subquery contains a single NULL, so ONE document
# with a NULL hash silently deleted no orphan content at all, and the self-check
# (same predicate) reported it clean. NOT EXISTS is NULL-safe.
SRC_NULL="$TMP_ROOT/src-nullhash.sqlite"
OUT_NULL="$TMP_ROOT/out-nullhash.sqlite"
mkfix "$SRC_NULL" nullhash
rc=0; out=$(node "$SCRIPT" --src "$SRC_NULL" --out "$OUT_NULL" --collections himmel,luna 2>&1) || rc=$?
assert_rc "null-hash fixture rc 0" 0 "$rc"
# salus/luna-curated-only content must STILL be gone despite the NULL row.
assert_eq "orphan cleanup still ran with a NULL hash present" "0" \
    "$(q "$OUT_NULL" "select count(*) c from content where hash='h_salus'")"
assert_eq "no orphan content survives (NULL-safe predicate)" "0" \
    "$(q "$OUT_NULL" 'select count(*) c from content where not exists (select 1 from documents d where d.hash = content.hash)')"
assert_eq "vectors still converge with a NULL hash present" \
    "$(q "$OUT_NULL" 'select count(*) c from content_vectors')" \
    "$(q "$OUT_NULL" 'select count(*) c from vectors_vec')"

# ============================================================================
echo "TEST: refuses a source whose documents_ad FTS trigger is missing"
# ============================================================================
# The whole FTS story rests on that trigger cascading document deletes. Without
# it the reconcile still "succeeds" and ships an index that full-text-matches
# documents it no longer contains — a wrong ANSWER with no error anywhere.
SRC_NOTRIG="$TMP_ROOT/src-notrigger.sqlite"
cp "$SRC" "$SRC_NOTRIG"
rc=0; node -e '
const {createRequire}=require("module");const req=createRequire(process.cwd()+"/x.js");
const os=require("os");
const cands=[process.env.HIMMEL_BETTER_SQLITE3,
  os.homedir()+"/.himmel/qmd-fork/node_modules/better-sqlite3",
  os.homedir()+"/Documents/github/qmd/node_modules/better-sqlite3"].filter(Boolean);
let D=null;for(const c of cands){try{D=req(c);break;}catch{}}
const fs=require("fs");
// Load vec0 before touching a DB that CONTAINS a vec0 virtual table — without
// it SQLite can refuse on schema access, and this helper would fail for a
// reason unrelated to what the test is checking.
const pkgs=process.platform==="win32"?[["sqlite-vec-windows-x64","vec0.dll"]]
  :process.platform==="darwin"?[["sqlite-vec-darwin-arm64","vec0.dylib"],["sqlite-vec-darwin-x64","vec0.dylib"]]
  :[["sqlite-vec-linux-x64","vec0.so"],["sqlite-vec-linux-arm64","vec0.so"]];
const roots=[os.homedir()+"/.himmel/qmd-fork/node_modules",
  os.homedir()+"/Documents/github/qmd/node_modules",
  os.homedir()+"/.bun/install/global/node_modules"];
const vecs=[process.env.HIMMEL_VEC0].concat(...roots.map(r=>pkgs.map(kl=>r+"/"+kl[0]+"/"+kl[1]))).filter(Boolean);
const db=new D(process.argv[1]);
for(const c of vecs){if(fs.existsSync(c)){try{db.loadExtension(c);break;}catch{}}}
db.exec("DROP TRIGGER documents_ad"); db.close();' "$SRC_NOTRIG" || rc=$?
assert_rc "fixture trigger dropped" 0 "$rc"
rc=0; out=$(node "$SCRIPT" --src "$SRC_NOTRIG" --out "$TMP_ROOT/out-notrig.sqlite" --collections himmel,luna 2>&1) || rc=$?
assert_rc "missing documents_ad trigger rc 3" 3 "$rc"
assert_contains "names the missing trigger" "documents_ad" "$out"
if [ ! -f "$TMP_ROOT/out-notrig.sqlite" ]; then
    pass "no artifact produced when the trigger is missing"
else
    fail "produced an artifact despite the missing trigger"
fi

# ============================================================================
echo "TEST: a FAILED build leaves any previous --out artifact intact"
# ============================================================================
# The artifact is built at a sibling work path and promoted only after the
# self-check passes, so a failure must not destroy a good previous artifact
# (nor leave a half-written file at the path the transport uploads).
PREV="$TMP_ROOT/prev-out.sqlite"
rc=0; node "$SCRIPT" --src "$SRC" --out "$PREV" --collections himmel,luna >/dev/null 2>&1 || rc=$?
assert_rc "seed a good previous artifact" 0 "$rc"
prev_sum="$(wc -c < "$PREV" | tr -d ' ')"
rc=0; node "$SCRIPT" --src "$SRC_NOTRIG" --out "$PREV" --collections himmel,luna >/dev/null 2>&1 || rc=$?
assert_rc "failing build rc 3" 3 "$rc"
assert_eq "previous artifact untouched after a failed build" "$prev_sum" "$(wc -c < "$PREV" | tr -d ' ')"
if ! compgen -G "$PREV.building.*" >/dev/null; then
    pass "no .building work file left behind"
else
    fail "work file litter left" "$(ls "$TMP_ROOT")"
fi

summary
