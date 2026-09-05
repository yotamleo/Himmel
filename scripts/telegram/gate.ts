import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

// Mirrors the telegram-himmel fork's DM allowlist check (server.ts gate()):
// access.json shape { dmPolicy, allowFrom: string[], groups, pending }.
// allowFrom holds sender ids as strings; the fork compares String(from.id).
// groups is keyed by chat_id string (HIMMEL-238); negative chat_ids cover
// groups (-…) and channels (-100…). Values carry the fork's GroupPolicy:
// a non-empty per-group allowFrom restricts senders (honored here);
// requireMention (LUNA-158) opts a group into @mention-only mode — honored by
// the bun bridge's poller.ts handleInbound via requireMentionForChat below
// (no message-entities parsing; matches `@<botusername>` against the raw
// text) — a present key without allowFrom admits every member.
// vault (HIMMEL-321): an absolute Obsidian-vault path a document/PDF sent to
// this chat is filed into. A group-level vault overrides the top-level
// defaultVault (see vaultForChat).
// trustAnonymousAdmins (HIMMEL-1358): opt in to treating this group's ANONYMOUS
// posts as the operator's for the triage floor. Off by default and per-group,
// because the anonymous sender id is shared by every admin of the chat — see
// isOperatorIdentity.
// cwd (LUNA-101): an absolute REPO path this chat's bounded run spawns in,
// instead of the himmel checkout. Sibling of vault, not a replacement: a
// cwd-routed chat is code-repo-routed, so it gets no Obsidian filing clause
// (see cwdForChat).
export type GroupPolicy = { requireMention?: boolean; allowFrom?: string[]; vault?: string; cwd?: string; trustAnonymousAdmins?: boolean };
export type Access = { dmPolicy?: string; allowFrom?: string[]; groups?: Record<string, GroupPolicy>; defaultVault?: string };

// Pure predicate. Fails CLOSED: missing/empty/malformed allowlist → false.
export function isAllowed(access: Access | null | undefined, fromId: number | string): boolean {
  const allow = access?.allowFrom;
  if (!Array.isArray(allow) || allow.length === 0) return false;
  return allow.includes(String(fromId));
}

// Pure predicate for group/channel chats. Fails CLOSED: groups must be a plain
// object and the chat_id a present key; a non-empty per-group allowFrom
// additionally requires the sender to be in it.
export function isGroupAllowed(access: Access | null | undefined, chatId: number | string, fromId?: number | string): boolean {
  const groups = access?.groups;
  if (!groups || typeof groups !== "object" || Array.isArray(groups)) return false;
  if (!Object.prototype.hasOwnProperty.call(groups, String(chatId))) return false;
  const perGroup = groups[String(chatId)]?.allowFrom;
  if (Array.isArray(perGroup) && perGroup.length > 0) return fromId != null && perGroup.includes(String(fromId));
  return true;
}

// Telegram's fixed GroupAnonymousBot id. When a group ADMIN posts with "Remain
// anonymous" enabled, Telegram strips the real sender and substitutes this id
// for every such message; it is a documented platform constant, not an account
// anyone can sign in as. A non-admin cannot post anonymously, so inside a given
// chat this id means exactly "an admin of this chat".
export const GROUP_ANONYMOUS_BOT_ID = 1087968824;

// Is this sender the OPERATOR, for the purposes of the triage operator floor
// (poller.ts handleInbound)? Two ways to be:
//   1. the global allowFrom identity — unchanged HIMMEL-1296 semantics;
//   2. the anonymous-admin substitute id, in a group that has OPTED IN via
//      `trustAnonymousAdmins`.
// (2) exists because the operator posts in his own groups with "Remain
// anonymous" on, so his real id NEVER reaches us and (1) can never match — his
// messages were classified `ignore` and permanently dropped (HIMMEL-1358).
//
// Why the explicit per-group opt-in rather than "any allow-listed group" (codex
// adversarial CR): the anonymous id is shared by EVERY admin of the chat, so in
// a multi-admin group mere allow-listing would silently promote all of them.
// Allow-listing means "ingest this chat's messages"; it does not mean "every
// admin here speaks for me". `trustAnonymousAdmins: true` is the operator
// saying the second part out loud, per group. It stacks ON TOP of the other
// conditions, never replaces them — the chat must still be a negative-id,
// allow-listed group, and there must still be a configured operator identity,
// since the anon branch is a SUBSTITUTION rule and an empty allowFrom leaves
// no one for it to be substituting for.
//
// This governs the triage floor ONLY. It is deliberately NOT wired into
// autoGate.authorize: the floor's worst case is spawning on chatter, whereas
// /arm grants powers, and an anonymous post cannot distinguish the operator
// from any other admin of that group even with the opt-in set.
// senderChatId: Telegram's `sender_chat` — for an on-behalf-of-chat message,
// the chat the post actually represents. When Telegram supplies it, the
// anonymous branch REQUIRES it to be the destination chat, so the floor rests on
// Telegram's own authoritative identity rather than on inferring "1087968824
// here must mean an admin of here" (codex adversarial CR).
// Absent (`undefined`/`null`) does NOT block: these fields come from Telegram's
// servers, not the client, so an attacker cannot suppress one — while REQUIRING
// it would silently re-break the exact drop this ticket exists to fix on any
// update shape that legitimately omits it. Present-and-mismatched is the only
// case that can be an impersonation, and it is the case this rejects.
export function isOperatorIdentity(access: Access | null | undefined, fromId: number | string, chatId: number | string, senderChatId?: number | string | null): boolean {
  // The anonymous id NEVER wins via the global allowFrom (CodeRabbit CR). It is
  // not a person, so globally it means nothing — and letting it short-circuit
  // here would grant operator status in ANY chat, skipping every group-scoped
  // guard below. Reachable by a plausible misconfiguration now that the README
  // tells operators to put 1087968824 in a group's allowFrom: putting it in the
  // TOP-LEVEL allowFrom instead is one indentation level away.
  const isAnonymous = String(fromId) === String(GROUP_ANONYMOUS_BOT_ID);
  if (!isAnonymous) return isAllowed(access, fromId);
  const allow = access?.allowFrom;
  if (!Array.isArray(allow) || allow.length === 0) return false;
  if (access?.groups?.[String(chatId)]?.trustAnonymousAdmins !== true) return false;
  if (senderChatId != null && String(senderChatId) !== String(chatId)) return false;
  return Number(chatId) < 0 && isGroupAllowed(access, chatId, fromId);
}

// Resolve the vault a document sent to `chatId` is filed into (HIMMEL-321):
// the chat's own group vault wins, else the top-level defaultVault, else null
// (no vault configured → the run surfaces the document but files nothing).
// String/number chatId both work; covers DMs (positive id, not in groups → default).
export function vaultForChat(access: Access | null | undefined, chatId: number | string): string | null {
  const g = access?.groups?.[String(chatId)];
  return g?.vault ?? access?.defaultVault ?? null;
}

// Resolve the repo cwd a chat's bounded run spawns in (LUNA-101). Deliberately
// NOT a mirror of vaultForChat: there is no defaultCwd, because a default would
// route every chat — DMs included — into that repo. Group's own `cwd`, else null
// (→ the caller keeps the himmel checkout).
// Rejects a non-string `cwd` at the boundary (CR CodeRabbit): access.json is
// hand-edited, and a malformed value like `"cwd": 7` is TRUTHY — it would reach
// the floor check and the child-process spawn as a number instead of being
// refused here.
// ABSOLUTE only (CR codex-1): the key is documented as an absolute repo path, and
// nothing enforced it. A relative `"cwd": "ggs-local"` would resolve against the
// POLLER's launch directory — so the same config would route to a different place
// depending on where the bridge happened to be started from, and could grant
// bypassPermissions over a directory the operator never named. Enforce what the
// docs already promise. Accepts both POSIX and Windows shapes, since access.json
// on this machine carries `C:/Users/…`.
const ABSOLUTE_CWD = /^(?:\/|[A-Za-z]:[\\/]|\\\\)/;
export function cwdForChat(access: Access | null | undefined, chatId: number | string): string | null {
  const cwd = access?.groups?.[String(chatId)]?.cwd;
  if (typeof cwd !== "string" || !ABSOLUTE_CWD.test(cwd)) return null;
  return cwd;
}

// Resolve whether `chatId`'s group opted into @mention-only mode (LUNA-158) —
// straight boolean read of GroupPolicy.requireMention, defaulting to false so
// a chat absent from `groups` (including every DM) is unaffected.
export function requireMentionForChat(access: Access | null | undefined, chatId: number | string): boolean {
  return access?.groups?.[String(chatId)]?.requireMention === true;
}

export const defaultAccessPath = () =>
  process.env.TELEGRAM_ACCESS_PATH ??
  join(homedir(), ".claude", "channels", "telegram", "access.json");

// Caller-side loader. On any read/parse failure returns an empty Access so
// isAllowed fails closed; never logs file contents.
export async function loadAccess(path: string = defaultAccessPath()): Promise<Access> {
  try { return JSON.parse(await readFile(path, "utf8")); }
  catch { return {}; }
}
