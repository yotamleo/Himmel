// One of several separate processes racing for one lock (lock.test.ts).
// argv: <lock path> <start-at epoch ms>. Prints "won" or "lost"; a winner
// holds the lock until it exits, so a late taker cannot win a released lock.
import { acquireLock } from "../lock";

const [path, startAt] = process.argv.slice(2);
while (Date.now() < Number(startAt)) { /* spin to a common start */ }
const l = acquireLock(path) as unknown;
const won = !!l && !(typeof l === "object" && "busy" in (l as object));
console.log(won ? "won" : "lost");
if (won) await Bun.sleep(1500);
