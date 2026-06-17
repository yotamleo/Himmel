import type { DashboardResult, DashboardRow } from "./analyze";

const DISCLAIMER =
  "> **This is not a diagnosis.** These are candidate associations surfaced for " +
  "review by the operator and clinicians. Correlation does not imply causation; " +
  "confounders are uncontrolled. `[inferred]`";

function fmt(n: number | null): string {
  return n === null ? "n/a" : (Math.round(n * 1000) / 1000).toString();
}

function row(r: DashboardRow): string {
  const mark = r.belowMinN ? "⚠ n<min" : r.fdrSurvivor ? "✓" : "·";
  return `| ${r.series} | ${r.factor} | ${r.bestLag >= 0 ? "+" : ""}${r.bestLag} | ${r.n} | ` +
    `${fmt(r.correlation)} | ${fmt(r.pValue)} | ${mark} | ${fmt(r.rateRatio)} |`;
}

/** Render the ranked correlation dashboard as a vault markdown note. Survivors
 *  (FDR-significant) sort first (analyze already ordered rows); the banner
 *  discloses the total comparison count so signals are not over-read. */
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
  ];
  return lines.join("\n");
}

export function dashboardJson(r: DashboardResult): string {
  return JSON.stringify(r, null, 2);
}
