import { expect, test } from "bun:test";
import { readFileSync, existsSync, readdirSync } from "node:fs";
import { join } from "node:path";

const REPO_ROOT = join(import.meta.dir, "..", "..");

// Strip line + block comments so prose (e.g. "the hermes Codex dispatch") does
// not false-trip the symbol scan — only CODE is checked.
function code(path: string): string {
  return readFileSync(path, "utf8").replace(/\/\/[^\n]*/g, "").replace(/\/\*[\s\S]*?\*\//g, "");
}

// AC10 passivity: the WS9 modules add NO write/dispatch/arm/spawn symbol beyond
// the append helper. (Task 3's auto-arm-on-cap.sh in-hook writer + Task 6's
// spawn-glm.ts append have their own scoped checks; spawn-glm.ts sits in a host
// that pre-exists an arm call, so a whole-file grep there would false-fail — it
// is asserted at its added-line scope in spawn-glm's own test.)
test("AC10 passivity: headroom.ts + headroom-codex.ts reach no arm/dispatch/spawn symbol", () => {
  const FORBIDDEN = /arm-resume|runSession|spawn-glm|schtasks|\brouter\b|\bdispatch\b/;
  for (const f of ["headroom.ts", "headroom-codex.ts"]) {
    expect(FORBIDDEN.test(code(join(REPO_ROOT, "scripts", "telegram", f)))).toBe(false);
  }
});

// AC10 passivity, Task 3 half: the WS9 lines grafted into the auto-arm-on-cap.sh
// watchdog reach no arm/spawn/schedule symbol. Scoped to the sentinel-delimited
// WS9 blocks — a whole-file grep would false-fail on the host's pre-existing
// arm-resume call, which is OUTSIDE WS9's envelope. The "arm-threshold" source
// label is a data string, not a call, so the forbidden set names the dangerous
// SYMBOLS (arm-resume/spawn/schtasks/...), never a bare "arm".
test("AC10 passivity: WS9's auto-arm-on-cap.sh added lines reach no arm/spawn/schedule symbol", () => {
  const hookSrc = readFileSync(
    join(REPO_ROOT, "scripts", "hooks", "auto-arm-on-cap.sh"),
    "utf8",
  );
  const ws9: string[] = [];
  let inBlock = false;
  for (const line of hookSrc.split("\n")) {
    if (/# >>> WS9-HEADROOM/.test(line)) { inBlock = true; continue; }
    if (/# <<< WS9-HEADROOM/.test(line)) { inBlock = false; continue; }
    if (inBlock) ws9.push(line.replace(/#.*/, "")); // strip shell comments
  }
  expect(ws9.length).toBeGreaterThan(0); // the blocks exist (patch landed)
  const FORBIDDEN = /arm-resume|spawn-glm|\bspawn\b|schtasks|\bat\b\s|runSession|\brouter\b|\bdispatch\b/;
  const offenders = ws9.filter((l) => FORBIDDEN.test(l));
  expect(offenders).toEqual([]);
});

// AC9 no new always-on surface: WS9 registers no hook, adds no poller loop, and
// ships no standalone lean-invoke Codex command (F5).
test("AC9 no new always-on surface (no hook registration / poller / standalone codex command)", () => {
  for (const f of ["headroom.ts", "headroom-codex.ts"]) {
    expect(/while\s*\(\s*true\s*\)|setInterval/.test(code(join(REPO_ROOT, "scripts", "telegram", f)))).toBe(false);
  }
  // no headroom hook wired into settings
  const settings = join(REPO_ROOT, ".claude", "settings.json");
  if (existsSync(settings)) expect(/headroom/i.test(readFileSync(settings, "utf8"))).toBe(false);
  // no standalone codex-usage / headroom command file
  const cmds = join(REPO_ROOT, ".claude", "commands");
  if (existsSync(cmds)) {
    const names = readdirSync(cmds).join(" ");
    expect(/codex.*usage|headroom/i.test(names)).toBe(false);
  }
});
