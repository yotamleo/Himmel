import { describe, test, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { ledgerPath } from "../src/ledger.js";

// Resolve a real bash on any platform. On Windows, prefer Git Bash explicitly —
// a bare `bash` can hit the WSL System32 stub (exit 127). Falls back to "bash"
// (correct under a Git-Bash / Linux PATH, e.g. CI's ubuntu runner).
function resolveBash(): string {
  if (process.platform !== "win32") return "bash";
  for (const c of ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files\\Git\\usr\\bin\\bash.exe"]) {
    if (existsSync(c)) return c;
  }
  return "bash";
}

const TWIN = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "lib", "ci-queue-ledger-path.sh");

function twinPath(env: Record<string, string>): string {
  return execFileSync(resolveBash(), [TWIN], { env: { ...process.env, ...env }, encoding: "utf8" }).trim();
}
const norm = (p: string) => p.replace(/\\/g, "/");

describe("ci-queue-ledger-path.sh parity with ledgerPath()", () => {
  test("override case: bash twin is byte-identical to ledgerPath()", () => {
    const env = { HIMMEL_CI_QUEUE_LEDGER: "/tmp/parity.jsonl" };
    expect(twinPath(env)).toBe(ledgerPath(env));
  });

  test("default case: bash twin resolves to $HOME/.himmel/ci-queue.jsonl", () => {
    const env = { HOME: "/home/parity", HIMMEL_CI_QUEUE_LEDGER: "" };
    expect(norm(twinPath(env))).toBe(norm(ledgerPath(env)));
  });

  test("empty HOME: ledgerPath falls back to the OS home (never a filesystem-root path)", () => {
    // Guards the root-write risk: `??` alone would let HOME="" resolve to
    // "/.himmel/ci-queue.jsonl". The bash twin's matching fail-closed guard is
    // only reachable on Linux (Windows Git Bash/MSYS repopulates an empty HOME
    // from USERPROFILE before the script runs), so it is not asserted here.
    const p = ledgerPath({ HOME: "", HIMMEL_CI_QUEUE_LEDGER: "" });
    expect(norm(p)).not.toBe("/.himmel/ci-queue.jsonl");
    expect(p).toContain(".himmel");
  });
});
