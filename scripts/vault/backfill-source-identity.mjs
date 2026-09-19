#!/usr/bin/env node
/**
 * backfill-source-identity.mjs — HIMMEL-3055.
 *
 * One-off backfill: gives every existing luna vault note that points at a
 * github repo (`source: https://github.com/<owner>/<repo>` in its
 * frontmatter, wherever the note lives — not just 30-Resources/Tech/) a
 * commit SHA, an upstream pushed_at, and a README hash, so a later sweep can
 * tell "moved since ingest" from "checked, unchanged" without re-fetching
 * everything. Never re-ingests, never touches a note body, never rewrites an
 * existing frontmatter key — see docs on `patchFrontmatter` in
 * lib/source-identity.mjs for the additive-write contract this relies on.
 *
 * Usage:
 *   node scripts/vault/backfill-source-identity.mjs [--vault <path>] [--apply]
 *       [--summary-out <path>]
 *
 * Dry-run by default (prints what would change, writes nothing). --apply is
 * required to write. Never the reverse.
 *
 * Exit codes: 0 success (dry-run or apply), 2 env unusable (vault missing).
 */
import { readFileSync, writeFileSync, readdirSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { execFileSync } from "node:child_process";
import {
  parseGithubSource,
  readmeSha256FromApiContent,
  extractFrontmatterField,
  groupNotesByRepo,
  applyCanonicalRenames,
  buildIdentityFields,
  patchFrontmatter,
} from "./lib/source-identity.mjs";

const GRAPHQL_BATCH_SIZE = 100;

function parseArgs(argv) {
  const args = { apply: false, vault: process.env.LUNA_VAULT_PATH || join(process.env.HOME, "Documents/luna") };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === "--apply") args.apply = true;
    else if (argv[i] === "--vault") args.vault = argv[++i];
    else if (argv[i] === "--summary-out") args.summaryOut = argv[++i];
  }
  return args;
}

function walkMarkdownFiles(root) {
  const out = [];
  const stack = [root];
  while (stack.length) {
    const dir = stack.pop();
    let entries;
    try {
      entries = readdirSync(dir, { withFileTypes: true });
    } catch {
      continue;
    }
    for (const ent of entries) {
      if (ent.name === ".git" || ent.name === ".obsidian") continue;
      const full = join(dir, ent.name);
      if (ent.isDirectory()) stack.push(full);
      else if (ent.isFile() && ent.name.endsWith(".md")) out.push(full);
    }
  }
  return out;
}

function loadNotes(vaultRoot) {
  const notes = [];
  for (const file of walkMarkdownFiles(vaultRoot)) {
    let content;
    try {
      content = readFileSync(file, "utf8");
    } catch {
      continue;
    }
    if (!content.startsWith("---")) continue;
    const source = extractFrontmatterField(content, "source");
    if (!source) continue;
    const parsed = parseGithubSource(source);
    if (!parsed) continue;
    const starsRaw = extractFrontmatterField(content, "stars");
    const trustReason = extractFrontmatterField(content, "trust_tier_reason") || "";
    const pushedMatch = trustReason.match(/pushed_at=(\S+)/);
    notes.push({
      path: relative(vaultRoot, file),
      absPath: file,
      owner: parsed.owner,
      repo: parsed.repo,
      content,
      existingStars: starsRaw ? parseInt(starsRaw, 10) : null,
      existingPushedAt: pushedMatch ? pushedMatch[1] : null,
    });
  }
  return notes;
}

function ghGraphqlBatch(rawKeys) {
  // rawKeys: lowercased "owner/repo" strings. Build one aliased query per
  // batch of GRAPHQL_BATCH_SIZE repos; alias index maps back to the raw key.
  // ghDataByRawKey carries the full { nameWithOwner, oid, pushedAt, stars }
  // reply; canonicalNameByRawKey is the string-only projection applyCanonicalRenames needs.
  const ghDataByRawKey = new Map();
  const canonicalNameByRawKey = new Map();
  let apiCalls = 0;
  for (let i = 0; i < rawKeys.length; i += GRAPHQL_BATCH_SIZE) {
    const batch = rawKeys.slice(i, i + GRAPHQL_BATCH_SIZE);
    const fields = batch
      .map((key, idx) => {
        const [owner, repo] = key.split("/");
        const o = JSON.stringify(owner);
        const r = JSON.stringify(repo);
        return `r${idx}: repository(owner: ${o}, name: ${r}) { nameWithOwner defaultBranchRef { target { oid } } pushedAt stargazerCount }`;
      })
      .join("\n");
    const query = `query {\n${fields}\n}`;
    let out;
    try {
      out = execFileSync("gh", ["api", "graphql", "-f", `query=${query}`], { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 });
    } catch (e) {
      out = e.stdout ? e.stdout.toString() : null; // gh exits non-zero on partial GraphQL errors but still returns data
    }
    apiCalls++;
    if (!out) continue;
    let json;
    try {
      json = JSON.parse(out);
    } catch {
      continue;
    }
    const data = json.data || {};
    batch.forEach((key, idx) => {
      const r = data[`r${idx}`];
      if (r && r.nameWithOwner) {
        ghDataByRawKey.set(key, r);
        canonicalNameByRawKey.set(key, r.nameWithOwner);
      }
    });
  }
  return { ghDataByRawKey, canonicalNameByRawKey, apiCalls };
}

// Authenticated README API — the same endpoint luna-ingest reads — so private
// repos and non-standard README names resolve and both paths hash one document.
// ponytail: a README over the API's 1 MB inline limit returns empty `.content`,
// which hashes as empty bytes here exactly as it does in luna-ingest.
function fetchReadmeSha256(nameWithOwner) {
  try {
    const out = execFileSync("gh", ["api", `repos/${nameWithOwner}/readme`, "--jq", ".content"], {
      encoding: "utf8",
      maxBuffer: 32 * 1024 * 1024,
      stdio: ["ignore", "pipe", "ignore"],
    });
    return readmeSha256FromApiContent(out);
  } catch {
    return null; // 404 (no README) or gh failure: omit the field
  }
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  let vaultStat;
  try {
    vaultStat = statSync(args.vault);
  } catch {
    console.error(`ERR backfill-source-identity: vault not found at ${args.vault}`);
    process.exit(2);
  }
  if (!vaultStat.isDirectory()) {
    console.error(`ERR backfill-source-identity: ${args.vault} is not a directory`);
    process.exit(2);
  }

  const notes = loadNotes(args.vault);
  const groupedByRawKey = groupNotesByRepo(notes);
  const rawKeys = [...groupedByRawKey.keys()];

  console.error(`backfill-source-identity: ${notes.length} notes across ${rawKeys.length} distinct repo keys (pre-rename-merge)`);

  const { ghDataByRawKey, canonicalNameByRawKey, apiCalls } = ghGraphqlBatch(rawKeys);
  const { merged, renames } = applyCanonicalRenames(groupedByRawKey, canonicalNameByRawKey);

  const revalidatedAt = new Date().toISOString();
  let notesUpdated = 0;
  let reposChecked = 0;
  let reposMoved = 0;
  let reposUnchanged = 0;
  let reposFetchFailed = 0;
  const clipOnlyRepos = [];

  for (const [canonicalKey, entry] of merged) {
    reposChecked++;
    const rawKey = entry.rawKeys.find((k) => ghDataByRawKey.has(k));
    const gh = rawKey ? ghDataByRawKey.get(rawKey) : null;
    if (!gh) {
      reposFetchFailed++;
      continue;
    }
    const oid = gh.defaultBranchRef ? gh.defaultBranchRef.target.oid : null;
    const upstreamPushedAt = gh.pushedAt || null;
    const newPushedAtDate = upstreamPushedAt ? upstreamPushedAt.slice(0, 10) : null;
    const newStars = typeof gh.stargazerCount === "number" ? gh.stargazerCount : null;

    const readmeSha256 = fetchReadmeSha256(gh.nameWithOwner);

    const hasTechNote = entry.notes.some((n) => n.path.startsWith("30-Resources/Tech/"));
    if (!hasTechNote) clipOnlyRepos.push(canonicalKey);

    let repoMoved = false;
    let repoComparable = false;
    for (const note of entry.notes) {
      const fields = buildIdentityFields({
        oid,
        upstreamPushedAt,
        readmeSha256,
        revalidatedAt,
        existingStars: note.existingStars,
        newStars,
        existingPushedAt: note.existingPushedAt,
        newPushedAtDate,
      });
      // Re-read immediately before writing rather than patching the content
      // captured at loadNotes() time: a full run walks hundreds of repos
      // through sequential network calls, and patching stale content would
      // silently clobber an edit made to the note during that window.
      const sourceContent = args.apply ? readFileSync(note.absPath, "utf8") : note.content;
      const { content, changed } = patchFrontmatter(sourceContent, fields);
      if (note.existingPushedAt && newPushedAtDate) {
        repoComparable = true;
        if (note.existingPushedAt !== newPushedAtDate) repoMoved = true;
      }
      if (changed) {
        notesUpdated++;
        if (args.apply) writeFileSync(note.absPath, content, "utf8");
        else console.log(`DRY would update: ${note.path}`);
      }
    }
    if (repoComparable) {
      if (repoMoved) reposMoved++;
      else reposUnchanged++;
    }
  }

  const summary = {
    vault: args.vault,
    apply: args.apply,
    notesScanned: notes.length,
    reposChecked,
    reposMoved,
    reposUnchanged,
    reposFetchFailed,
    notesUpdated,
    renames,
    clipOnlyRepos,
    apiCallsGraphql: apiCalls,
  };

  console.log(JSON.stringify(summary, null, 2));
  if (args.summaryOut) writeFileSync(args.summaryOut, JSON.stringify(summary, null, 2), "utf8");
  if (!args.apply) console.error("backfill-source-identity: DRY RUN — no files written. Pass --apply to write.");
}

main();
