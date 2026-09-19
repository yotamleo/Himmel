// Pure logic for scripts/vault/backfill-source-identity.mjs (HIMMEL-3055).
// No I/O here — every function takes plain data in and returns plain data out,
// so it is unit-testable without a vault, a network, or gh.
import { createHash } from "node:crypto";

/**
 * Parse a github repo source URL into { owner, repo }, or null if it is not
 * a bare repo URL (issue/PR/discussion URLs and non-github hosts are out of
 * scope for identity backfill — the backfill only touches repo notes).
 */
export function parseGithubSource(sourceUrl) {
  if (typeof sourceUrl !== "string") return null;
  const stripped = sourceUrl.trim().replace(/^https?:\/\/(www\.)?github\.com\//, "");
  if (stripped === sourceUrl.trim()) return null; // not a github.com URL
  const m = stripped.match(
    /^([A-Za-z0-9_.-]+)\/([A-Za-z0-9_.-]+?)(?:\.git)?(?:\/(?:tree|blob)\/.*)?\/?$/
  );
  if (!m) return null;
  const [, owner, repo] = m;
  return { owner, repo };
}

/** Group note refs ({path, owner, repo}) by lowercased "owner/repo" — keys on the repo, not the path. */
export function groupNotesByRepo(notes) {
  const grouped = new Map();
  for (const note of notes) {
    const key = `${note.owner}/${note.repo}`.toLowerCase();
    if (!grouped.has(key)) grouped.set(key, []);
    grouped.get(key).push(note);
  }
  return grouped;
}

/**
 * Merge groups whose raw keys resolved (via the GitHub API's own rename
 * follow-through) to the same canonical nameWithOwner, and report every
 * rename found. `canonicalByRawKey` maps a raw lowercased "owner/repo" to
 * the canonical "Owner/Repo" string GitHub returned for it; a raw key with
 * no entry (fetch failed, repo gone) keeps its own group unmerged.
 */
export function applyCanonicalRenames(groupedByRawKey, canonicalByRawKey) {
  const merged = new Map();
  const renames = [];
  for (const [rawKey, notes] of groupedByRawKey) {
    const canonical = canonicalByRawKey.get(rawKey) || rawKey;
    if (!merged.has(canonical)) merged.set(canonical, { notes: [], rawKeys: [] });
    const entry = merged.get(canonical);
    entry.notes.push(...notes);
    entry.rawKeys.push(rawKey);
    if (rawKey.toLowerCase() !== canonical.toLowerCase()) {
      renames.push({ from: rawKey, to: canonical });
    }
  }
  return { merged, renames };
}

/**
 * sha256 of the README bytes from the README API's `.content` (base64, wrapped
 * with embedded newlines). Mirrors luna-ingest's `tr -d '\n' | base64 -d |
 * sha256sum`, so backfill and ingest hash the same document. Null when there
 * is no API reply at all (404 / non-string) — an absent README is an absent
 * field, never a hash of empty bytes.
 */
export function readmeSha256FromApiContent(content) {
  if (typeof content !== "string") return null;
  const decoded = Buffer.from(content.replace(/\n/g, ""), "base64");
  return createHash("sha256").update(decoded).digest("hex");
}

function formatDelta(label, oldVal, newVal) {
  if (oldVal === null || oldVal === undefined || oldVal === "") {
    return `${label}: ${newVal} (no prior value recorded)`;
  }
  if (String(oldVal) === String(newVal)) {
    return `${label}: ${newVal} (unchanged)`;
  }
  return `${label}: ${oldVal}→${newVal}`;
}

/**
 * Build the ordered list of {key, value} identity fields to append to a
 * note's frontmatter. Any input that is null/undefined is omitted from the
 * output entirely rather than written as a fake/empty value.
 */
export function buildIdentityFields({
  oid,
  upstreamPushedAt,
  readmeSha256,
  revalidatedAt,
  existingStars,
  newStars,
  existingPushedAt,
  newPushedAtDate,
}) {
  const fields = [];
  if (oid) fields.push({ key: "upstream_commit", value: oid });
  if (upstreamPushedAt) fields.push({ key: "upstream_pushed_at", value: upstreamPushedAt });
  if (readmeSha256) fields.push({ key: "readme_sha256", value: readmeSha256 });
  if (revalidatedAt) fields.push({ key: "last_revalidated", value: revalidatedAt });

  const starsDelta = newStars !== null && newStars !== undefined
    ? formatDelta("stars", existingStars, newStars)
    : null;
  const pushedDelta = newPushedAtDate
    ? formatDelta("pushed_at", existingPushedAt, newPushedAtDate)
    : null;
  const deltaParts = [starsDelta, pushedDelta].filter(Boolean);
  if (deltaParts.length > 0) {
    fields.push({ key: "revalidation_delta", value: deltaParts.join(", ") });
  }
  return fields;
}

/** A plain YAML scalar is unsafe once it contains ": " (colon-space) or starts with a special char. */
function yamlScalar(value) {
  const str = String(value);
  if (/: |^[#>|*&!%@`"'?{}\[\],\s-]|:$/.test(str) || str === "") {
    return JSON.stringify(str);
  }
  return str;
}

/**
 * Additively patch a note's YAML frontmatter block: append any field in
 * `fields` whose key is not already present as a top-level `key:` line,
 * immediately before the closing `---`. Every existing line — frontmatter
 * or body — is preserved byte-identical and in order; nothing is reordered,
 * reformatted, or dropped. Re-running with fields that are all already
 * present is a true no-op (`changed: false`, identical content).
 */
export function patchFrontmatter(content, fields) {
  const lines = content.split("\n");
  if (lines[0] !== "---") {
    throw new Error("patchFrontmatter: content does not start with a frontmatter fence");
  }
  const closeIdx = lines.indexOf("---", 1);
  if (closeIdx === -1) {
    throw new Error("patchFrontmatter: no closing frontmatter fence found");
  }
  const frontmatterLines = lines.slice(0, closeIdx);
  const rest = lines.slice(closeIdx); // starts with the closing "---"

  const existingKeys = new Set();
  for (const line of frontmatterLines) {
    const m = line.match(/^([A-Za-z0-9_-]+):/);
    if (m) existingKeys.add(m[1]);
  }

  const toAppend = fields.filter((f) => !existingKeys.has(f.key));
  if (toAppend.length === 0) {
    return { content, changed: false };
  }

  const appended = toAppend.map((f) => `${f.key}: ${yamlScalar(f.value)}`);
  const newLines = [...frontmatterLines, ...appended, ...rest];
  return { content: newLines.join("\n"), changed: true };
}
