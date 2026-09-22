import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { classify } from "./router";
import { handleInbound } from "./poller";
import { consoleInboxPath, foldLine, type ConsoleRouteGate } from "./console-route";

// HIMMEL-3355: every test runs against a scratch bridge root and a fake reply
// seam — never the real ~/.claude/handover/bridge, never Telegram.
const root = () => mkdtempSync(join(tmpdir(), "console-route-"));
const NAME = "HIMMEL-nextleg-2026-09-21V-console";

// A console "arms" its inbox by creating the file (ACTION ZERO); the bridge
// only ever appends to one that exists.
function armInbox(r: string, name = NAME): string {
  mkdirSync(join(r, "consoles"), { recursive: true });
  const f = join(r, "consoles", `${name}.md`);
  writeFileSync(f, "");
  return f;
}

function gate(replies: string[], authorize = (from: number) => from === 1): ConsoleRouteGate {
  return { authorize: (from) => authorize(from), reply: async (_chat, text) => { replies.push(text); } };
}

const say = (text: string, extra: Record<string, unknown> = {}) => ({ from: 1, chat_id: 1, text, caption: false, ...extra });

test("router: /console <name> <text> classifies; prose and partial shapes stay chat", () => {
  expect(classify(`/console ${NAME} halt the wave`)).toEqual({ kind: "console", name: NAME, text: "halt the wave" });
  expect(classify(`/console ${NAME} line one\nline two`)).toEqual({ kind: "console", name: NAME, text: "line one\nline two" });
  expect(classify("console output: foo").kind).toBe("chat");
  expect(classify("/console").kind).toBe("chat");
  expect(classify(`/console ${NAME}`).kind).toBe("chat");
  expect(classify(`please /console ${NAME} hi`).kind).toBe("chat");
});

test("allowlisted /console message lands one line in the console inbox and spawns NO cold session", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/console ${NAME} go ahead with PR 12`), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  const lines = readFileSync(f, "utf8").split("\n").filter(Boolean);
  expect(lines.length).toBe(1);
  expect(lines[0]).toMatch(/^- \d\d:\d\d \[telegram from=1 chat=1\] go ahead with PR 12$/);
  expect(ran).toEqual([]);
  expect(existsSync(join(r, "sessions"))).toBe(false);
  expect(replies).toEqual([`→ console ${NAME}`]);
});

test("control: a non-allowlisted sender writes to NO console inbox and keeps today's cold-spawn chat path", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/console ${NAME} halt everything`, { from: 999 }), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
  expect(replies).toEqual([]);
});

test("control: an unaddressed message keeps today's cold-spawn behaviour", async () => {
  const r = root(); const f = armInbox(r); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say("hello there"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
  expect(replies).toEqual([]);
});

test("control: with no console gate wired, /console is ordinary chat (feature is inert)", async () => {
  const r = root(); const f = armInbox(r); const ran: string[] = [];
  await handleInbound(r, say(`/console ${NAME} hi`), async (s: string) => { ran.push(s); });
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
});

test("forwarded or caption /console messages are refused the console path and fall through to chat", async () => {
  for (const extra of [{ forwarded: true }, { caption: true }]) {
    const r = root(); const f = armInbox(r); const ran: string[] = [];
    await handleInbound(r, say(`/console ${NAME} halt`, extra), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toBe("");
    expect(ran).toEqual(["__chat__"]);
  }
});

// HIMMEL-3440: routeToConsole never creates an inbox (appendIfExists is
// O_CREAT-free — see bus.test.ts for the TOCTOU-race regression at the
// primitive level).
test("a console with no armed inbox gets an error reply, no file, and no cold session", async () => {
  const r = root(); const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say(`/console ${NAME} hi`), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(existsSync(join(r, "consoles", `${NAME}.md`))).toBe(false);
  expect(ran).toEqual([]);
  expect(existsSync(join(r, "sessions"))).toBe(false);
  expect(replies.length).toBe(1);
  expect(replies[0]).toContain("no console");
  expect(replies[0]).toContain(NAME);
});

test("a traversal-shaped console name is refused: nothing written outside consoles/, no cold session", async () => {
  const r = root(); const replies: string[] = []; const ran: string[] = [];
  mkdirSync(join(r, "consoles"), { recursive: true });
  writeFileSync(join(r, "escape.md"), "");
  // `../escape` has a `/`, so the router never matches it as a console address
  // (today's chat path); `a..b` matches the shape and is refused downstream.
  await handleInbound(r, say("/console ../escape hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(ran).toEqual(["__chat__"]);
  ran.length = 0;
  await handleInbound(r, say("/console a..b hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(join(r, "escape.md"), "utf8")).toBe("");
  expect(ran).toEqual([]);
  expect(replies.length).toBe(1);
  expect(replies[0]).toContain("not a valid console name");
  expect(consoleInboxPath(r, "../escape")).toBeNull();
  expect(consoleInboxPath(r, "a..b")).toBeNull();
  expect(consoleInboxPath(r, "")).toBeNull();
});

test("a multi-line message is folded onto ONE line so a tail -F monitor emits one event", async () => {
  const r = root(); const f = armInbox(r);
  await handleInbound(r, say(`/console ${NAME} first\nsecond\r\nthird`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  const raw = readFileSync(f, "utf8");
  expect(raw.endsWith("\n")).toBe(true);
  expect(raw.split("\n").filter(Boolean).length).toBe(1);
  expect(raw).toContain("first ⏎ second ⏎ third");
  expect(foldLine("a\nb")).toBe("a ⏎ b");
});

test("a reply-seam failure after the append does not throw (handleBatch would tell the operator to resend a duplicate)", async () => {
  const r = root(); const f = armInbox(r);
  const g: ConsoleRouteGate = { authorize: () => true, reply: async () => { throw new Error("outbox down"); } };
  await handleInbound(r, say(`/console ${NAME} hi`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, g);
  expect(readFileSync(f, "utf8").split("\n").filter(Boolean).length).toBe(1);
});

test("reply CLI appends one line to the chat's outbox under a scratch BRIDGE_ROOT", async () => {
  const r = root();
  const p = Bun.spawn(["bun", join(import.meta.dir, "console-route.ts"), "reply", "1", "done", "with", "PR 12"], { env: { ...process.env, BRIDGE_ROOT: r }, stdout: "pipe", stderr: "pipe" });
  expect(await p.exited).toBe(0);
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").split("\n").filter(Boolean);
  expect(out.map((l) => JSON.parse(l))).toEqual([{ text: "done with PR 12" }]);
  const meta = JSON.parse(readFileSync(join(r, "sessions", "__chat__", "meta.json"), "utf8"));
  expect(meta.chat_id).toBe(1);
});
