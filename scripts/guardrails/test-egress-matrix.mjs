#!/usr/bin/env node
// test-egress-matrix.mjs — invariant checks for scripts/guardrails/egress-matrix.json
// (HIMMEL-766). Run: node scripts/guardrails/test-egress-matrix.mjs
//
// evaluate() below is also the REFERENCE semantics for consumers
// (graphify-fence.sh, parity_guard.py, the HIMMEL-765 pilot client):
// first-match-wins over `rules`, '*' wildcards, then `default`;
// `conditional` is allow-only-under-condition; `pending-operator` IS a deny.
// Consumers MUST treat `conditional` as deny unless they positively verify
// the rule's prose `condition` — "anything not deny" is NOT allow.
// An unrecognized verdict string normalizes to deny (fail-closed).
// `allow+log` collapses to effective "allow" but rule.verdict retains
// "allow+log": consumers MUST honor its ledger obligation (a JSONL line per
// run — see semantics.verdicts in the JSON), not just the allow.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const matrixPath = join(dirname(fileURLToPath(import.meta.url)), "egress-matrix.json");
const m = JSON.parse(readFileSync(matrixPath, "utf8"));

function evaluate(corpus, provider, purpose) {
  for (const r of m.rules) {
    const hit =
      (r.corpus === "*" || r.corpus === corpus) &&
      (r.provider === "*" || r.provider === provider) &&
      (r.purpose === "*" || r.purpose === purpose);
    if (!hit) continue;
    const effective =
      r.verdict === "allow" ? "allow" :
      r.verdict === "allow+log" ? "allow" :
      r.verdict === "conditional" ? "conditional" :
      "deny"; // deny, pending-operator, and any UNKNOWN verdict all fail closed
    return { effective, rule: r };
  }
  // m.default is asserted to be "deny" below; treated as already-effective.
  return { effective: m.default, rule: null };
}

let failures = 0;
function assert(cond, msg) {
  if (!cond) { failures++; console.error(`FAIL: ${msg}`); }
}

// assertExplicitDeny: the cell must deny via its OWN explicit `deny` rule (the
// exact corpus×provider×purpose), NOT merely fall through to `default: deny`.
// This pins the HIMMEL-1257 de-listing as legible explicit deny ROWS (the
// audit-trail intent) — deleting a row would silently pass a plain
// `effective === "deny"` check via the default (CodeRabbit HIMMEL-1257).
function assertExplicitDeny(corpus, provider, purpose, msg) {
  const { effective, rule } = evaluate(corpus, provider, purpose);
  assert(effective === "deny", `${msg} — effective must be deny, got ${effective}`);
  assert(rule && rule.verdict === "deny" && rule.corpus === corpus &&
         rule.provider === provider && rule.purpose === purpose,
    `${msg} — must deny via an EXPLICIT ${corpus} x ${provider} x ${purpose} deny rule, not default-deny (got ${rule ? `${rule.corpus} x ${rule.provider} x ${rule.purpose} = ${rule.verdict}` : "default"})`);
}

const corpora = Object.keys(m.corpora);
const providers = Object.keys(m.providers);
const purposes = m.purposes;

// 1. Structure
assert(m.default === "deny", "default must be deny (fail-closed)");
assert(Array.isArray(m.rules) && m.rules.length > 0, "rules present");

// 2. Every rule references declared corpora/providers/purposes (or '*')
for (const [i, r] of m.rules.entries()) {
  assert(r.corpus === "*" || corpora.includes(r.corpus), `rule[${i}] unknown corpus ${r.corpus}`);
  assert(r.provider === "*" || providers.includes(r.provider), `rule[${i}] unknown provider ${r.provider}`);
  assert(r.purpose === "*" || purposes.includes(r.purpose), `rule[${i}] unknown purpose ${r.purpose}`);
  assert(["allow", "allow+log", "conditional", "deny", "pending-operator"].includes(r.verdict),
    `rule[${i}] unknown verdict ${r.verdict}`);
  if (r.verdict === "conditional") assert(typeof r.condition === "string" && r.condition.length > 0,
    `rule[${i}] conditional without condition`);
  if (r.verdict === "pending-operator") assert(typeof r.decision_needed === "string",
    `rule[${i}] pending-operator without decision_needed`);
}

// 3. salus: every CLOUD provider x every purpose = hard deny; local-ollama = conditional.
//    EXCEPTION (2026-08-15 operator ruling, HIMMEL-1774): the openrouter cell keeps
//    verdict deny (the default does NOT change) but is deliberately NOT hard — the
//    cell is operator-configurable (A-tier provider, adopter portability). Every
//    OTHER provider keeps its hard deny.
for (const p of providers) {
  for (const u of purposes) {
    const { effective, rule } = evaluate("salus", p, u);
    if (p === "local-ollama") {
      assert(effective === "conditional", `salus x ${p} x ${u} must be conditional (per-run opt-in), got ${effective}`);
    } else if (p === "openrouter") {
      assert(effective === "deny", `salus x ${p} x ${u} must stay deny by default (configurable ≠ open), got ${effective}`);
      assert(rule && rule.provider === "openrouter" && rule.hard === undefined,
        `salus x ${p} x ${u} must deny via its OWN non-hard openrouter row (operator-configurable, 2026-08-15 ruling), got ${rule ? `hard=${rule.hard}` : "default"}`);
    } else {
      assert(effective === "deny", `salus x ${p} x ${u} must be deny, got ${effective}`);
      assert(rule && rule.hard === true, `salus x ${p} x ${u} deny must be hard`);
    }
  }
}
// 3a. The NON-openrouter salus wildcard row is STILL hard — the 2026-08-15
//     configurability ruling is scoped to the openrouter provider ONLY.
const salusWildcard = m.rules.find(r => r.corpus === "salus" && r.provider === "*" && r.purpose === "*");
assert(salusWildcard && salusWildcard.verdict === "deny" && salusWildcard.hard === true,
  "salus x * x * wildcard deny must stay HARD (only the openrouter cell is configurable)");

// 3b. voice-audio: every NON-LOCAL provider x every purpose = hard deny;
//     local-speech = allow (HIMMEL-1522). EXCEPTION (2026-08-15 ruling,
//     HIMMEL-1774): the openrouter cell stays deny but is NOT hard —
//     operator-configurable, same scoped ruling as salus above.
//
// Held at the salus tier deliberately. The salus deny keys on file paths and
// speech has none, so a mic streaming to a cloud API would bypass the PHI
// perimeter with nothing to inspect. Audio cannot be classified before it is
// heard, so all of it is treated as maximally sensitive. Asserted the same way
// as salus — rule existence AND hardness, not just the outcome — so a later
// rule reordering that shadows the deny fails loudly instead of silently
// opening a mic to the network.
for (const p of providers) {
  for (const u of purposes) {
    const { effective, rule } = evaluate("voice-audio", p, u);
    if (p === "local-speech") {
      // Allowed for SPEECH purposes only. The original rule granted
      // purpose "*", which also permitted inference/extraction/embedding on a
      // provider documented as STT/TTS-only — a wider grant than the provider
      // can justify, and this test asserted that width as if it were intended.
      if (u === "stt" || u === "tts") {
        assert(effective === "allow", `voice-audio x ${p} x ${u} must be allow (on-machine speech), got ${effective}`);
      } else {
        assert(effective === "deny", `voice-audio x ${p} x ${u} must be deny — local-speech is STT/TTS only, got ${effective}`);
      }
    } else if (p === "openrouter") {
      assert(effective === "deny", `voice-audio x ${p} x ${u} must stay deny by default (configurable ≠ open), got ${effective}`);
      assert(rule && rule.provider === "openrouter" && rule.hard === undefined,
        `voice-audio x ${p} x ${u} must deny via its OWN non-hard openrouter row (operator-configurable, 2026-08-15 ruling), got ${rule ? `hard=${rule.hard}` : "default"}`);
    } else {
      assert(effective === "deny", `voice-audio x ${p} x ${u} must be deny, got ${effective}`);
      assert(rule && rule.hard === true, `voice-audio x ${p} x ${u} deny must be hard`);
    }
  }
}
// 3c. The NON-openrouter voice-audio wildcard row is STILL hard (scoped ruling).
const voiceWildcard = m.rules.find(r => r.corpus === "voice-audio" && r.provider === "*" && r.purpose === "*");
assert(voiceWildcard && voiceWildcard.verdict === "deny" && voiceWildcard.hard === true,
  "voice-audio x * x * wildcard deny must stay HARD (only the openrouter cell is configurable)");
// An unlisted provider must not reach the mic either (default fail-closed).
assert(evaluate("voice-audio", "brand-new-provider", "stt").effective === "deny",
  "voice-audio must deny an unlisted provider");
// local-speech is scoped to audio ONLY — it must not become a backdoor that
// reads the vaults or PHI just because it is marked local.
assert(evaluate("salus", "local-speech", "stt").effective === "deny",
  "local-speech must NOT reach salus");
for (const c of ["luna-personal", "luna-clippings", "handover-state"]) {
  assert(evaluate(c, "local-speech", "stt").effective === "deny",
    `local-speech must not reach ${c} — it is an audio-only provider`);
}

// 4. google-gemini denied everywhere, via the HARD rule (pins rule existence,
//    not just the outcome — mirrors the salus pattern)
for (const c of corpora) for (const u of purposes) {
  const { effective, rule } = evaluate(c, "google-gemini", u);
  assert(effective === "deny", `gemini must be denied for ${c} x ${u}`);
  assert(rule && rule.hard === true, `gemini deny for ${c} x ${u} must come from the hard rule`);
}

// 5. EVERY pending-operator cell evaluates as deny — programmatic enumeration,
//    so a future pending cell shadowed by an earlier allow rule fails loudly.
// HIMMEL-1257: the five HIMMEL-765 Alibaba cells were demoted from
// pending-operator to explicit deny (Alibaba de-listed, bad results), so there
// are now ZERO pending-operator cells. The enumeration loop below still runs
// (no-op on empty). A future pending cell would (correctly) trip the === 0
// tripwire, forcing a conscious count update in the PR that adds it.
const pendingRules = m.rules.filter(r => r.verdict === "pending-operator");
assert(pendingRules.length === 0, "expected ZERO pending-operator cells (the five 765 Alibaba cells were denied by HIMMEL-1257; update consciously if a new pending cell is added)");
for (const r of pendingRules) {
  const { effective, rule } = evaluate(r.corpus, r.provider, r.purpose);
  assert(effective === "deny" && rule?.verdict === "pending-operator",
    `pending cell ${r.corpus} x ${r.provider} x ${r.purpose} must evaluate deny via its own pending-operator rule (shadowed by an earlier rule?), got ${effective}/${rule?.verdict}`);
}

// 5e. The luna-personal x deepseek x enrichment cell must exist and, since
//     HIMMEL-1257 (DeepSeek de-listed), must be `deny` (the 2026-07-10
//     HIMMEL-833 allow+log ratification was reversed). Pins that the cell is
//     not silently deleted and stays denied.
const enrichmentRule = m.rules.find(r =>
  r.corpus === "luna-personal" && r.provider === "deepseek" && r.purpose === "enrichment");
assert(enrichmentRule, "missing luna-personal x deepseek x enrichment rule (HIMMEL-833/1257)");
assert(enrichmentRule.verdict === "deny",
  `enrichment cell must be deny post-HIMMEL-1257 (DeepSeek de-listed), got ${enrichmentRule.verdict}`);

// 5b. Fail-closed for UNDECLARED inputs — the exact shape a resolver bug
//     produces (a path that fails to classify into a known corpus)
assert(evaluate("mystery-corpus", "mystery-provider", "mystery-purpose").effective === "deny",
  "fully unknown triple must fall through to default deny");
assert(evaluate("luna-personal", "brand-new-provider", "inference").effective === "deny",
  "unknown provider on a non-wildcard corpus must deny");
assert(evaluate("luna-personal", "deepseek", "unknown-purpose").effective === "deny",
  "unknown purpose must deny");
assert(evaluate("mystery-corpus", "google-gemini", "inference").effective === "deny",
  "unknown corpus x gemini must deny");

// 5d. EVERY conditional rule's own triple evaluates as "conditional" —
//     programmatic, so a typo'd conditional->allow on the CN brief-egress
//     cells (or a shadowing earlier rule) fails loudly
const conditionalRules = m.rules.filter(r => r.verdict === "conditional");
assert(conditionalRules.length >= 2, "expected the salus opt-in + the handover-state x openai-codex brief-scoped cell (the alibaba brief cell was denied by HIMMEL-1257; the zai-glm handover-brief + clippings-GLM cells by HIMMEL-2224)");
for (const r of conditionalRules) {
  const probe = {
    corpus: r.corpus === "*" ? corpora[0] : r.corpus,
    provider: r.provider === "*" ? "local-ollama" : r.provider,
    purpose: r.purpose === "*" ? purposes[0] : r.purpose,
  };
  const { effective, rule } = evaluate(probe.corpus, probe.provider, probe.purpose);
  assert(effective === "conditional" && rule?.verdict === "conditional" && rule.condition === r.condition,
    `conditional cell ${probe.corpus} x ${probe.provider} x ${probe.purpose} must evaluate conditional via its own rule, got ${effective}/${rule?.verdict}`);
}

// 5c. Pin the ONE deliberate wildcard widening surface so it stays a conscious,
//     visible test change: himmel-code allows ANY declared-or-new provider
//     (public-propagated code; gemini already excluded by the earlier hard rule)
assert(evaluate("himmel-code", "brand-new-provider", "inference").effective === "allow",
  "himmel-code x * x * is the deliberate allow-all (change this test consciously if narrowing)");

// 6. Regression guard both directions.
// HIMMEL-1257: DeepSeek + Alibaba de-listed for vault/handover egress (bad
// results); the sanctioned set is GLM (zai-glm) + Claude (anthropic) + Codex
// (openai-codex). himmel-code stays provider-agnostic (public code).
// Each de-listed cell must deny via its OWN explicit deny row (not default-deny).
assertExplicitDeny("luna-personal", "deepseek", "extraction",
  "luna-personal x deepseek x extraction — DeepSeek de-listed (HIMMEL-1257), was the reversed 2026-07-05 override");
assertExplicitDeny("handover-state", "deepseek", "extraction",
  "handover-state x deepseek x extraction — DeepSeek de-listed (HIMMEL-1257), was the reversed HIMMEL-343 ratification");
assertExplicitDeny("luna-personal", "deepseek", "enrichment",
  "luna-personal x deepseek x enrichment — DeepSeek de-listed (HIMMEL-1257), was the reversed HIMMEL-833 ratification");
assertExplicitDeny("handover-state", "alibaba", "inference",
  "handover-state x alibaba x inference — Alibaba de-listed (HIMMEL-1257); the brief-scoped worker cell is denied");
assertExplicitDeny("luna-personal", "alibaba", "embedding",
  "luna-personal x alibaba x embedding — Alibaba de-listed, 765 pilot not pursued (HIMMEL-1257)");
// The sanctioned providers stay as-ratified (guard against over-broad edits).
// HIMMEL-2224: zai-glm de-listed too — landing HIMMEL-1749's DROP branch (GLM
// Coding Plan auto-renew cancelled 2026-08-12, plan lapsed 2026-08-17). Same
// legible-reversal pattern: four explicit deny ROWS, not deleted rows. moonshot
// (HIMMEL-1748) is the replacement CN extraction lane.
assertExplicitDeny("luna-personal", "zai-glm", "extraction",
  "luna-personal x zai-glm x extraction — GLM lane dropped (HIMMEL-2224/1749), was the reversed HIMMEL-1122 ratification");
assertExplicitDeny("luna-personal", "zai-glm", "enrichment",
  "luna-personal x zai-glm x enrichment — GLM lane dropped (HIMMEL-2224/1749), was the reversed HIMMEL-1167 ratification");
assertExplicitDeny("luna-clippings", "zai-glm", "extraction",
  "luna-clippings x zai-glm x extraction — GLM lane dropped (HIMMEL-2224/1749); the narrow G2.3 ladder exception is denied");
assertExplicitDeny("handover-state", "zai-glm", "inference",
  "handover-state x zai-glm x inference — GLM lane dropped (HIMMEL-2224/1749); the brief-scoped worker cell is denied");
assert(evaluate("himmel-code", "zai-glm", "inference").effective === "allow",
  "himmel-code x zai-glm stays allow — de-listing is for private-content egress, not public code (wildcard)");
assert(evaluate("handover-state", "openai-codex", "inference").rule?.verdict === "conditional",
  "handover-state x openai-codex x inference must STAY the brief-scoped conditional (the zai-glm de-listing must not touch the codex worker cell)");
assert(evaluate("luna-personal", "moonshot", "extraction").rule?.verdict === "allow+log",
  "luna-personal x moonshot x extraction must be allow+log (HIMMEL-1748)");
assert(evaluate("luna-clippings", "moonshot", "extraction").rule?.verdict === "allow+log",
  "luna-clippings x moonshot x extraction must be allow+log (HIMMEL-1748)");
assert(evaluate("luna-personal", "moonshot", "enrichment").effective === "deny",
  "luna-personal x moonshot x enrichment must stay denied (unratified purpose)");
assert(evaluate("salus", "moonshot", "extraction").effective === "deny",
  "salus x moonshot x extraction must be hard denied");
assert(evaluate("himmel-code", "openai-codex", "inference").effective === "allow",
  "himmel-code x codex impl lane must stay allowed");
assert(evaluate("himmel-code", "deepseek", "inference").effective === "allow",
  "himmel-code x deepseek stays allow — de-listing is for private-content egress, not public code (wildcard)");
assert(evaluate("luna-personal", "zai-glm", "inference").rule === null,
  "luna-personal x zai-glm x inference must still fall through to DEFAULT deny — the HIMMEL-2224 de-listing adds explicit deny rows only for the four cells that were open, it does not invent new rows");
assert(evaluate("luna-personal", "deepseek", "embedding").effective === "deny",
  "luna-personal x deepseek x embedding must deny (DeepSeek de-listed; no embedding cell existed anyway)");
assert(evaluate("handover-state", "openai-codex", "embedding").effective === "deny",
  "no bulk pipelines over handover-state");

// 7. OpenRouter (HIMMEL-1774): declared as its OWN provider — content transits
//    the aggregator, a different trust boundary from the vendor cells, so the
//    anthropic allowances do NOT carry over. Operator ruling pinned per cell:
//    ALLOW himmel-code + handover-state (inference — the scripts/claude-openrouter
//    lane, whose hard gate authorizes ONLY on an explicit provider:"openrouter"
//    rule); DENY salus + voice-audio and luna-personal + luna-clippings.
//    2026-08-15 operator ruling: ALL FOUR openrouter deny cells are deliberately
//    OPERATOR-CONFIGURABLE — verdict stays deny (nothing is opened by that
//    ruling), but `hard` is absent so an operator can later ratify an open by
//    editing the cell. wantHard below therefore asserts NON-hard for the deny
//    cells (hard === undefined), pinning the configurability decision itself.
//    Each cell is asserted via its OWN explicit row (not the wildcards and not
//    default-deny), so deleting or shadowing a ruling row fails loudly.
function assertOpenRouterCell(corpus, purpose, wantVerdict, wantHard, msg) {
  const { effective, rule } = evaluate(corpus, "openrouter", purpose);
  assert(effective === wantVerdict, `${msg} — effective must be ${wantVerdict}, got ${effective}`);
  assert(rule && rule.provider === "openrouter" && rule.corpus === corpus,
    `${msg} — must resolve via an EXPLICIT ${corpus} x openrouter rule, got ${rule ? `${rule.corpus} x ${rule.provider}` : "default"}`);
  if (wantHard === true) assert(rule.hard === true, `${msg} — the explicit rule must be hard`);
  if (wantHard === false) assert(rule.hard === undefined,
    `${msg} — the explicit rule must be NON-hard (operator-configurable, 2026-08-15 ruling), got hard=${rule.hard}`);
}
assertOpenRouterCell("himmel-code", "inference", "allow", null,
  "himmel-code x openrouter x inference — the lane's authorizing cell (HIMMEL-1774)");
assertOpenRouterCell("handover-state", "inference", "allow", null,
  "handover-state x openrouter x inference — substrate-shaped session lane (HIMMEL-1774)");
assertOpenRouterCell("salus", "extraction", "deny", false,
  "salus x openrouter — PHI denied by default, cell operator-configurable (HIMMEL-1774 + 2026-08-15 ruling)");
assertOpenRouterCell("voice-audio", "stt", "deny", false,
  "voice-audio x openrouter — audio denied by default, cell operator-configurable (HIMMEL-1774 + 2026-08-15 ruling)");
assertOpenRouterCell("luna-personal", "inference", "deny", false,
  "luna-personal x openrouter — vault DENY per ruling (HIMMEL-1774)");
assertOpenRouterCell("luna-clippings", "extraction", "deny", false,
  "luna-clippings x openrouter — vault DENY per ruling (HIMMEL-1774)");
// The allows are inference-ONLY: the lane must not silently become a bulk
// extraction/embedding pipeline over the transit vendor. (himmel-code's
// non-inference purposes stay covered by its deliberate wildcard allow-all.)
assert(evaluate("luna-personal", "openrouter", "enrichment").effective === "deny",
  "luna-personal x openrouter x enrichment must deny");
assert(evaluate("handover-state", "openrouter", "embedding").effective === "deny",
  "handover-state x openrouter x embedding must deny (no bulk pipelines over the transit vendor)");

if (failures > 0) {
  console.error(`egress-matrix: ${failures} invariant failure(s)`);
  process.exit(1);
}
console.log("egress-matrix: all invariants pass");
