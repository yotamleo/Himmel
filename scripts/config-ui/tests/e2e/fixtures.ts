// HIMMEL-4400: fixture feeds + the server harness. The bundle order and titles
// come from the real scripts/himmelctl/lib/feed-bundles.json, so a reorder
// there fails the suite; the rows are synthetic and deterministic.
import { spawn, type ChildProcess } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join, resolve } from "node:path";

const ROOT = resolve(__dirname, "../../../..");
export const BIN = join(ROOT, "scripts/himmelctl/bin.js");
export const BUNDLES: { id: string; title: string }[] = JSON.parse(
  readFileSync(join(ROOT, "scripts/himmelctl/lib/feed-bundles.json"), "utf8"),
).bundles.map((b: { id: string; title: string }) => ({ id: b.id, title: b.title }));

const row = (id: string, health: string, bundle: string, extra: Record<string, unknown> = {}) => ({
  id, source: "item", group: "core", bundle, title: id, health,
  declared: { where: "w", desired: "required", profile: "all" },
  installed: { state: health === "off" ? "absent" : "present", detail: `d-${id}` },
  fires: { state: "unverified", evidence: null, at: null },
  fix: { remedy: "", owner: "user" },
  probedAt: "2026-10-04T14:02:00Z", control: { class: "display-only" }, sensitive: false, ...extra,
});
const toggle = (action: string, target: string) => ({ control: { class: "toggle", action, target } });

export type Variant = { unmapped?: boolean; breakOrder?: boolean };

export function buildFeed(v: Variant = {}) {
  const rows: ReturnType<typeof row>[] = [];
  for (const b of BUNDLES) {
    if (b.id === "bypass") for (let i = 0; i < 48; i++) rows.push(row(`flag:E2E_FLAG_${i}`, "off", "bypass"));
    else if (b.id === "search") { rows.push(row("qmd-binary", "ok", "search")); rows.push(row("doctor:C45-e2e-hit", "ok", "search", { source: "doctor" })); }
    else if (b.id === "guards") {
      rows.push(row("guard-fail", "fail", "guards"), row("guard-warn", "warn", "guards"),
        row("guard-ok-1", "ok", "guards"), row("guard-ok-2", "ok", "guards"));
    } else if (b.id === "vault") rows.push(row("pipeline-cadence", "off", "vault", toggle("cadence.arm", "pipeline")), row("vault-ok", "ok", "vault"));
    else if (b.id === "workflow") rows.push(row("initiative:execute", "ok", "workflow", toggle("config.initiative", "execute")));
    else rows.push(row(`${b.id}-ok`, "ok", b.id));
  }
  if (v.unmapped) rows.push(row("orphan-row", "ok", "not-in-the-table"));
  const bundles = BUNDLES.map((b) => ({ ...b }));
  // E2E_BREAK=order: the RED control, a deliberately mis-ordered feed the suite must reject.
  if (v.breakOrder ?? process.env.E2E_BREAK === "order") [bundles[0], bundles[1]] = [bundles[1], bundles[0]];
  const count = (h: string) => rows.filter((r) => r.health === h).length;
  return {
    schema: "himmel-config-feed/1", generatedAt: "2026-10-04T14:02:00Z", target: { scope: "user", path: "/x" },
    base: "/b", profileCache: true, bundles, rows,
    summary: { total: rows.length, ok: count("ok"), warn: count("warn"), fail: count("fail"), off: count("off"), info: 0 },
  };
}

export type Harness = { url: string; argv: () => string[]; stateFiles: () => string[]; stop: () => Promise<void> };

// Starts the REAL `himmelctl ui --port 0`. The Claude session markers are
// dropped from the child env so the HIMMEL-4350 refusal is not tripped; the
// refusal itself is untouched (no --allow-agent-session anywhere).
export async function boot(v: Variant = {}): Promise<Harness> {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-e2e-"));
  const feed = join(dir, "feed.json"), argv = join(dir, "argv"), state = join(dir, "state"), cad = join(dir, "cad"), home = join(dir, "home");
  for (const d of [state, home]) mkdirSync(d, { recursive: true });
  writeFileSync(feed, JSON.stringify(buildFeed(v)));
  writeFileSync(argv, "");
  const stubCad = join(ROOT, "scripts/config-ui/tests/stub-cadence.sh");
  for (const c of ["scripts/luna/pipeline-cadence.sh", "scripts/luna/graphmap-cadence.sh", "scripts/luna/qmd-cadence.sh", "scripts/cleanup/codex-sweep-cadence.sh", "scripts/doctor-cadence.sh"]) {
    mkdirSync(join(cad, c, ".."), { recursive: true });
    copyFileSync(stubCad, join(cad, c));
  }
  const env: Record<string, string | undefined> = {
    ...process.env, HOME: home, CONFIG_UI_HIMMELCTL: join(__dirname, "e2e-stub.js"), CONFIG_UI_IDLE_MS: "300000",
    HIMMEL_REPORT_CADENCE_ROOT: cad, E2E_FEED: feed, STUB_ARGV: argv, STUB_STATE: state,
  };
  for (const k of Object.keys(env)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete env[k];
  const child: ChildProcess = spawn("node", [BIN, "ui", "--port", "0"], { env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const url = await new Promise<string>((ok, fail) => {
    let buf = "", err = "";
    child.stderr!.on("data", (d) => (err += d));
    child.stdout!.on("data", (d) => {
      buf += d;
      const m = /(http:\/\/127\.0\.0\.1:\d+\/#t=[0-9a-f]{64})/.exec(buf);
      if (m) ok(m[1]);
    });
    child.on("error", fail);
    child.on("exit", (c) => fail(new Error(`himmelctl ui exited ${c}: ${err}`)));
    timer = setTimeout(() => fail(new Error("himmelctl ui printed no URL in 15 s")), 15_000);
  }).catch((e) => {
    child.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true });
    throw e;
  }).finally(() => clearTimeout(timer));
  return {
    url,
    argv: () => readFileSync(argv, "utf8").split("\n").filter(Boolean),
    stateFiles: () => (existsSync(state) ? readdirSync(state) : []),
    stop: async () => {
      child.kill("SIGTERM");
      await new Promise((r) => (child.exitCode !== null || child.signalCode !== null ? r(null) : child.once("exit", r)));
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
