#!/usr/bin/env python3
"""Always-listening voice assistant: wake word in, stop word to cut it off.

Replaces the push-to-talk loop for hands-free use. One process owns the
microphone for its whole lifetime — two processes competing for one input
device is fragile, so wake detection, utterance capture and stop-word watching
all live here.

THE ECHO PROBLEM. A stop word has to work WHILE the assistant is talking, which
means keeping the mic open during playback. Speakers and mic share a room, so
the assistant's own voice comes straight back in. Gating the mic (what the
push-to-talk loop does) kills the feedback but also kills barge-in.

The way out is that we know exactly what is being spoken. While playback is
live, any transcription whose words are already in the outgoing text is treated
as our own echo and dropped. Only words that are NOT in what we are saying can
act — and the stop word is deliberately chosen to be one the assistant will not
say. That is cheap, needs no acoustic echo cancellation, and fails safe: a
missed stop word costs one more sentence of speech, never a wrong action.

Transcription runs in-process on faster-whisper (CUDA). whisper.cpp is a
subprocess per call, and paying process startup once a second for rolling wake
detection would dominate the latency budget.

Env:
    JARVIS_WAKE      comma-separated wake phrases (default "jarvis,hey jarvis")
    JARVIS_STOP      comma-separated stop phrases (default "stop,stop it,shut off,quiet,cancel")
    JARVIS_MODEL     faster-whisper model (default large-v3-turbo)
    JARVIS_VOICE     voice name for the daemon (default: daemon's own default)
    JARVIS_CLAUDE_MODEL   default "sonnet"
    MIC_DEVICE       input device (default the MOTU physical jack)
    VOICE_PORT       daemon port (default 8788)
"""
from __future__ import annotations

import json
import os
import queue
import re
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request

import numpy as np
import sounddevice as sd

SR = 16_000
BLOCK = 1600                      # 100ms
WINDOW_S = 2.4                    # rolling window handed to the recogniser
HOP_S = 0.8                       # how often that window is re-examined
SILENCE_DB = float(os.environ.get("MIC_SILENCE_DB", "-42"))
HANG_S = float(os.environ.get("MIC_HANG_SECS", "2.0"))
MAX_UTTER_S = float(os.environ.get("MIC_MAX_SECS", "60"))

WAKE = [w.strip().lower() for w in os.environ.get("JARVIS_WAKE", "jarvis,hey jarvis").split(",") if w.strip()]
STOP = [w.strip().lower() for w in
        os.environ.get("JARVIS_STOP", "stop,stop it,shut off,quiet,cancel").split(",") if w.strip()]
MODEL_NAME = os.environ.get("JARVIS_MODEL", "large-v3-turbo")
VOICE = os.environ.get("JARVIS_VOICE") or None
CLAUDE_MODEL = os.environ.get("JARVIS_CLAUDE_MODEL", "sonnet")
DEVICE_HINT = os.environ.get("MIC_DEVICE", "In 1-2 (MOTU M Series)")
PORT = int(os.environ.get("VOICE_PORT", "8788"))
DAEMON = f"http://127.0.0.1:{PORT}"

VOICE_PROMPT = """You are answering over a VOICE channel. The message you receive is a
speech-to-text transcript of someone talking to you, and your reply is read aloud.

- Answer in one to three sentences of plain spoken prose.
- No markdown, no bullet lists, no code blocks, no URLs, no emoji.
- Lead with the answer. Offer detail rather than delivering it.
- The transcript may contain speech-recognition errors. If a request is ambiguous
  because of a likely mishearing, ask a brief clarifying question.
- Never say you cannot hear or have no audio input; you are receiving a transcript."""

_spoken_now = ""          # what the daemon is currently saying, for echo rejection
_spoken_at = 0.0          # when we queued it — see clear_spoken()
_spoken_lock = threading.Lock()
# How long a queued reply keeps its echo reference even though the daemon still
# reports speaking=False. Covers the synthesis gap (~1s typical) with margin;
# too short reopens the self-cancel window, too long makes a genuine stop word
# spoken right after a reply look like echo.
SPOKEN_GRACE_S = 6.0


def norm(s: str) -> str:
    return re.sub(r"[^a-z0-9 ]+", " ", s.lower()).strip()


def post(path: str, payload: dict) -> dict | None:
    try:
        req = urllib.request.Request(
            f"{DAEMON}{path}", data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"}, method="POST")
        with urllib.request.urlopen(req, timeout=10) as r:
            return json.loads(r.read() or b"{}")
    except Exception:
        return None


def daemon_speaking() -> bool:
    try:
        with urllib.request.urlopen(f"{DAEMON}/health", timeout=3) as r:
            return bool(json.loads(r.read()).get("speaking"))
    except Exception:
        return False


def is_echo(text: str) -> bool:
    """True when what we heard is just the assistant's own speech coming back."""
    with _spoken_lock:
        current = norm(_spoken_now)
    if not current:
        return False
    words = [w for w in norm(text).split() if len(w) > 2]
    if not words:
        return True
    hits = sum(1 for w in words if w in current)
    # Most content words already present in what we are saying => our own voice.
    return hits / len(words) >= 0.6


def spoken_now() -> str:
    """What the assistant is saying right now (empty when silent)."""
    with _spoken_lock:
        return _spoken_now


def find_device(hint: str) -> int:
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and d["name"].strip() == hint:
            return i
    for i, d in enumerate(sd.query_devices()):
        if d["max_input_channels"] > 0 and hint.lower() in d["name"].lower():
            return i
    raise SystemExit(f"no input device matching {hint!r} — set MIC_DEVICE")


def phrase_in(text: str, phrases: list[str]) -> str | None:
    t = f" {norm(text)} "
    for p in phrases:
        if f" {norm(p)} " in t:
            return p
    return None


def ask_claude(text: str) -> str:
    # Voice runs in `plan` permission mode (HIMMEL-1522).
    #
    # voice-policy.json says read/search/status/explain may proceed, writes need
    # confirmation, and push/merge/deploy/secrets/salus are denied. None of that
    # was ENFORCED — the policy was a document, and an unenforced guard is the
    # one that regresses. Full enforcement needs an action classifier (mapping a
    # spoken sentence onto a policy action), which is real work and is ticketed.
    #
    # Until then `plan` mode is the structural floor: the harness itself refuses
    # writes, so the deny tier holds even though the confirm tier does not exist
    # yet. This is deliberately STRICTER than the policy — voice cannot write at
    # all, where the policy would allow a confirmed edit — because failing
    # toward "cannot act" is the safe direction for an unauthenticated channel.
    # plan mode covers WRITES; voice-permissions.json covers READS. The policy's
    # two `hard` rules (secrets, policy-edit) and its salus deny are all about
    # reading, which plan mode permits — so without the settings profile the one
    # rule marked un-flippable was the one still inert.
    # Hardcoded, with NO env override (codex-2). An env var that can widen the
    # permission mode makes the "structural floor" a default instead — and an
    # env var is exactly what a half-remembered debugging session leaves set.
    # Widening requires editing this file, deliberately and reviewably.
    # --strict-mcp-config with NO --mcp-config = zero MCP servers (CR round 6,
    # [codex-adv-1]). A bare `claude` inherits the user/project MCP fleet, and
    # an MCP tool is not Read/Bash/Grep — so NO pattern in voice-permissions.json
    # can reach it. Probed: a voice spawn without this flag reported
    # `mcp__tokensave__tokensave_read` available, a file reader completely
    # outside the deny tier. The read-side control is only as good as the set of
    # tools it can name, and MCP tools are named by the server, not by us.
    cmd = ["claude", "--model", CLAUDE_MODEL, "--permission-mode", "plan",
           "--strict-mcp-config"]
    settings = os.path.join(os.path.dirname(os.path.abspath(__file__)), "voice-permissions.json")
    if not os.path.exists(settings):
        # FAIL CLOSED. The previous version warned and carried on, which is
        # fail-OPEN on a security control: the profile carries the read-side
        # denies for secrets and salus, and a warning on stderr (which the
        # loops suppress) is not consent to run without them. Refusing costs a
        # turn; continuing silently reads a credential aloud.
        msg = f"voice-permissions.json missing at {settings} - refusing to run unprotected"
        print(f"[jarvis] REFUSED: {msg}", file=sys.stderr, flush=True)
        return "My permission profile is missing, so I won't run without it. Check the voice install."
    # `--` terminates option parsing (CR round 6, [codex-1]). The transcript is
    # attacker-influenced text on the SAME argv that carries the permission
    # floor: without the terminator, a transcript starting `--permission-mode`
    # or `--settings` is parsed as a flag rather than as the prompt. Whisper
    # emitting a literal `--flag` is unlikely, but this channel cannot
    # authenticate its speaker and the fix is one token.
    cmd += ["--settings", settings, "--append-system-prompt", VOICE_PROMPT, "--", text]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, encoding="utf-8",
                           errors="replace", stdin=subprocess.DEVNULL, timeout=300)
    except subprocess.TimeoutExpired:
        return "That took too long, so I stopped waiting."
    except OSError as e:
        # Anything that stops the process from starting at all — claude not on
        # PATH being the obvious one. This used to propagate out of the handler
        # and kill the always-listening loop, so a single bad launch ended the
        # session silently and the mic simply stopped responding (glm-3).
        print(f"[jarvis] cannot run claude: {e}", file=sys.stderr, flush=True)
        return "I could not start Claude. Check that it is on my PATH."
    out = re.sub(r"\x1b\[[0-9;?]*[a-zA-Z]", "", r.stdout or "").strip()
    return out or "I did not get an answer back."


def speak(text: str) -> None:
    global _spoken_now, _spoken_at
    with _spoken_lock:
        _spoken_now = text
        _spoken_at = time.monotonic()
    post("/speak", {"text": text, **({"voice": VOICE} if VOICE else {})})


def clear_spoken() -> None:
    """Forget what we are saying — but never during the synthesis gap.

    /speak returns as soon as the job is queued, so for the ~1s until playback
    starts the daemon reports speaking=False while a reply is very much on its
    way. Clearing the echo reference in that window is what let the assistant
    cut ITSELF off (glm-2): its own upcoming "...stop..." would arrive with no
    reference to compare against, fail the echo test, and be actioned as a real
    stop command. Holding the reference for a grace period closes the window.
    """
    global _spoken_now
    with _spoken_lock:
        if _spoken_now and (time.monotonic() - _spoken_at) < SPOKEN_GRACE_S:
            return
        _spoken_now = ""


def main() -> int:
    from faster_whisper import WhisperModel

    dev = find_device(DEVICE_HINT)
    print(f"[jarvis] mic: [{dev}] {sd.query_devices()[dev]['name']}", flush=True)
    print(f"[jarvis] loading {MODEL_NAME}...", flush=True)
    model = WhisperModel(MODEL_NAME, device="cuda", compute_type="float16")

    def hear(audio: np.ndarray) -> str:
        segs, _ = model.transcribe(audio, language=None, beam_size=1,
                                   vad_filter=True, condition_on_previous_text=False)
        return " ".join(s.text for s in segs).strip()

    # Bounded: ~4x the analysis window is plenty of slack for a hop while
    # capping how far behind the microphone the loop can drift. See cb().
    q: queue.Queue = queue.Queue(maxsize=max(8, int(4 * WINDOW_S * SR / BLOCK)))
    sd.default.device = (dev, None)

    def cb(indata, frames, t, status):
        # Never block the audio callback, and never let the backlog grow without
        # bound. Transcription is not guaranteed to keep up with capture — a
        # long utterance or a busy GPU is enough — and with an unbounded queue
        # the loop then falls further behind the microphone every hop, waking on
        # audio that is minutes old while memory climbs. Dropping the oldest
        # block keeps the listener anchored to the present, which is the only
        # useful place for a wake word to be.
        try:
            q.put_nowait(indata.copy())
        except queue.Full:
            try:
                q.get_nowait()          # drop oldest
                q.put_nowait(indata.copy())
            except (queue.Empty, queue.Full):
                pass

    ring = np.zeros(0, dtype=np.float32)
    win_n = int(WINDOW_S * SR)
    hop_n = int(HOP_S * SR)
    since_hop = 0

    print(f"[jarvis] wake: {WAKE}   stop: {STOP}", flush=True)
    print("[jarvis] listening.", flush=True)

    with sd.InputStream(samplerate=SR, blocksize=BLOCK, channels=1,
                        dtype="float32", device=dev, callback=cb):
        while True:
            block = q.get().flatten()
            ring = np.concatenate([ring, block])[-win_n:]
            since_hop += len(block)
            if since_hop < hop_n or len(ring) < win_n // 2:
                continue
            since_hop = 0

            speaking = daemon_speaking()
            heard = hear(ring)
            if not heard:
                if not speaking:
                    clear_spoken()
                continue

            # STOP first: it must win even mid-sentence, and it is the one thing
            # allowed through while the assistant is talking.
            if phrase_in(heard, STOP):
                # Echo rejection must not swallow a REAL stop (CR round 7,
                # [codex-adv-3]). is_echo() scores the WHOLE utterance, so
                # "here is the status stop" reads as ~80% echo and the genuine
                # "stop" is discarded — and that happens precisely when barge-in
                # matters most, since heavy speaker bleed is what makes the rest
                # of the words echo in the first place. Our own voice can only be
                # saying something stop-like if the reply we are currently
                # SPEAKING actually contains a stop phrase; when it does not, the
                # stop word cannot have come from us, whatever the surrounding
                # words score.
                if speaking and is_echo(heard) and phrase_in(spoken_now(), STOP):
                    continue                      # our own voice saying something stop-like
                print(f"[jarvis] STOP ({heard!r})", flush=True)
                post("/stop", {})
                clear_spoken()
                ring = np.zeros(0, dtype=np.float32)
                continue

            if speaking:
                continue                          # nothing but STOP acts during playback
            clear_spoken()

            if not phrase_in(heard, WAKE):
                continue

            print(f"[jarvis] WAKE ({heard!r})", flush=True)
            try:
                import winsound
                winsound.Beep(880, 120)
            except Exception:
                pass

            # Capture the utterance that follows the wake word.
            ring = np.zeros(0, dtype=np.float32)
            chunks: list[np.ndarray] = []
            speech = 0.0
            silence = 0.0
            started = False
            total = 0.0
            while total < MAX_UTTER_S:
                b = q.get().flatten()
                chunks.append(b)
                total += len(b) / SR
                db = 20 * np.log10(max(float(np.sqrt(np.mean(b.astype(np.float64) ** 2))), 1e-12))
                if db > SILENCE_DB:
                    started = True
                    speech += len(b) / SR
                    silence = 0.0
                elif started:
                    silence += len(b) / SR
                    if silence >= HANG_S and speech >= 0.4:
                        break

            if speech < 0.4:
                print("[jarvis] nothing said", flush=True)
                continue

            said = hear(np.concatenate(chunks))
            # The wake word often lands at the head of the capture; drop it so
            # the model is not asked to interpret its own trigger.
            for w in WAKE:
                said = re.sub(rf"^\W*{re.escape(w)}\W*", "", said, flags=re.I)
            said = said.strip()
            if not said:
                print("[jarvis] wake with no request", flush=True)
                continue

            print(f"you: {said}", flush=True)
            reply = ask_claude(said)
            print(f"claude: {reply}", flush=True)
            speak(reply)

            # Drain whatever accumulated while thinking, so the next window does
            # not start halfway through a stale phrase.
            while not q.empty():
                try:
                    q.get_nowait()
                except queue.Empty:
                    break
            ring = np.zeros(0, dtype=np.float32)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        print("\n[jarvis] stopped", flush=True)
