import { test, expect, afterAll } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { buildTable, resolveAction, loadRegistries } from "../actions";

// T4.0: the action table on its own, no server. Every path is a fixed fake root.
const ctx = { root: "/R", cadenceRoot: "/C", himmelctl: "/H/bin.js", platform: "linux", plugins: ["a@m", "b@m"], lanes: ["l1"] };
const table = buildTable(ctx);
const H = ["node", "/H/bin.js"];

const cases: [string, string, string | undefined, string[]][] = [
  ["cadence.arm", "pipeline", undefined, ["bash", "/C/scripts/luna/pipeline-cadence.sh", "arm"]],
  ["cadence.arm", "graphmap", undefined, ["bash", "/C/scripts/luna/graphmap-cadence.sh", "arm"]],
  ["cadence.arm", "qmd", undefined, ["bash", "/C/scripts/luna/qmd-cadence.sh", "arm"]],
  ["cadence.arm", "doctor", undefined, ["bash", "/C/scripts/doctor-cadence.sh", "arm"]],
  ["cadence.disarm", "graphmap", undefined, ["bash", "/C/scripts/luna/graphmap-cadence.sh", "disarm"]],
  ["plugin.enable", "a@m", undefined, [...H, "profile", "enable", "a@m"]],
  ["plugin.disable", "b@m", undefined, [...H, "profile", "disable", "b@m"]],
  ["profile.set", "lean", undefined, [...H, "profile", "lean"]],
  ["profile.set", "full", undefined, [...H, "profile", "full"]],
  ["config.lanes", "l1", "on", [...H, "config", "set", "lanes.l1", "on"]],
  ["config.lanes", "l1", "off", [...H, "config", "set", "lanes.l1", "off"]],
  ["config.initiative", "pr", "on", [...H, "config", "set", "initiative.pr", "on"]],
  ["config.initiative", "handover", "off", [...H, "config", "set", "initiative.handover", "off"]],
];

for (const [action, target, value, argv] of cases) {
  test(`${action} ${target}${value ? " " + value : ""} maps to its exact argv and dry-argv`, () => {
    const a = resolveAction(table, action, target, value);
    expect(a.argv).toEqual(argv);
    expect(a.dryArgv).toEqual([...argv, "--dry-run"]);
  });
}

test("consent, timeouts and cwd come from the table", () => {
  expect(resolveAction(table, "cadence.arm", "graphmap").consent).toEqual({ kind: "typed", expect: "graphmap" });
  expect(resolveAction(table, "profile.set", "full").consent).toEqual({ kind: "typed", expect: "full" });
  expect(resolveAction(table, "plugin.enable", "a@m").consent).toEqual({ kind: "plain", expect: null });
  expect(resolveAction(table, "cadence.arm", "qmd").timeoutMs).toBe(120_000);
  expect(resolveAction(table, "config.lanes", "l1", "on").timeoutMs).toBe(60_000);
  expect(resolveAction(table, "plugin.enable", "a@m").cwd).toBe("/R");
  expect(resolveAction(table, "cadence.arm", "graphmap").rowIds).toEqual(["graphmap-cadence"]);
});

const refused: [string, string, string | undefined][] = [
  ["nope", "graphmap", undefined],
  ["__proto__", "graphmap", undefined],
  ["constructor", "graphmap", undefined],
  ["cadence.arm", "nightly", undefined],
  ["cadence.arm", "codex-sweep", undefined], // platform gate: linux
  ["plugin.disable", "handover@himmel", undefined], // floor, never a target
  ["plugin.enable", "c@m", undefined],
  ["plugin.enable", "-a@m", undefined],
  ["plugin.enable", "a @m", undefined],
  ["profile.set", "medium", undefined],
  ["config.lanes", "l1", undefined], // value required
  ["config.lanes", "l1", "maybe"],
  ["config.lanes", "l2", "on"],
  ["config.initiative", "merge", "on"], // guard-class, never a target
  ["cadence.arm", "graphmap", "on"], // value only for config.*
];
for (const [action, target, value] of refused) {
  test(`${action} ${target} ${value ?? ""} is refused`, () => {
    expect(() => resolveAction(table, action, target, value)).toThrow();
  });
}

test("the codex-sweep cadence is a target only on Windows", () => {
  const win = buildTable({ ...ctx, platform: "win32" });
  expect(resolveAction(win, "cadence.arm", "codex-sweep").argv).toEqual(["bash", "/C/scripts/cleanup/codex-sweep-cadence.sh", "arm"]);
});

test("the table is frozen", () => {
  expect(Object.isFrozen(table)).toBe(true);
  expect(Object.isFrozen(table.get("cadence.arm")!.targets)).toBe(true);
});

// D1: plugin and lane targets come from the git-tracked registries at HEAD.
const scratch = mkdtempSync(join(tmpdir(), "cfgui-reg-"));
afterAll(() => rmSync(scratch, { recursive: true, force: true }));
const git = (...a: string[]) => execFileSync("git", ["-C", scratch, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ...a], { stdio: "ignore" });
function writeRegistries(plugins: string[], lanes: string[]) {
  mkdirSync(join(scratch, "docs/setup"), { recursive: true });
  mkdirSync(join(scratch, "scripts/lanes"), { recursive: true });
  writeFileSync(join(scratch, "docs/setup/settings-template.json"), JSON.stringify({ onDemandPlugins: Object.fromEntries(plugins.map((p) => [p, {}])) }));
  writeFileSync(join(scratch, "scripts/lanes/lanes.json"), JSON.stringify({ lanes: lanes.map((id) => ({ id })) }));
}

test("registries are read from git HEAD: floor, bad ids, dirty edits and *.local.json never become targets", () => {
  git("init", "-q");
  writeRegistries(["a@m", "handover@himmel", "-x@m", "sp ace@m", "y".repeat(65)], ["l1"]);
  git("add", "-A");
  git("commit", "-q", "-m", "reg");
  writeRegistries(["a@m", "dirty@m"], ["l1", "l2"]);
  writeFileSync(join(scratch, "scripts/lanes/lanes.local.json"), JSON.stringify({ lanes: [{ id: "l3" }] }));
  expect(loadRegistries(scratch)).toEqual({ plugins: ["a@m"], lanes: ["l1"] });
});

test("without git the registries fail closed to no plugin or lane targets", () => {
  const bare = mkdtempSync(join(tmpdir(), "cfgui-nogit-"));
  try { expect(loadRegistries(bare)).toEqual({ plugins: [], lanes: [] }); }
  finally { rmSync(bare, { recursive: true, force: true }); }
});
