import { describe, test, expect } from "vitest";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import { extractJobIds, checkCoverage, loadWorkflowJobIds } from "../src/ci-coverage.js";
import { loadMatrix, loadIntentionallyAbsent } from "../src/act-matrix.js";

const here = dirname(fileURLToPath(import.meta.url));
const CI_YML = join(here, "..", "..", "..", ".github", "workflows", "ci.yml");
const FIXTURE_WITH_EXTRA_JOB = join(here, "fixtures", "ci-coverage", "ci-with-extra-job.yml");

describe("extractJobIds", () => {
  test("parses top-level job ids under the jobs: key only", () => {
    const yaml = "name: X\non:\n  push:\njobs:\n  a:\n    runs-on: ubuntu-latest\n  b:\n    runs-on: ubuntu-latest\n";
    expect(extractJobIds(yaml)).toEqual(["a", "b"]);
  });
});

describe("ci-coverage gate", () => {
  test("every job in the real ci.yml is modeled in act-matrix.json or intentionally-absent", () => {
    const jobKeys = loadWorkflowJobIds(CI_YML).map((id) => `ci:${id}`);
    const modeled = new Set(Object.keys(loadMatrix()));
    const absent = new Set(Object.keys(loadIntentionallyAbsent()));
    const { missing } = checkCoverage(jobKeys, modeled, absent);
    expect(missing, `unmodeled ci.yml jobs: ${missing.join(", ")}`).toEqual([]);
  });

  // RED control (HIMMEL-2880): a coverage gate that can never fail is the
  // vacuous-pass class — this proves it fails when ci.yml carries a job the
  // real act-matrix.json neither models nor lists as intentionally-absent.
  test("RED control: a ci.yml job absent from both lists fails the gate", () => {
    const jobKeys = loadWorkflowJobIds(FIXTURE_WITH_EXTRA_JOB).map((id) => `ci:${id}`);
    const modeled = new Set(Object.keys(loadMatrix()));
    const absent = new Set(Object.keys(loadIntentionallyAbsent()));
    const { missing } = checkCoverage(jobKeys, modeled, absent);
    expect(missing).toEqual(["ci:totally-new-job"]);
  });
});
