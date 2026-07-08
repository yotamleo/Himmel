export type WorkerStatus = "running" | "done" | "failed" | "dead" | "capped" | "blocked" | "timeout" | "armed" | "queued" | "unknown";

export type Worker = {
  lane: "glm" | "codex" | "hermes" | "armed";
  name: string;
  status: WorkerStatus;
  branch?: string;
  sessionDir?: string;
  artifacts: string[];
  lastOutboxLine?: unknown;
  hasGrants?: boolean;
  pid?: number | null;
  title?: string;
  error?: string;
};
