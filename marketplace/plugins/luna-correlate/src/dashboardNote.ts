import type { DashboardResult, DashboardRow } from "./analyze";

const DISCLAIMER =
  "> **This is not a diagnosis.** These are candidate associations surfaced for " +
  "review by the operator and clinicians. Correlation does not imply causation; " +
  "confounders are uncontrolled. `[inferred]`";

// Max signals drawn on the lag-profile chart — survivors first, then the
// strongest remaining by |r|. Past a handful the line chart turns to spaghetti.
const LAG_CHART_MAX = 4;

function fmt(n: number | null): string {
  return n === null ? "n/a" : (Math.round(n * 1000) / 1000).toString();
}

// p-values can be far below the table's 3-decimal resolution; rounding them to
// "0" reads as "exactly zero" (impossible) and hides the strongest signals. Show
// "<0.001" instead so a tiny p is legible without faking precision.
function fmtP(p: number | null): string {
  if (p === null) return "n/a";
  // p >= 0 (not > 0) so an exact 0 — which pearsonPValue returns at r = ±1 — also
  // renders "<0.001" rather than the misleading "0".
  if (p >= 0 && p < 0.001) return "<0.001";
  return (Math.round(p * 1000) / 1000).toString();
}

function row(r: DashboardRow): string {
  const mark = r.belowMinN ? "⚠ n<min" : r.fdrSurvivor ? "✓" : "·";
  return `| ${r.series} | ${r.factor} | ${r.bestLag >= 0 ? "+" : ""}${r.bestLag} | ${r.n} | ` +
    `${fmt(r.correlation)} | ${fmtP(r.pValue)} | ${mark} | ${fmt(r.rateRatio)} |`;
}

// JSON-quote a chart label/title so commas, parentheses, and "×" stay one token
// inside the YAML flow sequence the Charts plugin parses.
function q(s: string): string {
  return JSON.stringify(s);
}

const r3 = (n: number): number => Math.round(n * 1000) / 1000;
const pairLabel = (r: DashboardRow): string => `${r.series} × ${r.factor}`;

/** Ranked horizontal bar of |r| across interpretable pairs, FDR-survivors marked
 *  with ✓. Renders via the Obsidian Charts community plugin; degrades to a plain
 *  code block if the plugin is absent (acceptable per operator choice). */
function rankedBarChart(rows: DashboardRow[]): string[] {
  const interp = rows.filter(r => !r.belowMinN && r.correlation !== null);
  if (interp.length === 0) return [];
  const labels = interp.map(r => `${r.fdrSurvivor ? "✓ " : ""}${pairLabel(r)}`);
  const data = interp.map(r => r3(Math.abs(r.correlation as number)));
  return [
    "## |r| ranked across interpretable pairs (✓ = FDR survivor)",
    "```chart",
    "type: bar",
    "indexAxis: y",
    "beginAtZero: true",
    "width: 80%",
    `labels: [${labels.map(q).join(", ")}]`,
    "series:",
    `  - title: ${q("|r| (best lag)")}`,
    `    data: [${data.join(", ")}]`,
    "```",
    "",
  ];
}

/** Per-signal lag profile: r across the swept window for the top signals. A real
 *  association peaks at one lag; a flat or ragged profile flags that the reported
 *  best-lag may be selection noise — the most diagnostic view of the dashboard. */
function lagProfileChart(rows: DashboardRow[]): string[] {
  const interp = rows.filter(r => !r.belowMinN && r.correlation !== null && r.lagProfile.length > 0);
  if (interp.length === 0) return [];
  const top = interp.slice(0, LAG_CHART_MAX);
  const lags = top[0].lagProfile.map(e => e.lag);
  const labels = lags.map(l => (l >= 0 ? `+${l}` : `${l}`));
  const series = top.map(r => {
    const data = r.lagProfile.map(e => (e.r === null ? "null" : r3(e.r)));
    return [`  - title: ${q(pairLabel(r))}`, `    data: [${data.join(", ")}]`];
  });
  return [
    "## Lag profiles — r across the swept window (top signals)",
    "> A real association peaks at one lag; a flat/ragged profile suggests the " +
      "reported best-lag is selection noise rather than a true peak.",
    "```chart",
    "type: line",
    `labels: [${labels.map(q).join(", ")}]`,
    "series:",
    ...series.flat(),
    "```",
    "",
  ];
}

/** Render the ranked correlation dashboard as a vault markdown note. Survivors
 *  (FDR-significant) sort first (analyze already ordered rows); the banner
 *  discloses the total comparison count so signals are not over-read. The table
 *  stays primary; the charts augment it (and degrade to code blocks if the
 *  Obsidian Charts plugin is absent). */
export function formatDashboard(r: DashboardResult): string {
  const lines: string[] = [
    "# Candidate health-factor signals — dashboard",
    "",
    DISCLAIMER,
    "",
    `**${r.testCount} comparisons** run (${r.pairCount} era-split series×factor pairs × ${r.lagCount} lags). ` +
      `${r.familySize} pairs met min-n and entered **BH-FDR q=${r.fdrQ}** → **${r.survivorCount} survived**. ` +
      `BH controls the false-discovery rate among survivors to ≤${Math.round(r.fdrQ * 100)}% ` +
      `(expected false discoveries ≲ ${Math.round(r.survivorCount * r.fdrQ * 10) / 10}).`,
    "",
    "> Caveat: the reported lag is the **best of the swept window** per pair " +
      "(best-lag selection inflates apparent significance) — treat survivors as " +
      "candidates to investigate, not confirmed associations. Device series are " +
      "split at the Fitbit→Galaxy sensor boundary and correlated within an era.",
    "",
    "| series | factor | best-lag (d) | n | r | p | FDR | rate-ratio |",
    "|---|---|---|---|---|---|---|---|",
    ...r.rows.map(row),
    "",
    ...rankedBarChart(r.rows),
    ...lagProfileChart(r.rows),
  ];
  return lines.join("\n");
}

export function dashboardJson(r: DashboardResult): string {
  return JSON.stringify(r, null, 2);
}
