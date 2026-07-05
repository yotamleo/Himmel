import { describe, test, expect } from "vitest";
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

function resolveBash(): string {
  if (process.platform !== "win32") return "bash";
  for (const c of ["C:\\Program Files\\Git\\bin\\bash.exe", "C:\\Program Files\\Git\\usr\\bin\\bash.exe"]) {
    if (existsSync(c)) return c;
  }
  return "bash";
}
const PROBE = join(dirname(fileURLToPath(import.meta.url)), "fixtures", "ci-queue", "atomicity-probe.sh");

// Guards the O_APPEND atomicity property the ledger inherits from quota-gauge.
describe("O_APPEND atomicity probe", () => {
  test("concurrent OS-level appenders produce no torn/lost lines", () => {
    const out = execFileSync(resolveBash(), [PROBE], { encoding: "utf8" }).trim();
    expect(out).toBe("PASS");
  });
});
