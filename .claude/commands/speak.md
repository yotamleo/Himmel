---
description: BETA — speak text aloud through the local voice daemon; the last reply by default, or whatever you pass. Detached.
argument-hint: [text to speak]
---

Speak through the local voice daemon (HIMMEL-1522). This is the **primary**
voice-output path and needs no hook, no configuration, and no always-on state —
you ask, it speaks.

> **BETA.** Voice is a detached, opt-in feature: not managed by `himmelctl`, not
> in the adopter settings template, and it needs a local runtime that is not in
> the repo. If the daemon is not running this command says so and does nothing
> else. Setup + direct script usage: [`docs/voice.md`](../../docs/voice.md).

## What to do

1. Decide the text:
   - **`$ARGUMENTS` non-empty** → speak exactly that.
   - **`$ARGUMENTS` empty** → speak your own most recent reply in this session.
     Do NOT re-read the transcript to find it; you already know what you just
     said. Condense it to something worth hearing out loud: 1–3 sentences,
     no markdown, no code, no URLs, no file paths. A spoken sentence is not a
     terminal line — read it back to yourself before sending it.

2. Send it:

   ```bash
   bash scripts/voice/speak.sh "<the text>"
   ```

   `VOICE_NAME=<name>` picks a voice, where the names are whatever the operator
   put in their own `~/.himmel/voice/voices.json`. With no such file the daemon
   uses Chatterbox's built-in voice, which needs no setup. Set `VOICE_PORT` if
   the daemon is not on its default port.

3. Report in one line what was spoken. Do not paste the text back in full — it
   is already on screen, and the point of speaking is to not need to read it.

## Notes

- **The daemon must be running.** If it is not, `speak.sh` says so on stderr and
  exits 0 — speech never fails the thing that asked for it. Start it with:

  ```powershell
  & "$HOME\.himmel\voice\venv\Scripts\python.exe" scripts\voice\speech-daemon.py
  ```

- **Zero token cost beyond this turn.** No summariser call, no second model
  pass — you write the spoken line yourself as part of the reply you were
  already writing.
- To have every reply spoken automatically instead of asking, the `Stop` hook
  in `scripts/hooks/speak-reply.sh` does that, but only when `VOICE_SPEAK=1` is
  set in the shell that launched claude. It is a temporary feature gate, not a
  permanent setting — it is expected to be replaced by real configuration when
  the wake-word mechanism lands.
- Voice-ORIGINATED sessions (the `jarvis.py` / `voice-loop.ps1` path) run under
  a much narrower permission profile than this command does. `/speak` is output
  only: it sends text to a loopback daemon and grants nothing.
