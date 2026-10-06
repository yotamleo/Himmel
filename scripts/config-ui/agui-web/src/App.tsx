import { useEffect, useReducer, useRef, useState, type ReactNode } from "react";
import { initialView, reduce, type Tool, type View } from "./reducer";
import type { Source } from "./stream";

type Action = { kind: "event"; e: any } | { kind: "reset" } | { kind: "fail"; message: string };
const step = (v: View, a: Action): View =>
  a.kind === "reset" ? initialView()
  : a.kind === "fail" ? { ...v, status: "error", error: a.message }
  : reduce(v, a.e);

export function App({ source }: { source: Source }) {
  const [view, dispatch] = useReducer(step, undefined, initialView);
  const [epoch, setEpoch] = useState(0);
  const [open, setOpen] = useState<Record<string, boolean>>({});
  const now = useRunClock(view);

  useEffect(() => {
    dispatch({ kind: "reset" });
    return source.start((e) => dispatch({ kind: "event", e }), (message) => dispatch({ kind: "fail", message }));
  }, [source, epoch]);

  const reveal = (id: string) => {
    setOpen((o) => ({ ...o, [id]: true }));
    requestAnimationFrame(() => document.getElementById(`call-${id}`)?.focus());
  };

  return (
    <>
      <TopBar view={view} now={now} source={source} onReplay={() => { setOpen({}); setEpoch((n) => n + 1); }} />
      <RunStrip view={view} now={now} onPick={reveal} />
      <div className="layout">
        <main className="transcript" aria-label="Agent transcript">
          {view.entries.length === 0 && <p className="quiet">{view.status === "error" ? "" : "Waiting for the agent's first event."}</p>}
          {view.entries.map((en) =>
            en.kind === "text"
              ? <Message key={en.id} text={view.texts[en.id].text} open={view.texts[en.id].open} />
              : <CallGroup key={en.ids[0]} tools={en.ids.map((id) => view.tools[id])} now={now} open={open}
                  onToggle={(id) => setOpen((o) => ({ ...o, [id]: !o[id] }))} />)}
          {view.status === "error" && <p className="run-error" role="alert">The run stopped: {view.error || "the stream failed"}.</p>}
        </main>
        <ReviewPanel review={view.state?.review} />
      </div>
    </>
  );
}

// While the run is live, time keeps moving between events so running bars keep growing.
function useRunClock(view: View): number {
  const [tick, setTick] = useState(0);
  const last = useRef({ elapsed: 0, wall: Date.now() });
  if (last.current.elapsed !== view.elapsed) last.current = { elapsed: view.elapsed, wall: Date.now() };
  useEffect(() => {
    if (view.status !== "running") return;
    const id = setInterval(() => setTick((n) => n + 1), 250);
    return () => clearInterval(id);
  }, [view.status]);
  void tick;
  return view.status === "running" ? view.elapsed + (Date.now() - last.current.wall) : view.elapsed;
}

const secs = (ms: number) => (ms < 10000 ? (ms / 1000).toFixed(1) : Math.round(ms / 1000).toString()) + "s";
const STATUS: Record<View["status"], string> = { idle: "connecting", running: "streaming", finished: "finished", error: "stopped" };

function TopBar({ view, now, source, onReplay }: { view: View; now: number; source: Source; onReplay: () => void }) {
  return (
    <header className="top">
      <span className="brand">himmel</span>
      <span className="run">{source.live ? `run ${source.run}` : "recorded review run"}</span>
      <span className={`state ${view.status}`} role="status">{STATUS[view.status]}</span>
      <span className="meta">{view.eventCount} events · {secs(now)}</span>
      {!source.live && view.status === "finished" && <button className="btn" onClick={onReplay}>Replay</button>}
    </header>
  );
}

function RunStrip({ view, now, onPick }: { view: View; now: number; onPick: (id: string) => void }) {
  const total = Math.max(now, 1);
  // One flat list in start order (so Tab walks the run chronologically), each bar placed on its lane.
  const tools = Object.values(view.tools).sort((a, b) => a.start - b.start);
  return (
    <section className="strip" aria-label="Tool calls over time">
      <div className="axis"><span>0s</span><span>{secs(total)}</span></div>
      <div className="lanes" style={{ height: `calc(var(--lane) * ${Math.max(view.lanes, 1)})` }}>
        {tools.map((t) => {
          const left = (t.start / total) * 100;
          const width = Math.max(((t.end ?? now) - t.start) / total * 100, 0.6);
          return (
            <button key={t.id} className={`bar ${t.status}`}
              style={{ left: `${left}%`, width: `${width}%`, top: `calc(var(--lane) * ${t.lane})` }}
              onClick={() => onPick(t.id)} aria-label={`${t.name} ${summarize(t)}, ${STATE_WORD[t.status]}, ${secs((t.end ?? now) - t.start)}`}>
              <span>{t.name} <i>{summarize(t)}</i></span>
            </button>
          );
        })}
      </div>
    </section>
  );
}

// Inline `code` is the only markup a message gets; everything else stays text.
function Message({ text, open }: { text: string; open: boolean }) {
  const parts = text.split("`");
  return (
    <p className="msg">
      {parts.map((p, i) => (i % 2 ? <code key={i}>{p}</code> : p))}
      {open && <span className="caret" aria-hidden="true" />}
    </p>
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

function ToolCard({ tool, now, open, onToggle }: { tool: Tool; now: number; open: boolean; onToggle: () => void }) {
  return (
    <article className={`call ${tool.status}`}>
      <button id={`call-${tool.id}`} className="call-head" aria-expanded={open} onClick={onToggle}>
        <span className="call-name">{tool.name}</span>
        <span className="call-sum">{summarize(tool)}</span>
        <span className="call-state">{STATE_WORD[tool.status]} {secs((tool.end ?? now) - tool.start)}</span>
      </button>
      {open && (
        <div className="call-body">
          <Field label="Input">{pretty(tool.args) || "—"}</Field>
          {tool.result !== undefined && <Field label={tool.status === "error" ? "Error" : "Result"}>{tool.result || "(empty)"}</Field>}
        </div>
      )}
    </article>
  );
}

const Field = ({ label, children }: { label: string; children: ReactNode }) => (
  <div className="field"><span>{label}</span><pre>{children}</pre></div>
);

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
  const settled = findings.filter((f) => f.verdict).length;
  const rounds = review?.maxRounds ?? review?.round ?? 0;
  return (
    <aside className="panel" aria-labelledby="panel-title">
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
    </aside>
  );
}
