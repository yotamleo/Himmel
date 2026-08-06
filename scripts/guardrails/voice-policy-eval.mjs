#!/usr/bin/env node
// voice-policy-eval.mjs — CLI over voice-policy.json (HIMMEL-1522).
//
// Deliberately shaped like egress-matrix-eval.mjs: same first-match-wins walk,
// same one-line tab-separated output, same "unknown fails to the safe side"
// posture. A consumer that already speaks to one can speak to the other.
//
// The safe side differs, though, and the difference is intentional:
//   egress   unknown -> deny    (sending the wrong thing is unrecoverable)
//   voice    unknown -> confirm (asking is safe AND keeps the assistant usable)
//
// Usage: node voice-policy-eval.mjs <action>
// Prints ONE line: "<verdict>\t<why>". Exit 0 on a clean evaluation,
// 2 on bad args or an unreadable policy (caller must fail safe).
import { readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

export function evaluate(policy, act) {
  for (const r of policy.rules) {
    if (r.action !== "*" && r.action !== act) continue;
    // Anything not explicitly allow/deny collapses to confirm. An unrecognised
    // verdict must not read as permission.
    const verdict =
      r.verdict === "allow" ? "allow" :
      r.verdict === "deny" ? "deny" :
      "confirm";
    return { verdict, why: r.why || "", rule: r };
  }
  return { verdict: policy.default ?? "confirm", why: "default (no rule matched)", rule: null };
}

// CLI only when run directly. Without this guard, importing evaluate() from a
// test runs the arg check and exits 2 before a single assertion executes.
const invokedDirectly =
  process.argv[1] && fileURLToPath(import.meta.url) === resolve(process.argv[1]);

if (invokedDirectly) {
  const [action] = process.argv.slice(2);
  if (!action) {
    process.stderr.write("voice-policy-eval: need <action>\n");
    process.exit(2);
  }
  let p;
  try {
    const path = join(dirname(fileURLToPath(import.meta.url)), "voice-policy.json");
    p = JSON.parse(readFileSync(path, "utf8"));
  } catch (e) {
    process.stderr.write(`voice-policy-eval: cannot read policy: ${e?.message ?? e}\n`);
    process.exit(2);
  }
  const { verdict, why } = evaluate(p, action);
  process.stdout.write(`${verdict}\t${why}\n`);
}
