/**
 * roadmap-aggregate.mjs — LUNA-59 pure cross-source item extraction for
 * /roadmap-clips. No I/O, no network. Each parser takes file content + an
 * origin label and returns a flat list of roadmap "items" the skill then
 * clusters into a sequenced roadmap.
 *
 * Item shape: { source_type, text, origin, category? }
 *   source_type ∈ action-item | deferred | synthesis-proposal | promotion | component
 *   text        — the actionable string (trimmed, single-line where possible)
 *   origin      — vault-relative file the item came from
 *   category    — optional sub-grouping (e.g. the _deferred.md section heading)
 */

/** Top-level `key: value` frontmatter parser (mirrors the obsidian-triage
 * tools' shared shape; CRLF-normalised; quoted scalars unwrapped). */
export function parseFrontmatterFields(content) {
  const text = String(content || "").replace(/\r\n/g, "\n");
  if (!text.startsWith("---\n")) return {};
  const rel = text.slice(4).search(/\n---(\n|$)/);
  if (rel < 0) return {};
  const fm = {};
  for (const line of text.slice(4, rel + 4).split("\n")) {
    const m = line.match(/^([a-zA-Z_][a-zA-Z0-9_-]*):(.*)$/);
    if (m) {
      let v = m[2].trim();
      if ((v.startsWith('"') && v.endsWith('"')) || (v.startsWith("'") && v.endsWith("'"))) v = v.slice(1, -1);
      fm[m[1]] = v;
    }
  }
  return fm;
}

/** Open-checkbox task text on a line, or null. `- [ ] foo` → "foo". */
function checkboxText(line) {
  const m = line.match(/^\s*-\s*\[\s\]\s+(.*\S)\s*$/);
  return m ? m[1] : null;
}

/** Daily-note action items: `- [ ]` lines, with an optional
 * `(from [[Clippings/…]])` backref captured into `category`. */
export function parseDailyActionItems(content, origin) {
  const items = [];
  for (const line of String(content || "").replace(/\r\n/g, "\n").split("\n")) {
    const t = checkboxText(line);
    if (!t) continue;
    const back = t.match(/\(from \[\[([^\]]+)\]\]\)/);
    items.push({ source_type: "action-item", text: t, origin, category: back ? back[1] : null });
  }
  return items;
}

/** A deferred item whose text is exactly a wrapping markdown link
 * `[label](url)` is reduced to its bare URL — downstream Jira-dedup keys on the
 * URL, and the raw `[…](…)` syntax is noise in the roadmap. Plain text and
 * links mid-sentence are left untouched (only a full-string wrap matches). */
function unwrapDeferredLink(text) {
  const m = text.match(/^\[[^\]]*\]\(([^)\s]+)\)$/);
  return m ? m[1] : text;
}

/** _deferred.md backlog: `- [ ]` items grouped under `## <section>` headings.
 * The section heading becomes `category`. */
export function parseDeferred(content, origin) {
  const items = [];
  let section = null;
  for (const line of String(content || "").replace(/\r\n/g, "\n").split("\n")) {
    const h = line.match(/^##\s+(.*\S)\s*$/);
    if (h) { section = h[1]; continue; }
    const t = checkboxText(line);
    if (t) items.push({ source_type: "deferred", text: unwrapDeferredLink(t), origin, category: section });
  }
  return items;
}

/** Synthesis proposal: the `## Proposed vault change` section body → ONE item.
 * Returns [] if the section is absent or empty. */
export function parseSynthesisProposal(content, origin) {
  const body = String(content || "").replace(/\r\n/g, "\n");
  const lines = body.split("\n");
  let i = lines.findIndex((l) => /^##\s+Proposed vault change\s*$/i.test(l));
  if (i < 0) return [];
  const collected = [];
  for (i += 1; i < lines.length; i++) {
    if (/^##\s+/.test(lines[i])) break; // next H2 ends the section
    collected.push(lines[i]);
  }
  const text = collected.join(" ").replace(/\s+/g, " ").trim();
  return text ? [{ source_type: "synthesis-proposal", text, origin, category: null }] : [];
}

/** Promotion candidate: a clip whose frontmatter carries a non-empty
 * `promotion_candidate:` (triage annotation). Title prefers `title:`. */
export function parsePromotionCandidate(content, origin) {
  const fm = parseFrontmatterFields(content);
  const cand = (fm.promotion_candidate || "").trim();
  if (!cand || cand.toLowerCase() === "false" || cand.toLowerCase() === "none") return [];
  const title = (fm.title || origin).trim();
  return [{ source_type: "promotion", text: `${title} — ${cand}`, origin, category: null }];
}

/** Component inventory note: name + type from frontmatter → one item. The
 * LUNA-57 component-scan notes carry the real kind in `component_type:`
 * (skill/command/agent/tool) while `type:` is the literal note kind
 * `component`; prefer `component_type:` and fall back for hand-authored notes. */
export function parseComponent(content, origin) {
  const fm = parseFrontmatterFields(content);
  const name = (fm.name || fm.title || "").trim();
  if (!name) return [];
  const type = (fm.component_type || fm.type || "component").trim();
  return [{ source_type: "component", text: `${name} (${type})`, origin, category: type }];
}

/** Tally items by source_type. */
export function countBySource(items) {
  const counts = {};
  for (const it of items) counts[it.source_type] = (counts[it.source_type] || 0) + 1;
  return counts;
}
