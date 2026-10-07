// HIMMEL-4807: probe-progress.cjs, the `node --require` preload that turns the report's spawns into
// `himmel-probe {"i","n","source"}` stderr lines. Driven by a fake report (no real config-feed, doctor or cadence).
import { test, expect, afterAll } from "bun:test";
import { spawnSync } from "node:child_process";
import { chmodSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const PRELOAD = join(import.meta.dir, "..", "probe-progress.cjs");
const dir = mkdtempSync(join(tmpdir(), "cfgui-probe-"));
afterAll(() => rmSync(dir, { recursive: true, force: true }));

const sh = (name: string) => { const p = join(dir, name); writeFileSync(p, "#!/bin/sh\nexit 0\n"); chmodSync(p, 0o755); return p; };
const S = Object.fromEntries(["x.sh", "pipeline-cadence.sh", "doctor-cadence.sh", "plugin-profile.sh"].map((n) => [n, sh(n)]));
writeFileSync(join(dir, "feed.js"), `module.exports = { CADENCES: [{ name: 'pipeline' }, { name: 'codex-sweep', windowsOnly: true }, { name: 'doctor' }], buildFeed() {} };\n`);
// The real config-feed.js destructures spawnSync at load; so does the fake.
writeFileSync(join(dir, "report.js"), `const { spawnSync } = require('child_process');
require(${JSON.stringify(join(dir, "feed.js"))});
const run = (a) => spawnSync('bash', a, { encoding: 'utf8' });
run([${JSON.stringify(S["pipeline-cadence.sh"])}, 'status']); // the status engine, before the doctor: no step
run([${JSON.stringify(S["x.sh"])}, '--json', '--no-color']);
run([${JSON.stringify(S["pipeline-cadence.sh"])}, 'status']);
run([${JSON.stringify(S["doctor-cadence.sh"])}, 'status']);
run([${JSON.stringify(S["plugin-profile.sh"])}, 'list', '--json']);
process.stdout.write('{}\\n');
`);

test("the preload emits one step per probed source, in order, n of N (codex-sweep only on Windows)", () => {
  const r = spawnSync("node", ["--require", PRELOAD, join(dir, "report.js")], { encoding: "utf8" });
  expect(r.status).toBe(0);
  expect(r.stdout).toBe("{}\n"); // the report's own output is untouched
  const steps = r.stderr.split("\n").filter((l) => l.startsWith("himmel-probe ")).map((l) => JSON.parse(l.slice("himmel-probe ".length)));
  const cad = process.platform === "win32" ? ["pipeline cadence", "codex-sweep cadence", "doctor cadence"] : ["pipeline cadence", "doctor cadence"];
  const names = ["install items", "doctor checks", ...cad, "plugin profile", "lanes, initiative legs, flags and secrets"];
  // On Windows the fake never spawns codex-sweep's status, so that step is skipped, never emitted.
  const want = names.map((source, k) => ({ i: k + 1, n: names.length, source })).filter((s) => s.source !== "codex-sweep cadence");
  expect(steps).toEqual(want);
});

test("without config-feed loading, the preload says nothing", () => {
  writeFileSync(join(dir, "other.js"), `require('child_process').spawnSync('bash', [${JSON.stringify(S["x.sh"])}, '--json', '--no-color']);\n`);
  const r = spawnSync("node", ["--require", PRELOAD, join(dir, "other.js")], { encoding: "utf8" });
  expect(r.status).toBe(0);
  expect(r.stderr).not.toContain("himmel-probe");
});
