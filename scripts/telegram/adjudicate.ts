// scripts/telegram/adjudicate.ts
// Parent-side lean-invoke CLI over the GLM offload sessions' append-only
// grants.jsonl / outbox.jsonl ledgers (escalation channel, HIMMEL-654 spec D9).
//   list                         — surface unresolved worker escalations
//   grant  <sessionDir> --arm <a> --pattern <re> [--ttl m] [--uses n] [--index i] [--autonomous]
//   refuse <sessionDir> <index>  — append a refusal that clears an escalation
// Single-writer: the parent/operator is the sole adjudicator per session;
// workers only ever APPEND escalation lines. The pure core
// (collectPendingEscalations / composeRefusalLine) is injectable + unit-tested;
// main() is the thin, fs-at-the-edges wrapper.
import { readdirSync, readFileSync, appendFileSync, existsSync } from "node:fs";
import { join } from "node:path";
import { glmSessionRoot } from "./spawn-glm";
import { composeGrantLine, nextGrantId, classifyShape, authorityGate, validateGrantSpec, composeEscalationForRefusedGrant } from "./grants";

export type PendingEscalation = { session: string; capability: string; arm: string; reason?: string; step?: string; ts?: string; index: number };

// An escalation at positional index i (within a session's outboxLines) is
// resolved iff a `refusal` line in that session's grantsLines carries
// index===i. v1 keeps ONLY this index spine — a grant does NOT auto-resolve an
// escalation (a grant merely re-enables the capability; the escalation stays
// listed until an explicit `refuse` clears it), so the correlation key is
// simple and test-pinned rather than a fuzzy arm+capability match.
export function collectPendingEscalations(
  sessions: { dir: string; outboxLines: string[]; grantsLines: string[] }[],
): PendingEscalation[] {
  const out: PendingEscalation[] = [];
  for (const s of sessions) {
    const refused = new Set<number>();
    for (const g of s.grantsLines) {
      let j: any;
      try { j = JSON.parse(g); } catch { continue; }
      if (j && j.type === "refusal" && typeof j.index === "number") refused.add(j.index);
    }
    for (let i = 0; i < s.outboxLines.length; i++) {
      let j: any;
      try { j = JSON.parse(s.outboxLines[i]); } catch { continue; }
      if (!j || j.type !== "escalation") continue;
      if (refused.has(i)) continue;
      out.push({ session: s.dir, capability: String(j.capability ?? ""), arm: String(j.arm ?? ""), reason: j.reason, step: j.step, ts: j.ts, index: i });
    }
  }
  return out;
}

// The `refusal` line that drops a resolved escalation from `list`. Written to
// grants.jsonl (the hook's grant-consult skips any non-"grant" line, so a
// refusal never affects the deny/allow decision).
export function composeRefusalLine(o: { grantId?: string; index?: number; now: Date }): string {
  const line: Record<string, unknown> = { type: "refusal", ts: o.now.toISOString() };
  if (o.index !== undefined) line.index = o.index;
  if (o.grantId !== undefined) line.grant_id = o.grantId;
  return JSON.stringify(line);
}

function readLines(p: string): string[] {
  if (!existsSync(p)) return [];
  return readFileSync(p, "utf8").split("\n").filter((l) => l.trim() !== "");
}

function readSessions(root: string): { dir: string; outboxLines: string[]; grantsLines: string[] }[] {
  if (!existsSync(root)) return [];
  return readdirSync(root, { withFileTypes: true })
    .filter((d) => d.isDirectory())
    .map((d) => {
      const dir = join(root, d.name);
      return { dir, outboxLines: readLines(join(dir, "outbox.jsonl")), grantsLines: readLines(join(dir, "grants.jsonl")) };
    });
}

function parseOpts(a: string[]): { arm?: string; pattern?: string; ttl?: number; uses?: number; index?: number; autonomous?: boolean } {
  const o: { arm?: string; pattern?: string; ttl?: number; uses?: number; index?: number; autonomous?: boolean } = {};
  for (let i = 0; i < a.length; i++) {
    if (a[i] === "--arm") o.arm = a[++i];
    else if (a[i] === "--pattern") o.pattern = a[++i];
    else if (a[i] === "--ttl") o.ttl = Number(a[++i]);
    else if (a[i] === "--uses") o.uses = Number(a[++i]);
    else if (a[i] === "--index") o.index = Number(a[++i]);
    else if (a[i] === "--autonomous") o.autonomous = true;
  }
  return o;
}

export async function main(argv: string[]): Promise<void> {
  const [cmd, ...rest] = argv;
  const root = glmSessionRoot();

  if (cmd === undefined || cmd === "list") {
    const pending = collectPendingEscalations(readSessions(root));
    if (pending.length === 0) { console.log("no pending escalations"); return; }
    for (const p of pending) console.log(`${p.session}\t#${p.index}\t${p.arm}\t${p.capability}${p.step ? `  (step ${p.step})` : ""}`);
    return;
  }

  if (cmd === "grant") {
    const sessionDir = rest[0];
    const opt = parseOpts(rest.slice(1));
    if (!sessionDir || !opt.arm || !opt.pattern) {
      throw new Error("usage: adjudicate grant <sessionDir> --arm <git-push|git-url|gh|network> --pattern <regex> [--ttl m] [--uses n] [--index i] [--autonomous]");
    }
    const v = validateGrantSpec({ arm: opt.arm, pattern: opt.pattern, ttlMins: opt.ttl ?? 60, maxUses: opt.uses ?? 1 });
    if (!v.ok) throw new Error(v.error);
    const shape = classifyShape(v.spec.arm, v.spec.pattern);
    const grantsPath = join(sessionDir, "grants.jsonl");
    if (authorityGate(shape, !!opt.autonomous).action === "grant") {
      const line = composeGrantLine(v.spec, { capability: opt.pattern, grantId: nextGrantId(readLines(grantsPath)), grantedBy: "operator:adjudicate", now: new Date() });
      appendFileSync(grantsPath, line + "\n");
      console.log(`granted ${v.spec.arm} (${shape}) -> ${grantsPath}`);
    } else {
      appendFileSync(join(sessionDir, "outbox.jsonl"), composeEscalationForRefusedGrant({ capability: opt.pattern, arm: v.spec.arm, reason: "autonomous refuses write grant — operator adjudication required", step: "adjudicate", now: new Date() }) + "\n");
      console.log("refused write-shaped grant under --autonomous; recorded a pending operator escalation");
    }
    return;
  }

  if (cmd === "refuse") {
    const sessionDir = rest[0];
    const idx = Number(rest[1]);
    if (!sessionDir || !Number.isInteger(idx)) throw new Error("usage: adjudicate refuse <sessionDir> <escalation-index>");
    appendFileSync(join(sessionDir, "grants.jsonl"), composeRefusalLine({ index: idx, now: new Date() }) + "\n");
    console.log(`refused escalation #${idx} in ${sessionDir}`);
    return;
  }

  throw new Error(`unknown command: ${cmd} (expected list|grant|refuse)`);
}

if (import.meta.main) {
  main(process.argv.slice(2)).catch((e) => { console.error(`adjudicate: ${String((e as any)?.message ?? e)}`); process.exit(1); });
}
