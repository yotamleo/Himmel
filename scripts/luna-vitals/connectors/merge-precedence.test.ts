import { test, expect } from "bun:test";
import { join } from "path";
import { mkdtempSync } from "fs";
import { tmpdir } from "os";

/**
 * Merge precedence contract — spec §5: argv order within the --det pool
 *
 * When two deterministic artifacts disagree on the same (metric, date):
 *   - The artifact listed FIRST in `--det` argv order wins (mergeRows emits
 *     pool[0], i.e. the first row pushed into the deterministic pool).
 *   - The disagreement is ALWAYS recorded in conflicts[] — so the operator
 *     can see which value was auto-selected and audit it later.
 *
 * Practical rule: always pass the connector artifact BEFORE structured-note
 * artifacts in --det so that machine-measured values take precedence over
 * hand-written estimates.  Reversing the order makes the note value win; this
 * test will catch that regression loudly.
 */

const ROOT = join(import.meta.dir, "..");

async function readJson(p: string): Promise<any> {
  return JSON.parse(await Bun.file(p).text());
}

test(
  "connector artifact (listed first in --det) wins over note artifact on same metric+date; conflict recorded",
  async () => {
    const dir = mkdtempSync(join(tmpdir(), "luna-vitals-prec-"));

    const connectorArtifact = join(dir, "connector.json");
    const noteArtifact = join(dir, "note.json");
    const mergedArtifact = join(dir, "merged.json");

    // Connector artifact: authoritative machine reading (Google Health Connect)
    await Bun.write(
      connectorArtifact,
      JSON.stringify({
        bucket: "google-health:2026-06-28..2026-06-28",
        rows: [{ metric: "sleep_hours", date: "2026-06-28", value: 7.5, source: "google-health:sleep:HEALTH_CONNECT" }],
        conflicts: [],
      }),
    );

    // Note artifact: hand-written estimate — disagrees on the same (metric, date)
    await Bun.write(
      noteArtifact,
      JSON.stringify({
        bucket: "daily-note:2026-06-28",
        rows: [{ metric: "sleep_hours", date: "2026-06-28", value: 6.0, source: "daily note: felt like 6h" }],
        conflicts: [],
      }),
    );

    // Run the real CLI merge: connector listed FIRST in --det → occupies pool[0]
    const p = Bun.spawn(
      ["bun", "run", "cli.ts", "merge", "--det", connectorArtifact, "--det", noteArtifact, "--out", mergedArtifact],
      { cwd: ROOT, stderr: "pipe" },
    );
    expect(await p.exited).toBe(0);

    const merged = await readJson(mergedArtifact);

    // Exactly one sleep_hours row for 2026-06-28; connector value (7.5) must win
    const sleepRows = merged.rows.filter(
      (r: { metric: string; date: string }) => r.metric === "sleep_hours" && r.date === "2026-06-28",
    );
    expect(sleepRows).toHaveLength(1);
    expect((sleepRows[0] as { value: number }).value).toBe(7.5);

    // The disagreement must be recorded in conflicts[]
    expect(merged.conflicts).toHaveLength(1);
    const conflict = merged.conflicts[0];
    expect(conflict.metric).toBe("sleep_hours");
    expect(conflict.date).toBe("2026-06-28");

    // Both competing values must appear in conflict.values
    const recordedValues = (conflict.values as { value: number }[]).map((c) => c.value);
    expect(recordedValues).toContain(7.5);
    expect(recordedValues).toContain(6.0);

    // chosen must reflect the first-listed (connector) value
    expect(conflict.chosen.value).toBe(7.5);
  },
);
