import { join } from "node:path";
import { readGlmWorkers } from "./glm";
import { readCodexJobs } from "./codex";
import { readHermes, type HermesCoverage } from "./hermes";
import { readArmedSlots } from "./armed";
import { readFeeds, type Feeds } from "./ledger";
import type { Worker } from "./types";

// HIMMEL-760 seam: the deterministic zero-token scheduler will be the first
// non-human consumer of this API as a fleet-control CLIENT/principal - never a
// second dispatch authority. Phase-1 read surfaces (GET /fleet) are designed
// with a programmatic consumer in mind (stable JSON contract, no HTML-only state).
export type FleetRoots = { bridgeRoot: string; stateRoot: string; pluginDataRoot: string };
type Lane = "glm" | "codex" | "hermes" | "armed";
export type FleetDoc = { lanes: Record<Lane, Worker[]>; feeds: Feeds; coverage: HermesCoverage; generatedAt: string };

function errMessage(e: unknown): string {
  return e instanceof Error ? e.message : String(e);
}

// Per-lane error isolation: a throwing reader must NOT 500 the whole document.
// It degrades to a single synthetic "failed" worker carrying the error while the
// other lanes render normally (truthful state: degrade visibly, never drop silently).
function safeLane(lane: Lane, read: () => Worker[]): Worker[] {
  try {
    return read();
  } catch (e) {
    return [{ lane, name: "<reader error>", status: "failed", artifacts: [], error: errMessage(e) }];
  }
}

export function buildFleet(roots: FleetRoots): FleetDoc {
  let hermesWorkers: Worker[];
  let coverage: HermesCoverage;
  try {
    const hermes = readHermes(roots.stateRoot);
    hermesWorkers = hermes.workers;
    coverage = hermes.coverage;
  } catch (e) {
    hermesWorkers = [{ lane: "hermes", name: "<reader error>", status: "failed", artifacts: [], error: errMessage(e) }];
    coverage = { hermesNativeChildren: "blind", note: `coverage unavailable: ${errMessage(e)}` };
  }

  let feeds: Feeds;
  try {
    feeds = readFeeds({
      ledgerPath: join(roots.stateRoot, "where-are-we.jsonl"),
      quotaPath: join(roots.stateRoot, "quota-gauge.jsonl"),
      posturePath: join(roots.stateRoot, "posture-734.jsonl"),
    });
  } catch (e) {
    feeds = { ledger: [], quota: [], posture: null, parseErrors: 0, error: errMessage(e) };
  }

  return {
    lanes: {
      glm: safeLane("glm", () => readGlmWorkers(roots.bridgeRoot)),
      codex: safeLane("codex", () => readCodexJobs(roots.pluginDataRoot)),
      hermes: hermesWorkers,
      armed: safeLane("armed", () => readArmedSlots()),
    },
    feeds,
    coverage,
    generatedAt: new Date().toISOString(),
  };
}
