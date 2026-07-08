import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readCodexJobs } from "../aggregator/codex";

function root() { return mkdtempSync(join(tmpdir(), "fleet-codex-")); }

test("readCodexJobs reads companion state and marks dead recorded pids", () => {
  const pluginData = root();
  const stateDir = join(pluginData, "state", "himmel-abc123");
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, "state.json"), JSON.stringify({ jobs: [
    { id: "live", title: "Live job", status: "running", pid: process.pid, workspaceRoot: "/repo", updatedAt: new Date().toISOString() },
    { id: "dead", title: "Dead job", status: "running", pid: 999999, workspaceRoot: "/repo", updatedAt: new Date().toISOString() },
  ] }));

  const jobs = readCodexJobs(pluginData);
  expect(jobs.find((j) => j.name === "live")?.status).toBe("running");
  expect(jobs.find((j) => j.name === "dead")?.status).toBe("dead");
  expect(jobs.find((j) => j.name === "dead")?.artifacts).toContain(join(stateDir, "state.json"));
});

test("queued job with a live pid renders 'queued'; unknown status fails closed (finding 10)", () => {
  const pluginData = root();
  const stateDir = join(pluginData, "state", "himmel-status");
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, "state.json"), JSON.stringify({ jobs: [
    { id: "q", status: "queued", pid: process.pid, workspaceRoot: "/repo" },
    { id: "weird", status: "banana", pid: process.pid, workspaceRoot: "/repo" },
  ] }));

  const jobs = readCodexJobs(pluginData);
  expect(jobs.find((j) => j.name === "q")?.status).toBe("queued");
  expect(jobs.find((j) => j.name === "weird")?.status).toBe("failed");
});

test("active jobs with pid=null keep their mapped status (foreground/queued shape, not dead)", () => {
  const pluginData = root();
  const stateDir = join(pluginData, "state", "himmel-nullpid");
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, "state.json"), JSON.stringify({ jobs: [
    { id: "fg", title: "Foreground job", status: "running", pid: null, workspaceRoot: "/repo" },
    { id: "q0", title: "Not yet spawned", status: "queued", workspaceRoot: "/repo" },
  ] }));

  const jobs = readCodexJobs(pluginData);
  expect(jobs.find((j) => j.name === "fg")?.status).toBe("running");
  expect(jobs.find((j) => j.name === "q0")?.status).toBe("queued");
});

test("unparseable state.json renders one degraded row; missing file yields nothing (finding 5)", () => {
  const pluginData = root();
  const corrupt = join(pluginData, "state", "himmel-corrupt");
  mkdirSync(corrupt, { recursive: true });
  writeFileSync(join(corrupt, "state.json"), "{not json");
  const empty = join(pluginData, "state", "himmel-empty");
  mkdirSync(empty, { recursive: true }); // no state.json at all

  const jobs = readCodexJobs(pluginData);
  expect(jobs).toHaveLength(1);
  expect(jobs[0]).toMatchObject({ lane: "codex", name: "<corrupt state>", status: "failed" });
  expect(jobs[0].artifacts).toContain(join(corrupt, "state.json"));
});

test("state.jobs present but not an array renders a degraded row (finding 5)", () => {
  const pluginData = root();
  const stateDir = join(pluginData, "state", "himmel-badjobs");
  mkdirSync(stateDir, { recursive: true });
  writeFileSync(join(stateDir, "state.json"), JSON.stringify({ jobs: { not: "an array" } }));

  const jobs = readCodexJobs(pluginData);
  expect(jobs).toHaveLength(1);
  expect(jobs[0]).toMatchObject({ lane: "codex", name: "<corrupt state>", status: "failed" });
});
