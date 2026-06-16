import { unlink } from "node:fs/promises";
import { join } from "node:path";
import { homedir } from "node:os";

// Local whisper.cpp transcription (HIMMEL-251). Backend decision (operator):
// whisper.cpp — free + offline + multi-language; do NOT fold into gemini.
// Pipeline: ffmpeg (OGG/Opus → 16kHz mono WAV, whisper.cpp's required input)
// → whisper-cli (-l auto for multi-language detection) → stdout transcript.
//
// Binary/model resolution: env override first, else the default install dir
// (~/.himmel/whisper — setup steps in scripts/telegram/README.md), ffmpeg from PATH.
// WHISPER_CLI default is Windows-only (whisper-cli.exe); set WHISPER_CLI env var
// on macOS/Linux (e.g. /usr/local/bin/whisper-cli). Env vars are read at poller
// start — restart the bridge after any change.
const WHISPER_DIR = process.env.WHISPER_DIR ?? join(homedir(), ".himmel", "whisper");
const WHISPER_CLI = process.env.WHISPER_CLI ?? join(WHISPER_DIR, "whisper-cli.exe");
// small (multilingual) over base: operator voice notes may be non-English
// (hard requirement on the ticket) and base's non-English WER is poor.
const WHISPER_MODEL = process.env.WHISPER_MODEL ?? join(WHISPER_DIR, "ggml-small.bin");
const FFMPEG = process.env.FFMPEG_BIN ?? "ffmpeg";
// Per-step bound: a hung ffmpeg/whisper must not wedge the ingest loop forever.
// Malformed env values must not become NaN/0 — setTimeout(NaN|0) fires
// immediately, killing every child at spawn with a misleading "ffmpeg failed".
const RAW_TIMEOUT_MS = Number(process.env.TRANSCRIBE_TIMEOUT_MS ?? 120_000);
const STEP_TIMEOUT_MS = Number.isFinite(RAW_TIMEOUT_MS) && RAW_TIMEOUT_MS > 0 ? RAW_TIMEOUT_MS : 120_000;

// timedOut distinguishes a kill-on-timeout from a non-zero exit (HIMMEL-268 hardening):
// a timeout kill logs "timed out after Xms" so the operator debugs the timeout,
// not the tool. Without it, a kill appears as a generic "ffmpeg/whisper failed (code)".
export type ExecResult = { code: number; stdout: string; stderr: string; timedOut?: boolean };
export type ExecFn = (cmd: string[], timeoutMs: number) => Promise<ExecResult>;

export async function realExec(cmd: string[], timeoutMs: number): Promise<ExecResult> {
  const p = Bun.spawn(cmd, { stdout: "pipe", stderr: "pipe", stdin: "ignore" });
  let timedOut = false;
  const t = setTimeout(() => {
    timedOut = true;
    try { p.kill(); } catch {}
  }, timeoutMs);
  const [stdout, stderr, code] = await Promise.all([
    new Response(p.stdout).text(), new Response(p.stderr).text(), p.exited,
  ]);
  clearTimeout(t);
  return { code, stdout, stderr, timedOut };
}

// Transcribe an audio file to text. Null on ANY failure (missing binaries,
// conversion error, whisper error, empty/silent audio) — logged, never throws;
// the caller owns the user-facing "couldn't transcribe" reply.
export async function transcribe(audioPath: string, exec: ExecFn = realExec): Promise<string | null> {
  const wav = audioPath + ".wav";
  try {
    const ff = await exec([FFMPEG, "-y", "-i", audioPath, "-ar", "16000", "-ac", "1", wav], STEP_TIMEOUT_MS);
    if (ff.code !== 0) {
      const reason = ff.timedOut ? `timed out after ${STEP_TIMEOUT_MS}ms` : `exit ${ff.code}: ${ff.stderr.slice(-300)}`;
      console.error(`[transcribe] ffmpeg failed (${reason})`);
      return null;
    }
    const w = await exec([WHISPER_CLI, "-m", WHISPER_MODEL, "-f", wav, "-l", "auto", "-nt", "-np"], STEP_TIMEOUT_MS);
    if (w.code !== 0) {
      const reason = w.timedOut ? `timed out after ${STEP_TIMEOUT_MS}ms` : `exit ${w.code}: ${w.stderr.slice(-300)}`;
      console.error(`[transcribe] whisper failed (${reason})`);
      return null;
    }
    const text = w.stdout.trim();
    return text || null;   // empty transcript (silence) counts as a failure
  } catch (e) {
    console.error(`[transcribe] failed for ${audioPath}: ${e}`);
    return null;
  } finally {
    // WAV is ours (created by ffmpeg) — clean up. Log non-ENOENT failures (HIMMEL-268
    // hardening): Windows EBUSY/EPERM would silently leak WAVs; logging surfaces them
    // while still degrading gracefully (the transcript was already captured).
    await unlink(wav).catch((e: NodeJS.ErrnoException) => {
      if (e.code !== "ENOENT") console.error(`[transcribe] wav cleanup failed for ${wav}: ${e.code ?? e}`);
    });
  }
}
