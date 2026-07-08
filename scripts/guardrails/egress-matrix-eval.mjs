#!/usr/bin/env node
// egress-matrix-eval.mjs - CLI wrapper over the egress-matrix reference
// semantics (HIMMEL-766) for shell consumers (graphify-fence.sh, HIMMEL-621/622).
//
// Reuses the SAME first-match-wins evaluation as the reference evaluate() in
// test-egress-matrix.mjs: iterate `rules`, '*' wildcards, then `default`.
// Unlike that helper (which collapses allow+log -> allow for its invariant
// asserts), THIS wrapper PRESERVES the distinction the fence needs:
//   allow       -> permitted, no ledger
//   allow+log   -> permitted, ledger obligation
//   conditional -> permitted ONLY if the caller verifies the rule condition
//   deny        -> refused (pending-operator and any UNKNOWN verdict fail closed)
// No rule match returns `default` (asserted "deny" by the matrix test).
//
// Usage: node egress-matrix-eval.mjs <corpus> <provider> <purpose>
// Prints ONE line to stdout: "<verdict>\t<note>". Exit 0 on a clean
// evaluation, 2 on bad args / unreadable matrix (caller fails closed).
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const [corpus, provider, purpose] = process.argv.slice(2);
if (!corpus || !provider || !purpose) {
  process.stderr.write("egress-matrix-eval: need <corpus> <provider> <purpose>\n");
  process.exit(2);
}

let m;
try {
  const matrixPath = join(dirname(fileURLToPath(import.meta.url)), "egress-matrix.json");
  m = JSON.parse(readFileSync(matrixPath, "utf8"));
} catch (e) {
  process.stderr.write(`egress-matrix-eval: cannot read matrix: ${e?.message ?? e}\n`);
  process.exit(2);
}

function evaluate(c, p, u) {
  for (const r of m.rules) {
    const hit =
      (r.corpus === "*" || r.corpus === c) &&
      (r.provider === "*" || r.provider === p) &&
      (r.purpose === "*" || r.purpose === u);
    if (!hit) continue;
    const verdict =
      r.verdict === "allow" ? "allow" :
      r.verdict === "allow+log" ? "allow+log" :
      r.verdict === "conditional" ? "conditional" :
      "deny"; // deny, pending-operator, and any UNKNOWN verdict fail closed
    return { verdict, note: r.why || r.condition || "" };
  }
  // m.default is asserted "deny" by test-egress-matrix.mjs; treated as effective.
  return { verdict: m.default, note: "default (no rule matched)" };
}

const { verdict, note } = evaluate(corpus, provider, purpose);
process.stdout.write(`${verdict}\t${note}\n`);
