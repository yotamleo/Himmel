import { detectThreadSignal } from "../tools/fxtwitter-enrich.mjs";
import assert from "node:assert";

const cases = [
  // [text, repliesCount, expected, label]
  ["thoughts on agents\n\n1/5 first point", 0, true, "n/N at line start"],
  ["a point 3/7", 0, true, "n/N at line end"],
  ["my deep dive 🧵", 0, true, "thread emoji"],
  ["here's a thread on X", 0, true, "the words 'a thread'"],
  ["repo in comment", 3, true, "reply pointer + replies>0"],
  ["link in replies 👇", 12, true, "down-arrow pointer + replies>0"],
  ["repo in comment", 0, false, "reply pointer but zero replies"],
  ["I ate 1/2 cup of rice", 0, false, "mid-line fraction not a counter"],
  ["just a normal tweet", 5, false, "no signal"],
  ["", 9, false, "empty text"],
];

let pass = 0;
for (const [text, rc, expected, label] of cases) {
  const got = detectThreadSignal(text, rc);
  assert.strictEqual(got, expected, `FAIL: ${label} (got ${got}, want ${expected})`);
  pass++;
}
console.log(`test-thread-signal: ${pass}/${cases.length} pass`);
