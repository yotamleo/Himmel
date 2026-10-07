// Test seam CONFIG_UI_HIMMELCTL: prints a fixed feed for `report --json`.
const leak = process.env.STUB_LEAK ? ` ${process.env.STUB_LEAK}` : "";
const row = (id, health, source) => ({
  id, source, group: "core", bundle: "guards", title: id, health,
  declared: { where: "w", desired: "required", profile: "all" },
  installed: { state: health === "off" ? "absent" : "present", detail: `d-${id}${leak}` },
  fires: { state: "unverified", evidence: null, at: null },
  fix: { remedy: `fix ${id}`, owner: "user" },
  probedAt: "2026-10-04T14:02:00Z", control: { class: "display-only" }, sensitive: false,
});
const rows = [
  row("stub-row-one", "fail", "item"),
  row("stub-row-two", "warn", "doctor"),
  row("stub-row-three", "ok", "item"),
  row("stub-row-off", "off", "item"),
];
// STUB_FEED_COUNT (file): one line appended per invocation, to count coalescing; the feed then
// carries stubRun = this invocation's number, so a test can tell one report's body from another's.
const fs = require("node:fs");
let stubRun;
if (process.env.STUB_FEED_COUNT) {
  fs.appendFileSync(process.env.STUB_FEED_COUNT, "run\n");
  stubRun = fs.readFileSync(process.env.STUB_FEED_COUNT, "utf8").split("\n").filter(Boolean).length;
}
const out = () => process.stdout.write(JSON.stringify({
  schema: "himmel-config-feed/1", generatedAt: "2026-10-04T14:02:00Z", target: { scope: "user", path: "/x" },
  base: "/b", profileCache: true, bundles: [{ id: "guards", title: "Guards" }], rows, summary: { total: 4, ok: 1, warn: 1, fail: 1, off: 1, info: 0 },
  ...(stubRun ? { stubRun } : {}),
}) + "\n");
// STUB_FEED_SLEEP (ms): answer late, like the real report (~2 min on the station).
const wait = Number(process.env.STUB_FEED_SLEEP || 0);
// HIMMEL-4807: STUB_FEED_STEPS (n): n probe-progress lines on stderr, spread over the sleep, as
// probe-progress.cjs writes them; STUB_FEED_JUNK=1 puts malformed ones before each.
const steps = Number(process.env.STUB_FEED_STEPS || 0);
const line = (o) => process.stderr.write(`himmel-probe ${typeof o === "string" ? o : JSON.stringify(o)}\n`);
for (let k = 0; k < steps; k++) {
  setTimeout(() => {
    if (process.env.STUB_FEED_JUNK) {
      line({ i: steps + 1, n: steps, source: "past the end" });
      line({ i: k + 1, n: steps, source: "<b>markup</b>" });
      line("{not json");
      line({ i: 1.5, n: steps, source: "fraction" });
    }
    line({ i: k + 1, n: steps, source: `stub step ${k + 1}` });
  }, Math.floor((wait * k) / steps));
}
if (wait > 0) setTimeout(out, wait); else out();
