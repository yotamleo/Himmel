// roadmap.ts — the read-side behind GET /api/roadmap (HIMMEL-4943). The Jira mirror, the plan dir, the drift log and the
// legs are read LIVE on every request; nothing here writes or executes anything. Semantics are a port of
// scripts/handover/console-kit/tracker.py (read_mirror, read_versions, bucket, jira_view, drift_log), which stays the
// CLI/offline renderer and the drift log's only writer. legSync only PLANS Jira CLI argv: the console kit is the one writer.
import { closeSync, fstatSync, openSync, readdirSync, readFileSync, readSync } from "node:fs";
import { basename, join } from "node:path";
import type { Section } from "./health-sources";

export const SYNC_LABEL = "leg-blocked";
const TRAIN_RE = /^v1\.\d+\.\d+[a-z]?$/;
const TAIL_BYTES = 64 * 1024;
const TREND_ROWS = 30;
const NO_THEME = "(no theme)";
const STUCK = new Set(["BLOCKED", "FINDING", "HALTED", "PARKED-BANK"]);
const CLEARING = new Set(["LIVE", "RESUMED", "RESOLVED", "READY", "WRAPPED"]);
const NOTED = new Set(["READY", "WRAPPED"]);
// tracker.py BUCKETS: the status NAME decides, the category only a name not listed.
const BUCKETS: Record<string, string> = { "to do": "todo", backlog: "todo", "in progress": "prog", "in review": "rev", ci: "ci", "in ci": "ci",
  done: "done", closed: "done", "in public": "done", "wont do": "wont", "wont fix": "wont" };

export type Bucket = "todo" | "prog" | "rev" | "ci" | "done" | "wont";
export type Leg = { label: string; marker: string; reason: string };
export type Ticket = {
  k: number; t: string; s: string; b: Bucket; v: number; theme: number; pv: string | null; drift: 0 | 1 | 2;
  labels: string[]; leg: Leg | null; noted?: string; // noted: the mirror body, for the sync dedupe; non-enumerable, never shipped
};
export type Version = { n: string; rel: boolean; date: string; counts: Record<Bucket, number>; open: number[] };
export type Proposal = { k: number; title: string; proposal: string; needsApproval: true };
export type DupProposal = { keys: number[]; title: string; proposal: string; needsApproval: true };
export type SyncOp = { k: number; marker: string; argv: string[]; why: string };
export type Roadmap = {
  state: "ok" | "absent"; reason?: string;
  mirror: { dir: string; count: number; newest: string };
  releaseUnknown: boolean; versions: Version[]; tickets: Ticket[]; themes: string[];
  plan: { state: "ok" | "absent"; reason?: string; dir?: string };
  cur: number; next: number;
  drift: { now: { drift: number; unplanned: number; unthemed: number }; trend: [string, number, number, number][] };
  librarian: { staleInProgress: Proposal[]; drift: Proposal[]; unthemed: Proposal[]; releasedOpen: Proposal[]; duplicates: DupProposal[] };
};
type Opts = { mirrorDir: string; versionsFile?: string; planDir?: string; driftLog?: string; legs: Section };
type M = { k: number; sn: string; cat: string; fv: string[]; labels: string[]; upd: string; title: string; body: string };

const text = (f: string) => { try { return readFileSync(f, "utf8"); } catch { return ""; } };
const json = <T>(s: string | undefined, d: T): T => { try { return s === undefined ? d : JSON.parse(s); } catch { return d; } };
const unq = (s: string | undefined) => (s ?? "").trim().replace(/^"|"$/g, "");
const clip = (s: string, n: number) => { s = s.split(/\s+/).filter(Boolean).join(" "); return s.length <= n ? s : s.slice(0, n - 1) + "…"; };
const rows = (f: string) => text(f).split(/\r?\n/).filter(Boolean).map((l) => l.split("\t"));
const keyNum = (k: string | undefined) => { const m = /^HIMMEL-(\d+)$/.exec((k ?? "").trim()); return m ? Number(m[1]) : null; };

// tracker.py ver_key: v1.0.n[a-z] by n, v1.1.N after v1.0.2, later milestone minors numerically, anything else last.
function verKey(v: string): [number, number, string] {
  let m = /^v1\.0\.(\d+)([a-z]?)$/.exec(v);
  if (m) return [0, Number(m[1]), m[2]];
  m = /^v1\.1\.(\d+)$/.exec(v);
  if (m) return [0, 2, String.fromCharCode(98 + Number(m[1]))];
  m = /^v1\.([2-9]|\d{2,})\.(\d+)([a-z]?)$/.exec(v);
  return m ? [0, 1000 + Number(m[1]), String(m[2]).padStart(12, "0") + m[3]] : [1, 0, ""];
}
const verCmp = (a: string, b: string) => { const x = verKey(a), y = verKey(b); return x[0] - y[0] || x[1] - y[1] || (x[2] < y[2] ? -1 : x[2] > y[2] ? 1 : 0); };

function readMirror(dir: string): M[] {
  let names: string[];
  try { names = readdirSync(dir).filter((f) => /^HIMMEL-\d+\.md$/.test(f)); } catch { return []; }
  const out: M[] = [];
  for (const f of names) {
    const parts = text(join(dir, f)).split("---");
    if (parts.length < 3) continue;
    const fm: Record<string, string> = {};
    for (const l of parts[1].split("\n")) { const i = l.indexOf(":"); if (i > 0 && !l.startsWith(" ")) fm[l.slice(0, i).trim()] = l.slice(i + 1).trim(); }
    const k = keyNum(unq(fm.key));
    if (k === null) continue;
    const body = parts.slice(2).join("---");
    const sn = json<unknown>(fm.status, "");
    out.push({ k, sn: typeof sn === "string" ? sn : "", cat: unq(fm.statusCategory), fv: json<string[]>(fm.fixVersions, []).map(String), labels: json<string[]>(fm.labels, []).map(String),
      upd: unq(fm.updated), title: /^# [A-Z]+-\d+:\s*(.*)$/m.exec(body)?.[1] ?? "", body });
  }
  return out;
}

const bucketOf = (m: M): Bucket => (BUCKETS[m.sn.trim().toLowerCase()] ?? ({ Done: "done", "In Progress": "prog" } as Record<string, string>)[m.cat] ?? "todo") as Bucket;
const isOpen = (b: Bucket) => b !== "done" && b !== "wont";

function readVersions(file: string, mir: M[]): { list: { n: string; rel: boolean; date: string }[]; unknown: boolean } {
  const ok = (f: string[]) => f.length >= 2 && TRAIN_RE.test(f[0]) && f[0] !== "v1.0.0";
  const lines = rows(file).filter(ok);
  if (!lines.length) {
    const names = [...new Set(mir.flatMap((m) => m.fv).filter((v) => TRAIN_RE.test(v) && v !== "v1.0.0"))].sort(verCmp);
    return { list: names.map((n) => ({ n, rel: false, date: "" })), unknown: true };
  }
  return { list: lines.map((f) => ({ n: f[0], rel: f[1] === "true", date: f[2] ?? "" })), unknown: false };
}

// Plan tables are TSVs with a header row; a column is found by its name.
function table(f: string): Record<string, string>[] {
  const [head, ...body] = rows(f);
  return head ? body.map((r) => Object.fromEntries(head.map((h, i) => [h, r[i] ?? ""]))) : [];
}

function readTheme(planDir: string): Map<number, string> {
  const out = new Map<number, string>();
  const stage1 = join(planDir, "stage1");
  let files: string[] = [];
  try { files = readdirSync(stage1).filter((f) => /^C\d\d\.tsv$/.test(f)).sort(); } catch { /* no stage1 */ }
  for (const f of files) for (const r of table(join(stage1, f))) { const k = keyNum(r.key); if (k !== null && r.theme) out.set(k, r.theme); }
  for (const r of table(join(stage1, "themes-overlay.tsv"))) { const k = keyNum(r.key); if (k !== null && r.theme && !out.has(k)) out.set(k, r.theme); } // overlay fills only the missing
  return out;
}

// The last 64 KiB of a file; "" when unreadable.
function tail(f: string): string {
  try {
    const fd = openSync(f, "r");
    try {
      const size = fstatSync(fd).size, start = Math.max(0, size - TAIL_BYTES), buf = Buffer.alloc(size - start);
      readSync(fd, buf, 0, buf.length, start);
      return buf.toString("utf8");
    } finally { closeSync(fd); }
  } catch { return ""; }
}

// The text after the marker on the doc's newest `- ` bullet that starts with it ("- 04:32 BLOCKED — why").
function legReason(doc: string, marker: string): string {
  const re = new RegExp(`^-\\s+(?:\\d{1,2}:\\d{2}\\s+)?(?:\\*\\*)?${marker.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")}(?:\\*\\*)?[\\s:—–-]*(.*)$`);
  const lines = tail(doc).split(/\r?\n/);
  for (let i = lines.length - 1; i >= 0; i--) { const m = re.exec(lines[i]); if (m) return m[1].replace(/\*\*$/, "").trim(); }
  return "";
}

function readTrend(f: string): [string, number, number, number][] {
  return rows(f).slice(1).filter((r) => r.length === 4 && r.slice(1).every((x) => /^\d+$/.test(x)))
    .map((r) => [r[0], Number(r[1]), Number(r[2]), Number(r[3])] as [string, number, number, number]).slice(-TREND_ROWS);
}

const normTitle = (s: string) => s.toLowerCase().replace(/[^a-z0-9]+/g, " ").trim();

export function readRoadmap(o: Opts): Roadmap {
  const mir = readMirror(o.mirrorDir);
  const empty: Roadmap = { state: "absent", mirror: { dir: o.mirrorDir, count: 0, newest: "" }, releaseUnknown: false, versions: [], tickets: [], themes: [NO_THEME],
    plan: { state: "absent" }, cur: -1, next: -1, drift: { now: { drift: 0, unplanned: 0, unthemed: 0 }, trend: [] },
    librarian: { staleInProgress: [], drift: [], unthemed: [], releasedOpen: [], duplicates: [] } };
  if (!mir.length) return { ...empty, reason: `no Jira mirror at ${o.mirrorDir}; build one with: node scripts/jira/dist/index.js mirror` };

  const { list, unknown } = readVersions(o.versionsFile ?? o.mirrorDir + ".versions.tsv", mir);
  const vi = new Map(list.map((v, i) => [v.n, i]));

  // Plan: placement.tsv (version per ticket) and the themes; absent plan = every drift 0.
  let place: Map<number, string> | null = null, planReason = "no plan dir";
  if (o.planDir) {
    const p = table(join(o.planDir, "stage3", "placement.tsv"));
    if (p.length) place = new Map(p.flatMap((r) => { const k = keyNum(r.key); return k === null ? [] : [[k, r.version] as [number, string]]; }));
    else planReason = `no stage3/placement.tsv in ${o.planDir}`;
  }
  const themeOf = o.planDir ? readTheme(o.planDir) : new Map<number, string>();
  const themes = [...new Set([NO_THEME, ...themeOf.values()])].sort();

  // Legs: ticket number -> the last leg listed for it.
  const legs = new Map<number, Leg>();
  if (o.legs.state === "ok" && Array.isArray(o.legs.legs)) {
    for (const l of o.legs.legs as { doc: string; status: string }[]) {
      const m = /^HIMMEL-(\d+)-(N\d+[a-z]?)-.*\.md$/.exec(basename(String(l.doc)));
      if (m) legs.set(Number(m[1]), { label: m[2], marker: String(l.status), reason: legReason(String(l.doc), String(l.status)) });
    }
  }

  const tickets: Ticket[] = [];
  for (const m of mir) {
    const hit = m.fv.filter((v) => vi.has(v));
    if (!hit.length) continue;
    const un = hit.filter((v) => !list[vi.get(v)!].rel);
    const v = un.length ? un.reduce((a, b) => (vi.get(b)! < vi.get(a)! ? b : a)) : hit.reduce((a, b) => (vi.get(b)! > vi.get(a)! ? b : a));
    const b = bucketOf(m), pv = place?.get(m.k) ?? null;
    const drift = !place ? 0 : pv !== null ? (pv !== v ? 1 : 0) : isOpen(b) ? 2 : 0;
    const t: Ticket = { k: m.k, t: clip(m.title, 90), s: m.sn || m.cat, b, v: vi.get(v)!, theme: themes.indexOf(themeOf.get(m.k) ?? NO_THEME), pv, drift: drift as 0 | 1 | 2,
      labels: m.labels, leg: isOpen(b) ? legs.get(m.k) ?? null : null };
    Object.defineProperty(t, "noted", { value: m.body, enumerable: false });
    tickets.push(t);
  }
  tickets.sort((a, b) => a.k - b.k);

  const versions: Version[] = list.map((v, i) => {
    const counts = { todo: 0, prog: 0, rev: 0, ci: 0, done: 0, wont: 0 };
    const mine = tickets.filter((t) => t.v === i);
    for (const t of mine) counts[t.b]++;
    return { ...v, counts, open: v.rel ? mine.filter((t) => isOpen(t.b)).map((t) => t.k) : [] };
  });
  const cur = versions.findIndex((v, i) => !v.rel && tickets.some((t) => t.v === i && isOpen(t.b)));
  const next = versions.findIndex((v, i) => i > cur && !v.rel && tickets.some((t) => t.v === i));

  const open = tickets.filter((t) => isOpen(t.b));
  const unthemed = open.filter((t) => themes[t.theme] === NO_THEME);
  const now = { drift: tickets.filter((t) => t.drift === 1).length, unplanned: open.filter((t) => t.drift === 2).length, unthemed: unthemed.length };

  const prop = (t: Ticket, proposal: string): Proposal => ({ k: t.k, title: t.t, proposal, needsApproval: true });
  const run = versions[cur]?.n;
  // ponytail: duplicates are an exact match on the normalized title only, upgrade path: token-similarity when the librarian lane runs.
  const byTitle = new Map<string, Ticket[]>();
  for (const t of open) { const n = normTitle(t.t); if (n) byTitle.set(n, [...(byTitle.get(n) ?? []), t]); }
  const librarian = {
    staleInProgress: tickets.filter((t) => ["prog", "rev", "ci"].includes(t.b) && (!t.leg || t.leg.marker === "WRAPPED" || t.leg.marker === "HALTED"))
      .map((t) => prop(t, t.leg ? `${t.s} but its leg is ${t.leg.marker}: confirm the state, then move it back to To Do or close it` : `${t.s} with no leg: confirm someone is on it, else move it back to To Do`)),
    drift: tickets.filter((t) => t.drift === 1).map((t) => prop(t, `Jira says ${versions[t.v].n}, the plan says ${t.pv}: move fixVersion to ${t.pv} or re-plan`)),
    unthemed: unthemed.map((t) => prop(t, "assign a theme in the plan (stage1 overlay)")),
    releasedOpen: open.filter((t) => versions[t.v].rel).map((t) => prop(t, `${versions[t.v].n} is released but this is still open: move to ${run ?? "the running version"}`)),
    duplicates: [...byTitle.values()].filter((g) => g.length > 1).map((g) => ({ keys: g.map((t) => t.k).sort((a, b) => a - b), title: g[0].t,
      proposal: "same title: close all but one, linking the rest to it", needsApproval: true as const })).sort((a, b) => a.keys[0] - b.keys[0]),
  };

  return {
    state: "ok", mirror: { dir: o.mirrorDir, count: mir.length, newest: mir.reduce((a, m) => (m.upd > a ? m.upd : a), "") },
    releaseUnknown: unknown, versions, tickets, themes,
    plan: place ? { state: "ok", dir: o.planDir } : { state: "absent", reason: planReason },
    cur, next, drift: { now, trend: o.driftLog ? readTrend(o.driftLog) : [] }, librarian,
  };
}

// The Jira CLI argv that mirrors each leg's marker onto its ticket. Planned only: the console kit is the one writer,
// legs never write Jira, and this page never does. `--labels` is a full replace in the jira CLI; a status is never moved.
export function legSync(tickets: Ticket[]): SyncOp[] {
  const ops: SyncOp[] = [];
  for (const t of tickets) {
    if (!t.leg) continue;
    const { label, marker, reason } = t.leg, key = `HIMMEL-${t.k}`;
    const line = `[leg-sync] ${label} ${marker}${reason ? `: ${reason}` : ""}`;
    const noted = (t.noted ?? "").includes(line);
    const has = t.labels.includes(SYNC_LABEL);
    if (STUCK.has(marker)) {
      if (!has) ops.push({ k: t.k, marker, argv: ["edit", key, "--add-labels", SYNC_LABEL], why: `leg ${label} is ${marker}: flag the ticket` });
      if (!noted) ops.push({ k: t.k, marker, argv: ["comment", key, line], why: `record why leg ${label} is ${marker}` });
    } else if (CLEARING.has(marker)) {
      if (has) ops.push({ k: t.k, marker, argv: ["edit", key, "--labels", t.labels.filter((l) => l !== SYNC_LABEL).join(",")], why: `leg ${label} is ${marker}: clear the flag` });
      if (NOTED.has(marker) && !noted) ops.push({ k: t.k, marker, argv: ["comment", key, line], why: `note once that leg ${label} is ${marker}` });
    }
  }
  return ops;
}
