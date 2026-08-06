// scripts/telegram/round-guard.test.ts — HIMMEL-1553 symptom-brief loop breaker.
// Every refusal case asserts the specific REASON STRINGS, not rc/shape alone:
// exit-code-only assertions are how a fail-closed bug reads as a fail-closed
// feature (HIMMEL-1554 — the 1540 test suite passed on the WRONG refusal for
// four rounds).
import { expect, test } from "bun:test";
import {
  ROUND_WARN_THRESHOLD,
  ROUND_ESCALATE_THRESHOLD,
  ROUNDS_OVERRIDE_MIN_CHARS,
  INVARIANT_MIN_CHARS,
  extractTicketKey,
  countReviewedRounds,
  hasSubstantiveInvariant,
  checkRoundGuard,
} from "./round-guard";

const avail = (branch: string, head: string) =>
  JSON.stringify({ kind: "avail", branch, head, model: "codex", status: "ok" });
const finding = (branch: string, head: string, severity = "imp", verdict = "agreed", id = "codex-1") =>
  JSON.stringify({ kind: "finding", branch, head, model: "codex", finding_id: id, severity, verdict });

const INVARIANT_BRIEF = [
  "fix HIMMEL-1540",
  "INVARIANT:",
  "the certificate binds one identity (the reviewed sha) across all four consumers of the marker.",
].join("\n");

// ── extractTicketKey ─────────────────────────────────────────────────────────
test("ticket key: branch wins over name and task", () => {
  expect(extractTicketKey("fix/himmel-1540-cr", "himmel-9-x", "do HIMMEL-7")).toBe("HIMMEL-1540");
});

test("ticket key: name (own-mode slug) is case-insensitive", () => {
  expect(extractTicketKey(undefined, "himmel-1540-marker-fix", "task")).toBe("HIMMEL-1540");
});

test("ticket key: task text matches UPPERCASE keys only", () => {
  expect(extractTicketKey(undefined, undefined, "Fix HIMMEL-1540 now")).toBe("HIMMEL-1540");
  // lowercase prose must not read as a ticket ("bash-3.2-safe" -> "bash-3")
  expect(extractTicketKey(undefined, undefined, "keep it bash-3.2-safe")).toBeUndefined();
});

test("ticket key: none anywhere -> undefined (guard fails open)", () => {
  expect(extractTicketKey("feat/no-ticket-here-x", undefined, "explore the repo")).toBeUndefined();
});

test("ticket key: HIMMEL-154 does not truncate out of HIMMEL-1540", () => {
  expect(extractTicketKey("fix/himmel-1540-x", undefined, "t")).toBe("HIMMEL-1540");
  const rounds = countReviewedRounds([avail("fix/himmel-1540-x", "aaaaaaa1")], "HIMMEL-154", "fix/himmel-1540-x");
  expect(rounds.rounds).toBe(0);
});

test("ticket boundary: a letter suffix is NOT the ticket (codex-2 — himmel-1540abc)", () => {
  // extraction: himmel-1540abc must not read as HIMMEL-1540 from any source
  expect(extractTicketKey("fix/himmel-1540abc", undefined, "t")).toBeUndefined();
  expect(extractTicketKey(undefined, undefined, "see HIMMEL-1540abc")).toBeUndefined();
  // counting: a himmel-1540abc branch contributes NO HIMMEL-1540 rounds
  expect(countReviewedRounds([avail("fix/himmel-1540abc", "aaaaaaa1")], "HIMMEL-1540", "fix/himmel-1540abc").rounds).toBe(0);
  // a hyphen still bounds — the normal slug shape keeps matching
  expect(countReviewedRounds([finding("fix/himmel-1540-x", "aaaaaaa1")], "HIMMEL-1540", "fix/himmel-1540-x").rounds).toBe(1);
});

// ── countReviewedRounds ──────────────────────────────────────────────────────
test("rounds: short and full forms of the same blocking head count once", () => {
  const full = "a5e73acb0ce202da8722567753debf091258090d";
  const lines = [avail("fix/himmel-1540-x", full), finding("fix/himmel-1540-x", full.slice(0, 8))];
  expect(countReviewedRounds(lines, "HIMMEL-1540", "fix/himmel-1540-x").rounds).toBe(1);
});

test("rounds: clean and parallel branches do not escalate the active branch", () => {
  const lines = [
    finding("fix/himmel-1540-a", "1111111abc"),
    finding("glm/himmel-1540-b", "2222222abc"),
    avail("claudex/himmel-1540-c", "3333333abc"),
  ];
  expect(countReviewedRounds(lines, "HIMMEL-1540", "feat/himmel-1540-active").rounds).toBe(0);
});

test("rounds: a clean review resets the active branch's consecutive blocking sequence", () => {
  const branch = "feat/himmel-1540-active";
  const lines = [
    finding(branch, "1111111abc"),
    finding(branch, "2222222abc"),
    avail(branch, "3333333abc"),
    finding(branch, "4444444abc"),
  ];
  expect(countReviewedRounds(lines, "HIMMEL-1540", branch)).toEqual({ rounds: 1, heads: ["4444444"] });
});

test("rounds: a FAILED critic attempt is not a round; a blocking finding row is (adversarial r3)", () => {
  const branch = "fix/himmel-1540-x";
  const availBad = JSON.stringify({ kind: "avail", branch, head: "aaaaaaa1", model: "codex", status: "unavailable" });
  // unavailable-only head -> zero rounds (a missing signal, not a review)
  expect(countReviewedRounds([availBad], "HIMMEL-1540", branch).rounds).toBe(0);
  // a finding at the same head IS evidence a critic responded and blocked
  expect(countReviewedRounds([availBad, finding(branch, "aaaaaaa1")], "HIMMEL-1540", branch).rounds).toBe(1);
});

test("rounds: non-blocking findings are clean reviews, not failed cycles", () => {
  const branch = "fix/himmel-1540-x";
  const lines = [
    finding(branch, "1111111abc"),
    finding(branch, "2222222abc", "sug"),
    finding(branch, "3333333abc", "crit", "disproved"),
  ];
  expect(countReviewedRounds(lines, "HIMMEL-1540", branch).rounds).toBe(0);
});

test("rounds: other tickets, malformed lines, empty heads, non-review kinds are ignored", () => {
  const branch = "fix/himmel-1540-x";
  const lines = [
    finding("fix/himmel-1541-x", "4444444abc"),        // other ticket and branch
    "not json at all",                                   // malformed -> skipped (counter, not gate)
    JSON.stringify({ kind: "avail", branch, head: "", model: "m", status: "ok" }),
    JSON.stringify({ kind: "usage", branch, head: "5555555abc" }),
    JSON.stringify({ kind: "amend", branch, target_head: "6666666abc" }),
  ];
  expect(countReviewedRounds(lines, "HIMMEL-1540", branch).rounds).toBe(0);
});

// ── hasSubstantiveInvariant ──────────────────────────────────────────────────
test("invariant: absent, token-only, and thin all fail the floor", () => {
  expect(hasSubstantiveInvariant("fix the marker bug")).toBe(false);
  expect(hasSubstantiveInvariant("INVARIANT:")).toBe(false);
  expect(hasSubstantiveInvariant("INVARIANT: fix it")).toBe(false);
  // case-sensitive: the token is a deliberate act
  expect(hasSubstantiveInvariant("invariant: " + "x".repeat(INVARIANT_MIN_CHARS))).toBe(false);
});

// Divergence regression: cr-pending-audit.sh applies amends SEQUENTIALLY, so a
// set.head re-key moves the finding and the NEXT amend matches the moved head.
// Pre-merging by (head, identity) filed the two amends in different buckets and
// silently dropped the second — the counter then read a corrected finding as
// still blocking. Asserted as a ROUND COUNT, since that is the only thing a
// caller can observe.
test("rounds: a chained amend (re-key, then disprove) is applied, as the audit does it", () => {
  const branch = "fix/himmel-1540-x";
  const ledger = [
    finding(branch, "aaaaaaa1"),
    JSON.stringify({ kind: "amend", branch, target_head: "aaaaaaa1", finding_id: "codex-1", set: { head: "bbbbbbb2" } }),
    JSON.stringify({ kind: "amend", branch, target_head: "bbbbbbb2", finding_id: "codex-1", set: { verdict: "disproved" } }),
  ];
  // Pre-merge kept verdict "agreed" here and returned 1.
  expect(countReviewedRounds(ledger, "HIMMEL-1540", branch).rounds).toBe(0);
});

test("invariant: a labelled line inside the body does not end the section", () => {
  const brief = [
    "fix HIMMEL-1540",
    "INVARIANT:",
    "A: the certificate binds one identity — the reviewed sha — across all four consumers of the marker.",
  ].join("\n");
  // `^[A-Z][A-Z0-9 _/-]*:` broke on the bare "A:", leaving an empty body and
  // refusing a brief that had in fact stated its invariant.
  expect(hasSubstantiveInvariant(brief)).toBe(true);
  // ...but a real header, down to the shortest one in use, still ends it.
  const withHeader = [
    "fix HIMMEL-1540",
    "INVARIANT:",
    "WHY:",
    "the certificate binds one identity across all four consumers of the marker, which is plenty long.",
  ].join("\n");
  expect(hasSubstantiveInvariant(withHeader)).toBe(false);
});

test("invariant: substantive multi-line section passes", () => {
  expect(hasSubstantiveInvariant(INVARIANT_BRIEF)).toBe(true);
});

test("invariant: empty section does not borrow long trailing sections", () => {
  const brief = [
    "fix HIMMEL-1540",
    "INVARIANT:",
    "FILES:",
    "scripts/telegram/round-guard.ts contains plenty of unrelated implementation detail after the empty section.",
    "STEPS:",
    "Make the requested change and run every focused regression suite before reporting completion.",
  ].join("\n");
  expect(hasSubstantiveInvariant(brief)).toBe(false);
});

test("invariant: pasted refusal template is not an authored section", () => {
  const pasted = [
    "spawn-glm: REFUSED (round guard, HIMMEL-1553)",
    "Re-dispatch with a line-delimited section in the brief:",
    "INVARIANT:",
    "  <the single property every prior round's defect violated — what the fix must preserve, stated so a reviewer can check the WHOLE change against it>",
    "FILES:",
    "  <the files in scope; this next ALL-CAPS section header ends the invariant body>",
  ].join("\n");
  expect(hasSubstantiveInvariant(pasted)).toBe(false);
});

// ── checkRoundGuard (two-stage decision) ─────────────────────────────────────
const ACTIVE_BRANCH = "fix/himmel-1540-x";
const mkLedger = (n: number) => {
  const lines: string[] = [];
  for (let i = 0; i < n; i++) lines.push(finding(ACTIVE_BRANCH, `${i}`.repeat(7) + "abc", "imp", "agreed", `codex-${i}`));
  return lines;
};
const guardArgs = (task: string, roundsOverride?: string) => ({ task, branch: ACTIVE_BRANCH, cwd: ".", roundsOverride });

test("stage 0: under the warn threshold -> silent pass", () => {
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540"), () => mkLedger(ROUND_WARN_THRESHOLD - 1));
  expect(r.refusal).toBeUndefined();
  expect(r.note).toBeUndefined();
});

test("stage 1: warn threshold without invariant -> refusal names ticket, rounds, second-drift doctrine, remedy", () => {
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540 again"), () => mkLedger(ROUND_WARN_THRESHOLD));
  expect(r.refusal).toBeDefined();
  expect(r.refusal).toContain("HIMMEL-1540");
  expect(r.refusal).toContain(`${ROUND_WARN_THRESHOLD} consecutive blocking reviews`);
  expect(r.refusal).toContain("names no invariant");
  expect(r.refusal).toContain("second drift");
  expect(r.refusal).toContain("INVARIANT:");
  expect(r.refusal).toContain("HIMMEL-1553");
});

test("stage 1: warn threshold WITH substantive invariant -> pass, note warns of the escalate stage", () => {
  const r = checkRoundGuard("spawn-claudex", guardArgs(INVARIANT_BRIEF), () => mkLedger(ROUND_WARN_THRESHOLD));
  expect(r.refusal).toBeUndefined();
  expect(r.note).toContain("HIMMEL-1540");
  expect(r.note).toContain("INVARIANT section present");
  expect(r.note).toContain(`${ROUND_ESCALATE_THRESHOLD} consecutive blocking reviews`);
});

test("stage 2: escalate threshold refuses the CHEAP LANE even with a perfect invariant", () => {
  const r = checkRoundGuard("spawn-glm", guardArgs(INVARIANT_BRIEF), () => mkLedger(ROUND_ESCALATE_THRESHOLD));
  expect(r.refusal).toBeDefined();
  expect(r.refusal).toContain("buying another cheap-lane round is the failure mode itself");
  expect(r.refusal).toContain("judgment-tier lane");
  expect(r.refusal).toContain("--rounds-override");
  expect(r.refusal).toContain("HIMMEL-1553");
});

test("stage 2: refusal names the abstraction as the escalation task, never the newest defect", () => {
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540"), () => mkLedger(ROUND_ESCALATE_THRESHOLD));
  expect(r.refusal).toContain("state the invariant all");
  expect(r.refusal).toContain("never the newest defect");
});

test("stage 2: valid --rounds-override passes with a loud note recording the reason", () => {
  const why = "mechanical nit batch, no open crit/imp design question";
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540", why), () => mkLedger(ROUND_ESCALATE_THRESHOLD));
  expect(r.refusal).toBeUndefined();
  expect(r.note).toContain("OVERRIDE");
  expect(r.note).toContain(why);
});

test("stage 2: a too-short override reason still refuses and names the floor", () => {
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540", "because"), () => mkLedger(ROUND_ESCALATE_THRESHOLD));
  expect(r.refusal).toBeDefined();
  expect(r.refusal).toContain(`${ROUNDS_OVERRIDE_MIN_CHARS} chars`);
  expect(r.refusal).toContain("the reason given was too short");
});

test("override also satisfies stage 1 (stronger authority than the invariant)", () => {
  const why = "operator-directed respin, invariant tracked in the PR body";
  const r = checkRoundGuard("spawn-glm", guardArgs("fix HIMMEL-1540", why), () => mkLedger(ROUND_WARN_THRESHOLD));
  expect(r.refusal).toBeUndefined();
  expect(r.note).toContain("OVERRIDE");
});

test("fail-open: no ticket key -> pass even over a hot ledger", () => {
  const r = checkRoundGuard("spawn-glm", { task: "general refactor", cwd: "." }, () => mkLedger(9));
  expect(r.refusal).toBeUndefined();
});

test("shared-mode --branch drives extraction and active-lifecycle counting", () => {
  const branch = "glm/himmel-1540-cr";
  const ledger = Array.from({ length: ROUND_ESCALATE_THRESHOLD }, (_, i) =>
    finding(branch, `${i}`.repeat(7) + "abc", "imp", "agreed", `codex-${i}`));
  const r = checkRoundGuard("spawn-glm", { task: "apply CR round fixes", branch, cwd: "." }, () => ledger);
  expect(r.refusal).toContain("HIMMEL-1540");
});

test("fail-open: unreadable/missing ledger (default reader on a non-repo cwd)", () => {
  const r = checkRoundGuard("spawn-glm", { task: "fix HIMMEL-1540", cwd: "/nonexistent-dir-himmel-1553" });
  expect(r.refusal).toBeUndefined();
});

// PROPERTY LOCK, NOT A REGRESSION TEST — and the distinction is deliberate.
// A whitespace-only --name is truthy, so the pre-fix derivation sanitised it to
// "" and built the malformed branch `glm/`. That was worth removing, but it was
// NOT reachable as a behaviour change: the ticket filter in countReviewedRounds
// requires the ledger branch to CONTAIN the ticket key, and `glm/` never can, so
// the pre-fix path already failed open — identically to the fix.
// This test was RUN AGAINST THE PRE-FIX CODE AND PASSED (30/30). It is kept as a
// forward guard: if branch matching ever loosens, the blank-name path becomes
// reachable and this catches it. It is explicitly not evidence the fix changed
// behaviour, and must not be cited as such.
test("blank --name is treated as anonymous, not as the malformed branch `glm/`", () => {
  const ledger = Array.from({ length: ROUND_ESCALATE_THRESHOLD }, (_, i) =>
    finding("glm/", `${i}`.repeat(7) + "abc", "imp", "agreed", `codex-${i}`));
  const r = checkRoundGuard("spawn-glm", { task: "fix HIMMEL-1540", name: "   ", cwd: "." }, () => ledger);
  expect(r.refusal).toBeUndefined();
});
