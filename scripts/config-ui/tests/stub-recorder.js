// Test seam CONFIG_UI_HIMMELCTL for the action tests: appends its argv to
// $STUB_ARGV, and answers `report --json --items <ids>` from $STUB_STATE (a
// cadence row is ok/present when the cadence stub left a marker file there).
const { appendFileSync, existsSync, readFileSync } = require("node:fs");
const { join } = require("node:path");
const { chmodSync } = require("node:fs");
const args = process.argv.slice(2);
// STUB_RO_DIR: make that directory read-only, so the lock's setGroup write fails after the spawn.
if (process.env.STUB_RO_DIR) chmodSync(process.env.STUB_RO_DIR, 0o555);
appendFileSync(process.env.STUB_ARGV, `himmelctl ${args.join(" ")}\n`);
const leak = process.env.STUB_LEAK ? ` ${process.env.STUB_LEAK}` : "";
if (args[0] !== "report") {
  process.stdout.write(`did ${args.join(" ")}${leak}\n`);
  process.exit(0);
}
// HIMMEL-4807: a full report (no --items) carries seq = its line number in $STUB_ARGV, so a test can tell
// a report started before an action from one started after; $STUB_STATE/feed-sleep (ms) holds it back.
const full = !args.includes("--items");
const seq = full ? readFileSync(process.env.STUB_ARGV, "utf8").split("\n").filter(Boolean).length : undefined;
const fullSleep = full && existsSync(join(process.env.STUB_STATE, "feed-sleep")) ? Number(readFileSync(join(process.env.STUB_STATE, "feed-sleep"), "utf8")) : 0;
const ids = (args[args.indexOf("--items") + 1] || "").split(",").filter(Boolean);
// STUB_REPORT_DROP: answer with no rows at all.
const rows = process.env.STUB_REPORT_DROP ? [] : ids.map((id) => {
  const on = existsSync(join(process.env.STUB_STATE, id));
  return {
    id, source: "cadence", group: "cadence", title: id, health: on ? "ok" : "off",
    declared: { where: "w", desired: "opt-in", profile: "all" },
    installed: { state: on ? "present" : "absent", detail: `d${leak}` },
    fires: { state: "unverified", evidence: null, at: null }, fix: { remedy: "", owner: "user" },
    probedAt: "2026-10-04T14:02:00Z", control: { class: "display-only" }, sensitive: false,
  };
});
// STUB_REPORT_RC: valid JSON on stdout, but a failing exit code.
const out = () => { process.stdout.write(JSON.stringify({ schema: "himmel-config-feed/1", rows, ...(full ? { seq } : {}) }) + "\n"); process.exitCode = Number(process.env.STUB_REPORT_RC || 0); };
const wait = fullSleep || Number(process.env.STUB_REPROBE_SLEEP || 0);
if (wait > 0) setTimeout(out, wait); else out();
