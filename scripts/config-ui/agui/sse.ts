// sse.ts — stream a Claude Code session journal as AG-UI events over SSE (HIMMEL-4480 PR2).
//
// resolveJournal(home, run): <run> must be a lowercase session UUID; it names
// exactly one ~/.claude/projects/<slug>/<run>.jsonl whose realpath stays under
// the realpath of ~/.claude/projects (a symlinked file or project directory
// that leaves it does not count). The path is only ever joined from readdir
// names and the validated UUID.
//
// journalStream(path, ...): reads the file from the start through the journal
// mapper's pushChunk, then polls for appends every pollMs. It ends when the
// client cancels, when no run is open and the file has not grown for idleMs, or
// at maxMs. A comment line every HEARTBEAT_MS keeps Bun's idleTimeout from
// cutting a quiet stream. The wire format is hand-encoded and identical to
// @ag-ui/encoder's EventEncoder (`data: <json>\n\n`); config-ui takes no
// dependency for it.

import { open, readdir, realpath, stat, type FileHandle } from "node:fs/promises";
import { join, sep } from "node:path";
import { createJournalMapper } from "./journal-mapper.ts";
import type { AguiEvent } from "./events.ts";

export const RUN_ID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const CHUNK = 256 * 1024;
const HEARTBEAT_MS = 15_000;

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
const ID_FIELDS = new Set(["type", "threadId", "runId", "messageId", "toolCallId", "parentMessageId", "toolCallName", "role", "timestamp"]);
export function redactPayload(e: AguiEvent, redact: (value: unknown) => unknown): AguiEvent {
  return Object.fromEntries(Object.entries(e).map(([k, v]) => [k, ID_FIELDS.has(k) ? v : redact(v)])) as AguiEvent;
}

export function journalStream(path: string, o: StreamOpts): ReadableStream<Uint8Array> {
  const mapper = createJournalMapper({ threadId: o.threadId });
  const utf8 = new TextDecoder();
  const enc = new TextEncoder();
  const started = Date.now();
  let fh: FileHandle | undefined, offset = 0, grewAt = started, beatAt = started, runOpen = false, closed = false;
  let timer: ReturnType<typeof setTimeout> | undefined, deadline: ReturnType<typeof setTimeout> | undefined, wake: (() => void) | undefined;
  const cleanup = () => {
    if (closed) return;
    closed = true;
    clearTimeout(timer);
    clearTimeout(deadline);
    wake?.();
    fh?.close().catch(() => {});
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
        if (!fh) {
          const h = await open(path, "r");
          if (closed) { await h.close(); return; } // cancelled while opening: cleanup ran before fh existed
          fh = h;
        }
        while (!closed) {
          if (Date.now() - started >= o.maxMs) return end(c);
          const size = (await fh.stat()).size;
          if (size < offset) return end(c); // truncated or replaced: nothing left to follow
          if (size > offset) {
            const buf = Buffer.alloc(Math.min(CHUNK, size - offset));
            const { bytesRead } = await fh.read(buf, 0, buf.length, offset);
            offset += bytesRead;
            grewAt = Date.now();
            const events = mapper.pushChunk(utf8.decode(buf.subarray(0, bytesRead), { stream: true }));
            if (events.length) { c.enqueue(frame(events)); return; }
            continue;
          }
          if (!runOpen && Date.now() - grewAt >= o.idleMs) return end(c, mapper.flush());
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
