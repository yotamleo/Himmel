import { expect, test } from "bun:test";
import { join } from "node:path";
import { classifyForSpawn, parseTriageVerdict, type TriageVerdict } from "./triage";
import { REPO_ROOT } from "./run";

test("parseTriageVerdict accepts the four strict single-token verdicts", () => {
  for (const verdict of ["ignore", "ack", "spawn-low", "spawn-high"] as TriageVerdict[]) {
    expect(parseTriageVerdict(verdict)).toBe(verdict);
  }
});

test("parseTriageVerdict fails open on garbage or extra text", () => {
  expect(parseTriageVerdict("")).toBe("spawn-high");
  expect(parseTriageVerdict("ignore this")).toBe("spawn-high");
  expect(parseTriageVerdict("SPAWN-LOW")).toBe("spawn-high");
  expect(parseTriageVerdict("maybe")).toBe("spawn-high");
});

test("classifyForSpawn shells through the cheap classifier and parses its verdict", async () => {
  const calls: any[] = [];
  const verdict = await classifyForSpawn("ship this?", {
    invoke: async (args, input) => {
      calls.push({ args, input });
      return "spawn-low\n";
    },
    timeoutMs: 1000,
  });

  expect(verdict).toBe("spawn-low");
  expect(calls).toHaveLength(1);
  expect(calls[0].args).toEqual(["bash", join(REPO_ROOT, "scripts", "hermes", "invoke.sh"), "--model", "deepseek-chat", "--provider", "deepseek"]);
  expect(calls[0].input).toContain("ship this?");
  expect(calls[0].input).not.toContain("chat_id");
});

test("classifyForSpawn fails open on classifier timeout", async () => {
  const verdict = await classifyForSpawn("hello", {
    invoke: async () => {
      await Bun.sleep(100);
      return "ignore";
    },
    timeoutMs: 5,
  });

  expect(verdict).toBe("spawn-high");
});

test("TELEGRAM_TRIAGE_TIMEOUT_MS env var is honored when no deps.timeoutMs is given", async () => {
  process.env.TELEGRAM_TRIAGE_TIMEOUT_MS = "20";
  try {
    // no deps.timeoutMs ⇒ the env deadline (20ms) must govern; the slow invoke
    // (500ms) loses → fail-open spawn-high.
    const verdict = await classifyForSpawn("hello", {
      invoke: async () => { await Bun.sleep(500); return "ignore"; },
    });
    expect(verdict).toBe("spawn-high");
  } finally {
    delete process.env.TELEGRAM_TRIAGE_TIMEOUT_MS;
  }
});

test("TELEGRAM_TRIAGE_TIMEOUT_MS falls back to the default on garbage / non-positive values", async () => {
  for (const bad of ["0", "-5", "garbage", ""]) {
    process.env.TELEGRAM_TRIAGE_TIMEOUT_MS = bad;
    try {
      // A fast-resolving invoke must win against the (defaulted) deadline and
      // parse to spawn-low — proving the bad value did NOT collapse the timeout
      // to 0/NaN (which would race-reject before invoke resolves).
      const verdict = await classifyForSpawn("ship this?", {
        invoke: async () => "spawn-low\n",
      });
      expect(verdict).toBe("spawn-low");
    } finally {
      delete process.env.TELEGRAM_TRIAGE_TIMEOUT_MS;
    }
  }
});

test("cancelable timeout: a fast-resolving invoke leaves no unhandled rejection", async () => {
  // The old Promise.race-against-Bun.sleep().then(throw) leaked: when invoke
  // won, the sleep promise later fired its throw as an unhandledRejection. The
  // setTimeout/clearTimeout-in-finally fix clears the timer, so nothing fires.
  const rejections: unknown[] = [];
  const handler = (reason: unknown) => { rejections.push(reason); };
  process.on("unhandledRejection", handler);
  try {
    const verdict = await classifyForSpawn("ship this?", {
      invoke: async () => "spawn-low\n",
      timeoutMs: 1000,
    });
    expect(verdict).toBe("spawn-low");
    await Bun.sleep(50);   // give the runtime a turn to surface any late throw
    expect(rejections).toEqual([]);
  } finally {
    process.off("unhandledRejection", handler);
  }
});
