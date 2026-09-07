// scripts/telegram/compose-brief.ts
// HIMMEL-1734 P1 (design §4.3, C4): compose a lane dispatch brief as CODE,
// not retyped prose. This is the fix for "the RETASK block reaches only the
// GLM/claudex lanes" (design §1) — a lane-agnostic CLI any dispatcher can
// shell out to, producing a brief file a spawn-glm/spawn-claudex `--brief-file`
// (or a judge's own dispatch) can point a worker at.
//
// Deliberately imports ONLY brief-blocks.ts, never spawn-glm.ts — pulling in
// the GLM spawner here would drag its whole env/quota/guard machinery into a
// composer that has no business touching any of it (the reason brief-blocks.ts
// was extracted in the first place, design §4.3).
import { mkdirSync, readFileSync, writeFileSync, existsSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { mintRetaskNonce, composeRetaskBlock, composeWaiterBlock, composeWriteSetBlock } from "./brief-blocks";

// HIMMEL-203: argv carries ONLY enums, ids and paths — never free text. A
// model-authored string containing `$`/backticks/`&&` bails Claude Code's
// native permission matcher to an interactive prompt an unattended judge
// cannot answer (the same reasoning as the leg manifest's --evidence-file /
// --title-file convention, design §4.2). The task body therefore arrives
// exclusively via --task-file, never as a positional or flag value.
export type ComposeBriefArgs = {
  lane: string;
  model: string;
  effort: string;
  taskFile: string;
  writeSet: string[];
  out: string;
};

const USAGE = "usage: compose-brief --lane <l> --model <m> --effort <e> --task-file <f> [--write-set <path>]... --out <path>";

// HIMMEL-1225 style (spawn-glm.ts): --help/-h short-circuits before any side
// effect, checked on the raw argv before parsing.
export function isHelpFlag(argv: string[]): boolean {
  return argv.includes("--help") || argv.includes("-h");
}

// CR round 1 [codex-2]/[codex-3]: enforce the HIMMEL-203 argv contract
// ("argv carries ONLY enums, ids and paths — never free text", line 16 above)
// structurally instead of just documenting it. --lane/--model/--effort get
// interpolated verbatim into the brief header, and --write-set values into
// the write-set block; unvalidated, a newline in any of them forges brief
// sections. ENUM_RE pins the header fields to identifier shape; --write-set
// only rejects control chars (newlines included) — it still needs ordinary
// path characters (spaces, /, \, :), so no full path grammar here (that's
// single-writer enforcement's job, out of scope for this fix).
const ENUM_RE = /^[A-Za-z0-9][A-Za-z0-9._-]*$/;
const hasControlChar = (v: string): boolean => /[\x00-\x1f]/.test(v);

// Mirrors spawn-glm.ts's parseArgs: a value-taking flag with no value, or a
// missing required flag, is a clean usage refusal — never a silent undefined
// that surfaces later as a confusing crash.
export function parseArgs(argv: string[]): { ok: true; args: ComposeBriefArgs } | { ok: false; error: string } {
  let lane: string | undefined;
  let model: string | undefined;
  let effort: string | undefined;
  let taskFile: string | undefined;
  let out: string | undefined;
  const writeSet: string[] = [];
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--lane") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--lane requires a value" }; if (!ENUM_RE.test(v)) return { ok: false, error: "--lane must be an identifier (letters, digits, '.', '_', '-')" }; lane = v; }
    else if (a === "--model") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--model requires a value" }; if (!ENUM_RE.test(v)) return { ok: false, error: "--model must be an identifier (letters, digits, '.', '_', '-')" }; model = v; }
    else if (a === "--effort") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--effort requires a value" }; if (!ENUM_RE.test(v)) return { ok: false, error: "--effort must be an identifier (letters, digits, '.', '_', '-')" }; effort = v; }
    else if (a === "--task-file") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--task-file requires a value" }; taskFile = v; }
    else if (a === "--write-set") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--write-set requires a value" }; if (hasControlChar(v)) return { ok: false, error: "--write-set must not contain control characters" }; writeSet.push(v); }
    else if (a === "--out") { const v = argv[++i]; if (v === undefined) return { ok: false, error: "--out requires a value" }; out = v; }
    else return { ok: false, error: `unrecognized flag "${a}" (--help for usage)` };
  }
  if (!lane) return { ok: false, error: "--lane is required" };
  if (!model) return { ok: false, error: "--model is required" };
  if (!effort) return { ok: false, error: "--effort is required" };
  if (!taskFile) return { ok: false, error: "--task-file is required" };
  if (!out) return { ok: false, error: "--out is required" };
  return { ok: true, args: { lane, model, effort, taskFile, writeSet, out } };
}

// Pure composition — the document order is the C4 acceptance shape (design
// §4.3 / §8): header, task body, write-set (omitted when empty), waiter,
// RETASK (fresh nonce every call). `nonce` is injected so tests can assert
// against a known token instead of parsing one back out.
export function composeBrief(args: { lane: string; model: string; effort: string; taskBody: string; writeSet: string[] }, nonce: string): string {
  const header = `LANE: ${args.lane}  MODEL: ${args.model}  EFFORT: ${args.effort}`;
  const writeSetBlock = composeWriteSetBlock(args.writeSet);
  return [
    header,
    args.taskBody,
    ...(writeSetBlock ? [writeSetBlock] : []),
    composeWaiterBlock(),
    composeRetaskBlock(nonce),
  ].join("\n\n");
}

async function main(): Promise<void> {
  const rawArgv = process.argv.slice(2);
  if (isHelpFlag(rawArgv)) { console.log(USAGE); process.exit(0); }
  const parsed = parseArgs(rawArgv);
  if (!parsed.ok) { console.error(`compose-brief: ${parsed.error}`); console.error(USAGE); process.exit(2); }
  const { lane, model, effort, taskFile, writeSet, out } = parsed.args;

  // C4 / HIMMEL-203: refuse before any side effect (no --out write) if the
  // task file is missing or unreadable — free text arrives via files, never
  // argv, and an unreadable file must not silently compose a brief with an
  // empty task body.
  let taskBody: string;
  try {
    taskBody = readFileSync(resolve(taskFile), "utf8");
  } catch (e) {
    console.error(`compose-brief: --task-file ${taskFile} is missing or unreadable: ${String((e as any)?.message ?? e)}`);
    process.exit(2);
    return;
  }

  const brief = composeBrief({ lane, model, effort, taskBody, writeSet }, mintRetaskNonce());

  const outPath = resolve(out);
  const parent = dirname(outPath);
  if (!existsSync(parent)) mkdirSync(parent, { recursive: true });
  writeFileSync(outPath, brief);
  console.log(outPath);
}

if (import.meta.main) {
  main().catch((e) => { console.error(`compose-brief: ${String((e as any)?.message ?? e)}`); process.exit(1); });
}
