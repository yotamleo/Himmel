#!/usr/bin/env node
/**
 * daily-timeline.mjs — daily-note `## Clip pipeline` timeline (LUNA-90).
 *
 * Recomputes the day's clip-pipeline activity from VAULT STATE + the
 * synthesize-stubs ledger and upserts a SINGLE `## Clip pipeline` section into
 * 50-Journal/Daily/<date>.md. Four metrics, all date-anchored (bi-temporal,
 * design §9):
 *   - Captured → inbox    : clips with `date_clipped: <date>` anywhere in Clippings/
 *   - Reviewed → evidence : clips in Clippings/_evidence/ with `triaged_at: <date>`,
 *                           broken down by `evidence_kind`
 *   - Promoted → subjects : `.synthesize-stubs.ledger.jsonl` stub-create entries
 *                           dated <date> → [[subject]] backrefs
 *   - Densified subjects  : ledger densify entries dated <date> → [[subject]] backrefs
 *
 * Because it is a pure recount of state, re-running for the same date is
 * idempotent — it UPDATES the one section, never appends a second or
 * double-counts (handover HARD GUARDRAIL #1). Stages call it at end-of-run
 * (triage after Phase 5; synthesize-stubs after --apply) so the daily note is a
 * timeline of knowledge-work, not just capture.
 *
 *   node daily-timeline.mjs --vault <path> --date YYYY-MM-DD [--daily <path>]
 *
 * A missing daily note is a NO-OP (exit 0, no phantom file): the triage runbook
 * Phase 5 owns daily-note creation; this tool only annotates an existing note.
 *
 * Dependency-light: pure node + ./lib/{frontmatter,daily-timeline}.mjs.
 */

import fs from "node:fs";
import path from "node:path";
import { parse, fmScalar, fmList } from "./lib/frontmatter.mjs";
import { renderPipelineSection, upsertSection, PIPELINE_HEADING } from "./lib/daily-timeline.mjs";

const SELF = "daily-timeline.mjs";
const out = (s) => process.stdout.write(s + "\n");
const err = (s) => process.stderr.write(s + "\n");
function die(code, msg) { err(`${SELF}: ${msg}`); process.exit(code); }

function parseArgs(argv) {
  const a = { vault: null, date: null, daily: null };
  for (let i = 0; i < argv.length; i++) {
    const t = argv[i];
    if (t === "--vault") a.vault = argv[++i];
    else if (t === "--date") a.date = argv[++i];
    else if (t === "--daily") a.daily = argv[++i];
    else die(1, `unknown arg: ${t}`);
  }
  return a;
}

/** Resolve the daily note for <date>, or null if none exists (no phantom). */
function resolveDaily(vault, date, override) {
  const candidates = override
    ? [override]
    : [
        path.join(vault, "50-Journal", "Daily", `${date}.md`),
        path.join(vault, "Daily", `${date}.md`),
      ];
  for (const c of candidates) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}

/** Frontmatter scalar reader for a file (or "" when unreadable / no frontmatter). */
function readScalar(abs, key) {
  let content;
  try { content = fs.readFileSync(abs, "utf8"); } catch { return ""; }
  const { lines, bounds } = parse(content);
  if (!bounds) return "";
  return fmScalar(lines, bounds.close, key);
}

/** Recursively list *.md under dir, skipping the given directory basenames. */
function walkMd(dir, skipDirs) {
  const acc = [];
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return acc; }
  for (const e of entries) {
    const abs = path.join(dir, e.name);
    if (e.isDirectory()) {
      if (skipDirs.has(e.name)) continue;
      acc.push(...walkMd(abs, skipDirs));
    } else if (e.isFile() && e.name.endsWith(".md") && e.name !== "_deferred.md") {
      acc.push(abs);
    }
  }
  return acc;
}

/** Captured → inbox: clips anywhere in Clippings/ with `date_clipped: <date>`. */
function countCaptured(vault, date) {
  const root = path.join(vault, "Clippings");
  // _synthesis/ holds proposal pages (not clips); everything else is in scope.
  const files = walkMd(root, new Set(["_synthesis"]));
  let n = 0;
  for (const abs of files) {
    if (readScalar(abs, "date_clipped") === date) n++;
  }
  return n;
}

/** Reviewed → evidence: _evidence/ clips with `triaged_at: <date>`, by kind. */
function countReviewedByKind(vault, date) {
  const dir = path.join(vault, "Clippings", "_evidence");
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch { return { total: 0, byKind: {} }; }
  let total = 0;
  const byKind = {};
  for (const e of entries) {
    // Flat pool only — _rejected/ (and any subdir) is not "reviewed → evidence".
    if (!e.isFile() || !e.name.endsWith(".md")) continue;
    const abs = path.join(dir, e.name);
    let content;
    try { content = fs.readFileSync(abs, "utf8"); } catch { continue; }
    const { lines, bounds } = parse(content);
    if (!bounds) continue;
    if (fmScalar(lines, bounds.close, "triaged_at") !== date) continue;
    total++;
    for (const k of fmList(lines, bounds.close, "evidence_kind")) {
      byKind[k] = (byKind[k] || 0) + 1;
    }
  }
  return { total, byKind };
}

/** Read ledger subjects for a date, partitioned into promoted (stub-create) /
 *  densified (densify, excluding ones also created today). Order: first seen. */
function ledgerSubjects(vault, date) {
  const ledgerPath = path.join(vault, ".synthesize-stubs.ledger.jsonl");
  const promoted = [];
  const densified = [];
  const seenP = new Set();
  const seenD = new Set();
  let raw;
  try { raw = fs.readFileSync(ledgerPath, "utf8"); } catch { return { promoted, densified }; }
  for (const line of raw.split("\n")) {
    const t = line.trim();
    if (!t) continue;
    let e;
    try { e = JSON.parse(t); } catch { continue; }
    if (!e || typeof e.ts !== "string" || e.ts.slice(0, 10) !== date) continue;
    if (!e.subject) continue;
    // Stay a pure recount of STATE: the ledger is append-only, but `--revert`
    // deletes a reverted stub's page without truncating the ledger. Skip any
    // subject whose page no longer exists on disk so a created-then-reverted
    // stub never leaves a dangling [[subject]] backref / overstated count in the
    // daily note (a densified page still exists, so it survives this guard).
    const subjectAbs = path.join(vault, String(e.subject).split("/").join(path.sep));
    if (!fs.existsSync(subjectAbs)) continue;
    const link = `[[${String(e.subject).replace(/\.md$/, "")}]]`;
    if (e.action === "stub-create") {
      if (!seenP.has(link)) { seenP.add(link); promoted.push(link); }
    } else if (e.action === "densify") {
      if (!seenD.has(link)) { seenD.add(link); densified.push(link); }
    }
  }
  // A subject created AND densified on the same day shows only under Promoted.
  return { promoted, densified: densified.filter((l) => !seenP.has(l)) };
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  if (!a.vault) die(1, "usage: daily-timeline.mjs --vault <path> --date YYYY-MM-DD [--daily <path>]");
  if (!a.date || !/^\d{4}-\d{2}-\d{2}$/.test(a.date)) die(1, "missing/invalid --date (YYYY-MM-DD)");

  const daily = resolveDaily(a.vault, a.date, a.daily);
  if (!daily) {
    out(`${SELF}: no daily note for ${a.date} — nothing to annotate (Phase 5 creates it first)`);
    process.exit(0);
  }

  const metrics = {
    captured: countCaptured(a.vault, a.date),
    reviewed: countReviewedByKind(a.vault, a.date),
    ...ledgerSubjects(a.vault, a.date),
  };

  const content = fs.readFileSync(daily, "utf8");
  const eol = content.includes("\r\n") ? "\r\n" : "\n";
  const section = renderPipelineSection(metrics, eol);
  const next = upsertSection(content, PIPELINE_HEADING, section);
  if (next !== content) fs.writeFileSync(daily, next);

  out(
    `${SELF}: ${path.relative(a.vault, daily)} — captured ${metrics.captured}, ` +
    `reviewed ${metrics.reviewed.total}, promoted ${metrics.promoted.length}, densified ${metrics.densified.length}`,
  );
  process.exit(0);
}

main();
