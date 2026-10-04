#!/usr/bin/env node
/**
 * roadmap-aggregate.mjs — LUNA-59 cross-source roadmap-item aggregator.
 *
 * Scans the luna vault for actionable items across five sources and emits a
 * JSON inventory on stdout. READ-ONLY (no writes, no network) — safe to re-run.
 * The /roadmap-clips skill consumes this inventory, clusters items into a
 * sequenced roadmap, dedups candidate tickets against open Jira, and writes the
 * 60-Maps roadmap note.
 *
 * Sources:
 *   action-item        50-Journal/Daily/*.md          `- [ ]` lines
 *   deferred           Clippings/_deferred.md         `- [ ]` under `## section`
 *   synthesis-proposal Clippings/_synthesis/*.md       `## Proposed vault change`
 *   promotion          Clippings/**.md                 frontmatter promotion_candidate
 *   component          30-Resources/Components/**.md    frontmatter name+type
 *
 * Usage:  node roadmap-aggregate.mjs [--vault <path>] [--emit json|none]
 * Exit:   0 ok · 1 usage · 2 env unusable (vault missing / not an Obsidian vault)
 *
 * LUNA-59.
 */
import { existsSync, statSync, readFileSync, readdirSync } from "node:fs";
import { resolve, join, relative } from "node:path";
import { homedir } from "node:os";
import {
  parseDailyActionItems, parseDeferred, parseSynthesisProposal,
  parsePromotionCandidate, parseComponent, countBySource,
} from "./lib/roadmap-aggregate.mjs";

function die(code, msg) {
  process.stderr.write(`roadmap-aggregate: ${msg}\n`);
  process.exit(code);
}

function parseArgs(argv) {
  const a = { emit: "json" };
  // A flag that needs a value must have a non-flag token following it; otherwise
  // `--vault` silently swallows the next flag (or falls back to default) and
  // `--emit` with no value trips the json|none check with a confusing message.
  const val = (i, name) => {
    const v = argv[i + 1];
    if (v === undefined || v.startsWith("-")) die(1, `${name} requires a value.\n${USAGE}`);
    return v;
  };
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case "-h": case "--help": a.help = true; break;
      case "--vault": a.vault = val(i, "--vault"); i++; break;
      case "--emit": a.emit = val(i, "--emit"); i++; break;
      default: die(1, `unknown arg: ${argv[i]}`);
    }
  }
  return a;
}

const USAGE = "Usage: node roadmap-aggregate.mjs [--vault <path>] [--emit json|none]";

function resolveVault(arg) {
  const c = arg || process.env.OBSIDIAN_VAULT_PATH || join(homedir(), "Documents", "luna");
  if (!existsSync(c) || !statSync(c).isDirectory()) {
    die(2, `vault path not found: ${c} (pass --vault or set OBSIDIAN_VAULT_PATH)`);
  }
  if (!existsSync(join(c, ".obsidian"))) die(2, `not an Obsidian vault (no .obsidian/): ${c}`);
  return resolve(c);
}

/** Markdown files under dir (depth ≤ maxDepth), inbox-internals excluded. */
function mdFiles(dir, maxDepth, { skipDirs = new Set(), skipNames = new Set() } = {}) {
  const out = [];
  const walk = (d, depth) => {
    let entries;
    try { entries = readdirSync(d, { withFileTypes: true }); } catch (e) {
      if (e.code !== "ENOENT") process.stderr.write(`roadmap-aggregate: WARN cannot read ${d}: ${e.code || e.message}\n`);
      return;
    }
    for (const e of entries) {
      if (e.isDirectory()) {
        if (depth >= maxDepth || skipDirs.has(e.name)) continue;
        walk(join(d, e.name), depth + 1);
      } else if (e.isFile() && e.name.endsWith(".md") && !skipNames.has(e.name)) {
        out.push(join(d, e.name));
      }
    }
  };
  walk(dir, 1);
  return out;
}

function read(p) {
  try { return readFileSync(p, "utf8"); } catch (e) {
    process.stderr.write(`roadmap-aggregate: WARN cannot read ${p}: ${e.code || e.message}\n`);
    return null;
  }
}

function main() {
  const args = parseArgs(process.argv.slice(2));
  if (args.help) { process.stdout.write(USAGE + "\n"); process.exit(0); }
  if (args.emit !== "json" && args.emit !== "none") die(1, `--emit must be json|none.\n${USAGE}`);

  const vault = resolveVault(args.vault);
  const rel = (p) => relative(vault, p).replace(/\\/g, "/");
  const items = [];

  // action items — daily notes
  for (const f of mdFiles(join(vault, "50-Journal", "Daily"), 1, { skipNames: new Set(["_index.md"]) })) {
    const c = read(f); if (c) items.push(...parseDailyActionItems(c, rel(f)));
  }
  // deferred backlog
  const deferred = join(vault, "Clippings", "_deferred.md");
  if (existsSync(deferred)) { const c = read(deferred); if (c) items.push(...parseDeferred(c, rel(deferred))); }
  // synthesis proposals
  for (const f of mdFiles(join(vault, "Clippings", "_synthesis"), 1, { skipDirs: new Set(["_done"]) })) {
    const c = read(f); if (c) items.push(...parseSynthesisProposal(c, rel(f)));
  }
  // promotion candidates — clips (depth ≤ 2, inbox-internals excluded)
  for (const f of mdFiles(join(vault, "Clippings"), 2, {
    skipDirs: new Set(["_synthesis", "_done"]), skipNames: new Set(["_deferred.md"]),
  })) {
    const c = read(f); if (c) items.push(...parsePromotionCandidate(c, rel(f)));
  }
  // component inventory
  for (const f of mdFiles(join(vault, "30-Resources", "Components"), 3)) {
    const c = read(f); if (c) items.push(...parseComponent(c, rel(f)));
  }

  if (args.emit === "json") {
    process.stdout.write(JSON.stringify({ vault: rel(vault) || ".", counts: countBySource(items), total: items.length, items }, null, 2) + "\n");
  }
  process.exit(0);
}

main();
