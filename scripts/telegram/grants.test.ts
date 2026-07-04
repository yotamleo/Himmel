import { expect, test } from "bun:test";
import { parseGrantFlag, validateGrantSpec, classifyShape, composeGrantLine, nextGrantId, authorityGate, carryGrants, composeCarriedGrantLine, seedCarriedGrants, type CarriedGrant } from "./grants";

test("T2 validateGrantSpec: enum, ttl/uses, anchor, no unbounded prefix", () => {
  expect(validateGrantSpec({ arm: "gh", pattern: "gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)", ttlMins: 60, maxUses: 1 }).ok).toBe(true);
  expect(validateGrantSpec({ arm: "bogus", pattern: "gh[[:space:]]+api", ttlMins: 60, maxUses: 1 }).ok).toBe(false);      // unknown arm
  expect(validateGrantSpec({ arm: "gh", pattern: ".*", ttlMins: 60, maxUses: 1 }).ok).toBe(false);                        // unbounded .* (F2)
  expect(validateGrantSpec({ arm: "gh", pattern: "git[[:space:]]+status", ttlMins: 60, maxUses: 1 }).ok).toBe(false);     // cross-arm smuggle
  expect(validateGrantSpec({ arm: "git-push", pattern: "git[[:space:]]+status", ttlMins: 60, maxUses: 1 }).ok).toBe(false); // F8: no push token
  expect(validateGrantSpec({ arm: "git-push", pattern: "git([[:space:]]+-[a-z-]+)*[[:space:]]+push([[:space:]]|$)", ttlMins: 60, maxUses: 1 }).ok).toBe(true);
  expect(validateGrantSpec({ arm: "gh", pattern: "gh[[:space:]]+api", ttlMins: 0, maxUses: 1 }).ok).toBe(false);          // ttl<=0
  expect(validateGrantSpec({ arm: "gh", pattern: "gh[[:space:]]+api", ttlMins: 60, maxUses: 0 }).ok).toBe(false);         // uses<=0
});

test("T1-helper parseGrantFlag: defaults + malformed", () => {
  const g = parseGrantFlag("gh|gh[[:space:]]+api[[:space:]]+repos/o/r/pulls([[:space:]]|$)");
  expect(g.ok).toBe(true); if (g.ok) { expect(g.spec.ttlMins).toBe(60); expect(g.spec.maxUses).toBe(1); }
  expect(parseGrantFlag("gh|.*|30|2").ok).toBe(false);   // fails validity gate
  expect(parseGrantFlag("").ok).toBe(false);
  expect(parseGrantFlag("gh").ok).toBe(false);           // no pattern field
});

test("T3 classifyShape: gh api GET vs write; non-gh arms always write", () => {
  expect(classifyShape("gh", "gh api repos/o/r/pulls/42")).toBe("read");            // default method
  expect(classifyShape("gh", "gh api repos/o/r/pulls/42 -X GET")).toBe("read");
  expect(classifyShape("gh", "gh api repos/o/r/pulls --method GET")).toBe("read");
  expect(classifyShape("gh", "gh api repos/o/r/issues -f title=x")).toBe("write");  // body flag
  expect(classifyShape("gh", "gh api repos/o/r -X POST")).toBe("write");
  expect(classifyShape("gh", "gh release view v1")).toBe("read");
  expect(classifyShape("git-push", "git push origin x")).toBe("write");
  expect(classifyShape("network", "curl https://x")).toBe("write");
});

test("T4 authorityGate: autonomous refuses write", () => {
  expect(authorityGate("read", true)).toEqual({ action: "grant" });
  expect(authorityGate("write", true)).toEqual({ action: "pending-escalation" });
  expect(authorityGate("write", false)).toEqual({ action: "grant" });
});

test("T6 composeGrantLine: all required fields + unique ids", () => {
  const now = new Date("2026-07-03T18:30:04.210Z");
  const spec = { arm: "gh", pattern: "gh[[:space:]]+api[[:space:]]+repos/o/r/pulls/[0-9]+([[:space:]]|$)", ttlMins: 30, maxUses: 3 } as const;
  const line = composeGrantLine(spec, { capability: "gh api repos/o/r/pulls/N", grantId: "g1", grantedBy: "operator", now });
  const j = JSON.parse(line);
  expect(j.type).toBe("grant"); expect(j.grant_id).toBe("g1"); expect(j.arm).toBe("gh");
  expect(j.pattern).toBe(spec.pattern); expect(j.shape).toBe("read"); expect(j.max_uses).toBe(3);
  expect(j.granted_by).toBe("operator"); expect(typeof j.expires_at).toBe("string"); expect(typeof j.ts).toBe("string");
  expect(nextGrantId([line])).toBe("g2");
  expect(nextGrantId([])).toBe("g1");
});

test("git-url anchor accepts the canonical set-url + config...url shapes (CR gap)", () => {
  expect(validateGrantSpec({ arm: "git-url", pattern: "git[[:space:]]+remote[[:space:]]+set-url", ttlMins: 60, maxUses: 1 }).ok).toBe(true);
  expect(validateGrantSpec({ arm: "git-url", pattern: "git[[:space:]]+config[[:space:]]+remote.origin.url", ttlMins: 60, maxUses: 1 }).ok).toBe(true);
  expect(validateGrantSpec({ arm: "git-url", pattern: "git[[:space:]]+status", ttlMins: 60, maxUses: 1 }).ok).toBe(false); // no url token -> rejected
});

test("classifyShape: lowercase -x method (pattern form) classifies write, not read (CR gap)", () => {
  // grant patterns target the hook's LOWERCASED grammar, so -x must be case-insensitive
  expect(classifyShape("gh", "gh[[:space:]]+api[[:space:]]+repos/o/r[[:space:]]+-x[[:space:]]+put")).toBe("write");
  expect(classifyShape("gh", "gh[[:space:]]+api[[:space:]]+repos/o/r[[:space:]]+-x[[:space:]]+get")).toBe("read");
});

// ── HIMMEL-682: respawn grant carry-forward (Task L1) ──────────────────────
const GH_READ = "gh[[:space:]]+api[[:space:]]+repos/o/r([[:space:]]|$)";
const GP_WRITE = "git([[:space:]]+-[a-z-]+)*[[:space:]]+push([[:space:]]|$)";
const FAR = "2999-01-01T00:00:00Z";
const CNOW = new Date("2026-07-04T09:00:00Z");
// grant() sets shape:"read" DELIBERATELY so the git-push case proves carryGrants
// RE-DERIVES shape from arm+pattern (anti-spoof) rather than trusting the field.
const grant = (o: Record<string, unknown>) => JSON.stringify({ type: "grant", capability: "cap", shape: "read", granted_by: "operator", ts: "2026-07-03T18:00:00Z", ...o });
const consumption = (id: string) => JSON.stringify({ type: "consumption", grant_id: id, ts: "2026-07-03T18:00:00Z" });

test("BT1 carryGrants: surviving read grant → absolute expires_at + full remaining", () => {
  const out = carryGrants([grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 3 })], CNOW);
  expect(out.length).toBe(1);
  expect(out[0].expiresAt).toBe(FAR);   // ORIGINAL absolute, not restarted
  expect(out[0].remaining).toBe(3);
  expect(out[0].shape).toBe("read");
});

test("BT2 carryGrants: remaining = max_uses − consumptions; exhausted dropped", () => {
  const out = carryGrants([
    grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 3 }),
    grant({ grant_id: "g2", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 1 }),
    consumption("g1"),  // g1 → remaining 2
    consumption("g2"),  // g2 → exhausted, dropped
  ], CNOW);
  expect(out.length).toBe(1);
  expect(out[0].remaining).toBe(2);
  expect(out[0].expiresAt).toBe(FAR);
});

test("carryGrants: write-shaped line derives shape:write (F2 anti-spoof wiring)", () => {
  const out = carryGrants([grant({ grant_id: "g1", arm: "git-push", pattern: GP_WRITE, expires_at: FAR, max_uses: 2 })], CNOW);
  expect(out.length).toBe(1);
  expect(out[0].shape).toBe("write");   // re-derived, despite stored shape:"read"
});

test("carryGrants: expired grant dropped (19-char compare)", () => {
  const out = carryGrants([grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: "2020-01-01T00:00:00Z", max_uses: 3 })], CNOW);
  expect(out.length).toBe(0);
});

test("carryGrants: guarded parse skips malformed / consumption / missing-field", () => {
  const out = carryGrants([
    "{ bad json",
    consumption("g1"),
    JSON.stringify({ type: "grant", grant_id: "gX", arm: "gh", pattern: GH_READ }),  // no expires_at/max_uses
  ], CNOW);
  expect(out.length).toBe(0);
});

test("composeCarriedGrantLine: absolute expires_at, remaining→max_uses, carried flag", () => {
  const c: CarriedGrant = { arm: "gh", pattern: GH_READ, capability: "cap", shape: "read", expiresAt: FAR, remaining: 2, grantedBy: "operator" };
  const j = JSON.parse(composeCarriedGrantLine(c, { grantId: "g1", now: CNOW }));
  expect(j.type).toBe("grant");
  expect(j.expires_at).toBe(FAR);   // NOT now + ttl
  expect(j.max_uses).toBe(2);
  expect(j.grant_id).toBe("g1");
  expect(j.carried).toBe(true);
  expect(j.shape).toBe("read");
});

test("seedCarriedGrants: shape-split — autonomous seeds reads, re-escalates writes", () => {
  const carried = carryGrants([
    grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 2 }),
    grant({ grant_id: "g2", arm: "git-push", pattern: GP_WRITE, expires_at: FAR, max_uses: 2 }),
  ], CNOW);
  expect(carried.length).toBe(2);
  const auto = seedCarriedGrants(carried, true, [], CNOW);
  expect(auto.grantLines.length).toBe(1);           // read seeded
  expect(auto.escalationLines.length).toBe(1);      // write NOT seeded — re-escalated
  expect(JSON.parse(auto.grantLines[0]).shape).toBe("read");
  expect(JSON.parse(auto.grantLines[0]).carried).toBe(true);
  const ej = JSON.parse(auto.escalationLines[0]);
  expect(ej.type).toBe("escalation");
  expect(ej.arm).toBe("git-push");
  const op = seedCarriedGrants(carried, false, [], CNOW);
  expect(op.grantLines.length).toBe(2);             // operator present → write seeds
  expect(op.escalationLines.length).toBe(0);
});

test("seedCarriedGrants: grant_id continues past existing (no gap/collision)", () => {
  const carried = carryGrants([grant({ grant_id: "gA", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 1 })], CNOW);
  const existing = [grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 1 })];
  const out = seedCarriedGrants(carried, true, existing, CNOW);
  expect(out.grantLines.length).toBe(1);
  expect(JSON.parse(out.grantLines[0]).grant_id).toBe("g2");   // nextGrantId over 1 existing
});

test("carryGrants: drops a carried grant that fails validateGrantSpec (F8 anchor) — codex-6", () => {
  // git-push arm with NO push token → --grant's validateGrantSpec rejects it, so
  // a forged --carry-from file must not seed it un-gated either.
  const out = carryGrants([grant({ grant_id: "g1", arm: "git-push", pattern: "git[[:space:]]+status", expires_at: FAR, max_uses: 2 })], CNOW);
  expect(out.length).toBe(0);
});

test("carryGrants: expiry exactly == now is dropped (inclusive boundary) — S1", () => {
  const at = "2026-07-04T09:00:00Z";  // == CNOW to the second
  const out = carryGrants([grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: at, max_uses: 2 })], new Date(at));
  expect(out.length).toBe(0);
});

test("carryGrants: a consumption for an absent grant_id leaves live grants untouched — S3", () => {
  const out = carryGrants([
    grant({ grant_id: "g1", arm: "gh", pattern: GH_READ, expires_at: FAR, max_uses: 2 }),
    consumption("gZ"),  // dangling: references a grant not present
  ], CNOW);
  expect(out.length).toBe(1);
  expect(out[0].remaining).toBe(2);   // untouched by the dangling consumption
});
