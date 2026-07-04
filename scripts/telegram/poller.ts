import { readFile, writeFile, rename, mkdir, readdir, unlink, stat } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { appendLine, atomicWrite, bridgeRoot, ensureSession, readMeta, writeMeta, sessionDir, readNewLines, truncateFullyConsumed, type Meta } from "./bus";
import { classify, type Route } from "./router";
import { dispatchAutoAction, parseEnabledOps, KNOWN_OPS, appendAuditLine, type RunScriptFn, type AuditFields } from "./auto-action";
import { getUpdates, sendMessage, sendChatAction, getFile, downloadFile } from "./telegram-api";
import { isAllowed, isGroupAllowed, loadAccess, vaultForChat, type Access } from "./gate";
import { runSession, buildPrompt, type BusPaths, type PermissionMode } from "./run";
import { transcribe } from "./transcribe";

// Retry backoff for a capped session (ms). On a cap, settle retry_at = now + RETRY_MS
// so deliverAllPending's isRetryDue re-runs the session later instead of re-spawning a
// bounded `claude` against a usage-capped account every poll cycle.
const RETRY_MS = Number(process.env.TELEGRAM_RETRY_MS ?? 15 * 60 * 1000);

// from: sender user id; for anonymous channel posts the sender_chat (channel) id, or 0.
// image_path: local path of a downloaded photo (HIMMEL-250), absent for text messages.
// document_path/document_name: local path + original filename of a downloaded
// document attachment, e.g. a PDF (HIMMEL-321); absent for non-document messages.
// Invariant: document_path is only ever present alongside document_name (set as
// a pair); document_name without document_path means the download failed and the
// message degraded to caption-only forwarding.
// forwarded/caption (HIMMEL-424 B2): always explicit booleans, never optional — they
// gate the privileged `/arm` auto-command. `forwarded` = any Telegram forward marker
// present (the injection-refuse signal). `caption` = the text came from a media caption
// or voice transcript, NOT a genuinely typed m.text. Both fail toward "not a typed
// command" so an undefined-deserialized value can never fail OPEN.
export type Inbound = { from: number; chat_id: number; text: string; ts: number; update_id: number; forwarded: boolean; caption: boolean; image_path?: string; document_path?: string; document_name?: string };
export type AllowFn = (fromId: number, chatId: number) => boolean;
// Downloads a photo by file_id, returns the local path (null on failure).
export type FetchImageFn = (file_id: string, update_id: number) => Promise<string | null>;
// Downloads a document by file_id (file_name preserves the extension for Read),
// returns the local path (null on failure) (HIMMEL-321).
export type FetchDocFn = (file_id: string, update_id: number, file_name: string) => Promise<string | null>;
// Tells the operator their document couldn't be downloaded (HIMMEL-321). Unlike
// a silently-degraded photo, a dropped document also loses its vault-filing
// clause downstream (run.ts buildPrompt only fires when document_path is present),
// so the operator would otherwise get a caption-only reply with no sign the file
// dropped — the bridge's "never a silent drop" rule (cf. voice) applies here too.
export type NotifyDocFailFn = (chatId: number, name: string) => Promise<void>;
// Downloads + transcribes a voice/audio message, returns the TRANSCRIPT (HIMMEL-251).
// Convention (enforced by makeFetchVoice, the one production implementation):
// never throws; null = failure AND the chat was already told — so ingest can skip
// the update without breaking the "never a silent drop" acceptance.
export type FetchVoiceFn = (file_id: string, update_id: number, chat_id: number) => Promise<string | null>;

// Build the production FetchVoiceFn (HIMMEL-251). Wraps EVERY exit in the
// explicit "couldn't transcribe" reply (CR: a thrown getFile — network error /
// the FILE_FETCH_TIMEOUT_MS abort in telegram-api.ts — used to escape before the reply was sent = the
// silent drop the ticket forbids). sendFail failures are logged with context,
// never thrown: the reply is best-effort, the skip must still happen.
export function makeFetchVoice(deps: {
  getFile: (file_id: string) => Promise<string | null>;
  download: (file_path: string, dest: string) => Promise<boolean>;
  transcribe: (path: string) => Promise<string | null>;
  sendFail: (chat_id: number) => Promise<void>;
  attachmentsDir: string;
}): FetchVoiceFn {
  return async (file_id, update_id, chat_id) => {
    const fail = async (): Promise<null> => {
      try { await deps.sendFail(chat_id); }
      catch (e) { console.error(`[poller] transcription-failure reply could not be delivered for update ${update_id}: ${e}`); }
      return null;
    };
    try {
      const fp = await deps.getFile(file_id);
      if (!fp) return fail();
      await mkdir(deps.attachmentsDir, { recursive: true });
      const dest = join(deps.attachmentsDir, `${update_id}${safeExt(fp, ".oga")}`);
      if (!(await deps.download(fp, dest))) return fail();
      // Empty/whitespace counts as failure HERE, not just in transcribe()
      // (CR: a custom transcribe returning "" would slip past `??` reply-less,
      // then be dropped by ingest's falsy check — the silent drop, again).
      const transcript = (await deps.transcribe(dest))?.trim() || null;
      // HIMMEL-268 hardening: source .oga has no downstream consumer after transcription
      // (unlike photos which may be re-read by the session). Unlink here instead of
      // letting attachments/ accumulate dead-weight audio files. Fold into HIMMEL-267
      // GC pass if more nuanced lifecycle is needed later.
      await unlink(dest).catch((e: NodeJS.ErrnoException) => {
        if (e.code !== "ENOENT") console.error(`[poller] oga cleanup failed for ${dest}: ${e.code ?? e}`);
      });
      return transcript ?? fail();
    } catch (e) {
      console.error(`[poller] voice pipeline threw for update ${update_id}: ${e}`);
      return fail();
    }
  };
}

// Telegram controls file_path, so the extension it implies is attacker-shaped:
// allow only a plain alphanumeric suffix (no `/` subpaths, no `?` — invalid in
// NTFS filenames), else fall back (.jpg for photos, caller overrides for voice).
// Keeps dest strictly inside attachments/.
export function safeExt(file_path: string, fallback = ".jpg"): string {
  const dot = file_path.lastIndexOf(".");
  const ext = dot > 0 ? file_path.slice(dot) : "";
  return /^\.[A-Za-z0-9]+$/.test(ext) ? ext : fallback;
}

// The composed ingest gate. The DM leg is scoped to positive chat_ids: an
// allowFrom sender posting in a NON-allowed group must NOT open it (the reply
// would land in that group). Telegram DM chat_id == sender user id, so DMs
// from an allowFrom sender still pass. Group/channel chats pass only via the
// groups allowlist (with its optional per-group allowFrom).
export function makeAllow(access: Access): AllowFn {
  return (fromId, chatId) => (chatId > 0 && isAllowed(access, fromId)) || isGroupAllowed(access, chatId, fromId);
}

export async function loadOffset(root: string): Promise<number> {
  try { return Number(await readFile(join(root, "offset"), "utf8")) || 0; } catch { return 0; }
}
async function saveOffset(root: string, off: number): Promise<void> {
  const p = join(root, "offset"); const tmp = p + ".tmp";
  await writeFile(tmp, String(off), "utf8"); await rename(tmp, p);   // atomic
}

// Append-then-confirm: durably append accepted inbound, THEN advance offset.
// Updates with update_id < current offset are already confirmed → skipped (dedup).
// HIMMEL-266: photo downloads start concurrently across the batch instead of
// serializing inside the loop; inbox entries for photo updates are written once
// their download resolves (image_path points to an existing file). The offset
// still advances last — durability beats latency, and FILE_FETCH_TIMEOUT_MS in
// telegram-api.ts already bounds how long the batch can take.
type PendingPhoto = { rec: Omit<Inbound, "image_path">; p: Promise<string | null> };
// Document updates (HIMMEL-321) mirror the concurrent-photo pattern: download
// started during the loop, the inbox entry (with document_path) written after
// the offset advances. document_name is known up-front (carried on rec).
type PendingDoc = { rec: Omit<Inbound, "document_path">; p: Promise<string | null> };

export async function ingestUpdates(root: string, updates: any[], allow: AllowFn = () => true, fetchImage?: FetchImageFn, fetchVoice?: FetchVoiceFn, fetchDoc?: FetchDocFn, notifyDocFail?: NotifyDocFailFn): Promise<void> {
  await mkdir(root, { recursive: true });
  const offset = await loadOffset(root);
  let maxId = offset - 1;
  // Inbox entries ready to append immediately (no pending download).
  const ready: Inbound[] = [];
  // Photo updates: download started concurrently; inbox write happens after offset advance.
  const pendingPhotos: PendingPhoto[] = [];
  // Document updates: same concurrent-download treatment as photos.
  const pendingDocs: PendingDoc[] = [];
  for (const u of updates) {
    if (typeof u.update_id !== "number" || u.update_id < offset) continue;   // dedup already-seen
    maxId = Math.max(maxId, u.update_id);
    const m = u.message ?? u.channel_post;                 // channel posts arrive as channel_post (HIMMEL-238)
    if (!m) continue;
    if (m.is_automatic_forward === true) continue;         // drop linked-group duplicates (HIMMEL-244)
    const chatId = m.chat?.id;
    if (chatId == null) continue;
    // photos arrive as an array of sizes, smallest→largest — take the largest (HIMMEL-250)
    const photo = Array.isArray(m.photo) && m.photo.length ? m.photo[m.photo.length - 1] : null;
    // voice notes (m.voice) and audio files (m.audio) both carry a file_id (HIMMEL-251)
    const voice = m.voice ?? m.audio ?? null;
    // document attachments — PDFs and other files (HIMMEL-321). Mutually
    // exclusive with photo/voice on a single Telegram message.
    const doc = m.document ?? null;
    const hasText = typeof m.text === "string" && m.text.trim() !== "";
    // drop text-less, media-less updates (service messages, joins, stickers) —
    // they would otherwise spawn a bounded run answering an empty prompt
    if (!hasText && !photo && !voice && !doc) continue;
    // channel posts have no `from` (anonymous) — fall back to sender_chat (the channel itself)
    const fromId = m.from?.id ?? m.sender_chat?.id ?? 0;
    if (!allow(fromId, chatId)) {                          // gated out (offset still advances below)
      // log non-DM rejects so the operator can discover a new group/channel chat_id
      if (chatId < 0) console.error(`[poller] gated out chat ${chatId} (add to groups in access.json to allow)`);
      continue;
    }
    const caption = typeof m.caption === "string" ? m.caption.trim() : "";
    // forwarded (HIMMEL-424): any Telegram forward marker. forward_origin is the
    // authoritative modern field; the rest are deprecated back-compat. (is_automatic_forward
    // posts are already dropped at the top of the loop.) Presence => forwarded, the safe side.
    const forwarded = !!(m.forward_origin ?? m.forward_date ?? m.forward_from ?? m.forward_from_chat ?? m.forward_sender_name);
    let text: string;
    if (voice) {
      // transcription not wired → drop like other unsupported media (stickers)
      if (!fetchVoice) continue;
      let transcript: string | null = null;
      // defensive only: makeFetchVoice never throws (it owns the "couldn't
      // transcribe" reply on every exit); a custom fetchVoice that does throw
      // degrades to a logged skip
      try { transcript = await fetchVoice(voice.file_id, u.update_id, chatId); }
      catch (e) { console.error(`[poller] voice transcription failed for update ${u.update_id}: ${e}`); }
      // null = failure; makeFetchVoice already replied "couldn't transcribe"
      // to the chat (HIMMEL-251 acceptance: explicit error, not a silent drop).
      // HIMMEL-268 hardening: if there was a caption, forward it so the operator
      // context is preserved even when the audio couldn't be transcribed.
      // UX note: caption-with-failed-voice produces two outputs — the error notice
      // (from makeFetchVoice) and then a claude run on the caption text. This is
      // intentional: the caption carries independent context worth processing.
      if (!transcript) {
        if (!caption) continue;
        text = caption + "\n[voice transcript unavailable]";
      } else {
        text = (caption ? caption + "\n" : "") + "[voice transcript] " + transcript;
      }
      // caption:true — a voice transcript is never a typed command (auto-ineligible).
      ready.push({ from: fromId, chat_id: chatId, text, ts: m.date ?? 0, update_id: u.update_id, forwarded, caption: true });
    } else if (doc && fetchDoc) {
      // Document (e.g. PDF) — same concurrent, time-bounded download as photos (HIMMEL-321).
      const docName = typeof doc.file_name === "string" ? doc.file_name : "file";
      text = caption || `[document: ${docName}]`;
      const downloadP = fetchDoc(doc.file_id, u.update_id, docName)
        .catch((e: unknown) => { console.error(`[poller] document download failed for update ${u.update_id}: ${e}`); return null; });
      pendingDocs.push({ rec: { from: fromId, chat_id: chatId, text, ts: m.date ?? 0, update_id: u.update_id, document_name: docName, forwarded, caption: true }, p: downloadP });
    } else if (photo && fetchImage) {
      // Start the download immediately (after allow gate) but do NOT await it here —
      // downloads run concurrently across the batch (HIMMEL-266); each one is
      // already time-bounded by FILE_FETCH_TIMEOUT_MS in telegram-api.ts.
      text = caption || "[photo]";
      const downloadP = fetchImage(photo.file_id, u.update_id)
        .catch((e: unknown) => { console.error(`[poller] photo download failed for update ${u.update_id}: ${e}`); return null; });
      pendingPhotos.push({ rec: { from: fromId, chat_id: chatId, text, ts: m.date ?? 0, update_id: u.update_id, forwarded, caption: true }, p: downloadP });
    } else {
      // plain text, or photo/document with no fetch fn wired (forward caption text only)
      text = photo ? (caption || "[photo]")
           : doc ? (caption || `[document: ${typeof doc.file_name === "string" ? doc.file_name : "file"}]`)
           : m.text;
      // caption:true iff the text came from a media caption (photo/doc present), else it
      // is a genuinely typed m.text (caption:false) — the only auto-command-eligible shape.
      ready.push({ from: fromId, chat_id: chatId, text, ts: m.date ?? 0, update_id: u.update_id, forwarded, caption: !!(photo || doc) });
    }
  }
  // Write all non-photo inbox entries.
  for (const rec of ready) {
    await appendLine(join(root, "inbound.jsonl"), JSON.stringify(rec));
  }
  // Await photo downloads concurrently, then write their inbox entries.
  // image_path is only set when the download actually succeeded (consumer contract).
  if (pendingPhotos.length > 0) {
    const results = await Promise.all(pendingPhotos.map((pp) => pp.p));
    for (let i = 0; i < pendingPhotos.length; i++) {
      const { rec } = pendingPhotos[i];
      const image_path = results[i] ?? undefined;
      await appendLine(join(root, "inbound.jsonl"), JSON.stringify({ ...rec, ...(image_path ? { image_path } : {}) }));
    }
  }
  // Await document downloads concurrently, then write their inbox entries (HIMMEL-321).
  // document_path is only set when the download succeeded; a failed download
  // degrades to caption-only forwarding (document_name is still carried on rec).
  if (pendingDocs.length > 0) {
    const results = await Promise.all(pendingDocs.map((pd) => pd.p));
    for (let i = 0; i < pendingDocs.length; i++) {
      const { rec } = pendingDocs[i];
      const document_path = results[i] ?? undefined;
      await appendLine(join(root, "inbound.jsonl"), JSON.stringify({ ...rec, ...(document_path ? { document_path } : {}) }));
      // Failed download (null) degrades to caption-only forwarding — tell the
      // operator so a dropped PDF isn't a silent no-op (HIMMEL-321). Best-effort:
      // a notify failure is logged, never thrown (the inbox append already happened).
      if (!document_path && notifyDocFail) {
        try { await notifyDocFail(rec.chat_id, rec.document_name ?? "file"); }
        catch (e) { console.error(`[poller] doc-fail notice could not be delivered for chat ${rec.chat_id}: ${e}`); }
      }
    }
  }
  // Append-then-confirm preserved: the offset advances only after every accepted
  // inbound is durably in the inbox (a crash mid-batch re-delivers, never loses).
  // Concurrency — not an early offset — is the HIMMEL-266 fix; each download is
  // already time-bounded at the API layer, so this await cannot hang unbounded.
  if (maxId >= offset) await saveOffset(root, maxId + 1);
}

export type DeliveredMsg = { from: number; chat_id: number; text: string; ts?: number; forwarded?: boolean; caption?: boolean; image_path?: string; document_path?: string; document_name?: string };
export type RunFn = (session: string) => Promise<void>;

// Auto-command gate (HIMMEL-424 B2). `fire` is FIRE-AND-FORGET so a slow arm never
// blocks the ingest loop; `enabledOps` is parsed from TELEGRAM_AUTO_ACTIONS (empty by
// default ⇒ inert). `authorize(from, chat_id)` is the SELF-SUFFICIENT auth check: the
// SENDER must be the allowlisted operator (global allowFrom) AND the chat must be
// allowlisted (a DM or an allowlisted group). This authorizes `/arm` from the operator
// in a DM or an allowlisted group (groups carry distinct per-group context), refuses a
// non-operator member of a shared group, and does NOT depend on the upstream ingest
// gate as the chat-scope check (defense-in-depth, CR S1). Wired only in main(); absent
// in unit tests that don't exercise /arm.
export type AutoFire = (msg: DeliveredMsg, route: Extract<Route, { kind: "auto" }>) => void;
export type AutoGate = { enabledOps: Set<string>; authorize: (from: number, chat_id: number) => boolean; fire: AutoFire };

// Single-threaded dispatch: the poller calls handleInbound serially, so the
// "status === running" in-flight check needs no atomic CAS.
export async function handleInbound(root: string, msg: DeliveredMsg, run: RunFn, auto?: AutoGate): Promise<void> {
  const route = classify(msg.text);
  // control verbs act directly; minimal handling for v2.2 (status/sessions/stop)
  if (route.kind === "control") {
    if (route.verb === "stop" && "ticket" in route) {
      await ensureSession(root, route.ticket);
      await appendLine(join(sessionDir(root, route.ticket), "stop"), String(msg.ts ?? 0));
    }
    return; // status/sessions reporting is wired in the main loop (replies via outbox)
  }
  // Auto-command (HIMMEL-424 B2): a message AUTHORIZED by auto.authorize(from, chat_id)
  // — the sender is the allowlisted operator (global allowFrom) AND the chat is
  // allowlisted (DM or allowlisted group); a non-operator member of a shared group is
  // refused (fix C1) — that is genuinely TYPED (caption===false — a media-caption/voice
  // /arm is refused, fix C2) and an ENABLED op is invoked DIRECTLY by the trusted bridge
  // — the agent never sees it. The forwarded-refuse decision lives in handleAutoCommand.
  // Any condition false ⇒ falls through to ordinary (powerless) chat below (so a
  // non-operator/caption/disabled-op /arm is just chat).
  if (route.kind === "auto" && auto && auto.authorize(msg.from, msg.chat_id) && msg.caption === false && auto.enabledOps.has(route.op)) {
    auto.fire(msg, route);
    return;
  }
  // Non-DM chats (negative chat_id = group/channel) get their own session keyed
  // by chat_id so meta.chat_id pins replies to that chat, not the operator DM
  // (HIMMEL-238). "_" not ":" — the session id is an NTFS directory name.
  const chatSession = msg.chat_id < 0 ? `group_${msg.chat_id}` : "__chat__";
  // A non-eligible auto-command (group / caption / disabled-op) routes as chat.
  const session = (route.kind === "chat" || route.kind === "auto") ? chatSession : route.ticket;
  const { created } = await ensureSession(root, session);
  let meta = await readMeta(root, session);
  if (created || !meta) {
    meta = { chat_id: msg.chat_id, status: "idle", last_run_pid: null, last_run_at: null,
             task_name: route.kind === "dispatch" ? route.ticket : null, retry_at: null };
    await writeMeta(root, session, meta);
  } else if (meta.status === "failed") {
    // a NEW operator message un-parks a retry-capped session (HIMMEL-263)
    meta = { ...meta, status: "idle", fail_count: null };
    await writeMeta(root, session, meta);
  }
  const line = route.kind === "followup" ? route.text : msg.text;
  await appendLine(join(sessionDir(root, session), "inbox.jsonl"), JSON.stringify({ text: line, from: msg.from, ts: msg.ts ?? 0, ...(msg.image_path ? { image_path: msg.image_path } : {}), ...(msg.document_path ? { document_path: msg.document_path, document_name: msg.document_name } : {}) }));
  if (meta.status === "idle" || meta.status === "done") await run(session);
}

// Map the auto-action.sh exit code to an audit result label.
function auditResult(rc: number): string {
  switch (rc) {
    case 0:  return "armed";
    case 3:  return "no-match";
    case 4:  return "ambiguous";
    case 5:  return "already-armed";
    default: return "error";
  }
}

export type AutoCommandDeps = {
  runScript: RunScriptFn;
  reply: (chat_id: number, text: string) => Promise<void>;
  audit: (f: AuditFields) => Promise<void>;
};

// The auto-command flow (HIMMEL-424 B2). Run FIRE-AND-FORGET off the ingest loop (via
// the gate's `fire`) so a slow `--time smart` arm can't stall polling. A FORWARDED /arm
// is refused + audited (the injection kill-switch — `root` reserved for future use);
// otherwise the bridge invokes auto-action.sh and relays the result. Every attempt —
// executed OR refused — is audited.
export async function handleAutoCommand(root: string, msg: DeliveredMsg, route: Extract<Route, { kind: "auto" }>, deps: AutoCommandDeps): Promise<void> {
  void root;
  // The AUDIT is the security event and is written FIRST; the operator reply is
  // best-effort and must NEVER swallow the audit (CR I1: a reply-delivery failure
  // after a successful privileged arm would otherwise leave no durable record).
  const reply = async (text: string) => {
    try { await deps.reply(msg.chat_id, text); }
    catch (e) { console.error(`[poller] auto-action reply could not be delivered for chat ${msg.chat_id}: ${e}`); }
  };
  if (msg.forwarded === true) {
    await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: true, op: route.op, arg: route.arg, time: route.time, rc: -1, result: "refused-forwarded" });
    await reply("⚠️ forwarded commands are not executed");
    return;
  }
  const res = await dispatchAutoAction({ runScript: deps.runScript }, route);
  await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, resolved: res.resolved, time: route.time, rc: res.rc, result: auditResult(res.rc) });
  await reply(res.message);
}

// tail: last chunk of the run's stdout+stderr (HIMMEL-262) — persisted to run.log
// blocked: the run failed because the API blocked the model's OUTPUT under the
// content-filtering policy (deterministic — retrying replays the same block).
export type RunResult = { code: number; capped: boolean; blocked?: boolean; timedOut?: boolean; pid: number; tail?: string };
export type Runner = () => Promise<RunResult>;
export type NowFn = () => string;   // ISO timestamp (injected for tests / resume-slot in prod)

// Run one bounded session run and settle meta. Three outcomes:
//   * BLOCKED (content-filter, HIMMEL-313) -> park status=failed directly, no retry_at,
//     fail_count cleared. The block is deterministic (every retry replays the same blocked
//     output), so it parks immediately as "failed" in ONE settle write — it never transits
//     the transient "capped" back-off (which would mislabel it + invite the pointless retry
//     loop). A NEW operator message un-parks it via handleInbound's failed->idle reset.
//   * UNsuccessful, not blocked (cap OR non-zero exit, incl. timeout=-1 / crash) -> back
//     off: status=capped + retry_at. Treating any non-zero exit like a cap is what keeps the
//     message durable — the caller commits the inbox cursor only on a successful run, so a
//     crashed/timed-out run leaves it uncommitted and `deliverAllPending` re-runs the same
//     pending at retry_at instead of dropping it (the "capped" status doubles as the generic
//     back-off state). (Re-running on still-queued inbox is the MAIN LOOP's job, not here.)
//   * Successful (clean exit, no cap, no block) -> idle.
// `retryAt` defaults to `now` (a pure settle timestamp for tests); prod passes now + RETRY_MS
// so an unsuccessful run backs off instead of re-spawning immediately.
export async function runAndSettle(root: string, session: string, run: Runner, now: NowFn = () => new Date().toISOString(), retryAt: NowFn = now): Promise<RunResult> {
  let meta = await readMeta(root, session);
  if (!meta) return run();   // defensive; shouldn't happen (session created before RUN)
  meta = { ...meta, status: "running", last_run_at: now() };
  await writeMeta(root, session, meta);
  const res = await run();
  const unsuccessful = res.capped || res.code !== 0;
  if (res.blocked)       meta = { ...meta, status: "failed", retry_at: null, fail_count: null, last_run_pid: res.pid };
  else if (unsuccessful) meta = { ...meta, status: "capped", retry_at: retryAt(), last_run_pid: res.pid };
  else                   meta = { ...meta, status: "idle", retry_at: null, last_run_pid: null };
  await writeMeta(root, session, meta);
  return res;
}

export type SendFn = (chat_id: number, text: string) => Promise<void>;

// Send-then-commit: send each complete outbox line, advance the byte-cursor only
// AFTER the send resolves (at-least-once on crash). Per-chat throttle is the caller's job.
export async function flushOutboxes(root: string, send: SendFn): Promise<void> {
  let names: string[] = [];
  try { names = await readdir(join(root, "sessions")); } catch { return; }
  for (const s of names) {
    try {
      const meta = await readMeta(root, s);
      if (!meta) continue;
      const file = join(sessionDir(root, s), "outbox.jsonl");
      const curFile = file + ".cursor";
      let start = 0; try { start = Number(await readFile(curFile, "utf8")) || 0; } catch {}
      let buf = ""; try { buf = await readFile(file, "utf8"); } catch { continue; }
      if (start >= Buffer.byteLength(buf, "utf8")) { await truncateFullyConsumed(file, curFile); continue; }   // fully sent → reclaim (HIMMEL-221)
      const slice = Buffer.from(buf, "utf8").subarray(start).toString("utf8");
      const lastNl = slice.lastIndexOf("\n");
      if (lastNl < 0) continue;
      const complete = slice.slice(0, lastNl);
      let pos = start;
      for (const ln of complete.split("\n")) {
        const bytes = Buffer.byteLength(ln + "\n", "utf8");
        if (ln.trim()) {
          let text: string | null = null;
          try { text = JSON.parse(ln).text ?? ""; } catch { text = null; }
          if (text !== null) { await send(meta.chat_id, text); }   // send BEFORE committing
        }
        pos += bytes;
        await atomicWrite(curFile, String(pos));                    // commit after this line
      }
    } catch (e) { console.error("[poller] flush failed for " + s + ": " + e); continue; }
  }
}

// On poller start: any session marked running whose pid is dead -> reset to idle so it can re-RUN.
export async function reconcile(root: string, isAlive: (pid: number) => boolean): Promise<void> {
  const dir = join(root, "sessions");
  let names: string[] = [];
  try { names = await readdir(dir); } catch { return; }
  for (const s of names) {
    const m = await readMeta(root, s);
    if (m && m.status === "running" && (m.last_run_pid == null || !isAlive(m.last_run_pid))) {
      await writeMeta(root, s, { ...m, status: "idle", last_run_pid: null });
    }
  }
}

// Overlap guard: drops a call if a prior invocation is still in flight.
// Ensures at-most-one concurrent execution; errors are logged so a reject can't wedge the flag.
export function guarded(task: () => Promise<void>): () => void {
  let inFlight = false;
  return () => {
    if (inFlight) return;   // drop overlapping call
    inFlight = true;
    task().catch((e) => { console.error("[poller] guarded task failed: " + e); }).finally(() => { inFlight = false; });
  };
}

// Per-tick delivery scan: for every session, run any pending inbox lines via
// runFn — telegram backlog, IPC bus-send (T6), or a due-capped retry. A capped
// session is SKIPPED until its retry_at passes, so the cap backoff holds;
// every other session is run (runFn no-ops when nothing is pending).
export async function deliverAllPending(root: string, runFn: RunFn, now: Date, sessions: () => Promise<string[]>): Promise<void> {
  for (const s of await sessions()) {
    const m = await readMeta(root, s);
    if (!m) continue;
    if (m.status === "capped" && !isRetryDue(m, now)) continue;
    if (m.status === "failed") continue;   // retry cap exhausted (HIMMEL-263) — only a new message un-parks
    await runFn(s);
  }
}

// Pure: a capped session is due for retry once its retry_at timestamp has passed.
export function isRetryDue(meta: Meta, now: Date): boolean {
  return meta.status === "capped" && !!meta.retry_at && new Date(meta.retry_at).getTime() <= now.getTime();
}

const isAlive = (pid: number) => { try { process.kill(pid, 0); return true; } catch { return false; } };

// Peek-then-commit for inbox consumption (mirrors the outbox send-then-commit).
// peekPending writes the new (unconsumed) inbox lines into a fresh inbox.pending.jsonl
// the run will read, WITHOUT advancing the consumed cursor, and returns the count plus
// the byte position to commit. A capped/failed run that never commits can re-peek the
// SAME pending instead of losing it. Poller-owned cursor: inbox.jsonl.consumed.
export async function peekPending(root: string, session: string): Promise<{ count: number; nextPos: number }> {
  const sd = sessionDir(root, session);
  const inbox = join(sd, "inbox.jsonl");
  const curFile = inbox + ".consumed";
  const pendingFile = join(sd, "inbox.pending.jsonl");
  let start = 0; try { start = Number(await readFile(curFile, "utf8")) || 0; } catch {}
  let buf = ""; try { buf = await readFile(inbox, "utf8"); } catch { await atomicWrite(pendingFile, ""); return { count: 0, nextPos: start }; }
  if (start >= Buffer.byteLength(buf, "utf8")) { await atomicWrite(pendingFile, ""); return { count: 0, nextPos: start }; }
  const slice = Buffer.from(buf, "utf8").subarray(start).toString("utf8");
  const lastNl = slice.lastIndexOf("\n");
  if (lastNl < 0) { await atomicWrite(pendingFile, ""); return { count: 0, nextPos: start }; }
  const complete = slice.slice(0, lastNl);
  const nextPos = start + Buffer.byteLength(complete + "\n", "utf8");
  const lines = complete.split("\n").filter((l) => l.trim());
  await atomicWrite(pendingFile, lines.join("\n") + (lines.length ? "\n" : ""));
  return { count: lines.length, nextPos };
}

// Commit the consumed cursor AFTER a clean run, so the peeked pending is now consumed.
export async function commitPending(root: string, session: string, nextPos: number): Promise<void> {
  await atomicWrite(join(sessionDir(root, session), "inbox.jsonl.consumed"), String(nextPos));
}

// Build the runFn the poller uses to spawn a bounded COLD `claude` run per session and
// settle it (HIMMEL-226 — reverts the HIMMEL-222 warm stdin-pipe primitive, which never
// drove a turn: interactive `claude` only processes + replies at EOF, never on a newline
// written to a still-open stdin pipe). Each run reads ONLY the pending slice
// (peekPending's inbox.pending.jsonl), never the whole inbox; stdin is closed (EOF) so the
// child does one turn, appends its reply to outbox.jsonl, and exits. buildPrompt passes
// context.md so a cold reply still carries prior-turn continuity. The consumed cursor
// commits ONLY after a SUCCESSFUL run (clean exit, no cap); an unsuccessful run (cap OR
// non-zero exit / timeout / crash) does NOT commit, so the retry loop re-peeks the SAME
// pending and reprocesses it instead of losing those messages. After a successful run,
// drain by re-running — terminates when peekPending returns 0 (then reclaims the
// fully-consumed inbox, HIMMEL-221). runImpl is injected so the spawn/settle/commit logic
// is unit-testable without launching a real claude.
// Hard deadline wrapper (HIMMEL-246). runSession's own 30-min timer used to fail
// to settle (bare p.kill() leaves the claude tree alive on Windows → p.exited
// never resolves → session stuck "running" — observed live 2026-06-10, DM wedged
// ~1.5h). The PRIMARY fix is run.ts killTree (taskkill /T on timeout); this race
// is the settle BACKSTOP: a hung OR throwing runImpl resolves unsuccessful
// (code -1) at the deadline so runAndSettle backs the session off (capped +
// retry_at) and the pending stays uncommitted. Residual window (CR HIMMEL-246):
// if BOTH the tree-kill and the child's exit fail, an orphan could overlap the
// post-retry_at re-run of the same session — accepted: taskkill /T /F makes that
// double failure remote, and the overlap is bounded to one stale outbox append.
const FAILED_RUN: RunResult = { code: -1, capped: false, blocked: false, pid: -1 };
export function withDeadline(p: Promise<RunResult>, ms: number): Promise<RunResult> {
  return new Promise((resolve) => {
    // no unref: bun's unref'd timers can fail to fire (hung `bun test` observed);
    // the timer is always cleared when the run settles, so it never holds the loop
    const t = setTimeout(() => resolve(FAILED_RUN), ms);
    p.then((r) => { clearTimeout(t); resolve(r); },
           (e) => { clearTimeout(t); console.error("[poller] run rejected: " + e); resolve(FAILED_RUN); });
  });
}

// Default deadline: the child's own timeout + a minute of grace for clean settle.
const RUN_DEADLINE_MS = Number(process.env.RUN_TIMEOUT_MS ?? 30 * 60 * 1000) + 60 * 1000;

// notify (HIMMEL-260/263): called once per BACKOFF EPISODE when a run settles
// unsuccessful — kind "cap" for a genuine usage cap (CAP_SENTINELS in run.ts),
// kind "transient" for any other non-zero exit (server overload, timeout, crash)
// — and with kind "giveup" once when the retry cap parks the session. The
// cap/transient split keeps the notice honest: a 529 Overloaded must not read as
// a quota cap (HIMMEL-261/263/313 family — transient mislabeled as cap). main
// wires it to a direct poller-side sendMessage so the chat is told instead of
// going silent. A clean run ends the episode. The episode set is in-memory: a
// bridge restart may re-notice once — harmless.
export type NotifyKind = "cap" | "transient" | "giveup" | "blocked";
export type NotifyFn = (session: string, retryAt: string, kind: NotifyKind) => Promise<void>;
// noticeText (HIMMEL-353): the operator-facing notice string per kind. Pure +
// exported so the cap-vs-transient honesty (a 529 must say "NOT a usage cap",
// never the cap wording) is unit-testable, and the `never` default makes a new
// kind that forgets its notice a COMPILE error — not a silent transient mislabel
// (the very class HIMMEL-261/263/313 exists to kill). `when` is the pre-rendered
// retry time; `maxRetries` only used by the giveup wording.
export function noticeText(kind: NotifyKind, when: string, maxRetries: number): string {
  switch (kind) {
    case "giveup":    return `❌ gave up after ${maxRetries} failed runs — your message is still queued. Reply here to retry, or handle it from the terminal (see run.log in the session dir).`;
    case "blocked":   return `⛔ a reply was blocked by the content-filter policy (this is NOT a usage cap). Retrying won't help — the same output is blocked each time. Your message is still queued; investigate from the terminal (see run.log in the session dir).`;
    case "cap":       return `⏳ hit the usage cap — your message is queued, retrying ~${when}.`;
    case "transient": return `⏳ a run failed transiently (e.g. server overload) — your message is queued, retrying ~${when}. This is NOT a usage cap.`;
    default:          return ((_: never) => { throw new Error(`unhandled notify kind: ${String(_)}`); })(kind);
  }
}
// Retry cap (HIMMEL-263): a shipping-class ask that exceeds the bounded-run
// deadline would otherwise loop forever (kill → 15-min backoff → re-peek the
// SAME pending → restart from scratch — observed live: "ship 241+249" died at
// the 30-min deadline repeatedly). After maxRetries consecutive failures the
// session parks as status=failed: deliverAllPending stops offering it; the
// pending stays uncommitted (nothing lost); a NEW operator message un-parks it
// (handleInbound resets fail_count) — the operator decides retry vs terminal.
const MAX_RETRIES = Number(process.env.TELEGRAM_MAX_RETRIES ?? 3);
// vaultFor (HIMMEL-321): resolves the Obsidian-vault path a session's documents
// are filed into, from its meta.chat_id (gate.vaultForChat over loaded access).
// Optional — when absent or it returns null, the prompt carries no file-into-vault clause.
export type VaultForFn = (chatId: number) => string | null;
export function makeRunFn(root: string, repoCwd: string, runImpl: (prompt: string, cwd: string, permissionMode?: PermissionMode) => Promise<RunResult> = runSession, deadlineMs: number = RUN_DEADLINE_MS, notify?: NotifyFn, maxRetries: number = MAX_RETRIES, vaultFor?: VaultForFn): RunFn {
  const retryAt = () => new Date(Date.now() + RETRY_MS).toISOString();
  const noticed = new Set<string>();
  const safeNotify = async (session: string, retryAtIso: string, kind: NotifyKind) => {
    if (!notify) return;
    try { await notify(session, retryAtIso, kind); }
    catch (e) { console.error("[poller] " + kind + " notify failed for " + session + ": " + e); }
  };
  const runOnce = async (session: string): Promise<void> => {
    const sd = sessionDir(root, session);
    const parked = await readMeta(root, session);
    if (parked?.status === "failed") return;                    // retry cap exhausted — wait for a new message
    const { count, nextPos } = await peekPending(root, session);
    if (count === 0) {                                          // inbox fully consumed → reclaim (HIMMEL-221)
      const inbox = join(sd, "inbox.jsonl");
      await truncateFullyConsumed(inbox, inbox + ".consumed");
      return;
    }
    // `|| null` normalizes a falsy vault ("" from a blank access.json `vault:`) to
    // null, so the nullish-coalescing `?? repoCwd` below stays coherent with the
    // truthy `vault ?` checks (an empty string would otherwise spawn in cwd "" with
    // no bypass and no file-into-vault clause — an incoherent posture).
    const vault = (vaultFor && parked ? vaultFor(parked.chat_id) : null) || null;
    // HIMMEL-578: spawn the session in the chat's vault cwd when one is configured,
    // so the vault's own .claude/hooks load (e.g. a medical PHI-egress floor). The
    // Jira-CLI path stays on repoCwd (himmel) — `dist/` only exists there. Vault
    // sessions get bypassPermissions because himmel's auto-approve hook isn't loaded
    // under the vault cwd; the vault's hooks still enforce containment.
    const sessionCwd = vault ?? repoCwd;
    const permissionMode = vault ? "bypassPermissions" : undefined;
    const paths: BusPaths = { inbox: join(sd, "inbox.pending.jsonl"), outbox: join(sd, "outbox.jsonl"), context: join(sd, "context.md"), cwd: repoCwd, sessionCwd };
    const res = await runAndSettle(root, session, () => withDeadline(runImpl(buildPrompt(session, paths, vault), sessionCwd, permissionMode), deadlineMs), undefined, retryAt);
    // run.log (HIMMEL-262): persist the run's output tail — before this, a dead
    // run's stdout/stderr vanished and failures were undebuggable
    const logHead = `[${new Date().toISOString()}] session=${session} code=${res.code} capped=${res.capped} blocked=${res.blocked ?? false} pid=${res.pid}\n`;
    await atomicWrite(join(sd, "run.log"), logHead + (res.tail ?? "(no output captured — run hung or was killed at the deadline)") + "\n");
    if (res.blocked) {
      // Content-filter block (HIMMEL-313): runAndSettle already parked this run as
      // "failed" directly (never transiting the transient "capped" back-off, so no
      // pointless MAX_RETRIES climb). Here we only end the backoff episode + send an
      // ACCURATE notice. The pending stays uncommitted (re-peekable); a NEW operator
      // message un-parks it via handleInbound's failed→idle reset, like the retry-cap park.
      noticed.delete(session);
      await safeNotify(session, "", "blocked");
      return;
    }
    if (res.code === 0 && !res.capped) {
      noticed.delete(session);                                  // clean run ends the backoff episode
      const m = await readMeta(root, session);
      if (m?.fail_count) await writeMeta(root, session, { ...m, fail_count: null });
      await commitPending(root, session, nextPos); await runOnce(session);
      return;
    }
    // unsuccessful (cap OR non-zero exit / timeout / crash) → do NOT commit; the
    // pending stays re-peekable. Count the failure; park at the cap.
    const m = await readMeta(root, session);
    if (!m) return;
    const fails = (m.fail_count ?? 0) + 1;
    if (fails >= maxRetries) {
      // CR HIMMEL-263: a message that arrived DURING this final failing run must
      // not be stranded under the park — re-peek; growth = the operator spoke,
      // treat it as an un-park (same semantics as handleInbound's failed reset)
      const again = await peekPending(root, session);
      if (again.count > count) {
        await writeMeta(root, session, { ...m, status: "idle", fail_count: null });
        noticed.delete(session);
        return;
      }
      await writeMeta(root, session, { ...m, status: "failed", fail_count: fails, retry_at: null });
      noticed.delete(session);                                  // episode bookkeeping follows the persisted reset
      await safeNotify(session, "", "giveup");
    } else {
      await writeMeta(root, session, { ...m, fail_count: fails });
      if (!noticed.has(session)) {                              // first failure of an episode → tell the chat
        noticed.add(session);
        // genuine cap vs generic transient failure (529, timeout, crash) — keep the notice honest
        await safeNotify(session, m.retry_at ?? "", res.capped ? "cap" : "transient");
      }
    }
  };
  return runOnce;
}

// Typing signal (HIMMEL-260): for every session currently in flight, fire the
// injected action with its chat_id (main wires sendChatAction). Runs on its own
// short timer so the chat shows "typing…" while a bounded child works.
export async function signalTyping(root: string, isInFlight: (s: string) => boolean, sessions: () => Promise<string[]>, action: (chat_id: number) => Promise<void>): Promise<void> {
  for (const s of await sessions()) {
    if (!isInFlight(s)) continue;
    const m = await readMeta(root, s);
    if (m) { try { await action(m.chat_id); } catch {} }
  }
}

// --- Concurrent per-session dispatch (HIMMEL-246) ---
// The main loop used to AWAIT every bounded run inline, so one long run blocked
// getUpdates ingest and every other session. The dispatcher fires runs without
// the caller awaiting them: per-session serialization via an in-memory in-flight
// set (the CAS the single-threaded loop relied on), plus a global cap so
// concurrent claude children can't burn the Max quota in parallel. An over-cap
// or overlapping dispatch is a NO-OP — deliverAllPending re-offers every pending
// session each tick, so deferred sessions are picked up when a slot frees.
export type Dispatcher = RunFn & { inFlightCount: () => number; isInFlight: (s: string) => boolean };
export function makeDispatcher(runFn: RunFn, cap: number = Number(process.env.TELEGRAM_MAX_CONCURRENT_RUNS ?? 2)): Dispatcher {
  const inFlight = new Set<string>();
  const dispatch = (async (session: string): Promise<void> => {
    if (inFlight.has(session)) return;            // per-session serialization
    if (inFlight.size >= cap) return;             // cap reached — next tick retries
    inFlight.add(session);
    runFn(session)
      .catch((e) => { console.error("[poller] dispatched run failed for " + session + ": " + e); })
      .finally(() => { inFlight.delete(session); });
  }) as Dispatcher;
  dispatch.inFlightCount = () => inFlight.size;
  dispatch.isInFlight = (s: string) => inFlight.has(s);
  return dispatch;
}

// In-loop watchdog (HIMMEL-246): a session stuck status=running that THIS poller
// is not actually running (crashed previous incarnation, or a settle that never
// happened) is reset to idle so deliverAllPending can re-run its pending — no
// bridge restart needed. The in-memory in-flight set is the liveness truth;
// startup reconcile() (pid-based) still covers the cross-process cold start.
export async function sweepStuckRunning(root: string, isInFlight: (s: string) => boolean, sessions: () => Promise<string[]>): Promise<void> {
  for (const s of await sessions()) {
    if (isInFlight(s)) continue;
    const m = await readMeta(root, s);
    if (m && m.status === "running") await writeMeta(root, s, { ...m, status: "idle", last_run_pid: null });
  }
}

// Default retention window: 7 days. Long enough to never delete an in-flight
// (unconsumed) attachment — unprocessed messages are retried within minutes —
// while bounding disk growth to ~0.5-1 GB/year at moderate photo+voice volume.
// Only a finite POSITIVE number overrides the default: empty string and NaN
// fall through, and a negative value would flip the cutoff into the future
// (sweeping everything) while Math.min would turn the daily timer into a
// tight loop — so it must be rejected here, not downstream.
export function resolveRetentionMs(raw: string | undefined): number {
  const n = Number(raw);
  return Number.isFinite(n) && n > 0 ? n : 7 * 24 * 60 * 60 * 1000;
}
export const ATTACHMENT_RETENTION_MS = resolveRetentionMs(process.env.TELEGRAM_ATTACHMENT_RETENTION_MS);

// Age-based GC for the attachments/ directory (HIMMEL-267).
// Deletes files whose mtime is older than `maxAgeMs`. Only files at the
// top level of `dir` are swept — no subdirectories. Errors on individual
// files are logged and skipped so a single bad entry never aborts the sweep.
export async function sweepAttachments(dir: string, maxAgeMs: number = ATTACHMENT_RETENTION_MS): Promise<number> {
  let entries: string[];
  try { entries = await readdir(dir); } catch { return 0; }   // dir absent → nothing to sweep
  const cutoff = Date.now() - maxAgeMs;
  let removed = 0;
  for (const name of entries) {
    const p = join(dir, name);
    try {
      const s = await stat(p);
      if (!s.isFile()) continue;
      if (s.mtimeMs < cutoff) { await unlink(p); removed++; }
    } catch (e) { console.error(`[poller] sweep: skipped ${p}: ${e}`); }
  }
  return removed;
}

async function loadToken(): Promise<string> {
  const envPath = process.env.TELEGRAM_ENV ?? join(homedir(), ".claude", "channels", "telegram", ".env");
  const txt = await readFile(envPath, "utf8");
  const m = txt.match(/^TELEGRAM_BOT_TOKEN\s*=\s*(.+)$/m);
  if (!m) throw new Error("TELEGRAM_BOT_TOKEN not found in " + envPath);
  return m[1].trim();
}

async function sessionsList(root: string): Promise<string[]> {
  try { return await readdir(join(root, "sessions")); } catch { return []; }
}

// Reply via the originating chat's outbox (HIMMEL-424): consistent with every other
// operator-facing message in the bridge (send-then-commit durability + per-chat throttle
// via flushOutboxes), and — unlike a direct sendMessage in the ingest loop — it does not
// block polling. Routes to the SAME session the chat uses (group_<id> for a group, so a
// group `/arm` reply lands in that group and its per-group context is preserved;
// __chat__ for a DM) — mirrors handleInbound's chatSession routing.
export async function replyViaOutbox(root: string, chat_id: number, text: string): Promise<void> {
  const session = chat_id < 0 ? `group_${chat_id}` : "__chat__";
  const { created } = await ensureSession(root, session);
  const meta = await readMeta(root, session);
  if (created || !meta) {
    await writeMeta(root, session, { chat_id, status: "idle", last_run_pid: null, last_run_at: null, task_name: null, retry_at: null });
  }
  await appendLine(join(sessionDir(root, session), "outbox.jsonl"), JSON.stringify({ text }));
}

export async function main(): Promise<void> {
  const root = bridgeRoot();
  const repoCwd = process.env.HIMMEL_REPO ?? process.cwd();
  const token = await loadToken();
  const access = await loadAccess();
  const allow = makeAllow(access);
  // cap/transient/giveup/blocked notice (HIMMEL-260/263/353): poller-side direct
  // send — works exactly when the claude layer can't run (quota cap), so failure
  // is never silent. Text per kind lives in the exported pure noticeText().
  const notify: NotifyFn = async (session, retryAt, kind) => {
    const m = await readMeta(root, session);
    if (!m) return;
    const when = retryAt ? retryAt.slice(11, 16) + " UTC" : "soon";
    await sendMessage(token, m.chat_id, noticeText(kind, when, MAX_RETRIES));
  };
  // documents sent to a chat are filed into the vault resolved from access.json (HIMMEL-321)
  const vaultFor: VaultForFn = (chatId) => vaultForChat(access, chatId);
  const runFn = makeRunFn(root, repoCwd, undefined, undefined, notify, undefined, vaultFor);
  const dispatch = makeDispatcher(runFn);
  await reconcile(root, isAlive);
  // photo downloads land in a shared root-level attachments/ (named by update_id —
  // unique + dedup-stable); the session is only routed later, in handleInbound
  const attachmentsDir = join(root, "attachments");
  // Attachments GC (HIMMEL-267): sweep on startup, then once per day.
  // Age-based (default 7 days) so in-flight attachments are never touched.
  const sweepFn = () => sweepAttachments(attachmentsDir).then((n) => { if (n > 0) console.error(`[poller] sweep: removed ${n} expired attachment(s)`); }).catch((e) => console.error(`[poller] sweep failed: ${e}`));
  void sweepFn();
  const sweepTimer = setInterval(sweepFn, Math.min(ATTACHMENT_RETENTION_MS, 24 * 60 * 60 * 1000));
  if (typeof sweepTimer.unref === "function") sweepTimer.unref();
  const fetchImage: FetchImageFn = async (file_id, update_id) => {
    const fp = await getFile(token, file_id);
    if (!fp) return null;
    await mkdir(attachmentsDir, { recursive: true });
    const dest = join(attachmentsDir, `${update_id}${safeExt(fp)}`);
    return (await downloadFile(token, fp, dest)) ? dest : null;
  };
  // voice → download + whisper.cpp transcript (HIMMEL-251). Every failure path
  // replies an explicit error to the chat — acceptance: never a silent drop.
  const fetchVoice = makeFetchVoice({
    getFile: (id) => getFile(token, id),
    download: (fp, dest) => downloadFile(token, fp, dest),
    transcribe,
    sendFail: (chat) => sendMessage(token, chat, "⚠️ couldn't transcribe your voice note — try again or send it as text."),
    attachmentsDir,
  });
  // document/PDF download (HIMMEL-321). Mirrors fetchImage, but preserves the
  // original filename's extension (so the Read tool detects PDFs) — the
  // server-side file_path is the fallback. Telegram getFile caps at ~20MB; a
  // larger file resolves null here and degrades to caption-only forwarding.
  const fetchDoc: FetchDocFn = async (file_id, update_id, file_name) => {
    const fp = await getFile(token, file_id);
    if (!fp) return null;
    await mkdir(attachmentsDir, { recursive: true });
    const dest = join(attachmentsDir, `${update_id}${safeExt(file_name, safeExt(fp, ".pdf"))}`);
    return (await downloadFile(token, fp, dest)) ? dest : null;
  };
  // never-a-silent-drop notice for a document we couldn't download (HIMMEL-321).
  // "may exceed" — fetchDoc returns null identically for the ~20MB getFile cap, a
  // 4xx, or a timeout, so the notice can't assert a single cause.
  const notifyDocFail: NotifyDocFailFn = async (chatId, name) => {
    await sendMessage(token, chatId, `⚠️ couldn't download "${name}" (it may exceed Telegram's ~20MB limit) — I forwarded your caption only.`);
  };
  const send = async (chat: number, text: string) => { await sendMessage(token, chat, text); };
  // Remote auto-actions (HIMMEL-424 B2): the trusted bridge parses a structured `/arm`
  // and invokes auto-action.sh DIRECTLY — the agent is never in the trust path. Inert
  // unless TELEGRAM_AUTO_ACTIONS enables an op (default OFF). `runScript` spawns the
  // privileged script argv-array (no shell string — fix I2) with cwd=repoCwd. The child
  // INHERITS the full bridge env BY DESIGN ("inherit the system" — the operator
  // requirement): arm-resume.sh needs .env/HANDOVER_DIR/PATH/py-armor, and anticipated
  // future ops need more (file-ticket → Jira token, run-named-skill → ANTHROPIC) — so a
  // secret denylist is wrong here. The env is NOT an attacker surface: the child is
  // himmel's own trusted script and the /arm arg is passed as validated positional args,
  // never into env. We strip only TELEGRAM_BOT_TOKEN (+ TELEGRAM_OWN_POLLER) — the one
  // credential the arm path demonstrably never needs (fix M3). The arm runs
  // FIRE-AND-FORGET (autoFire) so a slow `--time smart` arm never stalls the ingest loop.
  const enabledOps = parseEnabledOps(process.env.TELEGRAM_AUTO_ACTIONS, KNOWN_OPS);
  if (enabledOps.size > 0) console.error(`[poller] auto-actions enabled: ${[...enabledOps].join(",")}`);
  const autoScript = join(import.meta.dir, "auto-action.sh");
  const runScript: RunScriptFn = async (op, arg, time) => {
    const env: Record<string, string> = { ...process.env } as Record<string, string>;
    delete env.TELEGRAM_BOT_TOKEN;
    delete env.TELEGRAM_OWN_POLLER;
    const p = Bun.spawn(["bash", autoScript, op, arg, time], { cwd: repoCwd, env, stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, code] = await Promise.all([
      new Response(p.stdout).text(),
      new Response(p.stderr).text(),
      p.exited,
    ]);
    return { code, stdout, stderr };
  };
  const auditFn = appendAuditLine(root);
  const autoFire: AutoFire = (msg, route) => {
    void handleAutoCommand(root, msg, route, { runScript, reply: (chat, text) => replyViaOutbox(root, chat, text), audit: auditFn })
      .catch((e) => console.error(`[poller] auto-action failed for op ${route.op}: ${e}`));
  };
  // authorize = operator-identity (global allowFrom) AND chat-allowlisted (makeAllow):
  // the operator in a DM or an allowlisted group arms; a non-operator group member or a
  // non-allowlisted chat is refused. Self-sufficient — re-asserts the chat gate (CR S1).
  const autoGate: AutoGate = { enabledOps, authorize: (from, chat_id) => isAllowed(access, from) && allow(from, chat_id), fire: autoFire };
  // typing indicator while a session's bounded child works (HIMMEL-260)
  const TYPING_MS = Number(process.env.TELEGRAM_TYPING_MS ?? 4000);
  const typingTimer = setInterval(guarded(() => signalTyping(root, dispatch.isInFlight, () => sessionsList(root), (chat) => sendChatAction(token, chat))), TYPING_MS);
  if (typeof typingTimer.unref === "function") typingTimer.unref();
  // Flush outboxes on an independent ~1s timer so a bounded run's reply lands without
  // waiting up to 30s for the next long-poll to complete (T4). A cold child is a separate
  // process that appends to outbox.jsonl as it works, so the concurrent flush still earns
  // its keep. The flush path touches only outbox files; the run path touches only
  // inbox/meta/pending — disjoint, so the timer adds no shared-file race.
  const FLUSH_MS = Number(process.env.TELEGRAM_FLUSH_MS ?? 1000);
  const flushTimer = setInterval(guarded(() => flushOutboxes(root, send)), FLUSH_MS);
  if (typeof flushTimer.unref === "function") flushTimer.unref();
  for (;;) {
    const offset = await loadOffset(root);
    let updates: any[] = [];
    try { updates = await getUpdates(token, offset, 30); } catch (e) { console.error("[poller] getUpdates failed: " + e); await Bun.sleep(1000); continue; }
    await ingestUpdates(root, updates, allow, fetchImage, fetchVoice, fetchDoc, notifyDocFail);
    const fresh = await readNewLines(join(root, "inbound.jsonl"), join(root, "inbound.jsonl.cursor"));
    // dispatch (not runFn) everywhere: runs fire WITHOUT blocking this loop —
    // ingest keeps polling while bounded children work (HIMMEL-246)
    for (const i of fresh) await handleInbound(root, { from: i.from, chat_id: i.chat_id, text: i.text, ts: i.ts, forwarded: i.forwarded, caption: i.caption, image_path: i.image_path, document_path: i.document_path, document_name: i.document_name }, dispatch, autoGate);
    await deliverAllPending(root, dispatch, new Date(), () => sessionsList(root));
    await sweepStuckRunning(root, dispatch.isInFlight, () => sessionsList(root));
  }
}

if (import.meta.main) await main();
