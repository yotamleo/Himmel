import { test, expect } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readFeeds } from "../aggregator/ledger";

test("readFeeds parses ledger and quota JSONL as render-only feeds with posture reserved", () => {
  const root = mkdtempSync(join(tmpdir(), "fleet-ledger-"));
  const ledgerPath = join(root, "where-are-we.jsonl");
  const quotaPath = join(root, "quota-gauge.jsonl");
  writeFileSync(ledgerPath, '{"event":"a"}\n{"event":"b"}\n');
  writeFileSync(quotaPath, '{"lane":"glm","used_pct":80}\n');

  const feeds = readFeeds({ ledgerPath, quotaPath });
  expect(feeds.ledger).toEqual([{ event: "a" }, { event: "b" }]);
  expect(feeds.quota).toEqual([{ lane: "glm", used_pct: 80 }]);
  expect(feeds.posture).toBeNull();
  expect(feeds.parseErrors).toBe(0);
  expect(feeds.error).toBeNull();
});

test("partial trailing line is skipped, good lines kept, and counted as parseErrors (finding 3)", () => {
  const root = mkdtempSync(join(tmpdir(), "fleet-ledger-partial-"));
  const ledgerPath = join(root, "where-are-we.jsonl");
  // append-only feed caught mid-write: a valid line then a partial trailing line.
  writeFileSync(ledgerPath, '{"event":"a"}\n{"event":"b"}\n{"event":"part');

  const feeds = readFeeds({ ledgerPath });
  expect(feeds.ledger).toEqual([{ event: "a" }, { event: "b" }]);
  expect(feeds.parseErrors).toBe(1);
});
