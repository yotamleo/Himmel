import { test, expect, afterEach } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { createJournalMapper, mapFile } from "../agui/journal-mapper.ts";
import { MAX_SUBAGENTS, mergeJournalFiles, sessionFiles } from "../agui/journal-merge.ts";

// HIMMEL-4670 P1: the journal + subagent merge that journalStream follows live, as one batch function
// the leg digest calls, so both order a session's lines the same way.
const FIX = join(import.meta.dir, "fixtures", "agui");
const RUN = "0b6e1c2a-3f4d-4e5f-8a9b-0c1d2e3f4a5b";

let cleanup: (() => void)[] = [];
afterEach(() => { for (const f of cleanup.reverse()) f(); cleanup = []; });

function session(): { dir: string; journal: string; subs: string } {
  const dir = mkdtempSync(join(tmpdir(), "agui-merge-"));
  cleanup.push(() => rmSync(dir, { recursive: true, force: true }));
  const subs = join(dir, RUN, "subagents");
  mkdirSync(subs, { recursive: true });
  return { dir, journal: join(dir, `${RUN}.jsonl`), subs };
}
function splitAgents(): { mainBody: string; subBody: string } {
  const lines = readFileSync(join(FIX, "agents.jsonl"), "utf8").split("\n").filter(Boolean);
  const side = (l: string) => JSON.parse(l).isSidechain === true;
  return { mainBody: lines.filter((l) => !side(l)).join("\n") + "\n", subBody: lines.filter(side).join("\n") + "\n" };
}
const mapLines = (lines: string[]) => {
  const m = createJournalMapper({ threadId: RUN });
  return [...lines.flatMap((l) => m.pushLine(l)), ...m.flush()];
};
const rec = (uuid: string, ts?: string) => JSON.stringify({ type: "system", subtype: "x", uuid, ...(ts ? { timestamp: ts } : {}) });

test("a journal and its subagent transcript merge into the same events as the inline journal", async () => {
  const s = session();
  const { mainBody, subBody } = splitAgents();
  writeFileSync(s.journal, mainBody);
  writeFileSync(join(s.subs, "agent-a1b2c3.jsonl"), subBody);
  const { paths, capped } = await sessionFiles(s.journal);
  expect(capped).toBe(false);
  expect(paths.length).toBe(2);
  const lines = await mergeJournalFiles(paths);
  expect(mapLines(lines)).toEqual(mapFile(join(FIX, "agents.jsonl"), { threadId: RUN }).events);
});

test("a line with no timestamp sorts with the line before it in its own file; ties keep file order", async () => {
  const s = session();
  writeFileSync(s.journal, [rec("m1", "2026-10-06T12:00:01Z"), rec("m2"), rec("m3", "2026-10-06T12:00:03Z")].join("\n") + "\n");
  const sub = join(s.subs, "agent-x.jsonl");
  writeFileSync(sub, [rec("s1", "2026-10-06T12:00:01Z"), rec("s2", "2026-10-06T12:00:02Z")].join("\n") + "\n");
  const order = (await mergeJournalFiles([s.journal, sub])).map((l) => JSON.parse(l).uuid);
  expect(order).toEqual(["m1", "m2", "s1", "s2", "m3"]);
});

test("a final line with no newline is kept; blank lines are dropped", async () => {
  const s = session();
  writeFileSync(s.journal, rec("a", "2026-10-06T12:00:01Z") + "\n\n" + rec("b", "2026-10-06T12:00:02Z"));
  expect((await mergeJournalFiles([s.journal])).map((l) => JSON.parse(l).uuid)).toEqual(["a", "b"]);
});

test("sessionFiles skips a subagent file symlinked out of the session directory", async () => {
  const s = session();
  writeFileSync(s.journal, "");
  const out = mkdtempSync(join(tmpdir(), "agui-merge-out-"));
  cleanup.push(() => rmSync(out, { recursive: true, force: true }));
  writeFileSync(join(out, "agent-zz.jsonl"), "");
  symlinkSync(join(out, "agent-zz.jsonl"), join(s.subs, "agent-zz.jsonl"));
  expect((await sessionFiles(s.journal)).paths).toEqual([s.journal]);
});

test(`sessionFiles follows at most ${MAX_SUBAGENTS} subagent files and says when it hit the cap`, async () => {
  const s = session();
  writeFileSync(s.journal, "");
  for (let i = 0; i < MAX_SUBAGENTS; i++) writeFileSync(join(s.subs, `agent-s${String(i).padStart(2, "0")}.jsonl`), "");
  expect(await sessionFiles(s.journal)).toMatchObject({ capped: false });
  writeFileSync(join(s.subs, "agent-zz.jsonl"), "");
  const { paths, capped } = await sessionFiles(s.journal);
  expect(capped).toBe(true);
  expect(paths.length).toBe(MAX_SUBAGENTS + 1);
});
