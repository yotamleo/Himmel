#!/usr/bin/env node
// secret-launch.mjs — HIMMEL-5002 MCP launcher shim.
//
// build-mcp-profiles.mjs keeps secret env values (API keys, tokens) OUT of the
// repo-tree profile JSON: it writes each one to a 0600 file under
//   ~/.config/himmel/mcp-secrets/<server>/<VAR>
// and points the profile at this shim, which reads those files and starts the
// real MCP server with the secrets in its environment only.
//
// Usage: node secret-launch.mjs <server> <command> [args...]
// Cross-platform: pure node, no shell.

import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawn } from "node:child_process";

export function secretsRoot() {
  return process.env.HIMMEL_MCP_SECRETS_DIR || path.join(os.homedir(), ".config", "himmel", "mcp-secrets");
}

const [server, command, ...args] = process.argv.slice(2);
if (!server || !command || /[\\/]|^\.\.?$/.test(server)) {
  console.error("secret-launch: usage: secret-launch.mjs <server> <command> [args...]");
  process.exit(2);
}

const dir = path.join(secretsRoot(), server);
const env = { ...process.env };
// The generator only wraps a server that has secrets, so a missing dir means
// they were never written: fail rather than start the server without them.
if (!fs.existsSync(dir)) {
  console.error(`secret-launch: ${dir} not found — run build-mcp-profiles.mjs`);
  process.exit(1);
}
for (const name of fs.readdirSync(dir)) {
  const f = path.join(dir, name);
  // Refuse a group/world-readable secret file rather than trust it.
  if (process.platform !== "win32" && (fs.statSync(f).mode & 0o077) !== 0) {
    console.error(`secret-launch: ${f} is not mode 0600 — refusing to read it`);
    process.exit(1);
  }
  env[name] = fs.readFileSync(f, "utf8").replace(/\r?\n$/, "");
}

const child = spawn(command, args, { stdio: "inherit", env });
for (const sig of ["SIGINT", "SIGTERM", "SIGHUP"]) process.on(sig, () => child.kill(sig));
child.on("error", (e) => { console.error(`secret-launch: cannot start ${command}: ${e.code || e.message}`); process.exit(127); });
child.on("exit", (code, sig) => process.exit(code ?? (sig ? 128 : 1)));
