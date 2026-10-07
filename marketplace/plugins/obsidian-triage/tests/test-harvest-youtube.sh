#!/usr/bin/env bash
# HIMMEL-4677: a bare YouTube watch link (Telegram-clipped, skeleton body) must
# get its metadata + transcript from the cookieless Scrapling path DURING the
# harvest batch, not be left as a thin-body partial. The clip below is the shape
# of the operator's evidence clip (UzMNBN6xLLA) before harvest. The scrapling
# python is a stub that records its argv and prints canned helper JSON.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
tool="$here/../tools/harvest-clip-body-batch.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/harvest-youtube.XXXXXX")" || exit 1; trap 'rm -rf "$tmp"' EXIT

cat > "$tmp/ok.json" <<'JSON'
{"status": "ok", "title": "Probe Talk", "channel": "Probe Channel", "duration": "12:34",
 "views": "1000", "published": "2026-10-01", "description": "A talk about probes.",
 "transcript": [{"ts": "0:00", "tx": "hello probe"}, {"ts": "0:05", "tx": "second line"}],
 "transcript_source": "yt-dlp", "transcript_error": null}
JSON
cat > "$tmp/notx.json" <<'JSON'
{"status": "ok", "title": "Probe Talk", "channel": "Probe Channel", "duration": "", "views": "",
 "published": "", "description": "", "transcript": [], "transcript_source": "yt-dlp",
 "transcript_error": "transcript_empty"}
JSON
echo '{"status": "login_wall", "detail": "LOGIN_REQUIRED"}' > "$tmp/wall.json"
# HIMMEL-4722: status ok but the wrong field types must not crash the render.
echo '{"status": "ok", "title": "Probe Talk", "channel": "Probe Channel", "description": ["x"], "transcript": ["hello"]}' > "$tmp/badtypes.json"
cat > "$tmp/scrapling-python" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_ARGS"
cat "$STUB_JSON"
exit "${STUB_RC:-0}"
STUB
chmod +x "$tmp/scrapling-python"

cat > "$tmp/t.py" <<'PY'
import importlib.util, os, sys
from pathlib import Path

tool, tmp = sys.argv[1], Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("harvest_batch", tool)
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.TODAY = "2026-10-07"
fails = []


def check(name, cond, detail=""):
    print(("ok   " if cond else "FAIL ") + name)
    if not cond:
        fails.append(name)
        if detail:
            print(detail)


def clip(vault):
    d = tmp / vault / "Clippings"
    d.mkdir(parents=True)
    p = d / "telegram-tg-1791335772-youtube-from-youtube-com-watch.md"
    p.write_text(
        "---\n"
        'title: "youtube from youtube.com/watch"\n'
        "source: https://www.youtube.com/watch?v=UzMNBN6xLLA\n"
        "date_clipped: 2026-10-07\n"
        "type: youtube\n"
        "tags:\n  - youtube\n"
        "status: unread\n"
        "clipped_via: telegram\n"
        "---\n\n"
        "# youtube from youtube.com/watch\n\n"
        "https://www.youtube.com/watch?v=UzMNBN6xLLA\n\n"
        "## Source\n"
        "[https://www.youtube.com/watch?v=UzMNBN6xLLA](https://www.youtube.com/watch?v=UzMNBN6xLLA)\n",
        encoding="utf-8")
    return p


def fm(p):
    return mod.parse_frontmatter(p.read_text(encoding="utf-8"))[0]


def run(vault, stub_json, rc="0", dry=False):
    os.environ["STUB_JSON"] = str(tmp / stub_json)
    os.environ["STUB_RC"] = rc
    os.environ["STUB_ARGS"] = str(tmp / f"{vault}.args")
    p = clip(vault)
    g, msg, _ = mod.process_clip(p, dry_run=dry)
    return p, g, msg


os.environ.pop("HIMMEL_MEDIA_COOKIES", None)
os.environ["YT_SCRAPLING_PYTHON"] = str(tmp / "scrapling-python")

p, g, msg = run("v1", "ok.json")
text = p.read_text(encoding="utf-8")
check("bare youtube clip harvested ok", g == "v" and fm(p).get("harvest_status") == "ok", f"{g} {msg}\n{text}")
check("harvest_skill youtube-scrapling", fm(p).get("harvest_skill") == "youtube-scrapling", text)
check("title + channel written", "Probe Talk" in text and "Probe Channel" in text, text)
check("transcript written", "hello probe" in text and "second line" in text, text)
check("no thin-body flag", "harvest_flag" not in fm(p), text)
check("Harvested content before Source", text.index("## Harvested content") < text.index("## Source"), text)
args = (tmp / "v1.args").read_text()
check("helper gets the video id + vault", "--video-id UzMNBN6xLLA" in args and f"--vault {tmp / 'v1'}" in args, args)
check("no cookie handed to the helper", "cookie" not in args.lower(), args)

p, g, msg = run("v2", "notx.json")
text = p.read_text(encoding="utf-8")
check("metadata without transcript still ok", g == "v" and "Probe Talk" in text, f"{g} {msg}\n{text}")
check("missing transcript named", "transcript_empty" in text, text)

p, g, msg = run("v3", "wall.json", rc="4")
check("login wall stays a deferred thin partial", g == "~" and "deferred 1/5" in msg
      and fm(p).get("harvest_flag") == "thin-body", msg)
check("partial message names the youtube miss", "youtube-scrapling" in msg and "login_wall" in msg, msg)

p, g, msg = run("v4", "ok.json", dry=True)
check("dry-run writes nothing", g == "v" and "dry-run" in msg and "harvest_status" not in fm(p), msg)
check("dry-run never calls the helper", not (tmp / "v4.args").exists())

p, g, msg = run("v6", "ok.json", rc="5")
check("non-zero helper exit is not a harvest", g == "~" and "deferred 1/5" in msg, msg)

# The evidence clip as harvest left it: a deferred thin-body partial. A retry
# that harvests it must not keep the stale thin-body flag beside status ok.
os.environ["STUB_JSON"] = str(tmp / "ok.json")
os.environ["STUB_RC"] = "0"
os.environ["STUB_ARGS"] = str(tmp / "v7.args")
p = clip("v7")
p.write_text(p.read_text(encoding="utf-8").replace(
    "clipped_via: telegram\n",
    "clipped_via: telegram\nharvest_status: partial\nharvest_flag: thin-body\nharvest_defer_count: 1\n"),
    encoding="utf-8")
g, msg, _ = mod.process_clip(p, dry_run=False)
check("retried partial harvested ok", g == "v" and fm(p).get("harvest_status") == "ok", msg)
check("stale thin-body flag cleared", "harvest_flag" not in fm(p), p.read_text(encoding="utf-8"))

p, g, msg = run("v8", "badtypes.json")
check("malformed ok payload stays a deferred thin partial", g == "~" and "deferred 1/5" in msg
      and "malformed payload" in msg and fm(p).get("harvest_flag") == "thin-body", msg)

os.environ["YT_SCRAPLING_PYTHON"] = str(tmp / "absent-python")
p, g, msg = run("v5", "ok.json")
check("no scrapling python: deferred partial", g == "~" and "deferred 1/5" in msg, msg)

sys.exit(1 if fails else 0)
PY
python3 "$tmp/t.py" "$tool" "$tmp"
