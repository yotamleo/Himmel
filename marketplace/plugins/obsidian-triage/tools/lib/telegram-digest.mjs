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

/** reply_to target for a chat: the numerically-largest (most recent) msg id when
 *  all are numeric, else the first seen — deterministic either way. */
export function pickReplyTo(msgIds) {
  const ids = (msgIds || []).map((s) => String(s)).filter(Boolean);
  if (!ids.length) return null;
  if (ids.every((s) => /^\d+$/.test(s))) {
    return ids.reduce((a, b) => (BigInt(b) > BigInt(a) ? b : a));
  }
  return ids[0];
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
 * @returns {Array<{chat_id:string, reply_to:string|null, text:string}>} at most
 *          one digest per originating telegram chat. Empty when there are no
 *          telegram-origin promotions or when suppressed. Distinct subjects only
 *          (a subject promoted from two telegram clips is listed once).
 */
export function buildPromotionDigest(promotions, opts = {}) {
  if (opts.suppress) return [];
  const byChat = new Map(); // chat_id -> { subjects:[], seen:Set, msgIds:[] }
  for (const p of promotions || []) {
    const c = p && p.clip;
    if (!c || c.clipped_via !== "telegram") continue;
    const chatId = c.telegram_chat_id;
    const msgId = c.telegram_msg_id;
    if (!chatId || !msgId || !p.subject) continue;
    let g = byChat.get(String(chatId));
    if (!g) { g = { subjects: [], seen: new Set(), msgIds: [] }; byChat.set(String(chatId), g); }
    if (!g.seen.has(p.subject)) { g.seen.add(p.subject); g.subjects.push(p.subject); }
    g.msgIds.push(String(msgId));
  }
  const digests = [];
  for (const [chatId, g] of byChat) {
    digests.push({ chat_id: chatId, reply_to: pickReplyTo(g.msgIds), text: renderDigestText(g.subjects) });
  }
  return digests;
}
