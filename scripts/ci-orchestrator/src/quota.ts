// scripts/ci-orchestrator/src/quota.ts
// HIMMEL-502 P2.5 — private-minute headroom predicate (corrected — B1).
//
// PURE headroom test over GitHub billing-API usage. The usage numbers come from
// the GitHub billing API (/users/{user}/settings/billing/actions — the same
// source as P0's measure.sh), fetched by an INJECTED fetchUsage() so the function
// stays hermetic. It does NOT read quota-gauge.jsonl — that ledger holds LLM-
// provider quota only and has no GHA-minutes signal (B1). Writing CI *spend* into
// the cross-lane gauge for Mission-Control visibility is a DEFERRED fold-in (it
// needs a real Lane-union extension; do NOT shim it via lane:"claude").
export type MinutesUsage = { includedMinutesUsed: number; includedMinutes: number };

// Below the 70%-of-cap target → headroom. A zero/absent cap yields no headroom
// (conservative: we never claim headroom we can't prove).
export const HEADROOM_TARGET = 0.7;

export function hasPrivateHeadroom(usage: MinutesUsage): boolean {
  if (!(usage.includedMinutes > 0)) return false;
  return usage.includedMinutesUsed / usage.includedMinutes < HEADROOM_TARGET;
}

// The raw GitHub billing/actions response (the fields we consume).
export type BillingActionsResponse = { total_minutes_used: number; included_minutes: number };

// Thin wrapper mapping the billing response → MinutesUsage. `fetchRaw` is injected
// (the real caller passes a `gh api ...` fetch) so this stays hermetic/testable.
export async function getUsage(fetchRaw: () => Promise<BillingActionsResponse>): Promise<MinutesUsage> {
  const r = await fetchRaw();
  return { includedMinutesUsed: r.total_minutes_used, includedMinutes: r.included_minutes };
}
