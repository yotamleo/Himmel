import type { Worker } from "./types";

// arm-resume.sh exposes scheduler query logic only as internal shell functions;
// Phase 1 therefore accepts a helper-produced JSONL stream via this env seam and
// never hand-rolls raw schtasks/crontab parsing in fleet-control.
export function readArmedSlots(jsonl = process.env.FLEET_CONTROL_ARMED_SLOTS_JSONL ?? ""): Worker[] {
  return jsonl.split(/\r?\n/).filter((l) => l.trim() !== "").map((line): Worker => {
    // A malformed slot line becomes a visible degraded row - never a throw
    // (which would 500 the fleet) and never a silent drop.
    let row: Record<string, unknown>;
    try {
      const parsed: unknown = JSON.parse(line);
      if (typeof parsed !== "object" || parsed === null) throw new Error("not an object");
      row = parsed as Record<string, unknown>;
    } catch {
      return { lane: "armed", name: "unparseable armed slot", status: "failed", artifacts: [] };
    }
    const handover = String(row.handover ?? row.handoverPath ?? "");
    return {
      lane: "armed",
      name: String(row.name ?? row.task ?? "armed-slot"),
      status: "armed",
      artifacts: handover ? [handover] : [],
      title: row.time ? `armed for ${row.time}` : undefined,
    };
  });
}
