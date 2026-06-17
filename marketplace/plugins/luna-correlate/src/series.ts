import type { SeriesPoint } from "./correlate";
export function parseSeriesCsv(text: string): SeriesPoint[] {
  const [head, ...rows] = text.split("\n").map(l => l.trim()).filter(l => Boolean(l) && !l.startsWith("#"));
  if (!head) throw new Error("series CSV has no header/data rows");
  const cols = head.split(",");
  const di = cols.indexOf("date"), vi = cols.indexOf("value");
  if (di === -1 || vi === -1) throw new Error(`series CSV missing date/value header; got: ${cols.join(",")}`);
  return rows.map(r => {
    const c = r.split(",");
    const date = (c[di] ?? "").trim();
    if (!date) throw new Error(`series CSV row has an empty date cell: "${r}"`);
    // The correlation join is an exact YYYY-MM-DD string match against the
    // factor dates, so a non-ISO date would silently never join (n=0). Reject
    // it at load time instead.
    if (!/^\d{4}-\d{2}-\d{2}$/.test(date)) {
      throw new Error(`series CSV row has a non-ISO (YYYY-MM-DD) date "${date}": "${r}"`);
    }
    const value = Number((c[vi] ?? "").trim());
    if (Number.isNaN(value)) throw new Error(`series CSV row has a non-numeric value: "${r}"`);
    return { date, value };
  });
}
