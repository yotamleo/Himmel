import { expect, test } from "bun:test";
import { mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sessionDir, ensureSession, readMeta, writeMeta, atomicWrite } from "./bus";
import { appendLine, readNewLines, sessionDir as _sd, ensureSession as _es, sendToSession } from "./bus";
import { appendContext, readContext, truncateFullyConsumed } from "./bus";

function root() { return mkdtempSync(join(tmpdir(), "bus-")); }

test("ensureSession atomically creates dir + returns created flag", async () => {
  const r = root();
  const a = await ensureSession(r, "HIMMEL-1");
  const b = await ensureSession(r, "HIMMEL-1");
  expect(a.created).toBe(true);
  expect(b.created).toBe(false);
  expect(sessionDir(r, "HIMMEL-1")).toBe(join(r, "sessions", "HIMMEL-1"));
});

test("meta write/read round-trips; poller is sole writer", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-1");
  await writeMeta(r, "HIMMEL-1", { chat_id: 42, status: "idle", task_name: "t", last_run_pid: null, last_run_at: null, retry_at: null });
  const m = await readMeta(r, "HIMMEL-1");
  expect(m?.chat_id).toBe(42);
});

test("append + cursor reads only complete lines; partial held until newline", async () => {
  const r = root(); await _es(r, "S");
  const f = join(_sd(r,"S"), "inbox.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  await appendLine(f, JSON.stringify({ n: 2 }));
  let got = await readNewLines(f, cur);
  expect(got.map((o:any)=>o.n)).toEqual([1,2]);
  got = await readNewLines(f, cur);
  expect(got.length).toBe(0);
  await Bun.write(f, (await Bun.file(f).text()) + '{"n":3}');   // partial, no newline
  got = await readNewLines(f, cur);
  expect(got.length).toBe(0);                                    // partial NOT parsed
});

test("context append then compaction keeps head + recent under budget", async () => {
  const r = root(); await ensureSession(r, "S");
  for (let i=0;i<50;i++) await appendContext(r, "S", `note ${i}`, 200);
  const c = await readContext(r, "S");
  expect(c.length).toBeLessThanOrEqual(400);
  expect(c).toContain("note 49");
});

test("sendToSession creates target dir and appends text record to inbox.jsonl", async () => {
  const r = root();
  await sendToSession(r, "HIMMEL-30", "hi from A");
  const inbox = join(_sd(r, "HIMMEL-30"), "inbox.jsonl");
  const raw = await Bun.file(inbox).text();
  const rec = JSON.parse(raw.trim());
  expect(rec.text).toBe("hi from A");
});

test("truncateFullyConsumed resets file+cursor only when cursor reached EOF; preserves a half-read log + later reads start fresh", async () => {
  const r = root();
  const f = join(r, "outbox.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  await appendLine(f, JSON.stringify({ n: 2 }));
  const full = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  // cursor short of EOF → must NOT truncate (unsent bytes remain)
  await atomicWrite(cur, "5");
  expect(await truncateFullyConsumed(f, cur)).toBe(false);
  expect(Buffer.byteLength(await Bun.file(f).text(), "utf8")).toBe(full);
  // cursor at EOF → reclaim: file emptied, cursor reset to 0
  await atomicWrite(cur, String(full));
  expect(await truncateFullyConsumed(f, cur)).toBe(true);
  expect(await Bun.file(f).text()).toBe("");
  expect(await Bun.file(cur).text()).toBe("0");
  // idempotent: nothing to reclaim after reset
  expect(await truncateFullyConsumed(f, cur)).toBe(false);
  // a fresh append after reclaim is read from offset 0 (no orphaned bytes)
  await appendLine(f, JSON.stringify({ n: 3 }));
  const got = await readNewLines(f, cur);
  expect(got.map((o:any)=>o.n)).toEqual([3]);
});

test("truncateFullyConsumed no-ops on missing files / zero cursor", async () => {
  const r = root();
  const f = join(r, "nope.jsonl"); const cur = f + ".cursor";
  expect(await truncateFullyConsumed(f, cur)).toBe(false);   // no cursor file
  await appendLine(f, "x"); await atomicWrite(cur, "0");
  expect(await truncateFullyConsumed(f, cur)).toBe(false);   // cursor at 0 → nothing consumed
});

test("atomicWrite writes content and leaves no .tmp file behind", async () => {
  const r = root();
  const p = join(r, "cursor");
  await atomicWrite(p, "123");
  expect(await Bun.file(p).text()).toBe("123");
  expect(existsSync(p + ".tmp")).toBe(false);
});
