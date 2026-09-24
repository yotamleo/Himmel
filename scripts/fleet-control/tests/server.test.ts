import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { scrubProviderKeys, PROVIDER_KEY_NAMES, startServer, eventsResponse, resolveCodexStateRoot, resolveServeRoots } from "../server";

test("scrubProviderKeys removes every known provider key from the env map", () => {
  const env: Record<string, string> = { ZAI_API_KEY: "x", PATH: "/usr/bin", ANTHROPIC_API_KEY: "y" };
  scrubProviderKeys(env);
  for (const k of PROVIDER_KEY_NAMES) expect(env[k]).toBeUndefined();
  expect(env.PATH).toBe("/usr/bin");
});

test("scrub removes each newly-covered provider key including xai/perplexity/dashscope/nvidia/openrouter/deepseek (finding 7)", () => {
  const env: Record<string, string | undefined> = {};
  for (const k of PROVIDER_KEY_NAMES) env[k] = "secret";
  env.PATH = "/usr/bin";
  scrubProviderKeys(env);
  for (const k of PROVIDER_KEY_NAMES) expect(env[k]).toBeUndefined();
  for (const k of ["XAI_API_KEY", "PERPLEXITY_API_KEY", "DASHSCOPE_API_KEY", "NVIDIA_API_KEY", "OPENROUTER_API_KEY", "DEEPSEEK_API_KEY"]) {
    expect(PROVIDER_KEY_NAMES).toContain(k as any);
  }
  expect(env.PATH).toBe("/usr/bin");
});

test("startServer scrubs an injected env, leaving process.env untouched (hermetic)", () => {
  const env: Record<string, string | undefined> = { ZAI_API_KEY: "leak", PATH: "/usr/bin" };
  const { server } = startServer({ port: 0, stateRoot: "/tmp/fc-test", env });
  expect(env.ZAI_API_KEY).toBeUndefined();
  server.stop();
});

test("server binds loopback only", () => {
  const { server } = startServer({ port: 0, stateRoot: "/tmp/fc-test" });
  expect(server.hostname).toBe("127.0.0.1");
  server.stop();
});

test("server ignores injected host override", () => {
  const { server } = startServer({ port: 0, stateRoot: "/tmp/fc-test", hostname: "0.0.0.0" } as any);
  expect(server.hostname).toBe("127.0.0.1");
  server.stop();
});

test("events stream teardown closes the fs watcher on cancel (finding 6)", async () => {
  const dir = mkdtempSync(join(tmpdir(), "fleet-events-"));
  let closed = false;
  const fakeWatcher = { close: () => { closed = true; } } as any;
  const factory = (() => fakeWatcher) as any;
  const res = eventsResponse(dir, factory);
  const reader = res.body!.getReader();
  await reader.read(); // ensure start() has run and the watcher is attached
  await reader.cancel();
  expect(closed).toBe(true);
});

test("missing state root emits a degraded SSE event so the page can show a stale banner (finding 12)", async () => {
  const res = eventsResponse(join(tmpdir(), `does-not-exist-${Date.now()}`));
  const reader = res.body!.getReader();
  const dec = new TextDecoder();
  let acc = "";
  for (let i = 0; i < 2; i++) {
    const { value } = await reader.read();
    if (value) acc += dec.decode(value);
  }
  await reader.cancel();
  expect(acc).toContain("event: degraded");
});

test("resolveCodexStateRoot precedence: CLAUDE_PLUGIN_DATA > plugins dir > tmpdir (finding 8)", () => {
  const home = mkdtempSync(join(tmpdir(), "fleet-home-"));
  expect(resolveCodexStateRoot({ CLAUDE_PLUGIN_DATA: "/x/plugindata", HOME: home })).toBe("/x/plugindata");

  const pluginsDir = join(home, ".claude", "plugins", "data", "codex-openai-codex");
  mkdirSync(pluginsDir, { recursive: true });
  expect(resolveCodexStateRoot({ HOME: home })).toBe(pluginsDir);

  const bareHome = mkdtempSync(join(tmpdir(), "fleet-barehome-"));
  expect(resolveCodexStateRoot({ HOME: bareHome })).toBe(join(tmpdir(), "codex-companion"));
});

test("passivity: starting the server and serving /fleet + /escalations never registers a recurring timer", async () => {
  // The claimed contract is that this server does no unsolicited background
  // work while idle — not merely that the literal text "setInterval" is
  // absent from server.ts/aggregator/*.ts (a comment mentioning it would
  // false-red; a recursive setTimeout poll or an imported polling helper
  // could stay green under the old source-grep). Spy on the real global
  // timer registrars across a realistic request cycle plus an idle window
  // instead, so a self-rescheduling poll loop anywhere in the reachable call
  // graph (server.ts AND every aggregator/*.ts reader it calls) is caught.
  const origInterval = globalThis.setInterval;
  const origTimeout = globalThis.setTimeout;
  let intervalCalls = 0;
  let timeoutCalls = 0;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  globalThis.setInterval = ((...args: any[]) => { intervalCalls++; return origInterval(...(args as [any, any])); }) as typeof setInterval;
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  globalThis.setTimeout = ((...args: any[]) => { timeoutCalls++; return origTimeout(...(args as [any, any])); }) as typeof setTimeout;
  try {
    const root = mkdtempSync(join(tmpdir(), "fleet-passivity-"));
    const glm = join(root, "glm-sessions", "demo");
    mkdirSync(glm, { recursive: true });
    writeFileSync(join(glm, "meta.json"), JSON.stringify({ task_name: "demo", branch: "glm/demo", status: "running" }));
    const logs = join(root, "logs");
    mkdirSync(logs, { recursive: true });
    writeFileSync(join(logs, "hermes-foo.log"), "ok\n");
    const { server, port } = startServer({ port: 0, stateRoot: root, bridgeRoot: root });
    await fetch(`http://127.0.0.1:${port}/fleet`);
    await fetch(`http://127.0.0.1:${port}/escalations`);
    const timeoutCallsAfterRequests = timeoutCalls;
    // Idle window with no further requests: a polling loop would self-reschedule here.
    await new Promise((r) => origTimeout(r, 50));
    expect(intervalCalls).toBe(0);
    expect(timeoutCalls).toBe(timeoutCallsAfterRequests);
    server.stop();
  } finally {
    globalThis.setInterval = origInterval;
    globalThis.setTimeout = origTimeout;
  }
});

test("resolveServeRoots derives bridgeRoot as the PARENT of the fleet-control state dir", () => {
  const r = resolveServeRoots({ BRIDGE_ROOT: "/bridge" });
  expect(r.bridgeRoot).toBe("/bridge");
  expect(r.stateRoot.replaceAll("\\", "/")).toBe("/bridge/fleet-control");
  const o = resolveServeRoots({ FLEET_CONTROL_BRIDGE_ROOT: "/b2", FLEET_CONTROL_STATE_ROOT: "/elsewhere/fc" });
  expect(o.bridgeRoot).toBe("/b2");
  expect(o.stateRoot).toBe("/elsewhere/fc");
});

test("eventsResponse watches every distinct root and dedupes nested ones", () => {
  const bridge = mkdtempSync(join(tmpdir(), "fleet-events-bridge-"));
  const state = join(bridge, "fleet-control");
  mkdirSync(state, { recursive: true });
  const watched: string[] = [];
  const factory = ((path: string) => { watched.push(String(path)); return { close() {} }; }) as never;
  // state nested under bridge -> bridge alone suffices (one watcher)
  eventsResponse([state, bridge], factory);
  expect(watched.length).toBe(1);
  // two unrelated roots -> two watchers
  const other = mkdtempSync(join(tmpdir(), "fleet-events-other-"));
  watched.length = 0;
  eventsResponse([other, bridge], factory);
  expect(watched.length).toBe(2);
});
