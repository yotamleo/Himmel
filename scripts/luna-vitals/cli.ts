import { parseStructured } from "./src/parse";
import { mergeRows } from "./src/merge";
import { writeSeries } from "./src/writeSeries";
import { readArtifact, writeArtifact, type ExtractedRow, type ReviewArtifact } from "./src/types";

const DEFAULT_METRICS = ["migraine", "skin_flare", "sleep_hours", "hrv_ms", "rhr_bpm"];

function flag(args: string[], name: string): string | undefined {
  const i = args.lastIndexOf(`--${name}`);
  return i !== -1 && i + 1 < args.length ? args[i + 1] : undefined;
}

async function main(): Promise<void> {
  const [cmd, ...rest] = process.argv.slice(2);
  const metrics = (flag(rest, "metrics") ?? DEFAULT_METRICS.join(",")).split(",").map(s => s.trim()).filter(Boolean);
  if (cmd === "parse") {
    const file = rest[0];
    const out = flag(rest, "out");
    if (!file || file.startsWith("--") || !out) { console.error("usage: parse <file> --out <artifact.json> [--note-date YYYY-MM-DD]"); process.exit(1); }
    const f = Bun.file(file);
    if (!(await f.exists())) { console.error(`[luna-vitals] error: input file not found: ${file}`); process.exit(1); }
    const text = await f.text();
    const rows = parseStructured(text, { source: file, metrics, noteDate: flag(rest, "note-date") });
    await writeArtifact(out, { bucket: file, rows, conflicts: [] });
    console.error(`[luna-vitals] parsed ${rows.length} rows -> ${out}`);
  } else if (cmd === "merge") {
    // Inputs are routed into two pools: deterministic-parser artifacts (after --det)
    // and LLM artifacts (after --llm, the default). mergeRows applies deterministic-wins
    // precedence between them — collapsing both into one pool would defeat it.
    const out = flag(rest, "out");
    // Fail fast on a missing --out BEFORE ingesting inputs — otherwise a forgotten
    // --out makes the would-be output path get read as an input artifact, surfacing
    // a confusing parse error instead of the usage message.
    if (!out) { console.error("usage: merge [--det <det.json>...] [--llm <llm.json>...] --out <merged.json>"); process.exit(1); }
    const det: ExtractedRow[] = [];
    const llm: ExtractedRow[] = [];
    const buckets: string[] = [];
    const valueFlags = new Set(["out", "metrics", "note-date", "dir"]);
    let pool: ExtractedRow[] = llm; // bare positional inputs default to the LLM pool
    for (let i = 0; i < rest.length; i++) {
      const a = rest[i];
      if (a === "--det") { pool = det; continue; }
      if (a === "--llm") { pool = llm; continue; }
      if (a.startsWith("--")) { if (valueFlags.has(a.slice(2))) i++; continue; }
      if (a.endsWith(".json") && a !== out) {
        const art = await readArtifact(a);
        pool.push(...art.rows);
        buckets.push(art.bucket);
      }
    }
    if (!det.length && !llm.length) { console.error("usage: merge [--det <det.json>...] [--llm <llm.json>...] --out <merged.json> (no input artifacts found)"); process.exit(1); }
    const uniq = [...new Set(buckets)];
    const bucket = uniq.length === 1 ? uniq[0] : `merged(${uniq.join(",")})`;
    await writeArtifact(out, mergeRows({ deterministic: det, llm, bucket }));
    console.error(`[luna-vitals] merged ${det.length} deterministic + ${llm.length} llm rows -> ${out}`);
  } else if (cmd === "write") {
    const file = rest[0];
    const dir = flag(rest, "dir");
    if (!file || !dir) { console.error("usage: write <artifact.json> --dir <50-Vitals>"); process.exit(1); }
    const res = await writeSeries(await readArtifact(file), dir);
    for (const r of res) console.error(`[luna-vitals] ${r.metric}: ${r.n} rows -> ${r.path}`);
  } else {
    console.error(`unknown command: ${cmd ?? "(none)"} — use parse|merge|write`);
    process.exit(1);
  }
}

if (import.meta.main) {
  main().catch(err => {
    // Surface failures as a clear message + non-zero exit so a caller (e.g. the
    // extraction skill checking `exited === 0`) never mistakes an error for success.
    console.error(`[luna-vitals] fatal: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  });
}
