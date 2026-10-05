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
const out = () => process.stdout.write(JSON.stringify({
  schema: "himmel-config-feed/1", generatedAt: "2026-10-04T14:02:00Z", target: { scope: "user", path: "/x" },
  base: "/b", profileCache: true, bundles: [{ id: "guards", title: "Guards" }], rows, summary: { total: 4, ok: 1, warn: 1, fail: 1, off: 1, info: 0 },
}) + "\n");
// STUB_FEED_SLEEP (ms): answer late, like the real report (~2 min on the station).
// STUB_FEED_COUNT (file): one line appended per invocation, to count coalescing.
if (process.env.STUB_FEED_COUNT) require("node:fs").appendFileSync(process.env.STUB_FEED_COUNT, "run\n");
const wait = Number(process.env.STUB_FEED_SLEEP || 0);
if (wait > 0) setTimeout(out, wait); else out();
