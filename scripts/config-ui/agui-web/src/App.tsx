import { useEffect, useReducer, useRef, useState, type CSSProperties, type ReactNode } from "react";
import { agentState, currentCall, initialView, liveness, reduce, runClock, runningCount, settledCount, type Agent, type ClockAnchor, type Entry, type Failure, type Text, type Tool, type View } from "./reducer";
import type { Source } from "./stream";

// A transport failure ends the run the same way RUN_ERROR does, so calls still running are marked failed too.
type Action = { kind: "event"; e: any } | { kind: "reset" } | { kind: "fail"; message: string };
const step = (v: View, a: Action): View =>
  a.kind === "reset" ? initialView()
  : a.kind === "fail" ? reduce(v, { type: "RUN_ERROR", message: a.message } as any) // no timestamp: ends at the run's last time
  : reduce(v, a.e);

// HIMMEL-4669: each agent gets a colour by order of appearance (six, then they repeat), carried as --ag on
// everything it did: its band in the strip, its row in the agent list, the rail beside its texts and calls.
const agentStyle = (v: View, id: string): CSSProperties => ({ ["--ag" as string]: `var(--ag${Math.max(v.agentOrder.indexOf(id), 0) % 6})` });

export function App({ source }: { source: Source }) {
  const [view, dispatch] = useReducer(step, undefined, initialView);
  const [epoch, setEpoch] = useState(0);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const [only, setOnly] = useState<string | null>(null); // the one agent shown, or everyone
  const [at, setAt] = useState(-1); // the failure last jumped to
  const [closed, setClosed] = useState(false); // HIMMEL-4711: the live stream ended (the server stopped tailing)
  // A live page between turns keeps ticking too, so "last event Ns ago" stays true.
  const now = useRunClock(view, view.status === "running" || (source.live && !closed && view.status === "finished"));

  useEffect(() => {
    dispatch({ kind: "reset" });
    setClosed(false);
    return source.start((e) => dispatch({ kind: "event", e }), (message) => dispatch({ kind: "fail", message }), () => setClosed(true));
  }, [source, epoch]);

  const focus = (id: string) => requestAnimationFrame(() => document.getElementById(id)?.focus());
  const reveal = (id: string) => {
    setOpen((o) => ({ ...o, [id]: true }));
    focus(`call-${id}`);
  };
  // Jumps through the failures in stream order, showing everyone if the filter hides the next one.
  const jump = (dir: 1 | -1) => {
    const n = view.failures.length;
    if (!n) return;
    const i = ((at < 0 && dir < 0 ? 0 : at + dir) % n + n) % n;
    const f = view.failures[i];
    const owner = f.kind === "tool" ? view.tools[f.id]?.agent : view.texts[f.id]?.agent;
    if (only && owner !== only) setOnly(null);
    setAt(i);
    if (f.kind === "tool") reveal(f.id);
    else focus(`msg-${f.id}`);
  };

  return (
    <>
      <TopBar view={view} now={now} source={source} closed={closed} at={at} onJump={jump}
        onReplay={() => { setOpen({}); setOnly(null); setAt(-1); setEpoch((n) => n + 1); }} />
      <RunStrip view={view} now={now} only={only} onPick={(id) => { if (only && view.tools[id]?.agent !== only) setOnly(null); reveal(id); }} />
      <div className="layout">
        <main className="transcript" aria-label="Agent transcript">
          {view.entries.length === 0 && <p className="quiet">{view.status === "error" ? "" : "Waiting for the agent's first event."}</p>}
          <Transcript view={view} now={now} only={only} open={open} onToggle={(id) => setOpen((o) => ({ ...o, [id]: !o[id] }))} />
          {view.status === "error" && <p className="run-error" role="alert">The run stopped: {view.error || "the stream failed"}.</p>}
        </main>
        <aside className="side">
          <Agents view={view} now={now} only={only} onOnly={setOnly} />
          {view.state?.review && <ReviewPanel review={view.state.review} />}
        </aside>
      </div>
    </>
  );
}

// While the run is live, time keeps moving between events so running bars keep growing.
function useRunClock(view: View, ticking: boolean): number {
  const [tick, setTick] = useState(0);
  const last = useRef<ClockAnchor | undefined>(undefined);
  const clock = runClock(last.current, view, Date.now());
  last.current = clock.anchor;
  useEffect(() => {
    if (!ticking) return;
    const id = setInterval(() => setTick((n) => n + 1), 250);
    return () => clearInterval(id);
  }, [ticking]);
  void tick;
  return clock.now;
}

const secs = (ms: number) => (ms < 10000 ? (ms / 1000).toFixed(1) : Math.round(ms / 1000).toString()) + "s";
// Wall-clock time of a run's moment: the stream's own clock (t0) plus the elapsed ms.
const clockTime = (ms: number) => new Date(ms).toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const plural = (n: number, one: string, many = one + "s") => `${n} ${n === 1 ? one : many}`;

function TopBar({ view, now, source, closed, at, onJump, onReplay }: {
  view: View; now: number; source: Source; closed: boolean; at: number; onJump: (dir: 1 | -1) => void; onReplay: () => void;
}) {
  const n = view.failures.length;
  const state = liveness(view, { live: source.live, closed }, Date.now());
  const turns = view.entries.filter((en) => en.kind === "turn").length;
  return (
    <header className="top">
      <span className="brand">himmel</span>
      <span className="run">{source.live ? `run ${source.run}` : "recorded review run"}</span>
      <span className={`state ${state.cls}`} role="status">{state.word}</span>
      <span className="meta">{[view.t0 !== undefined && `started ${clockTime(view.t0)}`, plural(turns, "turn"), `${view.eventCount} events`, secs(now)]
        .filter(Boolean).join(" · ")}</span>
      {n > 0 && (
        <span className="fails" role="group" aria-label="Failures">
          <span className="fails-count" aria-live="polite">{plural(n, "failure")}{at >= 0 ? ` · ${Math.min(at, n - 1) + 1} of ${n}` : ""}</span>
          <button className="btn" onClick={() => onJump(-1)} aria-label="Previous failure">↑</button>
          <button className="btn" onClick={() => onJump(1)} aria-label="Next failure">↓ next</button>
        </span>
      )}
      {!source.live && view.status === "finished" && <button className="btn replay" onClick={onReplay}>Replay</button>}
    </header>
  );
}

// One band per agent, in order of appearance; inside a band, parallel calls stack on its lanes.
function RunStrip({ view, now, only, onPick }: { view: View; now: number; only: string | null; onPick: (id: string) => void }) {
  const total = Math.max(now, 1);
  const tools = Object.values(view.tools).sort((a, b) => a.start - b.start);
  const bands = view.agentOrder.filter((id) => view.agents[id].lanes > 0);
  return (
    <section className="strip" aria-label="Tool calls over time, by agent">
      <div className="axis"><span>0s</span><span>{secs(total)}</span></div>
      {bands.map((id) => {
        const a = view.agents[id];
        return (
          <div key={id} className={`band${only && only !== id ? " dim" : ""}`} style={agentStyle(view, id)}>
            <span className="band-name" title={`${a.name} · ${a.role}`}><i className="dot" aria-hidden="true" />{a.name}</span>
            <div className="lanes" style={{ height: `calc(var(--lane) * ${a.lanes})` }}>
              {tools.filter((t) => t.agent === id).map((t) => {
                const left = (t.start / total) * 100;
                const width = Math.max(((t.end ?? now) - t.start) / total * 100, 0.6);
                return (
                  <button key={t.id} className={`bar ${t.status}${t.failure ? ` failed ${t.failure}` : ""}`}
                    style={{ left: `${left}%`, width: `${width}%`, top: `calc(var(--lane) * ${t.lane})` }}
                    onClick={() => onPick(t.id)}
                    aria-label={`${a.name}: ${t.name} ${summarize(t)}, ${stateWord(t)}, ${secs((t.end ?? now) - t.start)}`}>
                    <span>{t.name} <i>{summarize(t)}</i></span>
                  </button>
                );
              })}
            </div>
          </div>
        );
      })}
    </section>
  );
}

const ROLE: Record<Agent["role"], string> = { console: "console", leg: "leg", judge: "judge", critic: "critic", subagent: "subagent", agent: "agent" };
// "claude-opus-5-5" reads as "opus 5.5"; an alias or anything else stays as written.
const model = (m?: string) => m?.replace(/^claude-([a-z]+)-(\d+)-(\d+)(?:-\d{8})?$/, "$1 $2.$3");

// The agent list doubles as the legend and the filter: click one to show only what it did.
// HIMMEL-4711: each agent's state; a running one shows the call it is in and for how long, a finished one when it last acted.
function Agents({ view, now, only, onOnly }: { view: View; now: number; only: string | null; onOnly: (id: string | null) => void }) {
  if (view.agentOrder.length === 0) return null;
  const depth = (a: Agent) => (a.parentToolCallId ? 1 : 0);
  return (
    <section className="agents" aria-labelledby="agents-title">
      <h2 id="agents-title">Agents <span className="agents-running">{runningCount(view)} running</span></h2>
      <ul>
        {view.agentOrder.map((id) => {
          const a = view.agents[id];
          const st = agentState(view, id);
          const cur = st === "running" ? currentCall(view, id) : undefined;
          return (
            <li key={id} style={{ ...agentStyle(view, id), ["--depth" as string]: depth(a) }}>
              <button className="agent" aria-pressed={only === id} onClick={() => onOnly(only === id ? null : id)}
                title={only === id ? "Show every agent" : `Show only ${a.name}`}>
                <i className="dot" aria-hidden="true" />
                <span className="agent-name">{a.name}</span>
                <span className="agent-meta">{[ROLE[a.role], a.kind && a.kind !== a.role ? a.kind.replace(/^.*:/, "") : "", model(a.model)].filter(Boolean).join(" · ")}</span>
                <span className="agent-count">{plural(a.calls, "call")}</span>
                <span className={`agent-state ${st}`}>{st}</span>
                {a.failures > 0 && <span className="agent-fail">{plural(a.failures, "failure")}</span>}
                {cur ? <span className="agent-now">{cur.name} {summarize(cur)} · {secs(now - cur.start)}</span>
                  : view.t0 !== undefined && <span className="agent-now">last active {clockTime(view.t0 + a.last)}</span>}
              </button>
            </li>
          );
        })}
      </ul>
      {only && <button className="btn" onClick={() => onOnly(null)}>Show every agent</button>}
    </section>
  );
}

// Turns, then runs of one agent's work under that agent's name: a reader sees who acted before what they did.
function Transcript({ view, now, only, open, onToggle }: {
  view: View; now: number; only: string | null; open: Record<string, boolean>; onToggle: (id: string) => void;
}) {
  const owner = (en: Entry) => (en.kind === "text" ? view.texts[en.id].agent : en.kind === "tools" ? view.tools[en.ids[0]].agent : null);
  const shown = view.entries.filter((en) => !only || en.kind === "turn" || owner(en) === only);
  const blocks: { agent: string | null; entries: Entry[] }[] = [];
  for (const en of shown) {
    const a = owner(en);
    const last = blocks[blocks.length - 1];
    if (last && a !== null && last.agent === a) last.entries.push(en);
    else blocks.push({ agent: a, entries: [en] });
  }
  return (
    <>
      {blocks.map((b, i) => b.agent === null
        ? b.entries.map((en) => en.kind === "turn" && <TurnHead key={`turn-${en.id}-${i}`} n={en.n} at={en.at} />)
        : (
          <section key={`${b.agent}-${i}`} className={`block${view.agents[b.agent]?.parentToolCallId ? " sub" : ""}`}
            style={agentStyle(view, b.agent)} aria-label={`${view.agents[b.agent]?.name ?? "agent"}`}>
            <AgentHead agent={view.agents[b.agent]} />
            {b.entries.map((en) =>
              en.kind === "text" ? <Message key={en.id} t={view.texts[en.id]} sub={!!view.agents[b.agent!]?.parentToolCallId} />
              : en.kind === "tools" ? <CallGroup key={en.ids[0]} tools={en.ids.map((id) => view.tools[id])} now={now} open={open} onToggle={onToggle} />
              : null)}
          </section>
        ))}
    </>
  );
}

const TurnHead = ({ n, at }: { n: number; at: number }) => <h2 className="turn"><span>Turn {n}</span><span>{secs(at)}</span></h2>;

const AgentHead = ({ agent }: { agent?: Agent }) => agent ? (
  <p className="agent-head"><i className="dot" aria-hidden="true" /><b>{agent.name}</b>
    <span>{[ROLE[agent.role], model(agent.model)].filter(Boolean).join(" · ")}</span></p>
) : null;

const FAILURE: Record<Failure, string> = { denied: "denied", suite: "suite failed", blocked: "blocked", error: "error" };

// Inline `code` is the only markup a message gets; everything else stays text. A subagent's prompt is its brief.
function Message({ t, sub }: { t: Text; sub: boolean }) {
  const parts = t.text.split("`");
  const kind = t.role === "user" ? (sub ? " brief" : " prompt") : "";
  return (
    <div id={`msg-${t.id}`} tabIndex={-1} className={`msg${kind}${t.failure ? ` failed ${t.failure}` : ""}`}>
      {t.failure && <span className={`badge ${t.failure}`}>{FAILURE[t.failure]}</span>}
      {kind === " brief" && <span className="msg-label">brief</span>}
      <p>
        {parts.map((p, i) => (i % 2 ? <code key={i}>{p}</code> : p))}
        {t.open && <span className="caret" aria-hidden="true" />}
      </p>
    </div>
  );
}

function CallGroup({ tools, now, open, onToggle }: { tools: Tool[]; now: number; open: Record<string, boolean>; onToggle: (id: string) => void }) {
  const cards = tools.map((t) => <ToolCard key={t.id} tool={t} now={now} open={!!open[t.id]} onToggle={() => onToggle(t.id)} />);
  if (tools.length === 1) return cards[0];
  return (
    <section className="group" aria-label={`${tools.length} calls in parallel`}>
      <p className="group-label">{tools.length} calls in parallel</p>
      <div className="group-cards">{cards}</div>
    </section>
  );
}

const STATE_WORD: Record<Tool["status"], string> = { running: "running", done: "done", error: "failed" };
const stateWord = (t: Tool) => (t.failure ? FAILURE[t.failure] : STATE_WORD[t.status]);

function ToolCard({ tool, now, open, onToggle }: { tool: Tool; now: number; open: boolean; onToggle: () => void }) {
  return (
    <article className={`call ${tool.status}${tool.failure ? ` failed ${tool.failure}` : ""}`}>
      <button id={`call-${tool.id}`} className="call-head" aria-expanded={open} onClick={onToggle}>
        <span className="call-name">{tool.name}</span>
        <span className="call-sum">{summarize(tool)}</span>
        <span className="call-state">{tool.failure && <span className={`badge ${tool.failure}`}>{FAILURE[tool.failure]}</span>}
          {tool.failure ? "" : STATE_WORD[tool.status]} {secs((tool.end ?? now) - tool.start)}</span>
      </button>
      {open && (
        <div className="call-body">
          <Field label="Input">{pretty(tool.args) || "—"}</Field>
          {tool.result !== undefined && <Output label={tool.failure ? FAILURE[tool.failure] : tool.status === "error" ? "Error" : "Result"} text={tool.result || "(empty)"} />}
        </div>
      )}
    </article>
  );
}

const Field = ({ label, children }: { label: string; children: ReactNode }) => (
  <div className="field"><span>{label}</span><pre>{children}</pre></div>
);

// Long output shows its head; the rest is one click away.
const HEAD_LINES = 12;
function Output({ label, text }: { label: string; text: string }) {
  const [all, setAll] = useState(false);
  const lines = text.split("\n");
  const long = lines.length > HEAD_LINES + 3;
  return (
    <div className="field">
      <span>{label}</span>
      <pre>{long && !all ? lines.slice(0, HEAD_LINES).join("\n") : text}</pre>
      {long && <button className="more" aria-expanded={all} onClick={() => setAll(!all)}>{all ? "Show less" : `Show all ${lines.length} lines`}</button>}
    </div>
  );
}

function parseArgs(args: string): Record<string, unknown> | null {
  try { const v = JSON.parse(args); return v && typeof v === "object" ? v : null; } catch { return null; }
}
const pretty = (args: string) => { const v = parseArgs(args); return v ? JSON.stringify(v, null, 2) : args; };

// The one argument that says what a call is doing; args still streaming show their raw prefix.
function summarize(t: Tool): string {
  const a = parseArgs(t.args);
  if (!a) return t.args.slice(0, 80);
  for (const k of ["description", "command", "file_path", "pattern", "url", "query"]) if (typeof a[k] === "string") return a[k] as string;
  const first = Object.values(a).find((x) => typeof x === "string");
  return typeof first === "string" ? first : "";
}

// ---- review panel: findings by severity, verdicts, round ----
const SEVERITIES: [string, string][] = [["crit", "Critical"], ["major", "Major"], ["imp", "Important"], ["minor", "Minor"], ["sug", "Suggestion"]];
const VERDICT: Record<string, string> = {
  agreed: "agreed", fixed: "fixed", disproved: "disproved", deferred: "deferred", conflict: "conflict", unaddressed: "unaddressed",
};
type Finding = { id?: string; severity?: string; title?: string; file?: string; line?: number; verdict?: string; ticket?: string };
type Review = { pr?: number; head?: string; round?: number; maxRounds?: number; findings?: Finding[] };

function ReviewPanel({ review }: { review?: Review }) {
  const findings = Array.isArray(review?.findings) ? review!.findings : [];
  const known = new Set(SEVERITIES.map(([k]) => k));
  const groups: [string, string, Finding[]][] = [
    ...SEVERITIES.map(([k, label]): [string, string, Finding[]] => [k, label, findings.filter((f) => f.severity === k)]),
    ["other", "Other", findings.filter((f) => !known.has(f.severity ?? ""))],
  ];
  const settled = settledCount(findings);
  const rounds = review?.maxRounds ?? review?.round ?? 0;
  return (
    <section className="panel" aria-labelledby="panel-title">
      <h2 id="panel-title">Review panel</h2>
      <p className="panel-sub" aria-live="polite">
        {[review?.pr && `PR #${review.pr}`, review?.head && <code key="h">{review.head}</code>,
          review?.round && `round ${review.round}${review.maxRounds ? ` of ${review.maxRounds}` : ""}`]
          .filter(Boolean).flatMap((x, i) => (i ? [" · ", x] : [x]))}
        {findings.length > 0 && <span className="settled">{settled} of {findings.length} findings settled</span>}
      </p>
      {rounds > 0 && (
        <div className="rounds" role="img" aria-label={`round ${review?.round ?? 0} of ${rounds}`}>
          {Array.from({ length: rounds }, (_, i) => <i key={i} className={i < (review?.round ?? 0) ? "on" : ""} />)}
        </div>
      )}
      {findings.length === 0 && <p className="quiet">Findings appear here when a review round reports.</p>}
      {groups.filter(([, , fs]) => fs.length).map(([k, label, fs]) => (
        <section key={k} className={`sev ${k}`} aria-label={`${label}: ${fs.length}`}>
          <h3><span>{label}</span><span>{fs.length}</span></h3>
          <ul>
            {fs.map((f, i) => (
              <li key={f.id ?? i} className="finding">
                <span className="f-title">{f.title ?? "Untitled finding"}</span>
                <span className={`verdict ${f.verdict ?? "open"}`}>{f.verdict ? VERDICT[f.verdict] ?? f.verdict : "open"}</span>
                {(f.file || f.ticket) && (
                  <span className="f-loc">{f.file}{f.line ? `:${f.line}` : ""}{f.ticket && <span className="ticket">{f.file ? " → " : ""}{f.ticket}</span>}</span>
                )}
              </li>
            ))}
          </ul>
        </section>
      ))}
    </section>
  );
}
