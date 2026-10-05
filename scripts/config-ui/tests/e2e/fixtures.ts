// HIMMEL-4400: fixture feeds + the server harness. The bundle order and titles
// come from the real scripts/himmelctl/lib/feed-bundles.json, so the suite
// checks the UI renders the CURRENT table order (a reorder there is followed,
// not flagged); the rows are synthetic and deterministic.
import { spawn, type ChildProcess } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:http";
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

export const HIMMEL_ID = { version: "0.9.9", describe: "v0.9.9-3-gabc", commit: "0123456789abcdef0123456789abcdef01234567", checkout: "/srv/himmel-wt" };

// clean: no fail/warn rows (so the Health verdict can read All clear); failDetail overrides the fail row's detail.
export type Variant = { unmapped?: boolean; breakOrder?: boolean; noIdentity?: boolean; clean?: boolean; failDetail?: string };

export function buildFeed(v: Variant = {}) {
  const rows: ReturnType<typeof row>[] = [];
  for (const b of BUNDLES) {
    if (b.id === "bypass") for (let i = 0; i < 48; i++) rows.push(row(`flag:E2E_FLAG_${i}`, "off", "bypass"));
    else if (b.id === "search") { rows.push(row("qmd-binary", "ok", "search")); rows.push(row("doctor:C45-e2e-hit", "ok", "search", { source: "doctor" })); }
    else if (b.id === "guards") {
      if (v.clean) rows.push(row("guard-ok-1", "ok", "guards"), row("guard-ok-2", "ok", "guards"));
      else {
        rows.push(row("guard-fail", "fail", "guards", { fix: { remedy: "fix-guard-cmd", owner: "user" }, installed: { state: "present", detail: v.failDetail ?? "d-guard-fail" } }),
          row("guard-warn", "warn", "guards", { fix: { remedy: "warn-guard-cmd", owner: "user" } }),
          row("guard-ok-1", "ok", "guards"), row("guard-ok-2", "ok", "guards"));
      }
    } else if (b.id === "vault") {
      rows.push(row("pipeline-cadence", "off", "vault", toggle("cadence.arm", "pipeline")), row("vault-ok", "ok", "vault"),
        row("cadence:luna-pipeline", "ok", "vault", { source: "cadence", installed: { state: "present", detail: "armed e2e" }, fires: { state: "yes", evidence: "ran-e2e-evidence", at: "2026-10-04T12:00:00Z" } }));
    }
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
    ...(v.noIdentity ? {} : { himmel: HIMMEL_ID }),
    base: "/b", profileCache: true, bundles, rows,
    summary: { total: rows.length, ok: count("ok"), warn: count("warn"), fail: count("fail"), off: count("off"), info: 0 },
  };
}

export type Alert = { labels: Record<string, string>; annotations: Record<string, string> };
// HIMMEL-4405 PR-b seams. ledger: rows written to $HOME/.himmel/cadence-ledger.jsonl. handover: a temp root
// with one fleet manifest + one leg doc ending in the given bullet. prom: a loopback stub of /api/v1/alerts
// (absent: an unused port, so Prometheus is refused). feedDelayMs: the feed stub sleeps before answering.
export type BootOpts = { ledger?: object[]; handover?: { bullet: string }; prom?: { alerts: Alert[] }; feedDelayMs?: number };
export type Harness = {
  url: string; argv: () => string[]; stateFiles: () => string[]; stop: () => Promise<void>;
  ledgerLines: () => number; writeLedger: (rows: object[]) => void; setBullet: (bullet: string) => void; legDoc: string;
};

const writeRows = (file: string, rows: object[]) => { mkdirSync(join(file, ".."), { recursive: true }); writeFileSync(file, rows.map((r) => JSON.stringify(r) + "\n").join("")); };

// Starts the REAL `himmelctl ui --port 0`. The Claude session markers are
// dropped from the child env so the HIMMEL-4350 refusal is not tripped; the
// refusal itself is untouched (no --allow-agent-session anywhere).
export async function boot(v: Variant = {}, o: BootOpts = {}): Promise<Harness> {
  const dir = mkdtempSync(join(tmpdir(), "cfgui-e2e-"));
  const feed = join(dir, "feed.json"), argv = join(dir, "argv"), state = join(dir, "state"), cad = join(dir, "cad"), home = join(dir, "home");
  for (const d of [state, home]) mkdirSync(d, { recursive: true });
  writeFileSync(feed, JSON.stringify(buildFeed(v)));
  writeFileSync(argv, "");
  const ledger = join(home, ".himmel", "cadence-ledger.jsonl");
  if (o.ledger) writeRows(ledger, o.ledger);
  // HANDOVER_DIR always names a temp root: legs.sh falls back to the primary checkout's .env (the real luna root) when it is unset.
  const hroot = join(dir, "handover"), legDoc = join(hroot, "himmel", "HIMMEL-9999-N1-e2e-leg-RESUME.md");
  mkdirSync(join(hroot, "himmel"), { recursive: true });
  const setBullet = (b: string) => writeFileSync(legDoc, `# leg\n\n## Results\n- 02:00 LIVE — started\n${b}\n`);
  if (o.handover) {
    setBullet(o.handover.bullet);
    writeFileSync(join(hroot, "himmel", "c.fleet.json"), JSON.stringify({ schema: 1, legs: [{ doc: legDoc, label: "N1", added: "2026-10-05T00:00:00Z" }] }));
  }
  let prom: Server | undefined;
  let promUrl = "http://127.0.0.1:1";
  if (o.prom) {
    prom = createServer((req, res) => {
      res.setHeader("content-type", "application/json");
      res.end(req.url === "/api/v1/alerts" ? JSON.stringify({ status: "success", data: { alerts: o.prom!.alerts.map((a) => ({ ...a, state: "firing" })) } }) : "{}");
    });
    await new Promise<void>((ok) => prom!.listen(0, "127.0.0.1", ok));
    promUrl = `http://127.0.0.1:${(prom.address() as { port: number }).port}`;
  }
  const stubCad = join(ROOT, "scripts/config-ui/tests/stub-cadence.sh");
  for (const c of ["scripts/luna/pipeline-cadence.sh", "scripts/luna/graphmap-cadence.sh", "scripts/luna/qmd-cadence.sh", "scripts/cleanup/codex-sweep-cadence.sh", "scripts/doctor-cadence.sh"]) {
    mkdirSync(join(cad, c, ".."), { recursive: true });
    copyFileSync(stubCad, join(cad, c));
  }
  const env: Record<string, string | undefined> = {
    ...process.env, HOME: home, CONFIG_UI_HIMMELCTL: join(__dirname, "e2e-stub.js"), CONFIG_UI_IDLE_MS: "300000",
    HIMMEL_REPORT_CADENCE_ROOT: cad, E2E_FEED: feed, STUB_ARGV: argv, STUB_STATE: state,
    HANDOVER_DIR: hroot, HIMMEL_PROMETHEUS_URL: promUrl, HIMMEL_FLOW_EXPORTER_PORT: "1", E2E_FEED_DELAY_MS: String(o.feedDelayMs ?? 0),
  };
  delete env.CADENCE_BANK_LEDGER; // the operator's own ledger, root and monitoring never reach the child
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
    prom?.close();
    rmSync(dir, { recursive: true, force: true });
    throw e;
  }).finally(() => clearTimeout(timer));
  return {
    url,
    argv: () => readFileSync(argv, "utf8").split("\n").filter(Boolean),
    stateFiles: () => (existsSync(state) ? readdirSync(state) : []),
    ledgerLines: () => (existsSync(ledger) ? readFileSync(ledger, "utf8").split("\n").filter(Boolean).length : 0),
    writeLedger: (rows) => writeRows(ledger, rows),
    setBullet,
    legDoc,
    stop: async () => {
      prom?.close();
      child.kill("SIGTERM");
      await new Promise((r) => {
        if (child.exitCode !== null || child.signalCode !== null) return r(null);
        child.once("exit", r);
        setTimeout(() => { child.kill("SIGKILL"); r(null); }, 5_000).unref();
      });
      rmSync(dir, { recursive: true, force: true });
    },
  };
}
