#!/usr/bin/env python3
"""Agent Reach router stand-in for the bench (HIMMEL-4362). Agent Reach v1.5.0
(Panniantong/Agent-Reach, installed from its release tag in a venv on a test VM)
is a skill plus a doctor, not a read CLI: its SKILL.md routes each platform to a
per-platform tool. This adapter runs those documented zero-config commands for
the platforms they cover and exits 77 (needs-auth) for those that want cookies
or a login, so the bench can drive it like any other provider:

  bench.py --provider cmd --name agent-reach --cmd 'python3 agent_reach_adapter.py {url}'

Routes (from the installed skill/references/*.md):
  youtube.com / youtu.be   yt-dlp --dump-json            (keyless)
  github.com               gh CLI                        (needs `gh auth login`: 77 when unauthenticated)
  x.com / twitter.com      twitter-cli                   (cookies: 77)
  reddit.com               rdt-cli                       (login: 77)
  anything else            curl https://r.jina.ai/<url>  (the documented 'any web page' command)
Stdlib only. Prints markdown to stdout; never prints a secret."""
import json
import subprocess
import sys
from urllib.parse import urlparse

NEEDS_AUTH = 77


def run(argv, timeout=100):
    return subprocess.run(argv, capture_output=True, text=True, timeout=timeout)


def youtube(url):
    p = run(["yt-dlp", "--dump-json", "--no-warnings", url])
    if p.returncode != 0:
        sys.stderr.write("yt-dlp failed\n")
        return 1
    d = json.loads(p.stdout)
    print("# %s\n\n%s - %s views\n\n%s" % (d.get("title", ""), d.get("uploader", ""),
                                          d.get("view_count", ""), d.get("description", "")))
    return 0


def github(url):
    parts = [x for x in urlparse(url).path.split("/") if x]
    if len(parts) < 2:
        return 1
    repo = "%s/%s" % (parts[0], parts[1])
    if len(parts) >= 4 and parts[2] in ("issues", "pull") and parts[3].isdigit():
        argv = ["gh", "issue" if parts[2] == "issues" else "pr", "view", parts[3], "-R", repo]
    elif len(parts) == 2:
        argv = ["gh", "repo", "view", repo]
    else:  # blob/tree/other paths: gh has no keyless file read here, so use the generic web route
        return web(url)
    p = run(argv)
    err = p.stderr.lower()
    if p.returncode != 0:
        return NEEDS_AUTH if ("gh auth login" in err or "authentication" in err) else 1
    print(p.stdout)
    return 0


def web(url):
    p = run(["curl", "-sf", "-m", "60", "-L", "https://r.jina.ai/" + url], timeout=90)
    if p.returncode != 0:
        return 1
    out = p.stdout
    marker = "Markdown Content:"
    print(out[out.find(marker) + len(marker):].strip() if marker in out else out.strip())
    return 0


def main(url):
    host = (urlparse(url).hostname or "").lower()
    def on(*domains):
        return any(host == d or host.endswith("." + d) for d in domains)
    if on("youtube.com", "youtu.be"):
        return youtube(url)
    if host in ("github.com", "www.github.com"):
        return github(url)
    if on("x.com", "twitter.com", "reddit.com"):
        return NEEDS_AUTH
    return web(url)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
