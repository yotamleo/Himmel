export type ExtractedRow = { metric: string; date: string; value: number; source: string };
export type Conflict = { metric: string; date: string; values: { value: number; source: string }[] };
export type ReviewArtifact = { bucket: string; rows: ExtractedRow[]; conflicts: Conflict[] };

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

export async function writeArtifact(path: string, a: ReviewArtifact): Promise<void> {
  a.rows.forEach(validateRow);
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
  return a;
}
