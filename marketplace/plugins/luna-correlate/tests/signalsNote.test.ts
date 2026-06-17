import { test, expect } from "bun:test";
import { formatSignalsNote } from "../src/signalsNote";
import type { Signal } from "../src/correlate";

const sig: Signal = {
  series: "migraine", factor: "Kp-index", lagDays: 1,
  n: 25, nHigh: 5, nLow: 20,
  rateHigh: 0.6, rateLow: 0.2, rateRatio: 3,
  correlation: 0.42, caveats: ["Candidate signal only — correlation does not imply causation.", "n=25."],
  belowMinN: false,
};

test("formatSignalsNote renders factor, n, and the candidate caveats", () => {
  const md = formatSignalsNote([sig]);
  expect(md).toContain("Kp-index");
  expect(md).toContain("migraine");
  expect(md).toContain("n=25");
  expect(md).toContain("correlation does not imply causation");
});

test("formatSignalsNote always carries a never-diagnose disclaimer", () => {
  const md = formatSignalsNote([sig]);
  expect(md.toLowerCase()).toContain("not a diagnosis");
});

test("formatSignalsNote flags a below-min-n signal as not interpretable", () => {
  const md = formatSignalsNote([{ ...sig, n: 3, belowMinN: true }]);
  expect(md.toLowerCase()).toContain("below");
});
