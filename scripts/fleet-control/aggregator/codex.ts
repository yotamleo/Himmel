import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { isPidAlive } from "./liveness";
import type { Worker, WorkerStatus } from "./types";

function readJson(path: string): Record<string, unknown> | undefined {
  try {
    const v: unknown = JSON.parse(readFileSync(path, "utf8"));
    return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

// Fail-closed status mapping at the codex boundary: only known companion statuses
// pass through to an honest WorkerStatus; anything unexpected renders "failed"
// rather than leaking a raw string the UI can't reason about.
const CODEX_STATUS: Record<string, WorkerStatus> = {
  queued: "queued",
  running: "running",
  completed: "done",
  failed: "failed",
  cancelled: "failed",
};

export function readCodexJobs(pluginDataRoot: string): Worker[] {
  // The serve entry may pass either a plugin-data root (companion writes state
  // under <root>/state) or a bare state root (the tmpdir fallback IS the state
  // root). Prefer <root>/state when it exists, else treat the arg as the root.
  const withState = join(pluginDataRoot, "state");
  const stateRoot = existsSync(withState) ? withState : pluginDataRoot;
  if (!existsSync(stateRoot)) return [];
  const workers: Worker[] = [];
  for (const dir of readdirSync(stateRoot, { withFileTypes: true })) {
    if (!dir.isDirectory()) continue;
    const stateFile = join(stateRoot, dir.name, "state.json");
    const stateExists = existsSync(stateFile);
    const state = stateExists ? readJson(stateFile) : undefined;
    if (!state) {
      // Present-but-unparseable state.json = a job registry we can't read: show
      // it degraded (visible) instead of dropping it. Missing file = no jobs.
      if (stateExists) {
        workers.push({ lane: "codex", name: "<corrupt state>", status: "failed", artifacts: [stateFile], error: "unreadable state.json" });
      }
      continue;
    }
    if (state.jobs !== undefined && !Array.isArray(state.jobs)) {
      workers.push({ lane: "codex", name: "<corrupt state>", status: "failed", artifacts: [stateFile], error: "state.jobs is not an array" });
      continue;
    }
    const jobs: unknown[] = Array.isArray(state.jobs) ? state.jobs : [];
    for (const raw of jobs) {
      if (typeof raw !== "object" || raw === null) continue;
      const job = raw as Record<string, unknown>;
      const rawStatus = typeof job.status === "string" ? job.status : "";
      const mapped: WorkerStatus = CODEX_STATUS[rawStatus] ?? "failed";
      const active = rawStatus === "queued" || rawStatus === "running";
      const pid = typeof job.pid === "number" ? job.pid : null;
      // Liveness only DOWNGRADES an active job whose RECORDED pid is gone.
      // pid=null is a legitimate shape (foreground jobs run inside the parent;
      // queued jobs have not spawned) per companion-liveness.sh — those keep
      // their mapped status rather than being mislabeled "dead".
      const status: WorkerStatus = active && pid !== null && !isPidAlive(pid) ? "dead" : mapped;
      const logFile = typeof job.logFile === "string" ? job.logFile : undefined;
      workers.push({
        lane: "codex",
        name: String(job.id ?? job.title ?? "codex-job"),
        title: typeof job.title === "string" ? job.title : undefined,
        status,
        pid,
        sessionDir: typeof job.workspaceRoot === "string" ? job.workspaceRoot : undefined,
        artifacts: [stateFile, ...(logFile ? [logFile] : [])],
      });
    }
  }
  return workers;
}
