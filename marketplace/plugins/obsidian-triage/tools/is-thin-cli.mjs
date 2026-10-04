#!/usr/bin/env node
// is-thin-cli.mjs — mechanical thin/rich verdict for a clip file, used by
// the harvest runbook (single source of truth — not LLM eyeballing).
// Prints `thin` or `rich`; exit 0 always. Fail-open: any read/parse error
// → `rich`, so the harvest runbook is never blocked by this shim.
import { readFileSync } from "node:fs";
import { isThinClipBody } from "./lib/clip-lookup.mjs";
const path = process.argv[2];
let verdict = "rich"; // fail-open: never block harvest on a read/parse error
try {
  const text = readFileSync(path, "utf8");
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  let type = "", body = text, source = "";
  if (m) {
    body = text.slice(m[0].length);
    const tm = m[1].match(/^type:\s*(.*)$/m);
    if (tm) type = tm[1].replace(/^["']|["']$/g, "").trim();
    const sm = m[1].match(/^source:\s*(.*)$/m);
    if (sm) source = sm[1].replace(/^["']|["']$/g, "").trim();
  }
  verdict = isThinClipBody(body, type, source) ? "thin" : "rich";
} catch { verdict = "rich"; }
process.stdout.write(verdict + "\n");
process.exit(0);
