// fleet-cloud.ts — cloud sessions as fleet nodes (HIMMEL-4791), for fleet.ts's readFleet.
//
// A cloud session (`claude --cloud`) has no local process, ~/.claude/sessions entry or journal, so the census never
// sees it. Its node comes from two reads: the console bucket's cloud-route.jsonl (cloud-route.mjs appends one
// {ticket, class, reason, brief, time} per routing; a ticket's newest CLOUD-OK inside CLOUD_RECENT_MS is a cloud
// session) and its PR on GitHub (the PR whose title cites the ticket, and the CLOUD-DONE / CLOUD-BLOCKED comment the
// cloud brief makes it post, whose first line carries the session URL). Its local shepherd leg (a leg on the same
// ticket) is its child. No source exposes a cloud session's token usage, so its usage is null: "not measured".
//
// GitHub shares one API quota with the whole fleet, so it is read in ONE batched GraphQL query per poll at most,
// cached for GH_TTL_MS per ticket set (a failure too); a failed, throttled or timed-out read is "unknown", never an
// error the view waits on. Read-only: nothing here writes.
//
// ponytail: a cloud session is "recent" for CLOUD_RECENT_MS after its routing (no source says when it ended); upgrade
// path: drop the window once the cloud-route log records the session URL and GitHub's merge state retires the node.
import { execFile } from "node:child_process";
import { readFile } from "node:fs/promises";
import { basename, dirname, join } from "node:path";

export const CLOUD_RECENT_MS = 72 * 60 * 60 * 1000;
export const GH_TTL_MS = 60_000;
const GH_TIMEOUT_MS = 10_000;
// cloud-route.mjs's REPO_SLUG: the repo its briefs open PRs in.
const REPO = "yotamleo/Himmel";
const TICKET = /^[A-Z][A-Z0-9]+-\d+$/;
const SESSION = /^[A-Za-z0-9._+-]{1,160}$/;
const URL_RE = /^https:\/\/claude\.ai\/code\/[A-Za-z0-9_-]{1,120}$/;

export type CloudPhase = "working" | "done" | "blocked" | "merged" | "closed" | "unknown";
export type CloudPr = { pr: number | null; phase: CloudPhase; url: string | null };
export type CloudRoute = { ticket: string; brief: string | null; at: number; bucket: string };

// Each ticket's newest routing decides: re-routed BLOCKED or LOCAL-NATIVE after a CLOUD-OK is no cloud session.
export function cloudRoutes(lines: string[], now: number, bucket = ""): CloudRoute[] {
  const newest = new Map<string, { cls: string; brief: string | null; at: number }>();
  for (const line of lines) {
    let r: any;
    try { r = JSON.parse(line); } catch { continue; }
    const at = Date.parse(r?.time);
    if (typeof r?.ticket !== "string" || !TICKET.test(r.ticket) || !Number.isFinite(at)) continue;
    const old = newest.get(r.ticket);
    if (!old || at >= old.at) newest.set(r.ticket, { cls: String(r.class), brief: typeof r.brief === "string" ? r.brief : null, at });
  }
  return [...newest].filter(([, v]) => v.cls === "CLOUD-OK" && now - v.at <= CLOUD_RECENT_MS)
    .map(([ticket, v]) => ({ ticket, brief: v.brief, at: v.at, bucket })).sort((a, b) => a.ticket.localeCompare(b.ticket));
}

// The console the brief names (`cloud-pilot: <KEY> (console <name>)`), read from the bucket the log sits in only.
export async function consoleOf(r: CloudRoute): Promise<string | null> {
  if (!r.brief || basename(r.brief) !== `cloud-brief-${r.ticket}.md`) return null;
  let text = "";
  try { text = await readFile(join(r.bucket, basename(r.brief)), "utf8"); } catch { return null; }
  const name = /cloud-pilot: \S+ \(console ([^)\s]+)\)/.exec(text)?.[1];
  return name && SESSION.test(name) ? name : null;
}

// One search per ticket, aliased t<i> in ticket order, all in one query. Tickets are TICKET-shaped (no quoting).
export const cloudQuery = (tickets: string[]) =>
  `query{${tickets.map((t, i) => `t${i}:search(query:"repo:${REPO} is:pr in:title ${t}",type:ISSUE,first:5){nodes{...on PullRequest{number state title comments(last:50){nodes{body}}}}}`).join(" ")}}`;

// The batched reply, per ticket; null when the reply is not a usable answer (an errors-only or malformed body).
export function cloudPrs(reply: any, tickets: string[]): Map<string, CloudPr> | null {
  const data = reply?.data;
  if (!data || typeof data !== "object") return null;
  const out = new Map<string, CloudPr>();
  tickets.forEach((t, i) => {
    const nodes: any[] = Array.isArray(data[`t${i}`]?.nodes) ? data[`t${i}`].nodes : [];
    const prs = nodes.filter((n) => Number.isSafeInteger(n?.number) && typeof n.title === "string" && n.title.includes(`[${t}]`))
      .map((n) => {
        const bodies: string[] = (Array.isArray(n.comments?.nodes) ? n.comments.nodes : []).map((c: any) => String(c?.body ?? ""));
        const report = bodies.filter((b) => /^CLOUD-(DONE|BLOCKED)\s/.test(b)).at(-1);
        const [kind, url] = report ? report.split("\n")[0].trim().split(/\s+/) : [];
        return { n, kind, url: url && URL_RE.test(url) ? url : null };
      });
    const pick = prs.find((p) => p.kind) ?? prs.sort((a, b) => b.n.number - a.n.number)[0];
    if (!pick) return out.set(t, { pr: null, phase: "working", url: null });
    const phase: CloudPhase = pick.n.state === "MERGED" ? "merged" : pick.n.state === "CLOSED" ? "closed"
      : pick.kind === "CLOUD-BLOCKED" ? "blocked" : pick.kind === "CLOUD-DONE" ? "done" : "working";
    out.set(t, { pr: pick.n.number, phase, url: pick.url });
  });
  return out;
}

let cache: { key: string; at: number; value: Promise<Map<string, CloudPr> | null> } | null = null;

// At most one GitHub call per ticket set per GH_TTL_MS; concurrent polls share the call in flight.
export function readCloudPrs(tickets: string[], o: { gh: string; env: Record<string, string | undefined>; now: number }): Promise<Map<string, CloudPr> | null> {
  const key = `${o.gh}\n${tickets.join(",")}`;
  if (cache && cache.key === key && o.now - cache.at < GH_TTL_MS) return cache.value;
  const value = new Promise<Map<string, CloudPr> | null>((ok) => {
    execFile(o.gh, ["api", "graphql", "-f", `query=${cloudQuery(tickets)}`], { env: o.env as NodeJS.ProcessEnv, timeout: GH_TIMEOUT_MS, maxBuffer: 4 * 1024 * 1024 }, (err, stdout) => {
      if (err) return ok(null);
      try { ok(cloudPrs(JSON.parse(stdout), tickets)); } catch { ok(null); }
    });
  });
  cache = { key, at: o.now, value };
  return value;
}
