import { test, expect } from "bun:test";
import { mkdtempSync, mkdirSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readHermes } from "../aggregator/hermes";

test("readHermes lists pane-dispatched one-shot logs and states native-child blind spot", () => {
  const stateRoot = mkdtempSync(join(tmpdir(), "fleet-hermes-"));
  const logs = join(stateRoot, "logs");
  mkdirSync(logs, { recursive: true });
  writeFileSync(join(logs, "hermes-foo.log"), "hello\n");

  const got = readHermes(stateRoot);
  expect(got.workers).toHaveLength(1);
  expect(got.workers[0]).toMatchObject({ lane: "hermes", name: "foo", status: "unknown" });
  expect(got.workers[0].artifacts).toContain(join(logs, "hermes-foo.log"));
  expect(got.coverage.hermesNativeChildren).toBe("blind");
  expect(got.coverage.note.length).toBeGreaterThan(0);
});
