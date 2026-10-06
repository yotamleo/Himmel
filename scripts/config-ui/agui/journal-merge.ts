// journal-merge.ts — a session's journal plus its subagent transcripts, as one stream of lines in time
// order (HIMMEL-4670 P1). The order rule is defined here once: journalStream (sse.ts) applies it to the
// lines it has read so far, and mergeJournalFiles applies it to whole files for a batch reader (the leg
// digest), so the page and the digest interleave subagent lines the same way.
//
// Order: by the record's "timestamp"; a line with none takes the last timestamp seen in its own file; ties
// keep read order (files in the order given, then line order). A session's subagents write
// <session>/subagents/agent-<id>.jsonl beside <session>.jsonl; only plain names are joined, a file whose
// realpath leaves the journal's own directory is skipped, and at most MAX_SUBAGENTS are followed.

import { readdir, readFile, realpath, stat } from "node:fs/promises";
import { basename, dirname, join, resolve, sep } from "node:path";

export const MAX_SUBAGENTS = 64; // files followed per session, beside the journal itself

export type Line = { text: string; ts: number; order: number };
const TS = /"timestamp"\s*:\s*"([^"]+)"/;

// Stamps one file's complete lines with their time; `last` is that file's carried timestamp, updated.
export function stampLines(texts: string[], last: { ts: number }, next: () => number): Line[] {
  return texts.map((text) => {
    const ms = Date.parse(TS.exec(text)?.[1] ?? "");
    if (Number.isFinite(ms)) last.ts = ms;
    return { text, ts: last.ts, order: next() };
  });
}

export const byTime = (a: Line, b: Line) => a.ts - b.ts || a.order - b.order;

const SUB_FILE = /^agent-[A-Za-z0-9_-]{1,64}\.jsonl$/;

// The subagent transcripts of `journal` not yet in `known` (which holds the journal itself too), up to the cap.
export async function subagentFiles(journal: string, known: Set<string>): Promise<string[]> {
  return (await listSubagents(journal, known)).files;
}

async function listSubagents(journal: string, known: Set<string>): Promise<{ files: string[]; capped: boolean }> {
  const dir = dirname(resolve(journal));
  const subs = join(dir, basename(journal, ".jsonl"), "subagents");
  let names: string[];
  try { names = await readdir(subs); } catch { return { files: [], capped: false }; }
  const out: string[] = [];
  let capped = false;
  for (const name of names.filter((n) => SUB_FILE.test(n)).sort()) {
    let real: string;
    try { real = await realpath(join(subs, name)); } catch { continue; }
    if (known.has(real) || !real.startsWith(dir + sep)) continue;
    try { if (!(await stat(real)).isFile()) continue; } catch { continue; }
    if (known.size - 1 + out.length >= MAX_SUBAGENTS) { capped = true; break; }
    out.push(real);
  }
  return { files: out, capped };
}

// The journal and its subagent transcripts, in merge order; capped when more subagent files exist than are followed.
export async function sessionFiles(journal: string): Promise<{ paths: string[]; capped: boolean }> {
  const { files, capped } = await listSubagents(journal, new Set([journal]));
  return { paths: [journal, ...files], capped };
}

// Whole files → their non-blank lines in merge order. A final line with no newline is kept; a file that cannot be
// read (gone since it was listed) is skipped and counted.
export async function mergeJournalFiles(paths: string[]): Promise<{ lines: string[]; skipped: number }> {
  let order = 0;
  let skipped = 0;
  let lines: Line[] = [];
  for (const p of paths) {
    let body: string;
    try { body = await readFile(p, "utf8"); } catch { skipped++; continue; }
    // concat, not push(...spread): a long journal has more lines than a call takes arguments
    lines = lines.concat(stampLines(body.split("\n").filter((t) => t.trim()), { ts: -Infinity }, () => order++));
  }
  return { lines: lines.sort(byTime).map((l) => l.text), skipped };
}
