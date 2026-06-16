import { expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { record, readBreadcrumbs, parseTranscriptTail, resolve } from "./armed-session-track";

function ctx() { const dir = mkdtempSync(join(tmpdir(), "ast-")); return { dir, file: join(dir, "armed-sessions.jsonl") }; }

const JSONL = [
  `{"type":"last-prompt","leafUuid":"x"}`,
  `{"type":"user","timestamp":"2026-05-30T00:57:02Z","cwd":"C:/repo","message":{"role":"user","content":"load /h/x.md overnight mode"}}`,
  `{"type":"assistant","timestamp":"2026-05-30T01:05:00Z","message":{"role":"assistant","content":[{"type":"text","text":"step done →"}]}}`,
  `{"type":"assistant","timestamp":"2026-05-30T01:06:00Z","message":{"role":"assistant","content":[{"type":"tool_use","name":"AskUserQuestion","input":{"questions":[{"question":"A or B?","header":"Pick"}]}}]}}`,
  `{"type":"user","timestamp":"2026-05-30T01:07:00Z","message":{"role":"user","content":[{"type":"tool_result","content":"Your questions have been answered: \\"A or B?\\"=\\"A\\"."}]}}`,
].join("\n");

test("record appends a breadcrumb", async () => {
  const { file } = ctx();
  await record({ file, task:"t", ticket:"HIMMEL-216", handover:"/h/x.md", cwd:"C:/repo", armed_at:"2026-05-30T00:57:00Z", mode:"ticket" });
  const rows = await readBreadcrumbs(file);
  expect(rows.length).toBe(1); expect(rows[0].ticket).toBe("HIMMEL-216");
});

test("parseTranscriptTail extracts start, first-load, last text, Q+answers (utf8 → survives)", async () => {
  const { dir } = ctx(); const f = join(dir, "s.jsonl"); writeFileSync(f, JSONL, "utf8");
  const r = await parseTranscriptTail(f);
  expect(r.session_start).toBe("2026-05-30T00:57:02Z");
  expect(r.first_user?.startsWith("load /h/x.md")).toBe(true);
  expect(r.last_assistant_text).toContain("step done");
  expect(r.last_question).toBe("A or B?");
  expect(r.last_answers).toContain(`"A"`);
});

test("resolve A-path: breadcrumb cwd → slug → newest transcript", async () => {
  const { dir, file } = ctx();
  const proj = join(dir, "projects", "C--repo"); await mkdir(proj, { recursive: true });
  writeFileSync(join(proj, "s.jsonl"), JSONL, "utf8");
  await record({ file, task:"z", ticket:"HIMMEL-216", handover:"/h/x.md", cwd:"C:/repo", armed_at:"2026-05-30T00:57:00Z", mode:"ticket" });
  const r = await resolve({ file, projectsDir: join(dir, "projects") });
  expect(r.found).toBe(true); expect(r.source).toBe("breadcrumb"); expect(r.last_question).toBe("A or B?");
});

test("resolve degrades to not-found on empty projects dir", async () => {
  const { dir, file } = ctx();
  await record({ file, task:"z", ticket:"HIMMEL-1", handover:"", cwd:"C:/nope", armed_at:"2026-05-30T00:57:00Z", mode:"ticket" });
  const r = await resolve({ file, projectsDir: join(dir, "empty") });
  expect(r.found).toBe(false);
});
