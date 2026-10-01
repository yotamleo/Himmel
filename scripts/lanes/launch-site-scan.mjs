#!/usr/bin/env node
// HIMMEL-4013: scan scripts/ for every place that execs (or emits a command line
// that execs) `claude`, and report the ones that apply no plugin profile.
// A site is covered when, within WINDOW lines around it, there is a profile-
// derived `--settings` (the literal flag, LEG_PROFILE_SETTINGS, or the
// profile-settings.sh helper) or a `launch-profile-ok: <reason>` marker. A
// file-level `launch-profile-ok-file: <reason>` covers every site in the file.
// Usage: node launch-site-scan.mjs [repo-root]   -> prints "path:line: text" per UNCOVERED site.
import { readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";

const root = process.argv[2] || process.cwd();
const SITE = new RegExp(
  String.raw`(?<![\w./-])(claude|"?\$\{?[A-Za-z_]*(CLAUDE|LAUNCHER)[A-Za-z_]*\}?"?)\s+(-p\b|--print|--bg|--settings|--model|--dangerously|--permission|--append|-n\b|--name)` +
    String.raw`|spawn(Sync)?\(\s*["']claude["']` +
    // emitted command lines: a resume prompt / cron entry built around a bare claude
    String.raw`|(?<![\w./-])claude\s+("\$|\$\{?q_)|\}claude\s`,
);
const COVER = /--settings|LEG_PROFILE_SETTINGS|profile-settings\.sh|launch-profile-ok:/;
const FILE_OK = /launch-profile-ok-file:/;
const SKIP_DIR = new Set(["node_modules", "dist", "fixtures", ".git"]);
const EXT = /\.(sh|ts|mjs|js|ps1)$/;

function* walk(dir) {
  for (const n of readdirSync(dir)) {
    if (SKIP_DIR.has(n)) continue;
    const p = join(dir, n);
    const st = statSync(p);
    if (st.isDirectory()) yield* walk(p);
    else if (EXT.test(n) && !/^test-|\.test\.|^check-no-headless-claude/.test(n)) yield p;
  }
}

for (const f of walk(join(root, "scripts"))) {
  const lines = readFileSync(f, "utf8").split("\n");
  if (lines.some((l) => FILE_OK.test(l))) continue;
  lines.forEach((l, i) => {
    const t = l.trim();
    if (t.startsWith("#") || t.startsWith("//")) return;
    if (!SITE.test(l)) return;
    if (/`claude|claude --model (for|pin)|quota_gauge_row claude/.test(l)) return; // prose / usage text / gauge row, not a launch
    const win = lines.slice(Math.max(0, i - 12), i + 4).join("\n");
    if (COVER.test(win)) return;
    console.log(`${relative(root, f)}:${i + 1}: ${t.slice(0, 120)}`);
  });
}
