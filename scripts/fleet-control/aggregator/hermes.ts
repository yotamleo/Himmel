import { existsSync, readdirSync } from "node:fs";
import { join, basename } from "node:path";
import type { Worker } from "./types";

export type HermesCoverage = { hermesNativeChildren: "blind"; note: string };

export function readHermes(stateRoot: string): { workers: Worker[]; coverage: HermesCoverage } {
  // stateRoot is already the fleet-control root (serve passes <bridge>/fleet-control),
  // so logs live at <stateRoot>/logs - joining "fleet-control" again would double-nest.
  const logs = join(stateRoot, "logs");
  const workers: Worker[] = [];
  if (existsSync(logs)) {
    for (const entry of readdirSync(logs, { withFileTypes: true })) {
      if (!entry.isFile() || !entry.name.startsWith("hermes-") || !entry.name.endsWith(".log")) continue;
      const name = basename(entry.name, ".log").replace(/^hermes-/, "");
      // A log's mere existence does not prove completion; status is "unknown"
      // because we cannot derive it from the file alone.
      workers.push({ lane: "hermes", name, status: "unknown", artifacts: [join(logs, entry.name)] });
    }
  }
  return {
    workers,
    coverage: {
      hermesNativeChildren: "blind",
      note: "Hermes-native delegate_task children do not create durable fleet-control artifacts; only pane-dispatched one-shot logs are visible here.",
    },
  };
}
