#!/usr/bin/env python3
# semantic-merge.py -- HIMMEL-4185: the stdlib half of semantic-update.sh.
# Owns the content-hash manifest (<out>/semantic-manifest.json) and the merge of
# a scratch semantic extraction into the live <out>/graph.json. Never imports
# the `graphify` package (not importable from system python3; see
# harden-graph.py's header).
#
#   plan  --root R --out O --max-files N --plan P   diff corpus vs manifest
#   seed  --root R --out O                          stamp current hashes only
#   merge --out O --scratch S --plan P --runtime-s T --tokens-in I --tokens-out J
#
# Ownership rule for the merge: the AST pass (`graphify update`, hourly) owns
# every `_origin: ast` node/edge; this step owns only `_origin: semantic` ones.
# For each re-extracted or deleted file it drops that file's semantic nodes,
# edges and hyperedges, then adds the scratch extraction's semantic items.
# Clustering is left to the next AST pass, which reclusters the whole graph
# and keeps semantic nodes.
import argparse
import hashlib
import json
import os
import subprocess
import sys
import time

MANIFEST = "semantic-manifest.json"
RUNS = "semantic-runs.jsonl"
# Sonnet list price per 1M tokens (in, out): the GRAPHIFY_CLAUDE_CLI_MODEL pin.
# A cost EQUIVALENT only -- claude-cli bills the subscription bank, not dollars.
PRICE_IN, PRICE_OUT = 3.0, 15.0


def die(msg, rc=1):
    print("semantic-merge: " + msg, file=sys.stderr)
    sys.exit(rc)


def load_json(path, default=None):
    if not os.path.exists(path):
        if default is not None:
            return default
        die("missing " + path)
    with open(path, encoding="utf-8") as f:
        return json.load(f)


def write_json_atomic(path, data):
    tmp = "%s.tmp.%d" % (path, os.getpid())
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False)
    os.replace(tmp, path)


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def ignored_dirs(root):
    # Same file + dialect as refresh-graph-map.sh (HIMMEL-1903): one
    # corpus-relative directory per line, `#` comments, no `..` components.
    path = os.path.join(root, ".graphify-corpus-ignore")
    dirs = []
    if os.path.exists(path):
        with open(path, encoding="utf-8") as f:
            for line in f:
                line = line.strip().strip("/")
                if not line or line.startswith("#"):
                    continue
                if ".." in line.split("/") or line.startswith("/"):
                    print("semantic-merge: ignoring unsafe .graphify-corpus-ignore entry '%s'" % line, file=sys.stderr)
                    continue
                dirs.append(line + "/")
    return dirs


def corpus_files(root, out_name):
    # git ls-files when the root is a work tree: honours .gitignore and skips
    # nested worktrees (.claude/worktrees/) a bare walk would graph N times.
    try:
        raw = subprocess.run(
            ["git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard", "--", "*.md"],
            capture_output=True, check=True).stdout.decode("utf-8")
        files = [p for p in raw.split("\0") if p]
    except (subprocess.CalledProcessError, FileNotFoundError):
        files = []
        for dp, dns, fns in os.walk(root):
            dns[:] = [d for d in dns if d not in (".git", out_name, "graphify-out")]
            for fn in fns:
                if fn.endswith(".md"):
                    files.append(os.path.relpath(os.path.join(dp, fn), root))
    skip = ignored_dirs(root) + [out_name + "/", "graphify-out/"]
    keep = []
    for rel in files:
        rel = rel.replace(os.sep, "/")
        if any(rel.startswith(d) for d in skip):
            continue
        full = os.path.join(root, rel)
        if os.path.isfile(full) and not os.path.islink(full):
            keep.append(rel)
    return sorted(set(keep))


def manifest_files(out):
    return load_json(os.path.join(out, MANIFEST), {"version": 1, "files": {}}).get("files", {})


def cmd_plan(a):
    old = manifest_files(a.out)
    now = {rel: sha256(os.path.join(a.root, rel)) for rel in corpus_files(a.root, os.path.basename(a.out))}
    changed = [rel for rel in sorted(now) if old.get(rel) != now[rel]]
    deleted = sorted(rel for rel in old if rel not in now)
    batch = changed[:a.max_files]
    plan = {"changed_total": len(changed), "batch": batch, "deleted": deleted,
            "backlog": len(changed) - len(batch)}
    write_json_atomic(a.plan, plan)
    print("plan: changed=%d batch=%d deleted=%d backlog=%d"
          % (len(changed), len(batch), len(deleted), plan["backlog"]))


def cmd_seed(a):
    files = {rel: sha256(os.path.join(a.root, rel)) for rel in corpus_files(a.root, os.path.basename(a.out))}
    write_json_atomic(os.path.join(a.out, MANIFEST), {"version": 1, "files": files})
    print("seed: stamped %d files as the semantic baseline" % len(files))


def norm_src(src, scratch):
    if not isinstance(src, str):
        return src
    s = src.replace(os.sep, "/")
    prefix = scratch.replace(os.sep, "/").rstrip("/") + "/"
    return s[len(prefix):] if s.startswith(prefix) else s


def cmd_merge(a):
    plan = load_json(a.plan)
    graph_path = os.path.join(a.out, "graph.json")
    g = load_json(graph_path)
    ekey = "links" if "links" in g else "edges"
    batch = set(plan["batch"])

    sg = {"nodes": [], ekey: [], "hyperedges": []}
    if batch:
        sg = load_json(os.path.join(a.scratch, "graphify-out", "graph.json"))
    s_edges = sg.get("links", sg.get("edges", []))

    def semantic(item):
        return item.get("_origin", "semantic") != "ast"

    new_nodes = [n for n in sg.get("nodes", []) if semantic(n)]
    new_edges = [e for e in s_edges if semantic(e)]
    new_hyper = [h for h in sg.get("hyperedges", []) or [] if semantic(h)]
    for item in new_nodes + new_edges + new_hyper:
        item["source_file"] = norm_src(item.get("source_file"), a.scratch)
        item["_origin"] = "semantic"
    # A scratch path anywhere in what we are about to promote is a host-path
    # leak (same class refresh-graph-map.sh's promote scan refuses).
    if a.scratch in json.dumps(new_nodes + new_edges + new_hyper, ensure_ascii=False):
        die("REFUSING merge: the scratch path %s leaks into the extraction" % a.scratch, 2)

    # A batch file the extraction produced nothing for is a failed chunk (the
    # model omitted it): it keeps its old semantic items and stays unstamped,
    # so the next run retries it. Only produced and deleted files are replaced.
    # ponytail: a file the model always omits is retried (and billed) every run, add a per-file failure count to the manifest once semantic-runs.jsonl shows `failed` not draining.
    produced = {n.get("source_file") for n in new_nodes}
    failed = sorted(batch - produced)
    touched = (batch & produced) | set(plan["deleted"])

    def owned(item):
        return item.get("_origin") == "semantic" and item.get("source_file") in touched

    # Remove the owned items, add the new nodes, and only THEN prune edges
    # against the final node set: an untouched file's edge to a node the
    # re-extraction restores must survive.
    before_n, before_e = len(g["nodes"]), len(g[ekey])
    g["nodes"] = [n for n in g["nodes"] if not owned(n)]
    live_ids = {n["id"] for n in g["nodes"]}
    nodes_removed = before_n - len(g["nodes"])
    g["hyperedges"] = [h for h in g.get("hyperedges") or [] if not owned(h)]

    nodes_added = 0
    for n in new_nodes:
        if n["id"] not in live_ids:
            g["nodes"].append(n)
            live_ids.add(n["id"])
            nodes_added += 1
    g[ekey] = [e for e in g[ekey] if not owned(e) and e["source"] in live_ids and e["target"] in live_ids]
    edges_removed = before_e - len(g[ekey])
    edges_added = 0
    for e in new_edges:
        if e.get("source") in live_ids and e.get("target") in live_ids:
            g[ekey].append(e)
            edges_added += 1
    # Hyperedge members follow their nodes: prune removed ids, and drop a
    # hyperedge left with fewer than two members.
    hyper = []
    for h in g["hyperedges"] + new_hyper:
        h["nodes"] = [m for m in h.get("nodes", []) if m in live_ids]
        if len(h["nodes"]) >= 2:
            hyper.append(h)
    g["hyperedges"] = hyper

    # The manifest dict is computed (files hashed) first, so a hashing failure
    # leaves graph.json untouched. graph.json is then written BEFORE the
    # manifest: a file is stamped only once its graph content landed, and a
    # crash between the two leaves it unstamped, so the next run re-replaces it
    # by source_file (idempotent).
    files = manifest_files(a.out)
    for rel in plan["deleted"]:
        files.pop(rel, None)
    for rel in batch - set(failed):
        files[rel] = sha256(os.path.join(a.scratch, rel))
    write_json_atomic(graph_path, g)
    write_json_atomic(os.path.join(a.out, MANIFEST), {"version": 1, "files": files})

    run = {
        "ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "name": a.name, "changed_total": plan["changed_total"], "batch": len(batch),
        "deleted": len(plan["deleted"]), "backlog": plan["backlog"], "failed": len(failed),
        "nodes_added": nodes_added, "nodes_removed": nodes_removed,
        "edges_added": edges_added, "edges_removed": edges_removed,
        "runtime_s": a.runtime_s, "tokens_in": a.tokens_in, "tokens_out": a.tokens_out,
        "cost_eq_usd": round(a.tokens_in / 1e6 * PRICE_IN + a.tokens_out / 1e6 * PRICE_OUT, 4),
    }
    with open(os.path.join(a.out, RUNS), "a", encoding="utf-8") as f:
        f.write(json.dumps(run) + "\n")
    print("merge: " + json.dumps(run))


def main():
    ap = argparse.ArgumentParser()
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("plan")
    p.add_argument("--root", required=True)
    p.add_argument("--out", required=True)
    p.add_argument("--max-files", type=int, required=True)
    p.add_argument("--plan", required=True)
    s = sub.add_parser("seed")
    s.add_argument("--root", required=True)
    s.add_argument("--out", required=True)
    m = sub.add_parser("merge")
    m.add_argument("--name", required=True)
    m.add_argument("--out", required=True)
    m.add_argument("--scratch", required=True)
    m.add_argument("--plan", required=True)
    m.add_argument("--runtime-s", type=int, default=0)
    m.add_argument("--tokens-in", type=int, default=0)
    m.add_argument("--tokens-out", type=int, default=0)
    a = ap.parse_args()
    {"plan": cmd_plan, "seed": cmd_seed, "merge": cmd_merge}[a.cmd](a)


if __name__ == "__main__":
    main()
