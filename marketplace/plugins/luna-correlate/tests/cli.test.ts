import { test, expect } from "bun:test";
import { join } from "path";
import { runCorrelate } from "../src/cli";

// Resolve paths against this file's dir (not cwd) so the suite passes from any
// working directory (#541 nit).
const ROOT = join(import.meta.dir, "..");
const FIXTURES = join(import.meta.dir, "fixtures");

test("runCorrelate joins fixtures", async () => {
  const sig = await runCorrelate(join(FIXTURES, "migraine-fixture.csv"), join(FIXTURES, "kp-sample.txt"), 1);
  expect(sig.factor).toBe("Kp-index");
  expect(sig.n).toBeGreaterThan(0);
});

test("cli rejects non-integer lagDays with exit 1", async () => {
  const proc = Bun.spawn(
    ["bun", "run", "src/cli.ts", "correlate", join(FIXTURES, "migraine-fixture.csv"), "notanumber"],
    { stderr: "pipe", cwd: ROOT },
  );
  const code = await proc.exited;
  const err = await new Response(proc.stderr).text();
  expect(code).toBe(1);
  expect(err).toContain("lagDays must be an integer");
});
