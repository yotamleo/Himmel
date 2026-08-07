// scripts/lanes/funded-max-pct.mjs
// Pure parser for the LANE_FUNDED_MAX_PCT threshold used by bank-status.ts.
// Extracted (HIMMEL-1624) so the clamp is unit-testable: bank-status.ts is a
// bun-run CLI with import-time side effects, so it cannot be imported in a test.
//
// Number.isFinite alone accepts negatives (Number.isFinite(-1) === true), which
// made every live bank read "spent" once LANE_FUNDED_MAX_PCT went negative.
// Require a sane 0..100 value; fall back to the 99 default on anything else
// (non-numeric, empty, out of range).
export function parseFundedMaxPct(raw) {
  // Full-string Number() conversion, not parseFloat: parseFloat("50%") is 50
  // and parseFloat("0invalid") is 0, silently accepting junk a caller almost
  // certainly mistyped (CR round 2, HIMMEL-1624). Number("") is 0, so blank
  // input must fall to the default before conversion.
  const text = String(raw ?? "").trim();
  if (text === "") return 99;
  const n = Number(text);
  return Number.isFinite(n) && n >= 0 && n <= 100 ? n : 99;
}
