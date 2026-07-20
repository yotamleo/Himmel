import { mkdir, readFile, writeFile, rename, appendFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

export const defaultRoot = () => process.env.BRIDGE_ROOT ?? join(homedir(), ".claude", "handover", "bridge");
export const bridgeRoot = defaultRoot;
export const sessionDir = (root: string, s: string) => join(root, "sessions", s);

// Atomic write: tmp + rename so a crash mid-write can't leave a torn file.
// Committed state (cursors/offsets/meta) must never be half-written.
export async function atomicWrite(path: string, data: string): Promise<void> {
  const tmp = path + ".tmp";
  await writeFile(tmp, data, "utf8");
  await rename(tmp, path);
}

// "failed" (HIMMEL-263): retry cap exhausted — auto-retry parked until a new
// operator message arrives (handleInbound resets it). fail_count counts
// consecutive unsuccessful settles; cleared by any clean run.
export type Meta = { chat_id: number; status: "idle"|"running"|"done"|"capped"|"failed";
  last_run_pid: number|null; last_run_at: string|null; task_name: string|null; retry_at: string|null;
  fail_count?: number|null };

export async function ensureSession(root: string, s: string): Promise<{created: boolean}> {
  await mkdir(join(root, "sessions"), { recursive: true });
  try { await mkdir(sessionDir(root, s)); return { created: true }; }
  catch (e: any) { if (e?.code === "EEXIST") return { created: false }; throw e; }
}

export async function readMeta(root: string, s: string): Promise<Meta|null> {
  try { return JSON.parse(await readFile(join(sessionDir(root, s), "meta.json"), "utf8")); }
  catch { return null; }
}
export async function writeMeta(root: string, s: string, m: Meta): Promise<void> {
  const p = join(sessionDir(root, s), "meta.json");
  const tmp = p + ".tmp";
  await writeFile(tmp, JSON.stringify(m), "utf8");
  await rename(tmp, p);
}

export async function appendLine(file: string, line: string): Promise<void> {
  await appendFile(file, line + "\n", "utf8");
}
// Reclaim a fully-consumed append-log so a very long-lived session's
// inbox/outbox can't grow unbounded (each flush/peek tick reads the whole file
// into memory — HIMMEL-221). Truncates ONLY when the byte-cursor has reached
// EOF, i.e. every line is already sent/consumed, then resets both file and
// cursor to 0. The pre-rename length re-read shrinks the window where a
// concurrent cross-process writer (a bounded run child appending to outbox) could lose
// a line: if the file grew between the two reads we defer to the next tick. A
// residual sub-millisecond race remains (an append landing on the old inode
// after the second read but before the rename) — acceptable under the bridge's
// existing at-least-once / operator-resends model, and bounded to one flush
// interval of output. Single-writer logs (cursor == EOF means the writer is
// idle) are fully safe. No-op (returns false) unless there is something to reclaim.
export async function truncateFullyConsumed(file: string, cursorFile: string): Promise<boolean> {
  let cur = 0;
  try { cur = Number(await readFile(cursorFile, "utf8")) || 0; } catch { return false; }
  if (cur <= 0) return false;                                  // nothing consumed yet / already fresh
  let len = 0;
  try { len = Buffer.byteLength(await readFile(file, "utf8"), "utf8"); } catch { return false; }
  if (cur < len) return false;                                 // unsent/unconsumed bytes remain → keep
  let len2 = 0;
  try { len2 = Buffer.byteLength(await readFile(file, "utf8"), "utf8"); } catch { return false; }
  if (len2 !== len) return false;                              // grew between reads → defer to next tick
  await atomicWrite(file, "");
  await atomicWrite(cursorFile, "0");
  return true;
}
// reader tracks a byte offset in <file>.cursor; parses only '\n'-terminated lines.
export async function readNewLines(file: string, cursorFile: string): Promise<any[]> {
  let start = 0;
  try { start = Number(await readFile(cursorFile, "utf8")) || 0; } catch {}
  let buf = "";
  try { buf = await readFile(file, "utf8"); } catch { return []; }
  const total = Buffer.byteLength(buf, "utf8");
  if (start >= total) return [];
  const slice = Buffer.from(buf, "utf8").subarray(start).toString("utf8");
  const lastNl = slice.lastIndexOf("\n");
  if (lastNl < 0) return [];
  const complete = slice.slice(0, lastNl);
  const consumed = start + Buffer.byteLength(complete + "\n", "utf8");
  const out: any[] = [];
  for (const ln of complete.split("\n")) if (ln.trim()) { try { out.push(JSON.parse(ln)); } catch {} }
  await atomicWrite(cursorFile, String(consumed));
  return out;
}

// IPC (T6/HIMMEL-219): append a message to <target>'s durable inbox so the
// poller's delivery scan spawns a bounded run for the target (if idle) to consume
// it. ensureSession first so a not-yet-seen target still queues durably.
// origin:"sendToSession" (HIMMEL-1218): this is the TRUSTED A->B inter-session
// writer (the only current caller is the `bus.ts send` CLI) — distinct from
// poller.ts's direct inbox.jsonl append for a real inbound Telegram message
// (no origin field there). Stamping it lets a session's RETASK-channel
// verification tell "arrived via the trusted bus" from "arrived via Telegram"
// without inferring it from message shape.
export async function sendToSession(root: string, target: string, text: string): Promise<void> {
  await ensureSession(root, target);
  await appendLine(join(sessionDir(root, target), "inbox.jsonl"), JSON.stringify({ text, from: 0, ts: 0, origin: "sendToSession" }));
}

// context.md: a session's cross-run memory. The bounded run is its SOLE writer
// (runs of one session are serialized so append is race-free); it COMPACTS past
// a size budget (bounded head summary + recent notes) so prompts stay bounded.
export async function readContext(root: string, s: string): Promise<string> {
  try { return await readFile(join(sessionDir(root, s), "context.md"), "utf8"); } catch { return ""; }
}
export async function appendContext(root: string, s: string, note: string, budget = 8000): Promise<void> {
  const p = join(sessionDir(root, s), "context.md");
  let cur = await readContext(root, s);
  cur += (cur ? "\n" : "") + `- ${note}`;
  if (cur.length > budget) {
    const head = cur.slice(0, Math.floor(budget * 0.25));
    const tail = cur.slice(-Math.floor(budget * 0.5));
    cur = head + "\n…(compacted)…\n" + tail;
  }
  const tmp = p + ".tmp"; await writeFile(tmp, cur, "utf8"); await rename(tmp, p);
}

// CLI: `bun bus.ts send <target> <text...>` — A→B inter-session message.
if (import.meta.main) {
  const [verb, target, ...rest] = process.argv.slice(2);
  if (verb === "send" && target && rest.length) {
    await sendToSession(defaultRoot(), target, rest.join(" "));
  } else {
    console.error("usage: bun bus.ts send <target> <text>");
    process.exit(1);
  }
}
