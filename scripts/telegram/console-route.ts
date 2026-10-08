import { join, dirname, basename, resolve } from "node:path";
import { readdir, readFile, stat, mkdir, open, unlink } from "node:fs/promises";
import { appendIfExists, atomicWrite, defaultRoot } from "./bus";
import { loadAccess, operatorChatId } from "./gate";
import { BASH_BIN } from "./run";

// HIMMEL-3355: operator Telegram message -> a named RUNNING console.
//
// A console runs without --channels on purpose (a second getUpdates consumer
// 409s the bridge), so nothing reaches it today. Instead the poller — the one
// getUpdates consumer, unchanged — appends one line to the console's own file
// inbox and the console Monitors that file (docs/handover/console-template.md,
// ACTION ZERO). Bare `/console <text>` discovers a single fresh heartbeat;
// explicit `/console <name> <text>` and Telegram reply receipts pin a console.
//
// The inbox lives in the bridge's own non-git state dir (<bridge root>/consoles/),
// NOT under the handover root: that root is a git repo that auto-commits and
// pushes, which would publish Telegram text and stall its gitleaks pre-commit.
// It is also NOT <handover root>/inbox/<name>.md: the name-keyed claudex-inbox
// hook fires on native sessions too and would deliver every line twice.
//
// Authority (operator-equal, but not unbounded): the caller (poller.ts
// handleInbound) only reaches this for the global-allowFrom operator in an
// allowed chat, typed and not forwarded — gate.ts stays the sole sender gate.
// The line is tagged `[telegram from=<id> chat=<chat_id>]` so the console can
// tell it from a terminal message. It carries no RETASK token: it is operator
// -> console, never console -> leg (docs/internals/retask-channel.md).
//
// ponytail: explicit named/thread routes preserve armed-inbox delivery even
// without a fresh heartbeat; use /consoles before addressing an old identity,
// or require liveness on named routes if silent old-inbox queues recur.

export type ConsoleReplyFn = (chat_id: number, text: string, consoleName?: string, replyToMessageId?: number) => Promise<void>;
export type ConsoleRouteGate = {
  authorize: (from: number, chat_id: number) => boolean;
  reply: ConsoleReplyFn;
};
export type ConsoleRoute = { kind: "console"; name: string; text: string; thread?: boolean } | { kind: "consoles" };

export type LiveConsole = { name: string; hb: number; bucket: string; project: string };

export async function liveConsoles(root: string, now = Date.now()): Promise<LiveConsole[]> {
  const dir = join(root, "consoles");
  let files: string[];
  try { files = await readdir(dir); } catch { return []; }
  const live: LiveConsole[] = [];
  for (const f of files.sort()) {
    if (!f.endsWith(".md.wait")) continue;
    const name = f.slice(0, -8);
    const inbox = consoleInboxPath(root, name);
    if (!inbox) continue;
    let raw: string;
    try { raw = await readFile(inbox + ".wait", "utf8"); } catch { continue; }
    const match = /^hb=(\d+) pid=\d+ key=\S+ tick=(?:ok|fail|-) state=(waiting|sampling)$/.exec(raw.trim());
    if (!match) continue;
    const hb = Number(match[1]);
    const age = now - hb * 1000;
    if (!Number.isSafeInteger(hb) || age < 0 || age >= 300_000) continue;
    try { if (!(await stat(inbox)).isFile()) continue; } catch { continue; }
    let meta: { bucket?: string; project?: string } = {};
    try { meta = JSON.parse(await readFile(inbox + ".meta.json", "utf8")); } catch {}
    live.push({ name, hb, bucket: typeof meta?.bucket === "string" ? meta.bucket : "unknown", project: typeof meta?.project === "string" ? meta.project : "unknown" });
  }
  return live;
}

const describeConsoles = (live: LiveConsole[]) => live.map(c => `${c.name} — hb=${c.hb} (${new Date(c.hb * 1000).toISOString()}) bucket=${c.bucket} project=${c.project}`).join("\n");

// Same refusals as console-kit/inbox-send.sh (empty, path separator, `..`,
// whitespace) — the path is built from this value. The router's charset already
// excludes `/` and whitespace; `..` and empty are what reach here.
export function consoleInboxPath(root: string, name: string): string | null {
  if (name === "" || /[\\/\s]/.test(name) || name.includes("..")) return null;
  return join(root, "consoles", `${name}.md`);
}

// One message = one line, so a `tail -F` Monitor emits one event per message.
export const foldLine = (text: string): string => text.trim().replace(/\r?\n/g, " ⏎ ");

const hhmm = (d = new Date()) => `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;

export function staleConsoleCommand(ts?: number): boolean {
  const configured = Number(process.env.TELEGRAM_VERB_MAX_AGE_S ?? 300);
  const maxAge = Number.isSafeInteger(configured) && configured > 0 ? configured : 300;
  const age = Date.now() / 1000 - (ts ?? 0);
  return !Number.isSafeInteger(ts) || age < -5 || age > maxAge;
}

export async function routeFleetCommand(
  root: string,
  msg: { from: number; chat_id: number; ts?: number; message_id?: number; reply_to_message_id?: number },
  route: Extract<import("./router").Route, { kind: "fleet" }>,
  gate: ConsoleRouteGate,
): Promise<void> {
  if (!gate.authorize(msg.from, msg.chat_id)) return;
  const reply: ConsoleReplyFn = (chat, text, name) => gate.reply(chat, text, name, msg.message_id);
  if (staleConsoleCommand(msg.ts)) {
    await reply(msg.chat_id, "⚠️ stale, resend — nothing was queued.");
    return;
  }
  const pinned = msg.reply_to_message_id == null ? null : await consoleReplyTarget(root, msg.chat_id, msg.reply_to_message_id);
  const live = await liveConsoles(root);
  const target = pinned ? live.find(c => c.name === pinned) : live.length === 1 ? live[0] : undefined;
  if (!target) {
    await reply(msg.chat_id, pinned ? `⚠️ console ${pinned} is stale or not live — nothing was queued.` : live.length > 1 ? `More than one console is live; reply to its announcement or answer:\n${describeConsoles(live)}` : "⚠️ no live console — nothing was queued.");
    return;
  }
  const text = route.verb === "status" ? "fleet status" : `${route.verb}${route.leg ? ` ${route.leg}` : ""}`;
  await routeToConsole(root, msg, { kind: "console", name: target.name, text, thread: true }, (chat, ack, name) => reply(chat, name ? `queued ${text} → console ${name}` : ack, name));
}

export async function routeToConsole(
  root: string,
  msg: { from: number; chat_id: number },
  route: ConsoleRoute,
  reply: ConsoleReplyFn,
): Promise<void> {
  // The append is the delivery. A failed ack after it must not throw out of
  // handleInbound: handleBatch would tell the operator "could not be queued —
  // please resend" for a message that WAS queued, manufacturing a duplicate.
  const say = async (text: string, name?: string) => {
    try { await reply(msg.chat_id, text, name); }
    catch (e) { console.error(`[poller] console reply could not be delivered for chat ${msg.chat_id}: ${e}`); }
  };
  if (route.kind === "consoles") {
    const live = await liveConsoles(root);
    await say(live.length ? describeConsoles(live) : "⚠️ no live console — nothing was sent.");
    return;
  }
  let name = route.name;
  let text = route.text;
  let file = name ? consoleInboxPath(root, name) : null;
  // Preserve explicit addressing of an armed inbox. Otherwise the first word
  // is part of the bare command, not an invented session name.
  const named = file && await stat(file).then(s => s.isFile(), () => false);
  if (!named) {
    if (route.thread) { await say(`⚠️ no console "${name}" has an armed inbox — nothing was sent.`); return; }
    const live = await liveConsoles(root);
    if (live.length !== 1) {
      await say(live.length ? `More than one console is live; choose /console <name> <text>:\n${describeConsoles(live)}` : `⚠️ no live console${name ? ` (requested "${name}")` : ""} — nothing was sent.`);
      return;
    }
    text = name ? `${name} ${text}` : text;
    name = live[0].name;
    file = consoleInboxPath(root, name);
  }
  if (!file) return;
  // Append only to an inbox a console already armed; never create one, so a typo
  // cannot open a mailbox nobody reads. The append itself is the existence
  // check (HIMMEL-3440) — no separate existsSync() step left to race.
  const delivered = await appendIfExists(file, `- ${hhmm()} [telegram from=${msg.from} chat=${msg.chat_id}] ${foldLine(text)}`);
  if (!delivered) { await say(`⚠️ no console "${name}" is listening (it has not armed its inbox) — nothing was sent.`); return; }
  await say(`→ console ${name}`, name);
}

function replyPath(root: string, chat: number, message: number): string | null {
  if (!Number.isSafeInteger(chat) || chat === 0 || !Number.isSafeInteger(message) || message <= 0) return null;
  return join(root, "consoles", "replies", `${chat}_${message}.json`);
}

// Only the bridge's send receipt writes these mappings; reply text and quoted
// Telegram message bodies never supply a console identity.
export async function rememberConsoleReply(root: string, chat: number, message: number, name: string): Promise<void> {
  const file = replyPath(root, chat, message);
  if (!file || typeof name !== "string" || !consoleInboxPath(root, name)) return;
  await mkdir(dirname(file), { recursive: true });
  await atomicWrite(file, JSON.stringify({ name }));
}

export async function consoleReplyTarget(root: string, chat: number, message: number): Promise<string | null> {
  const file = replyPath(root, chat, message);
  if (!file) return null;
  try {
    const { name } = JSON.parse(await readFile(file, "utf8"));
    return typeof name === "string" && consoleInboxPath(root, name) ? name : null;
  } catch { return null; }
}

function inboxIdentity(inbox: string): { root: string; name: string } {
  const path = resolve(inbox);
  const root = dirname(dirname(path));
  const name = basename(path).replace(/\.md$/, "");
  if (consoleInboxPath(root, name) !== path) throw new Error("not a console inbox path");
  return { root, name };
}

export async function registerConsole(inbox: string, bucket: string, project: string): Promise<void> {
  inboxIdentity(inbox);
  await mkdir(dirname(inbox), { recursive: true });
  await atomicWrite(inbox + ".meta.json", JSON.stringify({ bucket, project }));
}

export async function announceConsole(inbox: string): Promise<void> {
  const { root, name } = inboxIdentity(inbox);
  if (!(await liveConsoles(root)).some(c => c.name === name)) return;
  const chat = operatorChatId(await loadAccess());
  if (chat === null) return;
  const marker = inbox + ".announced";
  let claim;
  try { claim = await open(marker, "wx"); }
  catch (e: any) { if (e.code === "EEXIST") return; throw e; }
  await claim.close();
  // ponytail: a kill between claim and enqueue can lose this one announcement;
  // use transactional outbox dedupe if crash-loss is observed. Re-arms never spam.
  try {
    const { replyViaOutbox } = await import("./poller");
    await replyViaOutbox(root, chat, `Console ${name} is live — just send /console <text>`, name);
  } catch (e) { await unlink(marker); throw e; }
}

async function currentConsoleName(root: string): Promise<string | undefined> {
  try {
    const p = Bun.spawn([BASH_BIN, "-c", '. "$1"; current_session_name', "console-reply", join(import.meta.dir, "../lib/session-name.sh")], { stdout: "pipe", stderr: "ignore" });
    const name = (await new Response(p.stdout).text()).trim();
    const file = consoleInboxPath(root, name);
    if (await p.exited === 0 && file && await stat(file).then(s => s.isFile(), () => false)) return name;
  } catch {}
  return undefined;
}

// CLI: `bun console-route.ts reply [--console <name>] <chat_id> <text...>` — the console's reply
// path. Appends to the same per-chat outbox every other bridge reply uses; the
// running poller flushes it. Dynamic import: poller.ts imports this module, so a
// static import back would be a cycle.
if (import.meta.main) {
  const [verb, ...args] = process.argv.slice(2);
  if (verb === "register" && args.length === 3) {
    await registerConsole(args[0], args[1], args[2]);
  } else if (verb === "announce" && args.length === 1) {
    await announceConsole(args[0]);
  } else {
    const name = args[0] === "--console" ? args.splice(0, 2)[1] : verb === "reply" ? await currentConsoleName(defaultRoot()) : undefined;
    const [chat, ...rest] = args;
    const chatId = Number(chat);
    if (verb === "reply" && Number.isSafeInteger(chatId) && chatId !== 0 && rest.length && (!name || consoleInboxPath(defaultRoot(), name))) {
      const { replyViaOutbox } = await import("./poller");
      await replyViaOutbox(defaultRoot(), chatId, rest.join(" "), name);
    } else {
      console.error("usage: bun console-route.ts reply [--console <name>] <chat_id> <text> | register <inbox> <bucket> <project> | announce <inbox>");
      process.exit(1);
    }
  }
}
