import { appendFile, mkdir, readFile, readdir, stat } from "node:fs/promises";
import { dirname, join } from "node:path";
import { homedir } from "node:os";

export type Breadcrumb = { task:string; ticket:string; handover:string; cwd:string; armed_at:string; mode:"owner"|"ticket" };
export const DEFAULT_FILE = process.env.ARMED_SESSIONS_FILE ?? join(homedir(), ".claude", "handover", "armed-sessions.jsonl");

export async function record(b: Breadcrumb & { file?: string }): Promise<void> {
  const file = b.file ?? DEFAULT_FILE; await mkdir(dirname(file), { recursive: true });
  const { file: _o, ...row } = b as any;
  await appendFile(file, JSON.stringify(row) + "\n", "utf8");
}
export async function readBreadcrumbs(file = DEFAULT_FILE): Promise<Breadcrumb[]> {
  let t = ""; try { t = await readFile(file, "utf8"); } catch { return []; }
  return t.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l) as Breadcrumb; } catch { return null; } }).filter(Boolean) as Breadcrumb[];
}

export type StopPoint = { session_start:string|null; first_user:string|null; last_assistant_text:string|null; last_question:string|null; last_answers:string|null };
export async function parseTranscriptTail(path: string): Promise<StopPoint> {
  const out: StopPoint = { session_start:null, first_user:null, last_assistant_text:null, last_question:null, last_answers:null };
  const text = await readFile(path, "utf8");
  for (const line of text.split("\n")) {
    if (!line.trim()) continue;
    let o:any; try { o = JSON.parse(line); } catch { continue; }
    if (out.session_start === null && o.timestamp) out.session_start = o.timestamp;
    const content = o?.message?.content;
    if (o.type === "user") {
      if (out.first_user === null && typeof content === "string") out.first_user = content;
      if (Array.isArray(content)) for (const b of content) {
        if (b?.type === "tool_result") { const tr = typeof b.content==="string"?b.content:JSON.stringify(b.content);
          if (tr.includes("have been answered")) out.last_answers = tr; }
      }
    } else if (o.type === "assistant" && Array.isArray(content)) {
      for (const b of content) {
        if (b?.type === "text" && b.text) out.last_assistant_text = b.text;
        if (b?.type === "tool_use" && b.name === "AskUserQuestion") { const qs = b.input?.questions ?? []; if (qs.length) out.last_question = qs[0].question ?? null; }
      }
    }
  }
  return out;
}

const slugOf = (cwd:string) => cwd.replace(/[^A-Za-z0-9]/g, "-");
export type Resolved = StopPoint & { source:"breadcrumb"|"degrade"; found:boolean; ticket?:string; handover?:string; transcript?:string };
export async function resolve(opts:{ file?:string; projectsDir?:string } = {}): Promise<Resolved> {
  const file = opts.file ?? DEFAULT_FILE;
  const projectsDir = opts.projectsDir ?? process.env.CLAUDE_PROJECTS_DIR ?? join(homedir(), ".claude", "projects");
  const rows = await readBreadcrumbs(file);
  const last = rows[rows.length - 1];
  const cwd = last?.cwd ?? process.cwd();
  const source: Resolved["source"] = last ? "breadcrumb" : "degrade";
  const pdir = join(projectsDir, slugOf(cwd));
  let transcript = ""; let bestM = -1;
  try {
    for (const f of (await readdir(pdir)).filter((f)=>f.endsWith(".jsonl"))) {
      const full = join(pdir, f); const t = await readFile(full, "utf8");
      const firstUser = t.split("\n").map((l)=>{ try { return JSON.parse(l); } catch { return null; } })
        .find((o)=>o?.type==="user" && typeof o?.message?.content==="string");
      const isLoad = typeof firstUser?.message?.content==="string" && firstUser.message.content.startsWith("load ");
      const m = (await stat(full)).mtimeMs;
      if ((last || isLoad) && m > bestM) { bestM = m; transcript = full; }
    }
  } catch {}
  const empty: StopPoint = { session_start:null, first_user:null, last_assistant_text:null, last_question:null, last_answers:null };
  if (!transcript) return { ...empty, source, found:false, ticket:last?.ticket, handover:last?.handover };
  const tail = await parseTranscriptTail(transcript);
  return { ...tail, source, found:true, ticket:last?.ticket, handover:last?.handover, transcript };
}

if (import.meta.main) {
  const [verb, ...rest] = process.argv.slice(2);
  const arg = (n:string) => { const i = rest.indexOf("--"+n); return i>=0 ? rest[i+1] : ""; };
  if (verb === "record") await record({ task:arg("task"), ticket:arg("ticket"), handover:arg("handover"), cwd:arg("cwd"), armed_at:arg("armed-at"), mode:(arg("mode") as any)||"ticket" });
  else if (verb === "resolve") process.stdout.write(JSON.stringify(await resolve()));
  else { process.stderr.write("usage: armed-session-track.ts record|resolve\n"); process.exit(1); }
}
