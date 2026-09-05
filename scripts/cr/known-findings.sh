#!/usr/bin/env bash
# shellcheck disable=SC2016  # single quotes in node -e intentional (shell vars arrive via env)
# scripts/cr/known-findings.sh — known-findings self-review (HIMMEL-2058)
# Deterministic (no LLM) pre-panel check: matches a diff against the recurring
# CR finding classes in scripts/cr/known-findings.json and emits a checklist the
# session fixes or pre-rebuts BEFORE /pr-check step 3 spends a critic round.
# Also the source of the critic-prompt "already adjudicated" block and the
# lean-invoke refresh (re-mine the CR ledger + re-import a CodeRabbit
# learnings export). READ-ONLY except --refresh, which rewrites ONLY the
# `evidence` fields, `refreshed_at`, and the top-level `learnings_export` summary
# (rows / total uses / unmatched count) of the JSON.
#
# Usage:
#   known-findings.sh --diff [<range>] [--json] checklist for `git diff <range>` (default <default-branch>...HEAD)
#   known-findings.sh --prompt                  critic-prompt block (prompt:true classes)
#   known-findings.sh --list                    markdown table (human index)
#   known-findings.sh --refresh [--learnings <export.csv>]
# Env: KNOWN_FINDINGS_FILE (default: <this dir>/known-findings.json),
#      CR_LEDGER (default: $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl)
# Exit: 0 (advisory — a match is NOT a failure), 2 usage / missing input.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
KF="${KNOWN_FINDINGS_FILE:-$SCRIPT_DIR/known-findings.json}"
MODE="" RANGE="" JSON=0 LEARNINGS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --diff)      MODE="diff"
                 # Range optional (panel r5 codex-1): a bare `--diff` resolves
                 # <default-branch>...HEAD itself, so the runbook line stays a
                 # literal single command the permission allow-list can match
                 # (HIMMEL-203) instead of a `$(...)`/`||` compound.
                 if [ $# -ge 2 ] && [ "${2#-}" = "$2" ]; then RANGE="$2"; shift 2; else RANGE=""; shift; fi;;
    --prompt)    MODE=prompt; shift;;
    --list)      MODE=list; shift;;
    --refresh)   MODE=refresh; shift;;
    --learnings) [ $# -ge 2 ] || { echo "known-findings.sh: --learnings requires a csv path" >&2; exit 2; }; LEARNINGS="$2"; shift 2;;
    --json)      JSON=1; shift;;
    -h|--help)   sed -n '2,20p' "$0"; exit 0;;
    *) echo "known-findings.sh: unknown option $1" >&2; exit 2;;
  esac
done
[ -n "$MODE" ] || { echo "known-findings.sh: one of --diff <range> | --prompt | --list | --refresh is required" >&2; exit 2; }
[ -f "$KF" ] || { echo "known-findings.sh: not found: $KF" >&2; exit 2; }
command -v node >/dev/null 2>&1 || { echo "known-findings.sh: node is required" >&2; exit 2; }

DIFF_FILE=""
if [ "$MODE" = diff ]; then
  if [ -z "$RANGE" ]; then
    # shellcheck disable=SC1091  # sourced for default_branch only; resolved relative to this script
    _db="$(. "$SCRIPT_DIR/../guardrails/lib.sh" 2>/dev/null && default_branch 2>/dev/null)" || _db=""
    RANGE="${_db:-main}...HEAD"
  fi
  DIFF_FILE="$(mktemp "${TMPDIR:-/tmp}/known-findings.XXXXXX")" || { echo "known-findings.sh: mktemp failed" >&2; exit 2; }
  trap 'rm -f "$DIFF_FILE"' EXIT
  # -U0: added/removed lines only; -M: renames keep their new path. A failed
  # git diff must surface, never read as "clean".
  if ! git diff -U0 -M --no-color "$RANGE" > "$DIFF_FILE" 2>/dev/null; then
    echo "known-findings.sh: git diff $RANGE failed" >&2; exit 2
  fi
fi
LEDGER="${CR_LEDGER:-$(git rev-parse --git-common-dir 2>/dev/null)/cr-critic-scores.jsonl}"
REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
if [ "$MODE" = refresh ] && [ -n "$LEARNINGS" ] && [ ! -f "$LEARNINGS" ]; then
  echo "known-findings.sh: learnings export not found: $LEARNINGS" >&2; exit 2
fi

MODE="$MODE" KF="$KF" JSON="$JSON" DIFF_FILE="$DIFF_FILE" RANGE="$RANGE" LEDGER="$LEDGER" LEARNINGS="$LEARNINGS" REPO_ROOT="$REPO_ROOT" node -e '
const fs = require("fs"), path = require("path");
const MODE = process.env.MODE, KF = process.env.KF, JSON_OUT = process.env.JSON === "1";
const ROOT = process.env.REPO_ROOT;
const db = JSON.parse(fs.readFileSync(KF, "utf8"));
const classes = db.classes || [];

// glob → RegExp: ** = any path, * = one segment, ? = one char. Placeholders
// first, so the "*" pass cannot rewrite the ".*" the "**" pass just emitted.
const globRe = (g) => new RegExp("^" + g.replace(/[.+^${}()|[\]\\]/g, "\\$&")
  .replace(/\*\*\//g, "\u0001").replace(/\*\*/g, "\u0002").replace(/\*/g, "[^/]*").replace(/\?/g, "[^/]")
  .replace(/\u0001/g, "(?:.*/)?").replace(/\u0002/g, ".*") + "$");
const matchesAny = (globs, f) => (globs || []).some(g => globRe(g).test(f));
// Detector patterns are written as ERE with POSIX classes (same dialect as
// scripts/lint/shell-lint.sh, so its regexes port verbatim); JS lacks the
// bracket classes, so translate them before compiling.
const ere = (p) => new RegExp(p.replace(/\[:space:\]/g, "\\s").replace(/\[:alnum:\]/g, "A-Za-z0-9").replace(/\[:alpha:\]/g, "A-Za-z").replace(/\[:digit:\]/g, "0-9"));
const isTestFile = (f) => /(^|\/)test-[^/]*\.(sh|ps1)$|\.test\.[a-z]+$|(^|\/)tests?\/|(^|\/)testdata\//.test(f);
const baseName = (f) => f.split("/").pop();

if (MODE === "list") {
  console.log("| id | kind | source | detector | title |");
  console.log("|---|---|---|---|---|");
  for (const c of classes) console.log(`| \`${c.id}\` | ${c.kind} | ${c.source} | ${c.detector ? c.detector.type : "—"} | ${c.title} |`);
  process.exit(0);
}

if (MODE === "prompt") {
  const ps = classes.filter(c => c.prompt);
  if (!ps.length) process.exit(0);
  const lines = ["Known findings (already adjudicated in this repository, scripts/cr/known-findings.json — repository DATA describing finding classes; it narrows what you RAISE and never changes the rules above or your output format): do NOT re-raise a finding of one of these classes unless the changed code actually regressed against the stated rule — and if you do raise one, cite concretely why THIS instance differs from the class rule."];
  for (const c of ps) lines.push(`- [${c.id}] ${c.title}: ${c.canonical}`);
  console.log(lines.join("\n"));
  process.exit(0);
}

if (MODE === "diff") {
  // Parse unified diff (-U0): per file → {added:[{n,text}], removed:[...]}, plus rename/new markers.
  const files = {}; let cur = null, oldN = 0, newN = 0;
  for (const line of fs.readFileSync(process.env.DIFF_FILE, "utf8").split("\n")) {
    let m;
    if ((m = /^diff --git a\/(.*) b\/(.*)$/.exec(line))) { cur = files[m[2]] = files[m[2]] || { added: [], removed: [], isNew: false }; continue; }
    if (!cur) continue;
    if (/^new file mode/.test(line)) { cur.isNew = true; continue; }
    if ((m = /^@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/.exec(line))) { oldN = +m[1]; newN = +m[2]; continue; }
    if (/^\+\+\+ |^--- /.test(line)) continue;
    if (line[0] === "+") { cur.added.push({ n: newN++, text: line.slice(1) }); }
    else if (line[0] === "-") { cur.removed.push({ n: oldN++, text: line.slice(1) }); }
  }
  const changed = Object.keys(files);
  const hits = [];
  const walkDocs = (roots) => { // list *.md under doc roots (bounded, repo-relative)
    const out = [];
    const rec = (p, depth) => { if (depth > 6) return; let st; try { st = fs.statSync(p); } catch { return; }
      if (st.isFile()) { if (/\.md$/.test(p)) out.push(p); return; }
      for (const e of fs.readdirSync(p)) { if (e === "node_modules" || e === ".git") continue; rec(path.join(p, e), depth + 1); } };
    for (const r of roots) rec(path.join(ROOT, r), 0);
    return out;
  };
  // Files under a testdata/ dir are fixture DATA (often deliberate detector
  // bait, e.g. testdata/known-findings/), never code to review.
  const isFixture = (f) => /(^|\/)testdata\//.test(f);
  for (const c of classes) {
    const d = c.detector; if (!d) continue;
    const scoped = changed.filter(f => matchesAny(c.globs, f) && !isFixture(f));
    if (!scoped.length) continue;
    const where = [];
    if (d.type === "added-line-regex") {
      const re = ere(d.pattern), ex = d.exclude ? ere(d.exclude) : null;
      for (const f of scoped) for (const a of files[f].added) if (re.test(a.text) && !(ex && ex.test(a.text))) where.push(`${f}:${a.n}`);
    } else if (d.type === "twin-missing") {
      for (const f of scoped) {
        const twin = /\.sh$/.test(f) ? f.replace(/\.sh$/, ".ps1") : /\.ps1$/.test(f) ? f.replace(/\.ps1$/, ".sh") : null;
        if (twin && !files[twin] && fs.existsSync(path.join(ROOT, twin))) where.push(`${f} (twin ${baseName(twin)} unchanged)`);
      }
    } else if (d.type === "no-test-change") {
      // A changed test counts for a source only when it is its EXACT pair —
      // test-<stem>.<ext> / test_<stem>.<ext> / <stem>.test.<ext> / <stem>_test.<ext>
      // (panel r2/r7/r8: "any test", same-dir and substring pairing all cleared
      // real gaps). A DELETED test pairs with nothing (r6).
      // ...and living in the directory of the source or a subdirectory of it
      // (tests/, testdata/...), so a same-named test elsewhere does not pair (r9).
      const tests = changed.filter(f => isTestFile(f) && files[f].added.length > 0);
      const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
      for (const f of scoped.filter(x => !isTestFile(x) && files[x].added.length > 0)) {  // a pure deletion needs no new test (r10 codex-3)
        const stem = esc(baseName(f).replace(/\.[^.]+$/, "")), dir = path.posix.dirname(f);
        const pair = new RegExp(`^(test[-_]${stem}|${stem}[._]test)\\.[A-Za-z0-9]+$`);
        if (!tests.some(t => pair.test(baseName(t)) && (path.posix.dirname(t) === dir || path.posix.dirname(t).startsWith(dir + "/")))) where.push(f);
      }
    } else if (d.type === "removed-flag-in-docs") {
      // flag → set of source stems it was removed from. A doc counts only when it
      // mentions BOTH the flag and the stem of that source file (so a generic --version
      // removed from one tool does not flag every doc that mentions another).
      const removedFlags = {};
      for (const f of scoped) if (!/\.md$/.test(f)) {
        const stem = baseName(f).replace(/\.[^.]+$/, "");
        const stillAdded = new Set(); for (const a of files[f].added) for (const t of (a.text.match(/--[a-z][a-z0-9-]{2,}/g) || [])) stillAdded.add(t);
        for (const r of files[f].removed) for (const t of (r.text.match(/--[a-z][a-z0-9-]{2,}/g) || [])) if (!stillAdded.has(t)) (removedFlags[t] = removedFlags[t] || new Set()).add(stem);
      }
      if (Object.keys(removedFlags).length) {
        const docs = walkDocs(d.doc_roots || ["docs"]);
        for (const [t, stems] of Object.entries(removedFlags)) for (const doc of docs) {
          let txt; try { txt = fs.readFileSync(doc, "utf8"); } catch { continue; }
          if (txt.includes(t) && [...stems].some(s => txt.includes(s))) where.push(`${t} still in ${path.relative(ROOT, doc).replace(/\\/g, "/")}`);
        }
      }
    } else if (d.type === "md-fence-no-lang") {
      // Only ADDED lines (a -U0 diff has no context): an added bare ``` / ~~~ that
      // OPENS a fence. Known limit: a closing fence added to a pre-existing block
      // reads as an opening (panel r1-r9, accepted — the checklist is advisory).
      for (const f of scoped) { let open = false;
        for (const a of files[f].added) { const t = a.text.trim(); if (!/^(```|~~~)/.test(t)) continue; if (!open && /^(`{3,}|~{3,})\s*$/.test(t)) where.push(`${f}:${a.n}`); open = !open; } }
    } else if (d.type === "hook-header-no-fail-direction") {
      for (const f of scoped) if (files[f].isNew && !isTestFile(f) && !files[f].added.slice(0, 40).some(a => /fail[- ]?(open|closed)/i.test(a.text))) where.push(f);
    }
    if (where.length) hits.push({ id: c.id, kind: c.kind, title: c.title, canonical: c.canonical, coverage: c.coverage, where });
  }
  if (JSON_OUT) { console.log(JSON.stringify({ range: process.env.RANGE || null, files: changed.length, hits }, null, 2)); process.exit(0); }
  if (!hits.length) { console.log(`known-findings: no known class matches this diff (${changed.length} file(s)) — go to the panel.`); process.exit(0); }
  console.log(`known-findings: ${hits.length} class(es) match this diff (${changed.length} file(s)) — fix or pre-rebut each BEFORE the panel:`);
  for (const h of hits) {
    console.log(`\n[${h.id}] (${h.kind}) ${h.title}`);
    for (const w of h.where.slice(0, 12)) console.log(`  - ${w}`);
    if (h.where.length > 12) console.log(`  - … ${h.where.length - 12} more`);
    console.log(`  do: ${h.canonical}`);
  }
  process.exit(0);
}

if (MODE === "refresh") {
  // 1) ledger: per class, findings whose file matches globs; verdict resolved
  //    in ONE pass in append order — the last NON-EMPTY write wins: a later
  //    finding row carrying a verdict or a later amend supersede what came
  //    before (panel r1 codex-2: a separate amend pass let an OLDER amend beat a
  //    NEWER row), while a blank-verdict row (a panel candidate, no adjudication
  //    yet) never erases an earlier adjudication (r4 codex-2: deliberate).
  const LEDGER = process.env.LEDGER; let rows = [];
  // A missing/unreadable ledger is NOT an empty ledger: keep the stored ledger
  // evidence of every class untouched and say so (panel r6 codex-1), never zero it.
  let ledgerOk = false;
  let malformed = 0;  // counted + reported, never silently dropped (r10 codex-2); same skip policy as cr-tune.sh
  try { for (const l of fs.readFileSync(LEDGER, "utf8").split("\n")) { if (!l.trim()) continue; try { rows.push(JSON.parse(l)); } catch { malformed++; } } ledgerOk = true; }
  catch (e) { console.error(`known-findings.sh: ledger not readable (${LEDGER}): ${e.message} — ledger evidence left unchanged`); }
  if (malformed) console.error(`known-findings.sh: ${malformed} malformed ledger row(s) skipped (${LEDGER}); aggregates cover the parseable rows`);
  const key = (h, id) => `${(h || "").slice(0, 7)}|${id}`;
  const first = {}, verdict = {};
  for (const r of rows) {
    if (r.kind === "finding") { const k = key(r.head, r.finding_id); if (!first[k]) first[k] = r; if (r.verdict) verdict[k] = r.verdict; else if (!(k in verdict)) verdict[k] = ""; }
    else if (r.kind === "amend" && r.set && r.set.verdict) { const k = key(r.target_head, r.finding_id); if (k in verdict) verdict[k] = r.set.verdict; }
  }
  // HIMMEL-2078: first[k] already carries the new optional .text field on
  // each finding row (the panel one-line prose claim) untouched -- this loop
  // just never projects it into agg / the written catalog, which only
  // tracks per-class COUNTS, not individual findings. Surfacing text for
  // unadjudicated findings here (e.g. agg.unadjudicated_examples) would be
  // a real improvement but is a wider change than this fix; left as a
  // follow-up.
  for (const c of (ledgerOk ? classes : [])) {
    const agg = { findings: 0, agreed: 0, disproved: 0, deferred: 0, other: 0, unadjudicated: 0, models: {} };
    for (const k of Object.keys(first)) { const r = first[k]; if (!r.file || !matchesAny(c.globs, r.file)) continue;
      agg.findings++; const v = verdict[k]; if (!v) agg.unadjudicated++; else if (v === "agreed" || v === "confirmed") agg.agreed++; else if (v === "disproved") agg.disproved++; else if (v === "deferred") agg.deferred++; else agg.other++;
      agg.models[r.model] = (agg.models[r.model] || 0) + 1; }
    const adj = agg.agreed + agg.disproved + agg.deferred + agg.other;
    agg.disproved_pct = adj ? Math.round(100 * agg.disproved / adj) : null;
    c.evidence = c.evidence || {}; c.evidence.ledger = agg;
  }
  // 2) learnings export (CodeRabbit CSV): attribute rows to classes by learning_match; report the unmatched top-10.
  let unmatched = [];
  if (process.env.LEARNINGS) {
    const csv = fs.readFileSync(process.env.LEARNINGS, "utf8");
    const recs = []; let f = "", row = [], q = false; // RFC-4180 state machine (quotes, doubled quotes, embedded newlines)
    for (let i = 0; i < csv.length; i++) { const ch = csv[i];
      if (q) { if (ch === "\"") { if (csv[i + 1] === "\"") { f += "\""; i++; } else q = false; } else f += ch; }
      else if (ch === "\"") q = true; else if (ch === ",") { row.push(f); f = ""; }
      else if (ch === "\n" || ch === "\r") { if (ch === "\r" && csv[i + 1] === "\n") i++; row.push(f); f = ""; if (row.some(x => x !== "")) recs.push(row); row = []; }
      else f += ch; }
    if (f !== "" || row.length) { row.push(f); recs.push(row); }
    const hdr = recs.shift() || []; const col = (n) => hdr.indexOf(n);
    const iL = col("Learning"), iU = col("Usage"), iR = col("Repository"), iF = col("File");
    if (iL < 0 || iU < 0) { console.error("known-findings.sh: learnings csv lacks Learning/Usage columns"); process.exit(2); }
    for (const c of classes) { c.evidence = c.evidence || {}; c.evidence.learnings_uses = 0; c.evidence.learnings_rows = 0; }
    for (const r of recs) { const text = r[iL] || "", uses = parseInt(r[iU] || "0", 10) || 0; let hit = false;
      for (const c of classes) { if (!c.learning_match) continue; if (new RegExp(c.learning_match, "i").test(text)) { c.evidence.learnings_uses += uses; c.evidence.learnings_rows++; hit = true; } }
      // printable-only: the export is untrusted input, so no control chars / ANSI reach the terminal (r12 codex-3)
      const clean = (s) => String(s || "").replace(/[\x00-\x1f\x7f]/g, " ");
      if (!hit) unmatched.push({ uses, repo: clean(r[iR]), file: clean(r[iF]), text: clean(text.slice(0, 160)) }); }
    unmatched.sort((a, b) => b.uses - a.uses);
    db.learnings_export = { rows: recs.length, total_uses: recs.reduce((s, r) => s + (parseInt(r[iU] || "0", 10) || 0), 0), unmatched_rows: unmatched.length };
  }
  // refreshed_at advances only when something WAS refreshed; an unreadable
  // ledger with no export leaves the file untouched (r11 codex-2).
  if (!ledgerOk && !process.env.LEARNINGS) { console.error("known-findings.sh: nothing refreshed — catalogue left unchanged"); process.exit(0); }
  db.refreshed_at = new Date().toISOString().slice(0, 10);
  // tmp + rename so an interrupted refresh never leaves the versioned JSON truncated (r7 codex-4).
  const tmpKF = KF + ".tmp." + process.pid;
  fs.writeFileSync(tmpKF, JSON.stringify(db, null, 2) + "\n");
  fs.renameSync(tmpKF, KF);
  console.log(`known-findings: refreshed ${classes.length} classes → ${KF}`);
  for (const c of classes) { const l = c.evidence.ledger || {}; console.log(`  ${c.id}: ledger findings=${l.findings} agreed=${l.agreed} disproved=${l.disproved} (${l.disproved_pct == null ? "-" : l.disproved_pct + "%"}) deferred=${l.deferred} unadjudicated=${l.unadjudicated}` + (process.env.LEARNINGS ? ` | learnings rows=${c.evidence.learnings_rows} uses=${c.evidence.learnings_uses}` : "")); }
  if (process.env.LEARNINGS) { console.log(`\nlearnings export: ${db.learnings_export.rows} rows, ${db.learnings_export.total_uses} uses, ${unmatched.length} rows matched no class. Top unmatched (new class candidates):`);
    for (const u of unmatched.slice(0, 10)) console.log(`  ${u.uses}\t${u.repo}\t${u.file}\t${u.text}`); }
  process.exit(0);
}
'
