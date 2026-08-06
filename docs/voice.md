# Voice I/O — BETA

> **BETA — detached feature, opt-in, not part of the himmel install.**
> Nothing here runs unless you start it by hand. It is not managed by
> `himmelctl`, it is not in the adopter settings template, and merging it
> changes the behaviour of exactly one thing: it adds a `/speak` command.
> HIMMEL-1522.

Local speech for the agent: it speaks replies aloud, and it can listen.

**What stays local, precisely.** Speech recognition and synthesis both run on
this machine, so **the audio never leaves it** — no recording, no voice, nothing
a cloud speech API would receive. That is the whole point of running the models
here rather than calling a hosted service.

**The transcript is a different question, and the answer is no.** Once whisper
turns your speech into text, that text is sent to Claude exactly as a typed
prompt would be. Speaking to the agent is not more private than typing to it;
it is the same egress with a different keyboard. What local models buy you is
that the *sound of the room* never becomes something that could be sent —
which matters because the salus perimeter keys on file paths, and audio has
none. See [HIMMEL-1548](#known-limits) for the consequence: while `jarvis.py` is
listening, anything said near the microphone can become such a transcript.

## What merging actually changes

| | |
|---|---|
| `/speak` | New slash command, available immediately. Needs the daemon running to make sound; without it, it says so and does nothing else. |
| `Stop` hook | Present in `.claude/settings.json`, runs on every turn, and **exits on its first line** unless `VOICE_SPEAK=1`. A session without that variable is byte-identical to before. |
| Everything else | Unchanged. The daemon, the wake word and push-to-talk are scripts you launch. |

**It does not work on a fresh clone** — but only because of the runtime, not the
voice. The Python venv and the Chatterbox model live in `~/.himmel/voice/`,
which is untracked; a new machine gets the scripts and none of that. Work
through [Install](#install), which is a one-time job.

You do **not** need to supply any audio. With no `voices.json` the daemon speaks
in Chatterbox's own built-in voice, and that is the default a fresh install
gets. A reference clip is an optional override, and this repo ships none by
design — see [step 4](#4-optional-supply-your-own-voice).

**Adopters get nothing**, by design. `docs/setup/settings-template.json` carries
no voice hook, so installing himmel into another project does not install voice.

**`himmelctl` is deliberately blind to it.** Voice is not an install item, so
`himmelctl status` will not report it missing and `himmelctl ensure` will not set
it up or repair it. That is the correct state for a beta — it means voice cannot
break a reconcile, and a broken voice install cannot make `status` go red. When
voice graduates out of beta, becoming a `himmelctl` item is the change that marks
it.

## Using it

### Speak on demand — the normal path

```
/speak                       # speak a condensed version of the last reply
/speak the build is green    # speak exactly this
```

`/speak` needs no configuration and no hook. With no argument, the model writes
the spoken line as part of the turn it was already writing — no summariser call
and no extra tokens.

Straight from the shell, no Claude involved:

```bash
bash scripts/voice/speak.sh "hello there"
echo "or from stdin" | bash scripts/voice/speak.sh
VOICE_NAME=myvoice bash scripts/voice/speak.sh "a different voice"
```

`speak.sh` is deliberately non-fatal: if the daemon is not running it prints one
line to stderr and exits 0, so it can never fail whatever called it.

### Speak every reply — the feature gate

```bash
VOICE_SPEAK=1 claude          # this session speaks its replies
claude                        # silent, as always
```

Set it in the shell that **launches** claude — a hook reads its own environment,
so a per-call prefix cannot work.

This is a **feature gate, not a setting**. It exists so voice can be lived with
per-session while the wake-word mechanism is built, and it is expected to be
replaced by real configuration when that lands. Do not treat it as the permanent
way to enable voice.

What gets spoken: if a reply contains an inline `<speak>…</speak>` block, that
block is spoken and the full text still reaches the screen untouched. Otherwise
the opening prose is spoken with code fences and markdown stripped, capped at
400 characters.

### The daemon

Everything above needs this running. It holds the model warm in VRAM — loading
Chatterbox takes seconds, so spawning it per sentence would make its ~75 ms
synthesis meaningless.

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" scripts\voice\speech-daemon.py
```

`POST /speak`, `POST /stop`, `GET /health` on `127.0.0.1:8788` (`VOICE_PORT`
to change). It refuses any request carrying an `Origin` header, so a web page
cannot drive your speakers.

### Listening

```powershell
.\scripts\voice\voice-loop.ps1 -Voice myvoice -Repeat -Continue  # full spoken turn
.\scripts\voice\ptt.ps1                                          # push-to-talk → clipboard
& "$HOME\.himmel\voice\venv\Scripts\python.exe" scripts\voice\jarvis.py
```

- **`voice-loop.ps1`** — speak, a Claude run answers, the answer is spoken back.
  `-Continue` carries context across turns of that invocation only. ENTER sends
  early. Expect 10–30 s per turn; that is Claude's cold start, not the voice
  layer (HIMMEL-1537).
- **`jarvis.py`** — say "jarvis" to wake, "stop" or "shut off" to cut it off.
- **`ptt.ps1`** — hold, talk, release; the transcript lands on the clipboard.

## Install

Runnable top to bottom on a machine that has never had voice.

**An NVIDIA GPU is required, not merely recommended.** Both models request CUDA
explicitly and neither has a CPU branch — `speech-daemon.py` loads
`ChatterboxTurboTTS.from_pretrained(device="cuda")` and `jarvis.py` loads
`WhisperModel(..., device="cuda")`. On a CPU-only machine they do not run
slowly; they fail at model load. If you need CPU support, that is a code change
to both files, not a configuration option.

### 1. Create the venv — its own, not another tool's

```powershell
mkdir "$HOME\.himmel\voice" -Force
python -m venv "$HOME\.himmel\voice\venv"
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -m pip install --upgrade pip
```

Deliberately **not** hermes's venv: that one carries CPU-only torch and belongs
to another tool. Sharing them means `device="cuda"` raises at model load — not a
quiet fallback, an outright failure, and one whose message points at the model
rather than at the venv you reused.

### 2. Install torch — `cu126`, not `cu128`

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -m pip install `
    torch==2.6.0 torchaudio==2.6.0 --index-url https://download.pytorch.org/whl/cu126
```

`chatterbox-tts` pins `torch==2.6.0` **exactly**, and CUDA wheels for that
version exist on cu118/cu124/cu126 only. `cu128` will not resolve, and the error
does not say why. A modern driver runs cu126 fine — CUDA is backward-compatible.

Confirm it actually sees the GPU before continuing:

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -c "import torch; ok = torch.cuda.is_available(); print(ok, torch.cuda.get_device_name(0) if ok else 'no CUDA device')"
```

The `if ok` guard is load-bearing: `get_device_name(0)` *raises* when CUDA is
unavailable, so the unguarded form gives a traceback on exactly the machines
this check exists to catch — and a traceback is easy to misread as a broken
install rather than a CPU-only one.

`False` means **stop here**. Neither model has a CPU branch, so everything after
this point fails at model load rather than running slowly. Get this to `True`
before installing anything else.

### 3. Install Chatterbox — with `setuptools` pinned

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -m pip install "setuptools<81"
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -m pip install chatterbox-tts sounddevice soundfile numpy
```

Chatterbox still imports `pkg_resources`, and fresh venvs may ship no setuptools
at all. Install the pin **first** — letting Chatterbox pull an unpinned one gets
you an ImportError at model load, long after the install appeared to succeed.

On the exact bound: upstream removed `pkg_resources` in **setuptools 82.0.0**,
and 81 still ships it (deprecated), so `<82` is the strictly correct constraint.
`<81` is what was actually verified working here, and it is kept because a pin
that is one minor tighter than necessary costs nothing, while loosening a
known-good one on the strength of a changelog is how install guides start
failing for the next person. If you have a reason to want 81, it should work.

### 4. (Optional) Supply your own voice

**Skip this and it still works.** With no `voices.json`, `select_voice()` returns
without conditioning the model and Chatterbox speaks in its own built-in voice.
That is the default, it needs no audio from you, and it is what a fresh install
gets.

A reference clip *overrides* that default by cloning a voice you supply. If you
want one:

> Use a voice you have the right to clone — your own recording, a licensed or
> public-domain sample, or a synthetic one. Cloning a real person's voice from
> copyrighted material is an infringement, and for an identifiable person it is
> a consent problem regardless of where the audio came from. That is why this
> repo ships **no** reference audio and never will.

Drop a clean 5–15 s WAV (one speaker, no music, no background) under
`~/.himmel/voice/voices/`, then write `~/.himmel/voice/voices.json`:

```json
{
  "default": "myvoice",
  "voices": {
    "myvoice": { "file": "myvoice.wav" }
  }
}
```

The key is **`file`** and the path is resolved relative to
`~/.himmel/voice/voices/` — that is what `select_voice()` reads
(`VOICE_HOME / "voices" / cfg["voices"][name]["file"]`). A missing file there is
a hard error naming the path, not a silent fallback to the built-in voice.

`voices.json` and everything under `voices/` are **never repo-tracked** — that
directory is yours and stays local.

### 5. Smoke-test before anything else

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" scripts\voice\speech-daemon.py
```

In a second shell:

```bash
curl -s http://127.0.0.1:8788/health
bash scripts/voice/speak.sh "if you can hear this, the hard part is done"
```

First synthesis loads the model and takes a few seconds; after that it is
~75 ms. If you hear it, the rest of this document works. If you do not, stop
here — everything else assumes this step.

### 6. For listening, pick the right microphone

`jarvis.py` and `ptt.ps1` need a **real** input device. Choose the physical jack
or USB interface, *not* a loopback/"stereo mix"/"what-U-hear" device — those
capture system output, so the assistant records itself and answers its own
voice, which looks exactly like a wake-word bug and is not one.

```powershell
& "$HOME\.himmel\voice\venv\Scripts\python.exe" -c "import sounddevice; print(sounddevice.query_devices())"
```

Speech recognition uses whisper.cpp / faster-whisper, which is a separate
install — see the STT setup in [`setup/new-machine.md`](setup/new-machine.md).

## Permission envelope

A voice session runs under a **narrower** envelope than the one you type in,
because the channel cannot authenticate its speaker — Whisper transcribes
whoever is in the room, including a guest or a video.

- `--permission-mode plan` — blocks writes.
- `--settings scripts/voice/voice-permissions.json` — blocks reads of secrets,
  salus, and the session-transcript store. Patterns are filesystem-anchored
  (`//**/…`), which matters: a bare pattern resolves relative to the project root
  and covers nothing outside the repo.
- `--strict-mcp-config` with no `--mcp-config` — zero MCP servers. A permission
  rule names a *tool*, and an MCP tool's name is chosen by its server, so no
  pattern in the profile could ever reach one.
- `Bash` and `PowerShell` both denied outright.

`/speak` itself is **output only** — it sends text to a loopback daemon and
grants nothing. It does not run under the voice profile, because it is you
typing.

## Known limits

| | |
|---|---|
| HIMMEL-1535 | The **confirm** tier is not built. Plan mode refuses those actions outright rather than speaking a confirmation back — safe, but not the designed behaviour. |
| HIMMEL-1536 | No shell at all by voice, so no CI checks and no `git status`. A narrow read-only allow-list would restore the useful part. |
| HIMMEL-1537 | 10–30 s per turn, all of it Claude's cold start. |
| HIMMEL-1548 | A wake phrase is not proof of deliberate address — anything said near the mic while `jarvis.py` runs can reach the cloud. Bounded today because you launch it by hand. |
| HIMMEL-1549 | The read-side profile is still a deny-list, and does not yet deliver the policy's hard `secrets` guarantee. Its own header says so. |
