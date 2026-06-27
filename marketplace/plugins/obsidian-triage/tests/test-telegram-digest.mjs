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
import { buildPromotionDigest, basenameLink, renderDigestText } from "../tools/lib/telegram-digest.mjs";

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

// A telegram clip missing chat_id can't be targeted → excluded.
const noChat = [{ subject: "[[A]]", clip: { clipped_via: "telegram", telegram_msg_id: "9" } }];
assert("telegram clip without chat_id → no message", 0, buildPromotionDigest(noChat).length);

// Helpers.
assert("basenameLink strips the path", "[[Context-Windows]]", basenameLink("[[30-Resources/Concepts/Context-Windows]]"));
assert("renderDigestText pluralizes", "📌 Saved → now subjects: [[A]], [[B]]", renderDigestText(["[[A]]", "[[B]]"]));

// Empty / nullish input is safe.
assert("empty promotions → no messages", 0, buildPromotionDigest([]).length);
assert("null promotions → no messages", 0, buildPromotionDigest(null).length);

console.log("");
console.log(`Results: ${pass} passed, ${fail} failed`);
process.exit(fail > 0 ? 1 : 0);
