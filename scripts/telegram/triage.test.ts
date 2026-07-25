import { expect, test } from "bun:test";
import { existsSync } from "node:fs";
import { join } from "node:path";
import { classifyForSpawn, parseTriageVerdict, type TriageVerdict } from "./triage";
import { BASH_BIN, REPO_ROOT, resolveBash } from "./run";

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
  expect(calls[0].args).toEqual([BASH_BIN, join(REPO_ROOT, "scripts", "hermes", "invoke.sh"), "--model", "deepseek-v4-flash", "--provider", "deepseek"]);
  expect(calls[0].input).toContain("ship this?");
  expect(calls[0].input).not.toContain("chat_id");
});

// HIMMEL-1279 regression. The classifier was dead on 100% of messages because
// argv[0] was a bare "bash": under the poller's PATH that resolves to the WSL
// System32 stub, which cannot see ANY C: path (it exits 127 on both `C:\...`
// and `C:/...`, so POSIX-ifying argv[1] would not have helped) — and
// classifyForSpawn fails open to spawn-high, so the breakage was invisible.
// Asserted on the CONSTRUCTED argv rather than on a live spawn so it runs on
// every platform: the interpreter must exist and must not be the stub, and the
// script path must resolve.
test("classifyForSpawn spawns a real non-WSL bash against an existing script (HIMMEL-1279)", async () => {
  const calls: any[] = [];
  await classifyForSpawn("hi", { invoke: async (args) => { calls.push(args); return "ack"; }, timeoutMs: 1000 });

  const [interpreter, script] = calls[0];
  expect(interpreter).not.toMatch(/system32|windowsapps/i);
  expect(existsSync(script)).toBe(true);
  if (process.platform === "win32") {
    // Windows must name the interpreter ABSOLUTELY. That is the whole contract:
    // any PATH-resolved name can land on the stub, so resolveBash() never
    // returns one here — not even as a last-resort fallback (it returns the
    // canonical Git Bash path, so a machine without it fails ENOENT loudly
    // rather than 127 silently). Asserting the shape, not existence, keeps this
    // true on a Windows box that has no Git Bash installed.
    expect(interpreter).not.toBe("bash");
    expect(interpreter).toMatch(/^[A-Za-z]:[\\/]/);
  } else {
    expect(interpreter).toBe("bash");
  }
  expect(resolveBash()).toBe(BASH_BIN);
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
