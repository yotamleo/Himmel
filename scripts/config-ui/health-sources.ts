// health-sources.ts — the three read-only sources behind GET /api/health (HIMMEL-4405).
// Each section is {state: ok|absent|error, reason?, ...data} and degrades alone (I3).
// Nothing here computes a verdict or runs a probe: the bank row is read from the
// ledger bank-preflight already wrote (I2), the legs from legs.sh, monitoring over loopback (I7).
import { spawn } from "node:child_process";
import { closeSync, fstatSync, openSync, readSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

type Env = Record<string, string | undefined>;
export type Section = { state: "ok" | "absent" | "error"; reason?: string; [k: string]: unknown };

const TAIL_BYTES = 64 * 1024;
const MONITOR_TIMEOUT_MS = 2000;
const LEGS_TIMEOUT_MS = 5000;

// The newest ledger row that carries bank numbers, read from the file's last 64 KiB.
export function readBank(env: Env): Section {
  const file = env.CADENCE_BANK_LEDGER || join(env.HOME || homedir(), ".himmel", "cadence-ledger.jsonl");
  let text: string;
  try {
    const fd = openSync(file, "r");
    try {
      const size = fstatSync(fd).size, start = Math.max(0, size - TAIL_BYTES);
      const from = Math.max(0, start - 1); // one byte early: tells a window that begins on a line start from one cut mid-row
      const buf = Buffer.alloc(size - from);
      readSync(fd, buf, 0, buf.length, from);
      text = buf.toString("utf8");
      if (start > 0) text = text.slice(text.indexOf("\n") + 1); // drops the cut row, or just the byte before a whole one
    } finally { closeSync(fd); }
  } catch { return { state: "absent", reason: "no bank-preflight ledger" }; }
  const lines = text.split("\n");
  for (let i = lines.length - 1; i >= 0; i--) {
    let r: Record<string, unknown>;
    try { r = JSON.parse(lines[i]); } catch { continue; }
    if (!r || typeof r !== "object" || (r.five_hour == null || r.five_hour === "") && (r.seven_day == null || r.seven_day === "")) continue;
    const { ts, verdict, five_hour, seven_day, age, degraded } = r;
    return { state: "ok", row: { ts, verdict, five_hour, seven_day, age, degraded } };
  }
  return { state: "absent", reason: "no bank-preflight ledger row with bank numbers" };
}

// legs.sh in its own process group, so a hung child cannot hold the response past the budget.
export function readLegs(script: string, env: Env, timeoutMs = LEGS_TIMEOUT_MS): Promise<Section> {
  return new Promise((resolve) => {
    let out = "", done = false;
    const child = spawn("bash", [script], { env: env as NodeJS.ProcessEnv, detached: true, stdio: ["ignore", "pipe", "ignore"] });
    const finish = (s: Section) => { if (!done) { done = true; clearTimeout(timer); resolve(s); } };
    const timer = setTimeout(() => {
      try { process.kill(-child.pid!, "SIGKILL"); } catch { /* already gone */ }
      finish({ state: "error", reason: "legs view timed out" });
    }, timeoutMs);
    child.stdout.on("data", (d) => { out += d; });
    child.on("error", () => finish({ state: "error", reason: "legs view failed to start" }));
    child.on("close", (rc) => {
      if (rc === 3) return finish({ state: "absent", reason: "no handover root" });
      if (rc !== 0) return finish({ state: "error", reason: `legs view exited ${rc}` });
      try {
        const j = JSON.parse(out);
        if (!j.manifest) return finish({ state: "absent", reason: "no fleet manifest" });
        finish({ state: "ok", manifest: j.manifest, legs: j.legs });
      } catch { finish({ state: "error", reason: "legs view printed no JSON" }); }
    });
  });
}

const LOOPBACK_HOSTS = new Set(["127.0.0.1", "localhost", "[::1]", "::1"]);
const refused = (e: unknown) => { const c = (e as { code?: string })?.code; return c === "ConnectionRefused" || c === "ECONNREFUSED"; };

async function probe(url: string): Promise<{ res?: Response; section?: Section }> {
  try {
    const res = await fetch(url, { redirect: "error", signal: AbortSignal.timeout(MONITOR_TIMEOUT_MS) }); // a redirect could leave loopback
    if (!res.ok) return { section: { state: "error", reason: `HTTP ${res.status}` } };
    return { res };
  } catch (e) {
    return { section: refused(e) ? { state: "absent", reason: "not running" } : { state: "error", reason: "no answer" } };
  }
}

// Prometheus firing alerts and the flow exporter, both loopback-only and both optional.
export async function readMonitoring(env: Env): Promise<Section> {
  const base = env.HIMMEL_PROMETHEUS_URL || "http://127.0.0.1:9090";
  const port = env.HIMMEL_FLOW_EXPORTER_PORT || "9877";
  let promUrl: URL;
  try { promUrl = new URL(base); } catch { return { state: "error", reason: "bad HIMMEL_PROMETHEUS_URL", prometheus: { state: "error" }, exporter: { state: "absent" } }; }
  if (!LOOPBACK_HOSTS.has(promUrl.hostname)) return { state: "error", reason: "non-loopback URL refused", prometheus: { state: "error", reason: "non-loopback URL refused" }, exporter: { state: "absent" } };

  const [p, e] = await Promise.all([
    probe(`${promUrl.origin}/api/v1/alerts`),
    probe(`http://127.0.0.1:${/^\d+$/.test(port) ? port : "9877"}/metrics`),
  ]);
  let prometheus: Section = p.section ?? { state: "ok" };
  if (p.res) {
    try {
      const j = (await p.res.json()) as { status?: string; data?: { alerts?: { state?: string; labels?: Record<string, string>; annotations?: Record<string, string> }[] } };
      if (j.status !== "success" || !Array.isArray(j.data?.alerts)) throw new Error("not a Prometheus alerts answer");
      const alerts = j.data!.alerts!.filter((a) => a.state === "firing")
        .map((a) => ({ alertname: a.labels?.alertname ?? "", severity: a.labels?.severity ?? "", summary: a.annotations?.summary ?? "" }));
      prometheus = { state: "ok", alerts };
    } catch { prometheus = { state: "error", reason: "unreadable alerts" }; }
  }
  const exporter: Section = e.section ?? { state: "ok" };
  const state = prometheus.state === "ok" || exporter.state === "ok" ? "ok" : prometheus.state === "error" || exporter.state === "error" ? "error" : "absent";
  return { state, prometheus, exporter };
}
