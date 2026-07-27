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

// HIMMEL-1296. The prompt handed the classifier a bare message: no statement of
// what the group IS, and — the part that actually caused the loss — no statement
// that `ack` DISCARDS the message. `ack` reads as "send an acknowledgement", so
// the model picked it for messages it had understood were addressed to the
// agent, and the poller threw them away. Both halves are asserted here; the
// measured verdict shift they produce is recorded above triagePrompt().
test("triage prompt frames the channel AND names each verdict's effect (HIMMEL-1296)", async () => {
  let prompt = "";
  await classifyForSpawn("try again..", {
    invoke: async (_args, input) => { prompt = input; return "spawn-low"; },
    timeoutMs: 1000,
    fromOperator: true,
  });

  expect(prompt).toContain("from the human operator");
  expect(prompt).toContain("follow-up is still a request");
  // the drop verdicts must both be described as discarding — `ack` especially,
  // whose token name otherwise promises the opposite of what it does
  expect(prompt).toContain("ignore: silently discarded");
  expect(prompt).toContain("ack: ALSO silently discarded");
  expect(prompt).toContain("try again..");
  // the four-token answer contract must survive the added framing
  expect(prompt).toContain("exactly one token: ignore, ack, spawn-low, or spawn-high");
});

// The operator framing must go ONLY where it is true (CR codex-adv-1). A bare
// group allowlist admits every member, so telling the classifier "this is from
// the operator" for an ordinary member would widen the very spam gate
// HIMMEL-721 exists to keep — and the branch's own measurements show framing
// moves verdicts, so this is not a harmless inaccuracy.
test("a NON-operator gets shared-group framing, never the operator framing (HIMMEL-1296)", async () => {
  let prompt = "";
  await classifyForSpawn("lol nice", {
    invoke: async (_args, input) => { prompt = input; return "ack"; },
    timeoutMs: 1000,
    fromOperator: false,
  });

  expect(prompt).not.toContain("from the human operator");
  expect(prompt).not.toContain("follow-up is still a request");
  expect(prompt).toContain("NOT from the operator");
  expect(prompt).toContain("ordinary chatter");
  // the ROLE-NEUTRAL half — what the verdicts actually do — is still told to
  // everyone, because that is what stops `ack` reading as "acknowledge"
  expect(prompt).toContain("ack: ALSO silently discarded");
});

// Absence of the flag must fall to the SAFE side: an unwired caller gets the
// shared-group framing, never the operator's.
test("triage prompt defaults to shared-group framing when the role is unset (HIMMEL-1296)", async () => {
  let prompt = "";
  await classifyForSpawn("hello", {
    invoke: async (_args, input) => { prompt = input; return "ack"; },
    timeoutMs: 1000,
  });

  expect(prompt).not.toContain("from the human operator");
  expect(prompt).toContain("NOT from the operator");
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
