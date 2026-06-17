import type { Signal } from "./correlate";

const DISCLAIMER =
  "> **This is not a diagnosis.** These are candidate associations surfaced for " +
  "review by the operator and clinicians. Correlation does not imply causation; " +
  "confounders are uncontrolled and multiple factors/lags tested elsewhere inflate " +
  "false-positive risk. `[inferred]`";

function fmt(n: number | null): string {
  return n === null ? "n/a" : (Math.round(n * 1000) / 1000).toString();
}

/**
 * Render candidate correlation signals as a vault "signals" markdown note,
 * ranked by absolute correlation (strongest first). Every note carries the
 * never-diagnose disclaimer and each signal's own caveats.
 */
export function formatSignalsNote(signals: Signal[]): string {
  const ranked = [...signals].sort(
    (a, b) => Math.abs(b.correlation ?? 0) - Math.abs(a.correlation ?? 0),
  );
  const lines: string[] = ["# Candidate health-factor signals", "", DISCLAIMER, ""];
  for (const s of ranked) {
    lines.push(`## ${s.series} × ${s.factor} (lag ${s.lagDays}d)`);
    lines.push("");
    lines.push(`- n=${s.n} (high-factor days: ${s.nHigh}, low: ${s.nLow})`);
    lines.push(`- rate (high vs low factor): ${fmt(s.rateHigh)} vs ${fmt(s.rateLow)} (ratio ${fmt(s.rateRatio)})`);
    lines.push(`- correlation: ${fmt(s.correlation)}`);
    if (s.belowMinN) lines.push(`- ⚠️ below min-n — treat as **not interpretable**.`);
    lines.push("");
    lines.push("Caveats:");
    for (const c of s.caveats) lines.push(`- ${c}`);
    lines.push("");
  }
  return lines.join("\n");
}
