import { test } from "node:test";
import assert from "node:assert/strict";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";
import { mkdtemp, rm, mkdir } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { readFileSync } from "node:fs";
import { estimateSessionCost, getNativeCostUsd } from "../dist/cost.js";
import { renderCostEstimate } from "../dist/render/lines/cost.js";
import { renderIdentityLine } from "../dist/render/lines/identity.js";

function stripAnsi(text) {
  return text
    .replace(/\x1b\[[0-9;]*m/g, "")
    .replace(/\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)/g, "");
}

function skipIfSpawnBlocked(result, t) {
  if (result.error?.code === "EPERM") {
    t.skip("spawnSync is blocked by sandbox policy in this environment");
    return true;
  }
  return false;
}

function withEnv(overrides, fn) {
  const originals = {};
  for (const key of Object.keys(overrides)) {
    originals[key] = process.env[key];
    process.env[key] = overrides[key];
  }
  try {
    return fn();
  } finally {
    for (const key of Object.keys(overrides)) {
      if (originals[key] === undefined) {
        delete process.env[key];
      } else {
        process.env[key] = originals[key];
      }
    }
  }
}

function basicStdin(fixturePath, projectDir) {
  return JSON.stringify({
    model: { display_name: "Opus" },
    context_window: {
      context_window_size: 200000,
      current_usage: { input_tokens: 45000 },
    },
    transcript_path: fixturePath,
    cwd: projectDir,
  });
}

// (a) model line reads CODEX_MODEL under the lane, not the stdin display_name
test("claudex lane: statusline model line reads CODEX_MODEL, not the stdin display_name", async (t) => {
  const fixturePath = fileURLToPath(
    new URL("./fixtures/transcript-render.jsonl", import.meta.url),
  );
  const homeDir = await mkdtemp(path.join(tmpdir(), "claude-hud-home-"));
  const projectDir = path.join(homeDir, "dev", "apps", "my-project");
  await mkdir(projectDir, { recursive: true });
  try {
    const result = spawnSync("node", ["dist/index.js"], {
      cwd: path.resolve(process.cwd()),
      input: basicStdin(fixturePath, projectDir),
      encoding: "utf8",
      env: {
        ...process.env,
        HOME: homeDir,
        LANG: "C",
        CLAUDEX_LANE_OK: "1",
        CODEX_MODEL: "gpt-6-astra",
      },
    });

    if (skipIfSpawnBlocked(result, t)) return;

    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr || "non-zero exit");
    const firstLine = stripAnsi(result.stdout).split("\n")[0];
    assert.match(firstLine, /\[gpt-6-astra\]/);
    assert.ok(!firstLine.includes("Opus"), `expected no "Opus" in: ${firstLine}`);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
  }
});

// (e) control: without the lane env, the same fixture renders exactly as today
test("claudex lane control: without the env, the same fixture renders exactly as today", async (t) => {
  const fixturePath = fileURLToPath(
    new URL("./fixtures/transcript-render.jsonl", import.meta.url),
  );
  const expectedPath = fileURLToPath(
    new URL("./fixtures/expected/render-basic.txt", import.meta.url),
  );
  const expected = readFileSync(expectedPath, "utf8").trimEnd();
  const homeDir = await mkdtemp(path.join(tmpdir(), "claude-hud-home-"));
  const projectDir = path.join(homeDir, "dev", "apps", "my-project");
  await mkdir(projectDir, { recursive: true });
  try {
    const result = spawnSync("node", ["dist/index.js"], {
      cwd: path.resolve(process.cwd()),
      input: basicStdin(fixturePath, projectDir),
      encoding: "utf8",
      env: { ...process.env, HOME: homeDir, LANG: "C" },
    });

    if (skipIfSpawnBlocked(result, t)) return;

    assert.equal(result.error, undefined, result.error?.message);
    assert.equal(result.status, 0, result.stderr || "non-zero exit");
    const normalized = stripAnsi(result.stdout).trimEnd();
    assert.equal(normalized, expected);
  } finally {
    await rm(homeDir, { recursive: true, force: true });
  }
});

// (b) + (c) cost slot renders "unmeasured" under the lane and never consults pricing
test('claudex lane: cost slot renders "unmeasured", never a dollar figure', () => {
  withEnv({ CLAUDEX_LANE_OK: "1" }, () => {
    const ctx = {
      stdin: { model: { display_name: "Opus" } },
      transcript: {
        sessionTokens: {
          inputTokens: 100000,
          outputTokens: 50000,
          cacheCreationTokens: 0,
          cacheReadTokens: 0,
        },
      },
      config: { display: { showCost: true }, colors: {} },
    };
    const line = stripAnsi(renderCostEstimate(ctx));
    assert.ok(line.includes("unmeasured"), `expected "unmeasured" in: ${line}`);
    assert.ok(!line.includes("$"), `expected no dollar figure in: ${line}`);
  });
});

test("claudex lane: the pricing lookup is not consulted under the lane", () => {
  withEnv({ CLAUDEX_LANE_OK: "1" }, () => {
    const tokens = {
      inputTokens: 100000,
      outputTokens: 50000,
      cacheCreationTokens: 0,
      cacheReadTokens: 0,
    };
    assert.equal(
      estimateSessionCost({ model: { display_name: "Claude Sonnet 4" } }, tokens),
      null,
    );
    assert.equal(
      getNativeCostUsd({
        model: { display_name: "Claude Sonnet 4" },
        cost: { total_cost_usd: 1.23 },
      }),
      null,
    );
  });
});

// (d) context line carries the "configured" denominator label under the lane
test("claudex lane: context line carries the configured denominator label", () => {
  withEnv({ CLAUDEX_LANE_OK: "1" }, () => {
    const ctx = {
      stdin: {
        model: { display_name: "Opus" },
        context_window: {
          context_window_size: 200000,
          current_usage: {
            input_tokens: 10000,
            cache_creation_input_tokens: 0,
            cache_read_input_tokens: 0,
          },
        },
      },
      config: { display: {}, colors: {} },
    };
    const line = stripAnsi(renderIdentityLine(ctx));
    assert.ok(line.includes("configured"), `expected "configured" in: ${line}`);
  });
});
