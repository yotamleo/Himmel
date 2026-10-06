// review-panel.ts — reads /pr-check review output out of tool-call text (HIMMEL-4480).
//
// Pure readers, all tolerant (no match gives null or [], never a throw):
//   parsePanelReport(text) — the critic panel's merged report, as printed by
//     scripts/cr/critic-panel.sh ("# Critic Panel Review (r/t critics responded)"
//     then "## Critical Issues (N found)" / "## Important Issues" / "## Suggestions"
//     sections of "- [<id>]: <text> [<file>:<line>]" bullets), plus the
//     "pr-check: round R of M on <branch>" line panel-first-pass prints before it.
//   extractVerdicts(text) — the write-verdicts grammar
//     ("VERDICT [<id>] = agreed|disproved|conflict|unaddressed" or
//     "VERDICT [<id>] = deferred -> <TICKET>").
//   extractLedgerVerdicts(command) — the CR ledger's "ledger-append.sh finding"
//     rows and "ledger-append.sh amend --set verdict=..." amends.
//   commandVerdicts(command, readFile) — what one shell command records: a
//     write-verdicts.sh run (its --from-file resolved by readFile) plus any
//     ledger rows. Text that only quotes a verdict line records nothing.
//
// The state shape is the contract agreed with the AG-UI page (leg N1346):
// { review: { pr?, head?, round?, maxRounds?, findings: [{ id, severity, title,
// file?, line?, verdict?, ticket? }] } }. An absent verdict means open.

export type Severity = "crit" | "major" | "imp" | "minor" | "sug";
export type Verdict = "agreed" | "disproved" | "conflict" | "unaddressed" | "deferred" | "fixed";

export type ReviewFinding = {
  id: string;
  severity: Severity;
  title: string;
  file?: string;
  line?: number;
  verdict?: Verdict;
  ticket?: string;
};

export type ReviewState = {
  pr?: number;
  head?: string;
  round?: number;
  maxRounds?: number;
  findings: ReviewFinding[];
};

export type VerdictUpdate = { id: string; verdict: Verdict; ticket?: string };

const PANEL_HEADER = /^# Critic Panel Review \(\d+\/\d+ critics responded\)\s*$/m;
const ROUND = /^pr-check: round (\d+) of (\d+) on \S+/m;
const SECTION = /^## (Critical Issues|Important Issues|Suggestions) \(\d+ found\)\s*$/;
const BULLET = /^- \[([^\]]+)\]:\s*(.*?)\s*$/;
const CITATION = /\s*\[([^\][]+):(\d+)\]$/;
const SEVERITY: Record<string, Severity> = { "Critical Issues": "crit", "Important Issues": "imp", Suggestions: "sug" };

export function parsePanelReport(text: string): ReviewState | null {
  if (!PANEL_HEADER.test(text)) return null;
  const state: ReviewState = { findings: [] };
  const round = ROUND.exec(text);
  if (round) {
    state.round = Number(round[1]);
    state.maxRounds = Number(round[2]);
  }
  let severity: Severity | undefined;
  for (const line of text.split("\n")) {
    const section = SECTION.exec(line);
    if (section) {
      severity = SEVERITY[section[1]];
      continue;
    }
    if (line.startsWith("## ") || line.startsWith("# ")) {
      severity = undefined; // Dropped Citations, re-raises and notes are not findings
      continue;
    }
    const bullet = severity && BULLET.exec(line);
    if (!bullet) continue;
    const finding: ReviewFinding = { id: bullet[1], severity: severity!, title: bullet[2] };
    const cite = CITATION.exec(finding.title);
    if (cite) {
      finding.title = finding.title.slice(0, cite.index);
      finding.file = cite[1];
      finding.line = Number(cite[2]);
    }
    state.findings.push(finding);
  }
  return state;
}

const VERDICT_LINE = /^\s*VERDICT \[([^\]]+)\] = (?:(agreed|disproved|conflict|unaddressed)|deferred -> ([A-Z][A-Z0-9]*-\d+))\s*$/;
const WRITE_VERDICTS = /write-verdicts\.sh\b/;
const LEDGER_CALL = /ledger-append\.sh['"]?\s+/;
const LEDGER_VERDICTS = new Set<Verdict>(["agreed", "disproved", "conflict", "unaddressed", "deferred", "fixed"]);
const FLAG_VALUE = `[ =]+(?:'([^']*)'|"([^"]*)"|(\\S+))`;

// The value after the first --flag, unquoted; undefined when the flag is absent.
function flag(text: string, name: string): string | undefined {
  const m = new RegExp(`--${name}${FLAG_VALUE}`).exec(text);
  return m ? (m[1] ?? m[2] ?? m[3]) : undefined;
}

// Every value of a repeatable --flag, unquoted, in order.
function flags(text: string, name: string): string[] {
  return [...text.matchAll(new RegExp(`--${name}${FLAG_VALUE}`, "g"))].map((m) => m[1] ?? m[2] ?? m[3]);
}

// The write-verdicts grammar, one verdict per line.
export function extractVerdicts(text: string): VerdictUpdate[] {
  const out: VerdictUpdate[] = [];
  for (const line of text.split("\n")) {
    const m = VERDICT_LINE.exec(line);
    if (m) out.push(m[3] ? { id: m[1], verdict: "deferred", ticket: m[3] } : { id: m[1], verdict: m[2] as Verdict });
  }
  return out;
}

// Verdicts a command records in the CR ledger, one per ledger-append.sh
// invocation: "finding ... --id <id> --verdict <v> [--deferred-to <T>]" or
// "amend ... --id <id> --set verdict=<v> [--set deferred_to=<T>]". Each
// invocation's flags are read only up to the next invocation.
export function extractLedgerVerdicts(command: string): VerdictUpdate[] {
  const out: VerdictUpdate[] = [];
  for (const call of command.split(LEDGER_CALL).slice(1)) {
    const verb = /^\S+/.exec(call)?.[0];
    let verdict: string | undefined;
    let ticket: string | undefined;
    if (verb === "finding") {
      verdict = flag(call, "verdict");
      ticket = flag(call, "deferred-to");
    } else if (verb === "amend") {
      const set = new Map(flags(call, "set").map((kv) => [kv.slice(0, kv.indexOf("=")), kv.slice(kv.indexOf("=") + 1)]));
      verdict = set.get("verdict");
      ticket = set.get("deferred_to");
    }
    const id = flag(call, "id");
    if (!id || !verdict || !LEDGER_VERDICTS.has(verdict as Verdict)) continue;
    out.push(ticket ? { id, verdict: verdict as Verdict, ticket } : { id, verdict: verdict as Verdict });
  }
  return out;
}

// Verdicts a shell command records: write-verdicts.sh reads VERDICT lines from
// its --from-file (looked up with readFile) or, without one, from the command
// text itself (a heredoc); ledger-append.sh rows count wherever they appear.
export function commandVerdicts(command: string, readFile: (path: string) => string | undefined): VerdictUpdate[] {
  const out: VerdictUpdate[] = [];
  if (WRITE_VERDICTS.test(command)) {
    const from = flag(command, "from-file");
    out.push(...extractVerdicts(from === undefined ? command : (readFile(from) ?? "")));
  }
  out.push(...extractLedgerVerdicts(command));
  return out;
}

// The --head sha a panel run was invoked with, if the call text names one.
export function extractHead(text: string): string | undefined {
  const head = flag(text, "head");
  return head && /^[0-9a-f]{7,40}$/.test(head) ? head : undefined;
}
