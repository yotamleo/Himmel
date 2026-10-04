// HIMMEL-4254 P4 (spec A14): one line per run in actions.jsonl. No output
// bodies: argv is table constants plus the validated target and value.
import { appendFileSync, mkdirSync } from "node:fs";
import { dirname } from "node:path";

export type AuditLine = {
  time: string; action: string; target: string; value: string | null; argv: string[]; rc: number | null;
  before: Record<string, string> | null; after: Record<string, string> | null;
  outcome?: "error"; // set only when the run rejected: rc null alone must never read as a success
};

export function appendAudit(path: string, l: AuditLine): void {
  mkdirSync(dirname(path), { recursive: true });
  const line: AuditLine = { time: l.time, action: l.action, target: l.target, value: l.value, argv: l.argv, rc: l.rc, before: l.before, after: l.after, ...(l.outcome ? { outcome: l.outcome } : {}) };
  appendFileSync(path, JSON.stringify(line) + "\n", { mode: 0o600 });
}
