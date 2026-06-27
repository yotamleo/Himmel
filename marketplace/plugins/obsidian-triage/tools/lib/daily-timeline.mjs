/**
 * daily-timeline.mjs — pure rendering + idempotent section upsert for the
 * daily-note `## Clip pipeline` timeline (LUNA-90).
 *
 * The section is a STATE RECOUNT (see tools/daily-timeline.mjs): the caller
 * recomputes all four metrics from vault state for a given date and hands them
 * here to render + upsert. Because every write is a full recount, the upsert is
 * idempotent by construction — re-rendering with unchanged state yields
 * byte-identical output, and the section is replaced in place, never appended
 * twice (handover HARD GUARDRAIL #1).
 *
 * No npm deps, no I/O. Line-based + EOL-preserving in the same style as
 * frontmatter.mjs: LF or CRLF round-trips; only the `## Clip pipeline` section
 * is rewritten, every other byte of the note is left untouched.
 */

export const PIPELINE_HEADING = "## Clip pipeline";

/** Detect the note's dominant EOL ("\r\n" if any CRLF present, else "\n"). */
export function eolOf(content) {
  return content.includes("\r\n") ? "\r\n" : "\n";
}

/** "concepts 2, tools 1" from a {kind: count} map, lexicographically ordered. */
export function summarizeKinds(byKind) {
  const keys = Object.keys(byKind || {}).filter((k) => byKind[k] > 0).sort();
  return keys.map((k) => `${k} ${byKind[k]}`).join(", ");
}

/**
 * Render the `## Clip pipeline` section body (heading + four metric bullets).
 * `metrics` = { captured:int, reviewed:{total:int, byKind:{}}, promoted:[link],
 * densified:[link] } where each link is a bare `[[...]]` string. EOL-aware.
 */
export function renderPipelineSection(metrics, eol = "\n") {
  const m = metrics || {};
  const captured = m.captured || 0;
  const reviewed = m.reviewed || { total: 0, byKind: {} };
  const promoted = m.promoted || [];
  const densified = m.densified || [];

  const kinds = summarizeKinds(reviewed.byKind);
  const reviewedLine = kinds
    ? `- **Reviewed → evidence:** ${reviewed.total || 0} (${kinds})`
    : `- **Reviewed → evidence:** ${reviewed.total || 0}`;
  const listSuffix = (links) => (links.length ? ` — ${links.join(", ")}` : "");

  const lines = [
    PIPELINE_HEADING,
    "",
    `- **Captured → inbox:** ${captured}`,
    reviewedLine,
    `- **Promoted → subjects:** ${promoted.length}${listSuffix(promoted)}`,
    `- **Densified subjects:** ${densified.length}${listSuffix(densified)}`,
  ];
  return lines.join(eol);
}

/**
 * Idempotently upsert a `## ` section into note content.
 *
 * If a heading line equal to `heading` exists, the span from that line up to
 * (but not including) the next `## ` heading — or EOF — is REPLACED with
 * `sectionText`. Otherwise `sectionText` is appended at EOF, separated by one
 * blank line. EOL-preserving; all other content is byte-identical.
 *
 * Returns the new content. Idempotent: upsert(upsert(c)) === upsert(c) when
 * `sectionText` is unchanged.
 */
export function upsertSection(content, heading, sectionText) {
  const eol = eolOf(content);
  // Normalise the section text to the note's EOL so a LF-built block doesn't
  // inject bare LFs into a CRLF note.
  const normalized = sectionText.split(/\r?\n/).join(eol);

  const lines = content.split(/\r?\n/);
  let start = -1;
  for (let i = 0; i < lines.length; i++) {
    if (lines[i] === heading) { start = i; break; }
  }

  if (start === -1) {
    // Append at EOF with a single blank-line separator. Trim trailing blank
    // lines first so we don't accumulate them across runs.
    let end = lines.length;
    while (end > 0 && lines[end - 1] === "") end--;
    const head = lines.slice(0, end).join(eol);
    return `${head}${eol}${eol}${normalized}${eol}`;
  }

  // Find the end of the existing section: the next `## ` heading, else EOF.
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    if (/^## /.test(lines[i])) { end = i; break; }
  }
  // Drop trailing blank lines inside the replaced span so the rejoin keeps a
  // single blank line before the following heading (or a clean EOF).
  let spanEnd = end;
  while (spanEnd > start + 1 && lines[spanEnd - 1] === "") spanEnd--;

  const before = lines.slice(0, start);
  const after = lines.slice(spanEnd);
  const rebuilt = [...before, ...normalized.split(eol), ...after];
  return rebuilt.join(eol);
}
