// HIMMEL-4807: every opt-in / opt-out toggle the console offers, end to end through the REAL himmelctl and the
// real server routes: preview -> run -> (1) the setting is written, (2) its owner reads it back, (3) a reload
// (the run's `after` re-probe AND a fresh GET /api/feed) shows the new state; then the opposite flip, checked
// the same way. The toggles are the feed's `control.class: "toggle"` rows: cadence.arm/disarm, plugin.enable/
// disable, config.lanes on/off, config.initiative on/off. profile.set is in the action table, but no feed row
// offers it, so it is not a console toggle and is not tested here.
// Hermetic: a temp HOME, a fake crontab/claude/qmd/graphify first on PATH (plus each cadence's *_CRONTAB seam),
// HIMMELCTL_REPO_ROOT = a temp tree of symlinks (so `config set` writes its .env and lanes.local.json there,
// never in the checkout), and a stub doctor (the full feed must not run the real one).
import { describe, test, expect, beforeAll, afterAll } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";
import { startServer } from "../server";
import { loadRegistries } from "../actions";

const CHECKOUT = resolve(import.meta.dir, "../../..");
const BIN = join(CHECKOUT, "scripts/himmelctl/bin.js");
const TOKEN = "t".repeat(64);
const LINUX_CADENCES = ["pipeline", "qmd", "graphmap", "doctor"]; // codex-sweep is Windows-only: a read-only row elsewhere
const CADENCE_SCRIPT: Record<string, string> = {
  pipeline: "scripts/luna/pipeline-cadence.sh", qmd: "scripts/luna/qmd-cadence.sh",
  graphmap: "scripts/luna/graphmap-cadence.sh", doctor: "scripts/doctor-cadence.sh",
};
// The plugin and lane targets exactly as the server's action table reads them (git HEAD of the checkout).
// Every target runs the same argv with only the id changed, so CI flips one of each (the first listed);
// CONFIG_UI_TOGGLES_ALL=1 flips all of them (about 100 s: 28 plugins and 17 lanes when this was written).
const { plugins: PLUGINS, lanes: LANES } = loadRegistries(CHECKOUT);
const ALL = process.env.CONFIG_UI_TOGGLES_ALL === "1";
const PLUGIN_CASES = ALL ? PLUGINS : PLUGINS.slice(0, 1);
const LANE_CASES = ALL ? LANES : LANES.slice(0, 1);
const LEGS = ["execute", "prcheck", "pr", "ticket", "handover"]; // merge and public are guard-class, display-only
// The checkout's own settings files: the suite must never write them.
const GUARDED = [".env", "scripts/lanes/lanes.local.json"];

let dir = "", home = "", repo = "", env: Record<string, string> = {}, port = 0, stop = () => {};
let guardBefore = "";
const guardState = () => GUARDED.map((p) => {
  const f = join(CHECKOUT, p);
  return `${p}:${existsSync(f) ? statSync(f).mtimeMs : "absent"}`;
}).join("\n") + "\n" + execFileSync("git", ["-C", CHECKOUT, "status", "--porcelain", "--ignored", "--", ...GUARDED], { encoding: "utf8" });

function exe(path: string, body: string) { writeFileSync(path, body); chmodSync(path, 0o755); }

describe.skipIf(process.platform === "win32")("console toggles, end to end", () => {
  beforeAll(() => {
    guardBefore = guardState();
    dir = mkdtempSync(join(tmpdir(), "cfgui-toggles-"));
    home = join(dir, "home"); repo = join(dir, "repo");
    const bin = join(dir, "bin");
    for (const d of [join(home, "Documents/luna"), bin, join(repo, "scripts/lanes")]) mkdirSync(d, { recursive: true });
    // scripts/: a symlink per entry, except lanes, a real directory of per-file links minus the overlay.
    for (const e of readdirSync(join(CHECKOUT, "scripts"))) if (e !== "lanes") symlinkSync(join(CHECKOUT, "scripts", e), join(repo, "scripts", e));
    for (const e of readdirSync(join(CHECKOUT, "scripts/lanes"))) if (e !== "lanes.local.json") symlinkSync(join(CHECKOUT, "scripts/lanes", e), join(repo, "scripts/lanes", e));
    symlinkSync(join(CHECKOUT, "docs"), join(repo, "docs"));
    exe(join(bin, "crontab"), `#!/bin/sh
f="$HOME/.fake-crontab"
case "$1" in
  -l) if [ -f "$f" ]; then cat "$f"; exit 0; fi; echo "no crontab for user" >&2; exit 1 ;;
  -r) rm -f "$f" ;;
  -) cat > "$f" ;;
  *) cat "$1" > "$f" ;;
esac
`);
    for (const t of ["qmd", "graphify"]) exe(join(bin, t), "#!/bin/sh\nexit 0\n");
    // claude: `plugin list --json` and `plugin enable|disable <spec> --scope user` over a store in $HOME;
    // every template plugin is installed at user scope, the on-demand tier disabled.
    exe(join(bin, "claude"), `#!/usr/bin/env node
const fs = require("fs"), path = require("path");
const store = path.join(process.env.HOME, ".fake-plugins.json");
let s;
try { s = JSON.parse(fs.readFileSync(store, "utf8")); } catch {
  const t = JSON.parse(fs.readFileSync(${JSON.stringify(join(CHECKOUT, "docs/setup/settings-template.json"))}, "utf8"));
  s = {};
  for (const k of Object.keys(t.enabledPlugins || {})) s[k] = true;
  for (const k of Object.keys(t.onDemandPlugins || {})) s[k] = false;
}
const a = process.argv.slice(2);
if (a[0] === "plugin" && a[1] === "list") process.stdout.write(JSON.stringify(Object.entries(s).map(([id, enabled]) => ({ id, scope: "user", enabled }))) + "\\n");
else if (a[0] === "plugin" && (a[1] === "enable" || a[1] === "disable")) {
  if (!(a[2] in s)) { console.error("no such plugin " + a[2]); process.exit(1); }
  s[a[2]] = a[1] === "enable";
  fs.writeFileSync(store, JSON.stringify(s));
}
`);
    const doctor = join(dir, "doctor.sh");
    exe(doctor, "#!/bin/sh\nexit 0\n");
    const cron = join(bin, "crontab");
    env = {
      PATH: `${bin}:${process.env.PATH}`, HOME: home, CONFIG_UI_IDLE_MS: "600000",
      HIMMELCTL_REPO_ROOT: repo, HIMMEL_REPORT_DOCTOR: doctor, HIMMEL_RUNTIME_PREFLIGHT: "0",
      DOCTORCAD_CRONTAB: cron, QMD_CADENCE_CRONTAB: cron, GRAPHMAP_CRONTAB: cron, PIPELINE_CRONTAB: cron,
    };
    const s = startServer({ port: 0, token: TOKEN, env: { ...env } });
    port = s.port; stop = s.stop;
  });
  afterAll(() => {
    stop();
    rmSync(dir, { recursive: true, force: true });
    expect(guardState()).toBe(guardBefore); // the checkout's .env and lanes overlay are untouched
  });

  const api = (path: string, body?: unknown) => fetch(`http://127.0.0.1:${port}${path}`, body === undefined ? { headers: { "X-Himmel-Token": TOKEN } } : {
    method: "POST", body: JSON.stringify(body), headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json" },
  });
  // A toggle exactly as the console drives it: the dry-run binds a preview id; confirm runs that.
  async function toggle(action: string, target: string, value?: string) {
    const req = { action, target, ...(value ? { value } : {}) };
    const pv = await api("/api/preview", req);
    const pj = await pv.json();
    expect(pv.status, JSON.stringify(pj)).toBe(200);
    expect(pj.command).toContain("--dry-run");
    const r = await api("/api/run", { previewId: pj.previewId, ...req, consent: pj.consent.kind === "typed" ? pj.consent.expect : undefined });
    const j = await r.json();
    expect(r.status, JSON.stringify(j)).toBe(200);
    expect(j.rc, j.output).toBe(0);
    expect(j.reprobe).toBe("ok");
    return j as { after: Record<string, { installed: string; health: string }>; output: string };
  }
  // The reload: a fresh full report (the action dropped the cached one).
  async function feedRow(id: string) {
    for (;;) {
      const r = await api("/api/feed");
      if (r.status === 202) continue;
      expect(r.status).toBe(200);
      const row = (await r.json()).rows.find((x: { id: string }) => x.id === id);
      expect(row, `feed row ${id}`).toBeDefined();
      return row as { installed: { state: string; detail: string }; health: string; control: { class: string; action: string } };
    }
  }
  const run = (argv: string[], input = "", extra: Record<string, string> = {}) => {
    const r = spawnSync(argv[0], argv.slice(1), { env: { ...env, ...extra }, input, encoding: "utf8", cwd: dir });
    return { rc: r.status, out: String(r.stdout) + String(r.stderr) };
  };

  test("the registries offer plugin and lane targets (the per-target rows below are not vacuous)", () => {
    expect(PLUGINS.length).toBeGreaterThan(0);
    expect(LANES.length).toBeGreaterThan(0);
  });

  test.each(LINUX_CADENCES)("cadence %s: arm, then disarm", async (c) => {
    const id = `${c}-cadence`;
    const status = () => run(["bash", join(CHECKOUT, CADENCE_SCRIPT[c]), "status"]).out;
    expect((await feedRow(id)).control).toMatchObject({ class: "toggle", action: "cadence.arm" });

    const on = await toggle("cadence.arm", c);
    expect(readFileSync(join(home, ".fake-crontab"), "utf8")).not.toBe(""); // written: a crontab entry
    expect(status()).toMatch(/^ARMED\b/m); // the owner reads it back
    expect(on.after[id]).toEqual({ installed: "present", health: "ok" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "present" }, health: "ok", control: { action: "cadence.disarm" } });

    const off = await toggle("cadence.disarm", c);
    expect(status()).toMatch(/^not armed\b/m);
    expect(off.after[id]).toEqual({ installed: "absent", health: "off" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "absent" }, health: "off", control: { action: "cadence.arm" } });
  }, 120_000);

  test.each(LEGS)("initiative %s: on, then off", async (leg) => {
    const id = `initiative:${leg}`;
    const get = () => run(["node", BIN, "config", "get", `initiative.${leg}`]).out.trim();
    // The consumer: the SessionStart hook reads HIMMEL_INITIATIVE from the himmel clone's .env. HIMMEL_REPO names
    // the clone; unset, the hook takes the git toplevel of its own path (the real checkout, behind the symlink).
    const hook = () => run(["bash", join(CHECKOUT, "scripts/hooks/inject-initiative.sh")], JSON.stringify({ session_id: `t-${leg}-${Math.random()}` }), { HIMMEL_REPO: repo });
    const envFile = () => readFileSync(join(repo, ".env"), "utf8");
    expect((await feedRow(id)).installed.state).toBe("absent");

    const on = await toggle("config.initiative", leg, "on");
    expect(envFile()).toMatch(new RegExp(`^HIMMEL_INITIATIVE=.*\\b${leg}\\b`, "m"));
    expect(get()).toBe(`initiative.${leg}: on`);
    const h = hook();
    expect(h.rc).toBe(0);
    expect(h.out).toMatch(new RegExp(`Active steps:.*\\b${leg}\\b`));
    expect(on.after[id]).toEqual({ installed: "present", health: "ok" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "present", detail: "on" }, health: "ok" });

    const off = await toggle("config.initiative", leg, "off");
    expect(envFile()).not.toMatch(new RegExp(`^HIMMEL_INITIATIVE=.*\\b${leg}\\b`, "m"));
    expect(get()).toBe(`initiative.${leg}: off`);
    expect(hook().out).not.toMatch(/Active steps/);
    expect(off.after[id]).toEqual({ installed: "absent", health: "off" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "absent", detail: "off" }, health: "off" });
  }, 60_000);

  // The on-demand plugins the action table offers (the floor is never a target).
  test.each(PLUGIN_CASES)("plugin %s: enable, then disable", async (spec) => {
    const id = `plugin:${spec}`;
    const store = () => JSON.parse(readFileSync(join(home, ".fake-plugins.json"), "utf8"))[spec];
    const listed = () => JSON.parse(run(["bash", join(repo, "scripts/machine-setup/plugin-profile.sh"), "list", "--json"]).out)
      .onDemand.find((p: { spec: string }) => p.spec === spec).state;
    expect((await feedRow(id)).control).toMatchObject({ class: "toggle", action: "plugin.enable" });

    const on = await toggle("plugin.enable", spec);
    expect(store()).toBe(true); // written at user scope
    expect(listed()).toBe("enabled"); // the profile owner reads it back
    expect(on.after[id]).toEqual({ installed: "present", health: "ok" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "present" }, health: "ok", control: { action: "plugin.disable" } });

    const off = await toggle("plugin.disable", spec);
    expect(store()).toBe(false);
    expect(listed()).toBe("disabled");
    expect(off.after[id]).toEqual({ installed: "absent", health: "off" });
    expect(await feedRow(id)).toMatchObject({ installed: { state: "absent" }, health: "off", control: { action: "plugin.enable" } });
  }, 60_000);

  // The registered lanes.
  // KNOWN GAP (HIMMEL-4807, config-feed.js laneRows): on writes probe.kind=always and off writes
  // probe.kind=never, but the row reads installed "present", health "info", detail "local override in
  // lanes.local.json" for BOTH, so after a reload the console cannot tell on from off (render.js offers both
  // buttons for that reason). The write and its read-back work; the row only shows that an override exists.
  test.each(LANE_CASES)("lane %s: on, then off (the row cannot show which)", async (lane) => {
    const id = `lane:${lane}`;
    const overlay = () => JSON.parse(readFileSync(join(repo, "scripts/lanes/lanes.local.json"), "utf8")).lanes.find((l: { id: string }) => l.id === lane);
    const get = () => run(["node", BIN, "config", "get", `lanes.${lane}`]).out;
    expect((await feedRow(id)).installed.detail).toBe("registry default");

    const on = await toggle("config.lanes", lane, "on");
    expect(overlay().probe.kind).toBe("always");
    expect(get()).toContain("override probe.kind=always");
    const onRow = await feedRow(id);
    expect(onRow.installed.detail).toBe("local override in lanes.local.json");

    const off = await toggle("config.lanes", lane, "off");
    expect(overlay().probe.kind).toBe("never");
    expect(get()).toContain("override probe.kind=never");
    const offRow = await feedRow(id);
    // The gap, asserted: on and off read the same after a reload.
    expect(off.after).toEqual(on.after);
    expect(on.after[id]).toEqual({ installed: "present", health: "info" });
    expect({ i: offRow.installed, h: offRow.health }).toEqual({ i: onRow.installed, h: onRow.health });
  }, 60_000);
});
