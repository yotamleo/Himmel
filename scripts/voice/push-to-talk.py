#!/usr/bin/env python3
"""Speak, get text on the clipboard. The desk-side ears.

Records from an EXPLICIT input device, transcribes locally with whisper.cpp,
and puts the result on the clipboard to paste wherever you like.

Why the device is never inferred: this machine's default input is
"Loopback Mix (MOTU M Series)", which captures the computer's own OUTPUT. Record
from the default and you capture the assistant speaking, not the operator — a
feedback loop that looks like a transcription bug. The physical jack is
"In 1-2 (MOTU M Series)". Measured, not assumed: In 1-2 ran ~3dB hotter than the
loopback blend and cannot pick up playback at all.

Audio never leaves the machine — whisper.cpp is local, and the egress matrix
classifies captured audio as voice-audio (local-speech only, HIMMEL-1522).
The recording is deleted after transcription.

Env:
    MIC_DEVICE     input device name substring (default: the MOTU physical jack)
    WHISPER_DIR    default ~/.himmel/whisper
    WHISPER_MODEL  default ggml-large-v3-turbo.bin
    MIC_MAX_SECS   hard cap, default 60
    MIC_LANG       default auto
"""
from __future__ import annotations

import os
import queue
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

import numpy as np
import sounddevice as sd
import soundfile as sf

# Send-now. Two mechanisms, because the obvious one is not reliable here.
#
# msvcrt.kbhit() reads the console input buffer directly and looked like the
# right tool, but it saw nothing when PowerShell ran this inside a pipeline —
# the console handle a piped child gets is not the one the keystrokes land on.
# A blocking read of inherited stdin does work, so ENTER is the real mechanism
# and kbhit stays only as a bonus for the un-piped case.
try:
    import msvcrt as _kb
except ImportError:
    _kb = None

_send_now = threading.Event()


def _watch_for_enter() -> None:
    """Block on stdin; a line means 'stop recording and send'."""
    try:
        sys.stdin.readline()
        _send_now.set()
    except Exception:
        pass

DEVICE_HINT = os.environ.get("MIC_DEVICE", "In 1-2 (MOTU M Series)")
WHISPER_DIR = Path(os.environ.get("WHISPER_DIR", Path.home() / ".himmel" / "whisper"))
MODEL = WHISPER_DIR / os.environ.get("WHISPER_MODEL", "ggml-large-v3-turbo.bin")
CLI = WHISPER_DIR / "whisper-cli.exe"
MAX_SECS = float(os.environ.get("MIC_MAX_SECS", "60"))
LANG = os.environ.get("MIC_LANG", "auto")

SR = 16_000            # whisper.cpp wants 16k mono; capture there directly
BLOCK = 1600           # 100ms
SILENCE_DB = float(os.environ.get("MIC_SILENCE_DB", "-42"))
# Trailing silence that ends the take. 1.5s cut real sentences short in use —
# people pause mid-thought — so the default is deliberately generous. Lower it
# for terse commands, raise it if you think out loud.
HANG_SECS = float(os.environ.get("MIC_HANG_SECS", "2.5"))
MIN_SPEECH = float(os.environ.get("MIC_MIN_SPEECH", "0.4"))  # ignore a cough or a keypress


def find_device(hint: str) -> int:
    exact = [i for i, d in enumerate(sd.query_devices())
             if d["max_input_channels"] > 0 and d["name"].strip() == hint]
    if exact:
        return exact[0]
    loose = [i for i, d in enumerate(sd.query_devices())
             if d["max_input_channels"] > 0 and hint.lower() in d["name"].lower()]
    if loose:
        return loose[0]
    raise SystemExit(f"no input device matching {hint!r} — set MIC_DEVICE")


def record(device: int) -> np.ndarray:
    q: queue.Queue = queue.Queue()

    def cb(indata, frames, time_info, status):
        q.put(indata.copy())

    chunks: list[np.ndarray] = []
    speech_secs = 0.0
    silence_secs = 0.0
    started = False

    # ASCII only: the Windows console is cp1252 and renders an em-dash as '?'.
    with sd.InputStream(samplerate=SR, blocksize=BLOCK, channels=1,
                        dtype="float32", device=device, callback=cb):
        # Announce readiness only AFTER the stream is open and settled.
        #
        # Previously the prompt printed first, so the caller heard "go" while
        # python was still importing and the device was still opening — the
        # opening word landed in that gap and was simply never captured. The
        # cue has to come from the point where audio is genuinely arriving,
        # not from the point where we intend to start.
        settle_deadline = time.monotonic() + 0.35
        while time.monotonic() < settle_deadline:
            try:
                q.get(timeout=0.1)      # discard warm-up blocks (device noise)
            except queue.Empty:
                break

        # Only watch stdin when it is a real terminal. If it were redirected,
        # readline() would return EOF instantly and end the take before a word
        # was said.
        can_send = False
        try:
            can_send = sys.stdin is not None and sys.stdin.isatty()
        except Exception:
            can_send = False
        if can_send:
            threading.Thread(target=_watch_for_enter, daemon=True).start()

        # ASCII only: the Windows console is cp1252 and renders an em-dash as '?'.
        hint = "listening... speak, then pause" + (" (or press ENTER to send)" if can_send else "")
        print(hint, file=sys.stderr, flush=True)
        try:
            import winsound
            winsound.Beep(880, 120)     # cue fires here, not before the stream
        except Exception:
            pass

        total = 0.0
        while total < MAX_SECS:
            # Send-now: waiting out the silence timer to say "I am done" is
            # friction on every turn. ENTER ends the take at once.
            # ENTER specifically, not any key (codex-1): `getch() or True` ended
            # the take on whatever was pressed, so a stray keystroke truncated
            # the recording while the docs promised ENTER. A non-ENTER key is
            # still consumed here, so it cannot queue up and fire later.
            if _send_now.is_set() or (_kb and _kb.kbhit() and _kb.getch() in (b"\r", b"\n")):
                print("sent", file=sys.stderr, flush=True)
                break
            block = q.get()
            chunks.append(block)
            total += len(block) / SR
            rms = float(np.sqrt(np.mean(block.astype(np.float64) ** 2)))
            db = 20 * np.log10(max(rms, 1e-12))
            if db > SILENCE_DB:
                started = True
                speech_secs += len(block) / SR
                silence_secs = 0.0
            elif started:
                silence_secs += len(block) / SR
                # End the take only after real speech, so leading silence while
                # the operator gathers their thought does not cut it short.
                if silence_secs >= HANG_SECS and speech_secs >= MIN_SPEECH:
                    break

    if speech_secs < MIN_SPEECH:
        raise SystemExit("nothing said")
    audio = np.concatenate(chunks, axis=0).flatten()
    print(f"captured {len(audio)/SR:.1f}s ({speech_secs:.1f}s speech)", file=sys.stderr, flush=True)
    return audio


def transcribe(audio: np.ndarray) -> str:
    if not CLI.exists():
        raise SystemExit(f"whisper-cli not found at {CLI}")
    if not MODEL.exists():
        raise SystemExit(f"model not found at {MODEL}")

    peak = float(np.max(np.abs(audio))) or 1.0
    audio = audio * (0.95 / peak)          # the M2 runs quiet; normalise for whisper

    # mkdtemp INSIDE the try, so a failing sf.write cannot leak the directory
    # (glm-1). The finally below removes the recording, and a take that never
    # got written should not leave its folder behind either.
    tmpdir = Path(tempfile.mkdtemp(prefix="ptt-"))
    try:
        tmp = tmpdir / "take.wav"
        sf.write(str(tmp), audio, SR, subtype="PCM_16")
        out = subprocess.run(
            [str(CLI), "-m", str(MODEL), "-f", str(tmp), "-l", LANG, "-nt", "--no-prints"],
            # Explicit UTF-8, matching jarvis.py. text=True alone decodes with
            # the locale codec — cp1252 on Windows — which garbles any non-ASCII
            # transcription (glm-3).
            capture_output=True, text=True, encoding="utf-8", errors="replace",
            timeout=300,
        )
        if out.returncode != 0:
            raise SystemExit(f"whisper failed ({out.returncode}): {out.stderr.strip()[:300]}")
        return " ".join(out.stdout.split()).strip()
    finally:
        # Keyed off tmpdir, not tmp: if sf.write raised, `tmp` may never have
        # become a file, but the directory always exists by this point.
        (tmpdir / "take.wav").unlink(missing_ok=True)   # the recording is not kept
        try:
            tmpdir.rmdir()
        except OSError:
            pass


def to_clipboard(text: str) -> bool:
    # Set-Clipboard over clip.exe: clip.exe mangles non-ASCII, and the operator
    # dictates in more than one language.
    try:
        # Absolute path, not a bare name: a bare "powershell" resolves through
        # PATH, so anything earlier on it wins and receives the dictated text on
        # stdin. SystemRoot rather than a hardcoded C:.
        pwsh = os.path.join(os.environ.get("SystemRoot", r"C:\Windows"),
                            "System32", "WindowsPowerShell", "v1.0", "powershell.exe")
        subprocess.run([pwsh, "-NoProfile", "-Command", "Set-Clipboard -Value $input"],
                       input=text, text=True, encoding="utf-8", check=True, timeout=15)
        return True
    except Exception:
        return False


def main() -> int:
    # --out <path> writes the transcript to a file instead of relying on stdout.
    #
    # A caller that pipes our stdout (PowerShell's `| Out-String`) leaves this
    # process with console handles that msvcrt cannot poll and that made the
    # ENTER watcher unreliable — and it swallows the "listening" hint too,
    # since that goes to stderr. Handing the result back through a file lets
    # the caller run us with a plain inherited console, where stdin and the
    # prompts both behave normally.
    out_path = None
    if "--out" in sys.argv:
        i = sys.argv.index("--out")
        if i + 1 < len(sys.argv):
            out_path = Path(sys.argv[i + 1])

    dev = find_device(DEVICE_HINT)
    print(f"device: [{dev}] {sd.query_devices()[dev]['name']}", file=sys.stderr)
    text = transcribe(record(dev))
    if not text:
        print("(nothing transcribed)", file=sys.stderr)
        if out_path:
            out_path.write_text("", encoding="utf-8")
        return 1
    if out_path:
        out_path.write_text(text, encoding="utf-8")
    else:
        print(text)
    print("-> clipboard" if to_clipboard(text) else "!! clipboard failed", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
