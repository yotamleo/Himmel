import { test, expect } from "bun:test";
import { join } from "node:path";

const BIN = join(import.meta.dir, "..", "..", "himmelctl", "bin.js");
const STUB = join(import.meta.dir, "stub-himmelctl.js");

// A suite run from inside a Claude session must not trip the agent-session refusal, so the Claude markers are dropped.
const cleanEnv = () => {
  const e: Record<string, string | undefined> = { ...process.env, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: "60000" };
  for (const k of Object.keys(e)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete e[k];
  return e;
};

// seam: CONFIG_UI_HIMMELCTL (stub feed) — the real `himmelctl ui` runs, the live station feed never does.
test("himmelctl ui --port 0 prints a tokened URL that serves the feed, then dies on SIGTERM", async () => {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "0"], {
    env: cleanEnv(), stdout: "pipe", stderr: "pipe",
  });
  let base = "";
  try {
    const url = new TextDecoder().decode((await p.stdout.getReader().read()).value).trim();
    const m = /^(http:\/\/127\.0\.0\.1:\d+)\/#t=([0-9a-f]{64})$/.exec(url);
    expect(m).not.toBeNull();
    let token: string;
    [, base, token] = m!;
    expect((await fetch(`${base}/api/feed`)).status).toBe(401);
    const r = await fetch(`${base}/api/feed`, { headers: { "X-Himmel-Token": token } });
    expect(r.status).toBe(200);
    expect((await r.json()).rows.length).toBe(4);
  } finally {
    p.kill("SIGTERM");
    await p.exited;
  }
  // the server child must die with the wrapper (no orphan keeps the port)
  await new Promise((r) => setTimeout(r, 300));
  await expect(fetch(`${base}/`)).rejects.toThrow();
});

test("himmelctl ui rejects a bad --port with rc 2", async () => {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "99999"], { stdout: "ignore", stderr: "pipe" });
  expect(await p.exited).toBe(2);
});

test("--help documents ui as operator-only", async () => {
  const p = Bun.spawn(["node", BIN, "--help"], { stdout: "pipe", stderr: "ignore" });
  const out = await new Response(p.stdout).text();
  expect(out).toMatch(/ui \[--port N\][\s\S]*agents must not/);
});

// HIMMEL-4350: `ui` is operator-only, so a Claude session env refuses it unless the operator overrides.
for (const marker of ["CLAUDECODE", "CLAUDE_CODE_ENTRYPOINT"]) {
  test(`himmelctl ui refuses under ${marker} with rc 2 and names the override`, async () => {
    const p = Bun.spawn(["node", BIN, "ui", "--port", "0"], { env: { ...cleanEnv(), [marker]: "1" }, stdout: "pipe", stderr: "pipe" });
    const [err, out] = await Promise.all([new Response(p.stderr).text(), new Response(p.stdout).text()]);
    expect(await p.exited).toBe(2);
    expect(err).toMatch(/operator-only[\s\S]*--allow-agent-session/);
    expect(out).toBe("");
  });
}

test("himmelctl ui --allow-agent-session starts under a Claude session env", async () => {
  const p = Bun.spawn(["node", BIN, "ui", "--port", "0", "--allow-agent-session"], { env: { ...cleanEnv(), CLAUDECODE: "1" }, stdout: "pipe", stderr: "pipe" });
  try {
    const url = new TextDecoder().decode((await p.stdout.getReader().read()).value).trim();
    expect(url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/#t=[0-9a-f]{64}$/);
  } finally {
    p.kill("SIGTERM");
    await p.exited;
  }
});

test("--help aligns the gaps description with the other verbs", async () => {
  const p = Bun.spawn(["node", BIN, "--help"], { stdout: "pipe", stderr: "ignore" });
  const lines = (await new Response(p.stdout).text()).split("\n");
  const col = (re: RegExp) => lines.find((l) => re.test(l))!.search(/read-only/);
  expect(col(/^  gaps /)).toBe(col(/^  ui \[/));
});
