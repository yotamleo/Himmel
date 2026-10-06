// HIMMEL-4480: harness for the AG-UI page e2e and the README GIF recorder.
// Boots the REAL `himmelctl ui --port 0 --agui <run>` (the same spawn as fixtures.ts, so the
// HIMMEL-4350 in-session refusal stays untouched) with a temp HOME whose ~/.claude/projects holds a
// session journal the test APPENDS to while the page is open: a live stream over the real SSE path.
import { spawn, type ChildProcess } from "node:child_process";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { BIN } from "./fixtures";

export const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";
const DIST = join(__dirname, "../../agui-web/dist/index.html");
export const aguiBuilt = () => existsSync(DIST);

const SESSION = "e2e-session";
let seq = 0;
const ts = () => new Date().toISOString();
const line = (o: object) => JSON.stringify({ isSidechain: false, sessionId: SESSION, timestamp: ts(), uuid: `u-${++seq}`, ...o }) + "\n";
// HIMMEL-4669: `sub` writes the record as a subagent's (isSidechain + agentId, as in subagents/agent-<id>.jsonl);
// `model` names the assistant's model; `error` marks a failed tool result; `use` is its toolUseResult.
type Opt = { sub?: string; model?: string; error?: boolean; use?: Record<string, unknown> };
const side = (o?: Opt) => (o?.sub ? { isSidechain: true, agentId: o.sub } : {});
const assistant = (stop: string, block: object, o?: Opt) =>
  line({ type: "assistant", requestId: `req_${seq}`, ...side(o),
    message: { id: `msg_${seq}`, type: "message", role: "assistant", stop_reason: stop, ...(o?.model ? { model: o.model } : {}), content: [block] } });

// Journal records, in the shape tests/fixtures/agui/happy-path.jsonl pins.
export const J = {
  prompt: (text: string, o?: Opt) => line({ parentUuid: null, promptId: "p-1", type: "user", ...side(o), message: { role: "user", content: text } }),
  text: (text: string, stop = "end_turn", o?: Opt) => assistant(stop, { type: "text", text }, o),
  tool: (id: string, name: string, input: Record<string, unknown>, o?: Opt) => assistant("tool_use", { type: "tool_use", id, name, input }, o),
  result: (id: string, content: string, o?: Opt) =>
    line({ type: "user", promptId: "p-1", ...side(o), ...(o?.use ? { toolUseResult: o.use } : {}),
      message: { role: "user", content: [{ type: "tool_result", tool_use_id: id, content, is_error: o?.error === true }] } }),
  end: () => line({ type: "system", subtype: "turn_duration", durationMs: 4000, messageCount: 6 }),
  name: (agentName: string) => JSON.stringify({ type: "agent-name", agentName, sessionId: SESSION }) + "\n",
};

export type AguiHarness = {
  url: string; // http://127.0.0.1:<port>/agui/#t=<64 hex>&run=<RUN>
  append: (record: string) => void;
  appendSub: (agentId: string, record: string) => void; // to <session>/subagents/agent-<id>.jsonl
  stop: () => Promise<void>;
};

export async function bootAgui(initial = ""): Promise<AguiHarness> {
  const dir = mkdtempSync(join(tmpdir(), "agui-e2e-"));
  const home = join(dir, "home");
  const slug = join(home, ".claude", "projects", "e2e-project");
  mkdirSync(slug, { recursive: true });
  const journal = join(slug, `${RUN}.jsonl`);
  writeFileSync(journal, initial);
  const env: Record<string, string | undefined> = {
    ...process.env, HOME: home, CONFIG_UI_HIMMELCTL: join(__dirname, "e2e-stub.js"), CONFIG_UI_IDLE_MS: "300000",
    HANDOVER_DIR: join(dir, "handover"), HIMMEL_PROMETHEUS_URL: "http://127.0.0.1:1", HIMMEL_FLOW_EXPORTER_PORT: "1",
    E2E_FEED: join(dir, "feed.json"), STUB_ARGV: join(dir, "argv"),
  };
  delete env.CADENCE_BANK_LEDGER;
  for (const k of Object.keys(env)) if (k === "CLAUDECODE" || k.startsWith("CLAUDE_CODE_")) delete env[k];
  const child: ChildProcess = spawn("node", [BIN, "ui", "--port", "0", "--agui", RUN], { env: env as NodeJS.ProcessEnv, stdio: ["ignore", "pipe", "pipe"] });
  let timer: ReturnType<typeof setTimeout> | undefined;
  const url = await new Promise<string>((ok, fail) => {
    let buf = "", err = "";
    child.stderr!.on("data", (d) => (err += d));
    child.stdout!.on("data", (d) => {
      buf += d;
      const m = /(http:\/\/127\.0\.0\.1:\d+\/agui\/#t=[0-9a-f]{64}&run=[0-9a-f-]{36})/.exec(buf);
      if (m) ok(m[1]);
    });
    child.on("error", fail);
    child.on("exit", (c) => fail(new Error(`himmelctl ui exited ${c}: ${err}`)));
    timer = setTimeout(() => fail(new Error("himmelctl ui --agui printed no URL in 15 s")), 15_000);
  }).catch((e) => {
    child.kill("SIGKILL");
    rmSync(dir, { recursive: true, force: true });
    throw e;
  }).finally(() => clearTimeout(timer));
  return {
    url,
    append: (r) => appendFileSync(journal, r),
    appendSub: (id, r) => {
      const subs = join(slug, RUN, "subagents");
      mkdirSync(subs, { recursive: true });
      appendFileSync(join(subs, `agent-${id}.jsonl`), r);
    },
    stop: async () => {
      child.kill("SIGTERM");
      await new Promise((r) => {
        if (child.exitCode !== null || child.signalCode !== null) return r(null);
        child.once("exit", r);
        setTimeout(() => { child.kill("SIGKILL"); r(null); }, 5_000).unref();
      });
      rmSync(dir, { recursive: true, force: true });
    },
  };
}

// HIMMEL-4669: a leg's /pr-check round: the critic panel reports three findings (the Review panel fills), a
// correctness critic subagent checks the critical one while the suite runs, verdicts are recorded, and four
// kinds of failure land (a red suite, a guardrail denial, a BLOCKED report by message and by text). Records
// are built when played, so each carries the time it was appended; `pause` is the recorder's wait after a step
// (the e2e plays it without waiting).
const CRITIC = "a7c1e0";
const HEAD = "6c2bb12a9d4e0f1b2c3d4e5f6a7b8c9d0e1f2a3b";
const BRIEF = "Check finding r1-1 in scripts/check-ci.sh at 6c2bb12: is the cap counter off by one? Cite file:line.";
const PANEL = [
  "pr-check: round 1 of 3 on fix/check-ci-cap",
  "# Critic Panel Review (3/3 critics responded)",
  "## Critical Issues (1 found)",
  "- [r1-1]: The cap counter is off by one when two polls land in the same second [scripts/check-ci.sh:88]",
  "",
  "## Important Issues (1 found)",
  "- [r1-2]: Unquoted $max_wait splits on spaces [scripts/check-ci.sh:12]",
  "",
  "## Suggestions (1 found)",
  "- [r1-3]: The test header names the wrong ticket [tests/test-check-ci.sh:3]",
].join("\n");
const VERDICTS = "VERDICT [r1-1] = agreed\nVERDICT [r1-2] = deferred -> HIMMEL-4650\nVERDICT [r1-3] = disproved\n";
const SONNET = { sub: CRITIC, model: "claude-sonnet-5-5" };
const OPUS = { model: "claude-opus-5-5" };
export const SCENE: { sub?: string; rec: () => string; pause: number }[] = [
  { rec: () => J.name("HIMMEL-1957-N1290-check-ci-cap"), pause: 0 },
  { rec: () => J.prompt("Run /pr-check on PR 1957, then the check-ci suite."), pause: 900 },
  { rec: () => J.text("Running the critic panel on the head first.", "tool_use", OPUS), pause: 700 },
  { rec: () => J.tool("toolu_panel", "Bash", { command: `bash scripts/cr/panel-first-pass.sh --head ${HEAD} --branch 'fix/check-ci-cap'`, description: "Run the critic panel" }, OPUS), pause: 1400 },
  { rec: () => J.result("toolu_panel", PANEL), pause: 1200 },
  { rec: () => J.text("Three findings. A critic checks the critical one while the suite runs.", "tool_use", OPUS), pause: 600 },
  { rec: () => J.tool("toolu_crit", "Agent", { description: "correctness critic", subagent_type: "pr-review-toolkit-himmel:code-reviewer", model: "sonnet", prompt: BRIEF }, OPUS), pause: 150 },
  { rec: () => J.tool("toolu_suite", "Bash", { command: "bash scripts/quiet-run.sh suite -- bash tests/test-check-ci.sh", description: "Run the check-ci suite" }, OPUS), pause: 500 },
  { sub: CRITIC, rec: () => J.prompt(BRIEF, { sub: CRITIC }), pause: 500 },
  { sub: CRITIC, rec: () => J.tool("toolu_read", "Read", { file_path: "scripts/check-ci.sh" }, SONNET), pause: 500 },
  { sub: CRITIC, rec: () => J.result("toolu_read", Array.from({ length: 40 }, (_, i) => `${i + 1}\t# check-ci.sh line ${i + 1}`).join("\n"), { sub: CRITIC }), pause: 400 },
  { sub: CRITIC, rec: () => J.tool("toolu_grep", "Grep", { pattern: "polls >=", path: "scripts/check-ci.sh" }, SONNET), pause: 600 },
  { sub: CRITIC, rec: () => J.result("toolu_grep", "scripts/check-ci.sh:88: (( polls >= max_wait ))", { sub: CRITIC }), pause: 600 },
  { rec: () => J.result("toolu_suite", "Exit code 1\nERR quiet-run suite exit=1 (5s, log: /tmp/quiet-run-suite-41.log)\nnot ok 7 - the cap is reached twice in one second", { error: true }), pause: 700 },
  { sub: CRITIC, rec: () => J.text("Confirmed: r1-1 is real. Two polls in one second both pass the >= check (check-ci.sh:88).", "end_turn", SONNET), pause: 700 },
  { rec: () => J.result("toolu_crit", "Confirmed: r1-1 is real (check-ci.sh:88).", { use: { status: "completed", agentId: CRITIC, resolvedModel: "claude-sonnet-5-5" } }), pause: 600 },
  { rec: () => J.tool("toolu_vfile", "Write", { file_path: "/tmp/pr-check/verdicts.txt", content: VERDICTS }, OPUS), pause: 300 },
  { rec: () => J.result("toolu_vfile", "File created successfully at: /tmp/pr-check/verdicts.txt"), pause: 300 },
  { rec: () => J.tool("toolu_verdicts", "Bash", { command: "bash scripts/cr/write-verdicts.sh prior-blocking --branch 'fix/check-ci-cap' --from-file /tmp/pr-check/verdicts.txt", description: "Record the verdicts" }, OPUS), pause: 500 },
  { rec: () => J.result("toolu_verdicts", "write-verdicts: 3 verdicts recorded"), pause: 900 },
  { rec: () => J.tool("toolu_push", "Bash", { command: "git push origin HEAD:main", description: "Push the fix" }, OPUS), pause: 500 },
  { rec: () => J.result("toolu_push", "PreToolUse:Bash hook error: check-push-target: refusing a direct push to main", { error: true }), pause: 700 },
  { rec: () => J.tool("toolu_msg", "SendMessage", { to: "HIMMEL-roadmap-console", message: "BLOCKED suite red and the push guard refused; need a ruling" }, OPUS), pause: 400 },
  { rec: () => J.result("toolu_msg", "Message sent."), pause: 600 },
  { rec: () => J.text("BLOCKED: the suite is red and the push guard refused. Holding for the console.", "end_turn", OPUS), pause: 600 },
  { rec: () => J.end(), pause: 0 },
];

export async function play(h: AguiHarness, steps = SCENE, wait = (_ms: number) => Promise.resolve()) {
  for (const s of steps) {
    if (s.sub) h.appendSub(s.sub, s.rec());
    else h.append(s.rec());
    await wait(s.pause);
  }
}
