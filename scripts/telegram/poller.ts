import { readFile, writeFile, rename, mkdir, readdir, unlink, stat } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";
import { appendLine, atomicWrite, bridgeRoot, ensureSession, readMeta, writeMeta, sessionDir, readNewLines, truncateFullyConsumed, type Meta } from "./bus";
import { classify, type Route } from "./router";
import { dispatchAutoAction, describeEnabledOps, KNOWN_OPS, appendAuditLine, type RunScriptFn, type AuditFields } from "./auto-action";
import { getUpdates, sendMessage, sendChatAction, getFile, downloadFile } from "./telegram-api";
import { isAllowed, isGroupAllowed, loadAccess, vaultForChat, type Access } from "./gate";
import { runSession, buildPrompt, BASH_BIN, type BusPaths, type PermissionMode } from "./run";
import { classifyForSpawn, type TriageVerdict, type TriageModelOverride } from "./triage";
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
export type RunFn = (session: string, modelOverride?: TriageModelOverride) => Promise<void>;
export type TriageFn = (text: string, sessionLabel?: string) => Promise<TriageVerdict>;

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
export async function handleInbound(root: string, msg: DeliveredMsg, run: RunFn, auto?: AutoGate, triage: TriageFn = (text, sessionLabel) => classifyForSpawn(text, { sessionLabel })): Promise<void> {
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
  // CHEAP TRIAGE GATE (HIMMEL-721) — runs BEFORE the message is enqueued. The
  // session id is a pure derivation (above), so the gate needs no session I/O.
  // On ignore/ack the message is DROPPED PERMANENTLY: nothing is written to
  // inbox.jsonl, the consumed cursor never moves, and a later deliverAllPending
  // has nothing to resurrect — triage is truthful rather than a no-op (the prior
  // order appended the line first, so the main loop's unconditional
  // deliverAllPending re-spawned the "ignored" chatter in the same poll tick).
  // Deliberate tradeoff: chatter triaged away is dropped, not delayed; a crash
  // mid-triage loses only that one piece of chatter, and the classifier is
  // fail-open (any error → spawn-high) so a real failure still enqueues + spawns.
  let modelOverride: TriageModelOverride | undefined;
  if (msg.chat_id < 0 && (route.kind === "chat" || route.kind === "auto") && process.env.TELEGRAM_TRIAGE !== "off") {
    const verdict = await triage(msg.text, session);
    switch (verdict) {
      case "ignore":
      case "ack":
        console.error(`[poller] triage ${verdict}: dropped (never enqueued) for ${session}`);
        return;
      case "spawn-low":
        modelOverride = "haiku";
        break;
      case "spawn-high":
        break;
      // exhaustive (mirrors noticeText): a future 5th verdict is a compile error,
      // not a silent fall-through that spawns untriaged.
      default:
        return ((_: never) => { throw new Error(`unhandled triage verdict: ${String(_)}`); })(verdict);
    }
  }
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
  if (meta.status === "idle" || meta.status === "done") await run(session, modelOverride);
}

// Map the auto-action.sh exit code to an audit result label. OP-AWARE
// (HIMMEL-1213 codex-adv): merge-public relays merge-public-on-green.sh's OWN rc
// space (0=merged, 12=no-open-pr, 15=head-moved, 16=not-green), which is disjoint
// from arm-resume's — so an irreversible successful public merge is logged as
// `merged`, not the arm-specific `armed`, and its refusal states keep their
// meaning for forensic/result-keyed queries.
function auditResult(op: string, rc: number): string {
  // restart (HIMMEL-1272) has its own two-value space: it either got far enough to
  // fire (0) or it did not. There is no "succeeded" beyond that — by the time a
  // restart has actually happened this process is gone and cannot log anything.
  if (op === "restart") {
    switch (rc) {
      case 0:  return "restarting";
      case 20: return "restart-unsupported";
      default: return "error";
    }
  }
  if (op === "merge-public") {
    switch (rc) {
      case 0:  return "merged";
      case 12: return "no-open-pr";
      case 15: return "head-moved";
      case 16: return "not-green";
      default: return "error";
    }
  }
  switch (rc) {   // arm-resume
    case 0:  return "armed";
    case 3:  return "no-match";
    case 4:  return "ambiguous";
    case 5:  return "already-armed";
    default: return "error";
  }
}

// restart (HIMMEL-1272): invoked AFTER the ack has been appended + audited, because
// it takes down the transport that would deliver them. Returns the fire result; it
// does not return at all on the rung-1 happy path (the process exits).
export type RestartFn = (rung: string) => Promise<{ rc: number; message: string }>;

// Rung-2 watchdog (HIMMEL-1272 CR). `schtasks /run` exiting 0 means the TASK WAS
// LAUNCHED, not that the relaunch succeeded — restart-bridge.ps1 can still fail
// after that, and this process simply keeps running. Without a watchdog the
// operator is left holding a confirmation that never came true, which is the same
// false-success this op already guards against on the fire path.
export type ScheduleWatchdogFn = (afterMs: number, fire: () => void) => void;
export const RESTART_WATCHDOG_MS = 90_000;   // restart-bridge.ps1 settles ~12s; 90s is comfortably past a slow-but-working relaunch

export type AutoCommandDeps = {
  runScript: RunScriptFn;
  reply: (chat_id: number, text: string) => Promise<void>;
  audit: (f: AuditFields) => Promise<void>;
  restart?: RestartFn;
  scheduleWatchdog?: ScheduleWatchdogFn;
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
  // restart (HIMMEL-1272) is executed IN THIS PROCESS, not by auto-action.sh: rung 1
  // must exit the caller, and rung 2's relaunch has to outlive the processes it
  // kills. ORDERING IS LOAD-BEARING — ack, then audit, THEN fire. The reply is an
  // outbox APPEND (durable on disk); the running poller never gets to flush it,
  // because firing is exactly what kills the transport. The respawned poller drains
  // outbox.jsonl on its next tick, so the operator sees the ack a second or two
  // later. Fire first and the operator watches the bridge go silent with no
  // confirmation it heard them.
  if (route.op === "restart") {
    if (!deps.restart) {
      await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, time: route.time, rc: 20, result: auditResult(route.op, 20) });
      await reply("⚠️ restart is not wired in this poller build");
      return;
    }
    await reply(route.arg === "full"
      ? "♻️ restarting the whole bridge (fresh env) — back in a moment"
      : "♻️ bouncing the poller — back in a moment");
    await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, time: route.time, rc: 0, result: auditResult(route.op, 0) });
    const out = await deps.restart(route.arg);
    // Only reached when the fire FAILED (a successful rung 1 never returns, and a
    // successful rung 2 is killed by the task it just started). Surface the rc
    // rather than leaving the operator with an ack and a bridge that never went
    // away — a silent no-op here is indistinguishable from a slow restart.
    if (out.rc !== 0) {
      await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, time: route.time, rc: out.rc, result: auditResult(route.op, out.rc) });
      await reply(out.message);
      return;
    }
    // rc 0 on rung 2 means schtasks LAUNCHED the task, not that the relaunch
    // worked. If restart-bridge.ps1 fails after that we just keep running, and the
    // operator is left holding a "restarting…" that never came true. Still alive
    // well past a slow-but-working relaunch ⇒ say so. (Rung 1 needs no watchdog:
    // it exits, so surviving is impossible.) unref'd via the injected scheduler so
    // this timer never keeps the process up on the path where it DOES restart.
    if (route.arg === "full" && deps.scheduleWatchdog) {
      deps.scheduleWatchdog(RESTART_WATCHDOG_MS, () => {
        void (async () => {
          await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, time: route.time, rc: 23, result: auditResult(route.op, 23) });
          await reply(`⚠️ this poller is STILL RUNNING ${Math.round(RESTART_WATCHDOG_MS / 1000)}s after \`/restart full\` — the task fired, but the relaunch has not taken effect yet. If the bridge comes back in the next moment, ignore this. If not: HimmelTelegramBridge is "Interactive only" (needs you logged ON, not just unlocked) and has no periodic trigger, so nothing will retry it — restart manually with pwsh -File scripts/telegram/restart-bridge.ps1`);
        })().catch((e) => console.error(`[poller] /restart watchdog failed: ${e}`));
      });
    }
    return;
  }
  const res = await dispatchAutoAction({ runScript: deps.runScript }, route);
  await deps.audit({ chat_id: msg.chat_id, user: msg.from, forwarded: false, op: route.op, arg: route.arg, resolved: res.resolved, time: route.time, rc: res.rc, result: auditResult(route.op, res.rc) });
  await reply(res.message);
}

// The real restart executor (HIMMEL-1272). Injected into handleAutoCommand so the
// unit tests never bounce anything.
//
// Rung 1 — exit 0. supervisor.ts's main() loop respawns the poller immediately and
// rewrites the pidfile; a >5s run resets its immediate-crash counter, so a healthy
// bridge never walks toward POLLER_MAX_FAILS. This picks up anything re-read from
// a FILE at startup (post-HIMMEL-1270 that includes TELEGRAM_AUTO_ACTIONS) but NOT
// a changed User-scope env var: the respawn inherits the supervisor's environment,
// frozen when the operator's shell launched it.
//
// Rung 2 — `schtasks /run` on the ALREADY-REGISTERED HimmelTelegramBridge task
// (install-logon-task.ps1:28), whose action is restart-bridge.ps1. Two reasons this
// is the right primitive rather than a fresh one-shot task or an in-poller call:
//   * It is launched by the Task Scheduler SERVICE, so it is fully detached. A
//     naive in-poller `restart-bridge.ps1` cannot work — Get-BridgeProcs matches
//     `scripts[\/]+telegram`, which includes the calling poller, so the restarter
//     kills itself mid-command.
//   * A scheduler-launched process reads the CURRENT User/Machine environment at
//     fire time. That is the only mechanism that picks up
//     [Environment]::SetEnvironmentVariable(..., 'User') without a reboot — i.e.
//     the only rung that delivers a changed env knob.
// We do NOT exit here: restart-bridge.ps1 kills the bridge procs itself, and
// exiting first would have the supervisor respawn a poller into the middle of that.
// Args go through Bun.spawn as an argv ARRAY (no shell), so `/run` reaches
// schtasks.exe verbatim — routing it through a shell would let MSYS rewrite the
// leading-slash flags into paths.
export function makeRestart(deps: { exit?: (code: number) => never; spawnSync?: typeof Bun.spawnSync; platform?: string } = {}): RestartFn {
  const exit = deps.exit ?? ((code: number) => process.exit(code));
  const spawnSync = deps.spawnSync ?? Bun.spawnSync;
  const platform = deps.platform ?? process.platform;
  return async (rung: string) => {
    if (rung !== "full") {
      console.error("[poller] /restart: exiting 0 — the supervisor will respawn the poller");
      exit(0);
      return { rc: 0, message: "" };   // unreachable in prod; keeps the type honest for tests
    }
    if (platform !== "win32") {
      return { rc: 20, message: "⚠️ `/restart full` needs the Windows HimmelTelegramBridge scheduled task; use `/restart` (poller bounce) or restart the bridge manually" };
    }
    // spawnSync THROWS (it does not return a non-zero exitCode) when the binary
    // cannot be launched at all — no schtasks on PATH, EACCES. Unhandled, that
    // escapes deps.restart() into autoFire's .catch(), which only console.errors:
    // the operator would be left holding the ack with the bridge still up and no
    // failure message — the precise silent no-op the rc handling below exists to
    // prevent. Same failure shape, so it takes the same path.
    let r: { exitCode: number | null; stdout?: Buffer; stderr?: Buffer };
    try {
      r = spawnSync(["schtasks", "/run", "/tn", "HimmelTelegramBridge"], { stdout: "pipe", stderr: "pipe" });
    } catch (e) {
      return {
        rc: 22,
        message: `⚠️ couldn't launch schtasks (${String((e as any)?.message ?? e)}) — the HimmelTelegramBridge task could not be started. The poller is still running; restart manually.`,
      };
    }
    if (r.exitCode === 0) {
      console.error("[poller] /restart full: HimmelTelegramBridge fired — the scheduled task now owns the relaunch");
      return { rc: 0, message: "" };
    }
    // "Interactive only" logon mode: the task can only run while the operator is
    // LOGGED ON (locked is fine, logged off is not), and an at-logon task has no
    // periodic trigger — so there is no watchdog to fall back on. Say so rather
    // than leaving the operator waiting for a bridge that is not coming back.
    const detail = (r.stderr?.toString() || r.stdout?.toString() || "").trim().split("\n")[0] ?? "";
    return {
      rc: r.exitCode ?? 21,
      // Same nullish fallback as the returned rc — a signal-killed process has a
      // null exitCode, and "rc=null" in the operator's message is noise.
      message: `⚠️ couldn't fire HimmelTelegramBridge (rc=${r.exitCode ?? 21}${detail ? `: ${detail}` : ""}). The task is "Interactive only" — it needs you logged on, and it has no periodic trigger. The poller is still running; restart manually if needed.`,
    };
  };
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
// isHeld (HIMMEL-1273): a session whose burst is still inside its quiet window
// is SKIPPED here. Without this the coalescer would be pointless — handleInbound
// appends the line and holds the dispatch, then this scan, running later in the
// SAME tick, would fire the run immediately and split the burst exactly as
// before. The hold is bounded (max-hold cap), and the coalescer releases it on
// an accepted dispatch, so a session can never be skipped here indefinitely.
// A DEFERRED dispatch is re-held on purpose (see flushDue) so the burst's model
// override survives the retry — that keeps the session skipped here for as long
// as the dispatcher is refusing it, which is precisely while a run for it is
// already in flight or the concurrency cap is full. Both clear on their own, and
// the coalescer retries every tick, so it is still bounded.
export async function deliverAllPending(root: string, runFn: (session: string) => Promise<unknown>, now: Date, sessions: () => Promise<string[]>, isHeld: (s: string) => boolean = () => false): Promise<void> {
  for (const s of await sessions()) {
    const m = await readMeta(root, s);
    if (!m) continue;
    if (m.status === "capped" && !isRetryDue(m, now)) continue;
    if (m.status === "failed") continue;   // retry cap exhausted (HIMMEL-263) — only a new message un-parks
    if (isHeld(s)) continue;               // burst still landing — the coalescer owns this dispatch
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
export function makeRunFn(root: string, repoCwd: string, runImpl: (prompt: string, cwd: string, permissionMode?: PermissionMode, lane?: "glm", modelOverride?: string) => Promise<RunResult> = runSession, deadlineMs: number = RUN_DEADLINE_MS, notify?: NotifyFn, maxRetries: number = MAX_RETRIES, vaultFor?: VaultForFn, isHeld: (s: string) => boolean = () => false): RunFn {
  const retryAt = () => new Date(Date.now() + RETRY_MS).toISOString();
  const noticed = new Set<string>();
  const safeNotify = async (session: string, retryAtIso: string, kind: NotifyKind) => {
    if (!notify) return;
    try { await notify(session, retryAtIso, kind); }
    catch (e) { console.error("[poller] " + kind + " notify failed for " + session + ": " + e); }
  };
  const runOnce = async (session: string, modelOverride?: TriageModelOverride): Promise<void> => {
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
    const res = await runAndSettle(root, session, () => withDeadline(runImpl(buildPrompt(session, paths, vault), sessionCwd, permissionMode, undefined, modelOverride), deadlineMs), undefined, retryAt);
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
      await commitPending(root, session, nextPos);
      // Self-drain: a clean run immediately re-runs to pick up anything that
      // landed WHILE it was running, so a mid-run message does not wait for the
      // next poll tick.
      //
      // But it is the third consumer of the pending lines, and the only one that
      // was never given the isHeld guard the other two have (deliverAllPending
      // takes it; the coalescer's own dispatch carries the model). That gap
      // leaked the burst model (public-PR CR round 4, second codex pass): lines
      // arriving mid-run are held by the coalescer with their resolved override,
      // and this drain would consume them first — with no override at all —
      // before the dispatcher cleared in-flight and the coalescer-owned retry
      // could run. The held burst then ran on the DEFAULT model, which is the
      // same silent cost regression the re-hold above exists to prevent, just
      // reached by a different path.
      //
      // Skipping while held is not a delay: the coalescer flushes on its own
      // timer (bounded by maxHoldMs), and its dispatch lands after this run's
      // promise settles and clears in-flight — so the lines run with the model
      // the burst actually resolved to. Guarding all three consumers closes the
      // set; there is no fourth reader of the pending slice.
      if (!isHeld(session)) await runOnce(session);
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
// Returns whether the run was ACCEPTED. The two no-op paths (already in flight,
// global cap reached) are not failures, but the caller has to be able to tell
// them apart from an accepted run: a deferred dispatch carries state — the
// coalesced model override — that is lost unless whoever holds it keeps it.
export type Dispatcher = ((session: string, modelOverride?: TriageModelOverride) => Promise<boolean>)
  & { inFlightCount: () => number; isInFlight: (s: string) => boolean };
export function makeDispatcher(runFn: RunFn, cap: number = positiveEnvInt(process.env.TELEGRAM_MAX_CONCURRENT_RUNS, 2)): Dispatcher {
  const inFlight = new Set<string>();
  // `modelOverride` must be declared AND forwarded. Dispatcher is RunFn, which
  // takes it, but the `as Dispatcher` cast below silences the arity mismatch —
  // so a one-parameter dispatch type-checks while dropping the argument on the
  // floor. That is exactly how burst coalescing lost it: flushDue computes the
  // strongest model across the burst, passes it here, and it went nowhere.
  const dispatch = (async (session: string, modelOverride?: TriageModelOverride): Promise<boolean> => {
    if (inFlight.has(session)) return false;      // per-session serialization
    if (inFlight.size >= cap) return false;       // cap reached — next tick retries
    inFlight.add(session);
    runFn(session, modelOverride)
      .catch((e) => { console.error("[poller] dispatched run failed for " + session + ": " + e); })
      .finally(() => { inFlight.delete(session); });
    return true;
  }) as Dispatcher;
  dispatch.inFlightCount = () => inFlight.size;
  dispatch.isInFlight = (s: string) => inFlight.has(s);
  return dispatch;
}

// --- Burst coalescing (HIMMEL-1273) ---
// Messages sent in close proximity — especially a bulk of attachments — used to
// land as N cold runs answering N fragments of one intent. Runs were already
// serialized per session and peekPending already takes the whole unconsumed
// slice, so the machinery to batch existed; what was missing is a QUIET PERIOD.
// Two things split a burst:
//   - intra-tick: the main loop dispatched on the FIRST line of a tick, so lines
//     2..N were appended after the run had already peeked and got re-offered as
//     a second cold run. (Dispatching after the ingest loop fixes that alone.)
//   - cross-tick: getUpdates returns as soon as updates exist, so a phone
//     sending 3 PDFs usually produces 2-3 separate ticks. Only a timer fixes it.
//
// So this wraps the dispatcher: a request RECORDS intent instead of firing, and
// the hold is released once the session has been quiet for quietMs — or once
// maxHoldMs has elapsed since the first message, so a steady trickle can never
// starve the session (HIMMEL-358 asked for that cap and it still applies).
//
// Flushing is driven by an explicit `flushDue(now)` rather than per-session
// setTimeout: it is deterministic to test, leaks no timers, and matches the
// typing/outbox timers this file already runs. It CANNOT be driven off the main
// loop's tick — that blocks in a 30s long-poll, which would stretch a 4s window
// to 30s — so main wires it to its own short interval.
//
// Auto-ops (/arm, /mergepub, /restart) never reach here: handleInbound fires
// them and returns before the run call, so a privileged op is never buffered.
// That is asserted by test, not just by reading.
export type BurstCoalescer = RunFn & {
  isHolding: (s: string) => boolean;
  holdingCount: () => number;
  flushDue: (nowMs: number) => Promise<void>;
};

// Env numbers are operator-supplied: a typo must not silently disable the cap
// (NaN comparisons are always false, which would hold a burst forever).
//
// The empty/whitespace guard is load-bearing (HIMMEL-1289, public-PR CR):
// Number("") is 0, NOT NaN — and 0 is a MEANINGFUL value here (it disables
// coalescing). So `TELEGRAM_BATCH_QUIET_MS=` — set but empty, which is what a
// commented-out or half-edited .env line produces — would have silently turned
// burst coalescing OFF while looking configured, instead of falling back to the
// default. An empty value is absence, not a request for zero.
function positiveEnvMs(raw: string | undefined, fallback: number): number {
  if (raw === undefined || raw.trim() === "") return fallback;
  const n = Number(raw);
  return Number.isFinite(n) && n >= 0 ? n : fallback;
}

// A concurrency cap is a positive INTEGER, and unlike the millisecond periods
// above, 0 is not a meaningful setting here — it is a stall. Both malformed
// shapes fail, in opposite and equally bad directions:
//   TELEGRAM_MAX_CONCURRENT_RUNS=   -> Number("") is 0 -> cap 0 -> EVERY dispatch
//     defers. The coalescer re-holds, deliverAllPending skips held sessions, and
//     the bridge goes quiet while looking configured.
//   TELEGRAM_MAX_CONCURRENT_RUNS=tow -> NaN -> `inFlight.size >= NaN` is always
//     false, so the cap is silently REMOVED and unbounded claude children run in
//     parallel — precisely what the cap exists to prevent, and it burns the Max
//     quota rather than merely stalling.
// A fractional value is rejected too: "2.5" is not a number of concurrent runs.
// Same contract as the interval periods — malformed means default, and an empty
// value is absence rather than a request for zero.
//
// The bound at the TOP matters as much as the one at the bottom, and for the
// same reason intervalEnvMs carries a ceiling: a fat-fingered value with a few
// extra digits is a typo, not a request. `Number()` alone cannot see the
// difference — Number("1e6") is 1000000 and Number.isInteger says yes — so an
// exponent or an over-long digit string would restore precisely the unbounded
// parallelism the cap exists to prevent, while looking configured. Hence a
// strict decimal parse (no exponent, no hex, no sign, no separators) plus a
// ceiling. The ceiling is a fat-finger guardrail, NOT a tuning limit: every run
// is a claude child process, so a machine wanting more than this many in
// parallel has a different problem than a misread env var.
const MAX_CONCURRENT_RUNS = 64;
function positiveEnvInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const t = raw.trim();
  if (!/^[0-9]+$/.test(t)) return fallback;   // also rejects "" , "1e6", "0x10", "+5", "2.5", "-1", "NaN"
  const n = Number(t);
  return n >= 1 && n <= MAX_CONCURRENT_RUNS ? n : fallback;
}

// Interval PERIODS (HIMMEL-1291, public-PR CR). Same operator-typo hazard as
// above, worse consequence: setInterval clamps a 0/NaN period to ~1ms, so an
// unvalidated value does not fall back to the default — it spins the sweep at
// a thousand ticks a second. positiveEnvMs already turns ""/NaN/negative into
// the fallback, but it PERMITS 0, which is meaningful for a quiet WINDOW
// (0 disables coalescing) and never for a timer.
//
// So a period under 1ms falls back — it does NOT floor to 1 (codex-adv round).
// The public-CR patch proposed `Math.max(1, positiveEnvMs(…))`, which keeps the
// worst case intact: `TELEGRAM_FLUSH_MS=0` would still be a 1ms hot loop
// hammering the Telegram API and the outbox sweep, just spelled differently.
// Nothing here reads 0 as "disable the timer" — the timers are unconditional —
// so there is no operator intent to honour, only a bad value to reject. That
// makes sub-1ms exactly like "" and NaN: absence, and absence means default.
//
// The UPPER bound is the same hazard wearing the opposite disguise (codex-adv
// round 2, verified on bun 1.3.14): setInterval keeps its delay in a signed
// 32-bit int, so anything above 2147483647 does not become a long interval —
// it warns TimeoutOverflowWarning and is set to 1. A fat-fingered env value
// with a few extra digits therefore lands on the SAME 1ms hot loop as `=0`.
// Both ends fall back rather than clamp, for the same reason: an
// out-of-range period is a typo, and a typo means default.
// A FRACTIONAL period falls back too (CodeRabbit round). Not because it is a
// new hot-loop class — setInterval truncates, so 1.5 becomes 1, which is no
// worse than the 1 this function already permits outright — but because
// silently truncating is the one input shape that did not follow the contract
// the rest of the function states: a period that is not a whole millisecond is
// malformed, and malformed means default. Without it "0.4" fell back while
// "1.5" was quietly accepted and rounded, which is a distinction no operator
// could predict.
const MAX_INTERVAL_MS = 2_147_483_647;   // setInterval's signed-32-bit ceiling
export function intervalEnvMs(raw: string | undefined, fallback: number): number {
  const ms = positiveEnvMs(raw, fallback);
  return Number.isInteger(ms) && ms >= 1 && ms <= MAX_INTERVAL_MS ? ms : fallback;
}

// `dispatch` returns `false` when it DEFERRED the run (Dispatcher). A plain RunFn
// returning Promise<void> is still accepted — `undefined` is not `false`, so it
// reads as "accepted", which is the right default for a caller that cannot defer.
export function makeBurstCoalescer(
  dispatch: (session: string, modelOverride?: TriageModelOverride) => Promise<boolean | void>,
  opts: { quietMs?: number; maxHoldMs?: number; now?: () => number } = {},
): BurstCoalescer {
  // Default 4s, NOT the 5 minutes HIMMEL-358 asked for: this is the general
  // assistant chat, where a 5-minute hold would make normal conversation feel
  // dead. A link-triage group that wants minutes raises it per-deployment.
  const quietMs = opts.quietMs ?? positiveEnvMs(process.env.TELEGRAM_BATCH_QUIET_MS, 4000);
  const maxHoldMs = opts.maxHoldMs ?? positiveEnvMs(process.env.TELEGRAM_BATCH_MAX_HOLD_MS, 30000);
  const nowFn = opts.now ?? (() => Date.now());
  type Hold = { firstAt: number; lastAt: number; model?: TriageModelOverride };
  const holds = new Map<string, Hold>();

  const request = (async (session: string, modelOverride?: TriageModelOverride): Promise<void> => {
    // quietMs=0 disables coalescing entirely — an explicit escape hatch back to
    // the old dispatch-per-message behaviour.
    if (quietMs <= 0) { await dispatch(session, modelOverride); return; }
    const t = nowFn();
    const cur = holds.get(session);
    if (cur) {
      cur.lastAt = t;
      // Keep the STRONGEST model seen in the burst: a burst triaged spawn-low
      // then spawn-high must not run as haiku because the cheap line arrived
      // first. undefined (spawn-high) outranks an explicit downgrade.
      if (modelOverride === undefined) cur.model = undefined;
    } else {
      holds.set(session, { firstAt: t, lastAt: t, model: modelOverride });
    }
  }) as BurstCoalescer;

  request.isHolding = (s: string) => holds.has(s);
  request.holdingCount = () => holds.size;
  request.flushDue = async (nowMs: number): Promise<void> => {
    for (const [session, h] of [...holds.entries()]) {
      const quietElapsed = nowMs - h.lastAt >= quietMs;
      const cappedOut = nowMs - h.firstAt >= maxHoldMs;
      if (!quietElapsed && !cappedOut) continue;
      // Drop the hold BEFORE dispatching, then RE-HOLD if the dispatch was
      // deferred (session already in flight, or the global cap reached).
      //
      // The re-hold is the load-bearing part (public-PR CR round 4). Letting the
      // hold stay dropped falls back on deliverAllPending re-offering the
      // session — the pre-existing safety net — but that net calls `runFn(s)`
      // with NO model override and never re-triages, so a deferred spawn-low
      // burst came back as a DEFAULT-model run. That is a silent cost
      // regression, and it bit exactly under load, when the cap is what caused
      // the deferral in the first place. Keeping the hold keeps `h.model` with
      // it, and flushDue retries on the next tick because the hold is already
      // past due. deliverAllPending skips a held session, so ownership stays
      // here rather than being split — which is the point: only the holder
      // still knows what model the burst resolved to.
      holds.delete(session);
      // Isolate per-session failures (HIMMEL-1289, public-PR CR): one session's
      // dispatch throwing must not abort the sweep and delay every OTHER
      // already-due session to the next tick. A THROW deliberately does not
      // re-hold — the safety net takes it, as before. Re-holding a dispatch
      // that throws every tick would spin forever on the same session.
      try {
        if (await dispatch(session, h.model) === false) {
          // MERGE, never overwrite (public-PR CR round 4, CodeRabbit). The hold
          // was deleted before the await, so a message arriving DURING it finds
          // no hold and starts a fresh one. Blindly re-setting the snapshot
          // would drop that message's contribution — and in the dangerous
          // direction: a spawn-high line landing mid-await would be clobbered
          // back to the snapshot's "haiku", which is exactly the downgrade the
          // strongest-model rule exists to prevent. It would also rewind
          // lastAt, making the burst look quiet sooner than it is and splitting
          // it. Same arithmetic as the request() path above, applied to both
          // halves: strongest model wins, widest window wins.
          const cur = holds.get(session);
          if (!cur) {
            holds.set(session, h);
          } else {
            cur.firstAt = Math.min(cur.firstAt, h.firstAt);   // max-hold measures from the true burst start
            cur.lastAt = Math.max(cur.lastAt, h.lastAt);      // quiet window measures from the newest line
            if (h.model === undefined || cur.model === undefined) cur.model = undefined;
          }
        }
      } catch (e) {
        console.error(`[poller] burst flush failed for ${session}: ${e}`);
      }
    }
  };
  return request;
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

// Bridge config file (HIMMEL-1270). Until now the ONLY key ever read out of
// ~/.claude/channels/telegram/.env was TELEGRAM_BOT_TOKEN, while the shipped docs
// told operators to set TELEGRAM_AUTO_ACTIONS there too — so a correctly-edited
// .env enabled nothing and `/mergepub` silently routed as chat, twice. Every
// other knob is still process.env-only and stays that way; these two keys are the
// ones the docs point at the file for.
//
// The parsed values are returned as an explicit config object and NOT merged into
// process.env: the auto-action child inherits the poller env wholesale (see
// runScript below), and widening that surface from a config file is not something
// this ticket needs.
export const BRIDGE_ENV_KEYS = ["TELEGRAM_BOT_TOKEN", "TELEGRAM_AUTO_ACTIONS"] as const;
export type BridgeEnvKey = (typeof BRIDGE_ENV_KEYS)[number];

// Strips ONE layer of matching surrounding quotes. dotenv-style files quote
// values routinely, and an unstripped `"arm-resume"` is not a known op token —
// it would parse to the empty set, which is the exact silent-nothing this ticket
// exists to kill.
function unquote(v: string): string {
  const m = v.match(/^(['"])(.*)\1$/);
  return m ? m[2] : v;
}

// Duplicate-key precedence, line by line. The two keys need OPPOSITE rules, and
// picking one for both is wrong in a way that bites:
//
//   TELEGRAM_BOT_TOKEN — FIRST NON-EMPTY wins (the rule
//     scripts/lib/load-dotenv.sh:62-76 already implements). onboard-telegram.{sh,ps1}
//     scaffolds a literal empty `TELEGRAM_BOT_TOKEN=` placeholder, so an operator who
//     APPENDED the real token instead of editing the placeholder has a working bridge
//     today; letting the empty first line win would abort startup and take the whole
//     bridge down on upgrade. An empty assignment must never mask a real one.
//
//   TELEGRAM_AUTO_ACTIONS — LAST assignment wins, empty included. This is a
//     CAPABILITY flag, so the failure that matters is the opposite one: with
//     first-wins, `TELEGRAM_AUTO_ACTIONS=merge-public` followed by an appended
//     ``, `off`, or narrower value would leave the public-merge capability live
//     while the operator believes they revoked it. Editing by appending is exactly
//     the habit the token rule above accommodates, so duplicates are realistic.
//     Last-wins makes the file behave the way an operator reading it top-to-bottom
//     expects, and fails toward LESS capability.
const LAST_ASSIGNMENT_WINS: ReadonlySet<BridgeEnvKey> = new Set<BridgeEnvKey>(["TELEGRAM_AUTO_ACTIONS"]);

export function parseBridgeEnv(txt: string): Partial<Record<BridgeEnvKey, string>> {
  const out: Partial<Record<BridgeEnvKey, string>> = {};
  const known = new Set<string>(BRIDGE_ENV_KEYS);
  for (const raw of txt.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (!line.trim() || line.trimStart().startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq < 0) continue;
    const key = line.slice(0, eq).trim() as BridgeEnvKey;
    if (!known.has(key)) continue;
    const val = unquote(line.slice(eq + 1).trim());
    // first-non-empty keys: a value that already won is never replaced
    if (!LAST_ASSIGNMENT_WINS.has(key) && out[key]) continue;
    out[key] = val;
  }
  return out;
}

// A real process env var still WINS over the file — the launching shell is the
// more specific scope, and that is the precedence the rest of the bridge assumes.
//
// Only TELEGRAM_AUTO_ACTIONS accepts a process-env override. TELEGRAM_BOT_TOKEN is
// deliberately FILE-ONLY, exactly as loadToken() was before HIMMEL-1270.
//
// The reason is specific, not conservatism: this repo runs a SECOND bot. The
// HIMMEL_JIRA_NUDGE SessionEnd relay reads `TELEGRAM_BOT_TOKEN` from the repo
// `.env` (see the jira-nudge block in .env.example), which is a different
// credential from the poller's. Letting the process env win would mean that
// launching the bridge from any shell that had sourced the repo `.env`
// authenticates the poller AS THE RELAY BOT — a deaf bridge, or two consumers
// competing for the same getUpdates offset, depending on which token it grabbed.
// The dedicated bridge file is the only correct source for that credential.
//
// For TELEGRAM_AUTO_ACTIONS the override is the point, and an EMPTY value counts:
// `TELEGRAM_AUTO_ACTIONS=` in the launching shell is the one-run kill switch, so
// treating it as "unset" would leave the file's `merge-public` live — a fail-OPEN
// on the privileged direction.
const PROCESS_OVERRIDABLE: ReadonlySet<BridgeEnvKey> = new Set<BridgeEnvKey>(["TELEGRAM_AUTO_ACTIONS"]);

// `source` records WHERE each effective value came from, so a startup warning can
// point the operator at the thing they actually have to edit. Reporting the file
// path for a value the process env supplied would send them to fix the wrong
// place — they would edit the file, restart, and the process value would win again.
export type BridgeEnvSource = "process env" | "file";
export type LoadedBridgeEnv = Partial<Record<BridgeEnvKey, string>> & {
  path: string;
  source: Partial<Record<BridgeEnvKey, BridgeEnvSource>>;
};

export async function loadBridgeEnv(): Promise<LoadedBridgeEnv> {
  const envPath = process.env.TELEGRAM_ENV ?? join(homedir(), ".claude", "channels", "telegram", ".env");
  const fromFile = parseBridgeEnv(await readFile(envPath, "utf8"));
  const merged: Partial<Record<BridgeEnvKey, string>> = { ...fromFile };
  const source: Partial<Record<BridgeEnvKey, BridgeEnvSource>> = {};
  for (const key of BRIDGE_ENV_KEYS) if (fromFile[key] !== undefined) source[key] = "file";
  for (const key of BRIDGE_ENV_KEYS) {
    if (!PROCESS_OVERRIDABLE.has(key)) continue;
    const live = process.env[key];
    if (live === undefined) continue;
    merged[key] = live;          // "" included — the kill switch
    source[key] = "process env";
  }
  if (!merged.TELEGRAM_BOT_TOKEN) throw new Error("TELEGRAM_BOT_TOKEN not found in " + envPath);
  return { ...merged, path: envPath, source };
}

// Where to tell the operator to go for a given key's EFFECTIVE value.
export function bridgeEnvOrigin(env: LoadedBridgeEnv, key: BridgeEnvKey): string {
  return env.source[key] === "process env" ? "the poller's process env" : env.path;
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
  const bridgeEnv = await loadBridgeEnv();
  const token = bridgeEnv.TELEGRAM_BOT_TOKEN!;
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
  // runFn -> dispatch -> coalesce -> isHolding -> runFn is a cycle, so the
  // hold predicate is late-bound. It reads false until `coalesce` exists a few
  // lines below, which is correct: nothing can be held before the coalescer is
  // constructed, and no run can have started either.
  let isHeldRef: (s: string) => boolean = () => false;
  const runFn = makeRunFn(root, repoCwd, undefined, undefined, notify, undefined, vaultFor, (s) => isHeldRef(s));
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
  // Read from the bridge .env (with a real process env var still winning) —
  // HIMMEL-1270: this used to be process.env ONLY, so the documented .env location
  // was inert. The describe* wrapper also makes a configured-but-inert value say so
  // at startup instead of looking identical to "off".
  const { ops: enabledOps, warning: autoActionsWarning } =
    describeEnabledOps(bridgeEnv.TELEGRAM_AUTO_ACTIONS, KNOWN_OPS);
  if (enabledOps.size > 0) console.error(`[poller] auto-actions enabled: ${[...enabledOps].join(",")}`);
  if (autoActionsWarning) console.error(`[poller] WARNING: ${autoActionsWarning} (set in ${bridgeEnvOrigin(bridgeEnv, "TELEGRAM_AUTO_ACTIONS")})`);
  const autoScript = join(import.meta.dir, "auto-action.sh");
  const runScript: RunScriptFn = async (op, arg, time) => {
    const env: Record<string, string> = { ...process.env } as Record<string, string>;
    delete env.TELEGRAM_BOT_TOKEN;
    delete env.TELEGRAM_OWN_POLLER;
    const p = Bun.spawn([BASH_BIN, autoScript, op, arg, time], { cwd: repoCwd, env, stdout: "pipe", stderr: "pipe" });
    const [stdout, stderr, code] = await Promise.all([
      new Response(p.stdout).text(),
      new Response(p.stderr).text(),
      p.exited,
    ]);
    return { code, stdout, stderr };
  };
  const auditFn = appendAuditLine(root);
  const restart = makeRestart();
  // unref'd: on the path where the restart DOES take effect this process is killed
  // long before the timer fires, and a ref'd timer would hold it open in between.
  const scheduleWatchdog: ScheduleWatchdogFn = (afterMs, fire) => { setTimeout(fire, afterMs).unref?.(); };
  const autoFire: AutoFire = (msg, route) => {
    void handleAutoCommand(root, msg, route, { runScript, reply: (chat, text) => replyViaOutbox(root, chat, text), audit: auditFn, restart, scheduleWatchdog })
      .catch((e) => console.error(`[poller] auto-action failed for op ${route.op}: ${e}`));
  };
  // authorize = operator-identity (global allowFrom) AND chat-allowlisted (makeAllow):
  // the operator in a DM or an allowlisted group arms; a non-operator group member or a
  // non-allowlisted chat is refused. Self-sufficient — re-asserts the chat gate (CR S1).
  const autoGate: AutoGate = { enabledOps, authorize: (from, chat_id) => isAllowed(access, from) && allow(from, chat_id), fire: autoFire };
  // Burst coalescing (HIMMEL-1273): handleInbound requests through this instead
  // of dispatching per message, so a burst becomes ONE run.
  const coalesce = makeBurstCoalescer(dispatch);
  isHeldRef = coalesce.isHolding;   // closes the runFn -> dispatch -> coalesce cycle declared above
  // Its own short timer — the main loop below blocks in a 30s long-poll, so
  // driving the flush from the tick would stretch a 4s quiet window to 30s.
  const BATCH_TICK_MS = intervalEnvMs(process.env.TELEGRAM_BATCH_TICK_MS, 500);
  const batchTimer = setInterval(guarded(() => coalesce.flushDue(Date.now())), BATCH_TICK_MS);
  if (typeof batchTimer.unref === "function") batchTimer.unref();
  // typing indicator while a session's bounded child works (HIMMEL-260), and
  // while a burst is being held (HIMMEL-1273): during the quiet window nothing
  // is in flight, so without this the operator gets several seconds of dead
  // silence after sending — which reads as "the bridge is down", the opposite
  // of the reassurance this indicator exists to give.
  const TYPING_MS = intervalEnvMs(process.env.TELEGRAM_TYPING_MS, 4000);
  const isBusy = (s: string) => dispatch.isInFlight(s) || coalesce.isHolding(s);
  const typingTimer = setInterval(guarded(() => signalTyping(root, isBusy, () => sessionsList(root), (chat) => sendChatAction(token, chat))), TYPING_MS);
  if (typeof typingTimer.unref === "function") typingTimer.unref();
  // Flush outboxes on an independent ~1s timer so a bounded run's reply lands without
  // waiting up to 30s for the next long-poll to complete (T4). A cold child is a separate
  // process that appends to outbox.jsonl as it works, so the concurrent flush still earns
  // its keep. The flush path touches only outbox files; the run path touches only
  // inbox/meta/pending — disjoint, so the timer adds no shared-file race.
  const FLUSH_MS = intervalEnvMs(process.env.TELEGRAM_FLUSH_MS, 1000);
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
    // coalesce (not dispatch): each inbound RECORDS intent, so a same-tick burst
    // is one run even before the quiet window elapses — the intra-tick race the
    // ticket calls near-free to close (HIMMEL-1273).
    for (const i of fresh) await handleInbound(root, { from: i.from, chat_id: i.chat_id, text: i.text, ts: i.ts, forwarded: i.forwarded, caption: i.caption, image_path: i.image_path, document_path: i.document_path, document_name: i.document_name }, coalesce, autoGate);
    await deliverAllPending(root, dispatch, new Date(), () => sessionsList(root), coalesce.isHolding);
    await sweepStuckRunning(root, dispatch.isInFlight, () => sessionsList(root));
  }
}

if (import.meta.main) await main();
