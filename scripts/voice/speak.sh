#!/usr/bin/env bash
# Speak text through the local voice daemon (HIMMEL-1522). BETA.
#
# BETA: voice is a detached, opt-in feature. It is not a himmelctl install item,
# so `himmelctl status` will not report it and `ensure` will not repair it, and
# it needs a runtime (venv + model + voices) under ~/.himmel/voice that is NOT in
# the repo. Setup and direct usage: docs/voice.md.
#
# The one place that knows how to reach the daemon. Both callers use it:
#   - /speak            the slash command, the primary and always-available path
#   - speak-reply.sh    the Stop hook, which only runs when VOICE_SPEAK=1
#
# Text comes from argv, or from stdin when no argv is given:
#   bash scripts/voice/speak.sh "hello"
#   echo "hello" | bash scripts/voice/speak.sh
#
# Deliberately quiet and non-fatal. Speech is a convenience layer; a daemon that
# is not running must never fail the thing that asked to speak. Every failure
# path prints one line to stderr and exits 0, EXCEPT usage errors (exit 2).
set -uo pipefail

port="${VOICE_PORT:-8788}"
daemon="http://127.0.0.1:${port}"

text="${*:-}"
if [ -z "$text" ] && [ ! -t 0 ]; then
    text="$(cat)"
fi
if [ -z "${text// /}" ]; then
    echo "speak: nothing to say (pass text as an argument or on stdin)" >&2
    exit 2
fi

if ! command -v curl >/dev/null 2>&1; then
    echo "speak: curl not found - cannot reach the voice daemon" >&2
    exit 0
fi

# Build the JSON body with python rather than string interpolation: a reply
# containing a double quote, a backslash or a newline would otherwise produce
# invalid JSON and the daemon would 400 on perfectly ordinary text.
# Resolve a JSON-capable interpreter once: prefer python3 (macOS/Linux ship
# only python3 in many cases), fall back to the legacy `python` alias. A bare
# `python` is frequently absent, which made the encode below silently fail.
if command -v python3 >/dev/null 2>&1; then
    py="python3"
elif command -v python >/dev/null 2>&1; then
    py="python"
else
    echo "speak: no python interpreter found (install python3) - cannot encode JSON" >&2
    exit 0
fi
body="$(VOICE_TEXT="$text" "$py" -c '
import json, os
t = os.environ["VOICE_TEXT"]
payload = {"text": t}
v = os.environ.get("VOICE_NAME")
if v:
    payload["voice"] = v
print(json.dumps(payload))
' 2>/dev/null)" || body=""

if [ -z "$body" ]; then
    echo "speak: could not encode the text as JSON (is python on PATH?)" >&2
    exit 0
fi

code="$(printf '%s' "$body" | curl -sS -o /dev/null -w '%{http_code}' \
    --max-time 15 \
    -X POST "${daemon}/speak" \
    -H 'Content-Type: application/json' \
    --data-binary @- 2>/dev/null)" || code=""

case "$code" in
    202|200) exit 0 ;;
    "")      echo "speak: no voice daemon on ${daemon} - start speech-daemon.py to hear replies" >&2; exit 0 ;;
    *)       echo "speak: daemon returned HTTP ${code}" >&2; exit 0 ;;
esac
