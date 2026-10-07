import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, rmSync, symlinkSync, utimesSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { aguiStaleWarning, startServer } from "../server";

const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

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
// HIMMEL-4711: `himmelctl ui` prints ONE URL; read the first line, then make sure no second one follows.
async function oneLine(args: string[], h: string): Promise<string[]> {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "0", ...args], { env: uiEnv(h), stdout: "pipe", stderr: "pipe" });
  try {
    const reader = p.stdout.getReader();
    const dec = new TextDecoder();
    let out = "";
    while (!out.includes("\n")) {
      const { value, done } = await reader.read();
      if (done) break;
      out += dec.decode(value);
    }
    const more = await Promise.race([reader.read().then(({ value }) => dec.decode(value)), sleep(300).then(() => "")]);
    return (out + more).trim().split("\n");
  } finally {
    p.kill("SIGTERM");
    await p.exited;
  }
}

// HIMMEL-4712: --agui with no session id prints the fleet landing (the token, no run).
test("himmelctl ui --agui with no session id prints one URL: the AG-UI fleet", async () => {
  const lines = await oneLine(["--agui"], home());
  expect(lines).toHaveLength(1);
  expect(lines[0]).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/agui\/#t=[0-9a-f]{64}$/);
});

for (const [label, args, want] of [["--agui latest", ["--agui", "latest"], NEW], ["--agui <id>", ["--agui", OLD], OLD]] as const) {
  test(`himmelctl ui ${label} prints one URL: the AG-UI run of ${want === NEW ? "the newest" : "that"} session`, async () => {
    const lines = await oneLine([...args], home());
    expect(lines).toHaveLength(1);
    expect(lines[0]).toMatch(new RegExp(`^http://127\\.0\\.0\\.1:\\d+/agui/#t=[0-9a-f]{64}&run=${want}$`));
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

// HIMMEL-4711: a dist older than the page's source is served with a banner saying so, and the launcher says so on
// stderr. Detect and say, never rebuild: a rebuild on start would run bun install/build under the operator's server.
function web(distAge: number, srcAge: number): { dir: string; web: string } {
  const { dir } = dist();
  const w = join(dir, "..", "web");
  mkdirSync(join(w, "src", "deep"), { recursive: true });
  writeFileSync(join(w, "index.html"), "<!doctype html>");
  writeFileSync(join(w, "src", "deep", "App.tsx"), "export {}");
  const at = Date.now() / 1000;
  utimesSync(join(dir, "index.html"), at - distAge, at - distAge);
  utimesSync(join(w, "index.html"), at - 9999, at - 9999);
  utimesSync(join(w, "src", "deep", "App.tsx"), at - srcAge, at - srcAge);
  return { dir, web: w };
}
function bootWeb(aguiDist: string, aguiWeb: string) {
  const s = startServer({ port: 0, token: TOKEN, aguiDist, aguiWeb, env: { PATH: process.env.PATH, HOME: tmp("agui-home-"), CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" } });
  cleanup.push(() => s.stop());
  return `http://127.0.0.1:${s.port}`;
}

test("a dist older than agui-web/src is served with a stale-build banner and named on stderr", async () => {
  const { dir, web: w } = web(3600, 60);
  const html = await (await fetch(`${bootWeb(dir, w)}/agui/`)).text();
  expect(html).toContain('id="agui-stale"');
  expect(html).toContain("bun run build");
  expect(html).toContain("./index-abc.js"); // the page itself is still served
  expect(html.startsWith("<!doctype html>")).toBe(true); // a page with no <body> keeps its doctype first (no quirks mode)
  expect(aguiStaleWarning(dir, w)).toMatch(/^himmelctl: ui: the AG-UI page is an old build .*bun run build/);
});

test("a dist newer than its source has no banner and no warning; assets never get one", async () => {
  const { dir, web: w } = web(60, 3600);
  const base = bootWeb(dir, w);
  expect(await (await fetch(`${base}/agui/`)).text()).not.toContain("agui-stale");
  expect(aguiStaleWarning(dir, w)).toBeNull();
  const old = web(3600, 60);
  expect(await (await fetch(`${bootWeb(old.dir, old.web)}/agui/index-abc.js`)).text()).toBe("console.log(1)");
});

// HIMMEL-4711: the page bundles the console's rail and theme from public/, so a newer one of those is a newer source.
test("a dist older than public/nav.js or public/theme.css is stale", () => {
  for (const f of ["nav.js", "theme.css"]) {
    const { dir, web: w } = web(3600, 7200);
    expect(aguiStaleWarning(dir, w)).toBeNull();
    mkdirSync(join(w, "..", "public"), { recursive: true });
    writeFileSync(join(w, "..", "public", f), "");
    expect(aguiStaleWarning(dir, w)).toMatch(/^himmelctl: ui: the AG-UI page is an old build .*bun run build/);
  }
});

// HIMMEL-4716: a source file deleted (or renamed) after the build leaves no newer mtime behind, so the build records
// its source list in dist/.agui-sources and a listed file that is gone marks the page stale. A directory mtime alone
// is no evidence: an editor's swap file added and removed moves it with no source change.
function manifest(dir: string, files: string[], age: number) {
  writeFileSync(join(dir, ".agui-sources"), JSON.stringify(files));
  const at = Date.now() / 1000;
  utimesSync(join(dir, "index.html"), at - age, at - age);
}

test("a source file deleted after the build marks the page stale", async () => {
  const { dir, web: w } = web(60, 3600);
  manifest(dir, [join("deep", "App.tsx"), join("deep", "Gone.tsx")], 60);
  expect(aguiStaleWarning(dir, w)).toMatch(/^himmelctl: ui: the AG-UI page is an old build .*bun run build/);
  expect(await (await fetch(`${bootWeb(dir, w)}/agui/`)).text()).toContain('id="agui-stale"');
});

test("a directory touched by a temp file but with every built source present is not stale", () => {
  const { dir, web: w } = web(60, 3600);
  manifest(dir, [join("deep", "App.tsx")], 60);
  writeFileSync(join(w, "src", "deep", ".App.tsx.swp"), "");
  rmSync(join(w, "src", "deep", ".App.tsx.swp"));
  expect(aguiStaleWarning(dir, w)).toBeNull();
  rmSync(join(dir, ".agui-sources")); // an older build with no list: mtimes only, as before
  expect(aguiStaleWarning(dir, w)).toBeNull();
  writeFileSync(join(dir, ".agui-sources"), "not json"); // an unreadable list is no evidence
  expect(aguiStaleWarning(dir, w)).toBeNull();
});
