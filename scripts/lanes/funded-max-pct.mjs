// scripts/lanes/funded-max-pct.mjs
// The ONE refuse/funded threshold for the codex weekly bank, shared by
// bank-status.ts (funded verdict) and spawn-claudex.ts (dispatch preflight).
// HIMMEL-1700: they used to default to 99 and 90, so at 90-98 % /lanes said
// "funded" while the dispatcher refused. 90 is the dispatcher's refuse point
// (the value that actually protects a worker from dying mid-run), so it wins.
// Extracted (HIMMEL-1624) so the clamp is unit-testable: bank-status.ts is a
// bun-run CLI with import-time side effects, so it cannot be imported in a test.
//
// Number.isFinite alone accepts negatives (Number.isFinite(-1) === true), which
// made every live bank read "spent" once LANE_FUNDED_MAX_PCT went negative.
// Require a sane 0..100 value; fall back to the default on anything else
// (non-numeric, empty, out of range).
export const DEFAULT_FUNDED_MAX_PCT = 90;

export function parseFundedMaxPct(raw, fallback = DEFAULT_FUNDED_MAX_PCT) {
  // Full-string Number() conversion, not parseFloat: parseFloat("50%") is 50
  // and parseFloat("0invalid") is 0, silently accepting junk a caller almost
  // certainly mistyped (CR round 2, HIMMEL-1624). Number("") is 0, so blank
  // input must fall to the default before conversion.
  const text = String(raw ?? "").trim();
  if (text === "") return fallback;
  const n = Number(text);
  return Number.isFinite(n) && n >= 0 && n <= 100 ? n : fallback;
}

// LANE_FUNDED_MAX_PCT wins; CLAUDEX_BANK_REFUSE_PCT (documented in .env.example
// and docs/configuration.md) stays a working alias so an existing pin keeps
// moving both consumers together; an invalid value falls through to the next.
export function resolveFundedMaxPct(env) {
  const alias = parseFundedMaxPct(env.CLAUDEX_BANK_REFUSE_PCT);
  return parseFundedMaxPct(env.LANE_FUNDED_MAX_PCT, alias);
}
