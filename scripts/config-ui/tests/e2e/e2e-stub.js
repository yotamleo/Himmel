// Test seam CONFIG_UI_HIMMELCTL for the e2e suite: `report --json` prints the
// feed file named by $E2E_FEED; any other verb is recorded (argv) in $STUB_ARGV and succeeds.
const fs = require("node:fs");
const args = process.argv.slice(2);
if (args[0] === "report") {
  // E2E_FEED_DELAY_MS holds the report so a test sees the pending feed.
  setTimeout(() => process.stdout.write(fs.readFileSync(process.env.E2E_FEED, "utf8")), Number(process.env.E2E_FEED_DELAY_MS) || 0);
} else {
  fs.appendFileSync(process.env.STUB_ARGV, `himmelctl ${args.join(" ")}\n`);
  process.stdout.write(`did ${args.join(" ")}\n`);
}
