import { expect, test } from "bun:test";
import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readNewLines, readMeta, writeMeta, ensureSession, appendLine, sessionDir } from "./bus";
import { ingestUpdates, loadOffset, handleInbound, handleAutoCommand, replyViaOutbox, runAndSettle, reconcile, flushOutboxes, isRetryDue, peekPending, commitPending, makeRunFn, makeAllow, makeDispatcher, makeFetchVoice, sweepStuckRunning, signalTyping, guarded, deliverAllPending, sweepAttachments, resolveRetentionMs, noticeText, type FetchImageFn } from "./poller";
import { readFile, writeFile, mkdir, utimes } from "node:fs/promises";
import { isAllowed, vaultForChat } from "./gate";

const root = () => mkdtempSync(join(tmpdir(), "poller-"));
const allowAll = () => true;

// --- retry cap + run.log (HIMMEL-262/263) ---

const freshMeta = (chat_id: number) => ({ chat_id, status: "idle" as const, last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });

test("retry cap: after maxRetries consecutive failures the session parks as failed, giveup notified once, no further spawns", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "ship it" }));
  let spawns = 0;
  const failing = async () => { spawns++; return { code: 1, capped: false, pid: 1 }; };
  const notices: string[] = [];
  const notify = async (_s: string, _r: string, kind: string) => { notices.push(kind); };
  const runFn = makeRunFn(r, "/repo", failing, 5000, notify, 3);
  await runFn("S"); await runFn("S"); await runFn("S");        // 3 failures = cap
  expect((await readMeta(r, "S"))?.status).toBe("failed");
  expect((await readMeta(r, "S"))?.fail_count).toBe(3);
  await runFn("S");                                            // parked → no spawn
  expect(spawns).toBe(3);
  expect(notices.filter((k) => k === "giveup").length).toBe(1);
  expect(notices.filter((k) => k === "transient").length).toBe(1);   // capped:false → transient, not cap (HIMMEL: first failure of the episode)
  expect((await peekPending(r, "S")).count).toBe(1);           // message preserved, not lost
});

test("content-filter block: parks failed on the FIRST failure (no retry climb), notifies kind 'blocked'", async () => {
  // A content-filter block is deterministic — every retry replays the same blocked
  // output. So it must park IMMEDIATELY as "failed" (not climb MAX_RETRIES under the
  // "capped" mislabel) and surface an accurate "blocked" notice, not "backoff".
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "trips the filter" }));
  let spawns = 0;
  const blockedRun = async () => { spawns++; return { code: 1, capped: false, blocked: true, pid: 1 }; };
  const notices: string[] = [];
  const notify = async (_s: string, _r: string, kind: string) => { notices.push(kind); };
  const runFn = makeRunFn(r, "/repo", blockedRun, 5000, notify, 3);
  await runFn("S");
  const m = await readMeta(r, "S");
  expect(m?.status).toBe("failed");                    // parked immediately, not "capped"
  expect(m?.fail_count ?? null).toBe(null);            // no retry climb
  expect(m?.retry_at).toBe(null);                      // no pointless backoff retry
  expect(spawns).toBe(1);                              // exactly ONE run — no 3× retry loop
  expect(notices).toEqual(["blocked"]);                // accurate notice, not "backoff"/"giveup"
  expect((await peekPending(r, "S")).count).toBe(1);   // message preserved (un-parkable by a new message)
});

test("content-filter block takes precedence over a simultaneous cap (blocked wins, parks failed not capped)", async () => {
  // Load-bearing ordering guard: if a run is BOTH capped and blocked, the deterministic
  // block must win — park failed immediately, NOT climb the capped/retry path. A future
  // reorder that let "capped" win would silently regress to the 3×-retry loop this fixes.
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "both flags set" }));
  let spawns = 0;
  const bothRun = async () => { spawns++; return { code: 1, capped: true, blocked: true, pid: 1 }; };
  const notices: string[] = [];
  const notify = async (_s: string, _r: string, kind: string) => { notices.push(kind); };
  await makeRunFn(r, "/repo", bothRun, 5000, notify, 3)("S");
  const m = await readMeta(r, "S");
  expect(m?.status).toBe("failed");        // blocked branch wins over the cap branch
  expect(m?.retry_at).toBe(null);          // not the capped back-off
  expect(spawns).toBe(1);                  // one run, no retry climb
  expect(notices).toEqual(["blocked"]);    // not "backoff"
});

test("transient non-zero exit (e.g. 529 Overloaded) notifies 'transient' not 'cap', and still backs off + retries", async () => {
  // Regression guard for the 529-mislabeled-as-cap bug: a run that exits non-zero
  // WITHOUT a genuine cap sentinel (capped:false) must surface the transient notice,
  // never the usage-cap one — while still backing off (status=capped is the shared
  // generic back-off state) and re-peeking the still-uncommitted pending.
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "5 X links" }));
  const overloaded = async () => ({ code: 1, capped: false, blocked: false, pid: 1, tail: "API Error: 529 Overloaded" });
  const notices: Array<[string, string]> = [];
  const notify = async (_s: string, retryAt: string, kind: string) => { notices.push([kind, retryAt]); };
  const runFn = makeRunFn(r, "/repo", overloaded, 5000, notify, 3);
  await runFn("S");
  const m = await readMeta(r, "S");
  expect(notices.map((n) => n[0])).toEqual(["transient"]);   // honest label — NOT "cap"
  expect(notices[0][1]).toBeTruthy();              // carries retry_at so the notice renders a real time
  expect(m?.status).toBe("capped");                // shared back-off state retained
  expect(m?.retry_at).toBeTruthy();                // retry scheduled
  expect(m?.fail_count).toBe(1);                   // counted toward the cap
  expect((await peekPending(r, "S")).count).toBe(1);   // pending preserved, re-peekable
});

test("noticeText: cap vs transient strings are honest (529 must not read as a usage cap)", () => {
  // The literal point of HIMMEL-353 — assert the operator-facing wording, not just
  // the kind token. A future edit that swapped the two arms or dropped the disclaimer
  // would otherwise ship green.
  const cap = noticeText("cap", "01:49 UTC", 3);
  expect(cap).toContain("usage cap");
  expect(cap).not.toContain("NOT a usage cap");
  expect(cap).toContain("01:49 UTC");              // renders the retry time

  const transient = noticeText("transient", "01:49 UTC", 3);
  expect(transient).toContain("NOT a usage cap");  // the honest disclaimer
  expect(transient).toContain("transiently");
  expect(transient).toContain("01:49 UTC");

  expect(noticeText("giveup", "", 3)).toContain("gave up after 3 failed runs");
  expect(noticeText("blocked", "", 3)).toContain("content-filter policy");
});

test("genuine cap (capped:true) notifies 'cap'", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "a" }));
  const cappedRun = async () => ({ code: 1, capped: true, pid: 1 });
  const notices: string[] = [];
  const notify = async (_s: string, _r: string, kind: string) => { notices.push(kind); };
  await makeRunFn(r, "/repo", cappedRun, 5000, notify, 3)("S");
  expect(notices).toEqual(["cap"]);                // genuine cap keeps the cap wording
});

test("retry cap: a message arriving DURING the final failing run prevents the park (no stranding)", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", { ...freshMeta(9), fail_count: 2 });
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "old" }));
  const failingWithArrival = async () => {
    await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "retry please (mid-run)" }));
    return { code: 1, capped: false, pid: 1 };
  };
  await makeRunFn(r, "/repo", failingWithArrival, 5000, undefined, 3)("S");   // would be the 3rd failure
  const m = await readMeta(r, "S");
  expect(m?.status).toBe("idle");              // NOT parked — new arrival un-parks
  expect(m?.fail_count ?? 0).toBe(0);
  expect((await peekPending(r, "S")).count).toBe(2);   // both messages re-runnable
});

test("retry cap: a clean run resets fail_count", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "a" }));
  let mode: "fail" | "ok" = "fail";
  const runImpl = async () => mode === "fail" ? { code: 1, capped: false, pid: 1 } : { code: 0, capped: false, pid: 1 };
  const runFn = makeRunFn(r, "/repo", runImpl, 5000, undefined, 3);
  await runFn("S"); await runFn("S");                          // 2 failures
  expect((await readMeta(r, "S"))?.fail_count).toBe(2);
  mode = "ok";
  await runFn("S");                                            // clean → reset
  expect((await readMeta(r, "S"))?.fail_count ?? 0).toBe(0);
});

test("retry cap: a NEW operator message un-parks a failed session", async () => {
  const r = root(); const ran: string[] = [];
  await ensureSession(r, "__chat__");
  await writeMeta(r, "__chat__", { ...freshMeta(7), status: "failed", fail_count: 3 });
  await handleInbound(r, { from: 1, chat_id: 7, text: "try again" }, async (s) => { ran.push(s); });
  expect(ran).toEqual(["__chat__"]);                           // re-dispatched
  const m = await readMeta(r, "__chat__");
  expect(m?.status).not.toBe("failed");
  expect(m?.fail_count ?? 0).toBe(0);
});

test("deliverAllPending skips failed sessions (no auto-retry loop)", async () => {
  const r = root();
  await ensureSession(r, "DEAD");
  await writeMeta(r, "DEAD", { ...freshMeta(1), status: "failed", fail_count: 3 });
  await appendLine(join(sessionDir(r, "DEAD"), "inbox.jsonl"), JSON.stringify({ text: "x" }));
  const ran: string[] = [];
  await deliverAllPending(r, async (s) => { ran.push(s); }, new Date(), async () => ["DEAD"]);
  expect(ran).toEqual([]);
});

test("run.log: each settle persists the run's output tail; hung run writes a placeholder — HIMMEL-262", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", freshMeta(9));
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "a" }));
  const okRun = async () => ({ code: 0, capped: false, pid: 1, tail: "hello from claude" });
  await makeRunFn(r, "/repo", okRun, 5000)("S");
  const log1 = await readFile(join(sessionDir(r, "S"), "run.log"), "utf8");
  expect(log1).toContain("hello from claude");
  expect(log1).toContain("code=0");
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "b" }));
  const hung = () => new Promise<any>(() => {});
  await makeRunFn(r, "/repo", hung, 50)("S");                  // deadline fires
  const log2 = await readFile(join(sessionDir(r, "S"), "run.log"), "utf8");
  expect(log2).toContain("no output captured");
  expect(log2).toContain("code=-1");
});

// --- backoff notice + typing signal (HIMMEL-260) ---

test("backoff notice: one notify per backoff episode; success resets; next cap notifies again", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", { chat_id: 9, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  const notices: Array<[string, string]> = [];
  const notify = async (session: string, retryAt: string) => { notices.push([session, retryAt]); };
  let mode: "cap" | "ok" = "cap";
  const runImpl = async () => mode === "cap" ? { code: 1, capped: true, pid: 1 } : { code: 0, capped: false, pid: 1 };
  const runFn = makeRunFn(r, "/repo", runImpl, 5000, notify);
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "a" }));
  await runFn("S");                      // capped → notice #1
  await runFn("S");                      // still capped, same episode → NO new notice
  expect(notices.length).toBe(1);
  expect(notices[0][0]).toBe("S");
  expect(notices[0][1]).toBeTruthy();    // carries retry_at
  mode = "ok";
  await runFn("S");                      // clean run → episode resets
  mode = "cap";
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "b" }));
  await runFn("S");                      // new episode → notice #2
  expect(notices.length).toBe(2);
});

test("backoff notice: a notify that throws does not break the settle", async () => {
  const r = root(); await ensureSession(r, "S");
  await writeMeta(r, "S", { chat_id: 9, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  const badNotify = async () => { throw new Error("telegram down"); };
  const runFn = makeRunFn(r, "/repo", async () => ({ code: 1, capped: true, pid: 1 }), 5000, badNotify);
  await appendLine(join(sessionDir(r, "S"), "inbox.jsonl"), JSON.stringify({ text: "a" }));
  await runFn("S");                      // must not throw
  expect((await readMeta(r, "S"))?.status).toBe("capped");   // settle landed despite notify failure
});

test("signalTyping: fires action with chat_id for in-flight sessions only", async () => {
  const r = root();
  await ensureSession(r, "BUSY");
  await writeMeta(r, "BUSY", { chat_id: -50, status: "running", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  await ensureSession(r, "IDLE");
  await writeMeta(r, "IDLE", { chat_id: 7, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  const typed: number[] = [];
  await signalTyping(r, (s) => s === "BUSY", async () => ["BUSY", "IDLE"], async (chat) => { typed.push(chat); });
  expect(typed).toEqual([-50]);
});

// --- concurrent per-session dispatch + watchdog (HIMMEL-246) ---

test("dispatcher: same-session overlap dropped; re-dispatch after completion runs again", async () => {
  let started = 0; let resolveRun!: () => void;
  const runFn = (_s: string) => { started++; return new Promise<void>((res) => { resolveRun = res; }); };
  const d = makeDispatcher(runFn, 4);
  await d("A");                       // starts (in flight)
  await d("A");                       // overlap → dropped
  expect(started).toBe(1);
  resolveRun();
  for (let i = 0; i < 5; i++) await Promise.resolve();   // flush finally
  expect(d.inFlightCount()).toBe(0);
  await d("A");                       // re-dispatch after completion
  expect(started).toBe(2);
  resolveRun();
});

test("dispatcher: returns without awaiting the run (poller loop is not blocked)", async () => {
  let resolveRun!: () => void;
  const runFn = (_s: string) => new Promise<void>((res) => { resolveRun = res; });
  const d = makeDispatcher(runFn, 4);
  let returned = false;
  await d("SLOW").then(() => { returned = true; });
  expect(returned).toBe(true);        // dispatch resolved while the run is still in flight
  expect(d.isInFlight("SLOW")).toBe(true);
  resolveRun();
});

test("dispatcher: concurrency cap defers extra sessions; freed slot admits them", async () => {
  const resolvers: Record<string, () => void> = {};
  const runFn = (s: string) => new Promise<void>((res) => { resolvers[s] = res; });
  const d = makeDispatcher(runFn, 2);
  await d("A"); await d("B");
  await d("C");                       // over cap → deferred (no-op this tick)
  expect(d.inFlightCount()).toBe(2);
  expect(d.isInFlight("C")).toBe(false);
  resolvers["A"]();
  for (let i = 0; i < 5; i++) await Promise.resolve();
  await d("C");                       // next tick picks it up
  expect(d.isInFlight("C")).toBe(true);
  resolvers["B"](); resolvers["C"]();
});

test("dispatcher: a rejected run clears in-flight (no permanent wedge)", async () => {
  const runFn = (_s: string) => Promise.reject(new Error("boom"));
  const d = makeDispatcher(runFn, 4);
  await d("A");
  for (let i = 0; i < 5; i++) await Promise.resolve();
  expect(d.inFlightCount()).toBe(0);
  let ran = false;
  await makeDispatcher(async () => { ran = true; }, 4)("A");
  expect(ran).toBe(true);
});

test("makeRunFn: a HUNG runImpl settles capped at the deadline instead of sticking running", async () => {
  const r = root(); await ensureSession(r, "HUNG");
  await writeMeta(r, "HUNG", { chat_id: 5, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  await appendLine(join(sessionDir(r, "HUNG"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  const hungRun = () => new Promise<{ code: number; capped: boolean; pid: number }>(() => {});   // never resolves
  await makeRunFn(r, "/repo", hungRun, 50)("HUNG");        // 50ms deadline
  const m = await readMeta(r, "HUNG");
  expect(m?.status).toBe("capped");                        // settled, not stuck running
  expect(m?.retry_at).toBeTruthy();
  expect((await peekPending(r, "HUNG")).count).toBe(1);    // message preserved for retry
});

test("makeRunFn: a THROWING runImpl settles capped (settle is not skipped on reject)", async () => {
  const r = root(); await ensureSession(r, "THROW");
  await writeMeta(r, "THROW", { chat_id: 5, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  await appendLine(join(sessionDir(r, "THROW"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  const throwingRun = () => Promise.reject(new Error("spawn failed"));
  await makeRunFn(r, "/repo", throwingRun, 5000)("THROW");
  const m = await readMeta(r, "THROW");
  expect(m?.status).toBe("capped");
  expect((await peekPending(r, "THROW")).count).toBe(1);
});

test("sweepStuckRunning: resets a running session NOT in flight; leaves in-flight ones alone", async () => {
  const r = root();
  await ensureSession(r, "STUCK");
  await writeMeta(r, "STUCK", { chat_id: 1, status: "running", last_run_pid: 12345, last_run_at: null, task_name: null, retry_at: null });
  await ensureSession(r, "LIVE");
  await writeMeta(r, "LIVE", { chat_id: 2, status: "running", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  const sessions = async () => ["STUCK", "LIVE"];
  await sweepStuckRunning(r, (s) => s === "LIVE", sessions);
  expect((await readMeta(r, "STUCK"))?.status).toBe("idle");      // wedge healed in-loop
  expect((await readMeta(r, "LIVE"))?.status).toBe("running");    // genuinely in flight → untouched
});

test("ingest appends inbound then advances offset; dedups by update_id", async () => {
  const r = root();
  const upd = { update_id: 10, message: { chat:{id:1}, from:{id:1}, text:"hi" } };
  await ingestUpdates(r, [upd], allowAll);
  await ingestUpdates(r, [upd], allowAll);           // same update_id again → already confirmed, skip
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].update_id).toBe(10);
  expect(lines[0].chat_id).toBe(1);
  expect(await loadOffset(r)).toBe(11);              // offset = max update_id + 1
});

test("gate predicate rejects disallowed senders (not appended)", async () => {
  const r = root();
  await ingestUpdates(r, [{ update_id: 1, message: { chat:{id:9}, from:{id:9}, text:"x" } }], (id)=>id===1);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(await loadOffset(r)).toBe(2);               // offset still advances past a rejected update (it's confirmed/seen)
});

// --- group + channel ingest (HIMMEL-238) ---

test("ingest passes chat_id to the gate so an allowed group accepts a non-allowlisted sender", async () => {
  const r = root();
  const allow = (fromId: number, chatId: number) => fromId === 1 || chatId === -50;
  await ingestUpdates(r, [
    { update_id: 1, message: { chat:{id:-50}, from:{id:9}, text:"from member" } },   // group allowed
    { update_id: 2, message: { chat:{id:-60}, from:{id:9}, text:"other group" } },   // neither → reject
  ], allow);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].chat_id).toBe(-50);
  expect(lines[0].from).toBe(9);
  expect(await loadOffset(r)).toBe(3);
});

test("makeAllow: the REAL composed gate — DM leg scoped to positive chat_ids", async () => {
  const access = { allowFrom: ["1"], groups: { "-50": {} } };
  const allow = makeAllow(access);
  expect(allow(1, 1)).toBe(true);       // allowFrom sender DM (chat_id == sender id)
  expect(allow(9, -50)).toBe(true);     // non-allowlisted member of an allowed group
  expect(allow(9, 7)).toBe(false);      // unknown sender DM
  expect(allow(9, -60)).toBe(false);    // unknown sender, non-allowed group
  expect(allow(1, -60)).toBe(false);    // allowFrom sender must NOT open a non-allowed group (reply would leak there)
  expect(allow(1, -50)).toBe(true);     // allowFrom sender in an allowed group
});

test("ingest drops text-less updates (service messages, stickers) — no empty bounded runs", async () => {
  const r = root();
  await ingestUpdates(r, [
    { update_id: 1, message: { chat:{id:-50}, from:{id:9}, new_chat_members:[{}] } },   // join service msg
    { update_id: 2, message: { chat:{id:-50}, from:{id:9}, text:"   " } },              // whitespace only
    { update_id: 3, message: { chat:{id:-50}, from:{id:9}, text:"real" } },
  ], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("real");
  expect(await loadOffset(r)).toBe(4);
});

test("ingest accepts a channel_post (no from) when the chat is allowed; from falls back to sender_chat", async () => {
  const r = root();
  const allow = (_fromId: number, chatId: number) => chatId === -1001234;
  await ingestUpdates(r, [
    { update_id: 5, channel_post: { chat:{id:-1001234}, sender_chat:{id:-1001234}, text:"channel msg" } },
    { update_id: 6, channel_post: { chat:{id:-1009999}, text:"other channel" } },    // not allowed → reject
  ], allow);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].chat_id).toBe(-1001234);
  expect(lines[0].from).toBe(-1001234);              // sender_chat fallback
  expect(lines[0].text).toBe("channel msg");
  expect(await loadOffset(r)).toBe(7);               // offset advances past both (confirmed)
});

test("dispatch creates session, enqueues, sets chat_id; running session only enqueues", async () => {
  const r = root(); const ran: string[] = [];
  const fakeRun = async (s:string)=>{ ran.push(s); };
  await handleInbound(r, { from:1, chat_id:7, text:"work on HIMMEL-5" }, fakeRun);
  const m = await readMeta(r, "HIMMEL-5"); expect(m?.chat_id).toBe(7);
  expect(ran).toEqual(["HIMMEL-5"]);
  await writeMeta(r, "HIMMEL-5", { ...(m as any), status:"running", last_run_pid: 999999 });
  await handleInbound(r, { from:1, chat_id:7, text:"HIMMEL-5: more" }, fakeRun);
  expect(ran).toEqual(["HIMMEL-5"]);   // no 2nd RUN while in-flight
});

test("chat routes to __chat__ session", async () => {
  const r = root(); const ran: string[] = [];
  await handleInbound(r, { from:1, chat_id:7, text:"hello" }, async (s:string)=>{ran.push(s);});
  expect(ran).toEqual(["__chat__"]);
});

// --- per-group session routing (HIMMEL-238) ---
// Non-DM chat (negative chat_id) gets its own session keyed by chat_id so
// meta.chat_id = the group/channel and replies route back there, not the DM.
// Key uses "_" not ":" — the session id is an NTFS directory name.

test("group chat routes to its own group_<chat_id> session with meta.chat_id = the group", async () => {
  const r = root(); const ran: string[] = [];
  await handleInbound(r, { from:1, chat_id:-1009999999, text:"hello group" }, async (s:string)=>{ran.push(s);});
  expect(ran).toEqual(["group_-1009999999"]);
  const m = await readMeta(r, "group_-1009999999");
  expect(m?.chat_id).toBe(-1009999999);
});

test("ticket session chat_id is pinned by its creator; a group followup does not re-route it", async () => {
  // first-writer-wins: a ticket dispatched from the DM keeps replying to the
  // DM even when a group member sends a followup to the same ticket
  const r = root();
  const fakeRun = async (_s:string)=>{};
  await handleInbound(r, { from:1, chat_id:7, text:"work on HIMMEL-5" }, fakeRun);
  await handleInbound(r, { from:9, chat_id:-50, text:"HIMMEL-5: from the group" }, fakeRun);
  expect((await readMeta(r, "HIMMEL-5"))?.chat_id).toBe(7);
});

test("group and DM chat sessions stay separate; group reply flushes to the group chat_id", async () => {
  const r = root();
  const fakeRun = async (_s:string)=>{};
  await handleInbound(r, { from:1, chat_id:7, text:"dm" }, fakeRun);
  await handleInbound(r, { from:1, chat_id:-50, text:"group" }, fakeRun);
  expect((await readMeta(r, "__chat__"))?.chat_id).toBe(7);          // DM unchanged
  expect((await readMeta(r, "group_-50"))?.chat_id).toBe(-50);
  await appendLine(join(sessionDir(r,"group_-50"),"outbox.jsonl"), JSON.stringify({ text:"reply" }));
  const sent: any[] = [];
  await flushOutboxes(r, async (chat:number,text:string)=>{ sent.push([chat,text]); });
  expect(sent).toContainEqual([-50,"reply"]);                        // reply lands in the GROUP
});

test("clean run settles idle; capped run sets retry_at", async () => {
  const r = root(); await ensureSession(r,"S");
  await writeMeta(r,"S",{chat_id:1,status:"idle",last_run_pid:null,last_run_at:null,task_name:null,retry_at:null});
  await runAndSettle(r, "S", async ()=>({code:0,capped:false,pid:1}), ()=>"2026-05-30T03:00:00Z");
  expect((await readMeta(r,"S"))?.status).toBe("idle");
  await runAndSettle(r, "S", async ()=>({code:1,capped:true,pid:2}), ()=>"2026-05-30T03:00:00Z");
  expect((await readMeta(r,"S"))?.status).toBe("capped");
  expect((await readMeta(r,"S"))?.retry_at).toBe("2026-05-30T03:00:00Z");   // retryAt defaults to now
});

test("runAndSettle: a blocked run parks failed directly (no transient capped, no retry_at)", async () => {
  const r = root(); await ensureSession(r,"S");
  await writeMeta(r,"S",{chat_id:1,status:"capped",last_run_pid:9,last_run_at:null,task_name:null,retry_at:"2020-01-01T00:00:00Z",fail_count:2});
  await runAndSettle(r, "S", async ()=>({code:1,capped:false,blocked:true,pid:3}), ()=>"2026-05-30T03:00:00Z");
  const m = await readMeta(r,"S");
  expect(m?.status).toBe("failed");          // settled straight to failed, not capped
  expect(m?.retry_at).toBe(null);            // no backoff retry scheduled
  expect(m?.fail_count ?? null).toBe(null);  // fail-count cleared (deterministic, no climb)
});

test("flush sends new outbox lines once, to meta.chat_id", async () => {
  const r = root(); await ensureSession(r,"S");
  await writeMeta(r,"S",{chat_id:55,status:"idle",last_run_pid:null,last_run_at:null,task_name:null,retry_at:null});
  await appendLine(join(sessionDir(r,"S"),"outbox.jsonl"), JSON.stringify({ text:"done" }));
  const sent: any[] = [];
  await flushOutboxes(r, async (chat:number,text:string)=>{ sent.push([chat,text]); });
  expect(sent).toEqual([[55,"done"]]);
  await flushOutboxes(r, async (chat:number,text:string)=>{ sent.push([chat,text]); });
  expect(sent.length).toBe(1);   // nothing new on re-flush (cursor committed)
});

test("flushOutboxes reclaims a fully-sent outbox (file+cursor reset to 0); fresh reply still sends — HIMMEL-221", async () => {
  const r = root(); await ensureSession(r,"S");
  await writeMeta(r,"S",{chat_id:55,status:"idle",last_run_pid:null,last_run_at:null,task_name:null,retry_at:null});
  const ob = join(sessionDir(r,"S"),"outbox.jsonl");
  await appendLine(ob, JSON.stringify({ text:"a" }));
  await flushOutboxes(r, async ()=>{});                    // sends "a" → cursor at EOF
  await flushOutboxes(r, async ()=>{});                    // nothing new → reclaim
  expect(await readFile(ob,"utf8")).toBe("");
  expect(await readFile(ob+".cursor","utf8")).toBe("0");
  const sent: string[] = [];                               // a reply after reclaim reads from offset 0 (no orphaned bytes)
  await appendLine(ob, JSON.stringify({ text:"b" }));
  await flushOutboxes(r, async (_c:number,t:string)=>{ sent.push(t); });
  expect(sent).toEqual(["b"]);
});

test("isRetryDue: capped session with past retry_at is due; future is not", () => {
  const base = { chat_id:1, status:"capped" as const, last_run_pid:null, last_run_at:null, task_name:null };
  expect(isRetryDue({ ...base, retry_at:"2020-01-01T00:00:00Z" }, new Date("2026-01-01T00:00:00Z"))).toBe(true);
  expect(isRetryDue({ ...base, retry_at:"2099-01-01T00:00:00Z" }, new Date("2026-01-01T00:00:00Z"))).toBe(false);
  expect(isRetryDue({ ...base, status:"idle", retry_at:null }, new Date())).toBe(false);
});

test("peekPending writes pending slice without consuming until commit", async () => {
  const r = root(); await ensureSession(r, "S");
  const inbox = join(sessionDir(r, "S"), "inbox.jsonl");
  await appendLine(inbox, JSON.stringify({ text: "one" }));
  await appendLine(inbox, JSON.stringify({ text: "two" }));
  const p1 = await peekPending(r, "S");
  expect(p1.count).toBe(2);
  const pending = await readFile(join(sessionDir(r, "S"), "inbox.pending.jsonl"), "utf8");
  expect(pending).toBe(JSON.stringify({ text: "one" }) + "\n" + JSON.stringify({ text: "two" }) + "\n");
  await commitPending(r, "S", p1.nextPos);
  expect((await peekPending(r, "S")).count).toBe(0);   // committed → nothing new
  await appendLine(inbox, JSON.stringify({ text: "three" }));
  expect((await peekPending(r, "S")).count).toBe(1);
});

test("peekPending does not consume until commit (capped run can re-peek)", async () => {
  const r = root(); await ensureSession(r, "S");
  const inbox = join(sessionDir(r, "S"), "inbox.jsonl");
  await appendLine(inbox, JSON.stringify({ text: "a" }));
  await appendLine(inbox, JSON.stringify({ text: "b" }));
  const p1 = await peekPending(r, "S");
  expect(p1.count).toBe(2);                       // pending.jsonl written with a,b
  const p2 = await peekPending(r, "S");
  expect(p2.count).toBe(2);                       // NOT consumed yet — capped-run safety
  await commitPending(r, "S", p1.nextPos);
  const p3 = await peekPending(r, "S");
  expect(p3.count).toBe(0);                       // committed → consumed
});

// --- cold-spawn runFn (HIMMEL-226: reverts the warm stdin-pipe delivery) ---

// DoD: a delivered inbound produces an outbox reply via the cold-spawn path; the cold
// prompt carries context.md (prior-turn continuity) + points at the peeked slice; the
// consumed cursor commits only AFTER a clean run. runImpl is injected so no real claude
// spawns — it simulates the child reading the pending slice and replying to the outbox.
test("cold runFn: pending inbound → cold run replies to outbox, passes continuity context, commits cursor", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-7");
  await writeMeta(r, "HIMMEL-7", { chat_id:9, status:"idle", last_run_pid:null, last_run_at:null, task_name:null, retry_at:null });
  const sd = sessionDir(r, "HIMMEL-7");
  await appendLine(join(sd, "inbox.jsonl"), JSON.stringify({ text:"do A" }));
  const prompts: string[] = [];
  const fakeRun = async (prompt: string, _cwd: string) => {
    prompts.push(prompt);
    const pending = await readFile(join(sd, "inbox.pending.jsonl"), "utf8");
    const n = pending.split("\n").filter((l)=>l.trim()).length;
    await appendLine(join(sd, "outbox.jsonl"), JSON.stringify({ text:`handled ${n}` }));
    return { code:0, capped:false, pid:1 };
  };
  await makeRunFn(r, "/repo", fakeRun)("HIMMEL-7");
  expect(await readFile(join(sd, "outbox.jsonl"), "utf8")).toContain("handled 1");   // reply landed
  expect(prompts[0]).toContain(join(sd, "context.md"));            // continuity context passed
  expect(prompts[0]).toContain(join(sd, "inbox.pending.jsonl"));   // reads the peeked slice, not raw inbox
  expect((await peekPending(r, "HIMMEL-7")).count).toBe(0);        // cursor committed after the clean run
});

test("cold runFn: a multi-line pending slice is consumed by ONE cold run (whole slice, not per-line)", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-12");
  await writeMeta(r, "HIMMEL-12", { chat_id:9, status:"idle", last_run_pid:null, last_run_at:null, task_name:null, retry_at:null });
  const sd = sessionDir(r, "HIMMEL-12");
  await appendLine(join(sd,"inbox.jsonl"), JSON.stringify({ text:"one" }));
  await appendLine(join(sd,"inbox.jsonl"), JSON.stringify({ text:"two" }));
  let calls = 0; let sawLines = 0;
  const fakeRun = async () => {
    calls++;
    const pending = await readFile(join(sd,"inbox.pending.jsonl"), "utf8");
    sawLines = pending.split("\n").filter((l)=>l.trim()).length;
    return { code:0, capped:false, pid:1 };
  };
  await makeRunFn(r, "/repo", fakeRun)("HIMMEL-12");
  expect(calls).toBe(1);          // one cold spawn for the whole slice
  expect(sawLines).toBe(2);       // both messages in the peeked slice
  expect((await peekPending(r, "HIMMEL-12")).count).toBe(0);
});

test("cold runFn: a capped run does NOT commit the cursor and settles meta capped + retry_at", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-9");
  await writeMeta(r, "HIMMEL-9", { chat_id:5, status:"idle", last_run_pid:null, last_run_at:null, task_name:null, retry_at:null });
  await appendLine(join(sessionDir(r,"HIMMEL-9"), "inbox.jsonl"), JSON.stringify({ text:"hi" }));
  const cappedRun = async () => ({ code:1, capped:true, pid:7 });
  await makeRunFn(r, "/repo", cappedRun)("HIMMEL-9");
  const m = await readMeta(r, "HIMMEL-9");
  expect(m?.status).toBe("capped");
  expect(m?.retry_at).toBeTruthy();                            // backoff scheduled (now + RETRY_MS)
  expect((await peekPending(r, "HIMMEL-9")).count).toBe(1);    // cursor NOT committed → message preserved
});

test("cold runFn: a FAILED run (non-zero exit, no cap) does NOT commit and backs off — no message loss", async () => {
  // A crash / 30-min timeout (code:-1) / non-sentinel error must be treated like a cap:
  // the message stays uncommitted and the session backs off, instead of committing the
  // cursor on a run that produced no reply (silent drop).
  const r = root(); await ensureSession(r, "HIMMEL-13");
  await writeMeta(r, "HIMMEL-13", { chat_id:5, status:"idle", last_run_pid:null, last_run_at:null, task_name:null, retry_at:null });
  await appendLine(join(sessionDir(r,"HIMMEL-13"), "inbox.jsonl"), JSON.stringify({ text:"hi" }));
  const failedRun = async () => ({ code:1, capped:false, pid:7 });   // exited non-zero, not a cap
  await makeRunFn(r, "/repo", failedRun)("HIMMEL-13");
  const m = await readMeta(r, "HIMMEL-13");
  expect(m?.status).toBe("capped");                             // backed off (shared back-off state)
  expect(m?.retry_at).toBeTruthy();
  expect((await peekPending(r, "HIMMEL-13")).count).toBe(1);    // cursor NOT committed → message preserved
});

test("cold runFn: a clean run after a cap settles back to idle + clears retry_at", async () => {
  // Regression guard: a capped session that later runs clean must reset, else isRetryDue
  // stays true forever and handleInbound's idle/done guard skips immediate dispatch.
  const r = root(); await ensureSession(r, "HIMMEL-11");
  await writeMeta(r, "HIMMEL-11", { chat_id:5, status:"capped", last_run_pid:9, last_run_at:null, task_name:null, retry_at:"2020-01-01T00:00:00Z" });
  await appendLine(join(sessionDir(r,"HIMMEL-11"), "inbox.jsonl"), JSON.stringify({ text:"hi" }));
  const cleanRun = async () => ({ code:0, capped:false, pid:8 });
  await makeRunFn(r, "/repo", cleanRun)("HIMMEL-11");
  const m = await readMeta(r, "HIMMEL-11");
  expect(m?.status).toBe("idle");                              // un-wedged (runAndSettle clean branch)
  expect(m?.retry_at).toBe(null);
  expect((await peekPending(r, "HIMMEL-11")).count).toBe(0);   // committed
});

test("cold runFn: empty tick reclaims a fully-consumed inbox; a fresh message still delivers — HIMMEL-221", async () => {
  const r = root(); await ensureSession(r, "HIMMEL-8");
  await writeMeta(r, "HIMMEL-8", { chat_id:9, status:"idle", last_run_pid:null, last_run_at:null, task_name:null, retry_at:null });
  const inbox = join(sessionDir(r,"HIMMEL-8"), "inbox.jsonl");
  await appendLine(inbox, JSON.stringify({ text:"x" }));
  let calls = 0;
  const fakeRun = async () => { calls++; return { code:0, capped:false, pid:1 }; };
  await makeRunFn(r, "/repo", fakeRun)("HIMMEL-8");   // consumes "x", clean → recurse → count 0 → reclaim
  expect(calls).toBe(1);
  expect(await readFile(inbox, "utf8")).toBe("");
  expect(await readFile(inbox + ".consumed", "utf8")).toBe("0");
  await appendLine(inbox, JSON.stringify({ text:"y" }));        // post-reclaim message reads from offset 0
  await makeRunFn(r, "/repo", fakeRun)("HIMMEL-8");
  expect(calls).toBe(2);
  expect((await peekPending(r, "HIMMEL-8")).count).toBe(0);
});

test("reconcile clears a dead last_run_pid so the session isn't stuck busy", async () => {
  const r = root(); await ensureSession(r,"S");
  await writeMeta(r,"S",{chat_id:1,status:"running",last_run_pid:2147480000,last_run_at:null,task_name:null,retry_at:null});
  await reconcile(r, (_pid)=>false);
  expect((await readMeta(r,"S"))?.status).not.toBe("running");
});

test("deliverAllPending: runs idle + due-capped sessions; skips not-due-capped", async () => {
  const r = root();
  const baseMeta = { last_run_pid: null, last_run_at: null, task_name: null };

  // idle session with a pending inbox line
  await ensureSession(r, "IDLE");
  await writeMeta(r, "IDLE", { ...baseMeta, chat_id: 1, status: "idle", retry_at: null });
  await appendLine(join(sessionDir(r, "IDLE"), "inbox.jsonl"), JSON.stringify({ text: "do it" }));

  // capped with FUTURE retry_at (not due) with a pending line
  await ensureSession(r, "CAPPED-FUTURE");
  await writeMeta(r, "CAPPED-FUTURE", { ...baseMeta, chat_id: 2, status: "capped", retry_at: "2099-01-01T00:00:00Z" });
  await appendLine(join(sessionDir(r, "CAPPED-FUTURE"), "inbox.jsonl"), JSON.stringify({ text: "skip me" }));

  // capped with PAST retry_at (due) with a pending line
  await ensureSession(r, "CAPPED-DUE");
  await writeMeta(r, "CAPPED-DUE", { ...baseMeta, chat_id: 3, status: "capped", retry_at: "2020-01-01T00:00:00Z" });
  await appendLine(join(sessionDir(r, "CAPPED-DUE"), "inbox.jsonl"), JSON.stringify({ text: "retry me" }));

  const ran: string[] = [];
  const mockRunFn = async (s: string) => { ran.push(s); };
  const now = new Date("2026-01-01T00:00:00Z");
  await deliverAllPending(r, mockRunFn, now, () => sessionsList(r));

  expect(ran).toContain("IDLE");
  expect(ran).toContain("CAPPED-DUE");
  expect(ran).not.toContain("CAPPED-FUTURE");
});

// helper: list session dirs (mirrors sessionsList in poller.ts)
async function sessionsList(root: string): Promise<string[]> {
  const { readdir } = await import("node:fs/promises");
  const { join } = await import("node:path");
  try { return await readdir(join(root, "sessions")); } catch { return []; }
}

test("guarded: overlapping calls are dropped; re-entry works after in-flight resolves", async () => {
  let counter = 0;
  let resolve!: () => void;
  // Slow task: waits on a manually-controlled promise, then increments counter.
  const task = () => new Promise<void>((res) => { resolve = res; }).then(() => { counter++; });
  const fn = guarded(task);

  fn();                    // starts the first invocation (in-flight)
  fn();                    // overlaps — must be a no-op (dropped)
  expect(counter).toBe(0); // task not done yet

  resolve();               // complete the first invocation
  // Flush enough microtask ticks: promise .then (counter++) → .catch → .finally (clears flag).
  for (let i = 0; i < 5; i++) await Promise.resolve();

  expect(counter).toBe(1); // exactly one run completed

  // Re-entry: in-flight flag is cleared, so calling again should start a new run.
  fn();                    // starts second invocation
  resolve();               // resolve it immediately
  for (let i = 0; i < 5; i++) await Promise.resolve();

  expect(counter).toBe(2); // second run completed
});

// --- photo+caption forwarding in poller mode (HIMMEL-250) ---

test("ingest photo+caption: caption becomes text, image_path recorded, largest size fetched", async () => {
  const r = root();
  const fetched: string[] = [];
  const fetchImage = async (file_id: string, _uid: number) => { fetched.push(file_id); return "/tmp/att/42.jpg"; };
  const upd = { update_id: 42, message: { chat:{id:1}, from:{id:1}, caption: "add milk to shopping list",
    photo: [{ file_id: "small" }, { file_id: "big" }] } };
  await ingestUpdates(r, [upd], allowAll, fetchImage);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("add milk to shopping list");
  expect(lines[0].image_path).toBe("/tmp/att/42.jpg");
  expect(fetched).toEqual(["big"]);                  // largest size = last array element
});

test("ingest caption-less photo: text falls back to [photo] (run prompt stays non-empty)", async () => {
  const r = root();
  const upd = { update_id: 7, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "f" }] } };
  await ingestUpdates(r, [upd], allowAll, async () => "/tmp/att/7.jpg");
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].text).toBe("[photo]");
  expect(lines[0].image_path).toBe("/tmp/att/7.jpg");
});

test("ingest photo when download fails: caption still forwarded, no image_path", async () => {
  const r = root();
  const upd = { update_id: 8, message: { chat:{id:1}, from:{id:1}, caption: "whiteboard", photo: [{ file_id: "f" }] } };
  await ingestUpdates(r, [upd], allowAll, async () => null);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("whiteboard");
  expect(lines[0].image_path).toBeUndefined();
});

test("ingest photo from a gated-out sender: never downloaded, never appended", async () => {
  const r = root();
  let called = 0;
  const upd = { update_id: 9, message: { chat:{id:9}, from:{id:9}, photo: [{ file_id: "f" }] } };
  await ingestUpdates(r, [upd], (id)=>id===1, async () => { called++; return "/x.jpg"; });
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(called).toBe(0);                            // allow gate runs BEFORE the download
  expect(await loadOffset(r)).toBe(10);              // still confirmed/seen
});

test("ingest with no fetchImage wired: photo forwarded text-only (no crash)", async () => {
  const r = root();
  const upd = { update_id: 11, message: { chat:{id:1}, from:{id:1}, caption: "c", photo: [{ file_id: "f" }] } };
  await ingestUpdates(r, [upd], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].text).toBe("c");
  expect(lines[0].image_path).toBeUndefined();
});

test("ingest still drops stickers/service messages (no text, no photo)", async () => {
  const r = root();
  const upd = { update_id: 12, message: { chat:{id:1}, from:{id:1}, sticker: { file_id: "s" } } };
  await ingestUpdates(r, [upd], allowAll, async () => "/never.jpg");
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
});

test("handleInbound forwards image_path into the session inbox line", async () => {
  const r = root();
  await handleInbound(r, { from: 1, chat_id: 1, text: "look at this", ts: 5, image_path: "/tmp/att/42.jpg" }, async () => {});
  const lines = await readNewLines(join(sessionDir(r, "__chat__"), "inbox.jsonl"), join(sessionDir(r, "__chat__"), "inbox.jsonl.cursor.test"));
  expect(lines.length).toBe(1);
  expect(lines[0].image_path).toBe("/tmp/att/42.jpg");
  expect(lines[0].text).toBe("look at this");
});

// --- document/PDF forwarding in poller mode (HIMMEL-321) ---

test("ingest document+caption: caption becomes text, document_path + document_name recorded", async () => {
  const r = root();
  const fetched: string[] = [];
  const fetchDoc = async (file_id: string, _uid: number, name: string) => { fetched.push(file_id + ":" + name); return "/tmp/att/42.pdf"; };
  const upd = { update_id: 42, message: { chat:{id:1}, from:{id:1}, caption: "blood test results",
    document: { file_id: "doc1", file_name: "results.pdf", mime_type: "application/pdf" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, undefined, fetchDoc);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("blood test results");
  expect(lines[0].document_path).toBe("/tmp/att/42.pdf");
  expect(lines[0].document_name).toBe("results.pdf");
  expect(fetched).toEqual(["doc1:results.pdf"]);
});

test("ingest caption-less document: text falls back to [document: name]", async () => {
  const r = root();
  const upd = { update_id: 7, message: { chat:{id:1}, from:{id:1}, document: { file_id: "f", file_name: "scan.pdf" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, undefined, async () => "/tmp/att/7.pdf");
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].text).toBe("[document: scan.pdf]");
  expect(lines[0].document_path).toBe("/tmp/att/7.pdf");
  expect(lines[0].document_name).toBe("scan.pdf");
});

test("ingest document when download fails: caption still forwarded, no document_path", async () => {
  const r = root();
  const upd = { update_id: 8, message: { chat:{id:1}, from:{id:1}, caption: "referral", document: { file_id: "f", file_name: "r.pdf" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, undefined, async () => null);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("referral");
  expect(lines[0].document_path).toBeUndefined();
});

test("ingest document from a gated-out sender: never downloaded, never appended", async () => {
  const r = root();
  let called = 0;
  const upd = { update_id: 9, message: { chat:{id:9}, from:{id:9}, document: { file_id: "f", file_name: "x.pdf" } } };
  await ingestUpdates(r, [upd], (id)=>id===1, undefined, undefined, async () => { called++; return "/x.pdf"; });
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(called).toBe(0);
  expect(await loadOffset(r)).toBe(10);
});

test("ingest with no fetchDoc wired: document forwarded text-only (no crash)", async () => {
  const r = root();
  const upd = { update_id: 11, message: { chat:{id:1}, from:{id:1}, caption: "c", document: { file_id: "f", file_name: "d.pdf" } } };
  await ingestUpdates(r, [upd], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].text).toBe("c");
  expect(lines[0].document_path).toBeUndefined();
});

test("handleInbound forwards document_path + document_name into the session inbox line", async () => {
  const r = root();
  await handleInbound(r, { from: 1, chat_id: -50, text: "file this", ts: 5, document_path: "/tmp/att/42.pdf", document_name: "results.pdf" }, async () => {});
  const lines = await readNewLines(join(sessionDir(r, "group_-50"), "inbox.jsonl"), join(sessionDir(r, "group_-50"), "inbox.jsonl.cursor.test"));
  expect(lines.length).toBe(1);
  expect(lines[0].document_path).toBe("/tmp/att/42.pdf");
  expect(lines[0].document_name).toBe("results.pdf");
  expect(lines[0].text).toBe("file this");
});

test("ingest document whose download fails notifies the operator (never a silent drop, HIMMEL-321)", async () => {
  const r = root();
  const notices: Array<[number, string]> = [];
  const notifyDocFail = async (chatId: number, name: string) => { notices.push([chatId, name]); };
  const upd = { update_id: 13, message: { chat:{id:-50}, from:{id:1}, document: { file_id: "f", file_name: "scan.pdf" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, undefined, async () => null, notifyDocFail);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].document_path).toBeUndefined();    // degraded to caption-only
  expect(notices).toEqual([[-50, "scan.pdf"]]);      // but the operator was told
});

test("ingest a successful document download does NOT notify failure", async () => {
  const r = root();
  let notified = 0;
  const upd = { update_id: 14, message: { chat:{id:-50}, from:{id:1}, document: { file_id: "f", file_name: "ok.pdf" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, undefined, async () => "/tmp/att/14.pdf", async () => { notified++; });
  expect(notified).toBe(0);
});

test("ingest a mixed batch (photo + document) lands both with their own attachment paths (HIMMEL-321/266)", async () => {
  const r = root();
  const photoUpd = { update_id: 20, message: { chat:{id:1}, from:{id:1}, caption: "pic", photo: [{ file_id: "p" }] } };
  const docUpd = { update_id: 21, message: { chat:{id:1}, from:{id:1}, caption: "doc", document: { file_id: "d", file_name: "x.pdf" } } };
  await ingestUpdates(r, [photoUpd, docUpd], allowAll, async () => "/tmp/att/20.jpg", undefined, async () => "/tmp/att/21.pdf");
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  const byText = Object.fromEntries(lines.map((l: any) => [l.text, l]));
  expect(byText["pic"].image_path).toBe("/tmp/att/20.jpg");
  expect(byText["pic"].document_path).toBeUndefined();
  expect(byText["doc"].document_path).toBe("/tmp/att/21.pdf");
  expect(byText["doc"].image_path).toBeUndefined();
  expect(await loadOffset(r)).toBe(22);              // offset advanced past both
});

test("makeRunFn resolves the chat's vault and threads it into the run prompt (HIMMEL-321 wiring seam)", async () => {
  const r = root(); await ensureSession(r, "group_-50");
  await writeMeta(r, "group_-50", freshMeta(-50));
  await appendLine(join(sessionDir(r, "group_-50"), "inbox.jsonl"), JSON.stringify({ text: "file this", document_path: "/att/x.pdf", document_name: "x.pdf" }));
  let captured = "";
  const runImpl = async (prompt: string) => { captured = prompt; return { code: 0, capped: false, pid: 1 }; };
  const vaultFor = (chatId: number) => chatId === -50 ? "/vaults/medic" : null;
  await makeRunFn(r, "/repo", runImpl, 5000, undefined, 3, vaultFor)("group_-50");
  expect(captured).toContain("/vaults/medic");
  expect(captured).toContain("document_path");
});

test("makeRunFn with no vault for the chat threads no file-into-vault clause (HIMMEL-321)", async () => {
  const r = root(); await ensureSession(r, "group_-99");
  await writeMeta(r, "group_-99", freshMeta(-99));
  await appendLine(join(sessionDir(r, "group_-99"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  let captured = "";
  const runImpl = async (prompt: string) => { captured = prompt; return { code: 0, capped: false, pid: 1 }; };
  const vaultFor = (_chatId: number) => null;
  await makeRunFn(r, "/repo", runImpl, 5000, undefined, 3, vaultFor)("group_-99");
  expect(captured).not.toContain("file the document's content into the Obsidian vault");
});

test("safeExt: keeps plain extensions, rejects Telegram-controlled traversal/query shapes", async () => {
  const { safeExt } = await import("./poller");
  expect(safeExt("photos/file_1.jpg")).toBe(".jpg");
  expect(safeExt("photos/file_1.PNG")).toBe(".PNG");
  expect(safeExt("photos/file_1")).toBe(".jpg");                       // no extension → fallback
  expect(safeExt("x./../../tmp/evil")).toBe(".jpg");                   // subpath in ext → fallback
  expect(safeExt("photos/file.jpg?redirect=evil.php?x")).toBe(".jpg"); // query chars (NTFS-invalid) → fallback
  expect(safeExt("voice/file_5.oga", ".oga")).toBe(".oga");            // voice keeps its real extension
  expect(safeExt("voice/file_5", ".oga")).toBe(".oga");                // voice fallback is caller-supplied
});

// --- voice-note transcription in poller mode (HIMMEL-251) ---

test("ingest voice: transcript becomes text with [voice transcript] prefix, file_id + chat_id passed through", async () => {
  const r = root();
  const calls: Array<[string, number, number]> = [];
  const fetchVoice = async (file_id: string, uid: number, chat_id: number) => { calls.push([file_id, uid, chat_id]); return "remind me to renew my passport"; };
  const upd = { update_id: 20, message: { chat:{id:1}, from:{id:1}, voice: { file_id: "v1", duration: 3 } } };
  await ingestUpdates(r, [upd], allowAll, undefined, fetchVoice);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("[voice transcript] remind me to renew my passport");
  expect(calls).toEqual([["v1", 20, 1]]);
});

test("ingest audio file (m.audio) is accepted like voice, caption prepended", async () => {
  const r = root();
  const upd = { update_id: 21, message: { chat:{id:1}, from:{id:1}, caption: "meeting recording", audio: { file_id: "a1" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, async () => "agenda item one");
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].text).toBe("meeting recording\n[voice transcript] agenda item one");
});

test("ingest voice when transcription fails: not forwarded (closure owns the error reply), offset still advances", async () => {
  const r = root();
  const upd = { update_id: 22, message: { chat:{id:1}, from:{id:1}, voice: { file_id: "v" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, async () => null);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(await loadOffset(r)).toBe(23);              // confirmed — no retry loop on a bad voice note
});

test("ingest voice when fetchVoice throws: degrades to a skip, no crash", async () => {
  const r = root();
  const upd = { update_id: 23, message: { chat:{id:1}, from:{id:1}, voice: { file_id: "v" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, async () => { throw new Error("whisper exploded"); });
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(await loadOffset(r)).toBe(24);
});

test("ingest voice from a gated-out sender: never fetched/transcribed, never appended", async () => {
  const r = root();
  let called = 0;
  const upd = { update_id: 24, message: { chat:{id:9}, from:{id:9}, voice: { file_id: "v" } } };
  await ingestUpdates(r, [upd], (id)=>id===1, undefined, async () => { called++; return "secret"; });
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(called).toBe(0);
  expect(await loadOffset(r)).toBe(25);
});

test("ingest voice with no fetchVoice wired: dropped like other unsupported media (no crash)", async () => {
  const r = root();
  const upd = { update_id: 25, message: { chat:{id:1}, from:{id:1}, voice: { file_id: "v" } } };
  await ingestUpdates(r, [upd], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
});

// makeFetchVoice — the production closure that OWNS the HIMMEL-251 acceptance
// ("explicit error reply on every failure, never a silent drop, never throws")

const voiceDeps = (over: Partial<Parameters<typeof makeFetchVoice>[0]> = {}) => {
  const failed: number[] = [];
  const deps = {
    getFile: async (_id: string) => "voice/file_5.oga",
    download: async (_fp: string, _dest: string) => true,
    transcribe: async (_p: string) => "hello",
    sendFail: async (chat_id: number) => { failed.push(chat_id); },
    attachmentsDir: root(),
    ...over,
  };
  return { deps, failed };
};

test("makeFetchVoice success: returns transcript, dest keyed by update_id + real extension, no error reply", async () => {
  const dests: string[] = [];
  const { deps, failed } = voiceDeps({ download: async (_fp, dest) => { dests.push(dest); return true; } });
  const fv = makeFetchVoice(deps);
  expect(await fv("f", 30, 7)).toBe("hello");
  expect(failed.length).toBe(0);
  expect(dests[0].endsWith("30.oga")).toBe(true);
});

test("makeFetchVoice: getFile null → error reply sent, returns null", async () => {
  const { deps, failed } = voiceDeps({ getFile: async () => null });
  expect(await makeFetchVoice(deps)("f", 31, 7)).toBeNull();
  expect(failed).toEqual([7]);
});

test("makeFetchVoice: download failure → error reply sent, returns null", async () => {
  const { deps, failed } = voiceDeps({ download: async () => false });
  expect(await makeFetchVoice(deps)("f", 32, 7)).toBeNull();
  expect(failed).toEqual([7]);
});

test("makeFetchVoice: transcription null → error reply sent, returns null", async () => {
  const { deps, failed } = voiceDeps({ transcribe: async () => null });
  expect(await makeFetchVoice(deps)("f", 33, 7)).toBeNull();
  expect(failed).toEqual([7]);
});

test("makeFetchVoice: empty/whitespace transcript → error reply sent, returns null (contract owned by the closure, not transcribe())", async () => {
  const { deps, failed } = voiceDeps({ transcribe: async () => "   " });
  expect(await makeFetchVoice(deps)("f", 36, 7)).toBeNull();
  expect(failed).toEqual([7]);
});

test("makeFetchVoice: thrown getFile (network/timeout) STILL replies — never a silent drop, never throws", async () => {
  const { deps, failed } = voiceDeps({ getFile: async () => { throw new Error("AbortError: timeout"); } });
  expect(await makeFetchVoice(deps)("f", 34, 7)).toBeNull();
  expect(failed).toEqual([7]);
});

test("makeFetchVoice: sendFail itself throwing is swallowed (logged), null still returned", async () => {
  const { deps } = voiceDeps({ getFile: async () => null, sendFail: async () => { throw new Error("telegram down"); } });
  expect(await makeFetchVoice(deps)("f", 35, 7)).toBeNull();
});

// --- HIMMEL-266: photo download non-blocking for ingest loop ---

test("HIMMEL-266: mixed batch — photo and text in same batch both land in inbox; offset advances for both", async () => {
  // Regression guard for the refactor: non-photo messages must not be lost when
  // a photo is present in the same batch, and offset must cover all updates.
  const r = root();
  const fetchImage: FetchImageFn = async () => "/tmp/att/100.jpg";

  const updates = [
    { update_id: 100, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "f1" }], caption: "look" } },
    { update_id: 101, message: { chat:{id:1}, from:{id:1}, text: "after photo" } },
  ];

  await ingestUpdates(r, updates, allowAll, fetchImage);

  const lines = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
  expect(lines.length).toBe(2);
  expect(lines.some((l) => l.text === "after photo")).toBe(true);
  const photoLine = lines.find((l) => l.update_id === 100);
  expect(photoLine?.image_path).toBe("/tmp/att/100.jpg");
  expect(await loadOffset(r)).toBe(102);
});

test("HIMMEL-266: consumer contract — image_path in inbox entry points to a file that exists at write time", async () => {
  // This test verifies that we only write image_path once the download promise has resolved
  // (the consumer — a bounded claude run — reads the inbox entry after download is done).
  const r = root();
  const written: Array<{ image_path?: string; resolvedBefore: boolean }> = [];
  let downloadResolved = false;

  const fetchImage: FetchImageFn = async (_file_id, _uid) => {
    // Simulate async download delay
    await new Promise<void>((res) => setTimeout(res, 5));
    downloadResolved = true;
    return "/tmp/att/200.jpg";
  };

  const upd = { update_id: 200, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "f" }], caption: "snap" } };
  await ingestUpdates(r, [upd], allowAll, fetchImage);

  const lines = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  // image_path is written (download succeeded), and the download had resolved before the entry was written
  expect(lines[0].image_path).toBe("/tmp/att/200.jpg");
  expect(downloadResolved).toBe(true);   // download was awaited before the inbox entry was appended
});

test("HIMMEL-266: a batch of N photos does not delay getUpdates by N × file-fetch timeout (concurrent downloads)", async () => {
  const r = root();
  const ORDER: string[] = [];
  // Three slow fetches — each takes 10ms but they run concurrently
  const slowFetch: FetchImageFn = async (file_id, _uid) => {
    ORDER.push(`start:${file_id}`);
    await new Promise<void>((res) => setTimeout(res, 10));
    ORDER.push(`end:${file_id}`);
    return `/tmp/${file_id}.jpg`;
  };
  const updates = [
    { update_id: 300, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "a" }] } },
    { update_id: 301, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "b" }] } },
    { update_id: 302, message: { chat:{id:1}, from:{id:1}, photo: [{ file_id: "c" }] } },
  ];
  await ingestUpdates(r, updates, allowAll, slowFetch);
  // All three downloads started before any ended (concurrency, not sequential)
  const startIdx = (id: string) => ORDER.indexOf(`start:${id}`);
  const endIdx   = (id: string) => ORDER.indexOf(`end:${id}`);
  // All starts should appear before the first end — i.e., all three kicked off concurrently
  const firstEnd = Math.min(endIdx("a"), endIdx("b"), endIdx("c"));
  expect(startIdx("a")).toBeLessThan(firstEnd);
  expect(startIdx("b")).toBeLessThan(firstEnd);
  expect(startIdx("c")).toBeLessThan(firstEnd);
  // All three inbox entries written
  const lines = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
  expect(lines.length).toBe(3);
});

// HIMMEL-268 hardening: oga cleanup after transcription

test("makeFetchVoice: oga source file is unlinked after successful transcription (no dead-weight audio)", async () => {
  const unlinked: string[] = [];
  const { deps } = voiceDeps({
    transcribe: async (p: string) => { unlinked.push(p); return "hello"; },
  });
  // transcribe() mock records the path; in production unlink happens inside
  // makeFetchVoice after transcribe() returns. We verify the path is the dest.
  const fv = makeFetchVoice(deps);
  const result = await fv("f", 40, 7);
  expect(result).toBe("hello");
  // The dest path passed to transcribe is the .oga file that makeFetchVoice unlinks.
  expect(unlinked[0]).toMatch(/40/);
  expect(unlinked[0]).toMatch(/\.oga$/);
});

// HIMMEL-268 hardening: caption forwarded when voice transcription fails

test("ingest voice with caption: caption + [voice transcript unavailable] forwarded when transcription fails", async () => {
  const r = root();
  const upd = {
    update_id: 50,
    message: { chat: { id: 1 }, from: { id: 1 }, voice: { file_id: "v" }, caption: "check this out" },
  };
  await ingestUpdates(r, [upd], allowAll, undefined, async () => null);
  const lines = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
  // caption MUST be forwarded even though transcription failed — operator context preserved
  expect(lines.length).toBe(1);
  expect(lines[0].text).toContain("check this out");
  expect(lines[0].text).toContain("[voice transcript unavailable]");
});

test("ingest voice without caption: skipped when transcription fails (no caption to forward)", async () => {
  const r = root();
  const upd = { update_id: 51, message: { chat: { id: 1 }, from: { id: 1 }, voice: { file_id: "v" } } };
  await ingestUpdates(r, [upd], allowAll, undefined, async () => null);
  const lines = await readNewLines(join(r, "inbound.jsonl"), join(r, "inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);   // no caption → nothing to forward
});

// --- attachments GC (HIMMEL-267) ---
// Helpers to write a file with a back-dated mtime so sweep can age it out.

async function writeStale(dir: string, name: string, ageMs: number): Promise<string> {
  await mkdir(dir, { recursive: true });
  const p = join(dir, name);
  await writeFile(p, "data");
  const t = new Date(Date.now() - ageMs);
  await utimes(p, t, t);
  return p;
}

async function writeFresh(dir: string, name: string): Promise<string> {
  await mkdir(dir, { recursive: true });
  const p = join(dir, name);
  await writeFile(p, "data");
  return p;
}

test("sweepAttachments: removes files older than the retention window", async () => {
  const dir = mkdtempSync(join(tmpdir(), "att-"));
  const old = await writeStale(dir, "42.jpg", 8 * 24 * 60 * 60 * 1000);  // 8 days old
  const count = await sweepAttachments(dir, 7 * 24 * 60 * 60 * 1000);
  expect(count).toBe(1);
  let gone = false;
  try { await readFile(old); } catch { gone = true; }
  expect(gone).toBe(true);
});

test("sweepAttachments: keeps files younger than the retention window", async () => {
  const dir = mkdtempSync(join(tmpdir(), "att-"));
  const fresh = await writeFresh(dir, "99.jpg");
  const count = await sweepAttachments(dir, 7 * 24 * 60 * 60 * 1000);
  expect(count).toBe(0);
  const contents = await readFile(fresh, "utf8");
  expect(contents).toBe("data");
});

test("sweepAttachments: mixed stale and fresh — only stale removed", async () => {
  const dir = mkdtempSync(join(tmpdir(), "att-"));
  await writeStale(dir, "old1.jpg", 10 * 24 * 60 * 60 * 1000);
  await writeStale(dir, "old2.oga", 8 * 24 * 60 * 60 * 1000);
  const fresh = await writeFresh(dir, "new.jpg");
  const count = await sweepAttachments(dir, 7 * 24 * 60 * 60 * 1000);
  expect(count).toBe(2);
  const stillThere = await readFile(fresh, "utf8");
  expect(stillThere).toBe("data");
});

test("sweepAttachments: absent dir returns 0 without throwing", async () => {
  const dir = join(tmpdir(), "att-nonexistent-" + Date.now());
  expect(await sweepAttachments(dir, 1000)).toBe(0);
});

test("sweepAttachments: empty dir returns 0", async () => {
  const dir = mkdtempSync(join(tmpdir(), "att-"));
  expect(await sweepAttachments(dir, 1000)).toBe(0);
});

test("resolveRetentionMs: only finite positive values override the default", () => {
  const DEFAULT = 7 * 24 * 60 * 60 * 1000;
  expect(resolveRetentionMs("3600000")).toBe(3600000);
  expect(resolveRetentionMs(undefined)).toBe(DEFAULT);
  expect(resolveRetentionMs("")).toBe(DEFAULT);
  expect(resolveRetentionMs("not-a-number")).toBe(DEFAULT);
  // negative would flip the cutoff into the future (sweep everything) and
  // collapse the daily timer interval — must fall back to the default
  expect(resolveRetentionMs("-1")).toBe(DEFAULT);
  expect(resolveRetentionMs("0")).toBe(DEFAULT);
  expect(resolveRetentionMs("Infinity")).toBe(DEFAULT);
});

// --- is_automatic_forward deduplication (HIMMEL-244) ---
// When a channel has a linked discussion group, Telegram sends TWO updates:
//   1. channel_post (the original, no is_automatic_forward)
//   2. message with is_automatic_forward: true (the auto-forwarded group copy)
// The poller must ingest (1) and drop (2) to avoid duplicate bounded runs.

test("ingest drops is_automatic_forward messages (linked-group copy); original channel_post still ingests", async () => {
  const r = root();
  const allow = (_fromId: number, chatId: number) => chatId === -1001234 || chatId === -1009876;
  await ingestUpdates(r, [
    // original channel post — must be ingested
    { update_id: 50, channel_post: { chat:{id:-1001234}, sender_chat:{id:-1001234}, text:"hello from channel" } },
    // auto-forwarded copy into the linked discussion group — must be DROPPED
    { update_id: 51, message: { chat:{id:-1009876}, from:{id:-1001234}, text:"hello from channel", is_automatic_forward: true } },
  ], allow);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].chat_id).toBe(-1001234);   // only the original channel post
  expect(lines[0].text).toBe("hello from channel");
  expect(await loadOffset(r)).toBe(52);       // both update_ids confirmed (offset advances past both)
});

test("ingest: is_automatic_forward: false is NOT dropped (regular forwarded messages pass through)", async () => {
  const r = root();
  await ingestUpdates(r, [
    { update_id: 60, message: { chat:{id:1}, from:{id:1}, text:"manually forwarded", is_automatic_forward: false } },
  ], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(1);
  expect(lines[0].text).toBe("manually forwarded");
});

test("ingest: is_automatic_forward drop still advances the offset (no retry loop on dupe)", async () => {
  const r = root();
  await ingestUpdates(r, [
    { update_id: 70, message: { chat:{id:-50}, from:{id:1}, text:"dupe", is_automatic_forward: true } },
  ], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines.length).toBe(0);
  expect(await loadOffset(r)).toBe(71);   // confirmed — no re-delivery
});

// --- HIMMEL-424 B2: remote auto-actions (forwarded/caption bits + /arm routing) ---

test("ingest marks forwarded (from a forward marker) + caption explicitly on each record", async () => {
  const r = root();
  await ingestUpdates(r, [
    { update_id: 1, message: { chat:{id:5}, from:{id:5}, text:"/arm HIMMEL-1", forward_origin:{type:"user"} } },
    { update_id: 2, message: { chat:{id:5}, from:{id:5}, text:"/arm HIMMEL-2" } },                     // typed, not forwarded
    { update_id: 3, message: { chat:{id:5}, from:{id:5}, text:"legacy fwd", forward_date: 123 } },     // deprecated marker
  ], allowAll);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].forwarded).toBe(true);  expect(lines[0].caption).toBe(false);
  expect(lines[1].forwarded).toBe(false); expect(lines[1].caption).toBe(false);
  expect(lines[2].forwarded).toBe(true);
});

test("ingest marks caption=true when the text came from a media caption (not m.text)", async () => {
  const r = root();
  const fetchImg: FetchImageFn = async () => "/tmp/x.jpg";
  await ingestUpdates(r, [
    { update_id: 1, message: { chat:{id:5}, from:{id:5}, caption:"/arm HIMMEL-1", photo:[{file_id:"a"}] } },
  ], allowAll, fetchImg);
  const lines = await readNewLines(join(r,"inbound.jsonl"), join(r,"inbound.jsonl.cursor"));
  expect(lines[0].caption).toBe(true);
  expect(lines[0].forwarded).toBe(false);
});

const autoGate = (ops: string[], fired: any[], authorize: (from: number, chat_id: number) => boolean = () => true) => ({
  enabledOps: new Set(ops),
  authorize,
  fire: (msg: any, route: any) => { fired.push({ msg, route }); },
});

test("handleInbound routes a DM + operator + typed + enabled /arm to the auto fire, NOT run", async () => {
  const r = root(); const fired: any[] = []; let ran = false;
  await handleInbound(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false },
    async () => { ran = true; }, autoGate(["arm-resume"], fired));
  expect(fired.length).toBe(1);
  expect(fired[0].route.op).toBe("arm-resume");
  expect(ran).toBe(false);
});

test("autoGate.authorize composition: operator + allowlisted-chat only (CR S1 self-sufficiency)", () => {
  const access = { allowFrom: ["5"], groups: { "-50": {} } };
  const allow = makeAllow(access);
  const authorize = (from: number, chat_id: number) => isAllowed(access, from) && allow(from, chat_id);
  expect(authorize(5, 5)).toBe(true);     // operator DM
  expect(authorize(5, -50)).toBe(true);   // operator in an allowlisted group
  expect(authorize(9, -50)).toBe(false);  // non-operator in the group → refused (not operator)
  expect(authorize(5, -99)).toBe(false);  // operator in a NON-allowlisted group → refused (chat gate)
});

test("handleInbound: an OPERATOR /arm in an allowlisted GROUP fires (operator-identity, HIMMEL-424 groups)", async () => {
  const r = root(); const fired: any[] = []; let ran = false;
  // operator (from=5) in a group (chat_id<0); isOperator(5)=true → arms
  await handleInbound(r, { from:5, chat_id:-50, text:"/arm HIMMEL-1", forwarded:false, caption:false },
    async () => { ran = true; }, autoGate(["arm-resume"], fired, (from) => from === 5));
  expect(fired.length).toBe(1);
  expect(ran).toBe(false);
});

test("handleInbound: a NON-operator /arm in a shared group falls through to chat, never arms — fix C1", async () => {
  const r = root(); const fired: any[] = []; const ran: string[] = [];
  // a different member (from=9) of the same group; isOperator(9)=false → powerless chat
  await handleInbound(r, { from:9, chat_id:-50, text:"/arm HIMMEL-1", forwarded:false, caption:false },
    async (s:string) => { ran.push(s); }, autoGate(["arm-resume"], fired, (from) => from === 5));
  expect(fired.length).toBe(0);
  expect(ran).toEqual(["group_-50"]);   // ordinary chat
});

test("handleInbound: a media-caption /arm in a DM falls through to chat, never arms — fix C2", async () => {
  const r = root(); const fired: any[] = []; const ran: string[] = [];
  await handleInbound(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:true },
    async (s:string) => { ran.push(s); }, autoGate(["arm-resume"], fired));
  expect(fired.length).toBe(0);
  expect(ran).toEqual(["__chat__"]);
});

test("handleInbound: empty enabledOps (default) → /arm is ordinary chat (inert)", async () => {
  const r = root(); const fired: any[] = []; const ran: string[] = [];
  await handleInbound(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false },
    async (s:string) => { ran.push(s); }, autoGate([], fired));
  expect(fired.length).toBe(0);
  expect(ran).toEqual(["__chat__"]);
});

test("handleInbound: a DIFFERENT op enabled but /arm (arm-resume) disabled → chat", async () => {
  const r = root(); const fired: any[] = []; const ran: string[] = [];
  await handleInbound(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false },
    async (s:string) => { ran.push(s); }, autoGate(["file-ticket"], fired));
  expect(fired.length).toBe(0);
  expect(ran).toEqual(["__chat__"]);
});

test("handleInbound: no auto deps wired → /arm is ordinary chat (back-compat)", async () => {
  const r = root(); const ran: string[] = [];
  await handleInbound(r, { from:5, chat_id:5, text:"/arm HIMMEL-1" }, async (s:string) => { ran.push(s); });
  expect(ran).toEqual(["__chat__"]);
});

const autoDeps = () => {
  const replies: any[] = []; const audits: any[] = []; let dispatched = 0;
  return {
    replies, audits, dispatched: () => dispatched,
    deps: {
      runScript: async () => { dispatched++; return { code: 0, stdout: "resolved=2026-x.md\n", stderr: "" }; },
      reply: async (chat: number, text: string) => { replies.push({ chat, text }); },
      audit: async (f: any) => { audits.push(f); },
    },
  };
};
const armRoute = { kind: "auto" as const, op: "arm-resume", arg: "HIMMEL-1", time: "smart" };

test("handleAutoCommand: a non-forwarded /arm arms, replies success, audits 'armed'", async () => {
  const r = root(); const a = autoDeps();
  await handleAutoCommand(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false }, armRoute, a.deps);
  expect(a.dispatched()).toBe(1);
  expect(a.replies[0].chat).toBe(5);
  expect(a.replies[0].text).toContain("armed");
  expect(a.audits[0].result).toBe("armed");
  expect(a.audits[0].resolved).toBe("2026-x.md");
});

test("handleAutoCommand: a FORWARDED /arm refuses — NO dispatch, reply + audit 'refused-forwarded' (THE injection test)", async () => {
  const r = root(); const a = autoDeps();
  await handleAutoCommand(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:true, caption:false }, armRoute, a.deps);
  expect(a.dispatched()).toBe(0);                                   // never armed
  expect(a.replies[0].text.toLowerCase()).toContain("forward");
  expect(a.audits[0].result).toBe("refused-forwarded");
  expect(a.audits[0].fwd ?? a.audits[0].forwarded).toBeTruthy();
});

test("handleAutoCommand: arm-resume dedup (rc 5) audits 'already-armed', no false success", async () => {
  const r = root(); const a = autoDeps();
  const deps = { ...a.deps, runScript: async () => ({ code: 5, stdout: "", stderr: "" }) };
  await handleAutoCommand(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false }, armRoute, deps);
  expect(a.replies[0].text.toLowerCase()).toContain("already armed");
  expect(a.audits[0].result).toBe("already-armed");
});

test("replyViaOutbox routes a group reply to group_<id> and a DM reply to __chat__; flush delivers each to its chat", async () => {
  const r = root();
  await replyViaOutbox(r, -50, "grp reply");
  await replyViaOutbox(r, 7, "dm reply");
  expect((await readMeta(r, "group_-50"))?.chat_id).toBe(-50);
  expect((await readMeta(r, "__chat__"))?.chat_id).toBe(7);
  const sent: any[] = [];
  await flushOutboxes(r, async (c: number, t: string) => { sent.push([c, t]); });
  expect(sent).toContainEqual([-50, "grp reply"]);   // group arm reply lands in the GROUP
  expect(sent).toContainEqual([7, "dm reply"]);
});

test("handleAutoCommand: a reply-delivery failure does NOT swallow the audit nor throw (CR I1)", async () => {
  const r = root(); const audits: any[] = [];
  const deps = {
    runScript: async () => ({ code: 0, stdout: "resolved=x.md\n", stderr: "" }),
    reply: async () => { throw new Error("telegram down"); },   // reply fails AFTER the arm
    audit: async (f: any) => { audits.push(f); },
  };
  await handleAutoCommand(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:false, caption:false }, armRoute, deps);
  expect(audits.length).toBe(1);              // the privileged arm is still durably recorded
  expect(audits[0].result).toBe("armed");
  // and the forwarded-refuse branch likewise audits before the (failing) reply
  audits.length = 0;
  await handleAutoCommand(r, { from:5, chat_id:5, text:"/arm HIMMEL-1", forwarded:true, caption:false }, armRoute, deps);
  expect(audits[0].result).toBe("refused-forwarded");
});

// --- HIMMEL-578: per-chat vault cwd + scoped bypassPermissions ---
test("makeRunFn: a vault-configured chat spawns in the vault cwd with bypassPermissions; jira path stays on repoCwd", async () => {
  const r = root(); await ensureSession(r, "V");
  await writeMeta(r, "V", freshMeta(42));
  await appendLine(join(sessionDir(r, "V"), "inbox.jsonl"), JSON.stringify({ text: "file this photo" }));
  const calls: Array<{ prompt: string; cwd: string; mode?: string }> = [];
  const spy = async (prompt: string, cwd: string, mode?: string) => { calls.push({ prompt, cwd, mode }); return { code: 0, capped: false, pid: 1 }; };
  const vaultFor = (chatId: number) => chatId === 42 ? "/vaults/medic" : null;
  await makeRunFn(r, "/repo", spy, 5000, undefined, 3, vaultFor)("V");
  expect(calls.length).toBeGreaterThan(0);
  expect(calls[0].cwd).toBe("/vaults/medic");                       // spawned IN the vault (loads its hooks)
  expect(calls[0].mode).toBe("bypassPermissions");                  // scoped bypass for vault sessions
  expect(calls[0].prompt).toContain("/repo/scripts/jira/dist/index.js"); // jira path decoupled onto repoCwd
  expect(calls[0].prompt).toContain("running in /vaults/medic");
});
test("makeRunFn: a NON-vault chat spawns in repoCwd with NO bypass (default posture unchanged)", async () => {
  const r = root(); await ensureSession(r, "N");
  await writeMeta(r, "N", freshMeta(7));
  await appendLine(join(sessionDir(r, "N"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  const calls: Array<{ cwd: string; mode?: string }> = [];
  const spy = async (_p: string, cwd: string, mode?: string) => { calls.push({ cwd, mode }); return { code: 0, capped: false, pid: 1 }; };
  const vaultFor = (_chatId: number) => null;
  await makeRunFn(r, "/repo", spy, 5000, undefined, 3, vaultFor)("N");
  expect(calls[0].cwd).toBe("/repo");
  expect(calls[0].mode).toBeUndefined();
});

// HIMMEL-578 CR follow-ups (test-analyzer findings):
// blast-radius — a configured defaultVault routes EVERY unconfigured chat (DMs,
// unknown groups) into a vault cwd WITH bypassPermissions. Pin that composed
// behavior with the REAL vaultForChat (the unit tests above stubbed it).
test("makeRunFn + real vaultForChat: a defaultVault grants vault-cwd+bypass to an UNCONFIGURED chat (blast radius)", async () => {
  const r = root(); await ensureSession(r, "D");
  await writeMeta(r, "D", freshMeta(99999));            // not in groups
  await appendLine(join(sessionDir(r, "D"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  const access = { dmPolicy: "allowlist", allowFrom: ["99999"], defaultVault: "/vaults/luna", groups: {}, pending: {} } as any;
  const calls: Array<{ cwd: string; mode?: string }> = [];
  const spy = async (_p: string, cwd: string, mode?: string) => { calls.push({ cwd, mode }); return { code: 0, capped: false, pid: 1 }; };
  await makeRunFn(r, "/repo", spy, 5000, undefined, 3, (id) => vaultForChat(access, id))("D");
  expect(calls[0].cwd).toBe("/vaults/luna");            // defaultVault → vault cwd even for an unconfigured chat
  expect(calls[0].mode).toBe("bypassPermissions");      // …and bypass follows (documented blast radius)
});
test("makeRunFn: an empty-string vault normalizes to null (repoCwd, no bypass) — no incoherent cwd \"\"", async () => {
  const r = root(); await ensureSession(r, "E");
  await writeMeta(r, "E", freshMeta(8));
  await appendLine(join(sessionDir(r, "E"), "inbox.jsonl"), JSON.stringify({ text: "hi" }));
  const calls: Array<{ cwd: string; mode?: string }> = [];
  const spy = async (_p: string, cwd: string, mode?: string) => { calls.push({ cwd, mode }); return { code: 0, capped: false, pid: 1 }; };
  await makeRunFn(r, "/repo", spy, 5000, undefined, 3, () => "")("E");   // blank vault
  expect(calls[0].cwd).toBe("/repo");                   // not "" — normalized
  expect(calls[0].mode).toBeUndefined();                // no bypass for a falsy vault
});
