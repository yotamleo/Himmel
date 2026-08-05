#!/usr/bin/env bash
# Stop hook: speak the reply through the local voice daemon (HIMMEL-1522). BETA.
#
# OFF BY DEFAULT, and deliberately so. This is a FEATURE GATE, not a setting we
# expect to leave on: it exists so voice can be tried per-session while the real
# wake-word mechanism is still being built, and it is expected to be replaced by
# proper configuration when that lands (operator, 2026-08-04). Nothing here runs
# unless VOICE_SPEAK=1 is set in the shell that LAUNCHED claude — a hook reads
# its own environment, so a per-call prefix cannot work:
#
#     VOICE_SPEAK=1 claude          # replies spoken for this session only
#     claude                        # silent, exactly as before
#
# The primary path is the /speak slash command, which needs none of this and is
# always available. Prefer it. This hook only removes the need to ask.
#
# Zero token cost: it reads the transcript the harness already wrote and POSTs
# to a local daemon. No model call.
set -uo pipefail

# GATE FIRST, before any work at all. A Stop hook runs on every single turn of
# every session in this repo, so the disabled path must be indistinguishable
# from not being installed.
[ "${VOICE_SPEAK:-}" = "1" ] || exit 0

payload="$(cat)"
[ -n "$payload" ] || exit 0

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
speak="${here}/../voice/speak.sh"
[ -f "$speak" ] || exit 0

# Pull the last assistant text out of the transcript.
#
# WHAT GETS SPOKEN. A terminal reply is long and full of markdown; read aloud
# verbatim it is unbearable, and summarising it would cost a model call on every
# turn. So: if the reply carries an inline <speak>...</speak> block, that block
# is spoken and the full text still goes to the screen untouched — the model
# chooses the spoken length per turn at no extra cost. With no such block we
# speak a trimmed opening rather than the whole thing.
# SC2016: the single quotes are the point — this is python source, not shell, and
# nothing in it should be expanded by bash. The backticks shellcheck spots are a
# markdown code-fence regex, not command substitution. The payload reaches python
# through the environment precisely so it is never interpolated into the source.
# shellcheck disable=SC2016
text="$(HOOK_PAYLOAD="$payload" python -c '
import json, os, re, sys

try:
    hook = json.loads(os.environ["HOOK_PAYLOAD"])
except Exception:
    sys.exit(0)

path = hook.get("transcript_path")
if not path or not os.path.exists(path):
    sys.exit(0)

# Read only the TAIL. This hook fires every turn, and a long session transcript
# reaches tens of megabytes — parsing all of it each time is O(n) per turn and
# O(n-squared) over the session, which would put a growing delay in front of
# every reply. The last assistant message is by definition near the end, so seek
# back a fixed window and parse only that. First line of the window is dropped:
# a byte-offset seek almost certainly lands mid-line.
TAIL_BYTES = 512 * 1024
last = ""
try:
    with open(path, "rb") as fh:
        fh.seek(0, os.SEEK_END)
        size = fh.tell()
        start = max(0, size - TAIL_BYTES)
        fh.seek(start)
        chunk = fh.read()
    lines = chunk.decode("utf-8", errors="replace").splitlines()
    if start > 0 and lines:
        lines = lines[1:]
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except Exception:
            continue
        if rec.get("type") != "assistant":
            continue
        content = rec.get("message", {}).get("content", [])
        if isinstance(content, list):
            parts = [c.get("text", "") for c in content
                     if isinstance(c, dict) and c.get("type") == "text"]
            joined = "\n".join(p for p in parts if p)
            if joined.strip():
                last = joined
except Exception:
    sys.exit(0)

if not last.strip():
    sys.exit(0)

m = re.search(r"<speak>(.*?)</speak>", last, re.S | re.I)
if m:
    out = m.group(1)
else:
    # No explicit block. Drop fenced code (never speakable), then take the
    # opening prose and cap it -- the daemon truncates too, but doing it here
    # keeps what we send honest about what will be heard.
    body = re.sub(r"```.*?```", " ", last, flags=re.S)
    body = re.sub(r"^\s*[#>|\-*]+\s*", "", body, flags=re.M)   # heading/list/quote marks
    body = re.sub(r"[`*_~]", "", body)                          # inline emphasis
    out = " ".join(body.split())[:400]

print(" ".join(out.split()))
' 2>/dev/null)" || text=""

[ -n "${text// /}" ] || exit 0

# Never let speech failure affect the session: speak.sh is already non-fatal,
# and this belt-and-braces keeps a broken python or curl from surfacing here.
bash "$speak" "$text" >/dev/null 2>&1 || true
exit 0
