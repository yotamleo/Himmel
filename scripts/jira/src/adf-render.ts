// ADF → plain text renderer.
//
// Companion to adf.ts (which converts markdown → ADF for `create`/`edit`).
// This module walks an ADF document tree and extracts plain text — used
// by `get` to dump an issue's description body inline. No round-tripping,
// no formatting preservation; the goal is "readable text" not "lossless
// markdown".
//
// Defined with its own minimal node interface (rather than reusing the
// builder's strict union types) so the renderer accepts ANY ADF tree
// shape Jira returns — including node types adf.ts doesn't emit
// (media, mentions, panels, etc.). Unknown node types are walked
// through (their children's text still surfaces); only the type-tag
// and per-type attrs (panel emoji, date attrs, etc.) are dropped.
// Trade-off: forward-compatible with future ADF schema additions, at
// the cost of losing type-specific metadata. Acceptable for the
// "readable text" goal.
//
// Returns empty string for null/undefined input (Jira returns null
// description on issues with no body). Never throws on malformed input.

export interface ADFRenderNode {
  type: string;
  text?: string;
  content?: ADFRenderNode[];
  attrs?: Record<string, unknown>;
  marks?: Array<{ type: string; attrs?: Record<string, unknown> }>;
}

export interface ADFDocument {
  type: 'doc';
  version?: number;
  content?: ADFRenderNode[];
}

const BLOCK_TYPES = new Set([
  'paragraph',
  'heading',
  'blockquote',
  'codeBlock',
  'rule',
  'listItem',
  'tableRow',
]);

export function adfToPlainText(
  doc: ADFDocument | ADFRenderNode | null | undefined,
): string {
  if (!doc) return '';
  if (doc.type === 'doc' && Array.isArray(doc.content)) {
    return doc.content.map((n) => walk(n)).join('\n').trim();
  }
  return walk(doc as ADFRenderNode).trim();
}

function walk(node: ADFRenderNode | null | undefined, listMarker?: string): string {
  if (!node || typeof node !== 'object') return '';

  if (node.type === 'text') {
    return typeof node.text === 'string' ? node.text : '';
  }
  if (node.type === 'hardBreak') return '\n';

  if (node.type === 'mention') {
    const attrs = node.attrs as
      | { text?: string; displayName?: string; id?: string }
      | undefined;
    if (attrs?.text) return attrs.text;
    if (attrs?.displayName) return `@${attrs.displayName}`;
    // Deleted-user / restricted-profile mentions can lack both text AND
    // displayName but still carry the account id. Surface the id so the
    // reader at least knows a person was mentioned, rather than a silent
    // gap in the sentence.
    if (attrs?.id) return `@user:${attrs.id}`;
    return '@unknown';
  }
  if (node.type === 'emoji') {
    const attrs = node.attrs as { shortName?: string; text?: string } | undefined;
    if (attrs?.shortName) return `:${attrs.shortName}:`;
    // Custom site emojis often have only `text` (the literal text the
    // user typed, e.g. ":custom_thing:"). Preserve it rather than dropping.
    if (attrs?.text) return attrs.text;
    return '';
  }

  // List rendering — bullet/ordered each pass a marker prefix to listItem
  // children so the marker appears in front of the rendered item text.
  if (node.type === 'bulletList' && Array.isArray(node.content)) {
    return node.content.map((c) => walk(c, '- ')).join('\n');
  }
  if (node.type === 'orderedList' && Array.isArray(node.content)) {
    return node.content.map((c, i) => walk(c, `${i + 1}. `)).join('\n');
  }

  // Tables: rows joined by newline; cells joined by ' | '.
  if (node.type === 'table' && Array.isArray(node.content)) {
    return node.content.map((row) => walk(row)).join('\n');
  }
  if (node.type === 'tableRow' && Array.isArray(node.content)) {
    return node.content.map((cell) => walk(cell)).join(' | ');
  }

  // Generic block/inline: walk children, concatenate. Block-level nodes
  // get a leading listMarker (when supplied by a parent list) but no
  // forced trailing newline — separation between blocks comes from the
  // join('\n') at the doc/list level.
  const inner = Array.isArray(node.content)
    ? node.content.map((c) => walk(c)).join('')
    : '';
  const prefix = listMarker ?? '';
  if (BLOCK_TYPES.has(node.type)) {
    return prefix + inner;
  }
  return inner;
}
