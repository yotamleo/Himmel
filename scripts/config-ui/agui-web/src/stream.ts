// Where events come from: a live run over AG-UI (SSE via @ag-ui/client), or the recorded fixture replayed
// with its own timing when the page is opened without a run id (a static preview needs no server).
import { HttpAgent } from "@ag-ui/client";
import fixture from "./fixture.json";
import { stampMissing } from "./reducer";

// The one place the endpoint shape lives (PR2 serves it from the config-ui server, token-gated).
export const AGUI_URL = (run: string) => `/api/agui/${encodeURIComponent(run)}`;

type Ev = { type: string; timestamp?: number; [k: string]: unknown };
export type Source = { live: boolean; run?: string; start: (onEvent: (e: Ev) => void, onFail: (msg: string) => void) => () => void };

// config-ui hands the page its token in the URL fragment (never in a request line): #t=<token>&run=<id>.
export function sourceFromLocation(hash: string): Source {
  const p = new URLSearchParams(hash.replace(/^#/, ""));
  const run = p.get("run");
  return run ? live(run, p.get("t") ?? "") : replay();
}

// The endpoint is a GET (the run already exists), so the client's POST body is dropped; the token rides the
// same header the rest of config-ui uses.
class RunStreamAgent extends HttpAgent {
  protected requestInit(): RequestInit {
    return { method: "GET", headers: { ...this.headers, Accept: "text/event-stream" }, signal: this.abortController.signal };
  }
}

function live(run: string, token: string): Source {
  return {
    live: true, run,
    start(onEvent, onFail) {
      const agent = new RunStreamAgent({ url: AGUI_URL(run), headers: { "X-Himmel-Token": token } });
      const input = { threadId: run, runId: run, messages: [], tools: [], context: [], state: {}, forwardedProps: {} };
      let ended = false;
      const sub = agent.run(input).subscribe({
        next: (e) => {
          if (e.type === "RUN_FINISHED" || e.type === "RUN_ERROR") ended = true;
          onEvent(stampMissing(e as Ev, Date.now()));
        },
        error: (err: unknown) => onFail(String((err as Error)?.message ?? err)),
        complete: () => { if (!ended) onFail("the stream closed before the run finished"); },
      });
      return () => { sub.unsubscribe(); agent.abortController.abort(); };
    },
  };
}

// Replays the fixture at recorded pace, with long gaps (a reviewer thinking) cut to MAX_GAP so the preview moves.
const MAX_GAP = 1200;
function replay(): Source {
  return {
    live: false,
    start(onEvent) {
      const events = fixture as Ev[];
      let i = 0, timer: ReturnType<typeof setTimeout> | undefined;
      const step = () => {
        const e = events[i++];
        onEvent({ ...e, timestamp: Date.now() }); // restamped, so the strip shows the pace the viewer sees
        const next = events[i];
        if (next) timer = setTimeout(step, Math.min(MAX_GAP, (next.timestamp ?? 0) - (e.timestamp ?? 0)));
      };
      timer = setTimeout(step, 300);
      return () => clearTimeout(timer);
    },
  };
}
