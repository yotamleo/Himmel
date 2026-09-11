// scripts/ci-orchestrator/src/ci-coverage.ts
// HIMMEL-2880 — structural coverage gate: every job id in ci.yml must be
// modeled in act-matrix.json's `jobs` or listed in its `intentionallyAbsent`,
// or a rename/add in ci.yml drifts the orchestrator's topology model with no
// signal (exactly what happened to `shell-unit` under HIMMEL-2872).
import { readFileSync } from "node:fs";

// Extract top-level job ids from a GitHub Actions workflow's `jobs:` block.
// Deliberately not a full YAML parser (none is a repo dependency yet — see
// package.json): job ids are exactly-2-space-indented keys under the
// top-level `jobs:` line, which is how every job in this repo's ci.yml is
// authored. A line at column 0 after `jobs:` ends the block (next top-level
// key) — blank lines and column-0 comments are valid YAML inside the block
// and don't end it, so this only breaks if ci.yml stops being flow-style-free
// at depth 1.
export function extractJobIds(yaml: string): string[] {
  const lines = yaml.split("\n");
  const jobsLine = lines.findIndex((l) => /^jobs:\s*$/.test(l));
  if (jobsLine === -1) throw new Error("no top-level 'jobs:' key found");
  const ids: string[] = [];
  for (const line of lines.slice(jobsLine + 1)) {
    if (/^\s*$/.test(line) || /^\s*#/.test(line)) continue;
    if (/^\S/.test(line)) break;
    const m = line.match(/^ {2}([A-Za-z0-9_-]+):/);
    if (m) ids.push(m[1]);
  }
  return ids;
}

export function loadWorkflowJobIds(path: string): string[] {
  return extractJobIds(readFileSync(path, "utf8"));
}

// missing is empty iff act-matrix.json's model is current with ci.yml.
export function checkCoverage(jobKeys: string[], modeled: Set<string>, intentionallyAbsent: Set<string>): { missing: string[] } {
  return { missing: jobKeys.filter((k) => !modeled.has(k) && !intentionallyAbsent.has(k)) };
}
