#!/usr/bin/env node
// clip-lookup-cli.mjs — runbook shim over clip-lookup.mjs.
// Prints one JSON line ({path,status,enriched} | null); exit 0 always
// (advisory — never blocks a runbook). Used by /read-link.
import { findHarvestedClipForUrl } from "./lib/clip-lookup.mjs";
const args = process.argv.slice(2);
const vi = args.indexOf("--vault");
const vaultRaw = vi >= 0 ? args[vi + 1] : undefined;
// Guard: if --vault is the last token or is followed by another flag, treat the
// vault as unset (degrade to default resolution) rather than consuming a flag.
const vault = vaultRaw && !vaultRaw.startsWith("--") ? vaultRaw : undefined;
const url = args.find((a, i) => a !== "--vault" && args[i - 1] !== "--vault" && !a.startsWith("--"));
let hit = null;
try { hit = findHarvestedClipForUrl(vault ? { vault } : null, url); } catch { hit = null; }
process.stdout.write(JSON.stringify(hit) + "\n");
process.exit(0);
