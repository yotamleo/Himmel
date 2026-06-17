import { parseSeriesCsv } from "./series";
import { parseKpAuto, KP_CACHE, type KpPoint } from "./kp";
import { correlate } from "./correlate";
import type { FactorPoint, Signal } from "./correlate";

// This CLI is the manual Kp path; location factors go through the MCP. Map the
// {date,kp} cache shape to the generic {date,value} factor and keep the Kp split
// at 5 / the "Kp-index" label so output matches the MCP correlate.
const KP_OPTS = { highThreshold: 5, factorLabel: "Kp-index" };
const kpToFactor = (kp: KpPoint[]): FactorPoint[] => kp.map(p => ({ date: p.date, value: p.kp }));

/**
 * runCorrelate: testable helper — reads both files explicitly (no cache dep).
 * seriesPath: path to date,value CSV
 * kpPath: path to Kp text file (simplified fixture OR real GFZ format — auto-detected)
 * lagDays: shift factor by N days (factor d matches series d+lagDays)
 */
export async function runCorrelate(seriesPath: string, kpPath: string, lagDays: number): Promise<Signal> {
  const seriesTxt = await Bun.file(seriesPath).text();
  const kpTxt = await Bun.file(kpPath).text();
  const series = parseSeriesCsv(seriesTxt);
  const factor = parseKpAuto(kpTxt);
  return correlate(series, kpToFactor(factor), lagDays, KP_OPTS);
}

async function main(): Promise<void> {
  const args = process.argv.slice(2);
  if (args[0] !== "correlate" || args.length < 3) {
    console.error("Usage: bun run src/cli.ts correlate <seriesCsvPath> <lagDays>");
    console.error("  Run `bun run src/fetchKp.ts` first to populate the Kp cache.");
    process.exit(1);
  }
  const [, seriesPath, lagStr] = args;
  const lagDays = parseInt(lagStr, 10);
  if (Number.isNaN(lagDays)) {
    console.error(`[luna-correlate] ERROR: lagDays must be an integer; got: ${lagStr}`);
    process.exit(1);
  }

  // Check cache exists
  const cacheFile = Bun.file(KP_CACHE);
  if (!(await cacheFile.exists())) {
    console.error(`[luna-correlate] ERROR: Kp cache not found at ${KP_CACHE}`);
    console.error("  Run: bun run src/fetchKp.ts");
    process.exit(1);
  }

  const seriesTxt = await Bun.file(seriesPath).text();
  const kpJson = await cacheFile.text();
  const series = parseSeriesCsv(seriesTxt);
  const factor = JSON.parse(kpJson) as KpPoint[];
  const signal = correlate(series, kpToFactor(factor), lagDays, KP_OPTS);
  console.log(JSON.stringify(signal, null, 2));
}

// Only run main when this file is the entry point (not imported in tests)
if (import.meta.main) {
  await main();
}
