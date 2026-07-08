import { test, expect } from "bun:test";
import { readArmedSlots } from "../aggregator/armed";

test("malformed armed-slot lines render a degraded row, never throw or drop (finding 2)", () => {
  const good = JSON.stringify({ name: "good-slot", handover: "/tmp/h.md", time: "01:00" });
  const slots = readArmedSlots(`${good}\n{not json\n`);
  expect(slots).toHaveLength(2);
  expect(slots[0]).toMatchObject({ lane: "armed", name: "good-slot", status: "armed" });
  expect(slots[1]).toMatchObject({ lane: "armed", name: "unparseable armed slot", status: "failed" });
});

test("readArmedSlots parses injected arm-resume helper JSONL without touching scheduler", () => {
  const old = process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL;
  process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL = JSON.stringify({ name: "HIMMEL-Resume-demo", handover: "/tmp/next.md", time: "12:34" });
  try {
    const slots = readArmedSlots();
    expect(slots).toHaveLength(1);
    expect(slots[0]).toMatchObject({ lane: "armed", name: "HIMMEL-Resume-demo", status: "armed" });
    expect(slots[0].artifacts).toContain("/tmp/next.md");
  } finally {
    if (old === undefined) delete process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL;
    else process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL = old;
  }
});
