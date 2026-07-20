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
test("sendMessage does not retry a rejected fetch and returns false", async () => {
  const fakeFetch = mock(async () => { throw new Error("net down"); });
  const ok = await sendMessage("T", 123, "hi", fakeFetch as any);
  expect(ok).toBe(false);
  expect(fakeFetch).toHaveBeenCalledTimes(1);
});
test("sendMessage fully redacts one- and two-character chat ids in logs", async () => {
  const fakeFetch = async () => new Response(JSON.stringify({ ok:false, description:"bad" }), {status:400});
  const error = spyOn(console, "error").mockImplementation(() => {});
  try {
    await sendMessage("T", 7, "hi", fakeFetch as any);
    await sendMessage("T", 42, "hi", fakeFetch as any);
    expect(error.mock.calls.map(([message]) => String(message))).toEqual([
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
