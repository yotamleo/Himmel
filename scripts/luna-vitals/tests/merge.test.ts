import { test, expect } from "bun:test";
import { mergeRows } from "../src/merge";

const r = (metric: string, date: string, value: number, source: string) => ({ metric, date, value, source });

test("deterministic overrides LLM at the same metric+date", () => {
  const out = mergeRows({
    deterministic: [r("migraine", "2024-06-14", 3, "table.md")],
    llm: [r("migraine", "2024-06-14", 2, "prose.md")],
    bucket: "2024",
  });
  expect(out.rows).toEqual([r("migraine", "2024-06-14", 3, "table.md")]);
  expect(out.conflicts).toEqual([]);
});

test("LLM fills gaps the parser left", () => {
  const out = mergeRows({
    deterministic: [r("migraine", "2024-06-14", 3, "t.md")],
    llm: [r("migraine", "2024-06-15", 1, "p.md")],
    bucket: "2024",
  });
  expect(out.rows).toEqual([r("migraine", "2024-06-14", 3, "t.md"), r("migraine", "2024-06-15", 1, "p.md")]);
});

test("identical values from overlap dedup silently", () => {
  const out = mergeRows({ deterministic: [], llm: [r("migraine", "2024-06-14", 2, "a.md"), r("migraine", "2024-06-14", 2, "b.md")], bucket: "x" });
  expect(out.rows).toEqual([r("migraine", "2024-06-14", 2, "a.md")]);
  expect(out.conflicts).toEqual([]);
});

test("non-authoritative LLM disagreement is flagged, first row still emitted", () => {
  const out = mergeRows({ deterministic: [], llm: [r("migraine", "2024-06-14", 2, "a.md"), r("migraine", "2024-06-14", 3, "b.md")], bucket: "x" });
  expect(out.rows).toEqual([r("migraine", "2024-06-14", 2, "a.md")]);
  expect(out.conflicts).toEqual([{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "a.md" }, { value: 3, source: "b.md" }] }]);
});

test("two deterministic sources disagreeing is flagged, first row emitted (no LLM)", () => {
  const out = mergeRows({ deterministic: [r("migraine", "2024-06-14", 2, "table.md"), r("migraine", "2024-06-14", 3, "bullet.md")], llm: [], bucket: "x" });
  expect(out.rows).toEqual([r("migraine", "2024-06-14", 2, "table.md")]);
  expect(out.conflicts).toEqual([{ metric: "migraine", date: "2024-06-14", values: [{ value: 2, source: "table.md" }, { value: 3, source: "bullet.md" }] }]);
});
