// scripts/telegram/round-guard.ts — the symptom-brief loop breaker (HIMMEL-1553).
//
// Live incident (2026-08-04): HIMMEL-1540 burned FOUR CR review rounds across
// four overnight legs without landing. Every round's dispatch brief described
// the PREVIOUS round's defect; nobody ever wrote down the invariant all four
// defects shared (what identity a CR certificate is keyed to). The orchestrator
// holds the full history and kept handing the symptom forward; the worker lane
// inherits nothing and can only fix what the brief names. Nothing in the system
// noticed "this ticket is on round N" and forced a change of approach — so per
// CLAUDE.md's structural>instructional doctrine this guard makes the dispatch
// REFUSE, rather than adding more handover prose.
//
// Mechanism: the CR ledger (<git-common-dir>/cr-critic-scores.jsonl) already
// records review evidence per branch. The counter follows the ACTIVE branch's
// trailing sequence of heads with blocking critic findings; a clean response
// resets that sequence, and historical/parallel branches are separate change
// lifecycles. Two-stage escalation (see the threshold constants below for the
// operator decision + evidence): at ROUND_WARN_THRESHOLD consecutive blocking
// reviews the dispatch is refused unless the brief carries a substantive
// `INVARIANT:` section — the property every prior round's defect violated,
// which the whole fix must preserve; at
// ROUND_ESCALATE_THRESHOLD the CHEAP LANE ITSELF is refused — the permitted
// paths are a judgment-tier lane given the abstraction as the task, or an
// explicit recorded operator override (--rounds-override). The guard cannot
// check an invariant is TRUE; it forces the escalation step all four
// HIMMEL-1540 rounds skipped.
//
// FAIL-OPEN by design: no ticket key extractable, no ledger, unreadable ledger,
// malformed lines — all pass. This is a workflow guard against an expensive
// loop, not a security gate; blocking every dispatch on a fresh clone (no
// ledger) or a keyless exploratory brief would be a worse failure than the one
// it prevents. The refusal itself is self-serviceable (add the section and
// re-dispatch), so there is no bypass env var to leak into automation.
import { existsSync, readFileSync } from "node:fs";
import { join } from "node:path";

// Two-stage escalation (operator decision, 2026-08-05 — "we should've stopped
// earlier"). Stage 1 at 2 consecutive blocking reviews: per CLAUDE.md doctrine
// "first drift is signal; on the SECOND, escalate to structural", the second
// failed review IS the second drift — from here the brief must carry the
// invariant. Stage 2 at 3 consecutive blocking reviews: REFUSE the cheap-lane
// dispatch outright. Evidence from the incident itself: HIMMEL-1540's rounds
// 1-4 all had competent workers and
// increasingly detailed briefs, and every round fixed the symptom and exposed
// the next seam; what actually broke the loop was a JUDGMENT-TIER pass given
// the abstraction as the task, which root-caused it in one pass. An INVARIANT
// paragraph written by the same orchestrator that produced four symptom-briefs
// is likely another symptom in invariant clothing — at round 3 the thing that
// has to change is the MODEL, not the brief. (Confirmed live: the round-5
// prediction "never add a fourth resolution source" was violated by the very
// next adversarial pass finding a fifth and sixth identity.)
export const ROUND_WARN_THRESHOLD = 2;
export const ROUND_ESCALATE_THRESHOLD = 3;

// The operator-override reason (--rounds-override) must state WHY another
// cheap round is justified — a bare token would be the same laundering the
// guard exists to end. Forgeable in principle (any flag is), but deliberate,
// per-dispatch, and recorded in the transcript — same posture as the claudex
// bank preflight's --force.
export const ROUNDS_OVERRIDE_MIN_CHARS = 20;

// The invariant must be more than a token gesture: "INVARIANT: fix it" is the
// symptom loop wearing a costume. 40 chars of substance is a floor, not proof
// of quality — proof is not mechanically checkable, forcing articulation is.
export const INVARIANT_MIN_CHARS = 40;

// Extract the ticket key the dispatch targets. Priority: branch (shared mode
// names the real branch) > name (own-mode slug) > task text. Branch/name are
// machine-shaped (type/himmel-1540-slug), so a case-insensitive match is safe;
// free task text only matches an UPPERCASE key ("HIMMEL-1540") — lowercase
// prose like "bash-3.2-safe" must not read as a ticket. A wrong extraction
// fails OPEN (an unknown key has no ledger rounds), never closed.
// The trailing boundary is FULL non-alnum, not digits-only (codex-2, CR round
// 2): a `(?![0-9])` guard let "himmel-1540abc" read as HIMMEL-1540. A hyphen
// still bounds (branch slugs continue "-slug").
export function extractTicketKey(branch: string | undefined, name: string | undefined, task: string): string | undefined {
  for (const s of [branch, name]) {
    const m = s?.match(/(?:^|[^a-zA-Z0-9])([a-zA-Z][a-zA-Z0-9]*-[0-9]+)(?![a-zA-Z0-9])/);
    if (m) return m[1].toUpperCase();
  }
  const m = task.match(/(?:^|[^A-Za-z0-9])([A-Z][A-Z0-9]*-[0-9]+)(?![A-Za-z0-9])/);
  return m ? m[1].toUpperCase() : undefined;
}

// Count the trailing sequence of BLOCKING review cycles on the active branch.
// A clean review ends the sequence and starts a new change lifecycle; reviews
// on historical/parallel branches never enter it. This reset is not a cheap
// evasion: producing a clean critic response means the failed loop has ended,
// and subsequent edits are a new lifecycle. Missing signals (failed, timed-out,
// rate-limited attempts) neither count nor reset anything.
//
// The ledger stores the SAME commit in short and full form, so heads are grouped
// by their first 7 hex chars. Effective finding state includes append-only amend
// records, matching the clearance gate's verdict semantics. Malformed lines are
// skipped: this is a round COUNTER feeding a refusal-only workflow guard, not the
// clearance gate (clear-cr-marker.sh keeps the fail-closed ledger read).
export function countReviewedRounds(ledgerLines: string[], ticketKey: string, activeBranch: string): { rounds: number; heads: string[] } {
  type LedgerRecord = {
    kind?: string; branch?: unknown; head?: unknown; target_head?: unknown;
    status?: unknown; finding_id?: unknown; severity?: unknown; verdict?: unknown;
    artifact?: unknown; perspective?: unknown; deferred_to?: unknown; reason?: unknown;
    set?: unknown;
  };
  const records: LedgerRecord[] = [];
  for (const line of ledgerLines) {
    try { records.push(JSON.parse(line)); } catch { /* counter skips malformed rows */ }
  }

  const SEP = String.fromCharCode(31);
  const headGroup = (value: unknown): string | undefined => {
    const head = String(value ?? "").trim().toLowerCase();
    return /^[0-9a-f]{7,40}$/.test(head) ? head.slice(0, 7) : undefined;
  };
  // Heads compare by hex prefix in EITHER direction, not by head-group equality:
  // the same identity the clearance-side reader uses (cr-pending-audit.sh's
  // sameHead), because the ledger stores one commit in both short and full form.
  const sameHead = (x: unknown, y: unknown): boolean => {
    const a = String(x ?? "").trim().toLowerCase();
    const b = String(y ?? "").trim().toLowerCase();
    if (!/^[0-9a-f]{7,40}$/.test(a) || !/^[0-9a-f]{7,40}$/.test(b)) return false;
    return a.startsWith(b) || b.startsWith(a);
  };
  // Amend identity EXCLUDES the head, and amends apply SEQUENTIALLY in ledger
  // order against the finding's CURRENT head. That is what makes a CHAINED
  // amend work: the first amend's set.head re-keys the finding, and the next
  // amend targets the MOVED head. Pre-merging into a Map keyed by (head,
  // identity) instead put the second amend in a different bucket and dropped
  // it — one ledger semantics with two implementations, and this half had
  // drifted from cr-pending-audit.sh, which does it sequentially. Over-counting
  // is the SAFE direction for a refusal-only guard, so the drift never showed
  // as a wrong answer; it is still two readers disagreeing about one ledger.
  const identityKey = (o: LedgerRecord): string =>
    [String(o.finding_id ?? ""), String(o.artifact || "diff"), String(o.perspective || "off")].join(SEP);
  const amends: { target: unknown; key: string; set: Record<string, unknown> }[] = [];
  for (const record of records) {
    if (record.kind !== "amend" || !record.set || typeof record.set !== "object") continue;
    amends.push({ target: record.target_head, key: identityKey(record), set: record.set as Record<string, unknown> });
  }

  const esc = ticketKey.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const ticketBranch = new RegExp(`(?:^|[^a-zA-Z0-9])${esc}(?![a-zA-Z0-9])`, "i");
  const cycles = new Map<string, { head: string; order: number; responded: boolean; blocking: boolean }>();
  for (let order = 0; order < records.length; order++) {
    const raw = records[order];
    if (raw.kind !== "avail" && raw.kind !== "finding") continue;
    let record = raw;
    if (raw.kind === "finding") {
      // Identity is fixed from the ORIGINAL row; only the head moves as amends
      // apply. Same order of operations as cr-pending-audit.sh.
      const key = identityKey(raw);
      for (const amend of amends) {
        if (amend.key === key && sameHead(amend.target, record.head)) record = { ...record, ...amend.set };
      }
    }
    const branch = String(record.branch ?? "");
    if (branch !== activeBranch || !ticketBranch.test(branch)) continue;
    const head = headGroup(record.head);
    if (!head) continue;
    const cycle = cycles.get(head) ?? { head, order, responded: false, blocking: false };
    if (record.kind === "avail") {
      if (record.status === "ok") cycle.responded = true;
    } else {
      cycle.responded = true;
      const ticket = typeof record.deferred_to === "string" ? record.deferred_to.trim() : "";
      const why = typeof record.reason === "string" ? record.reason.trim() : "";
      const deferred = record.verdict === "deferred" && /^[A-Z][A-Z0-9]*-[0-9]+$/.test(ticket) && why;
      if ((record.severity === "crit" || record.severity === "imp") && record.verdict !== "disproved" && !deferred) {
        cycle.blocking = true;
      }
    }
    cycles.set(head, cycle);
  }

  const reviewed = [...cycles.values()].filter((cycle) => cycle.responded).sort((a, b) => a.order - b.order);
  let start = reviewed.length;
  while (start > 0 && reviewed[start - 1].blocking) start--;
  const failed = reviewed.slice(start);
  return { rounds: failed.length, heads: failed.map((cycle) => cycle.head) };
}

// A substantive INVARIANT section is explicitly delimited: `INVARIANT:` must
// be its own, unindented line, and the body ends at the next line-anchored
// ALL-CAPS section header. That makes ordinary FILES/STEPS content unavailable
// to an empty section, and a pasted refusal template is not mistaken for an
// authored invariant. Case-sensitive: the marker is a deliberate act.
export function hasSubstantiveInvariant(task: string): boolean {
  const lines = task.split(/\r?\n/);
  const start = lines.findIndex((line) => /^INVARIANT:[ \t]*$/.test(line));
  if (start < 0) return false;
  const body: string[] = [];
  for (const line of lines.slice(start + 1)) {
    // >= 3 chars of header name: `*` let a bare `A:` end the section, so an
    // authored invariant containing a labelled line ("A: the reviewed sha")
    // was TRUNCATED at it and could fall under the floor — a false refusal on
    // a brief that did the right thing. Real headers are `WHY:`/`FILES:`/
    // `STEPS:`/`RETASK:`; 3 is below the shortest of them and above prose.
    if (/^[A-Z][A-Z0-9 _/-]{2,}:[ \t]*(?:.*)?$/.test(line)) break;
    body.push(line);
  }
  const content = body.join(" ").replace(/\s+/g, " ").trim();
  if (/^<.*>$/.test(content)) return false; // refusal/help placeholder, not authored substance
  return content.length >= INVARIANT_MIN_CHARS;
}

// Read the CR ledger for the repo at cwd. FAIL-OPEN: not a repo / no ledger /
// unreadable -> [] (see the header). The ledger path is the same fixed
// <git-common-dir>/cr-critic-scores.jsonl clear-cr-marker.sh reads — no
// CR_LEDGER seam here either, but for the opposite reason: this guard only
// REFUSES, so a caller-pointed ledger could only make it stricter; the fixed
// path is simply the one that holds the real history.
export function readCrLedgerLines(cwd: string): string[] {
  try {
    const r = Bun.spawnSync(["git", "-C", cwd, "rev-parse", "--path-format=absolute", "--git-common-dir"], { stdout: "pipe", stderr: "pipe" });
    if (r.exitCode !== 0) return [];
    const ledger = join(r.stdout.toString().trim(), "cr-critic-scores.jsonl");
    if (!existsSync(ledger)) return [];
    return readFileSync(ledger, "utf8").split("\n").filter(Boolean);
  } catch {
    return [];
  }
}

// The dispatch-time check both worker lanes call BEFORE any side effect.
// Returns a refusal message (caller prints + exits 2), a pass-through note
// (caller prints — the transcript should show the guard evaluated a hot
// ticket), or nothing.
//
// Decision table (rounds = trailing blocking reviews on the active branch):
//   < 2                       silent pass
//   >= 2, valid override      pass, loud note recording the override reason
//   2, INVARIANT present      pass with note
//   2, no INVARIANT           refuse: add the section (self-serviceable)
//   >= 3, no override         refuse the CHEAP LANE itself: route to a
//                             judgment-tier lane, or operator override
export function checkRoundGuard(
  lane: string,
  args: { task: string; branch?: string; name?: string; cwd: string; roundsOverride?: string },
  readLedger: (cwd: string) => string[] = readCrLedgerLines,
): { refusal?: string; note?: string } {
  const ticket = extractTicketKey(args.branch, args.name, args.task);
  if (!ticket) return {};
  // Shared mode names the active branch directly. Own mode has a stable branch
  // only when the caller supplied --name; an anonymous timestamped dispatch is
  // a new lifecycle with no prior branch to count, so this refusal-only guard
  // fails open rather than borrowing unrelated ticket history.
  const prefix = lane === "spawn-glm" ? "glm" : lane === "spawn-claudex" ? "claudex" : undefined;
  // A whitespace-only --name is truthy but sanitises to "", which would derive
  // the malformed branch `glm/` and count rounds against a ref no dispatch can
  // ever have used. Treat blank exactly as absent (anonymous dispatch), which
  // is the fail-open path this refusal-only guard already intends.
  const nameSlug = (args.name ?? "").trim().replace(/[^a-zA-Z0-9-]/g, "-");
  const activeBranch = args.branch ?? (nameSlug && prefix ? `${prefix}/${nameSlug}` : undefined);
  if (!activeBranch) return {};
  const { rounds, heads } = countReviewedRounds(readLedger(args.cwd), ticket, activeBranch);
  if (rounds < ROUND_WARN_THRESHOLD) return {};
  const override = (args.roundsOverride ?? "").trim();
  if (override.length >= ROUNDS_OVERRIDE_MIN_CHARS) {
    return { note: `${lane}: round guard OVERRIDE (HIMMEL-1553): ${ticket} is on review round ${rounds + 1} (${rounds} consecutive blocking reviews) — cheap-lane dispatch proceeding on recorded operator authority: "${override}"` };
  }
  if (rounds >= ROUND_ESCALATE_THRESHOLD) {
    return {
      refusal: [
        `${lane}: REFUSED (round guard, HIMMEL-1553): ${ticket} already has ${rounds} consecutive blocking reviews on the active branch (heads: ${heads.join(", ")}) — buying another cheap-lane round is the failure mode itself, not a fix for it.`,
        `Evidence class (HIMMEL-1540): four rounds of competent workers with increasingly detailed briefs each fixed the symptom and exposed the next seam; what broke the loop was a JUDGMENT-TIER pass given the abstraction as the task. At this round the thing that must change is the model, not the brief.`,
        `Permitted paths:`,
        `  (a) ESCALATE: route this to a judgment-tier lane (see /lanes) with the abstraction as the task — "state the invariant all ${rounds} rounds' defects violated, then fix to it" — never the newest defect;`,
        `  (b) OPERATOR OVERRIDE: re-dispatch with --rounds-override "<why another cheap round is justified>" (>= ${ROUNDS_OVERRIDE_MIN_CHARS} chars${override ? `; the reason given was too short` : ""}). Appropriate for a purely mechanical batch of nit/sug fixes with no open crit/imp design question. The reason is recorded in the transcript.`,
      ].join("\n"),
    };
  }
  if (hasSubstantiveInvariant(args.task)) {
    return { note: `${lane}: round guard (HIMMEL-1553): ${ticket} is on review round ${rounds + 1} (${rounds} consecutive blocking reviews in the CR ledger) — INVARIANT section present, dispatching. At ${ROUND_ESCALATE_THRESHOLD} consecutive blocking reviews a cheap-lane dispatch will be refused outright.` };
  }
  return {
    refusal: [
      `${lane}: REFUSED (round guard, HIMMEL-1553): ${ticket} already has ${rounds} consecutive blocking reviews on the active branch (heads: ${heads.join(", ")}) and this brief names no invariant.`,
      `A second failed review is the second drift (CLAUDE.md: escalate to structural on the second): each round's brief so far describes the previous defect, the worker fixes exactly that, and the next seam surfaces. Do NOT re-describe the newest defect.`,
      `Re-dispatch with a line-delimited section in the brief:`,
      `INVARIANT:`,
      `  <the single property every prior round's defect violated — what the fix must preserve, stated so a reviewer can check the WHOLE change against it (>= ${INVARIANT_MIN_CHARS} chars)>`,
      `FILES:`,
      `  <the files in scope; this next ALL-CAPS section header ends the invariant body>`,
      `Derive it from ALL prior rounds' findings (grep the CR ledger $(git rev-parse --git-common-dir)/cr-critic-scores.jsonl for ${ticket}), not from the last round alone. If you cannot state the invariant, the ticket needs a design pass or an escalation lane, not another worker round — and at ${ROUND_ESCALATE_THRESHOLD} consecutive blocking reviews this guard refuses a cheap-lane dispatch outright.`,
    ].join("\n"),
  };
}
