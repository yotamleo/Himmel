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

// 3. salus: every CLOUD provider x every purpose = hard deny; local-ollama = conditional
for (const p of providers) {
  for (const u of purposes) {
    const { effective, rule } = evaluate("salus", p, u);
    if (p === "local-ollama") {
      assert(effective === "conditional", `salus x ${p} x ${u} must be conditional (per-run opt-in), got ${effective}`);
    } else {
      assert(effective === "deny", `salus x ${p} x ${u} must be deny, got ${effective}`);
      assert(rule && rule.hard === true, `salus x ${p} x ${u} deny must be hard`);
    }
  }
}

// 4. google-gemini denied everywhere, via the HARD rule (pins rule existence,
//    not just the outcome — mirrors the salus pattern)
for (const c of corpora) for (const u of purposes) {
  const { effective, rule } = evaluate(c, "google-gemini", u);
  assert(effective === "deny", `gemini must be denied for ${c} x ${u}`);
  assert(rule && rule.hard === true, `gemini deny for ${c} x ${u} must come from the hard rule`);
}

// 5. EVERY pending-operator cell evaluates as deny — programmatic enumeration,
//    so a future pending cell shadowed by an earlier allow rule fails loudly
// NOTE: the count below is a deletion tripwire. Ratifying a 765 cell
// (pending-operator -> allow+log) legitimately LOWERS it — update the
// expected count consciously in the same PR that flips the cell.
const pendingRules = m.rules.filter(r => r.verdict === "pending-operator");
assert(pendingRules.length >= 5, "expected the five 765 gate cells to be pending-operator (update consciously when ratifying a cell)");
for (const r of pendingRules) {
  const { effective, rule } = evaluate(r.corpus, r.provider, r.purpose);
  assert(effective === "deny" && rule?.verdict === "pending-operator",
    `pending cell ${r.corpus} x ${r.provider} x ${r.purpose} must evaluate deny via its own pending-operator rule (shadowed by an earlier rule?), got ${effective}/${rule?.verdict}`);
}

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
assert(conditionalRules.length >= 5, "expected the salus opt-in + 3 handover brief-scoped + clippings-GLM cells");
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

// 6. Ratified allows stay allowed (regression guard both directions)
assert(evaluate("luna-personal", "deepseek", "extraction").effective === "allow",
  "luna-personal x deepseek x extraction is the ratified operator override (allow+log)");
assert(evaluate("handover-state", "deepseek", "extraction").effective === "allow",
  "handover-state x deepseek x extraction is the ratified operator override (HIMMEL-343, allow+log)");
assert(evaluate("himmel-code", "openai-codex", "inference").effective === "allow",
  "himmel-code x codex impl lane must stay allowed");
assert(evaluate("luna-personal", "zai-glm", "inference").effective === "deny",
  "luna-personal x zai-glm must fall through to default deny");
assert(evaluate("luna-personal", "deepseek", "embedding").effective === "deny",
  "DeepSeek override covers extraction ONLY — embedding must deny");
assert(evaluate("handover-state", "openai-codex", "embedding").effective === "deny",
  "no bulk pipelines over handover-state");

if (failures > 0) {
  console.error(`egress-matrix: ${failures} invariant failure(s)`);
  process.exit(1);
}
console.log("egress-matrix: all invariants pass");
