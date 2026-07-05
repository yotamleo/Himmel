import { describe, test, expect } from "vitest";
import { route, type RoutingInputs, type LaneAvailability, type LaneName } from "../src/routing.js";
import { type JobAttrs } from "../src/ledger.js";
import { type ActMatrix } from "../src/act-matrix.js";

const MATRIX: ActMatrix = {
  "ci:lint": { fidelity: "act-faithful", os: ["linux"], heavy: false },
  "ci:security-scan": { fidelity: "needs-shim", os: ["linux"], heavy: true },
  "ci:shell-unit": { fidelity: "act-faithful", os: ["linux", "windows", "macos"], heavy: true },
};

function lanes(over: Partial<LaneAvailability> = {}): LaneAvailability {
  const base: LaneAvailability = {
    "self-hosted-runner": { up: false, inFlight: 0, cap: 4, native: true },
    "private-gha-hosted": { up: true, inFlight: 0, cap: 4, native: true },
    "act-exec": { up: true, inFlight: 0, cap: 4 },
    "public-fork": { up: true, inFlight: 0, cap: 4 },
    "local-exec": { up: true, inFlight: 0, cap: 4 },
  };
  return { ...base, ...over };
}

function job(over: Partial<JobAttrs> = {}): JobAttrs {
  return {
    id: "j", headSha: "h", runSha: "h", workflow: "ci", job: "lint", required: false,
    needsSecrets: false, publicSafe: false, os: "linux", heavy: false, deterministic: false,
    treeHash: "t", enqueuedAt: "t", ...over,
  };
}

const base: Omit<RoutingInputs, "job"> = {
  lanes: lanes(),
  workProfile: "focus",
  loadBelowThreshold: false,
  privateMinutesHeadroom: true,
  actMatrix: MATRIX,
  githubUp: true,
};

describe("route — the decision table", () => {
  test("required light gate, runner up → self-hosted-runner", () => {
    const d = route({ ...base, job: job({ required: true }), lanes: lanes({ "self-hosted-runner": { up: true, inFlight: 0, cap: 4, native: true } }) });
    expect(d.lane).toBe("self-hosted-runner");
  });

  test("required light gate, runner down, github up → private-gha-hosted", () => {
    const d = route({ ...base, job: job({ required: true }) });
    expect(d.lane).toBe("private-gha-hosted");
  });

  test("required light gate, github down → act-exec (backbone)", () => {
    const d = route({ ...base, job: job({ required: true }), githubUp: false });
    expect(d.lane).toBe("act-exec");
  });

  test("linux heavy, act under cap → act-exec", () => {
    const d = route({ ...base, job: job({ job: "security-scan", heavy: true }) });
    expect(d.lane).toBe("act-exec");
  });

  test("linux heavy, act at cap, not public-safe, focus → defer (never local in focus)", () => {
    const d = route({ ...base, job: job({ job: "security-scan", heavy: true }), lanes: lanes({ "act-exec": { up: true, inFlight: 4, cap: 4 } }) });
    expect(d.lane).toBe("defer");
  });

  test("win/mac required needsSecrets, with headroom → private-gha-hosted", () => {
    const d = route({ ...base, job: job({ job: "shell-unit", os: "windows", required: true, needsSecrets: true, heavy: true }) });
    expect(d.lane).toBe("private-gha-hosted");
  });

  test("win/mac required, NO private headroom → defer (never silently skip)", () => {
    const d = route({ ...base, job: job({ job: "shell-unit", os: "windows", required: true, needsSecrets: true, heavy: true }), privateMinutesHeadroom: false });
    expect(d.lane).toBe("defer");
  });

  test("public-safe non-required, github up → public-fork", () => {
    const d = route({ ...base, job: job({ job: "shell-unit", os: "windows", publicSafe: true, heavy: true }) });
    expect(d.lane).toBe("public-fork");
  });

  test("public-safe non-required, github DOWN → defer (fork needs github)", () => {
    const d = route({ ...base, job: job({ job: "shell-unit", os: "windows", publicSafe: true, heavy: true }), githubUp: false });
    expect(d.lane).toBe("defer");
  });

  test("local-exec only when shared/drain AND load below threshold", () => {
    const j = job({ job: "shell-unit", os: "windows", heavy: true }); // not act-eligible, not public-safe
    expect(route({ ...base, job: j, workProfile: "drain", loadBelowThreshold: true }).lane).toBe("local-exec");
    expect(route({ ...base, job: j, workProfile: "drain", loadBelowThreshold: false }).lane).toBe("defer");
    expect(route({ ...base, job: j, workProfile: "focus", loadBelowThreshold: true }).lane).toBe("defer");
  });

  test("route never returns a 'skip' — only a lane or defer", () => {
    const legal: (LaneName | "defer")[] = ["self-hosted-runner", "private-gha-hosted", "act-exec", "public-fork", "local-exec", "defer"];
    const d = route({ ...base, job: job({ deterministic: false }) });
    expect(legal).toContain(d.lane);
  });
});
