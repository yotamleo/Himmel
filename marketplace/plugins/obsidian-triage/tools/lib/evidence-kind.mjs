/**
 * evidence-kind.mjs — infer the evidence_kind field for a clip.
 *
 * Introduced by LUNA-83 (evidence-pool substrate). Used to populate
 * `evidence_kind: [..]` when a clip is promoted to Clippings/_evidence/.
 *
 * No npm deps, no I/O. Pure function over a plain object — runnable with
 * bare `node` (no bundler needed).
 *
 * Closed set of kinds: authors | concepts | misc | patterns | questions | tools
 * `misc` is the fallback — emitted ONLY when no other kind matched.
 * Output is deduplicated and lexicographically sorted.
 *
 * Note: `framework` intentionally maps to BOTH tools and concepts (a
 * framework can be a library you adopt AND a conceptual model you reason
 * with).
 */

const TOOLS_TAGS = new Set([
  "tool", "tools", "cli", "library", "framework", "sdk", "plugin", "repo",
]);

const CONCEPTS_TYPES = new Set([
  "research", "article", "youtube", "newsletter", "reddit",
]);

const CONCEPTS_TAGS = new Set([
  "concept", "concepts", "mental-model", "idea", "framework", "theory",
]);

const AUTHORS_TAGS = new Set([
  "author", "person",
]);

const QUESTIONS_TAGS = new Set([
  "question", "questions", "open-question",
]);

const PATTERNS_TAGS = new Set([
  "pattern", "patterns",
]);

/**
 * Infer the evidence kind(s) for a clip.
 *
 * @param {object} clip
 * @param {string|undefined} clip.type   — frontmatter `type:` value
 * @param {string|undefined} clip.url    — source URL (harvest_url_canonical / source)
 * @param {string[]|undefined} clip.tags — already-parsed tag array
 * @returns {string[]} Deduplicated, lexicographically-sorted array of kind strings.
 *                     Falls back to ['misc'] when no other kind matched.
 */
export function inferEvidenceKind(clip) {
  const type = (clip && clip.type) ? String(clip.type).trim().toLowerCase() : "";
  const url  = (clip && clip.url)  ? String(clip.url).toLowerCase()         : "";
  const tags = Array.isArray(clip && clip.tags) ? clip.tags : [];

  // Normalise tags: lowercase + trim whitespace
  const normTags = tags.map(t => String(t).trim().toLowerCase());

  const matched = new Set();

  // tools: github.com URL or tag intersection
  if (url.includes("github.com") || normTags.some(t => TOOLS_TAGS.has(t))) {
    matched.add("tools");
  }

  // concepts: type in set or tag intersection
  if (CONCEPTS_TYPES.has(type) || normTags.some(t => CONCEPTS_TAGS.has(t))) {
    matched.add("concepts");
  }

  // authors: tweet type or tag intersection
  if (type === "tweet" || normTags.some(t => AUTHORS_TAGS.has(t))) {
    matched.add("authors");
  }

  // questions: tag intersection
  if (normTags.some(t => QUESTIONS_TAGS.has(t))) {
    matched.add("questions");
  }

  // patterns: tag intersection
  if (normTags.some(t => PATTERNS_TAGS.has(t))) {
    matched.add("patterns");
  }

  // misc: fallback ONLY when nothing else matched
  if (matched.size === 0) {
    matched.add("misc");
  }

  return Array.from(matched).sort();
}

// ── CLI entry point ───────────────────────────────────────────────────────────
// Runs ONLY when this module is the Node.js entry point:
//   node tools/lib/evidence-kind.mjs --type research --url <url> --tags a,b
// Importers (`import { inferEvidenceKind } from '...'`) are NOT affected.
//
// Run-as-main detection: compare the basename of process.argv[1] to this
// file's own basename extracted from import.meta.url. Works cross-platform
// (Linux/macOS/Git-Bash/Windows) without fileURLToPath or any imports.
const _selfBasename = import.meta.url.split('/').pop();
if (process.argv[1] && process.argv[1].split(/[/\\]/).pop() === _selfBasename) {
  const args = process.argv.slice(2);
  const get = (flag) => {
    const i = args.indexOf(flag);
    return (i >= 0 && args[i + 1] !== undefined) ? args[i + 1] : '';
  };
  const type    = get('--type') || undefined;
  const url     = get('--url')  || undefined;
  const tagsStr = get('--tags');
  const tags    = tagsStr ? tagsStr.split(',') : [];
  process.stdout.write(JSON.stringify(inferEvidenceKind({ type, url, tags })) + '\n');
}
