#!/usr/bin/env python3
"""Resident speech service — keeps the TTS model warm so replies are instant.

The daemon exists for one reason: Chatterbox costs ~8s to load and ~10s more to
warm up its first inference. Spawn it per utterance and you pay ~18s every time,
which makes its sub-second synthesis meaningless. Held resident, a short reply
is spoken in well under a second.

Output only. It speaks text handed to it; it does not decide anything and does
not act. The voice ACTION policy (scripts/guardrails/voice-policy.json) governs
the input path — what a spoken request may cause — and binds when voice input
lands, not here.

Endpoints (loopback only):
    POST /speak   {"text": str, "voice"?: str, "interrupt"?: bool}
    POST /stop    stop playback, drop anything pending
    GET  /health  model/voice/device state

Env:
    VOICE_PORT      default 8788
    VOICE_HOME      default ~/.himmel/voice
    VOICE_DEVICE    sounddevice output device (name substring or index)
    VOICE_NAME      override the default voice from voices.json
"""
from __future__ import annotations

import json
import os
import re
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

VOICE_HOME = Path(os.environ.get("VOICE_HOME", Path.home() / ".himmel" / "voice"))
PORT = int(os.environ.get("VOICE_PORT", "8788"))
DEVICE = os.environ.get("VOICE_DEVICE") or None
MAX_CHARS = 600

_model = None
_model_lock = threading.Lock()   # the model is not re-entrant; serialise generate()
_current_voice: str | None = None

# One pending item, latest wins. For an assistant a queued older reply is stale
# by the time it would play, so superseding beats backlogging.
_pending: dict | None = None
_pending_cv = threading.Condition()
_stop_flag = threading.Event()
# Bumped by /stop and by an interrupting /speak. A job carries the generation it
# was queued under; if that no longer matches when synthesis finishes, the job
# was cancelled WHILE it was being generated and must never reach the speakers.
# Without this a cancel arriving during the ~1s synthesis window was lost, and
# stale audio played anyway.
_generation = 0
_gen_lock = threading.Lock()
_state = {"speaking": False, "last_error": None, "spoken": 0}


def load_voices() -> dict:
    path = VOICE_HOME / "voices.json"
    if not path.exists():
        return {"default": None, "voices": {}}
    return json.loads(path.read_text(encoding="utf-8"))


def normalise(text: str) -> str:
    """Make arbitrary agent output speakable.

    Reading a fenced code block aloud is useless noise, and a URL read character
    by character is worse. Both are dropped rather than mangled — the full text
    is still on screen, which is the whole premise of the spoken channel.
    """
    text = re.sub(r"```.*?```", " ", text, flags=re.S)      # fenced code
    text = re.sub(r"`([^`]*)`", r"\1", text)                 # inline code ticks
    text = re.sub(r"https?://\S+", "a link", text)
    text = re.sub(r"^\s*[-*+]\s+", "", text, flags=re.M)     # list bullets
    text = re.sub(r"[*_#>|]+", " ", text)                    # md emphasis/table junk
    text = re.sub(r"\s+", " ", text).strip()
    if len(text) > MAX_CHARS:
        cut = text[:MAX_CHARS]
        # Prefer a sentence boundary so it does not stop mid-word.
        dot = max(cut.rfind(". "), cut.rfind("! "), cut.rfind("? "))
        text = (cut[: dot + 1] if dot > MAX_CHARS // 2 else cut).strip()
    return text


def flatten_edges(a, sr, edge_s=0.7, max_gain_db=10.0):
    """Fix the quiet first/last syllables.

    Two distinct artefacts, measured rather than assumed:
      * the model appends silence tokens, so the tail decays to ~-55 dB — that
        part is padding and simply gets trimmed;
      * the real speech either side of it sits ~6 dB under the body of the
        utterance, which is audible as a swallowed opening or ending. Trimming
        cannot fix that, so the edges get a bounded gain correction.

    Gain is capped and applied only near the ends, so a genuinely soft ending
    is lifted without pumping the middle or amplifying the noise floor.
    """
    import numpy as np

    a = np.asarray(a, dtype=np.float32)
    if a.size < sr // 10:
        return a

    fl = max(1, int(sr * 0.03))                       # 30ms frames
    n = a.size // fl
    if n < 4:
        return a
    frames = a[: n * fl].reshape(n, fl)
    rms = np.sqrt(np.mean(frames.astype(np.float64) ** 2, axis=1))
    db = 20 * np.log10(np.maximum(rms, 1e-9))

    voiced_mask = db > (db.max() - 25)
    if voiced_mask.sum() < 2:
        return a
    target = np.median(db[voiced_mask])

    # 1. trim padding: keep from the first to the last frame carrying real signal
    live = np.flatnonzero(db > target - 30)
    lo, hi = live[0] * fl, min(a.size, (live[-1] + 1) * fl)
    a = a[lo:hi]
    db = db[live[0]: live[-1] + 1]
    n = db.size
    if n < 4:
        return a

    # 2. lift only the edges, and only where they sit below the body
    gain_db = np.zeros(n)
    edge_frames = max(1, int(edge_s / 0.03))
    deficit = np.clip(target - db, 0, max_gain_db)
    ramp = np.linspace(1.0, 0.0, edge_frames)         # full effect at the very ends
    k = min(edge_frames, n // 2)
    gain_db[:k] = deficit[:k] * ramp[:k]
    gain_db[n - k:] = deficit[n - k:] * ramp[:k][::-1]

    # smooth so the correction is inaudible as a level change
    if n >= 5:
        kern = np.ones(5) / 5.0
        gain_db = np.convolve(gain_db, kern, mode="same")

    per_sample = np.interp(np.arange(a.size), np.arange(n) * fl + fl / 2, gain_db)
    out = a * (10 ** (per_sample / 20.0))
    peak = float(np.max(np.abs(out))) or 1.0
    if peak > 0.99:                                    # never clip
        out *= 0.99 / peak
    return out.astype(np.float32)


def get_model():
    global _model
    if _model is None:
        from chatterbox.tts_turbo import ChatterboxTurboTTS
        t0 = time.perf_counter()
        _model = ChatterboxTurboTTS.from_pretrained(device="cuda")
        print(f"[voice] model warm in {time.perf_counter() - t0:.1f}s", flush=True)
    return _model


def select_voice(name: str | None) -> str | None:
    """Condition the model on a named voice; returns the name actually used."""
    global _current_voice
    cfg = load_voices()
    name = name or os.environ.get("VOICE_NAME") or cfg.get("default")
    if not name or name not in cfg.get("voices", {}):
        return _current_voice
    if name == _current_voice:
        return name                     # conditioning is the slow part; do it once
    ref = VOICE_HOME / "voices" / cfg["voices"][name]["file"]
    if not ref.exists():
        raise FileNotFoundError(f"voice '{name}' missing its reference at {ref}")
    get_model().prepare_conditionals(str(ref))
    _current_voice = name
    print(f"[voice] conditioned on '{name}'", flush=True)
    return name


def play(wav, sr: int, job_gen: int) -> bool:
    """Play the audio. Returns False when the job was cancelled and nothing played."""
    import numpy as np
    import sounddevice as sd
    # Do NOT clear the stop flag unconditionally here.
    #
    # Synthesis takes ~1s, and a /stop or an interrupting /speak arriving during
    # it used to be erased at this line: the flag was set, generate() never
    # looked at it, and play() wiped it before making a sound. The stop word was
    # therefore silently ignored for the whole synthesis window — worst exactly
    # when a long reply had just started and the operator wanted it cut.
    #
    # The generation counter is the fix: a cancel bumps _generation, so a job
    # whose generation is stale must not play at all.
    with _gen_lock:
        if job_gen != _generation:
            return False
        _stop_flag.clear()
    # Lead-in silence. Opening an output stream is not instantaneous, and on a
    # device that takes a moment to spin up the first samples are dropped —
    # which lands on the first word. Padding means the device swallows silence
    # instead. Costs 120ms of latency and saves the opening syllable.
    pad = np.zeros(int(sr * 0.12), dtype=wav.dtype)
    sd.play(np.concatenate([pad, wav]), samplerate=sr, device=DEVICE)
    # Poll rather than sd.wait() so /stop can cut in mid-utterance — the same
    # hook barge-in will need later.
    while sd.get_stream().active:
        if _stop_flag.is_set():
            sd.stop()
            return False        # cut short — not a completed utterance
        time.sleep(0.02)
    return True


def worker() -> None:
    global _pending
    while True:
        with _pending_cv:
            while _pending is None:
                _pending_cv.wait()
            job, _pending = _pending, None
        # Stamped at enqueue under _gen_lock, NOT re-read here: re-reading it
        # after the dequeue is what let a /stop in that window bless a job it
        # had just cancelled (CR round 7, [codex-adv-4]).
        job_gen = job["gen"]           # the generation this job belongs to

        try:
            text = normalise(job["text"])
            if not text:
                continue
            with _model_lock:
                used = select_voice(job.get("voice"))
                model = get_model()
                t0 = time.perf_counter()
                wav = model.generate(text)
                synth = time.perf_counter() - t0
            # Cancelled while we were generating — drop it rather than speak
            # something the operator already told us to stop.
            with _gen_lock:
                cancelled = job_gen != _generation
            if cancelled:
                # ASCII only: the Windows console is cp1252 and mangles an em-dash.
                print("[voice] cancelled during synthesis - not played", flush=True)
                continue
            audio = flatten_edges(wav.squeeze(0).cpu().numpy(), model.sr)
            dur = len(audio) / model.sr
            print(f"[voice] {used or 'default'}: {synth:.2f}s synth -> {dur:.2f}s audio", flush=True)
            _state["speaking"] = True
            # Count only what was actually HEARD (glm-7): a cancelled or
            # cut-short job used to increment `spoken`, so the health counter
            # over-reported and could not be used to tell whether a reply
            # reached the room.
            if play(audio, model.sr, job_gen):
                _state["spoken"] += 1
        except Exception as e:                        # never let the worker die
            _state["last_error"] = repr(e)
            print(f"[voice] ERROR {e!r}", file=sys.stderr, flush=True)
        finally:
            _state["speaking"] = False


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):        # default logging is one noisy line per request
        pass

    def _reply(self, code: int, payload: dict) -> None:
        body = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        if self.path != "/health":
            return self._reply(404, {"error": "not found"})
        cfg = load_voices()
        self._reply(200, {
            "ok": True,
            "model_loaded": _model is not None,
            "voice": _current_voice or cfg.get("default"),
            "voices": list(cfg.get("voices", {})),
            "device": DEVICE or "system default",
            **_state,
        })

    def do_POST(self):
        # BOTH globals must be declared. Without `_generation` here, the
        # `_generation += 1` below binds a LOCAL and raises UnboundLocalError,
        # 500-ing every /speak and /stop — and the symptom is silence, which
        # reads exactly like a working cancel. Found only by reading the log.
        global _pending, _generation
        # Refuse browser-driven requests (codex, rounds 9/12). The daemon binds
        # loopback, which stops the network but NOT the browser: any page you
        # visit can fetch('http://127.0.0.1:8788/speak') and make your speakers
        # say whatever it likes. Browsers always attach Origin to such a request;
        # curl, the loop, and the hook do not. So the presence of Origin is
        # exactly the signal, and rejecting it costs the real clients nothing.
        # This is not authentication — a local PROCESS is still trusted, which is
        # the same trust every other loopback tool on this machine assumes.
        if self.headers.get("Origin"):
            return self._reply(403, {"error": "cross-origin requests are refused"})

        # Validate the length before reading it. A non-numeric header used to
        # raise ValueError out of int() and 500 the handler, and a huge one
        # would have had us read it all into memory. 64 KiB is far above any
        # real utterance.
        raw_len = self.headers.get("Content-Length") or "0"
        try:
            n = int(raw_len)
        except ValueError:
            return self._reply(400, {"error": "invalid Content-Length"})
        if n < 0 or n > 65536:
            return self._reply(413, {"error": "body too large"})
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except json.JSONDecodeError:
            return self._reply(400, {"error": "body must be JSON"})
        # `json.loads("[]")` and `"3"` both parse; the handlers below then call
        # .get() on a list or an int and 500.
        if not isinstance(body, dict):
            return self._reply(400, {"error": "body must be a JSON object"})

        if self.path == "/stop":
            # Both under ONE lock (glm-4): setting the flag outside it let
            # play() clear the flag between the set and the generation bump, so
            # the cancel landed in the gap and was lost.
            with _gen_lock:
                _stop_flag.set()
                _generation += 1        # invalidates any job mid-synthesis
            with _pending_cv:
                _pending = None
            return self._reply(200, {"ok": True, "stopped": True})

        if self.path != "/speak":
            return self._reply(404, {"error": "not found"})

        text = (body.get("text") or "").strip()
        if not text:
            return self._reply(400, {"error": "text is required"})

        # Default to interrupting: the newest reply supersedes an older one that
        # has not finished. Pass interrupt=false to let the current line finish.
        with _gen_lock:                 # one lock, same race as /stop (glm-4)
            if body.get("interrupt", True):
                _stop_flag.set()
                _generation += 1        # supersede anything already generating
            # Stamp the job with its generation HERE, at enqueue (CR round 7,
            # [codex-adv-4]). The worker used to snapshot `_generation` itself
            # after dequeuing, which left a window: a /stop landing between the
            # dequeue and the snapshot bumped the counter, the worker then read
            # the POST-stop value, generations matched, and the cancelled job
            # played anyway. A generation captured at enqueue can only ever be
            # invalidated by a later bump, never blessed by one.
            job_gen = _generation
            # Stamp AND enqueue in ONE critical section (CR round 9). Splitting
            # them left a window between two ThreadingHTTPServer handlers:
            # request A stamps generation 1, B advances to 2 and stores B, then
            # A overwrites _pending with its stale job. The worker drops A as
            # cancelled and B has already been erased — both callers got their
            # 202 and nothing is ever spoken. Lock order is _gen_lock ->
            # _pending_cv here; the worker takes only _pending_cv and /stop takes
            # only _gen_lock, so there is no cycle to deadlock on.
            with _pending_cv:
                _pending = {"text": text, "voice": body.get("voice"), "gen": job_gen}
                _pending_cv.notify()
        # Return immediately — a Stop hook must not block the session for the
        # length of the speech.
        self._reply(202, {"ok": True, "queued": True})


def main() -> int:
    cfg = load_voices()
    if not cfg.get("voices"):
        # Start anyway. Chatterbox has its own built-in voice, and select_voice()
        # already handles an empty config by returning WITHOUT conditioning the
        # model — so everything downstream works untouched. Refusing to start
        # here made a reference clip mandatory in practice while the rest of the
        # code treated it as optional, which is the wrong default for anyone who
        # has not got a clip they have the right to clone. Note this is stdout,
        # not stderr: it is ordinary operation, not a degraded mode.
        print(f"[voice] no voices configured in {VOICE_HOME / 'voices.json'} — "
              "using Chatterbox's built-in voice", flush=True)

    threading.Thread(target=worker, daemon=True).start()

    def _preload() -> None:
        # `with`, not a manual acquire/release pair: select_voice() can raise
        # (missing reference file, CUDA failure), and a bare release() that is
        # never reached leaves the lock held FOREVER — every later /speak then
        # blocks on it and the daemon is silently dead while /health still says
        # ok. The exception is swallowed here on purpose: a preload failure
        # should cost the warm start, not the service, and the first real
        # /speak will surface the same error through the worker's error path.
        try:
            with _model_lock:
                select_voice(None)
        except Exception as e:
            _state["last_error"] = repr(e)
            print(f"[voice] preload failed ({e!r}) — model will load on first request",
                  file=sys.stderr, flush=True)

    if os.environ.get("VOICE_PRELOAD", "1") == "1":
        # Pay the ~18s warm-up at startup, which is the entire point of a daemon.
        threading.Thread(target=_preload, daemon=True).start()

    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    # .get(), not cfg["voices"]: the guard above tests .get(), so a config
    # lacking the key entirely reaches here — and it could not before, because
    # the removed `return 1` bailed first. Dropping that guard turned a
    # tolerated shape into a KeyError at startup.
    _names = ", ".join(cfg.get("voices") or {}) or "built-in only"
    print(f"[voice] listening on 127.0.0.1:{PORT} (voices: {_names})", flush=True)
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\n[voice] shutting down", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
