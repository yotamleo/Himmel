/**
 * telegram-digest.mjs — LUNA-91 batched promotion-feedback digest (pure).
 *
 * When synthesize-stubs promotes evidence clips to subjects, clips that were
 * CAPTURED VIA TELEGRAM should let the operator see the vault compounding from
 * the same surface they captured on (design §8). Per the critic resolution
 * (§12.F) the feedback is **ONE batched digest reply per run, not one ping per
 * promotion**, and is **suppressed during migration backfill**.
 *
 * This module is pure (no I/O, no network): it turns the run's promotions into
 * at most one digest message PER originating chat. synthesize-stubs writes the
 * result to a digest file; the synthesize-stubs runbook sends it through the
 * telegram bridge `reply` tool (the live send is operator-gated — the bridge is
 * an MCP server in the session, never called from a vault script).
 */

/** Bracket-link basename: "[[30-Resources/Concepts/Context-Windows]]" → "[[Context-Windows]]". */
export function basenameLink(link) {
  const m = String(link || "").match(/^\[\[(.+)\]\]$/);
  if (!m) return String(link || "");
  const base = m[1].split("/").pop();
  return `[[${base}]]`;
}

/**
 * Composite telegram id form some bridges file under, e.g.
 * `telegram-tg-group_-1003985279697-1782605997` (single) or
 * `tg-group_-1003985279697-1782605414-7` (one drop of a multi-link message):
 * `…_<chat_id>-<message_id>[-<drop>]`, chat possibly negative (supergroup).
 * Captures group 1 = chat_id, group 2 = the numeric Telegram message_id.
 */
const COMPOSITE_REF_RE = /_(-?\d+)-(\d+)(?:-\d+)?$/;

/**
 * Resolve a clip's chat id + a NUMERIC reply target from its telegram fields,
 * tolerant of both the clean shape (separate `telegram_chat_id`, numeric
 * `telegram_msg_id`) and a composite `telegram_msg_id` that embeds both. The
 * digest never reaches into the vault — this derives from what the clip already
 * carries, so composite-id clips work for replies with no backfill.
 * @returns {{chatId:string|null, replyTo:string|null}} replyTo is null when no
 *          numeric message id is recoverable (→ send the reply unthreaded).
 */
export function parseTelegramRef(clip) {
  const c = clip || {};
  const rawMsg = c.telegram_msg_id != null ? String(c.telegram_msg_id) : "";
  let chatId = (c.telegram_chat_id != null && String(c.telegram_chat_id) !== "")
    ? String(c.telegram_chat_id) : null;
  let replyTo = /^\d+$/.test(rawMsg) ? rawMsg : null;
  if (!chatId || !replyTo) {
    const m = rawMsg.match(COMPOSITE_REF_RE);
    if (m) {
      if (!chatId) chatId = m[1];
      if (!replyTo) replyTo = m[2];
    }
  }
  return { chatId, replyTo };
}

/** reply_to target for a chat: the numerically-largest (most recent) message id
 *  among the resolved numeric targets, or null (→ unthreaded) when none. */
export function pickReplyTo(replyTargets) {
  const ids = (replyTargets || []).map((s) => String(s)).filter((s) => /^\d+$/.test(s));
  if (!ids.length) return null;
  return ids.reduce((a, b) => (BigInt(b) > BigInt(a) ? b : a));
}

/** "📌 Saved → now a subject: [[X]]" / "… now subjects: [[X]], [[Y]]". */
export function renderDigestText(subjectLinks) {
  const links = subjectLinks.map(basenameLink);
  const noun = links.length === 1 ? "a subject" : "subjects";
  return `📌 Saved → now ${noun}: ${links.join(", ")}`;
}

/**
 * Build the batched promotion digest for a synthesize run.
 *
 * @param {Array<{subject:string, clip:{clipped_via?:string, telegram_msg_id?:string,
 *                telegram_chat_id?:string}}>} promotions — one entry per
 *        (subject, contributing-clip) newly promoted in THIS run.
 * @param {{suppress?:boolean}} [opts] — suppress=true (migration backfill) → [].
 * Chat id + reply target are resolved via parseTelegramRef, so clips whose
 * bridge filed a composite `telegram_msg_id` (chat embedded, no separate
 * `telegram_chat_id`) still produce a correctly-targeted reply with no backfill.
 *
 * @returns {Array<{chat_id:string, reply_to:string|null, text:string}>} at most
 *          one digest per originating telegram chat. reply_to is null when no
 *          numeric message id is recoverable (→ send unthreaded). Empty when
 *          there are no telegram-origin promotions or when suppressed. Distinct
 *          subjects only (a subject promoted from two telegram clips is once).
 */
export function buildPromotionDigest(promotions, opts = {}) {
  if (opts.suppress) return [];
  const byChat = new Map(); // chat_id -> { subjects:[], seen:Set, replyTos:[] }
  for (const p of promotions || []) {
    const c = p && p.clip;
    if (!c || c.clipped_via !== "telegram" || !p.subject) continue;
    const { chatId, replyTo } = parseTelegramRef(c);
    if (!chatId) continue; // no chat to target → can't reply
    let g = byChat.get(chatId);
    if (!g) { g = { subjects: [], seen: new Set(), replyTos: [] }; byChat.set(chatId, g); }
    if (!g.seen.has(p.subject)) { g.seen.add(p.subject); g.subjects.push(p.subject); }
    if (replyTo) g.replyTos.push(replyTo);
  }
  const digests = [];
  for (const [chatId, g] of byChat) {
    digests.push({ chat_id: chatId, reply_to: pickReplyTo(g.replyTos), text: renderDigestText(g.subjects) });
  }
  return digests;
}
