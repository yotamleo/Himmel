// HIMMEL-4712: a fixture fleet — three live sessions (a console, a leg with a running subagent and one failure, an
// idle interactive session) and one wrapped leg — laid out exactly where the real fleet census reads it: a stub
// pgrep and a fake /proc (claude-sessions.sh's own CLAUDE_SESSIONS_PGREP / CLAUDE_SESSIONS_PROC seams), the
// harness's ~/.claude/sessions/<pid>.json, the session journals under ~/.claude/projects, and leg docs under
// HANDOVER_DIR. Shared by the route suite (agui-fleet.test.ts) and the page e2e (e2e/agui.e2e.ts).
import { appendFileSync, chmodSync, mkdirSync, writeFileSync } from "node:fs";
import { join } from "node:path";

// HIMMEL-4751: head = the doc's title tail and brief lines above Results (the graph link); autocompact = the
// --autocompact argv. The console succeeded a console that is no longer live; the leg's brief names the console.
type Member = { pid: number; name: string; run: string; model: string; status: "busy" | "idle"; doc?: string[]; head?: string[]; autocompact?: string };
export const PRIOR_CONSOLE = "HIMMEL-nextleg-2026-10-07ZY-roadmap-console";
export const FLEET = {
  console: { pid: 4101, name: "HIMMEL-nextleg-2026-10-07ZZ-roadmap-console", run: "1a000000-0000-4000-8000-000000000001", model: "claude-opus-5-5[1m]", status: "busy",
    autocompact: "auto", head: [`— CONSOLE — successor to ${PRIOR_CONSOLE}.md (fill signal 45 %)`], doc: [] },
  leg: { pid: 4102, name: "HIMMEL-901-N9001-fleet-leg-2026-10-07", run: "1a000000-0000-4000-8000-000000000002", model: "opus", status: "busy",
    autocompact: "200000", head: ["", "> **You are N9001.** Your console is **`HIMMEL-nextleg-2026-10-07ZZ-roadmap-console`**."],
    doc: ["- 09:00 LIVE — started", "- 09:40 LIVE — PR 1901 open, watching CI"] },
  idle: { pid: 4103, name: "scratch-session", run: "1a000000-0000-4000-8000-000000000003", model: "sonnet", status: "idle" },
  wrapped: { pid: 4104, name: "HIMMEL-903-N9003-done-leg-2026-10-07", run: "1a000000-0000-4000-8000-000000000004", model: "opus", status: "idle",
    doc: ["- 08:00 READY 1903 abc GREEN", "- 08:30 WRAPPED — merged"] },
} satisfies Record<string, Member>;

let seq = 0;
const rec = (m: Member, o: Record<string, unknown>) =>
  JSON.stringify({ isSidechain: false, sessionId: m.run, timestamp: new Date(Date.now() - 60_000 + seq * 10).toISOString(), uuid: `u-${++seq}`, ...o }) + "\n";
const prompt = (m: Member, text: string, side = {}) => rec(m, { type: "user", parentUuid: null, ...side, message: { role: "user", content: text } });
// HIMMEL-4751: every call carries the usage record a real transcript writes on it.
export const USAGE = { input_tokens: 10, output_tokens: 100, cache_read_input_tokens: 40000, cache_creation_input_tokens: 0 };
const call = (m: Member, id: string, name: string, input: Record<string, unknown>, side = {}) =>
  rec(m, { type: "assistant", ...side, message: { id: `m-${id}`, role: "assistant", stop_reason: "tool_use", model: "claude-opus-5-5", usage: USAGE, content: [{ type: "tool_use", id, name, input }] } });
const result = (m: Member, id: string, content: string, error = false, side = {}) =>
  rec(m, { type: "user", ...side, message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content, is_error: error }] } });
const end = (m: Member) => rec(m, { type: "system", subtype: "turn_duration", durationMs: 1000 });

const BRIEF = "Check the fleet census for a missing row.";
const SUB = { isSidechain: true, agentId: "a9001" };
function journal(m: Member): { main: string; sub?: string } {
  if (m === FLEET.console) return { main: prompt(m, "tick") + call(m, "toolu_c1", "Bash", { command: "bash tick.sh", description: "Tick the fleet" }) };
  if (m === FLEET.leg) return {
    main: prompt(m, "work the ticket")
      + call(m, "toolu_l1", "Bash", { command: "git push origin HEAD:main", description: "Push" })
      + result(m, "toolu_l1", "PreToolUse:Bash hook error: check-push-target: refusing a direct push to main", true)
      + call(m, "toolu_l2", "Agent", { description: "census critic", subagent_type: "general-purpose", prompt: BRIEF }),
    sub: prompt(m, BRIEF, SUB) + call(m, "toolu_s1", "Grep", { pattern: "claude_sessions", path: "scripts" }, SUB),
  };
  if (m === FLEET.idle) return { main: prompt(m, "hello") + rec(m, { type: "assistant", message: { id: "m-i", role: "assistant", stop_reason: "end_turn", content: [{ type: "text", text: "hi" }] } }) + end(m) };
  return { main: prompt(m, "wrap") + call(m, "toolu_w1", "Bash", { command: "bash wrap-subtree-check.sh", description: "Prove the subtree is clean" }) + result(m, "toolu_w1", "CLOSABLE: yes") + end(m) };
}

export type FleetFixture = {
  env: Record<string, string>; dir: string; home: string; pgrep: string;
  journal: (m: Member) => string; append: (m: Member, record: Record<string, unknown>) => void;
  gh: { calls: string; reply: string; rc: string };
};

// HIMMEL-4791: the cloud lane, opt-in ({ cloud: true }). The console's bucket carries cloud-route.jsonl (what
// cloud-route.mjs appends) and the briefs it wrote; GitHub is a stub gh (CONFIG_UI_GH) that logs each call's argv
// and answers the batched search with gh-reply.json. HIMMEL-905 reported CLOUD-DONE on open PR 1905 and has a live
// local shepherd leg; HIMMEL-906 has no PR yet; HIMMEL-907 merged. HIMMEL-908 was routed LOCAL-NATIVE, HIMMEL-909
// went CLOUD-OK too long ago, and HIMMEL-910's newest routing is BLOCKED: none of the three is a cloud session.
export const CLOUD = {
  shepherd: { pid: 4105, name: "HIMMEL-905-N9005-cloud-shepherd-2026-10-07", run: "1a000000-0000-4000-8000-000000000005", model: "sonnet", status: "busy",
    head: ["", "> **You are N9005.** Your console is **`HIMMEL-nextleg-2026-10-07ZZ-roadmap-console`**."], doc: ["- 10:00 LIVE — shepherding PR 1905"] } satisfies Member,
  url: "https://claude.ai/code/session_01AbCdEfGhIjKlMnOpQrStUv",
};
const HOUR = 60 * 60 * 1000;
const routed = (ticket: string, cls: string, ago: number, brief: string | null) =>
  JSON.stringify({ ticket, class: cls, reason: "x", brief, time: new Date(Date.now() - ago).toISOString() }) + "\n";
const prNode = (number: number, ticket: string, state: string, comments: string[]) =>
  ({ number, state, title: `feat: [${ticket}] cloud work`, comments: { nodes: comments.map((body) => ({ body })) } });
// One alias per routed ticket, in ticket order (905, 906, 907); a PR whose title cites another ticket is not its.
export const GH_REPLY = { data: {
  t0: { nodes: [prNode(1880, "HIMMEL-9050", "OPEN", [`CLOUD-DONE ${CLOUD.url}`]), prNode(1905, "HIMMEL-905", "OPEN", ["looks fine", `CLOUD-DONE ${CLOUD.url}\n\nHead SHA: abc`])] },
  t1: { nodes: [] },
  t2: { nodes: [prNode(1907, "HIMMEL-907", "MERGED", ["CLOUD-DONE https://claude.ai/code/session_07\nok"])] },
} };

export function fleetFixture(dir: string, opts: { cloud?: boolean } = {}): FleetFixture {
  const home = join(dir, "home"), proc = join(dir, "proc"), root = join(dir, "handover");
  const slug = join(home, ".claude", "projects", "fleet-project");
  const sessions = join(home, ".claude", "sessions");
  for (const d of [slug, sessions, proc, join(root, "yotam", "himmel")]) mkdirSync(d, { recursive: true });
  const members: Member[] = [...Object.values(FLEET), ...(opts.cloud ? [CLOUD.shepherd] : [])];
  const pgrep = join(dir, "pgrep");
  writeFileSync(pgrep, `#!/bin/sh\nprintf '%s\\n' ${members.map((m) => m.pid).join(" ")}\n`);
  chmodSync(pgrep, 0o755);
  const path = (m: Member) => join(slug, `${m.run}.jsonl`);
  for (const m of members) {
    mkdirSync(join(proc, String(m.pid)));
    writeFileSync(join(proc, String(m.pid), "cmdline"), ["claude", "-n", m.name, "--model", m.model, ...(m.autocompact ? ["--autocompact", m.autocompact] : []), ""].join("\0"));
    writeFileSync(join(sessions, `${m.pid}.json`), JSON.stringify({ pid: m.pid, sessionId: m.run, cwd: dir, name: m.name, status: m.status, kind: "interactive" }));
    const j = journal(m);
    writeFileSync(path(m), j.main);
    if (j.sub) {
      mkdirSync(join(slug, m.run, "subagents"), { recursive: true });
      writeFileSync(join(slug, m.run, "subagents", "agent-a9001.jsonl"), j.sub);
    }
    if (m.doc) writeFileSync(join(root, "yotam", "himmel", `${m.name}.md`), `# ${m.name} ${(m.head ?? []).join("\n")}\n\n## Results (newest at the bottom)\n\n${m.doc.join("\n")}\n`);
  }
  const gh = { calls: join(dir, "gh-calls"), reply: join(dir, "gh-reply.json"), rc: join(dir, "gh-rc") };
  writeFileSync(join(dir, "gh"), `#!/bin/sh\nprintf '%s\\n' "$*" >> '${gh.calls}'\ncat '${gh.reply}'\nexit "$(cat '${gh.rc}')"\n`);
  chmodSync(join(dir, "gh"), 0o755);
  writeFileSync(gh.reply, JSON.stringify(GH_REPLY));
  writeFileSync(gh.rc, "0");
  // HIMMEL-4925: the process-orphan inventory, silent by default so no suite reads the real process table.
  const orphans = join(dir, "orphan-loops.sh");
  writeFileSync(orphans, "#!/bin/sh\nexit 0\n");
  chmodSync(orphans, 0o755);
  if (opts.cloud) {
    const bucket = join(root, "yotam", "himmel");
    for (const t of ["HIMMEL-905", "HIMMEL-906", "HIMMEL-907"])
      writeFileSync(join(bucket, `cloud-brief-${t}.md`), `the line \`cloud-pilot: ${t} (console ${FLEET.console.name})\`, the line\n`);
    writeFileSync(join(bucket, "cloud-route.jsonl"), [
      routed("HIMMEL-909", "CLOUD-OK", 100 * HOUR, join(bucket, "cloud-brief-HIMMEL-909.md")),
      routed("HIMMEL-910", "CLOUD-OK", 2 * HOUR, null),
      routed("HIMMEL-905", "CLOUD-OK", HOUR, join(bucket, "cloud-brief-HIMMEL-905.md")),
      routed("HIMMEL-906", "CLOUD-OK", HOUR, join(bucket, "cloud-brief-HIMMEL-906.md")),
      routed("HIMMEL-907", "CLOUD-OK", HOUR, join(bucket, "cloud-brief-HIMMEL-907.md")),
      routed("HIMMEL-908", "LOCAL-NATIVE", HOUR, null),
      routed("HIMMEL-910", "BLOCKED", HOUR / 2, null),
      "{not json\n",
    ].join(""));
  }
  return {
    env: { HOME: home, HANDOVER_DIR: root, CLAUDE_SESSIONS_PGREP: pgrep, CLAUDE_SESSIONS_PROC: proc, CONFIG_UI_GH: join(dir, "gh"),
      CONFIG_UI_ORPHAN_LOOPS: orphans, CONFIG_UI_GITHUB_REPO: "acme/widgets" },
    dir, home, pgrep, journal: path, gh,
    append: (m, record) => appendFileSync(path(m), rec(m, record)),
  };
}
