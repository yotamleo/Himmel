/**
 * frontmatter.mjs — byte-preserving YAML-frontmatter helpers for the Phase-2
 * generative tools (LUNA-87/88/89).
 *
 * Line-based and lossless: split('\n')/join('\n') round-trips any content (LF
 * or CRLF — CRLF lines keep a trailing '\r'). We never normalise; insertion and
 * removal are exact so a stamp+unstamp pair restores the original bytes.
 *
 * Mirrors the local helpers in migrate-clip-lifecycle.mjs (LUNA-86) but is a
 * shared, exported module — the migration engine is intentionally left
 * untouched (it ships under review on the Phase-1 branch).
 *
 * No npm deps, no I/O. Pure string surgery + node:crypto for hashing.
 */

import crypto from "node:crypto";

export function splitLines(content) { return content.split("\n"); }
export function stripCR(s) { return s.endsWith("\r") ? s.slice(0, -1) : s; }
function eolOf(lines) { return lines.length && lines[0].endsWith("\r") ? "\r" : ""; }

/** Frontmatter fence bounds, or null when the file has no leading `---` block. */
export function frontmatterBounds(lines) {
  if (lines.length === 0) return null;
  if (stripCR(lines[0]) !== "---") return null;
  for (let i = 1; i < lines.length; i++) {
    if (stripCR(lines[i]) === "---") return { open: 0, close: i };
  }
  return null;
}

function matchKey(line, key) {
  const prefix = key + ":";
  if (!line.startsWith(prefix)) return null;
  return line.slice(prefix.length);
}

function unquote(s) {
  let t = String(s).trim();
  if ((t.startsWith('"') && t.endsWith('"')) || (t.startsWith("'") && t.endsWith("'"))) {
    t = t.slice(1, -1);
  }
  return t.trim();
}

/** Read a scalar frontmatter value (`key: value`). "" if absent. */
export function fmScalar(lines, close, key) {
  for (let i = 1; i < close; i++) {
    const m = matchKey(stripCR(lines[i]), key);
    if (m !== null) return unquote(m);
  }
  return "";
}

/** Read a list-valued frontmatter key: inline `[a, b]` OR block `- a` lines. */
export function fmList(lines, close, key) {
  for (let i = 1; i < close; i++) {
    const v = matchKey(stripCR(lines[i]), key);
    if (v === null) continue;
    const inline = v.trim();
    if (inline.startsWith("[") && inline.endsWith("]")) {
      return inline.slice(1, -1).split(",").map(unquote).filter((s) => s.length);
    }
    const items = [];
    for (let j = i + 1; j < close; j++) {
      const sub = stripCR(lines[j]);
      const t = sub.trim();
      if (t.startsWith("- ")) items.push(unquote(t.slice(2)));
      else if (t.startsWith("-")) items.push(unquote(t.slice(1)));
      else if (t === "") continue;
      else break;
    }
    return items;
  }
  return [];
}

export function hasKey(lines, close, key) {
  for (let i = 1; i < close; i++) {
    if (matchKey(stripCR(lines[i]), key) !== null) return true;
  }
  return false;
}

/** Convenience: parse content once into { lines, bounds }. */
export function parse(content) {
  const lines = splitLines(content);
  return { lines, bounds: frontmatterBounds(lines) };
}

/**
 * Insert a scalar `key: value` line at the end of the frontmatter block
 * (just before the closing fence). Throws if the key already exists (callers
 * must guard) or the file has no frontmatter. Byte-preserving / CRLF-aware.
 */
export function insertScalar(content, key, value) {
  const lines = splitLines(content);
  const b = frontmatterBounds(lines);
  if (!b) throw new Error("no frontmatter");
  if (hasKey(lines, b.close, key)) throw new Error(`key already present: ${key}`);
  const eol = eolOf(lines);
  const newLine = `${key}: ${value}${eol}`;
  const out = lines.slice(0, b.close).concat([newLine], lines.slice(b.close));
  return out.join("\n");
}

/**
 * Remove the scalar `key:` line from the frontmatter block. No-op (returns the
 * input unchanged) if the key is absent. Only removes a single scalar line —
 * not block-list children — which is all the Phase-2 stamps (`promoted_to:`) need.
 */
export function removeScalar(content, key) {
  const lines = splitLines(content);
  const b = frontmatterBounds(lines);
  if (!b) return content;
  for (let i = 1; i < b.close; i++) {
    if (matchKey(stripCR(lines[i]), key) !== null) {
      const out = lines.slice(0, i).concat(lines.slice(i + 1));
      return out.join("\n");
    }
  }
  return content;
}

export function sha256(str) {
  return crypto.createHash("sha256").update(str, "utf8").digest("hex");
}
