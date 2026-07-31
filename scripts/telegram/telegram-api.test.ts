import { expect, test, spyOn, mock } from "bun:test";
import { getUpdates, sendMessage, sendChatAction } from "./telegram-api";

test("sendChatAction posts chat_id + action; failure is swallowed (best-effort)", async () => {
  const bodies: any[] = [];
  const fakeFetch = async (_url: string, init: any) => { bodies.push(JSON.parse(init.body)); return new Response(JSON.stringify({ ok: true })); };
  await sendChatAction("T", 42, fakeFetch as any);
  expect(bodies[0]).toEqual({ chat_id: 42, action: "typing" });
  const failFetch = async () => { throw new Error("net down"); };
  await sendChatAction("T", 42, failFetch as any);   // must not throw
});
test("getUpdates passes offset+timeout and returns updates", async () => {
  const calls: string[] = [];
  const fakeFetch = async (url: string) => { calls.push(url);
    return new Response(JSON.stringify({ ok: true, result: [{ update_id: 5 }] })); };
  const r = await getUpdates("TOKEN", 4, 30, fakeFetch as any);
  expect(r[0].update_id).toBe(5);
  expect(calls[0]).toContain("offset=4"); expect(calls[0]).toContain("timeout=30");
});
test("getUpdates returns [] on a malformed ok:true with no result array (no throw)", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: true }));   // result missing
  const r = await getUpdates("TOKEN", 0, 30, fakeFetch as any);
  expect(r).toEqual([]);
});
test("getUpdates THROWS on a non-ok response (HIMMEL-1401) so the poller's catch can back off instead of hot-looping", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: false, description: "Bad Gateway" }), { status: 502 });
  await expect(getUpdates("TOKEN", 0, 30, fakeFetch as any)).rejects.toThrow(/Bad Gateway/);
});
test("getUpdates non-ok error falls back to the HTTP status when description is absent", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok: false }), { status: 502 });
  await expect(getUpdates("TOKEN", 0, 30, fakeFetch as any)).rejects.toThrow(/502/);
});
test("getUpdates aborts a stalled request within its client-side deadline (HIMMEL-1401 CR round 2) — a transport that never resolves must still REJECT, not hang forever, so the poller's catch/backoff fires", async () => {
  // Models a stuck transport: the fetch promise never resolves on its own, only
  // rejecting when the AbortSignal getUpdates wires up actually fires — exactly
  // what a real fetch implementation does under an AbortSignal (this is the same
  // contract getFile/downloadFile already rely on for FILE_FETCH_TIMEOUT_MS).
  // `timeout=0` and a 20ms abortMarginMs keep the deadline (0*1000+20=20ms) tiny
  // so the test doesn't wait out a real long-poll window.
  const stallForever = (_url: string, init?: { signal?: AbortSignal }) =>
    new Promise<Response>((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new Error("The operation was aborted.")));
    });
  const start = Date.now();
  await expect(getUpdates("TOKEN", 0, 0, stallForever as any, 20)).rejects.toThrow();
  expect(Date.now() - start).toBeLessThan(2000);   // rejected via the 20ms deadline, not left hanging
});
test("getUpdates passes an AbortSignal to fetch so a stalled request CAN be aborted (wiring pin)", async () => {
  let sawSignal: AbortSignal | undefined;
  const fakeFetch = async (_url: string, init?: { signal?: AbortSignal }) => {
    sawSignal = init?.signal;
    return new Response(JSON.stringify({ ok: true, result: [] }));
  };
  await getUpdates("TOKEN", 0, 30, fakeFetch as any);
  expect(sawSignal).toBeInstanceOf(AbortSignal);
});
test("sendMessage honors 429 retry_after then succeeds", async () => {
  let n = 0; const sleeps: number[] = [];
  const fakeFetch = async () => { n++;
    if (n === 1) return new Response(JSON.stringify({ ok:false, error_code:429, parameters:{ retry_after:2 }}), {status:429});
    return new Response(JSON.stringify({ ok:true, result:{} })); };
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, (s:number)=>{sleeps.push(s);return Promise.resolve();});
  expect(sleeps).toEqual([2000]);
  expect(ok).toBe(true);        // delivered after the retry
});
test("sendMessage drops on 400 client error without looping or sleeping, and reports not-delivered", async () => {
  let n = 0; const sleeps: number[] = [];
  const fakeFetch = async () => { n++;
    return new Response(JSON.stringify({ ok:false, error_code:400, description:"chat not found" }), {status:400}); };
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, (s:number)=>{sleeps.push(s);return Promise.resolve();});
  expect(n).toBe(1);            // called once, no retry loop
  expect(sleeps).toEqual([]);   // permanent error → no sleep
  expect(ok).toBe(false);       // permanent drop → false (never silently "delivered")
});
test("sendMessage does NOT report delivered on HTTP 200 with ok:false (validates Telegram's ok flag)", async () => {
  let n = 0;
  const fakeFetch = async () => { n++;
    return new Response(JSON.stringify({ ok:false, description:"blocked" }), {status:200}); };  // 2xx but app-level failure
  const ok = await sendMessage("T", 1, "hi", fakeFetch as any, () => Promise.resolve());
  expect(ok).toBe(false);       // must not treat a 200/{ok:false} as delivered
  expect(n).toBe(5);            // bounded retry, then gives up (no infinite loop)
});
test("sendMessage logs a redacted transport failure, does not retry, and returns false", async () => {
  const fakeFetch = mock(async () => { throw new Error("net down"); });
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    const ok = await sendMessage("T", 123, "hi", fakeFetch as any);
    expect(ok).toBe(false);
    expect(fakeFetch).toHaveBeenCalledTimes(1);
    expect(error).toHaveBeenCalledWith("[telegram] sendMessage transport failure chat=***23");
  } finally { error.mockRestore(); }
});
test("sendMessage fully redacts one- and two-digit chat ids in logs, including signed ids", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok:false, description:"bad" }), {status:400});
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    await sendMessage("T", 7, "hi", fakeFetch as any);
    await sendMessage("T", 42, "hi", fakeFetch as any);
    await sendMessage("T", -42, "hi", fakeFetch as any);
    expect(error.mock.calls.map(([message]) => String(message))).toEqual([
      "[telegram] sendMessage 400 chat=***: bad",
      "[telegram] sendMessage 400 chat=***: bad",
      "[telegram] sendMessage 400 chat=***: bad",
    ]);
  } finally { error.mockRestore(); }
});
// --- getFile + downloadFile (HIMMEL-250) ---
import { getFile, downloadFile } from "./telegram-api";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

test("getFile resolves file_id to file_path", async () => {
  const calls: string[] = [];
  const fakeFetch = async (url: string) => { calls.push(url);
    return new Response(JSON.stringify({ ok: true, result: { file_path: "photos/file_1.jpg" } })); };
  const fp = await getFile("TOKEN", "abc def", fakeFetch as any);
  expect(fp).toBe("photos/file_1.jpg");
  expect(calls[0]).toContain("file_id=abc%20def");   // file_id is URL-encoded
});

test("getFile returns null on not-ok / missing file_path (no throw)", async () => {
  expect(await getFile("T", "x", (async () => new Response(JSON.stringify({ ok: false, description: "bad" }))) as any)).toBeNull();
  expect(await getFile("T", "x", (async () => new Response(JSON.stringify({ ok: true, result: {} }))) as any)).toBeNull();
});

test("downloadFile writes the bytes to dest and returns true", async () => {
  const dest = join(mkdtempSync(join(tmpdir(), "tg-dl-")), "img.jpg");
  const fakeFetch = async (url: string) => {
    expect(url).toBe("https://api.telegram.org/file/botTOKEN/photos/file_1.jpg");
    return new Response(new Uint8Array([1, 2, 3]));
  };
  expect(await downloadFile("TOKEN", "photos/file_1.jpg", dest, fakeFetch as any)).toBe(true);
  expect([...readFileSync(dest)]).toEqual([1, 2, 3]);
});

test("downloadFile returns false on a non-ok response", async () => {
  const dest = join(mkdtempSync(join(tmpdir(), "tg-dl-")), "img.jpg");
  const fakeFetch = async () => new Response("nope", { status: 404 });
  expect(await downloadFile("TOKEN", "p.jpg", dest, fakeFetch as any)).toBe(false);
});
