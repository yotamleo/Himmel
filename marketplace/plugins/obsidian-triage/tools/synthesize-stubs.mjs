#!/usr/bin/env node
/**
 * synthesize-stubs.mjs — SYNTHESIZE stub mode (LUNA-87): the generative path
 * that compounds the evidence pool into early subject stubs.
 *
 * SEPARATE from the existing `_synthesis/` proposal path (synthesize-clips.md)
 * — that path stays for STRUCTURAL proposals; this one auto-creates real,
 * reversible `status: stub` subject pages.
 *
 *   node synthesize-stubs.mjs <vault> [--dry-run]   (default: dry-run, writes nothing)
 *   node synthesize-stubs.mjs <vault> --apply        create stubs + stamp + ledger
 *   node synthesize-stubs.mjs <vault> --revert <ledger.jsonl>   divergence-guarded undo
 *
 * Reversibility (handover HARD GUARDRAIL #1): every created page is recorded in
 * a generation-ledger with its sha256. `--revert` deletes a generated stub and
 * clears the `promoted_to:` it stamped ONLY when the page is byte-identical to
 * generation. A page the operator has touched (hash diverged) is REFUSED —
 * "delete to undo" is forbidden once a stub is hand-edited/densified.
 *
 * Dependency-light: pure node + ./lib/{frontmatter,stub-synthesis,url-canonical,evidence-kind}.mjs.
 */

import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { canonicalize } from "./lib/url-canonical.mjs";
import {
  parse, fmScalar, fmList, hasKey, insertScalar, removeScalar, sha256, stripCR,
} from "./lib/frontmatter.mjs";
import { planStubs, normalizeName } from "./lib/stub-synthesis.mjs";
import { repoSlugFromCanonical, claimTailSkippedRow } from "./lib/deferred-reconcile.mjs";
import { buildPromotionDigest } from "./lib/telegram-digest.mjs";

const SELF = path.basename(fileURLToPath(import.meta.url));
const out = (s) => process.stdout.write(s + "\n");
const err = (s) => process.stderr.write(s + "\n");
function die(code, msg) { err(`${SELF}: ${msg}`); process.exit(code); }

// ── args ─────────────────────────────────────────────────────────────────────
function parseArgs(argv) {
  const a = { mode: "dry-run", vault: null, ledger: null, revertPath: null, telegramDigest: true };
  const rest = [];
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--dry-run") a.mode = "dry-run";
    else if (t === "--apply") a.mode = "apply";
    else if (t === "--revert") { a.mode = "revert"; a.revertPath = argv[++i]; }
    else if (t === "--ledger") a.ledger = argv[++i];
    // LUNA-91: suppress the telegram promotion digest (e.g. the first big
    // synthesize run after the LUNA-86 migration backfill — design §12.F).
    else if (t === "--no-telegram-digest") a.telegramDigest = false;
    else rest.push(t);
  }
  if (rest.length) a.vault = rest[0];
  return a;
}

function ledgerPathFor(vault, override) {
  return override || path.join(vault, ".synthesize-stubs.ledger.jsonl");
}

function digestPathFor(vault) {
  return path.join(vault, ".synthesize-stubs.telegram-digest.json");
}

// ── clip scan (flat _evidence/, excludes _rejected/) ─────────────────────────
function clipIdOf(rel) {
  return rel.replace(/^Clippings\//, "").replace(/\.md$/, "");
}

function scanEvidence(vault) {
  const dir = path.join(vault, "Clippings", "_evidence");
  if (!fs.existsSync(dir)) return [];
  const clips = [];
  for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
    if (!ent.isFile() || !ent.name.endsWith(".md")) continue; // dirs (e.g. _rejected/) skipped
    const abs = path.join(dir, ent.name);
    const content = fs.readFileSync(abs, "utf8");
    const { lines, bounds } = parse(content);
    if (!bounds) continue;
    const close = bounds.close;
    const rel = `Clippings/_evidence/${ent.name}`;
    const author = fmScalar(lines, close, "author") || (fmList(lines, close, "authors")[0] || "");
    const rawUrl = fmScalar(lines, close, "harvest_url_canonical") || fmScalar(lines, close, "source");
    clips.push({
      abs,
      rel,
      id: clipIdOf(rel),
      base: ent.name.replace(/\.md$/, ""),
      type: fmScalar(lines, close, "type"),
      url: rawUrl,
      canonicalUrl: rawUrl ? (canonicalize(rawUrl) || "") : "",
      author,
      tags: fmList(lines, close, "tags"),
      evidenceKind: fmList(lines, close, "evidence_kind"),
    });
  }
  return clips;
}

// Bounded fuzzy matcher (LUNA-88): scan existing subjects in
// 30-Resources/{Concepts,Tech} + 60-Maps/*-MOC and match by NORMALISED name
// (case/punct-insensitive, `-MOC` suffix stripped) OR a declared `aliases:`
// entry. Bounded — exact normalised equality + operator aliases, never an
// open-ended similarity guess. A match means DENSIFY; no match means CREATE.
function buildSubjectIndex(vault) {
  const folders = ["30-Resources/Concepts", "30-Resources/Tech", "60-Maps"];
  const byKey = new Map(); // normalised key -> { path }
  for (const folder of folders) {
    const dir = path.join(vault, folder);
    if (!fs.existsSync(dir)) continue;
    for (const ent of fs.readdirSync(dir, { withFileTypes: true })) {
      if (!ent.isFile() || !ent.name.endsWith(".md")) continue;
      const rel = `${folder}/${ent.name}`;
      let base = ent.name.replace(/\.md$/, "");
      // 60-Maps MOC pages: drop the -MOC suffix so "Context-Windows-MOC" -> "Context Windows".
      if (folder === "60-Maps") base = base.replace(/-?MOC$/i, "");
      const keys = new Set([normalizeName(base)]);
      const content = fs.readFileSync(path.join(dir, ent.name), "utf8");
      const { lines, bounds } = parse(content);
      if (bounds) {
        for (const a of fmList(lines, bounds.close, "aliases")) keys.add(normalizeName(a));
      }
      for (const k of keys) {
        if (k && !byKey.has(k)) byKey.set(k, { path: rel });
      }
    }
  }
  return byKey;
}

function fuzzyMatcher(vault) {
  const index = buildSubjectIndex(vault);
  return (subjectName /*, target */) => index.get(normalizeName(subjectName)) || null;
}

// ── stub page rendering ──────────────────────────────────────────────────────
function today() { return new Date().toISOString().slice(0, 10); }

function renderStub(subjectName, target, contributors) {
  const isTech = target.kind === "tools";
  const typeLine = isTech ? "type: tech-ingest" : "type: concept";
  const tagLine = isTech ? "  - tech" : "  - concept";
  const firstId = contributors[0].id;
  const fm = [
    "---",
    typeLine,
    "status: stub",
    `date: ${today()}`,
    "tags:",
    tagLine,
    "ai-first: true",
    `derived_from: "[[Clippings/${firstId}]]"`,
    "generated_by: /synthesize-stubs",
    "promoted_from_evidence: true",
    // Tech subjects from github clips queue a one-hop reference crawl (LUNA-89).
    ...(isTech ? ["deepen_pending: true"] : []),
    "---",
  ];
  const body = [
    "",
    `# ${subjectName}`,
    "",
    `> **For future Claude:** stub auto-created from ${contributors.length} evidence clips sharing "${subjectName}". It densifies as more evidence links in; the definition below is a 1-line seed — sharpen it on review.`,
    "",
    "## Definition",
    "",
    "<1-line seed synthesized from the evidence below — sharpen on review.>",
    "",
    `## Evidence (${contributors.length} clips)`,
    "",
    ...contributors.map((c) => `- [[Clippings/${c.id}]] — <why this clip evidences the concept>`),
    "",
    // Reference scaffold for the LUNA-89 deepen pass (filled by /deepen-subject).
    ...(isTech ? [
      "## References",
      "",
      "<!-- deepen: pending — run /deepen-subject to crawl one-hop refs (classify integrate/take-parts/inspire/skip) -->",
      "",
    ] : []),
    "## Related",
    "",
    "- ",
    "",
  ];
  return fm.join("\n") + "\n" + body.join("\n");
}

// ── densify (LUNA-88) ────────────────────────────────────────────────────────
// Append the FRESH contributors (those not already wikilinked) to an existing
// subject's `## Evidence` section — inside the section (before the next `## `
// heading), or a new `## Evidence` section at EOF if none exists. Returns
// { newContent, appended, fresh } or null when there is nothing new to add.
// `appended` is the exact literal block written, so revert removes it verbatim.
function densifyContent(content, contributors) {
  const fresh = contributors.filter((c) => !content.includes(`[[Clippings/${c.id}]]`));
  if (!fresh.length) return null;
  const eol = content.includes("\r\n") ? "\r\n" : "\n";
  const bullets = fresh
    .map((c) => `- [[Clippings/${c.id}]] — <why this clip evidences the concept>`)
    .join(eol) + eol;

  const evIdx = content.indexOf("## Evidence");
  if (evIdx === -1) {
    const sep = content.endsWith(eol) ? "" : eol;
    const appended = `${sep}${eol}## Evidence${eol}${eol}${bullets}`;
    return { newContent: content + appended, appended, fresh };
  }
  // Insert before the next `## ` heading after Evidence (keeps bullets in-section), else EOF.
  const afterEv = evIdx + "## Evidence".length;
  const nextRel = content.slice(afterEv).search(/\n## /);
  let insertPos = nextRel === -1 ? content.length : afterEv + nextRel + 1;
  let appended = bullets;
  if (insertPos === content.length && !content.endsWith(eol)) appended = eol + bullets;
  const newContent = content.slice(0, insertPos) + appended + content.slice(insertPos);
  return { newContent, appended, fresh };
}

// ── apply ────────────────────────────────────────────────────────────────────
function runApply(vault, ledgerPath, dryRun) {
  const clips = scanEvidence(vault);
  const byRel = new Map(clips.map((c) => [c.rel, c]));
  const decisions = planStubs(clips, fuzzyMatcher(vault));

  let created = 0, densified = 0, skipped = 0;
  // LUNA-91: { subject, clipAbs } per contributor NEWLY stamped this run — fed to
  // the telegram promotion digest (filtered to telegram-origin clips in main()).
  const promotions = [];

  for (const d of decisions) {
    if (d.action === "skip") {
      out(`⊘ ${d.conceptKey} — skipped (${d.reason})`);
      skipped++;
      continue;
    }
    if (d.action === "densify") {
      const contributors = d.contributors.map((rel) => byRel.get(rel));
      const subjectRel = d.existingPath;
      const subjectAbs = path.join(vault, subjectRel.split("/").join(path.sep));
      const before = fs.readFileSync(subjectAbs, "utf8");
      const plan = densifyContent(before, contributors);
      if (!plan) { out(`≈ ${subjectRel} — already cites these clips, nothing to densify`); densified++; continue; }

      if (dryRun) {
        out(`≈ would densify ${subjectRel} — +${plan.fresh.length} evidence, concept '${d.conceptKey}'`);
        densified++;
        continue;
      }

      fs.writeFileSync(subjectAbs, plan.newContent);
      const densifyLink = `[[${subjectRel.replace(/\.md$/, "")}]]`;
      const promotedValue = `"${densifyLink}"`;
      const stamped = [];
      for (const c of plan.fresh) {
        const cur = fs.readFileSync(c.abs, "utf8");
        const { lines, bounds } = parse(cur);
        if (bounds && hasKey(lines, bounds.close, "promoted_to")) continue;
        fs.writeFileSync(c.abs, insertScalar(cur, "promoted_to", promotedValue));
        stamped.push(c.rel);
        promotions.push({ subject: densifyLink, clipAbs: c.abs });
      }
      fs.appendFileSync(ledgerPath, JSON.stringify({
        ts: new Date().toISOString(),
        action: "densify",
        subject: subjectRel,
        subject_sha256_before: sha256(before),
        subject_sha256: sha256(plan.newContent),
        appended: plan.appended,
        concept_key: d.conceptKey,
        contributors: plan.fresh.map((c) => c.rel),
        promoted_to_value: `[[${subjectRel.replace(/\.md$/, "")}]]`,
        stamped,
      }) + "\n");
      out(`≈ ${subjectRel} — densified +${plan.fresh.length} evidence, concept '${d.conceptKey}'`);
      // LUNA-89: a github clip newly densified onto a Tech subject is also a
      // promotion → claim its tail-skipped row (same event as the create path).
      if (d.target.kind === "tools") {
        const claimed = claimDeferredRows(vault, plan.fresh, `[[${subjectRel.replace(/\.md$/, "")}]]`, ledgerPath);
        if (claimed) out(`  ↳ claimed ${claimed} _deferred.md tail-skipped row(s) → ${subjectRel}`);
      }
      densified++;
      continue;
    }
    // action === "create"
    const contributors = d.contributors.map((rel) => byRel.get(rel));
    const subjectRel = `${d.target.folder}/${d.subjectName}.md`;
    const subjectAbs = path.join(vault, d.target.folder, `${d.subjectName}.md`);
    const content = renderStub(d.subjectName, d.target, contributors);

    if (dryRun) {
      out(`✓ would create ${subjectRel} — ${contributors.length} contributors, concept '${d.conceptKey}'`);
      created++;
      continue;
    }

    fs.mkdirSync(path.dirname(subjectAbs), { recursive: true });
    fs.writeFileSync(subjectAbs, content);

    // Stamp promoted_to on each contributor (skip if already stamped).
    const stamped = [];
    const createLink = `[[${d.target.folder}/${d.subjectName}]]`;
    const promotedValue = `"${createLink}"`;
    for (const c of contributors) {
      const cur = fs.readFileSync(c.abs, "utf8");
      const { lines, bounds } = parse(cur);
      if (bounds && hasKey(lines, bounds.close, "promoted_to")) continue;
      fs.writeFileSync(c.abs, insertScalar(cur, "promoted_to", promotedValue));
      stamped.push(c.rel);
      promotions.push({ subject: createLink, clipAbs: c.abs });
    }

    // Append the ledger entry per-page (right after the page + stamps land), so
    // a mid-run crash never leaves a created page without a ledger record —
    // every page on disk is revertable.
    fs.appendFileSync(ledgerPath, JSON.stringify({
      ts: new Date().toISOString(),
      action: "stub-create",
      subject: subjectRel,
      subject_sha256: sha256(content),
      concept_key: d.conceptKey,
      contributors: d.contributors,
      promoted_to_value: `[[${d.target.folder}/${d.subjectName}]]`,
      stamped,
    }) + "\n");
    out(`✓ ${subjectRel} — ${contributors.length} contributors, concept '${d.conceptKey}'`);
    created++;

    // LUNA-89: a github clip promoted to a Tech subject claims its tail-skipped
    // _deferred.md backlog row (the one-hop crawl itself is /deepen-subject).
    if (d.target.kind === "tools") {
      const claimed = claimDeferredRows(vault, contributors, `[[${d.target.folder}/${d.subjectName}]]`, ledgerPath);
      if (claimed) out(`  ↳ claimed ${claimed} _deferred.md tail-skipped row(s) → ${subjectRel}`);
    }
  }

  out(`${SELF}: ${created} ${dryRun ? "would-create" : "created"}, ${densified} ${dryRun ? "would-densify" : "densified"}, ${skipped} skipped`);
  return promotions;
}

// ── telegram promotion digest (LUNA-91) ──────────────────────────────────────
// Build the batched digest from THIS run's promotions and persist it to
// <vault>/.synthesize-stubs.telegram-digest.json for the synthesize-stubs
// runbook to send through the telegram bridge `reply` tool (ONE reply per
// originating chat, the live send operator-gated per HARD GUARDRAIL #4). The
// file is rewritten every apply: non-empty → the run's digest; empty (no
// telegram-origin promotions, or a re-run that promoted nothing new) → removed,
// so a stale digest is never re-sent. Suppressed entirely with
// --no-telegram-digest (migration backfill).
function emitTelegramDigest(vault, promotions, suppress) {
  const digestPath = digestPathFor(vault);
  const enriched = (promotions || []).map((p) => {
    let clip = {};
    try {
      const { lines, bounds } = parse(fs.readFileSync(p.clipAbs, "utf8"));
      if (bounds) {
        clip = {
          clipped_via: fmScalar(lines, bounds.close, "clipped_via"),
          telegram_msg_id: fmScalar(lines, bounds.close, "telegram_msg_id"),
          telegram_chat_id: fmScalar(lines, bounds.close, "telegram_chat_id"),
        };
      }
    } catch { /* unreadable clip → contributes nothing to the digest */ }
    return { subject: p.subject, clip };
  });
  const digest = buildPromotionDigest(enriched, { suppress });
  if (digest.length) {
    fs.writeFileSync(digestPath, JSON.stringify({ ts: new Date().toISOString(), replies: digest }, null, 2) + "\n");
    const total = digest.length;
    out(`${SELF}: telegram digest → ${total} repl${total === 1 ? "y" : "ies"} queued (${path.basename(digestPath)}); send via the bridge reply tool`);
  } else if (fs.existsSync(digestPath)) {
    fs.rmSync(digestPath); // clear a stale digest so nothing is re-sent
  }
}

// LUNA-89: claim the open _deferred.md tail-skipped rows for each github
// contributor, ledger each edit (reversible: oldLine/newLine recorded).
function claimDeferredRows(vault, contributors, subjectLink, ledgerPath) {
  const deferredAbs = path.join(vault, "Clippings", "_deferred.md");
  if (!fs.existsSync(deferredAbs)) return 0;
  const date = today();
  let content = fs.readFileSync(deferredAbs, "utf8");
  let count = 0;
  for (const c of contributors) {
    const slug = repoSlugFromCanonical(c.canonicalUrl);
    if (!slug) continue;
    const res = claimTailSkippedRow(content, slug, subjectLink, date);
    if (!res) continue;
    content = res.newContent;
    fs.writeFileSync(deferredAbs, content);
    fs.appendFileSync(ledgerPath, JSON.stringify({
      ts: new Date().toISOString(),
      action: "deferred-claim",
      file: "Clippings/_deferred.md",
      repo: slug,
      oldLine: res.oldLine,
      newLine: res.newLine,
    }) + "\n");
    count++;
  }
  return count;
}

// ── revert (divergence-guarded) ──────────────────────────────────────────────
// Undoes BOTH stub-create (delete the page) and densify (remove the appended
// block) entries — newest-first, so a stub-create+later-densify on one page
// reverts in the right order (densify restores the page to its stub bytes, then
// the stub-create entry matches and deletes it). Any page whose hash diverged
// from the recorded post-op hash is REFUSED — the operator touched it.
function clearStamps(vault, stamped) {
  for (const rel of stamped || []) {
    const cAbs = path.join(vault, rel.split("/").join(path.sep));
    if (!fs.existsSync(cAbs)) continue;
    fs.writeFileSync(cAbs, removeScalar(fs.readFileSync(cAbs, "utf8"), "promoted_to"));
  }
}

function runRevert(vault, revertPath) {
  if (!fs.existsSync(revertPath)) die(1, `ledger not found: ${revertPath}`);
  const raw = fs.readFileSync(revertPath, "utf8");
  const entries = raw.split("\n").map((l) => l.trim()).filter(Boolean).map((l) => {
    try { return JSON.parse(l); } catch (e) { die(1, `corrupt ledger line: ${e.message}`); }
  }).filter((e) => e.action === "stub-create" || e.action === "densify" || e.action === "deferred-claim");

  let reverted = 0, refused = 0, gone = 0;
  for (let i = entries.length - 1; i >= 0; i--) {
    const e = entries[i];

    // deferred-claim: restore the original _deferred.md row by literal swap.
    // No whole-file sha guard — _deferred.md is regenerated wholesale by
    // /archive-clips, so we key on the exact claimed line still being present.
    if (e.action === "deferred-claim") {
      const fAbs = path.join(vault, e.file.split("/").join(path.sep));
      if (!fs.existsSync(fAbs)) { gone++; continue; }
      const fc = fs.readFileSync(fAbs, "utf8");
      if (!fc.includes(e.newLine)) {
        out(`⊘ ${e.file} — row for ${e.repo} no longer present (regenerated); skipping restore`);
        gone++;
        continue;
      }
      // Function replacement: oldLine is data — a literal `$` in a re-run hint
      // must not be read as a `$&`/`$1` substitution pattern.
      fs.writeFileSync(fAbs, fc.replace(e.newLine, () => e.oldLine));
      out(`↩ ${e.file} — restored tail-skipped row for ${e.repo}`);
      reverted++;
      continue;
    }

    const abs = path.join(vault, e.subject.split("/").join(path.sep));
    if (!fs.existsSync(abs)) { gone++; continue; }
    const cur = fs.readFileSync(abs, "utf8");
    if (sha256(cur) !== e.subject_sha256) {
      out(`⊘ ${e.subject} — diverged since ${e.action} (operator touched it); refusing to revert`);
      refused++;
      continue;
    }
    if (e.action === "stub-create") {
      fs.rmSync(abs);
      clearStamps(vault, e.stamped);
      out(`↩ ${e.subject} — stub reverted (page removed, ${(e.stamped || []).length} promoted_to cleared)`);
    } else {
      // densify: remove the exact appended block (first literal occurrence).
      const restored = cur.replace(e.appended, "");
      fs.writeFileSync(abs, restored);
      clearStamps(vault, e.stamped);
      out(`↩ ${e.subject} — densify reverted (appended evidence removed, ${(e.stamped || []).length} promoted_to cleared)`);
    }
    reverted++;
  }
  out(`${SELF}: ${reverted} reverted, ${refused} refused (diverged), ${gone} already-gone`);
}

// ── main ─────────────────────────────────────────────────────────────────────
const a = parseArgs(process.argv.slice(2));
if (!a.vault && a.mode !== "revert") die(2, "usage: synthesize-stubs.mjs <vault> [--dry-run|--apply|--revert <ledger>]");
if (a.mode === "revert") {
  if (!a.vault) die(2, "revert needs <vault> and --revert <ledger>");
  runRevert(a.vault, a.revertPath);
} else {
  if (!fs.existsSync(path.join(a.vault, "Clippings"))) {
    out(`${SELF}: no Clippings/ — nothing to synthesize`);
    process.exit(0);
  }
  const dryRun = a.mode === "dry-run";
  const promotions = runApply(a.vault, ledgerPathFor(a.vault, a.ledger), dryRun);
  // LUNA-91: only a live --apply produces promotion feedback (a --dry-run stamps
  // nothing). Suppress with --no-telegram-digest during migration backfill.
  if (!dryRun) emitTelegramDigest(a.vault, promotions, !a.telegramDigest);
}
