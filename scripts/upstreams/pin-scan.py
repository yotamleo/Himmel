#!/usr/bin/env python3
"""pin-scan.py — discover every third-party pin in the repo and compare each to
its latest STABLE release (HIMMEL-3807). Called by scripts/check-plugin-drift.sh.

Discovery is by scanning, not by a hand-kept list, so a new package, hook rev
or action is watched from the day it lands:
  npm     every package.json dependency, at the version its lockfile resolves
          (package-lock.json or bun.lock); the OXLINT_VERSION= literal in
          scripts/hooks/*.sh is also an npm pin (oxlint)
  gh      every pre-commit `repo:`/`rev:` pair and the gitleaks `ver=` literal
          a workflow downloads (workflow `uses:` is Dependabot's, not scanned)
  pypi    every `pip install <pkg>==<ver>` literal in a workflow

Latest comes from the npm registry (`curl`) or `gh api` — both looked up via
PATH so the test harness can stub them. Prints one verdict line per pin and
exits with a bitmask: 1 = at least one BEHIND, 2 = at least one UNCHECKED.

A package inside a tree carrying a VENDORED.md marker (a verbatim upstream copy,
e.g. claude-hud) reads VENDORED: its pins are upstream's, so they are neither
compared to npm-latest nor bumped here.

scripts/upstreams/pin-holds.json records a bump held back on purpose. A hold
reads HELD only while the pin is still at `current` AND upstream's latest is
still `latest_reviewed`; any newer upstream release re-raises BEHIND.
"""
import json
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

# `fixtures` holds deliberately stale test inputs (scripts/lanes/bench/fixtures).
SKIP_DIRS = {"node_modules", ".git", "dist", ".claude", "graphify-out", "vendor", "fixtures"}
STABLE = re.compile(r"^v?\d+(\.\d+){0,3}$")


def walk(root):
    for dp, dns, fns in os.walk(root):
        dns[:] = [d for d in dns if d not in SKIP_DIRS]
        for fn in fns:
            yield os.path.join(dp, fn)


def rel(root, p):
    return os.path.relpath(p, root).replace(os.sep, "/")


def lock_versions(dirpath):
    res = {}
    lp = os.path.join(dirpath, "package-lock.json")
    bp = os.path.join(dirpath, "bun.lock")
    if os.path.exists(lp):
        try:
            for k, v in json.load(open(lp)).get("packages", {}).items():
                if k.startswith("node_modules/") and k.count("node_modules/") == 1:
                    res[k[len("node_modules/"):]] = v.get("version")
        except (OSError, ValueError):
            pass
    elif os.path.exists(bp):
        for m in re.finditer(r'"([^"]+)": \["([^"]+)@([^"@]+)"', open(bp).read()):
            res[m.group(1)] = m.group(3)
    return res


def is_vendored(root, dirpath):
    """True when dirpath or an ancestor below root carries a VENDORED.md marker."""
    root = os.path.abspath(root)
    d = os.path.abspath(dirpath)
    while d.startswith(root) and d != root:
        if os.path.exists(os.path.join(d, "VENDORED.md")):
            return True
        d = os.path.dirname(d)
    return False


def discover(root):
    pins = {}  # (eco, key, current) -> set(where)
    vendored = {}  # same key -> set(where) found inside vendored upstream trees

    def add(eco, key, current, where, vend=False):
        (vendored if vend else pins).setdefault((eco, key, current), set()).add(where)

    for p in walk(root):
        name = os.path.basename(p)
        r = rel(root, p)
        if name == "package.json":
            try:
                pj = json.load(open(p))
            except (OSError, ValueError):
                continue
            locked = lock_versions(os.path.dirname(p))
            vend = is_vendored(root, os.path.dirname(p))
            for sec in ("dependencies", "devDependencies"):
                for pkg, rng in (pj.get(sec) or {}).items():
                    cur = locked.get(pkg)
                    if not cur and re.match(r"^\d+\.\d+\.\d+$", str(rng)):
                        cur = rng
                    add("npm", pkg, cur or "?", os.path.dirname(r) or ".", vend)
        elif name.startswith(".pre-commit-config") and name.endswith((".yaml", ".yml")):
            text = open(p).read()
            for m in re.finditer(
                r"repo:\s*https://github\.com/([^\s/]+/[^\s/]+?)(?:\.git)?\s*\n\s*rev:\s*(\S+)", text
            ):
                add("gh", m.group(1), m.group(2), r)
        elif r.startswith(".github/workflows/") and name.endswith((".yml", ".yaml")):
            text = open(p).read()
            # `uses: o/r@ref` is deliberately NOT scanned: Dependabot's
            # github-actions ecosystem owns action bumps (one owner per pin,
            # HIMMEL-4258).
            for pm in re.finditer(r"pip install\b[^\n]*", text):
                for m in re.finditer(r"(?<![\w.=-])([A-Za-z0-9_.-]+)==(\d+(?:\.\d+)*)(?![\w.+!-])", pm.group(0)):
                    add("pypi", m.group(1), m.group(2), r)
            if "gitleaks/gitleaks/releases/download" in text:
                for m in re.finditer(r"^\s*ver=(\d+\.\d+\.\d+)\s*$", text, re.M):
                    add("gh", "gitleaks/gitleaks", "v" + m.group(1), r)
        elif r.startswith("scripts/hooks/") and name.endswith(".sh"):
            for m in re.finditer(r"^OXLINT_VERSION=(\d+\.\d+\.\d+)\s*$", open(p).read(), re.M):
                add("npm", "oxlint", m.group(1), r)
    return pins, vendored


def run(cmd):
    return subprocess.run(cmd, capture_output=True, text=True, timeout=30)


def latest_npm(pkg):
    out = run(["curl", "-fsS", "--max-time", "20", f"https://registry.npmjs.org/{pkg}/latest"])
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout).get("version")
    except ValueError:
        return None


def latest_pypi(pkg):
    out = run(["curl", "-fsS", "--max-time", "20", f"https://pypi.org/pypi/{pkg}/json"])
    if out.returncode != 0:
        return None
    try:
        return json.loads(out.stdout).get("info", {}).get("version")
    except ValueError:
        return None


def semver_key(v):
    return tuple(int(x) for x in re.findall(r"\d+", v.lstrip("vV").split("-")[0])[:4])


def latest_gh(repo):
    out = run(["gh", "api", f"repos/{repo}/releases/latest", "--jq", ".tag_name"])
    tag = out.stdout.strip()
    if out.returncode == 0 and STABLE.match(tag):
        return tag
    out = run(["gh", "api", f"repos/{repo}/tags?per_page=100", "--jq", ".[].name"])
    tags = [t for t in out.stdout.split() if STABLE.match(t)]
    if out.returncode != 0 or not tags:
        return None
    return max(tags, key=semver_key)


def compare(current, latest):
    """CURRENT / BEHIND. A major-only pin (an action's `v7`) tracks its major."""
    cur, lat = current.lstrip("vV"), latest.lstrip("vV")
    if cur == lat:
        return "CURRENT"
    if re.match(r"^\d+$", cur):
        return "CURRENT" if lat.split(".")[0] == cur else ("BEHIND" if int(lat.split(".")[0]) > int(cur) else "CURRENT")
    return "BEHIND" if semver_key(lat) > semver_key(cur) else "CURRENT"


def main():
    root = sys.argv[1]
    holds_path = sys.argv[2] if len(sys.argv) > 2 else ""
    holds = []
    if holds_path and os.path.exists(holds_path):
        holds = json.load(open(holds_path)).get("holds", [])
    found, vend_found = discover(root)
    pins = sorted(found.items())

    def check(item):
        (eco, key, current), where = item
        latest = {"npm": latest_npm, "pypi": latest_pypi}.get(eco, latest_gh)(key)
        return eco, key, current, sorted(where), latest

    with ThreadPoolExecutor(8) as ex:
        results = list(ex.map(check, pins))

    rc = 0
    # A vendored tree's pins are upstream's: never compared to npm-latest, never
    # bumped here. Upstream advance is watched by its scripts/upstreams.json row.
    for (eco, key, current), where in sorted(vend_found.items()):
        if (eco, key, current) not in found:
            print(f"  {eco}:{key} {current} ({', '.join(sorted(where))}): VENDORED (upstream-owned pin; "
                  "follows upstream — bump via /fork-resync, upstream advance watched by upstreams.json)")
    for eco, key, current, where, latest in results:
        label = f"{eco}:{key} {current} ({', '.join(where)})"
        if current == "?":
            print(f"  {label}: ? no resolvable current version — UNCHECKED")
            rc |= 2
        elif not latest:
            print(f"  {label}: ? latest release unreachable — UNCHECKED")
            rc |= 2
        elif compare(current, latest) == "CURRENT":
            print(f"  {label}: CURRENT  (latest {latest})")
        else:
            hold = next(
                (h for h in holds if h.get("eco") == eco and h.get("key") == key
                 and h.get("current") == current and h.get("latest_reviewed") == latest),
                None,
            )
            if hold:
                print(f"  {label}: HELD     (latest {latest} reviewed and held back: {hold.get('reason', '')})")
            else:
                print(f"  {label}: BEHIND   (latest {latest} — bump)")
                rc |= 1
    return rc


if __name__ == "__main__":
    sys.exit(main())
