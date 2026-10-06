// HIMMEL-4480: harness for the AG-UI page e2e and the README GIF recorder.
// Boots the REAL `himmelctl ui --port 0 --agui <run>` (the same spawn as fixtures.ts, so the
// HIMMEL-4350 in-session refusal stays untouched) with a temp HOME whose ~/.claude/projects holds a
// session journal the test APPENDS to while the page is open: a live stream over the real SSE path.
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BIN } from "./fixtures";

export const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const DIST = join(__dirname, "../../agui-web/dist/index.html");
export const aguiBuilt = () => existsSync(DIST);

const SESSION = "e2e-session";
let seq = 0;
const ts = () => new Date().toISOString();
const line = (o: object) => JSON.stringify({ isSidechain: false, sessionId: SESSION, timestamp: ts(), uuid: `u-${++seq}`, ...o }) + "\n";

// Journal records, in the shape tests/fixtures/agui/happy-path.jsonl pins.
export const J = {
  prompt: (text: string) => line({ parentUuid: null, promptId: "p-1", type: "user", message: { role: "user", content: text } }),
  text: (text: string, stop = "end_turn") =>
    line({ type: "assistant", requestId: `req_${seq}`, message: { id: `msg_${seq}`, type: "message", role: "assistant", stop_reason: stop, content: [{ type: "text", text }] } }),
  tool: (id: string, name: string, input: Record<string, unknown>) =>
    line({ type: "assistant", requestId: `req_${seq}`, message: { id: `msg_${seq}`, type: "message", role: "assistant", stop_reason: "tool_use", content: [{ type: "tool_use", id, name, input }] } }),
  result: (id: string, content: string) =>
    line({ type: "user", promptId: "p-1", message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content, is_error: false }] } }),
  end: () => line({ type: "system", subtype: "turn_duration", durationMs: 4000, messageCount: 6 }),
};

export type AguiHarness = {
  url: string; // http://127.0.0.1:<port>/agui/#t=<64 hex>&run=<RUN>
  append: (record: string) => void;
  stop: () => Promise<void>;
};

export async function bootAgui(initial = ""): Promise<AguiHarness> {
  const dir = mkdtempSync(join(tmpdir(), "agui-e2e-"));
  const home = join(dir, "home");
  const slug = join(home, ".claude", "projects", "e2e-project");
  mkdirSync(slug, { recursive: true });
  const journal = join(slug, `${RUN}.jsonl`);
  writeFileSync(journal, initial);
  const env: Record<string, string | undefined> = {
    ...process.env, HOME: home, CONFIG_UI_HIMMELCTL: join(__dirname, "e2e-stub.js"), CONFIG_UI_IDLE_MS: "300000",
    HANDOVER_DIR: join(dir, "handover"), HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1",
    E2E_FEED: join(dir, "feed.json"), STUB_ARGV: join(dir, "argv"),
  };
  delete env.CADENCE_BANK_LEDGER;
  for (const k of Object.keys(env)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete env[k];
  const child: ChildProcess = spawn("node", [BIN, "ui", "--port", "0", "--agui", RUN], { env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const url = await new Promise<string>((ok, fail) => {
    let buf = "", err = "";
    child.stderr!.on("data", (d) => (err += d));
    child.stdout!.on("data", (d) => {
      buf += d;
      const m = /(http:\/\/127\.0\.0\.1:\d+\/agui\/#t=[0-9a-f]{64}&run=[0-9a-f-]{36})/.exec(buf);
      if (m) ok(m[1]);
    });
    child.on("error", fail);
    child.on("exit", (c) => fail(new Error(`himmelctl ui exited ${c}: ${err}`)));
    timer = setTimeout(() => fail(new Error("himmelctl ui --agui printed no URL in 15 s")), 15_000);
  }).catch((e) => {
    child.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true });
    throw e;
  }).finally(() => clearTimeout(timer));
  return {
    url,
    append: (r) => appendFileSync(journal, r),
    stop: async () => {
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
