/**
 * component-extract.mjs — LUNA-57 pure component extraction for the
 * luna-ingest --deep mode. No I/O, no network. Mirrors the
 * frontmatter-parsing + slug conventions used across obsidian-triage tools.
 *
 * A "component" is a reusable Claude Code building block discoverable in a
 * repo's file tree: a skill, command, agent, tool script, or plugin manifest.
 */

import { basename } from "node:path";
import { createHash } from "node:crypto";

/**
 * The closed set of recognised component types. classifyPath and
 * extractComponent hardcode these literals rather than consult this constant,
 * so it must be kept in sync with both by hand — drift is caught by the
 * LUNA-62 "COMPONENT_TYPES complete" test, not at runtime. (LUNA-62)
 */
export const COMPONENT_TYPES = Object.freeze([
  "skill", "command", "agent", "plugin-manifest", "tool",
]);

/** Upper bound on a stored component description (chars). (LUNA-63) */
const MAX_DESCRIPTION = 500;

/** Trim + cap a description to MAX_DESCRIPTION chars. (LUNA-63) */
function boundDescription(s) {
  const t = String(s || "").trim();
  return t.length <= MAX_DESCRIPTION ? t : t.slice(0, MAX_DESCRIPTION).trimEnd();
}

/**
 * Normalise a repo-relative component path: backslashes → forward slashes,
 * strip a leading `./`, collapse repeated slashes. So the same file is keyed
 * and recorded identically regardless of incidental path spelling. (LUNA-63)
 */
export function normalizeComponentPath(p) {
  return String(p || "").replace(/\\/g, "/").replace(/^\.\//, "").replace(/\/{2,}/g, "/");
}

/**
 * Map a repo-relative file path to a component type, or null if it is not a
 * recognised component. Case-insensitive. Callers MUST pre-filter
 * `node_modules/` paths (selectComponentPaths does this).
 */
export function classifyPath(path) {
  const p = String(path || "").replace(/^\.\//, "");
  if (/(^|\/)skills\/[^/]+\/SKILL\.md$/i.test(p)) return "skill";
  if (/(^|\/)commands\/[^/]+\.md$/i.test(p)) return "command";
  if (/(^|\/)agents\/[^/]+\.md$/i.test(p)) return "agent";
  if (/(^|\/)\.claude-plugin\/plugin\.json$/i.test(p)) return "plugin-manifest";
  if (/(^|\/)(\.claude-plugin\/)?marketplace\.json$/i.test(p)) return "plugin-manifest";
  if (/(^|\/)tools\/.+\.(mjs|js|ts|py|sh)$/i.test(p)) return "tool";
  return null;
}

/**
 * Minimal top-level frontmatter field parser — mirrors the parser in
 * dedup-sweep.mjs / fxtwitter-enrich.mjs. CRLF-normalised. Top-level
 * `key: value` only (component frontmatter never nests name/description).
 */
export function parseFrontmatterFields(content) {
  const text = String(content || "").replace(/\r\n/g, "\n");
  if (!text.startsWith("---\n")) return {};
  const rel = text.slice(4).search(/\n---(\n|$)/);
  const end = rel < 0 ? -1 : rel + 4;
  if (end < 0) return {};
  const fm = {};
  for (const line of text.slice(4, end).split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):(.*)$/);
    if (m) {
      let v = m[2].trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      fm[m[1]] = v;
    }
  }
  return fm;
}

/** First human-readable doc/comment line from a tool script (best-effort). */
function firstDocLine(content) {
  const lines = String(content || "").replace(/\r\n/g, "\n").split("\n");
  for (let raw of lines) {
    let line = raw.trim();
    if (!line || line.startsWith("#!")) continue;            // shebang
    line = line.replace(/^\/\*+\s?/, "").replace(/\*+\/\s*$/, ""); // /** */ fences
    line = line.replace(/^[*#/]+\s?/, "");                     // *, //, # markers
    line = line.replace(/^"""|"""$/g, "").trim();             // py docstring fences
    if (line) return line;
  }
  return "";
}

/**
 * Slugify a component name → `[a-z0-9-]`, collapse, trim, max 60. When the
 * name slugifies to empty (CJK, all-symbol names), fall back to a
 * deterministic-but-unique `x<8-hex>` derived from a sha256 of the original
 * name — identical names still produce identical slugs (correct dedup) while
 * distinct empty-slug names stay distinct (no false merge under "unnamed").
 */
export function componentSlug(name) {
  const raw = String(name || "");
  const norm = raw
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-+|-+$/g, "");
  if (!norm) return "x" + createHash("sha256").update(raw).digest("hex").slice(0, 8);
  if (norm.length <= 60) return norm;
  // Truncation-collision guard (LUNA-61): distinct long names can share the
  // same 60-char prefix. Append a short hash of the FULL normalised slug so
  // identical names still collapse to one slug (correct dedup) while distinct
  // long names stay distinct. 51 + "-" + 8 hex = 60 chars max.
  const hash = createHash("sha256").update(norm).digest("hex").slice(0, 8);
  return norm.slice(0, 51).replace(/-+$/g, "") + "-" + hash;
}

/**
 * The string a component is identified — and cross-repo deduped — by.
 *
 * Skills, commands, agents and plugin manifests carry a declared `name` that
 * is stable across repos, so they dedup by that name. Tools are named by bare
 * basename, which collides across sibling dirs in one repo (tools/a/x.mjs vs
 * tools/b/x.mjs); they dedup by their (normalised) repo-relative path instead,
 * so distinct tools never share a key while the same tool path seen in several
 * repos still merges to one note. (LUNA-61)
 */
export function componentIdentity(record) {
  if (record.type === "tool") {
    return normalizeComponentPath(record.path || record.name || "");
  }
  return record.name || "";
}

/**
 * Canonical cross-repo dedup key: `<type>:<identity-slug>`. Identity is
 * name-based for skills/commands/agents/manifests and path-based for tools
 * (see componentIdentity); componentSlug guards against truncation collisions.
 * (LUNA-61)
 */
export function componentKey(record) {
  return `${record.type}:${componentSlug(componentIdentity(record))}`;
}

/** Name fallback for md components when frontmatter has no `name:`. */
function nameFromPath(path, type) {
  if (type === "skill") {
    const m = String(path).match(/(^|\/)skills\/([^/]+)\/SKILL\.md$/i);
    if (m) return m[2];
  }
  return basename(String(path)).replace(/\.md$/i, "");
}

/**
 * Build a component record from a classified file.
 * Input: { path, type, content }. Output: { name, type, description, path }.
 * Malformed manifests/frontmatter degrade gracefully (basename + empty
 * description); descriptions are length-bounded (LUNA-63). Throws on an
 * unrecognised `type` — a programmer error, distinct from malformed content,
 * since classifyPath only ever yields a COMPONENT_TYPES member. (LUNA-62)
 */
export function extractComponent({ path, type, content }) {
  if (type === "plugin-manifest") {
    let j = null;
    try { j = JSON.parse(content); } catch { /* degrade */ }
    return {
      name: (j && j.name) || basename(String(path)).replace(/\.json$/i, ""),
      type,
      description: boundDescription(j && typeof j.description === "string" ? j.description : ""),
      path,
    };
  }
  if (type === "skill" || type === "command" || type === "agent") {
    const fm = parseFrontmatterFields(content);
    return {
      name: fm.name || nameFromPath(path, type),
      type,
      description: boundDescription(fm.description),
      path,
    };
  }
  if (type === "tool") {
    return { name: basename(String(path)), type, description: boundDescription(firstDocLine(content)), path };
  }
  throw new Error(`extractComponent: unknown component type '${type}'`);
}

/**
 * Filter a flat list of repo-relative blob paths to component paths, excluding
 * any `node_modules/` path, and apply a hard cap. Returns
 * { selected: [{path, type}], skipped } where `skipped` counts components found
 * beyond `maxComponents` (deterministic tail-skip — input order preserved).
 */
export function selectComponentPaths(treePaths, { maxComponents }) {
  const selected = [];
  let skipped = 0;
  for (const p of treePaths) {
    if (/(^|\/)node_modules\//.test(p)) continue;
    const type = classifyPath(p);
    if (!type) continue;
    if (selected.length >= maxComponents) { skipped++; continue; }
    selected.push({ path: p, type });
  }
  return { selected, skipped };
}
