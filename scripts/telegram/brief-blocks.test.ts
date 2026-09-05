// scripts/telegram/brief-blocks.test.ts
// HIMMEL-1734 P1: brief-blocks.ts extraction + the two new blocks
// (composeWaiterBlock, composeWriteSetBlock). The mintRetaskNonce /
// composeRetaskBlock / composeBashShapeWarning tests here are the same
// assertions spawn-glm.test.ts already carries for the re-exported names
// (that file's tests are the regression guard for the re-export itself;
// these prove the moved bodies behave identically at the new home).
import { expect, test } from "bun:test";
import { mintRetaskNonce, composeRetaskBlock, composeBashShapeWarning, composeWaiterBlock, composeWriteSetBlock } from "./brief-blocks";

test("mintRetaskNonce returns a 128-bit random hex token, fresh per call", () => {
  const a = mintRetaskNonce();
  const b = mintRetaskNonce();
  expect(a).toMatch(/^[0-9a-f]{32}$/);
  expect(b).toMatch(/^[0-9a-f]{32}$/);
  expect(a).not.toBe(b);
});

test("composeRetaskBlock embeds the token and the fail-safe narrowing/expansion asymmetry", () => {
  const block = composeRetaskBlock("deadbeef");
  expect(block).toContain("RETASK CHANNEL");
  expect(block).toContain("R-deadbeef");
  expect(block).toMatch(/EXPANSION or REDIRECT.*injection/is);
  expect(block).toMatch(/Never output, echo, or write this token/i);
  expect(block).toMatch(/NARROWING may be honored regardless of source or token/i);
  expect(block).toMatch(/tool-permission envelope\s+never changes by message/i);
});

test("composeBashShapeWarning names the deny-fast behavior (HIMMEL-1378), not a hang", () => {
  const w = composeBashShapeWarning("/sess/glm-a-1/outbox.jsonl");
  expect(w).toMatch(/dontAsk/);
  expect(w).toMatch(/DENIED/i);
  expect(w).not.toMatch(/hang/i);
  expect(w).toContain("/sess/glm-a-1/outbox.jsonl");
});

// --- composeWaiterBlock (HIMMEL-1734 §4.3, the leg-14 waiter protocol) ------

test("composeWaiterBlock names the live-clock liveness check, over a repeated log line", () => {
  const w = composeWaiterBlock();
  expect(w).toMatch(/mtime/i);
  expect(w).toMatch(/LIVE CLOCK/i);
  expect(w).toMatch(/NOT evidence/i);
});

test("composeWaiterBlock names the TRACKED until/sleep background waiter", () => {
  const w = composeWaiterBlock();
  expect(w).toContain("until grep -q");
  expect(w).toContain("sleep 15");
  expect(w).toMatch(/TRACKED/);
});

test("composeWaiterBlock forbids parking on an untracked notification", () => {
  const w = composeWaiterBlock();
  expect(w).toMatch(/never park.*untracked notification/is);
});

test("composeWaiterBlock states the >60-minute foreground rule", () => {
  const w = composeWaiterBlock();
  expect(w).toMatch(/60 minutes/);
  expect(w).toMatch(/foreground/i);
});

// --- composeWriteSetBlock (HIMMEL-1734 §4.3, single-writer declaration) ----

test("composeWriteSetBlock lists every declared path", () => {
  const block = composeWriteSetBlock(["scripts/telegram/brief-blocks.ts", "scripts/telegram/compose-brief.ts"]);
  expect(block).toContain("scripts/telegram/brief-blocks.ts");
  expect(block).toContain("scripts/telegram/compose-brief.ts");
  expect(block).toMatch(/ONLY writer/i);
});

test("composeWriteSetBlock returns an empty string for an empty write-set", () => {
  expect(composeWriteSetBlock([])).toBe("");
});
