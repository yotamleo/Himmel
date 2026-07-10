export type ExtractedRow = { metric: string; date: string; value: number; source: string };
// One competing (value, source) candidate for a (metric, date) cell.
export type Candidate = { value: number; source: string };
// `chosen` records WHICH candidate value mergeRows emitted into `rows` (the
// deterministic-wins / first-row pick), so an operator resolving the conflict in
// the review artifact can see the auto-selected provenance, not just the rejects.
export type Conflict = {
  metric: string;
  date: string;
  values: Candidate[];
  chosen: Candidate;
};
// Optional operator-facing degradation/degradation-adjacent signals (HIMMEL-794).
// Absent on a clean pull (byte-identical artifacts to pre-794); present only when
// deriveSleep recorded a warning (degraded stage data, dropped session, non-array
// stages). Preserved (and deduped across inputs) by the `merge` CLI command in
// cli.ts — mergeRows itself never touches warnings. writeSeries ignores it.
export type ReviewArtifact = { bucket: string; rows: ExtractedRow[]; conflicts: Conflict[]; warnings?: string[] };

const ISO = /^\d{4}-\d{2}-\d{2}$/;

// True only for a real ISO YYYY-MM-DD calendar date. The format regex alone admits
// impossible dates (2024-02-30, 2024-13-01); the UTC round-trip rejects those.
// Shared by validateRow (incoming rows) and the existing-CSV seed path (writeSeries),
// so both gates reject phantom dates identically.
export function isValidISODate(date: string): boolean {
  if (!ISO.test(date)) return false;
  const d = new Date(`${date}T00:00:00Z`);
  return !Number.isNaN(d.getTime()) && d.toISOString().slice(0, 10) === date;
}

export function validateRow(r: ExtractedRow): void {
  if (!r.metric) throw new Error(`row has empty metric: ${JSON.stringify(r)}`);
  if (!r.source) throw new Error(`row has empty source: ${JSON.stringify(r)}`);
  if (!isValidISODate(r.date)) throw new Error(`row date is not a valid ISO calendar date: "${r.date}"`);
  if (typeof r.value !== "number" || !Number.isFinite(r.value)) throw new Error(`row value is not numeric: ${JSON.stringify(r)}`);
}

function validateCandidate(cand: Candidate, label: string, ctx: Conflict): void {
  if (!cand || typeof cand.value !== "number" || !Number.isFinite(cand.value) || !cand.source) {
    throw new Error(`conflict ${label} is not a well-formed {value, source} candidate: ${JSON.stringify(ctx)}`);
  }
}

export function validateConflict(c: Conflict): void {
  if (!c.metric) throw new Error(`conflict has empty metric: ${JSON.stringify(c)}`);
  if (!isValidISODate(c.date)) throw new Error(`conflict date is not a valid ISO calendar date: "${c.date}"`);
  // A conflict only exists because ≥2 distinct candidate values were seen, so the
  // values list must carry at least two well-formed candidates — `chosen` alone is
  // not enough provenance for an operator resolving medical-series disagreement.
  if (!Array.isArray(c.values) || c.values.length < 2) throw new Error(`conflict "values" must list at least two candidates: ${JSON.stringify(c)}`);
  c.values.forEach(v => validateCandidate(v, '"values" entry', c));
  validateCandidate(c.chosen, '"chosen" provenance entry', c);
  // The emitted candidate must be one of the recorded candidates; a `chosen` that
  // names no listed value is corruption (e.g. a bad hand-edit of the artifact).
  if (!c.values.some(v => v.value === c.chosen.value && v.source === c.chosen.source)) {
    throw new Error(`conflict "chosen" is not one of the recorded "values": ${JSON.stringify(c)}`);
  }
}

/**
 * Validate an optional `warnings` field on a ReviewArtifact: when present it must
 * be a non-empty array of non-empty strings — the documented contract is "absent
 * when empty, never []", so a present-but-empty array is rejected too. Returns an
 * error message when the value is malformed, or undefined when valid — absent
 * (undefined) counts as valid, so artifacts written before HIMMEL-794 (no warnings
 * field) keep loading unchanged. Shared by writeArtifact (outgoing) and
 * readArtifact (incoming, which prefixes the path), so both gates reject a
 * malformed warnings shape identically.
 */
function warningsError(warnings: unknown): string | undefined {
  if (warnings === undefined) return undefined;
  if (!Array.isArray(warnings)) return `artifact "warnings" must be an array of non-empty strings: ${JSON.stringify(warnings)}`;
  if (warnings.length === 0) return `artifact "warnings" must be absent when empty (never [])`;
  for (const w of warnings) {
    if (typeof w !== "string" || !w) return `artifact "warnings" must be an array of non-empty strings: ${JSON.stringify(warnings)}`;
  }
  return undefined;
}

export async function writeArtifact(path: string, a: ReviewArtifact): Promise<void> {
  a.rows.forEach(validateRow);
  a.conflicts.forEach(validateConflict);
  const werr = warningsError(a.warnings);
  if (werr) throw new Error(werr);
  await Bun.write(path, JSON.stringify(a, null, 2));
}

export async function readArtifact(path: string): Promise<ReviewArtifact> {
  let a: ReviewArtifact;
  try {
    a = (await Bun.file(path).json()) as ReviewArtifact;
  } catch (err) {
    // Surface WHICH artifact failed and why (a bare SyntaxError byte-offset is
    // unactionable in a multi-bucket pipeline over medical data).
    throw new Error(`failed to read/parse artifact at ${path}: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (typeof a.bucket !== "string" || !a.bucket) throw new Error(`malformed artifact at ${path}: missing or empty "bucket"`);
  if (!Array.isArray(a.rows) || !Array.isArray(a.conflicts)) throw new Error(`malformed artifact at ${path}: "rows" and "conflicts" must be arrays`);
  a.rows.forEach(validateRow);
  a.conflicts.forEach(validateConflict);
  const werr = warningsError(a.warnings);
  if (werr) throw new Error(`malformed artifact at ${path}: ${werr}`);
  return a;
}
