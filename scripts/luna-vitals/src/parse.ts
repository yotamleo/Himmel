import type { ExtractedRow } from "./types";

const ISO = /^\d{4}-\d{2}-\d{2}$/;
const num = (s: string): number | null => {
  const t = s.trim(); if (!t) return null;
  const n = Number(t); return Number.isFinite(n) ? n : null;
};

export function parseStructured(
  text: string,
  opts: { source: string; metrics: string[]; noteDate?: string },
): ExtractedRow[] {
  const { source, metrics, noteDate } = opts;
  const want = new Set(metrics);
  const rows: ExtractedRow[] = [];
  const lines = text.split("\n");

  const cells = (l: string): string[] => l.split("|").map(c => c.trim()).filter((_, i, a) => i > 0 && i < a.length - 1);

  // (a) markdown table with a `date` column + metric columns. Header detection
  // guards against a prose/bullet line that merely contains a pipe and "date":
  // require the literal lowercase word `date`, at least two pipe-delimited cells,
  // and that the line is not a `-`/`*` bullet.
  const headerIdx = lines.findIndex(
    l => !/^\s*[-*]\s/.test(l) && /\bdate\b/.test(l) && cells(l).length >= 2,
  );
  if (headerIdx !== -1) {
    const header = cells(lines[headerIdx]).map(h => h.toLowerCase());
    const di = header.indexOf("date");
    if (di !== -1) {
      // A well-formed table has a `|---|` separator at headerIdx+1; some notes omit
      // it. Start at +2 when the separator is present, +1 when absent, so the first
      // data row is never silently dropped.
      const sep = lines[headerIdx + 1];
      const start = headerIdx + (sep !== undefined && /^\s*\|[\s\-:|]+\|/.test(sep) ? 2 : 1);
      for (let i = start; i < lines.length && lines[i].includes("|"); i++) {
        const c = cells(lines[i]);
        const date = (c[di] ?? "").trim();
        if (!ISO.test(date)) continue;
        header.forEach((h, j) => {
          if (j === di || !want.has(h)) return;
          const v = num(c[j] ?? "");
          if (v !== null) rows.push({ metric: h, date, value: v, source });
        });
      }
    }
  }

  for (const raw of lines) {
    const line = raw.trim();
    // (c) dated bullet: "- YYYY-MM-DD metric value"
    const b = line.match(/^[-*]\s*(\d{4}-\d{2}-\d{2})\s+(\w+)\s+(-?\d+(?:\.\d+)?)\s*$/);
    if (b && want.has(b[2])) { rows.push({ metric: b[2], date: b[1], value: Number(b[3]), source }); continue; }
    // (b) inline field "metric:: value" or "metric: value" anchored to noteDate
    const f = line.match(/^(\w+)::?\s*(-?\d+(?:\.\d+)?)\s*$/);
    if (f && want.has(f[1]) && noteDate && ISO.test(noteDate)) {
      rows.push({ metric: f[1], date: noteDate, value: Number(f[2]), source });
    }
  }
  return rows;
}
