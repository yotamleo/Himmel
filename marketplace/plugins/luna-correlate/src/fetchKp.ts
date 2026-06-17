import { parseKpAuto, KP_CACHE } from "./kp";
// GFZ Potsdam Kp index — CC BY 4.0, public, no auth, no PHI, date-only join.
// Rubric verdict: ADOPT. See README.md for full vetting record.
const KP_URL = "https://kp.gfz.de/app/files/Kp_ap_Ap_SN_F107_since_1932.txt";
export async function fetchKpToCache(opts: { fetchImpl?: typeof fetch } = {}): Promise<number> {
  const f = opts.fetchImpl ?? fetch;
  console.error(`[luna-correlate] FETCH Kp (global, no PHI/location): ${KP_URL}`);
  const res = await f(KP_URL);
  if (!res.ok) throw new Error(`[luna-correlate] Kp fetch failed: HTTP ${res.status}`);
  const text = await res.text();
  const pts = parseKpAuto(text);
  // A non-empty body that parses to zero points means the archive format drifted
  // (or detection misrouted). Caching [] would silently degrade every later
  // correlation to a meaningless n=0 "no signal" — fail loudly instead.
  if (text.trim().length > 0 && pts.length === 0) {
    throw new Error(
      `[luna-correlate] Kp parse produced 0 points from ${text.length} bytes — ` +
      `archive format may have changed (expected GFZ Kp_ap_Ap_SN_F107 layout)`,
    );
  }
  await Bun.write(KP_CACHE, JSON.stringify(pts));
  console.error(`[luna-correlate] cached ${pts.length} Kp points -> ${KP_CACHE}`);
  return pts.length;
}

// Run the live fetch when invoked directly (`bun run src/fetchKp.ts`); importing
// the module (tests, MCP server) only loads the export.
if (import.meta.main) await fetchKpToCache();
