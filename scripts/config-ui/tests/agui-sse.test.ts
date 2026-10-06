import { test, expect, afterEach } from "bun:test";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { startServer } from "../server";
import { mapFile } from "../agui/journal-mapper.ts";
import { journalStream } from "../agui/sse.ts";

// HIMMEL-4480 PR2: GET /api/agui/<run> streams a session journal as AG-UI over SSE.
// seams: env.HOME (a temp HOME whose ~/.claude/projects holds the fixture journals),
// CONFIG_UI_HIMMELCTL (stub, never shelled here), the agui* timing options.
const STUB = join(import.meta.dir, "stub-himmelctl.js");
const FIX = join(import.meta.dir, "fixtures", "agui");
const TOKEN = "t".repeat(64);
const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const sleep = (ms: number) => new Promise((r) => setTimeout(r, ms));

let cleanup: (() => void)[] = [];
afterEach(() => { for (const f of cleanup.reverse()) f(); cleanup = []; });

function home(): string {
  const h = mkdtempSync(join(tmpdir(), "agui-sse-"));
  cleanup.push(() => rmSync(h, { recursive: true, force: true }));
  mkdirSync(join(h, ".claude", "projects"), { recursive: true });
  return h;
}
function journal(h: string, slug: string, run: string, body: string): string {
  mkdirSync(join(h, ".claude", "projects", slug), { recursive: true });
  const p = join(h, ".claude", "projects", slug, `${run}.jsonl`);
  writeFileSync(p, body);
  return p;
}
type Extra = { aguiIdleMs?: number; aguiMaxMs?: number; aguiPollMs?: number; onIdle?: () => void; idleMs?: string };
function boot(h: string, extra: Extra = {}) {
  const s = startServer({
    port: 0, token: TOKEN, env: { PATH: process.env.PATH, HOME: h, CONFIG_UI_HIMMELCTL: STUB, CONFIG_UI_IDLE_MS: extra.idleMs ?? "60000" },
    aguiPollMs: extra.aguiPollMs ?? 20, aguiIdleMs: extra.aguiIdleMs ?? 200, aguiMaxMs: extra.aguiMaxMs ?? 10_000, onIdle: extra.onIdle,
  });
  cleanup.push(() => s.stop());
  return s;
}
const get = (port: number, run: string, headers: Record<string, string> = { "X-Himmel-Token": TOKEN }, signal?: AbortSignal) =>
  fetch(`http://127.0.0.1:${port}/api/agui/${run}`, { headers: { Accept: "text/event-stream", ...headers }, signal });

// Parses the SSE wire format: one `data: <json>` per event, blank-line separated; `:` lines are comments.
function parse(text: string): Record<string, unknown>[] {
  return text.split("\n\n").filter((b) => b.startsWith("data: ")).map((b) => JSON.parse(b.slice(6)));
}
async function readUntil(r: Response, done: (events: Record<string, unknown>[]) => boolean, ms = 5000) {
  const reader = r.body!.getReader();
  const dec = new TextDecoder();
  let text = "";
  const deadline = Date.now() + ms;
  while (Date.now() < deadline) {
    const { value, done: end } = await reader.read();
    if (end) break;
    text += dec.decode(value, { stream: true });
    if (done(parse(text))) break;
  }
  return { reader, events: parse(text), text };
}

test("no token is 401", async () => {
  const { port } = boot(home());
  expect((await get(port, RUN, {})).status).toBe(401);
});

test("a wrong token is 401", async () => {
  const { port } = boot(home());
  expect((await get(port, RUN, { "X-Himmel-Token": "x".repeat(64) })).status).toBe(401);
});

test("a foreign Host is 403", async () => {
  const { port } = boot(home());
  expect((await get(port, RUN, { "X-Himmel-Token": TOKEN, Host: "evil.test" })).status).toBe(403);
});

for (const bad of ["not-a-uuid", "%2e%2e%2f%2e%2e%2fetc%2fpasswd", "..%2fsecret", `${RUN}.jsonl`, `${RUN}%2f..`, RUN.toUpperCase(), `${RUN}x`, ""]) {
  test(`a non-UUID run is 400: ${JSON.stringify(bad)}`, async () => {
    const { port } = boot(home());
    expect((await get(port, bad)).status).toBe(400);
  });
}

test("a non-GET is 405", async () => {
  const h = home();
  journal(h, "-proj", RUN, "");
  const { port } = boot(h);
  const r = await fetch(`http://127.0.0.1:${port}/api/agui/${RUN}`, { method: "POST", headers: { "X-Himmel-Token": TOKEN } });
  expect(r.status).toBe(405);
});

test("an unknown run is 404", async () => {
  const { port } = boot(home());
  expect((await get(port, RUN)).status).toBe(404);
});

test("a run present in two projects is 409", async () => {
  const h = home();
  journal(h, "-a", RUN, "");
  journal(h, "-b", RUN, "");
  const { port } = boot(h);
  expect((await get(port, RUN)).status).toBe(409);
});

test("a journal symlinked out of ~/.claude/projects is not served", async () => {
  const h = home();
  const outside = join(h, "outside.jsonl");
  writeFileSync(outside, readFileSync(join(FIX, "happy-path.jsonl")));
  mkdirSync(join(h, ".claude", "projects", "-proj"), { recursive: true });
  symlinkSync(outside, join(h, ".claude", "projects", "-proj", `${RUN}.jsonl`));
  const { port } = boot(h);
  expect((await get(port, RUN)).status).toBe(404);
});

test("a project directory symlinked out of ~/.claude/projects is not served", async () => {
  const h = home();
  mkdirSync(join(h, "elsewhere"));
  writeFileSync(join(h, "elsewhere", `${RUN}.jsonl`), readFileSync(join(FIX, "happy-path.jsonl")));
  symlinkSync(join(h, "elsewhere"), join(h, ".claude", "projects", "-linked"));
  const { port } = boot(h);
  expect((await get(port, RUN)).status).toBe(404);
});

test("a fixture journal streams the mapper's AG-UI events as SSE, then closes once the run ended and the file idles", async () => {
  const h = home();
  const src = join(FIX, "happy-path.jsonl");
  journal(h, "-proj", RUN, readFileSync(src, "utf8"));
  const { port } = boot(h);
  const r = await get(port, RUN);
  expect(r.status).toBe(200);
  expect(r.headers.get("content-type")).toBe("text/event-stream");
  const text = await r.text(); // ends: the run finished and the file idled past aguiIdleMs
  expect(parse(text)).toEqual(JSON.parse(JSON.stringify(mapFile(src, { threadId: RUN }).events)));
  expect(parse(text).map((e) => e.type)).toEqual([
    "RUN_STARTED",
    "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
    "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
    "TOOL_CALL_START", "TOOL_CALL_ARGS", "TOOL_CALL_END",
    "TOOL_CALL_RESULT",
    "TEXT_MESSAGE_START", "TEXT_MESSAGE_CONTENT", "TEXT_MESSAGE_END",
    "RUN_FINISHED",
  ]);
});

test("lines appended to a live journal arrive as new events, a split line once complete", async () => {
  const h = home();
  const lines = readFileSync(join(FIX, "happy-path.jsonl"), "utf8").split("\n").filter(Boolean);
  const turnEnd = lines.pop()!; // without turn_duration the run stays open
  const p = journal(h, "-proj", RUN, lines.join("\n") + "\n");
  const { port } = boot(h, { aguiIdleMs: 100 });
  const r = await get(port, RUN);
  const first = await readUntil(r, (ev) => ev.some((e) => e.type === "TOOL_CALL_RESULT") && ev.at(-1)?.type === "TEXT_MESSAGE_END");
  expect(first.events.map((e) => e.type)).not.toContain("RUN_FINISHED");
  await sleep(300); // past aguiIdleMs: an open run keeps the stream alive
  appendFileSync(p, turnEnd.slice(0, 40));
  await sleep(100);
  appendFileSync(p, turnEnd.slice(40) + "\n");
  const dec = new TextDecoder();
  let rest = "";
  for (;;) { const { value, done } = await first.reader.read(); if (done) break; rest += dec.decode(value, { stream: true }); }
  expect(parse(rest).map((e) => e.type)).toEqual(["RUN_FINISHED"]);
});

test("the stream closes at the max duration even while the run is open", async () => {
  const h = home();
  const lines = readFileSync(join(FIX, "happy-path.jsonl"), "utf8").split("\n").filter(Boolean);
  journal(h, "-proj", RUN, lines.slice(0, -1).join("\n") + "\n");
  const { port } = boot(h, { aguiMaxMs: 400 });
  const t0 = Date.now();
  const text = await (await get(port, RUN)).text();
  expect(Date.now() - t0).toBeLessThan(4000);
  expect(parse(text).map((e) => e.type)).not.toContain("RUN_FINISHED");
});

test("a client abort ends the stream: the idle window, deferred while it streamed, fires after", async () => {
  const h = home();
  const lines = readFileSync(join(FIX, "happy-path.jsonl"), "utf8").split("\n").filter(Boolean);
  journal(h, "-proj", RUN, lines.slice(0, -1).join("\n") + "\n"); // open run: only the client can end it
  let idled = 0;
  const s = boot(h, { idleMs: "300", onIdle: () => { idled++; } });
  const ac = new AbortController();
  const r = await get(s.port, RUN, undefined, ac.signal);
  await readUntil(r, (ev) => ev.length > 0);
  idled = 0;
  await sleep(800); // well past the idle window: the open stream defers it
  expect(idled).toBe(0);
  ac.abort();
  await sleep(1200);
  expect(idled).toBe(1);
});

test("secret-shaped strings in the journal are redacted before they leave the server", async () => {
  const h = home();
  const canary = "ghp_" + "A1b2".repeat(8);
  const body = readFileSync(join(FIX, "happy-path.jsonl"), "utf8").replace("List the files in the repo root.", `List ${canary} files.`);
  journal(h, "-proj", RUN, body);
  const { port } = boot(h);
  const text = await (await get(port, RUN)).text();
  expect(text).toContain("List ");
  expect(text).not.toContain(canary);
});

// HIMMEL-4669: a subagent writes its own transcript beside the journal; the stream follows it too.
function splitAgents(): { mainBody: string; subBody: string } {
  const lines = readFileSync(join(FIX, "agents.jsonl"), "utf8").split("\n").filter(Boolean);
  const side = (l: string) => JSON.parse(l).isSidechain === true;
  return { mainBody: lines.filter((l) => !side(l)).join("\n") + "\n", subBody: lines.filter(side).join("\n") + "\n" };
}
function subagentFile(h: string, body: string, name = "agent-a1b2c3.jsonl"): string {
  const dir = join(h, ".claude", "projects", "-proj", RUN, "subagents");
  mkdirSync(dir, { recursive: true });
  writeFileSync(join(dir, name), body);
  return join(dir, name);
}

test("subagent transcripts merge into the stream in timestamp order, attributed to the subagent", async () => {
  const h = home();
  const { mainBody, subBody } = splitAgents();
  journal(h, "-proj", RUN, mainBody);
  subagentFile(h, subBody);
  const { port } = boot(h);
  const events = parse(await (await get(port, RUN)).text());
  // the same events as the journal with the sidechain records inline, in their original order
  expect(events).toEqual(JSON.parse(JSON.stringify(mapFile(join(FIX, "agents.jsonl"), { threadId: RUN }).events)));
  const read = events.find((e) => e.type === "TOOL_CALL_START" && e.toolCallId === "toolu_s1") as any;
  expect(read.agent).toMatchObject({ id: "a1b2c3", name: "Review the diff", role: "critic" });
});

test("a subagent transcript appended while streaming arrives live", async () => {
  const h = home();
  const { mainBody, subBody } = splitAgents();
  const lines = mainBody.split("\n").filter(Boolean);
  journal(h, "-proj", RUN, lines.slice(0, 5).join("\n") + "\n"); // prompt, text and both calls: the run stays open
  const { port } = boot(h, { aguiIdleMs: 100 });
  const r = await get(port, RUN);
  const first = await readUntil(r, (ev) => ev.some((e) => e.type === "TOOL_CALL_START" && e.toolCallId === "toolu_suite"));
  await sleep(200);
  subagentFile(h, subBody);
  const more = await readUntil({ body: { getReader: () => first.reader } } as any, (ev) => ev.some((e) => e.type === "TOOL_CALL_START" && e.toolCallId === "toolu_s1"));
  expect((more.events.find((e) => e.type === "TOOL_CALL_START") as any).agent.id).toBe("a1b2c3");
  await first.reader.cancel();
});

test("a subagent file symlinked out of the session directory is not followed", async () => {
  const h = home();
  const { mainBody, subBody } = splitAgents();
  journal(h, "-proj", RUN, mainBody);
  mkdirSync(join(h, "elsewhere"));
  writeFileSync(join(h, "elsewhere", "agent-zz.jsonl"), subBody);
  mkdirSync(join(h, ".claude", "projects", "-proj", RUN, "subagents"), { recursive: true });
  symlinkSync(join(h, "elsewhere", "agent-zz.jsonl"), join(h, ".claude", "projects", "-proj", RUN, "subagents", "agent-zz.jsonl"));
  const { port } = boot(h);
  const events = parse(await (await get(port, RUN)).text());
  expect(events.some((e) => (e as any).toolCallId === "toolu_s1")).toBe(false);
});

test("a subagent transcript longer than one read chunk still lands before the journal's later lines", async () => {
  const h = home();
  const { mainBody, subBody } = splitAgents();
  // ~400 KB of the critic's reading, timestamped inside its run (before the Agent call's result at 3.5s)
  const filler = Array.from({ length: 1600 }, (_, i) => JSON.stringify({
    type: "assistant", isSidechain: true, agentId: "a1b2c3", uuid: `f-${i}`, sessionId: "sess-agents",
    timestamp: `2026-10-06T12:00:02.${String(500 + Math.floor(i / 4)).padStart(3, "0")}Z`,
    message: { id: `mf-${i}`, role: "assistant", model: "claude-sonnet-5-5", content: [{ type: "text", text: "x".repeat(220) }] },
  })).join("\n") + "\n";
  journal(h, "-proj", RUN, mainBody);
  subagentFile(h, subBody + filler);
  const { port } = boot(h);
  const events = parse(await (await get(port, RUN)).text());
  const runs = events.filter((e) => String(e.type).startsWith("RUN_"));
  expect(runs.map((e) => e.type)).toEqual(["RUN_STARTED", "RUN_FINISHED"]); // no late side runs: nothing overtook
  const lastFiller = events.findLastIndex((e) => e.messageId === "f-1599");
  const agentResult = events.findIndex((e) => e.type === "TOOL_CALL_RESULT" && e.toolCallId === "toolu_agent");
  expect(lastFiller).toBeGreaterThan(-1);
  expect(lastFiller).toBeLessThan(agentResult);
});

test("a subagent's name is the Agent call's free-text description: it passes the redactor", async () => {
  const h = home();
  const canary = "ghp_" + "A1b2".repeat(8);
  journal(h, "-proj", RUN, readFileSync(join(FIX, "agents.jsonl"), "utf8").replace('"description":"Review the diff"', `"description":"Review ${canary}"`));
  const { port } = boot(h);
  const text = await (await get(port, RUN)).text();
  expect(text).not.toContain(canary);
  const read = parse(text).find((e) => e.type === "TOOL_CALL_START" && e.toolCallId === "toolu_s1") as any;
  expect(read.agent).toMatchObject({ id: "a1b2c3", role: "critic" });
});

test("a long agent name is an identifier, not a secret: it is not redacted", async () => {
  const h = home();
  const name = "HIMMEL-4669-N1363-agui-agent-design-and-more";
  journal(h, "-proj", RUN, readFileSync(join(FIX, "agents.jsonl"), "utf8").replace("HIMMEL-4669-roadmap-console", name));
  const { port } = boot(h);
  const events = parse(await (await get(port, RUN)).text());
  expect((events.find((e) => e.type === "TOOL_CALL_START") as any).agent).toMatchObject({ name, role: "leg" });
});

test("a cancel that lands while the journal is still opening closes the handle once it opens", async () => {
  if (!existsSync("/proc/self/fd")) return; // fd count is read from procfs
  const h = home();
  const p = journal(h, "-proj", RUN, readFileSync(join(FIX, "happy-path.jsonl"), "utf8"));
  const fds = () => readdirSync("/proc/self/fd").length;
  const before = fds();
  for (let i = 0; i < 20; i++) {
    const reader = journalStream(p, { threadId: RUN, pollMs: 20, idleMs: 200, maxMs: 10_000, redact: (v) => v, onClose: () => {} }).getReader();
    await Promise.resolve(); // pull() has started and is awaiting open()
    await reader.cancel();
  }
  await sleep(200);
  expect(fds() - before).toBeLessThan(5);
});

test("the max duration releases the stream even when the client stops reading", async () => {
  const h = home();
  const line = (i: number) => JSON.stringify({ type: "assistant", uuid: `a-${i}`, sessionId: "s", timestamp: "2026-10-06T10:00:00.000Z",
    message: { id: `msg_${i}`, role: "assistant", content: [{ type: "text", text: "x".repeat(1000) }] } });
  const p = journal(h, "-proj", RUN, Array.from({ length: 1200 }, (_, i) => line(i)).join("\n") + "\n"); // several read chunks, each with events
  let closed = 0;
  const reader = journalStream(p, { threadId: RUN, pollMs: 20, idleMs: 60_000, maxMs: 150, redact: (v) => v, onClose: () => { closed++; } }).getReader();
  await reader.read(); // one chunk, then never read again: pull() is not called back
  await sleep(500);
  expect(closed).toBe(1);
});
