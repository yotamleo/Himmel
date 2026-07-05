// scripts/ci-orchestrator/src/index.ts
// HIMMEL-502 P3.7 — the executable entry. Thin wrapper over runCli (cli.ts owns
// the testable logic; this only binds process IO + the exit code).
import { runCli } from "./cli.js";

const code = await runCli(process.argv.slice(2), {
  out: (s) => process.stdout.write(s + "\n"),
  err: (s) => process.stderr.write(s + "\n"),
  env: process.env,
});
process.exit(code);
