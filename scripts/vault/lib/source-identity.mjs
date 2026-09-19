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

function formatDelta(label, oldVal, newVal, sameLabel = "unchanged") {
  if (oldVal === null || oldVal === undefined || oldVal === "") {
    return `${label}: ${newVal} (no prior value recorded)`;
  }
  if (String(oldVal) === String(newVal)) {
    return `${label}: ${newVal} (${sameLabel})`;
  }
  return `${label}: ${oldVal}→${newVal}`;
}

const sameInstant = (a, b) => {
  const [ta, tb] = [Date.parse(a), Date.parse(b)];
  return Number.isNaN(ta) || Number.isNaN(tb) ? String(a) === String(b) : ta === tb;
};

// Date.parse reads a bare "2026-09-10" as that day's 00:00:00Z, so a date-only
// value would pass for a full timestamp; require a time component.
const hasTime = (s) => /T\d/.test(s);

/**
 * Has the repo moved since the note's recorded evidence? Full-precision
 * evidence wins: a commit OID and/or a full pushed_at timestamp (one carrying a
 * time component — a bare date is calendar evidence) on both sides.
 * Any difference there is "moved"; all-equal is "unchanged" (confirmed).
 * With no full-precision pair, calendar dates are compared: a different date
 * is still "moved", but the SAME date is only "date-only" — two pushes on one
 * UTC day are indistinguishable, so it must not read as confirmed-unchanged.
 * No usable prior evidence at all -> "no-baseline".
 */
export function classifyMovement({
  existingCommit,
  newCommit,
  existingPushedAtFull,
  newPushedAtFull,
  existingPushedAtDate,
  newPushedAtDate,
}) {
  const compared = [];
  if (existingCommit && newCommit) compared.push(existingCommit === newCommit);
  if (hasTime(existingPushedAtFull ?? "") && hasTime(newPushedAtFull ?? "")) compared.push(sameInstant(existingPushedAtFull, newPushedAtFull));
  if (compared.length > 0) return compared.includes(false) ? "moved" : "unchanged";
  if (existingPushedAtDate && newPushedAtDate) {
    return existingPushedAtDate === newPushedAtDate ? "date-only" : "moved";
  }
  return "no-baseline";
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
    ? formatDelta("pushed_at", existingPushedAt, newPushedAtDate, "same day, date-only") // a calendar date cannot confirm "unchanged"
    : null;
  const deltaParts = [starsDelta, pushedDelta].filter(Boolean);
  if (deltaParts.length > 0) {
    fields.push({ key: "revalidation_delta", value: deltaParts.join(", ") });
  }
  return fields;
}

// Frontmatter fences are matched CR-tolerantly: a CRLF note splits on "\n" into
// lines that still end in "\r", and must not be mistaken for a fence-less note.
const isFence = (line) => line !== undefined && line.replace(/\r$/, "") === "---";
const closingFenceIndex = (lines) => lines.findIndex((line, i) => i > 0 && isFence(line));

/** Extract a top-level `key: value` line's value from WITHIN the frontmatter block only. */
export function extractFrontmatterField(content, key) {
  const lines = content.split("\n");
  if (!isFence(lines[0])) return null;
  const closeIdx = closingFenceIndex(lines);
  if (closeIdx === -1) return null;
  for (const line of lines.slice(1, closeIdx)) {
    const m = line.replace(/\r$/, "").match(new RegExp(`^${key}:\\s*(.*)$`));
    if (m) return m[1].trim().replace(/^["']|["']$/g, "");
  }
  return null;
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
  if (!isFence(lines[0])) {
    throw new Error("patchFrontmatter: content does not start with a frontmatter fence");
  }
  const closeIdx = closingFenceIndex(lines);
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

  // Split on "\n" leaves a CRLF note's "\r" on every original line, so those
  // round-trip untouched; the appended lines take the opening fence's ending.
  const cr = lines[0].endsWith("\r") ? "\r" : "";
  const appended = toAppend.map((f) => `${f.key}: ${yamlScalar(f.value)}${cr}`);
  const newLines = [...frontmatterLines, ...appended, ...rest];
  return { content: newLines.join("\n"), changed: true };
}
