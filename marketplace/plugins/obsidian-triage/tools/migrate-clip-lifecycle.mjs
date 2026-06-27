#!/usr/bin/env node
/**
 * migrate-clip-lifecycle.mjs — one-time, deterministic, reversible, resumable
 * migration engine (LUNA-86).
 *
 * Backfills the historical top-level `processed: true` clips out of the
 * Clippings/ inbox into the flat evidence pool Clippings/_evidence/, stamping
 * `evidence_kind:` and rewriting every inbound wikilink so nothing dangles.
 *
 * This is the engine ONLY. It does NOT run the live migration on the real
 * vault — the operator runbook (commands/migrate-clip-lifecycle.md) drives it
 * behind a mandatory staging gate. Run live only after the staging gate proves
 * (a) zero danglers (incl. `.md`-form) and (b) a byte-identical rollback.
 *
 * Modes:
 *   node migrate-clip-lifecycle.mjs <vault> --dry-run   [--month YYYY-MM] [--manifest <path>]
 *   node migrate-clip-lifecycle.mjs <vault> --apply      [--month YYYY-MM] [--manifest <path>]
 *   node migrate-clip-lifecycle.mjs <vault> --rollback <manifest.json>
 *
 * Hard invariants:
 *   - SIX literal boundary forms per clip (3 plain + 3 `.md`); fixed-string
 *     matching only, NEVER regex/sed (clip ids contain + ( . space en-dash).
 *   - apply → rollback restores the working tree BYTE-FOR-BYTE: the move, all
 *     six-form link rewrites, AND the evidence_kind insertion each reverse
 *     exactly. Reversal is by replaying the recorded manifest edits inversely.
 *   - Resumable + folder-keyed + idempotent: a clip already in _evidence/ is
 *     skipped; a second --apply is a no-op; --dry-run mutates nothing.
 *   - Eligible = top-level (depth 1–2) `processed: true` clips ONLY. Never
 *     touch _evidence/ / _done/ / _synthesis/ / _deferred.md / unprocessed.
 *
 * Dependency-light: pure node + ./lib/evidence-kind.mjs. No npm deps.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { inferEvidenceKind } from "./lib/evidence-kind.mjs";

const SELF = path.basename(fileURLToPath(import.meta.url));

// ── tiny stderr/stdout helpers ───────────────────────────────────────────────
const out = (s) => process.stdout.write(s + "\n");
const err = (s) => process.stderr.write(s + "\n");
function die(code, msg) { err(`${SELF}: ${msg}`); process.exit(code); }

// ── arg parsing ──────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = { mode: null, vault: null, month: null, manifest: null, rollbackPath: null };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--dry-run")       a.mode = "dry-run";
    else if (t === "--apply")    a.mode = "apply";
    else if (t === "--rollback") { a.mode = "rollback"; a.rollbackPath = argv[++i]; }
    else if (t === "--month")    a.month = argv[++i];
    else if (t === "--manifest") a.manifest = argv[++i];
    else rest.push(t);
  }
  if (rest.length) a.vault = rest[0];
  return a;
}

// ── filesystem walk (dependency-light) ───────────────────────────────────────
function walkMd(dir, acc) {
  let entries;
  // Log loudly on a readdir failure (EACCES/EIO/ENOENT race): a silently
  // swallowed error shrinks BOTH the inbound-enumerate scan and the
  // post-rewrite verify scan identically, so verify would falsely report
  // clean while inbound links go un-rewritten. The operator MUST see the
  // reduced scan scope. Non-fatal: a partial walk is better than a crash.
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); }
  catch (e) { err(`${SELF}: walkMd: cannot read ${dir}: ${e.message} — scan scope reduced`); return acc; }
  for (const e of entries) {
    // Skip non-content trees: .git; the vault's nested git worktrees (the
    // luna vault gitignores `/.worktrees/` — stale duplicate checkouts, NOT
    // vault content, and rewriting their links would dirty the operator's
    // active worktrees); and Obsidian state (holds no clip wikilinks).
    if (e.name === ".git" || e.name === ".worktrees" || e.name === ".obsidian") continue;
    const full = path.join(dir, e.name);
    if (e.isDirectory()) walkMd(full, acc);
    else if (e.isFile() && e.name.endsWith(".md")) acc.push(full);
  }
  return acc;
}

// Forward-slash path relative to vault root (manifest is portable + stable).
function relForward(vault, abs) {
  return path.relative(vault, abs).split(path.sep).join("/");
}

// ── frontmatter (line-based, byte-preserving) ────────────────────────────────
// split('\n') / join('\n') is lossless for any content (LF or CRLF: CRLF lines
// keep a trailing '\r'). We never normalise — insertion/removal is exact.
function splitLines(content) { return content.split("\n"); }

function frontmatterBounds(lines) {
  // Opening fence must be the very first line.
  if (lines.length === 0) return null;
  if (stripCR(lines[0]) !== "---") return null;
  for (let i = 1; i < lines.length; i++) {
    if (stripCR(lines[i]) === "---") return { open: 0, close: i };
  }
  return null;
}

function stripCR(s) { return s.endsWith("\r") ? s.slice(0, -1) : s; }

// Read a scalar frontmatter value (`key: value`). Returns "" if absent.
function fmScalar(lines, close, key) {
  for (let i = 1; i < close; i++) {
    const line = stripCR(lines[i]);
    const m = matchKey(line, key);
    if (m !== null) return m.trim();
  }
  return "";
}

// Match `key:` at zero indent; return the value portion or null.
function matchKey(line, key) {
  const prefix = key + ":";
  if (!line.startsWith(prefix)) return null;
  return line.slice(prefix.length);
}

// Read a list-valued frontmatter key: inline `[a, b]` OR block `- a` lines.
function fmList(lines, close, key) {
  for (let i = 1; i < close; i++) {
    const line = stripCR(lines[i]);
    const v = matchKey(line, key);
    if (v === null) continue;
    const inline = v.trim();
    if (inline.startsWith("[") && inline.endsWith("]")) {
      return inline.slice(1, -1).split(",").map(unquote).filter((s) => s.length);
    }
    // block list: following indented `- item` lines
    const items = [];
    for (let j = i + 1; j < close; j++) {
      const sub = stripCR(lines[j]);
      const t = sub.trim();
      if (t.startsWith("- ")) items.push(unquote(t.slice(2)));
      else if (t.startsWith("-")) items.push(unquote(t.slice(1)));
      else if (t === "") continue;
      else break; // next key
    }
    return items;
  }
  return [];
}

function unquote(s) {
  let t = s.trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    t = t.slice(1, -1);
  }
  return t.trim();
}

function hasKey(lines, close, key) {
  for (let i = 1; i < close; i++) {
    if (matchKey(stripCR(lines[i]), key) !== null) return true;
  }
  return false;
}

// ── eligibility ──────────────────────────────────────────────────────────────
// Excluded folder names under Clippings/ (never source clips).
const EXCLUDED_DIRS = new Set(["_evidence", "_done", "_synthesis"]);

function isEligibleClip(vault, abs) {
  const rel = relForward(vault, abs); // e.g. Clippings/foo.md or Clippings/2026-06/foo.md
  const parts = rel.split("/");
  if (parts[0] !== "Clippings") return false;
  // depth 1–2 under Clippings: Clippings/<file> or Clippings/<sub>/<file>
  if (parts.length < 2 || parts.length > 3) return false;
  if (parts[parts.length - 1] === "_deferred.md") return false;
  for (let i = 1; i < parts.length - 1; i++) {
    if (EXCLUDED_DIRS.has(parts[i])) return false;
  }
  const content = fs.readFileSync(abs, "utf8");
  const lines = splitLines(content);
  const b = frontmatterBounds(lines);
  if (!b) return false;
  const processed = fmScalar(lines, b.close, "processed").toLowerCase();
  return processed === "true";
}

// Clip identifier relative to Clippings/, without `.md` (the wikilink `<OLD>`).
function clipOldId(vault, abs) {
  const rel = relForward(vault, abs);          // Clippings/<...>.md
  return rel.replace(/^Clippings\//, "").replace(/\.md$/, "");
}

function monthOf(lines, close, absMtimeMs) {
  const dc = fmScalar(lines, close, "date_clipped") || fmScalar(lines, close, "harvested_at");
  if (dc && /^\d{4}-\d{2}/.test(dc)) return dc.slice(0, 7);
  const d = new Date(absMtimeMs);
  const mm = String(d.getMonth() + 1).padStart(2, "0");
  return `${d.getFullYear()}-${mm}`;
}

// ── six literal boundary forms ───────────────────────────────────────────────
// Returns [[oldForm, newForm], …] for the six forms, in a FIXED order. Apply
// replaces oldForm→newForm; rollback replaces newForm→oldForm (reverse order).
function sixForms(oldId, newId) {
  const o = (suffix) => `[[Clippings/${oldId}${suffix}`;
  const n = (suffix) => `[[Clippings/${newId}${suffix}`;
  return [
    [o("]]"),    n("]]")],
    [o("|"),     n("|")],
    [o("#"),     n("#")],
    [o(".md]]"), n(".md]]")],
    [o(".md|"),  n(".md|")],
    [o(".md#"),  n(".md#")],
  ];
}

// Literal (fixed-string) global replace. NEVER regex.
function literalReplaceAll(haystack, needle, repl) {
  return haystack.split(needle).join(repl);
}

// Apply the six forms forward; return { content, edits } where edits is the
// ordered list of [oldForm,newForm] actually applied (only forms present).
function applySixForms(content, forms) {
  let c = content;
  const edits = [];
  for (const [o, nw] of forms) {
    if (c.includes(o)) {
      c = literalReplaceAll(c, o, nw);
      edits.push([o, nw]);
    }
  }
  return { content: c, edits };
}

// Reverse a recorded edit list (newForm→oldForm), in reverse order.
function reverseEdits(content, edits) {
  let c = content;
  for (let i = edits.length - 1; i >= 0; i--) {
    const [o, nw] = edits[i];
    c = literalReplaceAll(c, nw, o);
  }
  return c;
}

// Replay a recorded edit list FORWARD (oldForm→newForm), in order. Inverse of
// reverseEdits; used to re-apply a clip's forward edits when a half-completed
// rollback must be returned to the fully-applied state.
function replayEdits(content, edits) {
  let c = content;
  for (const [o, nw] of edits) c = literalReplaceAll(c, o, nw);
  return c;
}

// Count total occurrences of any of the six forms (for the dry-run report).
function countOccurrences(content, forms) {
  let total = 0;
  for (const [o] of forms) total += content.split(o).length - 1;
  return total;
}

// ── evidence_kind insertion (exactly reversible) ─────────────────────────────
// Build the block-list lines to insert (matching the steady-state Phase-8
// format). Honour CRLF if the file uses it so the file stays uniform.
function evidenceKindLines(kinds, crlf) {
  const eol = crlf ? "\r" : "";
  const lines = [`evidence_kind:${eol}`];
  for (const k of kinds) lines.push(`  - ${k}${eol}`);
  return lines;
}

function inferKindsFor(lines, close) {
  const type = fmScalar(lines, close, "type");
  const url  = fmScalar(lines, close, "harvest_url_canonical") || fmScalar(lines, close, "source");
  const tags = fmList(lines, close, "tags");
  return inferEvidenceKind({ type, url, tags });
}

// ── manifest ─────────────────────────────────────────────────────────────────
function loadManifest(p) {
  if (p && fs.existsSync(p)) {
    // A PRESENT-but-corrupt manifest must FAIL LOUD, never fall through to an
    // empty manifest: a silent empty would make `--rollback <corrupt>` report
    // "0 reverted" exit 0 (operator believes rollback succeeded when it did
    // nothing) and a re-`--apply` would lose the prior session's rollback
    // ability. Only the legitimate "no file yet" path returns the empty manifest.
    let raw;
    try { raw = fs.readFileSync(p, "utf8"); }
    catch (e) { die(1, `cannot read manifest ${p}: ${e.message} — inspect/repair/delete it before retrying`); }
    try { return JSON.parse(raw); }
    catch (e) { die(1, `manifest ${p} is present but unparseable (${e.message}) — inspect/repair/delete it before retrying (refusing to continue with an empty manifest)`); }
  }
  return { version: 1, vault: null, clips: [] };
}

function saveManifest(p, manifest) {
  fs.writeFileSync(p, JSON.stringify(manifest, null, 2) + "\n");
}

function defaultManifestPath(vault) {
  return path.join(vault, ".migrate-clip-lifecycle.manifest.json");
}

function ledgerPath(vault) {
  return path.join(vault, ".migrate-clip-lifecycle.ledger.jsonl");
}

// ── per-clip apply transaction ───────────────────────────────────────────────
// Returns a manifest record for the migrated clip, or throws on failure (the
// caller reverts the partial transaction).
// `journal` (optional, mutated in place) records enough of the in-flight
// transaction for the caller to reverse a partial failure: the clip's
// pre-clip bytes, whether the file was moved, and every inbound link edit
// actually written. On success it is ignored (rollback uses the manifest).
function migrateClip(vault, clipAbs, journal) {
  const oldId = clipOldId(vault, clipAbs);          // e.g. 2026-06/foo or @karpathy – …
  const base = path.basename(oldId);                // flat pool basename
  const newId = `_evidence/${base}`;                // wikilink target after move
  const newAbs = path.join(vault, "Clippings", "_evidence", `${base}.md`);
  const newRel = relForward(vault, newAbs);
  const oldRel = relForward(vault, clipAbs);

  if (fs.existsSync(newAbs)) {
    throw new Error(`dest exists: Clippings/_evidence/${base}.md`);
  }

  const original = fs.readFileSync(clipAbs, "utf8");
  if (journal) journal.original = original;
  const lines = splitLines(original);
  const b = frontmatterBounds(lines);
  if (!b) throw new Error("no frontmatter");

  // 1. evidence_kind insertion (skip if already present — never double-insert).
  let fmRecord = null;
  let c1 = original;
  if (!hasKey(lines, b.close, "evidence_kind")) {
    const kinds = inferKindsFor(lines, b.close);
    const crlf = lines[0].endsWith("\r");
    const insLines = evidenceKindLines(kinds, crlf);
    const newLines = lines.slice(0, b.close).concat(insLines, lines.slice(b.close));
    c1 = newLines.join("\n");
    fmRecord = { file: newRel, index: b.close, lines: insLines };
  }

  // 2. ensure the pool dir exists.
  fs.mkdirSync(path.join(vault, "Clippings", "_evidence"), { recursive: true });

  // 3. enumerate inbound files (six forms) BEFORE the move — includes self-ref.
  const forms = sixForms(oldId, newId);
  const allMd = walkMd(vault, []);
  const inbound = [];
  for (const f of allMd) {
    const fc = (f === clipAbs) ? c1 : fs.readFileSync(f, "utf8");
    if (forms.some(([o]) => fc.includes(o))) inbound.push(f);
  }

  // 4. move the clip (mv via rename; never delete+recreate).
  fs.renameSync(clipAbs, newAbs);
  if (journal) journal.moved = true;

  // 5. rewrite inbound links — literal only. Clip self-ref happens at NEW path.
  const linkRecords = [];
  for (const f of inbound) {
    const isSelf = (f === clipAbs);
    const target = isSelf ? newAbs : f;
    const baseContent = isSelf ? c1 : fs.readFileSync(target, "utf8");
    const { content, edits } = applySixForms(baseContent, forms);
    if (edits.length) {
      fs.writeFileSync(target, content);
      linkRecords.push({ file: relForward(vault, target), edits });
      if (journal) journal.links.push({ fAbs: target, edits, isSelf });
    } else if (isSelf) {
      // self file had the frontmatter insertion but no link → still must persist c1.
      fs.writeFileSync(target, content);
    }
  }
  // If the self clip was NOT among inbound (no self-ref) but has a frontmatter
  // insertion, persist c1 at the new path (rename moved `original`).
  if (fmRecord && !inbound.includes(clipAbs)) {
    fs.writeFileSync(newAbs, c1);
  }

  // 6. verify: zero stale OLD six-form links across the vault.
  const stale = [];
  for (const f of walkMd(vault, [])) {
    const fc = fs.readFileSync(f, "utf8");
    if (forms.some(([o]) => fc.includes(o))) stale.push(relForward(vault, f));
  }
  if (stale.length) throw new Error(`stale links after rewrite: ${stale.join(", ")}`);

  return { oldRel, newRel, oldId, newId, move: { from: oldRel, to: newRel }, frontmatter: fmRecord, links: linkRecords };
}

// Reverse a PARTIAL (failed mid-flight) clip transaction from its journal so a
// failed clip leaves the vault in its pre-clip state — no torn links. Reverses
// the inbound link edits actually applied (inverse literal replace), then
// restores the clip file's pre-clip bytes and moves it back to the inbox. The
// self clip's own edits are subsumed by restoring its original bytes, so they
// are skipped in the link loop. Returns true if the vault was fully restored,
// false if any step could not complete (caller must warn: manual repair needed).
function revertClipJournal(vault, clipAbs, base, journal) {
  let clean = true;
  const newAbs = path.join(vault, "Clippings", "_evidence", `${base}.md`);
  // 1. reverse applied link edits on NON-self inbound files (newest first).
  for (let i = journal.links.length - 1; i >= 0; i--) {
    const { fAbs, edits, isSelf } = journal.links[i];
    if (isSelf) continue;
    try {
      const content = fs.readFileSync(fAbs, "utf8");
      fs.writeFileSync(fAbs, reverseEdits(content, edits));
    } catch { clean = false; }
  }
  // 2. restore the clip's pre-clip bytes (undoes both the self-ref rewrite and
  //    the evidence_kind insertion) and move it back to the inbox.
  if (journal.moved && journal.original !== null) {
    try {
      fs.writeFileSync(newAbs, journal.original);
      fs.renameSync(newAbs, clipAbs);
    } catch { clean = false; }
  } else if (fs.existsSync(newAbs) && !fs.existsSync(clipAbs)) {
    // Defensive: file half-moved but original not captured — move it back.
    try { fs.renameSync(newAbs, clipAbs); } catch { clean = false; }
  }
  return clean;
}

// Revert an in-flight (partial) transaction is handled by re-running rollback
// on the single record. For a fully-recorded clip we use rollbackClip.
function rollbackClip(vault, rec) {
  const fromAbs = path.join(vault, rec.move.to.split("/").join(path.sep));   // currently at NEW
  const toAbs   = path.join(vault, rec.move.from.split("/").join(path.sep)); // restore to OLD

  // 1. reverse link rewrites (clip self-ref file is rec.newRel — still at NEW).
  for (let i = rec.links.length - 1; i >= 0; i--) {
    const lr = rec.links[i];
    const fAbs = path.join(vault, lr.file.split("/").join(path.sep));
    const content = fs.readFileSync(fAbs, "utf8");
    fs.writeFileSync(fAbs, reverseEdits(content, lr.edits));
  }

  // Steps 2–3 can fail when the clip was edited AFTER apply (the frontmatter
  // reversal check below). If we left things here, links would be reversed (old
  // inbox form) while the file is still at _evidence/ — a torn half-revert. On
  // any step-2/3 failure, re-apply the step-1 forward link edits so the clip is
  // left FULLY in the applied state (links→_evidence, file at _evidence —
  // self-consistent), and tell the operator it needs a manual rollback. Rollback
  // is therefore NOT idempotent against an externally-modified clip.
  try {
    // 2. reverse the evidence_kind insertion at the NEW path (clip still there).
    if (rec.frontmatter) {
      const content = fs.readFileSync(fromAbs, "utf8");
      const lines = splitLines(content);
      const { index, lines: ins } = rec.frontmatter;
      // Verify the inserted lines are exactly where we put them, then splice out.
      const slice = lines.slice(index, index + ins.length);
      if (slice.length !== ins.length || slice.some((l, k) => l !== ins[k])) {
        throw new Error(`frontmatter reversal mismatch at ${rec.newRel}`);
      }
      const restored = lines.slice(0, index).concat(lines.slice(index + ins.length));
      fs.writeFileSync(fromAbs, restored.join("\n"));
    }

    // 3. move the clip back to its original path.
    fs.mkdirSync(path.dirname(toAbs), { recursive: true });
    fs.renameSync(fromAbs, toAbs);
  } catch (e) {
    for (const lr of rec.links) {
      try {
        const fAbs = path.join(vault, lr.file.split("/").join(path.sep));
        const content = fs.readFileSync(fAbs, "utf8");
        fs.writeFileSync(fAbs, replayEdits(content, lr.edits));
      } catch { /* best effort — operator will repair manually */ }
    }
    throw new Error(`${e.message} — clip left fully in the applied state (forward link edits re-applied); roll back this clip manually`);
  }
}

// ── basename-collision pre-detection ─────────────────────────────────────────
// The pool is FLAT and keyed on `path.basename`, so two eligible clips with the
// same basename in different folders/months both target the same
// Clippings/_evidence/<base>.md. Surface this BEFORE any move so the operator
// resolves it rather than hitting a mid-live-run failure.
// Returns Map<targetRel, srcRel[]> for every basename claimed by >1 clip.
const EXIT_COLLISION = 3;
function basenameCollisions(vault, eligible) {
  const byTarget = new Map();
  for (const abs of eligible) {
    const base = path.basename(clipOldId(vault, abs));
    const target = `Clippings/_evidence/${base}.md`;
    const arr = byTarget.get(target) || [];
    arr.push(relForward(vault, abs));
    byTarget.set(target, arr);
  }
  const col = new Map();
  for (const [t, srcs] of byTarget) if (srcs.length > 1) col.set(t, srcs);
  return col;
}

// ── modes ────────────────────────────────────────────────────────────────────
function collectEligible(vault, month) {
  const clipsDir = path.join(vault, "Clippings");
  if (!fs.existsSync(clipsDir)) return [];
  const all = walkMd(clipsDir, []);
  const eligible = [];
  for (const abs of all) {
    if (!isEligibleClip(vault, abs)) continue;
    if (month) {
      const lines = splitLines(fs.readFileSync(abs, "utf8"));
      const b = frontmatterBounds(lines);
      // Re-read race: the file lost its frontmatter between isEligibleClip and
      // here. Skip it loudly rather than crash on b.close (TypeError).
      if (!b) {
        err(`${SELF}: skipping ${relForward(vault, abs)} — frontmatter vanished between reads (file changed mid-scan)`);
        continue;
      }
      const m = monthOf(lines, b.close, fs.statSync(abs).mtimeMs);
      if (m !== month) continue;
    }
    eligible.push(abs);
  }
  // Deterministic order: by forward-relative path.
  eligible.sort((a, z) => relForward(vault, a).localeCompare(relForward(vault, z)));
  return eligible;
}

function runDryRun(vault, month, manifestPath) {
  const eligible = collectEligible(vault, month);
  const manifest = { version: 1, vault: relForward(vault, vault) || ".", dryRun: true, clips: [] };
  let totalLinks = 0;
  for (const abs of eligible) {
    const oldId = clipOldId(vault, abs);
    const base = path.basename(oldId);
    const newId = `_evidence/${base}`;
    const original = fs.readFileSync(abs, "utf8");
    const lines = splitLines(original);
    const b = frontmatterBounds(lines);
    const kinds = (b && !hasKey(lines, b.close, "evidence_kind")) ? inferKindsFor(lines, b.close) : [];
    const forms = sixForms(oldId, newId);
    let occ = 0;
    for (const f of walkMd(vault, [])) occ += countOccurrences(fs.readFileSync(f, "utf8"), forms);
    totalLinks += occ;
    out(`PLAN ${oldId} → _evidence/${base}  evidence_kind=[${kinds.join(",")}]  inbound=${occ}`);
    manifest.clips.push({ oldId, newId, evidence_kind: kinds, inbound: occ });
  }
  // Pre-detect flat-pool basename collisions — name BOTH colliding sources.
  const collisions = basenameCollisions(vault, eligible);
  for (const [target, srcs] of collisions) {
    out(`COLLISION: ${srcs.length} eligible clips target ${target} — sources: ${srcs.join("  |  ")}`);
  }
  manifest.collisions = Array.from(collisions, ([target, sources]) => ({ target, sources }));
  if (manifestPath) saveManifest(manifestPath, manifest);
  out(`${SELF}: DRY-RUN — ${eligible.length} eligible, ${totalLinks} inbound link occurrences, ${collisions.size} basename collision(s), 0 migrated (no writes).`);
  if (collisions.size > 0) {
    err(`${SELF}: ${collisions.size} basename collision(s) — resolve before --apply (advisory exit ${EXIT_COLLISION}).`);
    process.exit(EXIT_COLLISION);
  }
}

function runApply(vault, month, manifestPath) {
  const mp = manifestPath || defaultManifestPath(vault);
  let manifest = loadManifest(mp);
  // A dry-run plan manifest records no real moves — never resume from it; an
  // apply at the same path starts a fresh authoritative manifest.
  if (manifest.dryRun || manifest.clips.some((c) => !c.move)) {
    manifest = { version: 1, vault: null, clips: [] };
  }
  manifest.vault = relForward(vault, vault) || ".";
  // target → source map from prior batches (cross-month resume / collision check).
  const doneFrom = new Map();
  for (const c of manifest.clips) if (c.move) doneFrom.set(c.move.to, c.move.from);

  const eligible = collectEligible(vault, month);
  // Intra-batch basename collisions: refuse ALL colliding clips (no partial).
  const collisionMap = basenameCollisions(vault, eligible);
  const collidingSrc = new Set();
  for (const srcs of collisionMap.values()) for (const s of srcs) collidingSrc.add(s);

  let migrated = 0, skipped = 0, collided = 0, failed = 0;
  const lp = ledgerPath(vault);

  for (const abs of eligible) {
    const oldId = clipOldId(vault, abs);
    const oldRel = relForward(vault, abs);
    const base = path.basename(oldId);
    const newRel = `Clippings/_evidence/${base}.md`;
    const targetAbs = path.join(vault, "Clippings", "_evidence", `${base}.md`);
    // Fail safe: a basename shared within this batch, OR a pool target already
    // occupied by a DIFFERENT clip (e.g. a prior month-batch). Never overwrite,
    // never silently drop — refuse and let the operator rename the source.
    if (collidingSrc.has(oldRel) || (fs.existsSync(targetAbs) && doneFrom.get(newRel) !== oldRel)) {
      err(`✗ COLLISION: ${oldRel} → ${newRel} (basename already targeted/occupied); not migrated. Resolve basename before live run.`);
      collided++;
      continue;
    }
    const journal = { original: null, moved: false, links: [] };
    try {
      const rec = migrateClip(vault, abs, journal);
      manifest.clips.push(rec);
      doneFrom.set(rec.move.to, rec.move.from);
      saveManifest(mp, manifest);   // checkpoint after every clip (resumable)
      fs.appendFileSync(lp, JSON.stringify({
        clip: rec.move.from, dest: rec.move.to,
        evidence_kind: rec.frontmatter ? rec.frontmatter.lines.filter((l) => stripCR(l).startsWith("  - ")).map((l) => stripCR(l).slice(4)) : [],
        links_rewritten: rec.links.reduce((s, r) => s + r.edits.length, 0),
        ended_at: new Date().toISOString(),
      }) + "\n");
      out(`✓ ${oldId} → _evidence/${base}, ${rec.links.reduce((s, r) => s + r.edits.length, 0)} link forms rewritten`);
      migrated++;
    } catch (e) {
      // Reverse the partial transaction: undo any inbound link edits already
      // applied AND move the clip back, so a failed clip leaves no torn vault.
      const restored = revertClipJournal(vault, abs, base, journal);
      if (restored) {
        err(`✗ ${oldId} — failed: ${e.message}; reverted (vault restored to pre-clip state)`);
      } else {
        // Do NOT claim "reverted" — be honest that manual repair is needed.
        err(`✗ ${oldId} — failed: ${e.message}; PARTIAL REVERT — clip may be left at Clippings/_evidence/${base}.md with link edits; MANUAL REPAIR NEEDED`);
      }
      failed++;
    }
  }
  out(`${SELF}: ${migrated} migrated, ${skipped} skipped, ${collided} collisions, ${failed} failed.`);
  if (collided > 0) process.exit(EXIT_COLLISION);
  if (failed > 0) process.exit(4);
}

function runRollback(vault, rollbackPath) {
  if (!rollbackPath || !fs.existsSync(rollbackPath)) {
    die(1, `--rollback needs a manifest path (got: ${rollbackPath || "<none>"})`);
  }
  const manifest = loadManifest(rollbackPath);
  if (!manifest.clips || !manifest.clips.length) {
    out(`${SELF}: manifest has no migrated clips — nothing to roll back.`);
    return;
  }
  if (manifest.dryRun) die(1, "refusing to roll back a DRY-RUN manifest (it records no real moves)");
  let reverted = 0, failed = 0;
  // Reverse order: last-migrated clip first (inverse of apply order).
  for (let i = manifest.clips.length - 1; i >= 0; i--) {
    const rec = manifest.clips[i];
    if (!rec.move) continue;
    try {
      rollbackClip(vault, rec);
      out(`↩ ${rec.move.to} → ${rec.move.from}`);
      reverted++;
    } catch (e) {
      err(`✗ rollback failed for ${rec.move && rec.move.to}: ${e.message}`);
      failed++;
    }
  }
  out(`${SELF}: ${reverted} reverted, ${failed} failed.`);
  if (failed > 0) process.exit(4);
}

// ── main ─────────────────────────────────────────────────────────────────────
function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.mode) die(1, "usage: <vault> (--dry-run | --apply [--month YYYY-MM] | --rollback <manifest.json>) [--manifest <path>]");
  if (!a.vault) die(1, "missing <vault> path");
  if (!fs.existsSync(a.vault) || !fs.statSync(a.vault).isDirectory()) die(2, `vault not found: ${a.vault}`);
  const vault = path.resolve(a.vault);

  if (a.month && !/^\d{4}-\d{2}$/.test(a.month)) die(1, `--month must be YYYY-MM (got: ${a.month})`);

  if (a.mode === "dry-run")      runDryRun(vault, a.month, a.manifest);
  else if (a.mode === "apply")   runApply(vault, a.month, a.manifest);
  else if (a.mode === "rollback") runRollback(vault, a.rollbackPath);
}

main();
