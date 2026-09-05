#!/usr/bin/env bun
/**
 * luna-correlate MCP server.
 *
 * Wraps the offline health-factor correlator as five MCP tools. Posture A is
 * preserved: only `factors.cache` (the gated bulk fetcher) touches the network —
 * Kp is a global date-only archive; location factors (pressure/pollen/aq) are a
 * country-level GRID fetch with NO PHI and NO operator coordinates. `series.load`,
 * `correlate`, `signals.report`, and `signals.dashboard` are fully offline. Outputs
 * are candidate signals only — never a diagnosis, never causation.
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  ListToolsRequestSchema,
  CallToolRequestSchema,
} from "@modelcontextprotocol/sdk/types.js";
import {
  factorsCacheLogic,
  seriesLoadLogic,
  correlateLogic,
  signalsReportLogic,
  signalsDashboardLogic,
} from "./src/mcp";
import type { DateRange } from "./src/fetchFactors";

export const TOOLS = [
  {
    name: "factors.cache",
    description:
      "Bulk-fetch a public factor dataset into the local cache (the ONLY network path). factor='kp' is the global, date-only GFZ Kp archive. factor='pressure'|'pollen'|'aq' fetch a country-level GRID over `region` (LUNA_REGION_BBOX) for `dateRange` from Open-Meteo — NO PHI and NO operator coordinates are ever sent.",
    inputSchema: {
      type: "object",
      properties: {
        factor: { type: "string", description: "Factor to cache: kp | pressure | pollen | aq." },
        region: {
          type: "string",
          description: "Location factors only. Region bbox 'lat_min,lon_min,lat_max,lon_max' (default: LUNA_REGION_BBOX). A whole-country grid — never the operator's point.",
        },
        dateRange: {
          type: "object",
          description: "Location factors only. {start,end} ISO YYYY-MM-DD date range to fetch.",
          properties: { start: { type: "string" }, end: { type: "string" } },
          required: ["start", "end"],
        },
      },
      required: ["factor"],
    },
  },
  {
    name: "series.load",
    description:
      "Load a local (offline) health/status series by name as generic (date,value) points. Resolves <dir or LUNA_SERIES_DIR>/<name>.csv (explicit dir wins). The series never leaves the machine.",
    inputSchema: {
      type: "object",
      properties: {
        name: { type: "string", description: "Series name, e.g. migraine, pain, sleep, stress." },
        dir: { type: "string", description: "Override the series dir (default: LUNA_SERIES_DIR)." },
      },
      required: ["name"],
    },
  },
  {
    name: "correlate",
    description:
      "Offline join of a named series against the cached factor at an optional day lag. Returns a candidate Signal (rates, correlation, caveats, below-min-n flag). Location factors resolve the operator's local date×place to the nearest cached grid cell first. Never asserts causation.",
    inputSchema: {
      type: "object",
      properties: {
        series: { type: "string", description: "Series name to load + correlate." },
        factor: { type: "string", description: "Factor name: kp | pressure | pollen | aq (default: kp)." },
        lag: { type: "number", description: "Lag in days (factor day d matches series day d+lag). Default 0." },
        dir: { type: "string", description: "Override the series dir." },
        location: { type: "string", description: "Location factors only. Path to the operator's local date,lat,lon CSV (default: LUNA_LOCATION_FILE). Stays local — never egressed." },
      },
      required: ["series"],
    },
  },
  {
    name: "signals.report",
    description:
      "Run a correlation and render the candidate-signal vault note (markdown with caveats + never-diagnose disclaimer). Writes to outPath when given; always returns the markdown.",
    inputSchema: {
      type: "object",
      properties: {
        series: { type: "string", description: "Series name to load + correlate." },
        factor: { type: "string", description: "Factor name: kp | pressure | pollen | aq (default: kp)." },
        lag: { type: "number", description: "Lag in days. Default 0." },
        dir: { type: "string", description: "Override the series dir." },
        location: { type: "string", description: "Location factors only. Path to the operator's local date,lat,lon CSV (default: LUNA_LOCATION_FILE)." },
        outPath: { type: "string", description: "Optional path to write the markdown note to." },
      },
      required: ["series"],
    },
  },
  {
    name: "signals.dashboard",
    description:
      "Lag-swept, FDR-ranked correlation dashboard over multiple series × factors. Offline by default: kp/lunar_phase/daylight need no location or network. pressure/aq/pollen are opt-in (require a populated cache + LUNA_LOCATION_FILE). Writes dashboard.md + dashboard.json to outDir (or LUNA_SIGNALS_DIR). Returns markdown + paths + survivorCount.",
    inputSchema: {
      type: "object",
      properties: {
        seriesNames: {
          type: "array", items: { type: "string" },
          description: "Series names to correlate (default: sleep_hours, rhr_bpm, hrv_ms). sleep_hours and rhr_bpm are era-split at the Fitbit→Galaxy boundary.",
        },
        factors: {
          type: "array", items: { type: "string" },
          description: "Factor names to correlate against (default: kp, lunar_phase, daylight). Add pressure|pollen|aq when cache + location are ready.",
        },
        lagWindow: { type: "number", description: "Lag sweep ±N days (default: 3)." },
        minN: { type: "number", description: "Minimum overlapping days for a row to be included in FDR (default: 20)." },
        fdrQ: { type: "number", description: "Benjamini-Hochberg FDR q threshold (default: 0.1)." },
        region: { type: "string", description: "Region bbox 'lat_min,lon_min,lat_max,lon_max' for the daylight centroid-lat (default: LUNA_REGION_BBOX)." },
        location: { type: "string", description: "Location factors only. Path to the operator's local date,lat,lon CSV (default: LUNA_LOCATION_FILE)." },
        dir: { type: "string", description: "Override the series dir (default: LUNA_SERIES_DIR)." },
        outDir: { type: "string", description: "Directory to write dashboard.md + dashboard.json (default: LUNA_SIGNALS_DIR)." },
      },
      required: [],
    },
  },
] as const;

type Args = Record<string, unknown>;

// MCP arguments are caller-controlled JSON and the SDK does NOT validate them
// against inputSchema before dispatch, so validate the primitives here rather
// than blind-casting (a `lag:"2"` cast to number would silently NaN the join).
function str(v: unknown, field: string): string {
  if (typeof v !== "string") throw new Error(`"${field}" must be a string`);
  return v;
}
function optStr(v: unknown, field: string): string | undefined {
  return v === undefined ? undefined : str(v, field);
}
function optNum(v: unknown, field: string): number | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "number" || Number.isNaN(v)) throw new Error(`"${field}" must be a number`);
  return v;
}
function optDateRange(v: unknown, field: string): DateRange | undefined {
  if (v === undefined) return undefined;
  if (typeof v !== "object" || v === null) throw new Error(`"${field}" must be an object {start,end}`);
  const o = v as Record<string, unknown>;
  return { start: str(o.start, `${field}.start`), end: str(o.end, `${field}.end`) };
}
function optStrArr(v: unknown, field: string): string[] | undefined {
  if (v === undefined) return undefined;
  if (!Array.isArray(v)) throw new Error(`"${field}" must be a string array`);
  return v.map((item, i) => str(item, `${field}[${i}]`));
}

export async function callTool(name: string, args: Args): Promise<unknown> {
  switch (name) {
    case "factors.cache":
      return factorsCacheLogic({
        factor: str(args.factor, "factor"),
        region: optStr(args.region, "region"),
        dateRange: optDateRange(args.dateRange, "dateRange"),
      });
    case "series.load":
      return seriesLoadLogic({ name: str(args.name, "name"), dir: optStr(args.dir, "dir") });
    case "correlate":
      return correlateLogic({
        series: str(args.series, "series"),
        factor: optStr(args.factor, "factor"),
        lag: optNum(args.lag, "lag"),
        dir: optStr(args.dir, "dir"),
        location: optStr(args.location, "location"),
      });
    case "signals.report":
      return signalsReportLogic({
        series: str(args.series, "series"),
        factor: optStr(args.factor, "factor"),
        lag: optNum(args.lag, "lag"),
        dir: optStr(args.dir, "dir"),
        location: optStr(args.location, "location"),
        outPath: optStr(args.outPath, "outPath"),
      });
    case "signals.dashboard":
      return signalsDashboardLogic({
        seriesNames: optStrArr(args.seriesNames, "seriesNames"),
        factors: optStrArr(args.factors, "factors"),
        lagWindow: optNum(args.lagWindow, "lagWindow"),
        minN: optNum(args.minN, "minN"),
        fdrQ: optNum(args.fdrQ, "fdrQ"),
        region: optStr(args.region, "region"),
        location: optStr(args.location, "location"),
        dir: optStr(args.dir, "dir"),
        outDir: optStr(args.outDir, "outDir"),
      });
    default:
      throw new Error(`unknown tool: ${name}`);
  }
}

const mcp = new Server(
  { name: "luna-correlate", version: "0.2.0" },
  {
    capabilities: { tools: {} },
    instructions: [
      "luna-correlate surfaces CANDIDATE associations between local health/status series and external factors. It never diagnoses and never asserts causation — every output carries caveats for the operator and clinicians to interpret.",
      "",
      "Posture A: only `factors.cache` touches the network. Kp is a generic global date-only fetch; location factors (pressure/pollen/aq) are a country-level GRID fetch — no PHI and no operator coordinates. `series.load`, `correlate`, `signals.report`, and `signals.dashboard` are fully offline; location factors meet the operator's local date×place only inside the offline proximity index.",
      "",
      "Kp flow: factors.cache({factor:'kp'}) once → correlate({series:'migraine', lag:1}).",
      "Location flow: factors.cache({factor:'pressure', region:'47,5,55,15', dateRange:{start,end}}) → correlate({series:'migraine', factor:'pressure', lag:1, location:'…/places.csv'}).",
      "Dashboard: signals.dashboard({seriesNames, factors, outDir}) runs a lag-swept, BH-FDR-ranked multi-series correlation and writes dashboard.md + dashboard.json — fully offline for kp/lunar_phase/daylight (no factors.cache needed).",
    ].join("\n"),
  },
);

mcp.setRequestHandler(ListToolsRequestSchema, async () => ({ tools: TOOLS }));

mcp.setRequestHandler(CallToolRequestSchema, async req => {
  try {
    const out = await callTool(req.params.name, (req.params.arguments ?? {}) as Args);
    return { content: [{ type: "text", text: JSON.stringify(out, null, 2) }] };
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    return { content: [{ type: "text", text: `${req.params.name} failed: ${msg}` }], isError: true };
  }
});

if (import.meta.main) {
  await mcp.connect(new StdioServerTransport());

  // Exit cleanly when Claude Code closes the MCP connection (stdin EOF), so the
  // bun process doesn't linger as a zombie.
  let shuttingDown = false;
  const shutdown = (): void => {
    if (shuttingDown) return;
    shuttingDown = true;
    process.exit(0);
  };
  process.stdin.on("end", shutdown);
  process.stdin.on("close", shutdown);
  process.on("SIGTERM", shutdown);
  process.on("SIGINT", shutdown);
}
