import { expect, test } from "bun:test";
import { transcribe, realExec, type ExecFn, type ExecResult } from "./transcribe";

const ok = (stdout = ""): ExecResult => ({ code: 0, stdout, stderr: "" });
const fail = (stderr = "boom"): ExecResult => ({ code: 1, stdout: "", stderr });

test("transcribe happy path: ffmpeg converts to 16kHz mono wav, whisper runs -l auto, transcript trimmed", async () => {
  const calls: string[][] = [];
  const exec: ExecFn = async (cmd) => {
    calls.push(cmd);
    return calls.length === 1 ? ok() : ok("  hello world \n");
  };
  expect(await transcribe("/att/20.oga", exec)).toBe("hello world");
  expect(calls.length).toBe(2);
  // ffmpeg leg: source in, 16kHz mono wav out
  expect(calls[0]).toContain("/att/20.oga");
  expect(calls[0]).toContain("16000");
  expect(calls[0]).toContain("/att/20.oga.wav");
  // whisper leg: wav in, auto language (multi-language requirement)
  expect(calls[1]).toContain("/att/20.oga.wav");
  expect(calls[1]).toContain("auto");
});

test("transcribe: ffmpeg failure returns null, whisper never runs", async () => {
  const calls: string[][] = [];
  const exec: ExecFn = async (cmd) => { calls.push(cmd); return fail("bad ogg"); };
  expect(await transcribe("/att/x.oga", exec)).toBeNull();
  expect(calls.length).toBe(1);
});

test("transcribe: whisper failure returns null", async () => {
  let n = 0;
  const exec: ExecFn = async () => (++n === 1 ? ok() : fail("model not found"));
  expect(await transcribe("/att/x.oga", exec)).toBeNull();
});

test("transcribe: empty transcript (silence) counts as failure", async () => {
  let n = 0;
  const exec: ExecFn = async () => (++n === 1 ? ok() : ok("   \n"));
  expect(await transcribe("/att/x.oga", exec)).toBeNull();
});

test("transcribe: exec throw degrades to null, never throws", async () => {
  const exec: ExecFn = async () => { throw new Error("ENOENT ffmpeg"); };
  expect(await transcribe("/att/x.oga", exec)).toBeNull();
});

// HIMMEL-268 hardening: timedOut flag tests

test("transcribe: ffmpeg timeout sets timedOut flag, logs timeout reason", async () => {
  const logs: string[] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => { logs.push(String(a[0])); };
  try {
    let n = 0;
    const exec: ExecFn = async () => {
      ++n;
      return { code: 1, stdout: "", stderr: "", timedOut: true };
    };
    const result = await transcribe("/att/x.oga", exec);
    expect(result).toBeNull();
    expect(n).toBe(1);   // whisper must not run after timed-out ffmpeg
    expect(logs.some((l) => l.includes("timed out"))).toBe(true);
  } finally {
    console.error = orig;
  }
});

test("transcribe: whisper timeout sets timedOut flag, logs timeout reason", async () => {
  const logs: string[] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => { logs.push(String(a[0])); };
  try {
    let n = 0;
    const exec: ExecFn = async () => {
      ++n;
      return n === 1
        ? { code: 0, stdout: "", stderr: "" }
        : { code: 1, stdout: "", stderr: "", timedOut: true };
    };
    expect(await transcribe("/att/x.oga", exec)).toBeNull();
    expect(logs.some((l) => l.includes("timed out"))).toBe(true);
  } finally {
    console.error = orig;
  }
});

// HIMMEL-268 hardening: timeout arg reaches exec (realExec integration)
test("realExec: kills long-running child and sets timedOut after timeout", async () => {
  // ping -n 100 127.0.0.1 sends 100 ICMP requests with 1s gaps → ~100s wall time.
  // Killed after 200ms; timedOut must be set and exit code non-zero.
  // (cmd /c timeout /t 30 exits immediately in non-TTY contexts with code 125.)
  const res = await realExec(["ping", "-n", "100", "127.0.0.1"], 200);
  expect(res.timedOut).toBe(true);
  // exit code after a kill is non-zero (signal kill or taskkill forceful exit)
  expect(res.code).not.toBe(0);
}, 5000);

// HIMMEL-268 hardening: WAV cleanup non-ENOENT errors are logged

test("transcribe: wav cleanup ENOENT is silently swallowed", async () => {
  const logs: string[] = [];
  const orig = console.error;
  console.error = (...a: unknown[]) => { logs.push(String(a[0])); };
  try {
    // happy path exec — WAV path doesn't exist, unlink gets ENOENT, must not log
    let n = 0;
    const exec: ExecFn = async () => (++n === 1 ? { code: 0, stdout: "", stderr: "" } : { code: 0, stdout: "hello", stderr: "" });
    await transcribe("/nonexistent/x.oga", exec);
    expect(logs.filter((l) => l.includes("wav cleanup")).length).toBe(0);
  } finally {
    console.error = orig;
  }
});
