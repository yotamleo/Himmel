import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";

// HIMMEL-4480: GET /agui/ serves the built AG-UI page (agui-web/dist), and
// `himmelctl ui --agui` prints its live URL.
// seams: aguiDist (a temp dist), env.HOME (a temp ~/.claude/projects), CONFIG_UI_HIMMELCTL (stub, never shelled here).
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const BIN = join(import.meta.dir, "..", "..", "himmelctl", "bin.js");
const TOKEN = "t".repeat(64);
const OLD = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const NEW = "9f8e7d6c-5b4a-4321-8fed-cba987654321";

let cleanup: (() => void)[] = [];
afterEach(() => { for (const f of cleanup.reverse()) f(); cleanup = []; });

function tmp(prefix: string): string {
  const d = mkdtempSync(join(tmpdir(), prefix));
  cleanup.push(() => rmSync(d, { recursive: true, force: true }));
  return d;
}
function dist(): { dir: string; outside: string } {
  const base = tmp("agui-static-");
  const dir = join(base, "dist");
  mkdirSync(join(dir, "sub"), { recursive: true });
  writeFileSync(join(dir, "index.html"), '<!doctype html><script type="module" src="./index-abc.js"></script>');
  writeFileSync(join(dir, "index-abc.js"), "console.log(1)");
  writeFileSync(join(dir, "index-abc.css"), "body{}");
  const outside = join(base, "secret.js");
  writeFileSync(outside, "SECRET");
  symlinkSync(outside, join(dir, "link.js"));
  return { dir, outside };
}
function boot(aguiDist: string) {
  const s = startServer({ port: 0, token: TOKEN, aguiDist, env: { PATH: process.env.PATH, HOME: tmp("agui-home-"), CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" } });
  cleanup.push(() => s.stop());
  return `http://127.0.0.1:${s.port}`;
}

test("GET /agui/ serves dist/index.html with the security headers and no token", async () => {
  const base = boot(dist().dir);
  const r = await fetch(`${base}/agui/`);
  expect(r.status).toBe(200);
  expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
  expect(r.headers.get("content-security-policy")).toBe("default-src 'self'");
  expect(r.headers.get("x-frame-options")).toBe("DENY");
  expect(await r.text()).toContain("./index-abc.js");
});

test("hashed assets are served with their types; /agui redirects to /agui/", async () => {
  const base = boot(dist().dir);
  const js = await fetch(`${base}/agui/index-abc.js`);
  expect(js.status).toBe(200);
  expect(js.headers.get("content-type")).toBe("application/javascript; charset=utf-8");
  expect(js.headers.get("content-security-policy")).toBe("default-src 'self'");
  expect((await fetch(`${base}/agui/index-abc.css`)).headers.get("content-type")).toBe("text/css; charset=utf-8");
  const red = await fetch(`${base}/agui`, { redirect: "manual" });
  expect(red.status).toBe(308);
  expect(red.headers.get("location")).toBe("/agui/");
});

test("traversal, a symlink out of dist, a directory and a missing file are 404", async () => {
  const base = boot(dist().dir);
  for (const p of ["..%2fsecret.js", "%2e%2e%2fsecret.js", "..%2f..%2fserver.ts", "link.js", "sub", "sub/", "nope.js", "%E0%A4%A"]) {
    const r = await fetch(`${base}/agui/${p}`);
    expect([p, r.status]).toEqual([p, 404]);
    expect(await r.text()).not.toContain("SECRET");
  }
});

test("a missing dist answers 404 with the build steps", async () => {
  const base = boot(join(tmp("agui-nodist-"), "dist"));
  const r = await fetch(`${base}/agui/`);
  expect(r.status).toBe(404);
  expect(r.headers.get("content-type")).toBe("text/html; charset=utf-8");
  expect(await r.text()).toContain("bun run build");
});

test("the API stays token-gated", async () => {
  const base = boot(dist().dir);
  expect((await fetch(`${base}/api/agui/${OLD}`)).status).toBe(401);
});

// `himmelctl ui --agui`: the real wrapper and server, with a temp HOME and the Claude markers dropped.
function home(): string {
  const h = tmp("agui-ui-home-");
  const at = Date.now() / 1000;
  for (const [slug, id, age] of [["a", OLD, 600], ["b", NEW, 10]] as const) {
    mkdirSync(join(h, ".claude", "projects", slug), { recursive: true });
    const f = join(h, ".claude", "projects", slug, `${id}.jsonl`);
    writeFileSync(f, "");
    utimesSync(f, at - age, at - age);
  }
  writeFileSync(join(h, ".claude", "projects", "b", "not-a-session.jsonl"), "");
  return h;
}
function uiEnv(h: string) {
  const e: Record<string, string | undefined> = { ...process.env, HOME: h, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" };
  for (const k of Object.keys(e)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete e[k];
  return e;
}
async function twoLines(args: string[], h: string): Promise<string[]> {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "0", ...args], { env: uiEnv(h), stdout: "pipe", stderr: "pipe" });
  try {
    const reader = p.stdout.getReader();
    const dec = new TextDecoder();
    let out = "";
    while (out.split("\n").length < 3) {
      const { value, done } = await reader.read();
      if (done) break;
      out += dec.decode(value);
    }
    return out.trim().split("\n");
  } finally {
    p.kill("SIGTERM");
    await p.exited;
  }
}

for (const [label, args, want] of [["--agui (default latest)", ["--agui"], NEW], ["--agui latest", ["--agui", "latest"], NEW], ["--agui <id>", ["--agui", OLD], OLD]] as const) {
  test(`himmelctl ui ${label} prints the config URL, then the AG-UI URL for ${want === NEW ? "the newest" : "that"} session`, async () => {
    const [config, agui] = await twoLines([...args], home());
    const m = /^(http:\/\/127\.0\.0\.1:\d+)\/#t=([0-9a-f]{64})$/.exec(config);
    expect(m).not.toBeNull();
    expect(agui).toBe(`${m![1]}/agui/#t=${m![2]}&run=${want}`);
  });
}

test("himmelctl ui --agui latest with no transcript fails with rc 1", async () => {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "0", "--agui", "latest"], { env: uiEnv(tmp("agui-empty-")), stdout: "pipe", stderr: "pipe" });
  const err = await new Response(p.stderr).text();
  expect(await p.exited).toBe(1);
  expect(err).toMatch(/no session transcript/);
});

test("--agui is refused on a verb other than ui", async () => {
  const p = Bun.spawn(["node", BIN, "report", "--json", "--agui"], { stdout: "ignore", stderr: "pipe" });
  expect(await p.exited).toBe(2);
});
