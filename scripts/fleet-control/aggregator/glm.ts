import { existsSync, readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import type { Worker, WorkerStatus } from "./types";

function readJson(path: string): Record<string, unknown> | undefined {
  try {
    const v: unknown = JSON.parse(readFileSync(path, "utf8"));
    return typeof v === "object" && v !== null ? (v as Record<string, unknown>) : undefined;
  } catch {
    return undefined;
  }
}

// Fail-closed status mapping at the glm boundary (mirrors CODEX_STATUS in
// codex.ts): only known spawn-glm meta statuses pass through; anything
// unexpected renders "failed" instead of leaking a raw string.
const GLM_STATUS: Record<string, WorkerStatus> = {
  running: "running",
  done: "done",
  failed: "failed",
  capped: "capped",
  blocked: "blocked",
  timeout: "timeout",
};

function glmStatus(raw: unknown): WorkerStatus {
  if (typeof raw !== "string") return "running"; // running meta may predate the status write
  return GLM_STATUS[raw] ?? "failed";
}

function lastJsonLine(path: string): unknown | undefined {
  if (!existsSync(path)) return undefined;
  const lines = readFileSync(path, "utf8").split(/\r?\n/).filter((l) => l.trim() !== "");
  if (lines.length === 0) return undefined;
  try { return JSON.parse(lines[lines.length - 1]); } catch { return { parseError: true, raw: lines[lines.length - 1] }; }
}

export function readGlmWorkers(bridgeRoot: string): Worker[] {
  const root = join(bridgeRoot, "glm-sessions");
  if (!existsSync(root)) return [];
  const workers: Worker[] = [];
  for (const entry of readdirSync(root, { withFileTypes: true })) {
    if (!entry.isDirectory()) continue;
    const sessionDir = join(root, entry.name);
    const metaPath = join(sessionDir, "meta.json");
    const metaExists = existsSync(metaPath);
    const meta = metaExists ? readJson(metaPath) : undefined;
    if (!meta) {
      // meta.json present but unparseable/unreadable -> a worker existed here,
      // so render it degraded rather than dropping it. Missing meta entirely =
      // no worker was ever recorded, so skip silently.
      if (metaExists) {
        workers.push({ lane: "glm", name: entry.name, status: "failed", artifacts: [metaPath], error: "unreadable meta.json" });
      }
      continue;
    }
    const outboxPath = join(sessionDir, "outbox.jsonl");
    const grantsPath = join(sessionDir, "grants.jsonl");
    const artifacts = [metaPath];
    if (existsSync(outboxPath)) artifacts.push(outboxPath);
    if (existsSync(grantsPath)) artifacts.push(grantsPath);
    workers.push({
      lane: "glm",
      name: String(meta.name ?? meta.task_name ?? entry.name),
      status: glmStatus(meta.status),
      branch: typeof meta.branch === "string" ? meta.branch : undefined,
      sessionDir,
      artifacts,
      lastOutboxLine: lastJsonLine(outboxPath),
      hasGrants: existsSync(grantsPath),
      pid: typeof meta.pid === "number" ? meta.pid : undefined,
    });
  }
  return workers;
}
