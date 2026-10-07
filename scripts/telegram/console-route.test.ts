import { expect, test } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync, existsSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { classify } from "./router";
import { BASH_BIN } from "./run";
import { handleInbound, replyViaOutbox, flushOutboxes, ingestUpdates } from "./poller";
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

function heartbeat(r: string, name = NAME, state = "waiting", age = 0) {
  const f = armInbox(r, name);
  writeFileSync(f + ".wait", `hb=${Math.floor(Date.now() / 1000) - age} pid=123 key=- tick=- state=${state}\n`);
  writeFileSync(f + ".meta.json", JSON.stringify({ bucket: "himmel", project: "/repos/himmel" }));
  return f;
}

// Missing discovery must never turn a bare console command into a cold run.
test("bare /console routes the whole text to the sole fresh waiting or sampling console", async () => {
  for (const state of ["waiting", "sampling"]) {
    const r = root(); const f = heartbeat(r, NAME, state); const ran: string[] = [];
    await handleInbound(r, say("/console halt the wave"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] halt the wave");
    expect(ran).toEqual([]);
  }
});

test("bare /console accepts non-ASCII and punctuation text without inventing a name", async () => {
  for (const text of ["🙏 halt, please", "a..b hi", "../escape hi"]) {
    const r = root(); const f = heartbeat(r);
    await handleInbound(r, say(`/console ${text}`), async () => {}, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
    expect(readFileSync(f, "utf8")).toContain(text);
  }
});

test("bare /console with zero or two live consoles lists the problem without queuing", async () => {
  for (const count of [0, 2]) {
    const r = root(); const replies: string[] = []; const ran: string[] = [];
    const old = heartbeat(r, "old", "waiting", 301);
    const exited = heartbeat(r, "exited", "exited");
    if (count) { heartbeat(r); heartbeat(r, "second"); }
    await handleInbound(r, say("/console halt"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
    expect(ran).toEqual([]);
    expect(replies.join("\n")).toContain(count ? "second" : "no live console");
    expect(readFileSync(old, "utf8")).toBe("");
    expect(readFileSync(exited, "utf8")).toBe("");
    if (count) expect(readFileSync(join(r, "consoles", `${NAME}.md`), "utf8")).toBe("");
  }
});

test("/consoles lists only fresh consoles with heartbeat and bucket/project", async () => {
  const r = root(); heartbeat(r); heartbeat(r, "old", "waiting", 300); heartbeat(r, "exited", "exited");
  const replies: string[] = []; const ran: string[] = [];
  await handleInbound(r, say("/consoles"), async (s) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(ran).toEqual([]);
  expect(replies.join("\n")).toContain(NAME);
  expect(replies.join("\n")).toContain("hb=");
  expect(replies.join("\n")).toContain("himmel");
  expect(replies.join("\n")).toContain("/repos/himmel");
  expect(replies.join("\n")).not.toContain("old");
  expect(replies.join("\n")).not.toContain("exited");
});

test("bare /console and /consoles retain typed, sender and allowed-chat authority gates", async () => {
  for (const text of ["/console halt", "/consoles"]) {
    for (const extra of [{ forwarded: true }, { caption: true }, { from: 999 }, { chat_id: -99 }]) {
      const r = root(); const f = heartbeat(r); const replies: string[] = [];
      const g: ConsoleRouteGate = { authorize: (from, chat) => from === 1 && chat === 1, reply: async (_chat, t) => { replies.push(t); } };
      await handleInbound(r, say(text, extra), async () => {}, undefined, async () => "spawn-high", undefined, undefined, undefined, undefined, g);
      expect(readFileSync(f, "utf8")).toBe("");
      expect(replies).toEqual([]);
    }
  }
});

test("router: /console <name> <text> classifies; prose and partial shapes stay chat", () => {
  expect(classify(`/console ${NAME} halt the wave`)).toEqual({ kind: "console", name: NAME, text: "halt the wave" });
  expect(classify(`/console ${NAME} line one\nline two`)).toEqual({ kind: "console", name: NAME, text: "line one\nline two" });
  expect(classify("console output: foo").kind).toBe("chat");
  expect(classify("/console").kind).toBe("chat");
  expect(classify(`/console ${NAME}`)).toEqual({ kind: "console", name: "", text: NAME });
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
  expect(replies[0]).toContain("no live console");
  expect(replies[0]).toContain(NAME);
});

test("a traversal-shaped console name is refused: nothing written outside consoles/, no cold session", async () => {
  const r = root(); const replies: string[] = []; const ran: string[] = [];
  mkdirSync(join(r, "consoles"), { recursive: true });
  writeFileSync(join(r, "escape.md"), "");
  // Invalid first words are bare text, never paths; with no live console
  // they queue nothing.
  await handleInbound(r, say("/console ../escape hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(ran).toEqual([]);
  replies.length = 0;
  await handleInbound(r, say("/console a..b hi"), async (s: string) => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate(replies));
  expect(readFileSync(join(r, "escape.md"), "utf8")).toBe("");
  expect(ran).toEqual([]);
  expect(replies.length).toBe(1);
  expect(replies[0]).toContain("no live console");
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

test("first waiter arm queues one announcement per identity, including successor, never on restart", async () => {
  const r = root(); const f = heartbeat(r); const successor = heartbeat(r, "successor");
  const access = join(r, "access.json");
  writeFileSync(access, JSON.stringify({ allowFrom: ["1"] }));
  const tick = join(r, "tick.sh"); const bank = join(r, "bank.sh");
  writeFileSync(tick, "#!/usr/bin/env bash\nexit 1\n");
  writeFileSync(bank, "#!/usr/bin/env bash\nprintf 'PROCEED\\n'\n");
  for (const inbox of [f, f, successor]) {
    // A pending inbox line makes the real waiter exit immediately, not an idle
    // timing probe. First-arm announcement must happen before its first wake.
    writeFileSync(inbox, "wake\n");
    writeFileSync(inbox + ".cursor", "0");
    const p = Bun.spawn([BASH_BIN, join(import.meta.dir, "../handover/console-kit/console-wait.sh"), inbox], {
      env: { ...process.env, BRIDGE_ROOT: r, TELEGRAM_ACCESS_PATH: access, CONSOLE_WAIT_TICK: tick, CONSOLE_WAIT_BANK: bank }, stdout: "pipe", stderr: "pipe",
    });
    await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
    expect(await p.exited).toBe(0);
  }
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").trim().split("\n").map(l => JSON.parse(l));
  expect(out.map(m => m.console)).toEqual([NAME, "successor"]);
  expect(out[0].text).toContain(`/console <text>`);
  expect(out[1].text).toContain("successor");
});

test("trusted console outbox receipt routes a Telegram reply to that console, even with two live consoles", async () => {
  const r = root(); const f = heartbeat(r); heartbeat(r, "second");
  await replyViaOutbox(r, 1, "console answer", NAME);
  await flushOutboxes(r, async () => 777);
  await ingestUpdates(r, [{ update_id: 1, message: { from: { id: 1 }, chat: { id: 1 }, text: "thanks, halt", reply_to_message: { message_id: 777 }, date: 1 } }]);
  const msg = JSON.parse(readFileSync(join(r, "inbound.jsonl"), "utf8").trim());
  const ran: string[] = [];
  await handleInbound(r, msg, async s => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(f, "utf8")).toContain("[telegram from=1 chat=1] thanks, halt");
  expect(readFileSync(join(r, "consoles", "second.md"), "utf8")).toBe("");
  expect(ran).toEqual([]);
});

test("reply mapping is chat-scoped and never bypasses sender, caption, forwarded or chat gates", async () => {
  for (const extra of [{ from: 999 }, { caption: true }, { forwarded: true }, { chat_id: -99 }]) {
    const r = root(); const f = heartbeat(r);
    await replyViaOutbox(r, 1, "answer", NAME);
    await flushOutboxes(r, async () => 777);
    const replies: string[] = [];
    const g: ConsoleRouteGate = { authorize: (from, chat) => from === 1 && chat === 1, reply: async (_chat, text) => { replies.push(text); } };
    await handleInbound(r, say("halt", { reply_to_message_id: 777, ...extra }), async () => {}, undefined, async () => "spawn-high", undefined, undefined, undefined, undefined, g);
    expect(readFileSync(f, "utf8")).toBe("");
    expect(replies).toEqual([]);
  }
});

test("an unrelated bot message or a forged reply label stays ordinary chat", async () => {
  const r = root(); const f = heartbeat(r); const ran: string[] = [];
  await replyViaOutbox(r, 1, "ordinary answer");
  await flushOutboxes(r, async () => 777);
  await handleInbound(r, say(`Console ${NAME} is live`, { reply_to_message_id: 777 }), async s => { ran.push(s); }, undefined, undefined, undefined, undefined, undefined, undefined, gate([]));
  expect(readFileSync(f, "utf8")).toBe("");
  expect(ran).toEqual(["__chat__"]);
});

test("reply CLI tags a running console's answer using the established session-name resolver", async () => {
  const r = root(); heartbeat(r);
  const cmdline = join(r, "cmdline");
  writeFileSync(cmdline, `claude\0-n\0${NAME}\0`);
  const p = Bun.spawn(["bun", join(import.meta.dir, "console-route.ts"), "reply", "1", "answer"], {
    env: { ...process.env, BRIDGE_ROOT: r, CLAUDE_PID: "123", SESSION_NAME_CMDLINE_FILE: cmdline }, stdout: "pipe", stderr: "pipe",
  });
  await Promise.all([new Response(p.stdout).text(), new Response(p.stderr).text()]);
  expect(await p.exited).toBe(0);
  const out = readFileSync(join(r, "sessions", "__chat__", "outbox.jsonl"), "utf8").trim();
  expect(JSON.parse(out)).toEqual({ text: "answer", console: NAME });
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
