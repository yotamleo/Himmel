import { expect, test } from "bun:test";
import { isAllowed, isGroupAllowed, vaultForChat } from "./gate";

// Real access.json shape (~/.claude/channels/telegram/access.json):
//   { "dmPolicy": "allowlist", "allowFrom": ["1000000001"], "groups": {}, "pending": {} }
// The fork's gate() compares String(from.id) against allowFrom (string array).

test("allows listed sender, rejects others", () => {
  const access = { dmPolicy: "allowlist", allowFrom: ["123", "456"] };
  expect(isAllowed(access, 123)).toBe(true);
  expect(isAllowed(access, "456")).toBe(true);
  expect(isAllowed(access, 999)).toBe(false);
});

test("fails closed on missing allowlist", () => {
  expect(isAllowed({}, 123)).toBe(false);
  expect(isAllowed({ dmPolicy: "allowlist" }, 123)).toBe(false);
});

test("fails closed on empty allowlist", () => {
  expect(isAllowed({ dmPolicy: "allowlist", allowFrom: [] }, 123)).toBe(false);
});

test("fails closed on malformed allowlist", () => {
  expect(isAllowed({ allowFrom: "123" } as any, 123)).toBe(false);
  expect(isAllowed(null as any, 123)).toBe(false);
  expect(isAllowed(undefined as any, 123)).toBe(false);
});

// --- group/channel allowlist (HIMMEL-238) ---
// groups is the fork's object shape keyed by chat_id string; a present key
// allows the chat. Covers groups (-…) and channels (-100…) alike.

test("isGroupAllowed: allows a chat_id present in groups, rejects others", () => {
  const access = { allowFrom: ["1"], groups: { "-1009999999": {} } };
  expect(isGroupAllowed(access, -1009999999)).toBe(true);
  expect(isGroupAllowed(access, "-1009999999")).toBe(true);
  expect(isGroupAllowed(access, -999)).toBe(false);
  expect(isGroupAllowed(access, 1000000001)).toBe(false);   // DM id not in groups
});

test("isGroupAllowed: fails closed on missing/empty/malformed groups", () => {
  expect(isGroupAllowed({}, -1009999999)).toBe(false);
  expect(isGroupAllowed({ groups: {} }, -1009999999)).toBe(false);
  expect(isGroupAllowed({ groups: ["-1009999999"] } as any, -1009999999)).toBe(false);
  expect(isGroupAllowed({ groups: "-1009999999" } as any, -1009999999)).toBe(false);
  expect(isGroupAllowed(null as any, -1009999999)).toBe(false);
  expect(isGroupAllowed(undefined as any, -1009999999)).toBe(false);
});

test("isGroupAllowed: a non-empty per-group allowFrom restricts senders (fork GroupPolicy)", () => {
  const access = { groups: { "-50": { allowFrom: ["123"] } } };
  expect(isGroupAllowed(access, -50, 123)).toBe(true);
  expect(isGroupAllowed(access, -50, "123")).toBe(true);
  expect(isGroupAllowed(access, -50, 999)).toBe(false);
  expect(isGroupAllowed(access, -50)).toBe(false);          // no sender (anonymous) → fail closed
});

test("isGroupAllowed: empty/missing per-group allowFrom admits any member; requireMention is ignored", () => {
  // pins the documented divergence from the fork: the bun bridge does not
  // parse entities, so requireMention has no effect here
  expect(isGroupAllowed({ groups: { "-50": { allowFrom: [] } } }, -50, 999)).toBe(true);
  expect(isGroupAllowed({ groups: { "-50": { requireMention: true } } }, -50, 999)).toBe(true);
});

// --- per-group vault routing (HIMMEL-321) ---
// A document/PDF attachment is filed into the vault resolved for its chat:
// a group's own `vault` wins, else the top-level `defaultVault`, else null
// (no vault configured → the run just surfaces the document, files nothing).

test("vaultForChat: a group's own vault wins", () => {
  const access = { defaultVault: "/luna", groups: { "-1001234567890": { vault: "/salus" } } };
  expect(vaultForChat(access, -1001234567890)).toBe("/salus");
  expect(vaultForChat(access, "-1001234567890")).toBe("/salus");
});

test("vaultForChat: a group without its own vault falls back to defaultVault", () => {
  const access = { defaultVault: "/luna", groups: { "-50": {} } };
  expect(vaultForChat(access, -50)).toBe("/luna");
});

test("vaultForChat: an unknown chat still gets defaultVault (covers DMs too)", () => {
  const access = { defaultVault: "/luna", groups: { "-50": {} } };
  expect(vaultForChat(access, -999)).toBe("/luna");
  expect(vaultForChat(access, 1000000001)).toBe("/luna");
});

test("vaultForChat: null when no vault and no default (fails closed → file nothing)", () => {
  expect(vaultForChat({ groups: { "-50": {} } }, -50)).toBeNull();
  expect(vaultForChat({}, -50)).toBeNull();
  expect(vaultForChat(null as any, -50)).toBeNull();
  expect(vaultForChat(undefined as any, -50)).toBeNull();
});
