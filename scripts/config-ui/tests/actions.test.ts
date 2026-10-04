import { test, expect, beforeAll, afterAll, beforeEach, afterEach } from "bun:test";
import { execFileSync, spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

// Seams: CONFIG_UI_HIMMELCTL (stub-recorder.js), HIMMEL_REPORT_CADENCE_ROOT (a
// scratch tree of stub-cadence.sh copies), HOME (scratch: lock + audit), and the
// function-only opts root (scratch git repo for the registries and cwd), now,
// actionTimeoutMs, reprobeBudgetMs. No real action, cadence or ~/.himmel is touched.
const TOKEN = "t".repeat(64);
const CANARY = "ghp_" + "Z9y8".repeat(8);
const CADENCES = ["scripts/luna/pipeline-cadence.sh", "scripts/luna/graphmap-cadence.sh", "scripts/luna/qmd-cadence.sh",
  "scripts/cleanup/codex-sweep-cadence.sh", "scripts/doctor-cadence.sh"];
let dir = "", repo = "", home = "", cad = "", state = "", argvFile = "";
const stops: (() => void)[] = [];

beforeAll(() => {
  repo = mkdtempSync(join(tmpdir(), "cfgui-repo-"));
  const git = (...a: string[]) => execFileSync("git", ["-C", repo, "-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false", ...a], { stdio: "ignore" });
  const reg = (plugins: string[], lanes: string[]) => {
    mkdirSync(join(repo, "docs/setup"), { recursive: true });
    mkdirSync(join(repo, "scripts/lanes"), { recursive: true });
    writeFileSync(join(repo, "docs/setup/settings-template.json"), JSON.stringify({ onDemandPlugins: Object.fromEntries(plugins.map((p) => [p, {}])) }));
    writeFileSync(join(repo, "scripts/lanes/lanes.json"), JSON.stringify({ lanes: lanes.map((id) => ({ id })) }));
  };
  git("init", "-q");
  reg(["a@m"], ["l1"]);
  git("add", "-A");
  git("commit", "-q", "-m", "reg");
  reg(["a@m", "dirty@m"], ["l1"]); // a dirty working-tree edit must not widen the list
});
afterAll(() => rmSync(repo, { recursive: true, force: true }));
beforeEach(() => {
  dir = mkdtempSync(join(tmpdir(), "cfgui-act-"));
  home = join(dir, "home"); cad = join(dir, "cad"); state = join(dir, "state"); argvFile = join(dir, "argv");
  for (const d of [home, state]) mkdirSync(d, { recursive: true });
  for (const c of CADENCES) { mkdirSync(join(cad, c, ".."), { recursive: true }); copyFileSync(join(import.meta.dir, "stub-cadence.sh"), join(cad, c)); }
  writeFileSync(argvFile, "");
});
afterEach(() => { while (stops.length) stops.pop()!(); rmSync(dir, { recursive: true, force: true }); });

type Extra = { env?: Record<string, string>; now?: () => number; actionTimeoutMs?: number; reprobeBudgetMs?: number };
function boot(x: Extra = {}) {
  const env = { PATH: process.env.PATH, HOME: home, CONFIG_UI_HIMMELCTL: join(import.meta.dir, "stub-recorder.js"),
    HIMMEL_REPORT_CADENCE_ROOT: cad, STUB_ARGV: argvFile, STUB_STATE: state, CONFIG_UI_IDLE_MS: "60000", ...x.env };
  const s = startServer({ port: 0, token: TOKEN, env, root: repo, now: x.now, actionTimeoutMs: x.actionTimeoutMs, reprobeBudgetMs: x.reprobeBudgetMs } as never);
  stops.push(() => s.stop());
  return s.port;
}
const recorded = () => readFileSync(argvFile, "utf8").split("\n").filter(Boolean);
function post(port: number, path: string, body: unknown, h: Record<string, string> = {}) {
  return fetch(`http://127.0.0.1:${port}${path}`, {
    method: "POST", body: typeof body === "string" ? body : JSON.stringify(body),
    headers: { "X-Himmel-Token": TOKEN, Origin: `http://127.0.0.1:${port}`, "Content-Type": "application/json", ...h },
  });
}
const preview = (port: number, body: Record<string, unknown> = { action: "cadence.arm", target: "graphmap" }) => post(port, "/api/preview", body);
async function previewId(port: number, body?: Record<string, unknown>) {
  const r = await preview(port, body);
  expect(r.status).toBe(200);
  return (await r.json()).previewId as string;
}
const ARM = { action: "cadence.arm", target: "graphmap" };

// ── T4.1 ────────────────────────────────────────────────────────────────
test("preview cadence.arm graphmap runs exactly `arm --dry-run` and returns a preview id", async () => {
  const port = boot();
  const r = await preview(port);
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.previewId).toMatch(/^[0-9a-f]{32}$/);
  expect(b.output).toContain("plan: graphmap-cadence arm --dry-run");
  expect(b.consent).toEqual({ kind: "typed", expect: "graphmap" });
  expect(recorded()).toEqual(["graphmap-cadence.sh arm --dry-run"]);
});

test("run with the preview id and typed consent runs exactly `arm`, then re-probes that row", async () => {
  const port = boot();
  const id = await previewId(port);
  const r = await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" });
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.rc).toBe(0);
  const lines = recorded();
  expect(lines.filter((l) => l.startsWith("graphmap-cadence.sh"))).toEqual(["graphmap-cadence.sh arm --dry-run", "graphmap-cadence.sh arm"]);
  const reports = lines.filter((l) => l.startsWith("himmelctl"));
  expect(reports.length).toBeGreaterThan(0);
  for (const l of reports) expect(l).toBe("himmelctl report --json --items graphmap-cadence");
  expect(b.before).toEqual({ "graphmap-cadence": { installed: "absent", health: "off" } });
  expect(b.after).toEqual({ "graphmap-cadence": { installed: "present", health: "ok" } });
});

const bad400: [string, Record<string, unknown>][] = [
  ["unknown action", { action: "shell.exec", target: "graphmap" }],
  ["inherited key as action", { action: "__proto__", target: "graphmap" }],
  ["target outside the list", { action: "cadence.arm", target: "nightly" }],
  ["leading-dash id", { action: "plugin.enable", target: "-a@m" }],
  ["id with a space", { action: "plugin.enable", target: "a @m" }],
  ["id not in the frozen list", { action: "plugin.enable", target: "z@m" }],
  ["dirty-worktree-only id", { action: "plugin.enable", target: "dirty@m" }],
  ["value on a non-config action", { action: "cadence.arm", target: "graphmap", value: "on" }],
  ["config.lanes without a value", { action: "config.lanes", target: "l1" }],
  ["config.lanes with a value outside on/off", { action: "config.lanes", target: "l1", value: "yes" }],
  ["non-string target", { action: "cadence.arm", target: ["graphmap"] }],
  ["codex-sweep off Windows (T4.6)", { action: "cadence.arm", target: "codex-sweep" }],
];
for (const [name, body] of bad400) {
  test(`preview refuses ${name} with 400 and runs nothing`, async () => {
    if (name.includes("codex-sweep") && process.platform === "win32") return;
    const port = boot();
    expect((await preview(port, body)).status).toBe(400);
    expect(recorded()).toEqual([]);
  });
}

test("malformed JSON is 400 and runs nothing", async () => {
  const port = boot();
  expect((await post(port, "/api/preview", "{not json")).status).toBe(400);
  expect(recorded()).toEqual([]);
});

for (const path of ["/api/preview", "/api/run"]) {
  test(`${path}: no token 401, foreign Host 403, foreign or missing Origin 403, text/plain 415; no child runs`, async () => {
    const port = boot();
    const body = path === "/api/preview" ? ARM : { previewId: "0".repeat(32), ...ARM, consent: "graphmap" };
    expect((await post(port, path, body, { "X-Himmel-Token": "" })).status).toBe(401);
    expect((await post(port, path, body, { Host: "evil.test" })).status).toBe(403);
    expect((await post(port, path, body, { Origin: "http://evil.test" })).status).toBe(403);
    const noOrigin = await fetch(`http://127.0.0.1:${port}${path}`, { method: "POST", body: JSON.stringify(body), headers: { "X-Himmel-Token": TOKEN, "Content-Type": "application/json" } });
    expect(noOrigin.status).toBe(403);
    expect((await post(port, path, body, { "Content-Type": "text/plain" })).status).toBe(415);
    expect(recorded()).toEqual([]);
  });
}

// ── T4.3 preview binding ─────────────────────────────────────────────────
test("a reused preview id is 409", async () => {
  const port = boot();
  const id = await previewId(port);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(200);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(409);
});

test("an expired preview id is 409 (fake clock)", async () => {
  let t = 1_000_000;
  const port = boot({ now: () => t });
  const id = await previewId(port);
  t += 5 * 60 * 1000 + 1;
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(409);
  expect(recorded()).toEqual(["graphmap-cadence.sh arm --dry-run"]);
});

test("an id from a different action, a missing id, or a different value is 409", async () => {
  const port = boot();
  const id = await previewId(port);
  expect((await post(port, "/api/run", { previewId: id, action: "cadence.disarm", target: "graphmap", consent: "graphmap" })).status).toBe(409);
  expect((await post(port, "/api/run", { previewId: id, action: "cadence.arm", target: "qmd", consent: "qmd" })).status).toBe(409);
  expect((await post(port, "/api/run", { ...ARM, consent: "graphmap" })).status).toBe(409);
  expect((await post(port, "/api/run", { previewId: "f".repeat(32), ...ARM, consent: "graphmap" })).status).toBe(409);
  const lane = await previewId(port, { action: "config.lanes", target: "l1", value: "on" });
  expect((await post(port, "/api/run", { previewId: lane, action: "config.lanes", target: "l1", value: "off" })).status).toBe(409);
  expect(recorded().filter((l) => !l.includes("--dry-run"))).toEqual([]);
});

test("wrong typed consent is 403 and keeps the id; the right string then runs", async () => {
  const port = boot();
  const id = await previewId(port);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphma" })).status).toBe(403);
  expect((await post(port, "/api/run", { previewId: id, ...ARM })).status).toBe(403);
  expect(recorded()).toEqual(["graphmap-cadence.sh arm --dry-run"]);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(200);
});

test("profile.set needs the verb typed; plain-consent config runs without consent", async () => {
  const port = boot();
  const p = await previewId(port, { action: "profile.set", target: "lean" });
  expect((await post(port, "/api/run", { previewId: p, action: "profile.set", target: "lean", consent: "full" })).status).toBe(403);
  expect((await post(port, "/api/run", { previewId: p, action: "profile.set", target: "lean", consent: "lean" })).status).toBe(200);
  const l = await previewId(port, { action: "config.initiative", target: "pr", value: "on" });
  expect((await post(port, "/api/run", { previewId: l, action: "config.initiative", target: "pr", value: "on" })).status).toBe(200);
  expect(recorded()).toContain("himmelctl config set initiative.pr on");
});

// ── T4.4 lock and process group ──────────────────────────────────────────
const lockPath = () => join(home, ".himmel/state/config-ui/write.lock");

test("two concurrent runs: the second is 409", async () => {
  const port = boot({ env: { STUB_SLOW: "1" } });
  const a = await previewId(port);
  const b = await previewId(port, { action: "cadence.arm", target: "qmd" });
  const ra = post(port, "/api/run", { previewId: a, ...ARM, consent: "graphmap" });
  await Bun.sleep(200);
  const rb = await post(port, "/api/run", { previewId: b, action: "cadence.arm", target: "qmd", consent: "qmd" });
  expect(rb.status).toBe(409);
  expect((await ra).status).toBe(200);
  expect(existsSync(lockPath())).toBe(false);
});

test("a second server instance on the same HOME gets 409 while the first runs", async () => {
  const p1 = boot({ env: { STUB_SLOW: "1" } });
  const p2 = boot();
  const a = await previewId(p1);
  const ra = post(p1, "/api/run", { previewId: a, ...ARM, consent: "graphmap" });
  await Bun.sleep(200);
  expect((await preview(p2, { action: "cadence.arm", target: "qmd" })).status).toBe(409);
  expect((await ra).status).toBe(200);
});

test("a lock file holding a dead pid is replaced and the run succeeds", async () => {
  const dead = spawnSync("true").pid!;
  mkdirSync(join(lockPath(), ".."), { recursive: true });
  writeFileSync(lockPath(), String(dead));
  const port = boot();
  const id = await previewId(port);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(200);
  expect(existsSync(lockPath())).toBe(false);
});

test("a live foreign lock is 409", async () => {
  mkdirSync(join(lockPath(), ".."), { recursive: true });
  writeFileSync(lockPath(), String(process.pid));
  const port = boot();
  expect((await preview(port)).status).toBe(409);
  expect(existsSync(lockPath())).toBe(true);
});

test("a timed-out child's whole process group is killed before the lock is released", async () => {
  const port = boot({ env: { STUB_HANG: "1" }, actionTimeoutMs: 600 });
  const id = await previewId(port);
  const r = await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" });
  expect(r.status).toBe(200);
  expect((await r.json()).timedOut).toBe(true);
  expect(existsSync(lockPath())).toBe(false);
  const gc = Number(readFileSync(join(state, "grandchild"), "utf8"));
  // with no /proc (off Linux) the kill(0) answer stands, so this is not vacuous
  const alive = () => {
    try { process.kill(gc, 0); } catch { return false; }
    try { return !readFileSync(`/proc/${gc}/stat`, "utf8").includes(") Z "); } catch { return true; }
  };
  for (let i = 0; i < 20 && alive(); i++) await Bun.sleep(50);
  expect(alive()).toBe(false);
});

// ── T4.5 redaction, re-probe, audit ──────────────────────────────────────
test("a canary printed by a child is absent from preview, run and error bodies", async () => {
  const port = boot({ env: { STUB_LEAK: CANARY } });
  const pr = await preview(port);
  const pt = await pr.text();
  expect(pt).toContain("plan: graphmap-cadence");
  expect(pt).not.toContain(CANARY);
  const id = JSON.parse(pt).previewId;
  const rt = await (await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).text();
  expect(rt).not.toContain(CANARY);
  const failing = boot({ env: { STUB_LEAK: CANARY, STUB_RC: "3" } });
  const ft = await (await preview(failing)).text();
  expect(ft).toContain("err: graphmap-cadence");
  expect(ft).not.toContain(CANARY);
});

test("a slow re-probe returns `re-probe timed out`", async () => {
  const port = boot({ env: { STUB_REPROBE_SLEEP: "3000" }, reprobeBudgetMs: 300 });
  const id = await previewId(port);
  const b = await (await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).json();
  expect(b.reprobe).toBe("re-probe timed out");
});

test("a re-probe that exits non-zero is `re-probe failed`, even with valid JSON", async () => {
  const port = boot({ env: { STUB_REPORT_RC: "2" } });
  const id = await previewId(port);
  const b = await (await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).json();
  expect(b.reprobe).toBe("re-probe failed");
  expect(b.before).toBeNull();
});

test("a re-probe that omits a requested row is `re-probe incomplete`", async () => {
  const port = boot({ env: { STUB_REPORT_DROP: "1" } });
  const id = await previewId(port);
  const b = await (await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).json();
  expect(b.reprobe).toBe("re-probe incomplete");
});

test("an audit append that fails after the action ran still answers 200, flagged `audit: failed`", async () => {
  mkdirSync(join(home, ".himmel/state/config-ui/actions.jsonl"), { recursive: true }); // a directory: append fails
  const port = boot();
  const id = await previewId(port);
  const r = await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" });
  expect(r.status).toBe(200);
  const b = await r.json();
  expect(b.rc).toBe(0);
  expect(b.audit).toBe("failed");
});

test("each run appends one audit line with an exact key set, table argv and no output", async () => {
  const port = boot({ env: { STUB_LEAK: CANARY } });
  const id = await previewId(port);
  expect((await post(port, "/api/run", { previewId: id, ...ARM, consent: "graphmap" })).status).toBe(200);
  const lines = readFileSync(join(home, ".himmel/state/config-ui/actions.jsonl"), "utf8").trim().split("\n");
  expect(lines.length).toBe(1);
  expect(lines[0]).not.toContain(CANARY);
  const a = JSON.parse(lines[0]);
  expect(Object.keys(a).sort()).toEqual(["action", "after", "argv", "before", "rc", "target", "time", "value"]);
  expect(a.argv).toEqual(["bash", join(cad, "scripts/luna/graphmap-cadence.sh"), "arm"]);
  expect(a).toMatchObject({ action: "cadence.arm", target: "graphmap", value: null, rc: 0, before: { "graphmap-cadence": "off" }, after: { "graphmap-cadence": "ok" } });
});

// ── HIMMEL-4350 item 3: security headers on every response ────────────────
test("every response carries CSP default-src 'self' and X-Frame-Options DENY", async () => {
  const port = boot();
  const rs = [
    await fetch(`http://127.0.0.1:${port}/`), await fetch(`http://127.0.0.1:${port}/app.js`),
    await fetch(`http://127.0.0.1:${port}/nope`), await fetch(`http://127.0.0.1:${port}/api/feed`),
    await fetch(`http://127.0.0.1:${port}/`, { headers: { Host: "evil.test" } }), await preview(port, { action: "x", target: "y" }),
  ];
  for (const r of rs) {
    expect(r.headers.get("content-security-policy")).toBe("default-src 'self'");
    expect(r.headers.get("x-frame-options")).toBe("DENY");
  }
});
