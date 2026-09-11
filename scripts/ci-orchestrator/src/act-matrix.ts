// scripts/ci-orchestrator/src/act-matrix.ts
// HIMMEL-502 P1.1 (partial — the type + data surface P2 depends on).
//
// The `act` compatibility matrix classifies every job in .github/workflows/ci.yml
// by whether nektos/act can run it faithfully in Docker, its OS set, and whether
// it's a heavy leg. Consumed by routing.ts (act-exec eligibility) and dedup.ts.
//
// SCOPE (this P2 slice): the TYPES, the committed `act-matrix.json` (authored
// from static analysis of ci.yml), and `loadMatrix()` (reads the committed JSON,
// zero-dep). The empirical fidelity classification (run each job under `act` on
// the VM — plan P1.1 Step 4) and the YAML `jobsInWorkflows()` discovery helper
// are the P1 infra chunk (they need the live VM / a YAML parser) and are NOT in
// this slice. The `fidelity` values below are STATIC best-effort, pending that
// live verification — loadMatrix + the shape test validate structure, not the
// fidelity verdict.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";

export type ActFidelity = "act-faithful" | "needs-shim" | "gha-only";
export type OsName = "linux" | "windows" | "macos";

// Keyed by "workflow:job" (workflow = the ci.yml file basename `ci`). `os` is an
// ARRAY because one job (shell-unit-shard) fans to linux+windows+macos via
// `runs-on: ${{ matrix.os }}` — the superset it can produce (B4). Routing then
// decides each OS leg independently (act-exec is eligible only for the linux leg
// AND when fidelity !== "gha-only").
export type ActMatrixEntry = { fidelity: ActFidelity; os: OsName[]; heavy: boolean; shim?: string };
export type ActMatrix = Record<string, ActMatrixEntry>;

// act-matrix.json's on-disk shape: `jobs` is the classification ActMatrix
// consumed by routing.ts/dedup.ts; `intentionallyAbsent` (HIMMEL-2880) names
// every ci.yml job deliberately left out of `jobs`, one-line reason each — the
// coverage gate (ci-coverage.ts) treats a ci.yml job as covered iff it is a key
// in one of the two.
export type ActMatrixFile = { jobs: ActMatrix; intentionallyAbsent: Record<string, string> };

// Resolve the committed act-matrix.json (package root, one dir up from src/).
function matrixPath(): string {
  const here = dirname(fileURLToPath(import.meta.url));
  return join(here, "..", "act-matrix.json");
}

function loadFile(path: string): ActMatrixFile {
  const raw = readFileSync(path, "utf8");
  return JSON.parse(raw) as ActMatrixFile;
}

// Load the committed matrix. Pure read; throws if the file is missing/malformed
// (a corrupt matrix must fail loud, not route silently on an empty table).
export function loadMatrix(path: string = matrixPath()): ActMatrix {
  return loadFile(path).jobs;
}

export function loadIntentionallyAbsent(path: string = matrixPath()): Record<string, string> {
  return loadFile(path).intentionallyAbsent;
}

// The doc-safe "light gate" job names and the heavy code-matrix job names are
// re-exported from dedup.ts (single source of truth there); act-matrix.json is
// the classification, dedup.ts owns the routing-reduction sets.
