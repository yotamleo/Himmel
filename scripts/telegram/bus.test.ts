import { expect, test } from "bun:test";
import { mkdtempSync, existsSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { sessionDir, ensureSession, readMeta, writeMeta, atomicWrite } from "./bus";
import { appendLine, readNewLines, sessionDir as _sd, ensureSession as _es, sendToSession } from "./bus";
import { appendContext, readContext, truncateFullyConsumed } from "./bus";
import { repairCursorBeyondEof } from "./bus";

function root() { return mkdtempSync(join(tmpdir(), "telegram-bus-")); }

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
  // HIMMEL-1218: the trusted A->B writer stamps its origin so a receiving
  // session's RETASK-channel verification can distinguish it from a directly
  // Telegram-relayed inbox record (which carries no origin field).
  expect(rec.origin).toBe("sendToSession");
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

// HIMMEL-2580: a cursor PAST EOF (the inbox file shrank under it — a restore
// copied an older inbound.jsonl next to a newer cursor) made readNewLines
// return [] on every tick forever, silently: 8 operator messages were dropped
// on 2026-09-05. `start > total` is not "nothing new", it is an INVALID
// cursor — reset it to EOF (never to 0: replaying a 345 KB inbox is its own
// incident) and make the loss visible, in the log AND to the operator.
test("readNewLines: a cursor beyond EOF is invalid — reset to EOF, log loudly, notify once", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  const size = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  await atomicWrite(cur, String(size + 7000));               // the shrink

  const seen: any[] = [];
  const logs: string[] = [];
  const origErr = console.error;
  console.error = (...a: any[]) => { logs.push(a.join(" ")); };
  let got: any[];
  try { got = await readNewLines(f, cur, (info) => { seen.push(info); }); }
  finally { console.error = origErr; }

  expect(got).toEqual([]);                                    // this batch is gone — it is not on disk
  expect(await Bun.file(cur).text()).toBe(String(size));      // reset to EOF, not 0
  expect(logs.some(l => l.includes("[bus] cursor") && l.includes("beyond EOF"))).toBe(true);
  expect(seen).toEqual([{ file: f, cursor: size + 7000, size }]);
  // and the very next read is a normal no-op: the reset is not itself a loop
  const logs2: string[] = []; const seen2: any[] = [];
  console.error = (...a: any[]) => { logs2.push(a.join(" ")); };
  try { expect(await readNewLines(f, cur, (i) => { seen2.push(i); })).toEqual([]); }
  finally { console.error = origErr; }
  expect(logs2).toEqual([]);
  expect(seen2).toEqual([]);
});

// Negative control for the above: cursor EXACTLY at EOF is the ordinary
// "nothing new since last tick" case that runs on every idle poll — it must
// stay silent, or the fix trades a silent drop for a per-tick false alarm.
test("readNewLines: cursor exactly at EOF stays silent (no log, no notice)", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  const size = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  await atomicWrite(cur, String(size));

  const seen: any[] = [];
  const logs: string[] = [];
  const origErr = console.error;
  console.error = (...a: any[]) => { logs.push(a.join(" ")); };
  try { expect(await readNewLines(f, cur, (i) => { seen.push(i); })).toEqual([]); }
  finally { console.error = origErr; }
  expect(logs).toEqual([]);
  expect(seen).toEqual([]);
  expect(await Bun.file(cur).text()).toBe(String(size));      // untouched
});

// A notice that throws (Telegram down, chat unreachable) must not take the
// cursor reset with it — the reset is the part that unwedges the bridge.
test("readNewLines: a failing reset notice still leaves the cursor repaired", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  const size = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  await atomicWrite(cur, String(size + 1));

  const logs: string[] = [];
  const origErr = console.error;
  console.error = (...a: any[]) => { logs.push(a.join(" ")); };
  try { expect(await readNewLines(f, cur, async () => { throw new Error("telegram down"); })).toEqual([]); }
  finally { console.error = origErr; }
  expect(await Bun.file(cur).text()).toBe(String(size));
  // HIMMEL-2580 CR: the notice failure must not vanish — log it, or the
  // operator has no way to learn the repair happened at all.
  expect(logs.some(l => l.includes("[bus]") && l.includes("notice failed"))).toBe(true);
});

// HIMMEL-2580 CR (Important, agreed): a MISSING inbox file must not bypass
// the repair. Before this fix, readFile(file) threw on ENOENT and
// repairCursorBeyondEof returned false without touching the cursor — exactly
// the restore/shadow-copy class that caused the original incident (a stale
// cursor survives next to an inbox file that is now genuinely GONE). ENOENT
// is treated as an empty inbox (total=0), so the ordinary start > total
// branch fires: the cursor resets to 0, the reset is logged, and the notice
// fires — same contract as any other beyond-EOF repair, just with nothing on
// disk to report as "beyond".
test("repairCursorBeyondEof: a stale cursor over a MISSING inbox file is still repaired", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";   // f is never created
  await atomicWrite(cur, "5000");

  const seen: any[] = [];
  const logs: string[] = [];
  const origErr = console.error;
  console.error = (...a: any[]) => { logs.push(a.join(" ")); };
  let repaired: boolean;
  try { repaired = await repairCursorBeyondEof(f, cur, (info) => { seen.push(info); }); }
  finally { console.error = origErr; }

  expect(repaired).toBe(true);
  expect(await Bun.file(cur).text()).toBe("0");
  expect(logs.some(l => l.includes("[bus] cursor") && l.includes("beyond EOF"))).toBe(true);
  expect(seen).toEqual([{ file: f, cursor: 5000, size: 0 }]);
});

// HIMMEL-2580 CR (Important, agreed): repairing a beyond-EOF cursor AFTER the
// poll tick's own ingestUpdates append discards that tick's just-appended
// messages too, because the reset lands on the POST-append EOF and the fresh
// lines sit below it. This is the ordering defect itself — the ordering
// PROPERTY of repairCursorBeyondEof relative to a simulated ingest append —
// not a restatement of the reset/log/notice contract above, and not itself a
// pin on the poller's production call site (see poller.test.ts's
// repairThenIngest test for that: calling repairCursorBeyondEof and
// appendLine directly here, as these two tests do, stays green even if
// main()'s real call were moved back below ingestUpdates).
test("repairCursorBeyondEof before the tick's own append preserves that append", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  const staleSize = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  await atomicWrite(cur, String(staleSize + 7000));             // the shrink (stale cursor beyond EOF)

  const origErr = console.error;
  console.error = () => {};
  try {
    // Fixed order: repair FIRST (the ordering this ticket ships), THEN the
    // tick's own append (simulating ingestUpdates) — the appended line lands
    // above the just-repaired cursor and IS read.
    await repairCursorBeyondEof(f, cur);
    await appendLine(f, JSON.stringify({ n: 2 }));
    const got = await readNewLines(f, cur);
    expect(got).toEqual([{ n: 2 }]);
  } finally { console.error = origErr; }
});

test("repairCursorBeyondEof after the append loses it — why the poller repairs pre-ingest", async () => {
  const r = root();
  const f = join(r, "inbound.jsonl"); const cur = f + ".cursor";
  await appendLine(f, JSON.stringify({ n: 1 }));
  const staleSize = Buffer.byteLength(await Bun.file(f).text(), "utf8");
  await atomicWrite(cur, String(staleSize + 7000));             // the shrink (stale cursor beyond EOF)

  const origErr = console.error;
  console.error = () => {};
  try {
    // The order this branch moved AWAY from, pinned here as the negative
    // case of repairCursorBeyondEof's own ordering property (NOT a pin on
    // the poller's production call site — that protection lives in
    // poller.test.ts's repairThenIngest test, which goes red if main()'s
    // call is ever moved back below ingestUpdates): the tick's own append
    // happens FIRST, THEN repair — the reset lands on the POST-append EOF,
    // so the appended line sits below the repaired cursor and is swallowed
    // with the lost bytes.
    await appendLine(f, JSON.stringify({ n: 2 }));
    await repairCursorBeyondEof(f, cur);
    const got = await readNewLines(f, cur);
    expect(got).toEqual([]);
  } finally { console.error = origErr; }
});
