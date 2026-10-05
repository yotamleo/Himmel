// HIMMEL-4289: Grafana webhook contact point -> scripts/luna/cadence-alert.sh.
//
// WHY: the Linux Grafana tier must alert through the ONE existing sink
// (cadence-alert.sh: console-readable log + a deduped Telegram DM), not a second
// Telegram path of its own. Grafana can only POST a webhook, so this ~40-line
// receiver turns each alert of a webhook payload into one cadence-alert call:
//   firing   -> cadence-alert.sh fail grafana-<alertname> <alertname> <summary url>
//   resolved -> cadence-alert.sh clear grafana-<alertname>
// The leg is per alertname so a resolve re-arms only that alert's dedupe.
//
// Loopback only (127.0.0.1); run as a systemd user unit by install-grafana.sh.
import { spawnSync } from "node:child_process";
import { join } from "node:path";

type GrafanaAlert = {
  status?: string;
  labels?: Record<string, string>;
  annotations?: Record<string, string>;
  generatorURL?: string;
};
type Runner = (args: string[]) => void;

export function alertCalls(body: { alerts?: GrafanaAlert[] }): string[][] {
  const calls: string[][] = [];
  for (const a of body.alerts ?? []) {
    const name = a.labels?.alertname || "unknown";
    const leg = `grafana-${name}`;
    if (a.status === "resolved") {
      calls.push(["clear", leg]);
    } else {
      const log = [a.annotations?.summary, a.generatorURL].filter(Boolean).join(" ");
      calls.push(["fail", leg, name, log]);
    }
  }
  return calls;
}

// Returns the HTTP status Grafana sees: 400 unparseable, 500 a runner failure
// (Grafana retries a non-2xx), 200 otherwise.
export async function handleWebhook(raw: string, run: Runner): Promise<number> {
  let body: { alerts?: GrafanaAlert[] };
  try {
    body = JSON.parse(raw);
  } catch {
    return 400;
  }
  try {
    for (const call of alertCalls(body)) run(call);
  } catch {
    return 500;
  }
  return 200;
}

if (import.meta.main) {
  const sink = join(import.meta.dir, "..", "luna", "cadence-alert.sh");
  const run: Runner = (args) => {
    const r = spawnSync("bash", [sink, ...args], { stdio: "ignore", timeout: 30_000 });
    if (r.error) throw r.error;
  };
  const port = Number(process.env.HIMMEL_GRAFANA_HOOK_PORT || 9878);
  Bun.serve({
    hostname: "127.0.0.1",
    port,
    async fetch(req) {
      const url = new URL(req.url);
      if (url.pathname === "/healthz") return new Response("ok");
      if (url.pathname !== "/alert" || req.method !== "POST") return new Response("not found", { status: 404 });
      return new Response("", { status: await handleWebhook(await req.text(), run) });
    },
  });
}
