#!/usr/bin/env node
// build-mcp-profiles.mjs — HIMMEL-719 MCP fleet tiered management.
//
// Emits per-lane MINIMAL `--strict-mcp-config` profiles so a session/subagent
// launches with only the servers it needs instead of the full per-session fleet
// (~6 node procs × N sessions). The verified lever: `--strict-mcp-config
// --mcp-config <file>` loads ONLY the servers named in <file>, ignoring
// ~/.claude.json and every enabled plugin's MCP server.
//
// Committed = this generator + profiles.json manifest + README (all path- and
// secret-free). Generated = .claude/mcp-profiles/local.<name>.json, which carry
// the machine's real absolute paths + env (incl. secrets) and are gitignored.
// This is why the profiles are generated, not committed: it keeps the operator's
// OBSIDIAN_API_KEY and C:\Users\... paths out of git while staying runnable.
//
// Usage:  node scripts/mcp/build-mcp-profiles.mjs [--list]
// Cross-platform: pure node, no shell — no .ps1 twin needed.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..", "..");
const outDir = path.join(repoRoot, ".claude", "mcp-profiles");
const manifestPath = path.join(outDir, "profiles.json");
const claudeJson = path.join(os.homedir(), ".claude.json");

// Portable plugin-server specs (npx-based, no absolute path). Kept here rather
// than read from plugin caches so the generated browser/research profiles work
// even after the plugins are disabled (which is the whole point). context7-remote
// is the HTTP endpoint form — zero local procs, N sessions share one singleton.
const PLUGIN_SERVERS = {
  playwright: { type: "stdio", command: "npx", args: ["@playwright/mcp@latest"] },
  "chrome-devtools": { type: "stdio", command: "npx", args: ["chrome-devtools-mcp@latest"] },
  "context7-remote": { type: "http", url: "https://mcp.context7.com/mcp" },
};

function die(msg) {
  console.error(`build-mcp-profiles: ${msg}`);
  process.exit(1);
}

if (!fs.existsSync(manifestPath)) die(`manifest not found: ${manifestPath}`);
const manifest = JSON.parse(fs.readFileSync(manifestPath, "utf8"));

if (process.argv.includes("--list")) {
  for (const [name, keys] of Object.entries(manifest.profiles)) {
    console.log(`${name.padEnd(10)} ${keys.join(", ")}`);
  }
  process.exit(0);
}

if (!fs.existsSync(claudeJson)) die(`~/.claude.json not found — cannot resolve machine server specs`);
const globalServers = (JSON.parse(fs.readFileSync(claudeJson, "utf8")).mcpServers) || {};

fs.mkdirSync(outDir, { recursive: true });

// Fail loudly on any unresolved server: under --strict-mcp-config a silently
// missing server = that capability just gone, so a typo in profiles.json must
// not produce a "successful" but broken profile. We still write every complete
// profile, never an empty one, and exit non-zero if anything was unresolved.
let written = 0;
const problems = [];
for (const [name, keys] of Object.entries(manifest.profiles)) {
  const mcpServers = {};
  for (const key of keys) {
    const spec = globalServers[key] ?? PLUGIN_SERVERS[key];
    if (!spec) { problems.push(`${name}: unresolved server "${key}"`); continue; }
    // context7-remote is written under the plain "context7" name so tools resolve normally.
    mcpServers[key === "context7-remote" ? "context7" : key] = spec;
  }
  if (Object.keys(mcpServers).length === 0) {
    problems.push(`${name}: no servers resolved — profile not written`);
    continue;
  }
  const dest = path.join(outDir, `local.${name}.json`);
  fs.writeFileSync(dest, JSON.stringify({ mcpServers }, null, 2) + "\n");
  console.log(`  wrote ${path.relative(repoRoot, dest)} (${Object.keys(mcpServers).length} server(s))`);
  written++;
}
console.log(`build-mcp-profiles: ${written} profile(s) generated in ${path.relative(repoRoot, outDir)}/`);
console.log(`launch a lean session:  claude --strict-mcp-config --mcp-config .claude/mcp-profiles/local.minimal.json`);
if (problems.length) {
  console.error(`build-mcp-profiles: FAILED — unresolved server(s) (fix profiles.json keys or install the server):`);
  for (const p of problems) console.error(`  - ${p}`);
  process.exit(1);
}
