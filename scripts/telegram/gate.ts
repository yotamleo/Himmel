import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

// Mirrors the telegram-himmel fork's DM allowlist check (server.ts gate()):
// access.json shape { dmPolicy, allowFrom: string[], groups, pending }.
// allowFrom holds sender ids as strings; the fork compares String(from.id).
// groups is keyed by chat_id string (HIMMEL-238); negative chat_ids cover
// groups (-…) and channels (-100…). Values carry the fork's GroupPolicy:
// a non-empty per-group allowFrom restricts senders (honored here);
// requireMention is IGNORED by the bun bridge (it doesn't parse message
// entities) — a present key without allowFrom admits every member.
// vault (HIMMEL-321): an absolute Obsidian-vault path a document/PDF sent to
// this chat is filed into. A group-level vault overrides the top-level
// defaultVault (see vaultForChat).
export type GroupPolicy = { requireMention?: boolean; allowFrom?: string[]; vault?: string };
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

// Resolve the vault a document sent to `chatId` is filed into (HIMMEL-321):
// the chat's own group vault wins, else the top-level defaultVault, else null
// (no vault configured → the run surfaces the document but files nothing).
// String/number chatId both work; covers DMs (positive id, not in groups → default).
export function vaultForChat(access: Access | null | undefined, chatId: number | string): string | null {
  const g = access?.groups?.[String(chatId)];
  return g?.vault ?? access?.defaultVault ?? null;
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
