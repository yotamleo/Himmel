import { existsSync } from "node:fs";
import { join } from "node:path";
import { appendLine, defaultRoot } from "./bus";

// HIMMEL-3355: operator Telegram message -> a named RUNNING console.
//
// A console runs without --channels on purpose (a second getUpdates consumer
// 409s the bridge), so nothing reaches it today. Instead the poller — the one
// getUpdates consumer, unchanged — appends one line to the console's own file
// inbox and the console Monitors that file (docs/handover/console-template.md,
// ACTION ZERO). Addressing is `/console <name> <text>` (router.ts).
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
// ponytail: an inbox file that exists is only evidence a console armed its
// monitor at some point, not that it is alive now — a wrapped console leaves
// its file behind, and a line to it is acked but read by no one. Liveness would
// need lock parsing; the ack text says "queued", never "read".

export type ConsoleReplyFn = (chat_id: number, text: string) => Promise<void>;
export type ConsoleRouteGate = {
  authorize: (from: number, chat_id: number) => boolean;
  reply: ConsoleReplyFn;
};
export type ConsoleRoute = { kind: "console"; name: string; text: string };

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

export async function routeToConsole(
  root: string,
  msg: { from: number; chat_id: number },
  route: ConsoleRoute,
  reply: ConsoleReplyFn,
): Promise<void> {
  // The append is the delivery. A failed ack after it must not throw out of
  // handleInbound: handleBatch would tell the operator "could not be queued —
  // please resend" for a message that WAS queued, manufacturing a duplicate.
  const say = async (text: string) => {
    try { await reply(msg.chat_id, text); }
    catch (e) { console.error(`[poller] console reply could not be delivered for chat ${msg.chat_id}: ${e}`); }
  };
  const file = consoleInboxPath(root, route.name);
  if (!file) { await say(`⚠️ refused: "${route.name}" is not a valid console name — nothing was sent.`); return; }
  // Append only to an inbox a console already armed; never create one, so a typo
  // cannot open a mailbox nobody reads.
  if (!existsSync(file)) { await say(`⚠️ no console "${route.name}" is listening (it has not armed its inbox) — nothing was sent.`); return; }
  await appendLine(file, `- ${hhmm()} [telegram from=${msg.from} chat=${msg.chat_id}] ${foldLine(route.text)}`);
  await say(`→ console ${route.name}`);
}

// CLI: `bun console-route.ts reply <chat_id> <text...>` — the console's reply
// path. Appends to the same per-chat outbox every other bridge reply uses; the
// running poller flushes it. Dynamic import: poller.ts imports this module, so a
// static import back would be a cycle.
if (import.meta.main) {
  const [verb, chat, ...rest] = process.argv.slice(2);
  const chatId = Number(chat);
  if (verb === "reply" && Number.isSafeInteger(chatId) && chatId !== 0 && rest.length) {
    const { replyViaOutbox } = await import("./poller");
    await replyViaOutbox(defaultRoot(), chatId, rest.join(" "));
  } else {
    console.error("usage: bun console-route.ts reply <chat_id> <text>");
    process.exit(1);
  }
}
