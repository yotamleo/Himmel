#!/usr/bin/env python3
"""plan_docs.py — HIMMEL-4000. Turn the roadmap plan dir (HIMMEL-3882) into one
markdown doc per ticket / version / theme / epic, for a qmd collection, and
compute the change fingerprint plan-index.sh gates a rebuild on.

Read-only against the plan dir and every --watch path; writes only --docs.

  plan_docs.py --plan-dir D --emit-fp [--watch P]...
  plan_docs.py --plan-dir D --docs OUT [--watch P]...

Inputs: stage1/C<NN>.tsv (theme, epic, goals), stage1/C<NN>.explain.tsv (plain
text), stage3/placement.tsv (version, layer, rank, reason; the placed set).
"""
import argparse
import csv
import hashlib
import os
import re
import shutil
import sys


def read_tsv(path):
    with open(path, newline="", encoding="utf-8") as fh:
        return list(csv.DictReader(fh, delimiter="\t", quoting=csv.QUOTE_NONE))


def chunk_files(plan, stage, pattern):
    d = os.path.join(plan, stage)
    if not os.path.isdir(d):
        return []
    return [os.path.join(d, n) for n in sorted(os.listdir(d)) if re.fullmatch(pattern, n)]


def slug(text):
    return re.sub(r"[^a-z0-9.]+", "-", text.lower()).strip("-.") or "none"


def fingerprint(plan, watches):
    h = hashlib.sha256()
    for stage in ("stage1", "stage3"):
        d = os.path.join(plan, stage)
        if not os.path.isdir(d):
            continue
        for n in sorted(os.listdir(d)):
            if n.endswith((".tsv", ".json")):
                with open(os.path.join(d, n), "rb") as fh:
                    h.update(("%s/%s\0" % (stage, n)).encode() + hashlib.sha256(fh.read()).digest())
    for w in watches:
        if os.path.isdir(w):
            for root, _dirs, files in sorted(os.walk(w)):
                for n in sorted(files):
                    p = os.path.join(root, n)
                    st = os.stat(p)
                    h.update(("%s\0%d\0%d\0" % (p, st.st_size, st.st_mtime_ns)).encode())
        elif os.path.isfile(w):
            st = os.stat(w)
            h.update(("%s\0%d\0%d\0" % (w, st.st_size, st.st_mtime_ns)).encode())
        else:
            h.update(("%s\0missing\0" % w).encode())
    return h.hexdigest()


def write(path, text):
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text)


def group_doc(kind, name, members):
    lines = ["---", "kind: %s" % kind, "name: %s" % name, "---", "", "# %s %s" % (kind, name), ""]
    lines += ["- %s: %s" % (k, why) for k, why in members]
    return "\n".join(lines) + "\n"


def build(plan, docs):
    stage1, explain = {}, {}
    for f in chunk_files(plan, "stage1", r"C\d+\.tsv"):
        for r in read_tsv(f):
            stage1[r["key"]] = r
    for f in chunk_files(plan, "stage1", r"C\d+\.explain\.tsv"):
        for r in read_tsv(f):
            explain[r["key"]] = r
    placement = read_tsv(os.path.join(plan, "stage3", "placement.tsv"))
    for p in placement:
        if not re.fullmatch(r"[A-Za-z][A-Za-z0-9]*-[0-9]+", p["key"]):
            sys.exit("plan_docs: refusing ticket key %r (not a plain KEY-n)" % p["key"])
    rp, rd = os.path.realpath(plan), os.path.realpath(docs)
    if rd == rp or rd.startswith(rp + os.sep) or rp.startswith(rd + os.sep):
        sys.exit("plan_docs: --docs %s overlaps the plan dir %s; refusing to delete it" % (docs, plan))
    tmp = docs + ".new"
    shutil.rmtree(tmp, ignore_errors=True)
    os.makedirs(tmp)
    groups = {"version": {}, "theme": {}, "epic": {}}
    for p in placement:
        key = p["key"]
        s1 = stage1.get(key, {})
        ex = explain.get(key, {})
        theme, epic = s1.get("theme", ""), s1.get("epic", "")
        goals = [g for g in re.split(r"[;,\s]+", s1.get("goals", "")) if g]
        version = p.get("version", "")
        reason = p.get("reason", "")
        for kind, val in (("version", version), ("theme", theme), ("epic", epic)):
            if val:
                groups[kind].setdefault(val, []).append((key, reason or p.get("layer", "")))
        body = [
            "---", "ticket: %s" % key, "version: %s" % version, "theme: %s" % theme,
            "epic: %s" % epic, "goals: %s" % ";".join(goals), "layer: %s" % p.get("layer", ""),
            "rank: %s" % p.get("rank", ""), "commit: %s" % p.get("commit", ""), "---", "",
            "# %s (roadmap plan)" % key, "",
            "Version %s, theme %s, epic %s, goals %s." % (version, theme or "none", epic or "none", ", ".join(goals) or "none"),
            "", "Why placed: %s" % reason, "",
        ]
        if ex.get("issue_plain"):
            body += ["What it is: %s" % ex["issue_plain"], ""]
        if ex.get("user_impact"):
            body += ["User impact: %s" % ex["user_impact"], ""]
        write(os.path.join(tmp, "%s.md" % key), "\n".join(body))
    used = set()
    for kind, members in groups.items():
        for name, rows in members.items():
            fname, n = "%s-%s.md" % (kind, slug(name)), 2
            while fname in used:  # distinct names can share a slug; never overwrite
                fname, n = "%s-%s-%d.md" % (kind, slug(name), n), n + 1
            used.add(fname)
            write(os.path.join(tmp, fname), group_doc(kind, name, rows))
    shutil.rmtree(docs, ignore_errors=True)
    os.rename(tmp, docs)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--plan-dir", required=True)
    ap.add_argument("--docs")
    ap.add_argument("--watch", action="append", default=[])
    ap.add_argument("--emit-fp", action="store_true")
    a = ap.parse_args()
    if a.emit_fp:
        print(fingerprint(a.plan_dir, a.watch))
        return 0
    if not a.docs:
        ap.error("--docs required unless --emit-fp")
    build(a.plan_dir, a.docs)
    return 0


if __name__ == "__main__":
    sys.exit(main())
