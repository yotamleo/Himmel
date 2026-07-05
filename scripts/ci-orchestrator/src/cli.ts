// scripts/ci-orchestrator/src/cli.ts
// HIMMEL-502 P3.7 — the CLI command surface (state | tick | daemon | measure).
//
// runCli is pure over an injected IO object (out/err/env) so it is hermetically
// testable — `state` on an empty ledger prints `{}`. `tick` and `daemon` require
// the production lane + git-discovery wiring (assembled from the operator's
// environment); until that wiring is configured they report the boundary rather
// than firing fake work. `measure` belongs to P0 (the baseline-measurement shell
// harness) and is not built yet — it reports the same boundary, not a stub path.
import { readState, type JobState } from "./ledger.js";

export type CliIo = {
  out: (s: string) => void;
  err: (s: string) => void;
  env: Record<string, string | undefined>;
  ledgerPath?: string; // test override
};

const USAGE = "usage: ci-orchestrator <state|tick|daemon|measure>";

export async function runCli(argv: string[], io: CliIo): Promise<number> {
  const cmd = argv[0];
  switch (cmd) {
    case "state": {
      const state = readState(io.env, io.ledgerPath);
      const obj: Record<string, JobState> = {};
      for (const [id, js] of state) obj[id] = js;
      io.out(JSON.stringify(obj));
      return 0;
    }
    case "tick":
    case "daemon":
      io.err(
        `ci-orchestrator ${cmd}: requires production lane + discovery wiring ` +
          `(HIMMEL_CI_* env + registered adapters). See docs/internals/ci-orchestrator.md. ` +
          `Not configured in this environment.`,
      );
      return 2;
    case "measure":
      io.err(
        "ci-orchestrator measure: the baseline measurement is a P0 deliverable " +
          "(baseline shell harness) and is not built yet. See docs/internals/ci-orchestrator.md.",
      );
      return 2;
    default:
      io.err(cmd ? `ci-orchestrator: unknown command '${cmd}'\n${USAGE}` : USAGE);
      return 1;
  }
}
