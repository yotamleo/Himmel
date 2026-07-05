import { describe, test, expect } from "vitest";
import { hasPrivateHeadroom, getUsage } from "../src/quota.js";

describe("hasPrivateHeadroom", () => {
  test("75% used → no headroom (above the 70% target)", () => {
    expect(hasPrivateHeadroom({ includedMinutesUsed: 1500, includedMinutes: 2000 })).toBe(false);
  });
  test("50% used → headroom", () => {
    expect(hasPrivateHeadroom({ includedMinutesUsed: 1000, includedMinutes: 2000 })).toBe(true);
  });
  test("exactly 70% → no headroom (strict below target)", () => {
    expect(hasPrivateHeadroom({ includedMinutesUsed: 1400, includedMinutes: 2000 })).toBe(false);
  });
  test("zero/absent cap → no headroom (never claim what we cannot prove)", () => {
    expect(hasPrivateHeadroom({ includedMinutesUsed: 0, includedMinutes: 0 })).toBe(false);
  });
});

describe("getUsage", () => {
  test("maps the billing response into MinutesUsage", async () => {
    const u = await getUsage(async () => ({ total_minutes_used: 1200, included_minutes: 2000 }));
    expect(u).toEqual({ includedMinutesUsed: 1200, includedMinutes: 2000 });
  });
});
