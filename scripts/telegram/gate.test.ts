import { expect, test } from "bun:test";
import { GROUP_ANONYMOUS_BOT_ID, cwdForChat, isAllowed, isGroupAllowed, isOperatorIdentity, requireMentionForChat, vaultForChat } from "./gate";

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

test("isGroupAllowed: empty/missing per-group allowFrom admits any member; requireMention is out of scope here", () => {
  // isGroupAllowed answers "is this sender/chat admitted at all" — requireMention
  // (LUNA-158) is a separate @mention-only gate honored by poller.ts
  // handleInbound via requireMentionForChat below, not by this predicate.
  expect(isGroupAllowed({ groups: { "-50": { allowFrom: [] } } }, -50, 999)).toBe(true);
  expect(isGroupAllowed({ groups: { "-50": { requireMention: true } } }, -50, 999)).toBe(true);
});

// --- operator identity, including anonymous group admins (HIMMEL-1358) ---
// When a group admin posts with "Remain anonymous" on, Telegram replaces the
// sender with the fixed GroupAnonymousBot id, so the operator's real id never
// reaches us and a raw allowFrom comparison can never match. Measured live:
// every message from the affected group carried 1087968824, while the same
// sender's DMs carried their real id. Fixtures below are synthetic.

const OPTED_IN = { allowFrom: ["1000000001"], groups: { "-1009999999": { trustAnonymousAdmins: true } } };

test("isOperatorIdentity: the anonymous-admin id is operator in an opted-in group (HIMMEL-1358)", () => {
  expect(isOperatorIdentity(OPTED_IN, 1000000001, -1009999999)).toBe(true);              // named post
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999)).toBe(true);  // anonymous post
  expect(isOperatorIdentity(OPTED_IN, "1087968824", "-1009999999")).toBe(true);          // string ids too
});

// The codex adversarial CR's finding, pinned: the anonymous id is shared by
// EVERY admin of the chat, so allow-listing a group (which only means "ingest
// this chat") must NOT by itself promote its admins to operator. The opt-in is
// what says that out loud, per group.
test("isOperatorIdentity: allow-listing alone does NOT trust anonymous admins (HIMMEL-1358)", () => {
  const noOptIn = { allowFrom: ["1000000001"], groups: { "-1009999999": {} } };
  expect(isOperatorIdentity(noOptIn, GROUP_ANONYMOUS_BOT_ID, -1009999999)).toBe(false);
  expect(isOperatorIdentity(noOptIn, 1000000001, -1009999999)).toBe(true);   // named post is unaffected
  // an explicit false is the same as absent
  const optedOut = { allowFrom: ["1000000001"], groups: { "-1009999999": { trustAnonymousAdmins: false } } };
  expect(isOperatorIdentity(optedOut, GROUP_ANONYMOUS_BOT_ID, -1009999999)).toBe(false);
});

// Telegram's sender_chat is the authoritative "which chat does this post
// represent". Where it is supplied it must BE the destination chat, so the floor
// no longer rests on inferring that 1087968824 here means an admin of here.
// Absent is permitted on purpose — see the note on isOperatorIdentity.
test("isOperatorIdentity: a mismatched sender_chat is refused; matching and absent pass (HIMMEL-1358)", () => {
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999, -1009999999)).toBe(true);   // matches
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999, "-1009999999")).toBe(true); // string form
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999, -777)).toBe(false);         // some OTHER chat
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999, undefined)).toBe(true);     // absent → allowed
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -1009999999, null)).toBe(true);          // null → allowed
  // the named-identity path is unaffected by sender_chat entirely
  expect(isOperatorIdentity(OPTED_IN, 1000000001, -1009999999, -777)).toBe(true);
});

test("isOperatorIdentity: the anonymous-admin id is NOT operator outside its opted-in group (HIMMEL-1358)", () => {
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);            // unlisted group
  expect(isOperatorIdentity(OPTED_IN, GROUP_ANONYMOUS_BOT_ID, 1087968824)).toBe(false);     // positive chat_id (DM)
  expect(isOperatorIdentity(OPTED_IN, 9, -1009999999)).toBe(false);                      // ordinary member
});

// The narrower gate wins, deliberately: trustAnonymousAdmins must not quietly
// undo a per-group allowFrom the operator set on purpose. The consequence — such
// a group keeps losing anonymous posts (they are rejected at INGEST by
// makeAllow, before triage) unless 1087968824 is added to that allowFrom too —
// is a real trap and is documented in README.md rather than papered over here.
test("isOperatorIdentity: a per-group allowFrom that excludes the anon id keeps it out (HIMMEL-1358)", () => {
  const access = { allowFrom: ["5"], groups: { "-50": { allowFrom: ["9"], trustAnonymousAdmins: true } } };
  expect(isOperatorIdentity(access, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);
  expect(isOperatorIdentity(access, 9, -50)).toBe(false);   // per-group member is not the operator (HIMMEL-1296)
  expect(isOperatorIdentity(access, 5, -50)).toBe(true);    // global allowFrom identity still wins
  // ...and listing the anon id in that allowFrom is what admits it (the README's escape hatch)
  const listed = { allowFrom: ["5"], groups: { "-50": { allowFrom: ["9", "1087968824"], trustAnonymousAdmins: true } } };
  expect(isOperatorIdentity(listed, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(true);
});

// The anonymous branch is a SUBSTITUTION rule — "Telegram replaced the
// operator's id" — so it is meaningless where no operator identity is
// configured at all. With an empty/absent global allowFrom nobody is the
// operator, and the anon id must not become one by default.
// A globally-listed anonymous id must not short-circuit past the group-scoped
// guards (CodeRabbit CR). The id is not a person, so globally it means nothing —
// and this misconfiguration is one indentation level away from the per-group
// allowFrom entry the README now recommends.
test("isOperatorIdentity: the anon id in the GLOBAL allowFrom grants nothing (HIMMEL-1358)", () => {
  const misconfigured = { allowFrom: ["1000000001", "1087968824"], groups: { "-50": {} } };
  expect(isOperatorIdentity(misconfigured, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);        // no group opt-in
  expect(isOperatorIdentity(misconfigured, GROUP_ANONYMOUS_BOT_ID, 12345)).toBe(false);      // and not in a DM
  expect(isOperatorIdentity(misconfigured, GROUP_ANONYMOUS_BOT_ID, -1)).toBe(false);         // nor an unlisted group
  // it still cannot skip sender_chat once a group DOES opt in
  const optedIn = { allowFrom: ["1000000001", "1087968824"], groups: { "-50": { trustAnonymousAdmins: true } } };
  expect(isOperatorIdentity(optedIn, GROUP_ANONYMOUS_BOT_ID, -50, -777)).toBe(false);
  expect(isOperatorIdentity(optedIn, GROUP_ANONYMOUS_BOT_ID, -50, -50)).toBe(true);
  // and a real operator id in the global allowFrom is unaffected
  expect(isOperatorIdentity(misconfigured, 1000000001, -50)).toBe(true);
});

test("isOperatorIdentity: fails closed when no operator identity is configured (HIMMEL-1358)", () => {
  expect(isOperatorIdentity({}, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);
  expect(isOperatorIdentity({ groups: { "-50": { trustAnonymousAdmins: true } } }, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);
  expect(isOperatorIdentity({ allowFrom: [], groups: { "-50": { trustAnonymousAdmins: true } } }, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);
  expect(isOperatorIdentity(null as any, 5, -50)).toBe(false);
  expect(isOperatorIdentity(undefined as any, GROUP_ANONYMOUS_BOT_ID, -50)).toBe(false);
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

// cwdForChat (LUNA-101) — the repo a chat's session spawns in. Deliberately
// NOT a mirror of vaultForChat: there is no defaultCwd, because a default
// would route every chat (including DMs) into that repo.

test("cwdForChat: a group's own cwd is returned", () => {
  const access = { groups: { "-5553924158": { cwd: "C:/x/ggs-local" } } };
  expect(cwdForChat(access, -5553924158)).toBe("C:/x/ggs-local");
  expect(cwdForChat(access, "-5553924158")).toBe("C:/x/ggs-local");
});

test("cwdForChat: a group without cwd gets null (no default fallback)", () => {
  const access = { defaultVault: "/luna", groups: { "-50": {} } };
  expect(cwdForChat(access, -50)).toBeNull();
});

test("cwdForChat: an unknown chat gets null and never inherits defaultVault", () => {
  const access = { defaultVault: "/luna", groups: { "-5553924158": { cwd: "C:/x/ggs-local" } } };
  expect(cwdForChat(access, -999)).toBeNull();
  expect(cwdForChat(access, 1000000001)).toBeNull();
});

test("cwdForChat: missing/empty access fails closed", () => {
  expect(cwdForChat({}, -50)).toBeNull();
  expect(cwdForChat(null as any, -50)).toBeNull();
  expect(cwdForChat(undefined as any, -50)).toBeNull();
});

// access.json is hand-edited, and a malformed cwd is TRUTHY — it would otherwise
// reach the floor check and the spawn as a non-string (CR CodeRabbit).
// The key is DOCUMENTED as absolute; a relative value would resolve against the
// poller's launch directory, so the same config would mean different places
// depending on where the bridge was started (CR codex-1).
test("cwdForChat: a RELATIVE cwd is refused (absolute paths only)", () => {
  expect(cwdForChat({ groups: { "-50": { cwd: "ggs-local" } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: "./ggs-local" } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: "../ggs-local" } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: "" } } }, -50)).toBeNull();
});
test("cwdForChat: accepts the absolute shapes access.json actually carries", () => {
  expect(cwdForChat({ groups: { "-50": { cwd: "C:/Users/x/ggs-local" } } }, -50)).toBe("C:/Users/x/ggs-local");
  expect(cwdForChat({ groups: { "-50": { cwd: "C:\\Users\\x\\ggs-local" } } }, -50)).toBe("C:\\Users\\x\\ggs-local");
  expect(cwdForChat({ groups: { "-50": { cwd: "/home/x/ggs-local" } } }, -50)).toBe("/home/x/ggs-local");
  expect(cwdForChat({ groups: { "-50": { cwd: "\\\\server\\share" } } }, -50)).toBe("\\\\server\\share");
});

test("cwdForChat: a malformed (non-string) cwd is refused at the boundary", () => {
  expect(cwdForChat({ groups: { "-50": { cwd: 7 as any } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: true as any } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: ["/x"] as any } } }, -50)).toBeNull();
  expect(cwdForChat({ groups: { "-50": { cwd: { path: "/x" } as any } } }, -50)).toBeNull();
});

// requireMentionForChat (LUNA-158) — the per-group @mention-only opt-in.
test("requireMentionForChat: true only for a group with requireMention:true", () => {
  const access = { groups: { "-5245475441": { requireMention: true }, "-50": {} } };
  expect(requireMentionForChat(access, -5245475441)).toBe(true);
  expect(requireMentionForChat(access, "-5245475441")).toBe(true);
  expect(requireMentionForChat(access, -50)).toBe(false);
});

test("requireMentionForChat: unknown chat and missing/empty access default to false (unaffected, including DMs)", () => {
  expect(requireMentionForChat({ groups: { "-50": { requireMention: true } } }, -999)).toBe(false);
  expect(requireMentionForChat({}, -50)).toBe(false);
  expect(requireMentionForChat(null as any, -50)).toBe(false);
  expect(requireMentionForChat(undefined as any, -50)).toBe(false);
});
