// sse.ts — stream a Claude Code session journal as AG-UI events over SSE (HIMMEL-4480 PR2).
//
// resolveJournal(home, run): <run> must be a lowercase session UUID; it names
// exactly one ~/.claude/projects/<slug>/<run>.jsonl whose realpath stays under
// the realpath of ~/.claude/projects (a symlinked file or project directory
// that leaves it does not count). The path is only ever joined from readdir
// names and the validated UUID.
//
// journalStream(path, ...): reads the file from the start through the journal
// mapper, then polls for appends every pollMs. It also follows the session's
// subagent transcripts (<session>/subagents/agent-<id>.jsonl, HIMMEL-4669),
// merging their lines with the journal's in timestamp order, so the page can
// show which agent did what. It ends when the client cancels, when no run is
// open and no file has grown for idleMs, or at maxMs. A comment line every HEARTBEAT_MS keeps Bun's idleTimeout from
// cutting a quiet stream. The wire format is hand-encoded and identical to
// @ag-ui/encoder's EventEncoder (`data: <json>\n\n`); config-ui takes no
// dependency for it.

import { open, readdir, realpath, stat, type FileHandle } from "node:fs/promises";
import { basename, dirname, join, sep } from "node:path";
import { createJournalMapper } from "./journal-mapper.ts";
import type { AguiEvent } from "./events.ts";

export const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CHUNK = 256 * 1024;
const HEARTBEAT_MS = 15_000;
const MAX_SUBAGENTS = 64; // files followed per stream, beside the journal itself

export type Resolved = { path: string } | { status: 400 | 404 | 409 };

export async function resolveJournal(home: string, run: string): Promise<Resolved> {
  if (!RUN_ID.test(run)) return { status: 400 };
  let root: string, slugs: string[];
  try {
    root = await realpath(join(home, ".claude", "projects"));
    slugs = await readdir(root);
  } catch { return { status: 404 }; }
  const found: string[] = [];
  for (const slug of slugs) {
    let real: string;
    try { real = await realpath(join(root, slug, `${run}.jsonl`)); } catch { continue; }
    if (!real.startsWith(root + sep)) continue;
    try { if (!(await stat(real)).isFile()) continue; } catch { continue; }
    found.push(real);
  }
  if (found.length === 0) return { status: 404 };
  if (found.length > 1) return { status: 409 };
  return { path: found[0] };
}

export type StreamOpts = {
  threadId: string; pollMs: number; idleMs: number; maxMs: number;
  redact: (value: unknown) => unknown; onClose: () => void;
};

// The fields that only identify (ids, names, roles, times). The shared redactor
// treats any 32+ char run as a secret, which would collapse every session UUID
// and toolu_ id into one; payload fields (deltas, results, messages, state) pass it.
// `agent` (who acted: a session or subagent name, role, model) and `failure` (an enum) identify too: a leg's
// session name is often 32+ chars and would otherwise be redacted to nothing.
const ID_FIELDS = new Set(["type", "threadId", "runId", "messageId", "toolCallId", "parentMessageId", "toolCallName", "role", "timestamp", "agent", "failure"]);
export function redactPayload(e: AguiEvent, redact: (value: unknown) => unknown): AguiEvent {
  return Object.fromEntries(Object.entries(e).map(([k, v]) => [k, ID_FIELDS.has(k) ? v : redact(v)])) as AguiEvent;
}

// One followed file: the session journal, or one of its subagents' transcripts.
type Source = { path: string; fh?: FileHandle; offset: number; tail: string; utf8: TextDecoder; lastTs: number };
type Line = { text: string; ts: number; order: number };
const TS = /"timestamp"\s*:\s*"([^"]+)"/;

// A session's subagents write <session>/subagents/agent-<id>.jsonl beside <session>.jsonl. Only plain names
// are joined, and a file whose realpath leaves the journal's own directory is skipped.
const SUB_FILE = /^agent-[A-Za-z0-9_-]{1,64}\.jsonl$/;
async function subagentFiles(journal: string, known: Set<string>): Promise<string[]> {
  const dir = dirname(journal);
  const subs = join(dir, basename(journal, ".jsonl"), "subagents");
  let names: string[];
  try { names = await readdir(subs); } catch { return []; }
  const out: string[] = [];
  for (const name of names.filter((n) => SUB_FILE.test(n)).sort()) {
    if (known.size + out.length >= MAX_SUBAGENTS) break;
    let real: string;
    try { real = await realpath(join(subs, name)); } catch { continue; }
    if (known.has(real) || !real.startsWith(dir + sep)) continue;
    try { if (!(await stat(real)).isFile()) continue; } catch { continue; }
    out.push(real);
  }
  return out;
}

export function journalStream(path: string, o: StreamOpts): ReadableStream<Uint8Array> {
  const mapper = createJournalMapper({ threadId: o.threadId });
  const enc = new TextEncoder();
  const started = Date.now();
  const src = (p: string): Source => ({ path: p, offset: 0, tail: "", utf8: new TextDecoder(), lastTs: -Infinity });
  const main = src(path);
  const subs: Source[] = [];
  const known = new Set<string>([path]);
  let held: Line[] = []; // subagent lines newer than the journal has been read to
  let order = 0, grewAt = started, beatAt = started, runOpen = false, closed = false;
  let timer: ReturnType<typeof setTimeout> | undefined, deadline: ReturnType<typeof setTimeout> | undefined, wake: (() => void) | undefined;
  const cleanup = () => {
    if (closed) return;
    closed = true;
    clearTimeout(timer);
    clearTimeout(deadline);
    wake?.();
    for (const s of [main, ...subs]) s.fh?.close().catch(() => {});
    o.onClose();
  };
  const frame = (events: AguiEvent[]) => {
    for (const e of events) {
      if (e.type === "RUN_STARTED") runOpen = true;
      else if (e.type === "RUN_FINISHED" || e.type === "RUN_ERROR") runOpen = false;
    }
    return enc.encode(events.map((e) => `data: ${JSON.stringify(redactPayload(e, o.redact))}\n\n`).join(""));
  };
  const end = (c: ReadableStreamDefaultController<Uint8Array>, tail: AguiEvent[] = []) => {
    if (tail.length) c.enqueue(frame(tail));
    cleanup();
    c.close();
  };
  // Reads up to CHUNK new bytes of one source into complete lines; a line with no timestamp sorts with the one before.
  // Returns null when the file shrank (truncated or replaced).
  const read = async (s: Source): Promise<Line[] | null> => {
    if (!s.fh) {
      const h = await open(s.path, "r");
      if (closed) { await h.close(); return []; } // cancelled while opening: cleanup ran before fh existed
      s.fh = h;
    }
    const size = (await s.fh.stat()).size;
    if (size < s.offset) return null;
    if (size === s.offset) return [];
    const buf = Buffer.alloc(Math.min(CHUNK, size - s.offset));
    const { bytesRead } = await s.fh.read(buf, 0, buf.length, s.offset);
    s.offset += bytesRead;
    grewAt = Date.now();
    const parts = (s.tail + s.utf8.decode(buf.subarray(0, bytesRead), { stream: true })).split("\n");
    s.tail = parts.pop()!;
    return parts.map((text) => {
      const ms = Date.parse(TS.exec(text)?.[1] ?? "");
      if (Number.isFinite(ms)) s.lastTs = ms;
      return { text, ts: s.lastTs, order: order++ };
    });
  };
  const map = (lines: Line[]) => lines.sort((a, b) => a.ts - b.ts || a.order - b.order).flatMap((l) => mapper.pushLine(l.text));
  return new ReadableStream<Uint8Array>({
    // pull() is not called while a stalled client leaves the queue full, so the
    // max duration also runs on its own timer to release the fd and the server.
    start(c) {
      deadline = setTimeout(() => {
        if (closed) return;
        cleanup();
        try { c.close(); } catch {}
      }, o.maxMs);
    },
    async pull(c) {
      try {
        while (!closed) {
          if (Date.now() - started >= o.maxMs) return end(c);
          for (const p of await subagentFiles(path, known)) { known.add(p); subs.push(src(p)); }
          const fromMain = await read(main);
          if (fromMain === null) return end(c); // truncated or replaced: nothing left to follow
          for (const s of subs) held.push(...((await read(s)) ?? [])); // a shrunk subagent file just stops growing
          // While the journal still has unread bytes, a subagent line later than its last line waits for them,
          // so a subagent's records land after the Agent call that spawned it.
          const behind = main.fh && main.offset < (await main.fh.stat()).size;
          const cut = behind ? main.lastTs : Infinity;
          const ready = held.filter((l) => l.ts <= cut);
          held = held.filter((l) => l.ts > cut);
          const events = map([...fromMain, ...ready]);
          if (events.length) { c.enqueue(frame(events)); return; }
          if (fromMain.length || ready.length || behind) continue;
          if (!runOpen && Date.now() - grewAt >= o.idleMs) {
            const rest = [main, ...subs].filter((s) => s.tail).map((s) => ({ text: s.tail, ts: s.lastTs, order: order++ }));
            for (const s of [main, ...subs]) s.tail = "";
            return end(c, [...map([...held, ...rest]), ...mapper.flush()]);
          }
          if (Date.now() - beatAt >= HEARTBEAT_MS) { beatAt = Date.now(); c.enqueue(enc.encode(": keepalive\n\n")); return; }
          await new Promise<void>((r) => { wake = r; timer = setTimeout(r, o.pollMs); });
        }
      } catch (e) {
        if (closed) return; // the client cancelled mid-read
        cleanup();
        c.error(e);
      }
    },
    cancel() { cleanup(); },
  });
}
