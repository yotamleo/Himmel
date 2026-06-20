import { expect, test } from "bun:test";
import { buildRunArgs, detectCap, detectContentFilter, buildPrompt, killTree } from "./run";
import { spawn } from "bun";

test("killTree takes down a live child process (HIMMEL-246 orphan guard)", async () => {
  // a child that would sleep ~100s; killTree must end it promptly
  const p = spawn(["bun", "-e", "await Bun.sleep(100000)"], { stdin: "ignore", stdout: "ignore", stderr: "ignore" });
  killTree(p.pid, (s) => p.kill(s as any));
  const code = await p.exited;          // resolves only if the kill landed
  expect(code).not.toBe(0);             // killed, not clean exit
});
test("buildPrompt names the session + the bus paths + reply contract", () => {
  const p = buildPrompt("HIMMEL-5", { inbox:"/b/in.jsonl", outbox:"/b/out.jsonl", context:"/b/ctx.md", cwd:"/repo" });
  expect(p).toContain("HIMMEL-5");
  expect(p).toContain("/b/in.jsonl");
  expect(p).toContain("/b/out.jsonl");
  expect(p).toContain("/b/ctx.md");
  expect(p).toContain("/repo");
  expect(p.toLowerCase()).toContain("do not poll");   // must not self-poll telegram
});
test("buildPrompt for __chat__ asks to answer (not do ticket work)", () => {
  const p = buildPrompt("__chat__", { inbox:"i", outbox:"o", context:"c", cwd:"/r" });
  expect(p.toLowerCase()).toContain("answer");
});
test("run args: interactive claude, prompt, stdin closed, no -p/--channels", () => {
  const a = buildRunArgs("do the thing");
  expect(a.cmd[0]).toBe("claude");
  expect(a.cmd).toContain("do the thing");
  expect(a.cmd).not.toContain("-p"); expect(a.cmd).not.toContain("--print");
  expect(a.cmd).not.toContain("--channels");
  expect(a.stdin).toBe("ignore");
});
test("detectCap flags a rate-limit sentinel in output", () => {
  expect(detectCap("…\nClaude usage limit reached\n")).toBe(true);
  expect(detectCap("all good")).toBe(false);
  // disjoint from a content-filter block — this is what makes runSession emit
  // capped:false, blocked:true for a block (the root-cause distinction).
  expect(detectCap("API Error: Output blocked by content filtering policy")).toBe(false);
});
test("detectContentFilter flags an output-blocked sentinel; not confused with a cap", () => {
  expect(detectContentFilter("API Error: Output blocked by content filtering policy")).toBe(true);
  expect(detectContentFilter("…blocked by the content filter…")).toBe(true);
  expect(detectContentFilter("Claude usage limit reached")).toBe(false);   // a cap is NOT a block
  expect(detectContentFilter("all good")).toBe(false);
});
// live smoke — only runs with LIVE=1 (pins the empirical primitive); skipped in CI
test.skipIf(!process.env.LIVE)("live: claude </dev/null exits cleanly", async () => {
  const { runSession } = await import("./run");
  const r = await runSession("Reply with exactly PONG and nothing else.", process.cwd());
  expect(r.code).toBe(0);
});
test("buildPrompt tells the run to Read an image_path when a line carries one (HIMMEL-250)", () => {
  const p = buildPrompt("__chat__", { inbox:"i", outbox:"o", context:"c", cwd:"/r" });
  expect(p).toContain("image_path");
  expect(p).toContain("Read");
});
test("buildPrompt tells the run to Read a document_path attachment (HIMMEL-321)", () => {
  const p = buildPrompt("group_-50", { inbox:"i", outbox:"o", context:"c", cwd:"/r" });
  expect(p).toContain("document_path");
  expect(p).toContain("Read");
});
test("buildPrompt with a vault adds a file-into-vault clause (HIMMEL-321)", () => {
  const p = buildPrompt("group_-50", { inbox:"i", outbox:"o", context:"c", cwd:"/r" }, "/luna-medic");
  expect(p).toContain("/luna-medic");
  expect(p).toContain("document_path");
  expect(p).toContain("_CLAUDE.md");
});
test("buildPrompt without a vault adds no file-into-vault clause (HIMMEL-321)", () => {
  const p = buildPrompt("group_-50", { inbox:"i", outbox:"o", context:"c", cwd:"/r" });
  expect(p).not.toContain("into the Obsidian vault");   // matches the real clause text
});
test("buildPrompt sanctions non-destructive Jira ticket ops (HIMMEL-424 followup — lifts the classifier veto)", () => {
  const p = buildPrompt("__chat__", { inbox:"i", outbox:"o", context:"c", cwd:"/repo" });
  // the absolute jira CLI path, derived from cwd (avoids the worktree dist/ trap)
  expect(p).toContain("/repo/scripts/jira/dist/index.js");
  // Jira ticket work is stated as IN-SCOPE so the auto-mode classifier doesn't veto it
  expect(p).toContain("Jira");
  expect(p.toLowerCase()).toMatch(/create|edit|comment|transition/);
  // explicit non-destructive boundary: assert the FORBIDDANCE phrasing, not just the
  // keyword (a prompt that said "you may delete" would otherwise pass — CR gptoss-1)
  expect(p).toMatch(/NOT delete/i);                       // no deletion
  expect(p).toMatch(/do NOT use [`']?move/i);             // no move (closes the source ticket)
  expect(p).toContain("project-create");                  // admin op named in the exclusion
});
