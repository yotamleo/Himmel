/**
 * test-telegram-digest.mjs — unit tests for the LUNA-91 batched promotion digest.
 *
 * Run: node tests/test-telegram-digest.mjs
 * (from marketplace/plugins/obsidian-triage/)  — or via the .sh wrapper.
 *
 * No npm deps, no I/O: pure over plain objects.
 *
 * Contract (design §8 + §12.F, Jira LUNA-91 acceptance):
 *   - a run that promotes N telegram-origin clips sends ONE message (not N).
 *   - distinct subjects only; non-telegram clips never trigger feedback.
 *   - suppress (migration backfill) → no messages.
 *   - reply threads under the most recent contributing message id.
 */
import { buildPromotionDigest, basenameLink, renderDigestText, parseTelegramRef } from "../tools/lib/telegram-digest.mjs";

let pass = 0, fail = 0;
function assert(desc, expected, actual) {
  const exp = JSON.stringify(expected), act = JSON.stringify(actual);
  if (exp === act) { console.log(`  PASS  ${desc}`); pass++; }
  else { console.log(`  FAIL  ${desc}`); console.log(`         expected: ${exp}`); console.log(`         actual:   ${act}`); fail++; }
}

const tg = (chat, msg) => ({ clipped_via: "telegram", telegram_chat_id: chat, telegram_msg_id: msg });

// 5 telegram-origin promotions, same chat → exactly ONE message (not 5).
const five = [
  { subject: "[[30-Resources/Concepts/A]]", clip: tg("100", "11") },
  { subject: "[[30-Resources/Concepts/B]]", clip: tg("100", "12") },
  { subject: "[[30-Resources/Concepts/C]]", clip: tg("100", "13") },
  { subject: "[[30-Resources/Concepts/D]]", clip: tg("100", "14") },
  { subject: "[[60-Maps/E-MOC]]",           clip: tg("100", "15") },
];
const d5 = buildPromotionDigest(five);
assert("5 telegram promotions → exactly 1 message", 1, d5.length);
assert("the one message targets the originating chat", "100", d5[0].chat_id);
assert("reply threads under the most recent (max) msg id", "15", d5[0].reply_to);
assert("message lists all 5 distinct subjects by basename", true,
  ["[[A]]", "[[B]]", "[[C]]", "[[D]]", "[[E-MOC]]"].every((s) => d5[0].text.includes(s)));

// Distinct-subject dedup: same subject from two telegram clips → listed once.
const dup = [
  { subject: "[[30-Resources/Concepts/A]]", clip: tg("100", "11") },
  { subject: "[[30-Resources/Concepts/A]]", clip: tg("100", "12") },
];
const dDup = buildPromotionDigest(dup);
assert("duplicate subject collapses to one message", 1, dDup.length);
assert("duplicate subject listed once", "📌 Saved → now a subject: [[A]]", dDup[0].text);

// Non-telegram clips never trigger feedback.
const nonTg = [
  { subject: "[[30-Resources/Concepts/A]]", clip: { clipped_via: "web-clipper" } },
  { subject: "[[30-Resources/Concepts/B]]", clip: {} },
];
assert("non-telegram promotions → no messages", 0, buildPromotionDigest(nonTg).length);

// Mixed origin: only the telegram one contributes.
const mixed = [
  { subject: "[[30-Resources/Concepts/A]]", clip: tg("100", "11") },
  { subject: "[[30-Resources/Concepts/B]]", clip: { clipped_via: "web-clipper" } },
];
const dMixed = buildPromotionDigest(mixed);
assert("mixed origin → one message, telegram subject only", 1, dMixed.length);
assert("mixed message lists only the telegram subject", "📌 Saved → now a subject: [[A]]", dMixed[0].text);

// Suppression (migration backfill) → nothing.
assert("suppress=true → no messages", 0, buildPromotionDigest(five, { suppress: true }).length);

// Two chats → one message each (one digest per originating chat).
const twoChats = [
  { subject: "[[30-Resources/Concepts/A]]", clip: tg("100", "11") },
  { subject: "[[30-Resources/Concepts/B]]", clip: tg("200", "21") },
];
assert("two originating chats → two messages (one each)", 2, buildPromotionDigest(twoChats).length);

// A telegram clip with a bare numeric msg id and no chat_id can't be targeted.
const noChat = [{ subject: "[[A]]", clip: { clipped_via: "telegram", telegram_msg_id: "9" } }];
assert("telegram clip without chat_id (bare numeric msg id) → no message", 0, buildPromotionDigest(noChat).length);

// ── Composite bridge id form (real vault shape): telegram-tg-group_<chat>-<msg>[-<drop>]
// Some bridges file the chat+message_id into a single composite telegram_msg_id.
// The digest must derive both the chat AND a NUMERIC reply target from it, with
// no separate telegram_chat_id and no vault backfill.
const single = "telegram-tg-group_-1003985279697-1782605997"; // single message
const drop   = "tg-group_-1003985279697-1782605414-7";        // one drop of a multi-link msg

assert("parseTelegramRef derives chat + numeric msg from a composite id",
  { chatId: "-1003985279697", replyTo: "1782605997" }, parseTelegramRef({ telegram_msg_id: single }));
assert("parseTelegramRef strips the multi-drop suffix to the real message id",
  { chatId: "-1003985279697", replyTo: "1782605414" }, parseTelegramRef({ telegram_msg_id: drop }));
assert("parseTelegramRef prefers an explicit telegram_chat_id over the embedded one",
  { chatId: "777", replyTo: "1782605997" }, parseTelegramRef({ telegram_chat_id: "777", telegram_msg_id: single }));

// A composite-id clip with NO separate chat_id still yields one digest, chat +
// reply_to recovered from the id (the 7 pre-LUNA-91 clips work, zero backfill).
const composite = [{ subject: "[[30-Resources/Concepts/Voicebox]]", clip: { clipped_via: "telegram", telegram_msg_id: single } }];
const dComp = buildPromotionDigest(composite);
assert("composite-id clip (no separate chat_id) → one message", 1, dComp.length);
assert("composite digest targets the embedded chat", "-1003985279697", dComp[0].chat_id);
assert("composite digest threads under the embedded numeric message id", "1782605997", dComp[0].reply_to);

// reply_to is OPTIONAL: a clean chat_id but an unparseable msg id → still sends,
// just unthreaded (reply_to null), never a bogus non-numeric reply target.
const unthreaded = [{ subject: "[[A]]", clip: { clipped_via: "telegram", telegram_chat_id: "555", telegram_msg_id: "weird-id" } }];
const dUnthreaded = buildPromotionDigest(unthreaded);
assert("unparseable msg id with chat_id → one message", 1, dUnthreaded.length);
assert("unparseable msg id → reply_to null (send unthreaded, not a bogus id)", null, dUnthreaded[0].reply_to);

// Helpers.
assert("basenameLink strips the path", "[[Context-Windows]]", basenameLink("[[30-Resources/Concepts/Context-Windows]]"));
assert("renderDigestText pluralizes", "📌 Saved → now subjects: [[A]], [[B]]", renderDigestText(["[[A]]", "[[B]]"]));

// Empty / nullish input is safe.
assert("empty promotions → no messages", 0, buildPromotionDigest([]).length);
assert("null promotions → no messages", 0, buildPromotionDigest(null).length);

console.log("");
console.log(`Results: ${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
