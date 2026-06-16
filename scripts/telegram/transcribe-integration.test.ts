// Integration acceptance test for whisper.cpp go-live (HIMMEL-268).
// Requires real binaries in ~/.himmel/whisper/ and ffmpeg on PATH.
// Skip in CI or when WHISPER_INTEGRATION_TEST is not set.
//
// Run manually:
//   WHISPER_INTEGRATION_TEST=1 bun test scripts/telegram/transcribe-integration.test.ts
//
// Sample file: ~/.himmel/whisper/jfk.wav (downloaded during HIMMEL-268 install;
// expected transcript contains "ask not what your country can do for you").
import { expect, test } from "bun:test";
import { transcribe } from "./transcribe";
import { join } from "node:path";
import { homedir } from "node:os";
import { access } from "node:fs/promises";

const SKIP = !process.env.WHISPER_INTEGRATION_TEST;
const testFn = SKIP ? test.skip : test;

const WHISPER_DIR = process.env.WHISPER_DIR ?? join(homedir(), ".himmel", "whisper");
const SAMPLE_WAV = join(WHISPER_DIR, "jfk.wav");

testFn("LIVE: transcribe jfk.wav via real whisper.cpp — transcript contains expected words", async () => {
  // Guard: binaries + sample file must exist or the test gives a useless error
  await access(SAMPLE_WAV);   // throws ENOENT if missing — tells the operator what to fix

  const transcript = await transcribe(SAMPLE_WAV);
  // whisper output for jfk.wav is stable across models — key phrase is deterministic
  expect(transcript).not.toBeNull();
  const lower = transcript!.toLowerCase();
  expect(lower).toContain("country");
  expect(lower).toContain("ask");
}, 120_000);   // 120s: first run cold-loads the model
