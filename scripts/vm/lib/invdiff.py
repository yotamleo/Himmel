#!/usr/bin/env python3
"""invdiff.py A B — diff two /tmp/inv-<label> dirs (home.meta + home.sha + others). HIMMEL-3324."""
import sys, os, re, collections

# INVDIFF_BASE: the dir holding inv-<label>/ (S9a seam; unset = <script dir>/inv, the 3324 layout).
base = os.environ.get("INVDIFF_BASE") or os.path.dirname(os.path.abspath(__file__)) + "/inv"
a, b = sys.argv[1], sys.argv[2]
NOISE = [r"^/tmp/node-compile-cache", r"^/tmp/systemd-private-", r"/\.npm/_logs/"]


def noisy(p):
    return any(re.search(n, p) for n in NOISE)


def meta(label, name="home.meta"):
    d = {}
    for line in open(f"{base}/inv-{label}/{name}", errors="replace"):
        f = line.rstrip("\n").split("\t")
        if len(f) < 4:
            continue
        d[f[3]] = (f[0], f[1], f[2], f[4] if len(f) > 4 else "")
    return d


def unescape(p):
    # sha256sum escapes \ as \\, newline as \n and CR as \r in the name of an escaped record.
    return re.sub(r"\\(.)", lambda m: {"n": "\n", "r": "\r"}.get(m.group(1), m.group(1)), p)


def sha(label, name="home.sha"):
    d = {}
    for line in open(f"{base}/inv-{label}/{name}", errors="replace"):
        h, _, p = line.rstrip("\n").partition("  ")
        if h.startswith("\\"):  # a leading backslash marks a record whose name is escaped
            h, p = h[1:], unescape(p)
        d[p] = h
    return d


def describe(t):
    kind, mode, _size, target = t
    return f"{kind} {mode}" + (f" -> {target}" if target else "")


def meta_changed(xa, xb):
    """Paths in both inventories whose type, mode or symlink target differ. Size is left out on
    purpose: a regular file's size moves with its content (reported by the sha diff) and a
    directory's size is filesystem noise."""
    return sorted(p for p in xa if p in xb and not noisy(p)
                  and (xa[p][0], xa[p][1], xa[p][3]) != (xb[p][0], xb[p][1], xb[p][3]))


DEPTH = int(sys.argv[3]) if len(sys.argv) > 3 else 3


def top(p, n=None):
    n = n or DEPTH
    parts = p.split("/")
    return "/".join(parts[: n + 1])


ma, mb = meta(a), meta(b)
sa, sb = sha(a), sha(b)
added = sorted(p for p in mb if p not in ma and not noisy(p))
removed = sorted(p for p in ma if p not in mb and not noisy(p))
changed = sorted(p for p in sa if p in sb and sa[p] != sb[p] and not noisy(p))
mchanged = meta_changed(ma, mb)
print(f"### {a} -> {b}: added={len(added)} removed={len(removed)} content-changed={len(changed)} meta-changed={len(mchanged)}")

for title, lst, m in (("ADDED", added, mb), ("REMOVED", removed, ma)):
    grp = collections.Counter(top(p) for p in lst)
    sz = collections.Counter()
    for p in lst:
        if m[p][0] == "f":
            sz[top(p)] += int(m[p][2])
    print(f"\n== {title}: grouped by first 3 path components under $HOME (count, bytes)")
    for k, v in sorted(grp.items()):
        print(f"{v:7d} {sz[k]:14d}  {k}")
print("\n== CONTENT-CHANGED regular files (shown individually)")
for p in changed:
    print("  ", p)
print("\n== META-CHANGED paths present in both (type/mode/symlink target: before => after)")
for p in mchanged:
    print("  ", f"{p}: {describe(ma[p])} => {describe(mb[p])}")
for name in ("etc.sha",):
    ea, eb = sha(a, name), sha(b, name)
    print(f"\n== /etc: added={[p for p in eb if p not in ea]} removed={[p for p in ea if p not in eb]} changed={[p for p in ea if p in eb and ea[p]!=eb[p]]}")
for name in ("sys.meta", "tmp.meta"):
    xa, xb = meta(a, name), meta(b, name)
    ad = sorted(p for p in xb if p not in xa and not noisy(p))
    rm = sorted(p for p in xa if p not in xb and not noisy(p))
    print(f"\n== {name}: added={ad} removed={rm} meta-changed={meta_changed(xa, xb)}")
