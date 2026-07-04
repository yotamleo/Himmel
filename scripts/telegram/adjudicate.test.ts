import { expect, test } from "bun:test";
import { collectPendingEscalations, composeRefusalLine } from "./adjudicate";

const esc = (id: string) => `{"type":"escalation","capability":"gh api repos/o/r/pulls/${id}","arm":"gh","reason":"r","step":"3/5","ts":"2026-07-03T18:22:11Z"}`;

test("T7 collectPendingEscalations surfaces only unresolved escalation lines", () => {
  const out = collectPendingEscalations([
    { dir: "s1", outboxLines: [`{"text":"progress"}`, esc("1"), esc("2")], grantsLines: [] },
    { dir: "s2", outboxLines: [esc("9")], grantsLines: [`{"type":"refusal","index":0,"ts":"x"}`] },
  ]);
  // s1: two unresolved; s2: resolved by refusal -> dropped
  expect(out.map((o) => o.session)).toEqual(["s1", "s1"]);
  expect(out[0].capability).toContain("gh api");
  expect(out[0].arm).toBe("gh");
  expect(out.map((o) => o.index)).toEqual([1, 2]); // positional index within outboxLines
});

test("composeRefusalLine shape", () => {
  const j = JSON.parse(composeRefusalLine({ index: 0, now: new Date("2026-07-03T00:00:00Z") }));
  expect(j.type).toBe("refusal");
  expect(j.index).toBe(0);
  expect(typeof j.ts).toBe("string");
});

test("a malformed outbox/grants line is skipped, never throws", () => {
  const out = collectPendingEscalations([
    { dir: "s3", outboxLines: [`{not json`, esc("7")], grantsLines: [`{bad`] },
  ]);
  expect(out.length).toBe(1); // the malformed lines are skipped; the one escalation surfaces at its true index
  expect(out[0].index).toBe(1);
});
